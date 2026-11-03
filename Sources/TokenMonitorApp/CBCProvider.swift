import Foundation
import CryptoKit

struct CBCProvider: UsageProvider {
    let baseURL: URL
    let session: URLSession
    var manifest: ProviderManifest {
        let host = baseURL.host?.lowercased()
        let isRunOK = host == "runok.ai" || host == "www.runok.ai"
        return ProviderManifest(
            id: isRunOK ? "cbc-runok" : (baseURL.absoluteString == "https://cbc.icu/prod-api" ? "cbc" : "cbc:\(baseURL.absoluteString)"),
            name: isRunOK ? "柴哥 API" : (baseURL.host == "cbc.icu" ? "CBC 旧版" : (baseURL.host ?? "中转站")),
            capabilities: [.balance, .usageTrend, .requestDetails, .cacheUsage, .modelBreakdown, .groupRates],
            supportedAuthMethods: [.apiKey, .password]
        )
    }

    private let decoder: JSONDecoder

    init(baseURL: URL = URL(string: "https://cbc.icu/prod-api")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        let formatters = ["yyyy-MM-dd'T'HH:mm:ss.SSSXXX", "yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = format
            return formatter
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            for formatter in formatters {
                if let date = formatter.date(from: value) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: value))
        }
        self.decoder = decoder
    }

    static func endpoint(for address: String) throws -> URL {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw ProviderError.invalidURL
        }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.split(separator: "/").last == "index"
            ? path.split(separator: "/").dropLast().joined(separator: "/") : path
        components.path = normalizedPath.split(separator: "/").last == "prod-api"
            ? "/\(normalizedPath)" : "/\(normalizedPath.isEmpty ? "" : "\(normalizedPath)/")prod-api"
        guard let url = components.url else { throw ProviderError.invalidURL }
        return url
    }

    func authenticate(_ method: AuthMethod, secret: String, username: String?) async throws -> AuthSession {
        switch method {
        case .apiKey:
            guard !secret.isEmpty else { throw ProviderError.unauthenticated }
            struct APIKeyBody: Encodable { let apiKey: String }
            struct LoginResponse: Decodable { let token: String?; let msg: String? }
            let response: LoginResponse = try await request(path: "/apikey/login", method: "POST", token: nil, body: APIKeyBody(apiKey: secret))
            guard let token = response.token else {
                throw ProviderError.server(response.msg ?? "API Key 登录失败")
            }
            return AuthSession(token: token, expiresAt: nil, method: method)
        case .password:
            guard let username, !username.isEmpty, !secret.isEmpty else { throw ProviderError.unauthenticated }
            struct LoginBody: Encodable { let username: String; let password: String; let code: String; let uuid: String; let rememberMe = true }
            struct LoginResponse: Decodable { let token: String?; let accessToken: String?; let msg: String? }
            let response: LoginResponse = try await request(path: "/login", method: "POST", token: nil, body: LoginBody(username: username, password: secret, code: "", uuid: ""))
            guard let token = response.token ?? response.accessToken else {
                throw ProviderError.server(response.msg ?? "登录失败，站点可能要求验证码")
            }
            return AuthSession(token: token, expiresAt: nil, method: method)
        }
    }

    func fetchOverview(session: AuthSession) async throws -> UsageOverview {
        let payload: Envelope<OverviewPayload> = try await request(path: "/aigate/dashboard/user", token: session.token)
        guard let value = payload.data else { throw ProviderError.decoding("概览数据为空") }
        return UsageOverview(
            availableBalance: value.availableBalance ?? value.balance,
            balance: value.balance,
            frozenBalance: value.frozenBalance,
            usedBalance: value.usedBalance,
            totalUncoveredAmount: value.totalUncoveredAmount,
            requestCount: value.requestCount ?? 0,
            todayRequests: value.todayRequests ?? 0,
            totalTokens: value.totalTokens ?? 0,
            inputTokens: value.promptTokens ?? 0,
            outputTokens: value.completionTokens ?? 0,
            cacheReadTokens: value.cacheReadTokens ?? 0,
            cacheWriteTokens: value.cacheWriteTokens,
            reasoningTokens: value.reasoningOutputTokens ?? 0,
            cost: value.totalChargedAmount,
            todayCost: nil,
            averageFirstTokenTimeMs: value.averageFirstTokenTime,
            averageResponseTimeMs: value.averageResponseTime,
            apiKeyCount: value.apiKeyCount ?? 0,
            updatedAt: Date()
        )
    }

    func fetchTrend(session: AuthSession, days: Int) async throws -> [UsageBucket] {
        try await fetchTrend(session: session, days: days) { query in
            try await fetchRecentUsage(session: session, query: query)
        }
    }

    func fetchTrend(session: AuthSession, days: Int,
                    fetchPage: @Sendable (UsageQuery) async throws -> UsagePage) async throws -> [UsageBucket] {
        do {
            let payload: Envelope<[TrendPayload]> = try await request(path: "/aigate/dashboard/user/trend", query: [URLQueryItem(name: "range", value: String(days))], token: session.token)
            guard let data = payload.data else { throw ProviderError.decoding("趋势数据为空") }
            return data.compactMap { item -> UsageBucket? in
                guard let date = item.date else { return nil }
                return UsageBucket(id: date.formatted(.iso8601), date: date, requestCount: item.requestCount ?? 0, inputTokens: item.promptTokens ?? 0, outputTokens: item.completionTokens ?? 0, totalTokens: item.totalTokens ?? ((item.promptTokens ?? 0) + (item.completionTokens ?? 0)), cacheReadTokens: item.cacheReadTokens ?? 0, cacheWriteTokens: item.cacheWriteTokens, cost: item.cost)
            }
        } catch ProviderError.server(let message) where message.contains("请求地址不存在") || message.contains("HTTP 404") || message.contains("服务器返回错误 404") {
            return try await fetchTrendFromUsage(days: days, fetchPage: fetchPage)
        }
    }

    private func fetchTrendFromUsage(days: Int, fetchPage: @Sendable (UsageQuery) async throws -> UsagePage) async throws -> [UsageBucket] {
        guard days > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: 1 - days, to: today)!
        var aggregates: [Date: (requests: Int, input: Int, output: Int, total: Int, read: Int, write: Int, cost: Decimal)] = [:]
        var page = 1
        var total = Int.max
        var loaded = 0
        while loaded < total && page <= 100 {
            let result = try await fetchPage(UsageQuery(page: page, pageSize: 100))
            total = result.total
            loaded += result.records.count
            for record in result.records {
                guard let date = record.requestTime else { continue }
                let day = calendar.startOfDay(for: date)
                if day < start || day > today { continue }
                let existing = aggregates[day] ?? (0, 0, 0, 0, 0, 0, 0)
                aggregates[day] = (existing.requests + 1,
                                   existing.input + record.inputTokens,
                                   existing.output + record.outputTokens,
                                   existing.total + record.totalTokens,
                                   existing.read + record.cacheReadTokens,
                                   existing.write + (record.cacheWriteTokens ?? 0),
                                   existing.cost + (record.cost ?? 0))
            }
            if result.records.isEmpty || result.records.contains(where: { record in
                guard let date = record.requestTime else { return false }
                return calendar.startOfDay(for: date) < start
            }) { break }
            page += 1
        }
        return (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let value = aggregates[date] ?? (0, 0, 0, 0, 0, 0, 0)
            return UsageBucket(id: date.formatted(.iso8601), date: date, requestCount: value.requests,
                               inputTokens: value.input, outputTokens: value.output, totalTokens: value.total,
                               cacheReadTokens: value.read, cacheWriteTokens: value.write, cost: value.cost)
        }
    }

    func fetchRecentUsage(session: AuthSession, query: UsageQuery) async throws -> UsagePage {
        let items: [URLQueryItem] = [
            URLQueryItem(name: "pageNum", value: String(query.page)),
            URLQueryItem(name: "pageSize", value: String(query.pageSize)),
            URLQueryItem(name: "modelName", value: query.modelName),
            URLQueryItem(name: "status", value: query.status)
        ].compactMap { $0.value == nil ? nil : $0 }
        let payload: PagedEnvelope<UsagePayload> = try await request(path: "/aigate/log/usage-list", query: items, token: session.token)
        guard let rows = payload.rows else { throw ProviderError.decoding("请求记录为空") }
        let records = rows.map { row in
            UsageRecord(id: Self.recordID(row), requestId: row.requestId, requestTime: row.requestTime, modelName: row.modelName ?? "未知模型", inputTokens: row.promptTokens ?? 0, outputTokens: row.completionTokens ?? 0, cacheReadTokens: row.cacheReadTokens ?? 0, cacheWriteTokens: row.cacheWriteTokens, reasoningTokens: row.reasoningOutputTokens ?? 0, cost: row.cost, status: row.normalizedStatus, errorMessage: row.errorMessage, keyName: row.keyName, relayMode: row.relayMode, reasoningEffort: row.reasoningEffort, groupName: row.groupName, isStream: row.isStream.map { $0 == 1 }, durationMs: row.duration, timeToFirstTokenMs: row.ttft, upstreamFirstEventMs: row.upstreamFirstEventMs, groupID: row.groupId.map(String.init), groupMultiplier: row.groupRatio)
        }
        return UsagePage(records: records, total: payload.total ?? records.count)
    }

    func fetchGroupRates(session: AuthSession) async throws -> [GroupRate] {
        let payload: Envelope<[LegacyGroupPayload]> = try await request(path: "/aigate/group/available", token: session.token)
        guard let groups = payload.data else { throw ProviderError.decoding("分组倍率数据为空") }
        return groups.compactMap { group in
            guard group.status == nil || group.status == "0",
                  let id = group.groupId,
                  let name = group.groupName, !name.isEmpty,
                  let ratio = group.ratio else { return nil }
            return GroupRate(id: String(id), name: name, multiplier: ratio)
        }
    }

    private static func recordID(_ row: UsagePayload) -> String {
        if let logId = row.logId { return "cbc-\(logId)" }
        if let requestId = row.requestId, !requestId.isEmpty { return "cbc-\(requestId)" }
        let stable = [row.requestTime?.formatted(.iso8601) ?? "", row.modelName ?? "", String(row.promptTokens ?? 0), String(row.completionTokens ?? 0), String(row.cacheReadTokens ?? 0), row.cost.map(String.init) ?? "", row.relayMode ?? "", row.groupId.map(String.init) ?? ""].joined(separator: "|")
        let digest = SHA256.hash(data: Data(stable.utf8)).map { String(format: "%02x", $0) }.joined()
        return "cbc-\(digest.prefix(24))"
    }

    private func request<T: Decodable>(path: String, method: String = "GET", query: [URLQueryItem] = [], token: String?, body: Encodable? = nil) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { throw ProviderError.invalidURL }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ProviderError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.server("没有收到有效响应") }
        if http.statusCode == 429 { throw ProviderError.rateLimited(retryAfter: http.retryAfterSeconds()) }
        if http.statusCode == 401 { throw ProviderError.unauthenticated }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.server("服务器返回 HTTP \(http.statusCode)") }
        if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true {
            throw ProviderError.server("站点返回网页而非接口数据，请确认所选 CBC 接口版本")
        }
        do {
            let status = try decoder.decode(ResponseStatus.self, from: data)
            if status.code == 401 { throw ProviderError.unauthenticated }
            if status.code == 429 { throw ProviderError.rateLimited(retryAfter: http.retryAfterSeconds()) }
            if let code = status.code, code != 200 {
                throw ProviderError.server(status.msg ?? "服务器返回错误 \(code)")
            }
            return try decoder.decode(T.self, from: data)
        }
        catch let error as ProviderError { throw error }
        catch { throw ProviderError.decoding(error.localizedDescription) }
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init(_ value: Encodable) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}

