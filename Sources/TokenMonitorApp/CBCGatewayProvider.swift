import Foundation

/// The temporary CBC site uses Sub2API's /api/v1 contract. Its credentials
/// are intentionally separate from CBCProvider's legacy /prod-api session.
struct CBCGatewayProvider: UsageProvider {
    let baseURL: URL
    let session: URLSession

    var manifest: ProviderManifest {
        ProviderManifest(
            id: baseURL.absoluteString == "https://cbc.icu" ? "cbc-v2" : "cbc-v2:\(baseURL.absoluteString)",
            name: baseURL.host == "cbc.icu" ? "CBC 新版" : (baseURL.host ?? "中转站"),
            capabilities: [.balance, .usageTrend, .requestDetails, .cacheUsage, .modelBreakdown],
            supportedAuthMethods: [.password]
        )
    }

    init(baseURL: URL = URL(string: "https://cbc.icu")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    static func endpoint(for address: String) throws -> URL {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw ProviderError.invalidURL }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard ["", "index", "dashboard", "api/v1"].contains(path) else { throw ProviderError.invalidURL }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.path = ""
        guard let url = components.url else { throw ProviderError.invalidURL }
        return url
    }

    func authenticate(_ method: AuthMethod, secret: String, username: String?) async throws -> AuthSession {
        guard method == .password, let email = username, !email.isEmpty, !secret.isEmpty else {
            throw ProviderError.unauthenticated
        }
        let result: GatewayLogin = try await request(
            path: "/auth/login", method: "POST", token: nil,
            body: GatewayLoginBody(email: email, password: secret)
        )
        if result.requires2Fa == true { throw ProviderError.unsupported("此账号需要双重验证，请先在 CBC 网页完成登录") }
        guard let token = result.accessToken, !token.isEmpty else {
            throw ProviderError.decoding("登录响应缺少访问令牌")
        }
        return AuthSession(token: token, expiresAt: result.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                           method: .password, refreshToken: result.refreshToken)
    }

    func renewSession(_ old: AuthSession) async throws -> AuthSession {
        guard let refreshToken = old.refreshToken, !refreshToken.isEmpty else { throw ProviderError.unauthenticated }
        let result: GatewayLogin = try await request(
            path: "/auth/refresh", method: "POST", token: nil,
            body: GatewayRefreshBody(refreshToken: refreshToken)
        )
        guard let token = result.accessToken, !token.isEmpty else { throw ProviderError.unauthenticated }
        return AuthSession(token: token, expiresAt: result.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                           method: .password, refreshToken: result.refreshToken ?? refreshToken)
    }

    func fetchOverview(session: AuthSession) async throws -> UsageOverview {
        async let user: GatewayUser = request(path: "/auth/me", token: session.token)
        async let stats: GatewayStats = request(path: "/usage/dashboard/stats", token: session.token)
        let account = try await user
        let usage = try await stats
        guard usage.totalRequests != nil || usage.totalTokens != nil || usage.todayRequests != nil else {
            throw ProviderError.decoding("概览统计缺少用量字段")
        }
        return UsageOverview(
            availableBalance: account.balance, balance: account.balance, frozenBalance: account.frozenBalance,
            usedBalance: nil, totalUncoveredAmount: nil,
            requestCount: usage.totalRequests ?? 0, todayRequests: usage.todayRequests ?? 0,
            totalTokens: usage.totalTokens ?? 0, inputTokens: usage.totalInputTokens ?? 0,
            outputTokens: usage.totalOutputTokens ?? 0, cacheReadTokens: usage.totalCacheReadTokens ?? 0,
            cacheWriteTokens: usage.totalCacheCreationTokens, reasoningTokens: 0,
            cost: usage.totalActualCost, todayCost: usage.todayActualCost,
            averageFirstTokenTimeMs: nil, averageResponseTimeMs: usage.averageDurationMs,
            apiKeyCount: usage.totalApiKeys ?? 0, updatedAt: Date(), cacheReadIncludedInInput: false
        )
    }

