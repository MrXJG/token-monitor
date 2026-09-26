import Foundation

struct ZhiyaoProvider: UsageProvider {
    let baseURL: URL
    let session: URLSession

    var manifest: ProviderManifest {
        ProviderManifest(
            id: baseURL.absoluteString == "https://zyapi.tuluo.top:8888" ? "zhiyao" : "zhiyao:\(baseURL.absoluteString)",
            name: baseURL.host == "zyapi.tuluo.top" ? "知遥 API" : (baseURL.host ?? "中转站"),
            capabilities: [.balance, .usageTrend, .requestDetails, .cacheUsage, .modelBreakdown],
            supportedAuthMethods: [.password, .apiKey]
        )
    }

    init(baseURL: URL = URL(string: "https://zyapi.tuluo.top:8888")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    static func endpoint(for address: String) throws -> URL {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              ["", "dashboard"].contains(components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            throw ProviderError.invalidURL
        }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.path = ""
        guard let url = components.url else { throw ProviderError.invalidURL }
        return url
    }

    func capabilities(for session: AuthSession) -> ProviderCapabilities {
        session.method == .apiKey ? [.balance] : manifest.capabilities
    }

    func authenticate(_ method: AuthMethod, secret: String, username: String?) async throws -> AuthSession {
        guard !secret.isEmpty else { throw ProviderError.unauthenticated }
        switch method {
        case .password:
            guard let username, !username.isEmpty else { throw ProviderError.unauthenticated }
            let response: LoginResponse = try await request(
                path: "/user/login", method: "POST", token: nil,
                body: LoginBody(username: username, password: secret)
            )
            guard let token = response.accessToken, !token.isEmpty else {
                throw ProviderError.decoding("登录响应缺少 access_token")
            }
            return AuthSession(token: token, expiresAt: nil, method: .password)
        case .apiKey:
            let response: KeyUsageResponse = try await request(path: "/api/cc-switch/v1/usage", token: secret)
            guard response.success, response.data.first(where: \.isValid) != nil else {
                throw ProviderError.server("API Key 无法读取余额")
            }
            return AuthSession(token: secret, expiresAt: nil, method: .apiKey)
        }
    }

    func fetchOverview(session: AuthSession) async throws -> UsageOverview {
        if session.method == .apiKey {
            let response: KeyUsageResponse = try await request(path: "/api/cc-switch/v1/usage", token: session.token)
            guard response.success, let balance = response.data.first(where: \.isValid)?.remaining else {
                throw ProviderError.decoding("API Key 余额数据为空")
            }
            return UsageOverview(
                availableBalance: balance, balance: balance, frozenBalance: nil, usedBalance: nil,
                totalUncoveredAmount: nil, requestCount: 0, todayRequests: 0, totalTokens: 0,
                inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: nil,
                reasoningTokens: 0, cost: nil, todayCost: response.keyUsage?.todayCostUsd,
                averageFirstTokenTimeMs: nil, averageResponseTimeMs: nil, apiKeyCount: 0, updatedAt: Date()
            )
        }
        let value: UserResponse = try await request(path: "/user/me", token: session.token)
        let explicitCacheRead = value.totalCacheReadInputTokens ?? 0
        let cacheWrite = value.totalCacheWriteInputTokens ?? 0
        let cacheRead = explicitCacheRead + cacheWrite > 0 ? explicitCacheRead : value.totalCachedTokens ?? 0
        return UsageOverview(
            availableBalance: value.availableBalance ?? value.fixedBalance,
            balance: value.fixedBalance, frozenBalance: value.fixedBalanceReserved,
            usedBalance: nil, totalUncoveredAmount: nil,
            requestCount: value.totalRequests, todayRequests: value.todayRequests,
            totalTokens: value.totalInputTokens + value.totalOutputTokens + cacheRead + cacheWrite,
            inputTokens: value.totalInputTokens, outputTokens: value.totalOutputTokens,
            cacheReadTokens: cacheRead, cacheWriteTokens: value.totalCacheWriteInputTokens,
            reasoningTokens: 0, cost: nil, todayCost: value.todayTotalCost,
            averageFirstTokenTimeMs: nil, averageResponseTimeMs: nil,
            apiKeyCount: value.apiKeyCount, updatedAt: Date(), cacheReadIncludedInInput: false
        )
    }

    func fetchTrend(session: AuthSession, days: Int) async throws -> [UsageBucket] {
        guard session.method == .password else { return [] }
        guard days == 7 else { throw ProviderError.unsupported("知遥 API 仅提供近 7 天费用趋势") }
        let response: SpendingResponse = try await request(
            path: "/user/spending-trend", token: session.token,
            query: [URLQueryItem(name: "range", value: "7d")]
        )
        return response.data.compactMap { item in
            guard let date = Self.date(item.time) else { return nil }
            return UsageBucket(
                id: item.time, date: date, requestCount: item.requestCount,
                inputTokens: 0, outputTokens: 0, totalTokens: 0,
                cacheReadTokens: 0, cacheWriteTokens: nil, cost: item.costUsd
            )
        }
    }

    func fetchRecentUsage(session: AuthSession, query: UsageQuery) async throws -> UsagePage {
        guard session.method == .password else { return UsagePage(records: [], total: 0) }
        let response: UsageResponse = try await request(
            path: "/user/usage-logs", token: session.token,
            query: [
                URLQueryItem(name: "skip", value: String(max(0, query.page - 1) * query.pageSize)),
                URLQueryItem(name: "limit", value: String(query.pageSize))
            ]
        )
        return UsagePage(records: response.items.map { item in
            let explicitCacheRead = item.cacheReadInputTokens ?? 0
            let cacheWrite = item.cacheWriteInputTokens ?? 0
            let cacheRead = explicitCacheRead + cacheWrite > 0 ? explicitCacheRead : item.cachedTokens ?? 0
            let status = item.normalizedStatus
            return UsageRecord(
                id: String(item.id), requestId: item.correlationId ?? String(item.id),
                requestTime: Self.date(item.requestTime), modelName: item.displayModel ?? item.model ?? "未知模型",
                inputTokens: item.inputTokens ?? 0, outputTokens: item.outputTokens ?? 0,
                cacheReadTokens: cacheRead, cacheWriteTokens: item.cacheWriteInputTokens,
                reasoningTokens: 0, cost: item.costUsd,
                status: status, errorMessage: item.errorMessage,
                keyName: item.apiKeyName, relayMode: item.endpoint, reasoningEffort: item.reasoningEffort,
                groupName: item.catalogGroup, isStream: item.isStream,
                durationMs: item.latencyMs, timeToFirstTokenMs: nil, upstreamFirstEventMs: nil,
                cacheReadIncludedInInput: false
            )
        }, total: response.total)
    }

    private static func date(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "Asia/Shanghai")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: value)
    }

    private func request<T: Decodable>(
        path: String, method: String = "GET", token: String?,
        query: [URLQueryItem] = [], body: Encodable? = nil
    ) async throws -> T {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidURL
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ProviderError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(ZhiyaoAnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.server("没有收到有效响应") }
        if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthenticated }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.detail
            throw ProviderError.server(detail ?? "服务器返回 HTTP \(http.statusCode)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(T.self, from: data) }
        catch { throw ProviderError.decoding(error.localizedDescription) }
    }
}

