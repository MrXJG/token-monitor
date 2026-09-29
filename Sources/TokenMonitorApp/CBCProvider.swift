import Foundation

struct CBCProvider: UsageProvider {
    let baseURL: URL
    let session: URLSession
    var manifest: ProviderManifest {
        ProviderManifest(
            id: baseURL.absoluteString == "https://cbc.icu/prod-api" ? "cbc" : "cbc:\(baseURL.absoluteString)",
            name: baseURL.host == "cbc.icu" ? "CBC 旧版" : (baseURL.host ?? "中转站"),
            capabilities: [.balance, .usageTrend, .requestDetails, .cacheUsage, .modelBreakdown],
            supportedAuthMethods: [.apiKey, .password]
        )
    }

    private let decoder: JSONDecoder

    init(baseURL: URL = URL(string: "https://cbc.icu/prod-api")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formats = ["yyyy-MM-dd'T'HH:mm:ss.SSSXXX", "yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]
            for format in formats {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
                formatter.dateFormat = format
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
        let payload: Envelope<[TrendPayload]> = try await request(path: "/aigate/dashboard/user/trend", query: [URLQueryItem(name: "range", value: String(days))], token: session.token)
        guard let data = payload.data else { throw ProviderError.decoding("趋势数据为空") }
        return data.compactMap { item -> UsageBucket? in
            guard let date = item.date else { return nil }
            return UsageBucket(id: date.formatted(.iso8601), date: date, requestCount: item.requestCount ?? 0, inputTokens: item.promptTokens ?? 0, outputTokens: item.completionTokens ?? 0, totalTokens: item.totalTokens ?? ((item.promptTokens ?? 0) + (item.completionTokens ?? 0)), cacheReadTokens: item.cacheReadTokens ?? 0, cacheWriteTokens: item.cacheWriteTokens, cost: item.cost)
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
            UsageRecord(id: row.logId.map(String.init) ?? row.requestId ?? UUID().uuidString, requestId: row.requestId, requestTime: row.requestTime, modelName: row.modelName ?? "未知模型", inputTokens: row.promptTokens ?? 0, outputTokens: row.completionTokens ?? 0, cacheReadTokens: row.cacheReadTokens ?? 0, cacheWriteTokens: row.cacheWriteTokens, reasoningTokens: row.reasoningOutputTokens ?? 0, cost: row.cost, status: row.status == "0" ? "成功" : "失败", errorMessage: row.errorMessage, keyName: row.keyName, relayMode: row.relayMode, reasoningEffort: row.reasoningEffort, groupName: row.groupName, isStream: row.isStream.map { $0 == 1 }, durationMs: row.duration, timeToFirstTokenMs: row.ttft, upstreamFirstEventMs: row.upstreamFirstEventMs)
        }
        return UsagePage(records: records, total: payload.total ?? records.count)
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
        if http.statusCode == 401 { throw ProviderError.unauthenticated }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.server("服务器返回 HTTP \(http.statusCode)") }
        if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true {
            throw ProviderError.server("站点返回网页而非接口数据，请确认所选 CBC 接口版本")
        }
        do {
            let status = try decoder.decode(ResponseStatus.self, from: data)
            if status.code == 401 { throw ProviderError.unauthenticated }
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
private struct UsagePayload: Decodable { var logId: Int?; var requestId: String?; var requestTime: Date?; var modelName: String?; var promptTokens: Int?; var completionTokens: Int?; var cacheReadTokens: Int?; var cacheWriteTokens: Int?; var reasoningOutputTokens: Int?; var cost: Decimal?; var status: String?; var errorMessage: String?; var keyName: String?; var relayMode: String?; var reasoningEffort: String?; var groupName: String?; var isStream: Int?; var duration: Int?; var ttft: Int?; var upstreamFirstEventMs: Int? }