    func fetchTrend(session: AuthSession, days: Int) async throws -> [UsageBucket] {
        guard days > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: 1 - days, to: end)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let result: GatewayTrend = try await request(
            path: "/usage/dashboard/trend", token: session.token,
            query: [URLQueryItem(name: "start_date", value: formatter.string(from: start)),
                    URLQueryItem(name: "end_date", value: formatter.string(from: end)),
                    URLQueryItem(name: "granularity", value: "day")]
        )
        return result.trend.compactMap { item in
            guard let date = formatter.date(from: item.date) else { return nil }
            let input = item.inputTokens ?? 0
            let output = item.outputTokens ?? 0
            let read = item.cacheReadTokens ?? 0
            let write = item.cacheCreationTokens ?? 0
            return UsageBucket(id: item.date, date: date, requestCount: item.requests ?? 0,
                               inputTokens: input, outputTokens: output,
                               totalTokens: item.totalTokens ?? (input + output + read + write),
                               cacheReadTokens: read, cacheWriteTokens: item.cacheCreationTokens,
                               cost: item.actualCost)
        }
    }

    func fetchRecentUsage(session: AuthSession, query: UsageQuery) async throws -> UsagePage {
        let result: GatewayUsagePage = try await request(
            path: "/usage", token: session.token,
            query: [URLQueryItem(name: "page", value: String(query.page)),
                    URLQueryItem(name: "page_size", value: String(query.pageSize)),
                    URLQueryItem(name: "sort_by", value: "created_at"),
                    URLQueryItem(name: "sort_order", value: "desc")]
        )
        let records = result.items.map { item in
            let status: String
            if let code = item.statusCode { status = (200..<300).contains(code) ? "成功" : "失败" }
            else if item.inputTokens == nil && item.outputTokens == nil { status = "处理中" }
            else { status = "成功" }
            return UsageRecord(
                id: item.id.description, requestId: item.requestId,
                requestTime: item.createdAt.flatMap(Self.date), modelName: item.model ?? "未知模型",
                inputTokens: item.inputTokens ?? 0, outputTokens: item.outputTokens ?? 0,
                cacheReadTokens: item.cacheReadTokens ?? 0, cacheWriteTokens: item.cacheCreationTokens,
                reasoningTokens: item.reasoningTokens ?? 0, cost: item.actualCost ?? item.totalCost,
                status: status, errorMessage: item.errorMessage,
                keyName: item.apiKey?.name ?? item.keyName, relayMode: item.inboundEndpoint,
                reasoningEffort: item.reasoningEffort, groupName: item.group?.name ?? item.groupName,
                isStream: item.stream, durationMs: item.durationMs,
                timeToFirstTokenMs: item.firstTokenMs, upstreamFirstEventMs: nil,
                cacheReadIncludedInInput: false
            )
        }
        return UsagePage(records: records, total: result.total)
    }

    private static func date(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private func request<T: Decodable>(path: String, method: String = "GET", token: String?,
                                       query: [URLQueryItem] = [], body: Encodable? = nil) async throws -> T {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidURL
        }
        components.path = "/api/v1" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ProviderError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpBody = try encoder.encode(GatewayAnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.server("没有收到有效响应") }
        if http.statusCode == 401 { throw ProviderError.unauthenticated }
        if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true {
            throw ProviderError.server("站点返回网页而非接口数据，请确认所选 CBC 接口版本")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(GatewayFailure.self, from: data))?.message
            throw ProviderError.server(message ?? "服务器返回 HTTP \(http.statusCode)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let envelope = try decoder.decode(GatewayEnvelope<T>.self, from: data)
            guard envelope.code == 0 else { throw ProviderError.server(envelope.message ?? "服务器返回错误 \(envelope.code)") }
            guard let payload = envelope.data else { throw ProviderError.decoding("接口未返回数据") }
            return payload
        } catch let error as ProviderError { throw error }
        catch { throw ProviderError.decoding(error.localizedDescription) }
    }
}

private struct GatewayAnyEncodable: Encodable {
    let encodeValue: (Encoder) throws -> Void
    init(_ value: Encodable) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}
private struct GatewayEnvelope<T: Decodable>: Decodable { let code: Int; let message: String?; let data: T? }
private struct GatewayFailure: Decodable { let message: String? }
private struct GatewayLoginBody: Encodable { let email: String; let password: String }
private struct GatewayRefreshBody: Encodable { let refreshToken: String }
private struct GatewayLogin: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let requires2Fa: Bool?
}
private struct GatewayUser: Decodable { let balance: Decimal?; let frozenBalance: Decimal? }
private struct GatewayStats: Decodable {
    let totalRequests: Int?
    let todayRequests: Int?
    let totalTokens: Int?
    let totalInputTokens: Int?
    let totalOutputTokens: Int?
    let totalCacheReadTokens: Int?
    let totalCacheCreationTokens: Int?
    let totalActualCost: Decimal?
    let todayActualCost: Decimal?
    let averageDurationMs: Double?
    let totalApiKeys: Int?
}
private struct GatewayTrend: Decodable { let trend: [GatewayTrendItem] }
private struct GatewayTrendItem: Decodable {
    let date: String
    let requests: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let totalTokens: Int?
    let actualCost: Decimal?
}
private struct GatewayUsagePage: Decodable { let items: [GatewayUsageItem]; let total: Int }
private struct GatewayUsageItem: Decodable {
    let id: GatewayID
    let requestId: String?
    let createdAt: String?
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let reasoningTokens: Int?
    let actualCost: Decimal?
    let totalCost: Decimal?
    let statusCode: Int?
    let errorMessage: String?
    let apiKey: GatewayAPIKey?
    let keyName: String?
    let inboundEndpoint: String?
    let reasoningEffort: String?
    let groupName: String?
    let group: GatewayGroup?
    let stream: Bool?
    let durationMs: Int?
    let firstTokenMs: Int?
}
private struct GatewayAPIKey: Decodable { let name: String? }
private struct GatewayGroup: Decodable { let name: String? }
private enum GatewayID: Decodable, CustomStringConvertible {
    case number(Int), string(String)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let id = try? value.decode(Int.self) { self = .number(id) }
        else { self = .string(try value.decode(String.self)) }
    }
    var description: String {
        switch self { case .number(let value): String(value); case .string(let value): value }
    }
}