private struct ResponseStatus: Decodable { let code: Int?; let msg: String? }

private struct Envelope<T: Decodable>: Decodable { let data: T?; let code: Int?; let msg: String? }
private struct PagedEnvelope<T: Decodable>: Decodable { let rows: [T]?; let total: Int?; let code: Int?; let msg: String? }

private struct OverviewPayload: Decodable {
    var apiKeyCount: Int?; var availableBalance: Decimal?; var balance: Decimal?; var frozenBalance: Decimal?; var usedBalance: Decimal?; var totalUncoveredAmount: Decimal?; var requestCount: Int?; var todayRequests: Int?; var totalTokens: Int?; var promptTokens: Int?; var completionTokens: Int?; var cacheReadTokens: Int?; var cacheWriteTokens: Int?; var reasoningOutputTokens: Int?; var totalChargedAmount: Decimal?; var averageFirstTokenTime: Double?; var averageResponseTime: Double?
}
private struct TrendPayload: Decodable { var date: Date?; var requestCount: Int?; var totalTokens: Int?; var promptTokens: Int?; var completionTokens: Int?; var cacheReadTokens: Int?; var cacheWriteTokens: Int?; var cost: Decimal? }
private struct UsagePayload: Decodable {
    var logId: Int?; var requestId: String?; var requestTime: Date?; var modelName: String?
    var promptTokens: Int?; var completionTokens: Int?; var cacheReadTokens: Int?; var cacheWriteTokens: Int?
    var reasoningOutputTokens: Int?; var cost: Decimal?; var status: String?; var statusCode: Int?; var fail: String?
    var errorMessage: String?; var keyName: String?; var relayMode: String?; var reasoningEffort: String?
    var groupName: String?; var groupId: Int?; var groupRatio: Decimal?; var isStream: Int?; var duration: Int?; var ttft: Int?; var upstreamFirstEventMs: Int?

    var normalizedStatus: String {
        if let statusCode { return (200..<300).contains(statusCode) ? "成功" : "失败" }
        if let fail {
            switch fail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "0", "false", "success", "succeeded", "completed", "ok": return "成功"
            case "1", "true", "failed", "failure", "error": return "失败"
            default: break
            }
        }
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "success", "succeeded", "completed", "ok": return "成功"
        case "1", "failed", "failure", "error": return "失败"
        default: return "处理中"
        }
    }
}

private struct LegacyGroupPayload: Decodable {
    var groupId: Int?
    var groupName: String?
    var ratio: Decimal?
    var status: String?
}