private struct ZhiyaoAnyEncodable: Encodable {
    let encodeValue: (Encoder) throws -> Void
    init(_ value: Encodable) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}
private struct LoginBody: Encodable { let username: String; let password: String }
private struct LoginResponse: Decodable { let accessToken: String? }
private struct ErrorResponse: Decodable { let detail: String? }
private struct UserResponse: Decodable {
    let availableBalance: Decimal?
    let fixedBalance: Decimal
    let fixedBalanceReserved: Decimal?
    let todayTotalCost: Decimal?
    let totalRequests: Int
    let todayRequests: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCachedTokens: Int?
    let totalCacheReadInputTokens: Int?
    let totalCacheWriteInputTokens: Int?
    let apiKeyCount: Int
}
private struct KeyUsageResponse: Decodable {
    let success: Bool
    let data: [KeyBalance]
    let keyUsage: KeyUsage?
}
private struct KeyBalance: Decodable { let isValid: Bool; let remaining: Decimal? }
private struct KeyUsage: Decodable { let todayCostUsd: Decimal? }
private struct SpendingResponse: Decodable { let data: [SpendingItem] }
private struct SpendingItem: Decodable {
    let time: String
    let requestCount: Int
    let costUsd: Decimal
}
private struct UsageResponse: Decodable { let items: [ZhiyaoUsageItem]; let total: Int }
private struct ZhiyaoUsageItem: Decodable {
    let id: Int
    let requestTime: String
    let correlationId: String?
    let displayModel: String?
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheWriteInputTokens: Int?
    let cachedTokens: Int?
    let costUsd: Decimal?
    let status: String?
    let statusCode: Int?
    let errorMessage: String?
    let apiKeyName: String?
    let endpoint: String?
    let reasoningEffort: String?
    let catalogGroup: String?
    let isStream: Bool?
    let latencyMs: Int?

    var normalizedStatus: String {
        let normalized = status?.lowercased()
        if statusCode == 200 || normalized == "success" || normalized == "completed" { return "成功" }
        if normalized == "pending" || normalized == "processing" || normalized == "running" || normalized == "in_progress" {
            return "处理中"
        }
        if statusCode == nil && status == nil && inputTokens == nil && outputTokens == nil { return "处理中" }
        return "失败"
    }
}
