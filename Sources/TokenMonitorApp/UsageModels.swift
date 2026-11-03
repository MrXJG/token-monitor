import Foundation

struct ProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let balance = Self(rawValue: 1 << 0)
    static let usageTrend = Self(rawValue: 1 << 1)
    static let requestDetails = Self(rawValue: 1 << 2)
    static let cacheUsage = Self(rawValue: 1 << 3)
    static let modelBreakdown = Self(rawValue: 1 << 4)
    static let groupRates = Self(rawValue: 1 << 5)
}

enum AuthMethod: String, CaseIterable, Identifiable, Sendable {
    case apiKey
    case password
    var id: String { rawValue }
    var title: String { self == .apiKey ? "API Key" : "账号密码" }
}

enum MenuBarDisplay: String, CaseIterable, Identifiable, Sendable {
    case balance, summary, todayTokens, inputTokens, outputTokens, cacheHitRate, requests, todayCost
    var id: String { rawValue }
    var title: String {
        switch self {
        case .balance: "余额"
        case .summary: "余额与用量"
        case .todayTokens: "今日 Token"
        case .inputTokens: "今日输入"
        case .outputTokens: "今日输出"
        case .cacheHitRate: "缓存命中率"
        case .requests: "今日请求"
        case .todayCost: "今日费用"
        }
    }
}

struct ProviderManifest: Sendable {
    let id: String
    let name: String
    let capabilities: ProviderCapabilities
    let supportedAuthMethods: [AuthMethod]
}

struct AuthSession: Sendable {
    let token: String
    let expiresAt: Date?
    var method: AuthMethod = .apiKey
    var refreshToken: String? = nil
}

struct UsageOverview: Sendable {
    var availableBalance: Decimal?
    var balance: Decimal?
    var frozenBalance: Decimal?
    var usedBalance: Decimal?
    var totalUncoveredAmount: Decimal?
    var requestCount: Int
    var todayRequests: Int
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int?
    var reasoningTokens: Int
    var cost: Decimal?
    var todayCost: Decimal?
    var averageFirstTokenTimeMs: Double?
    var averageResponseTimeMs: Double?
    var apiKeyCount: Int
    var updatedAt: Date
    var cacheReadIncludedInInput = true
    var billingAccountID: String? = nil

    var calculatedTokens: Int {
        inputTokens + outputTokens + (cacheReadIncludedInInput ? 0 : cacheReadTokens + (cacheWriteTokens ?? 0))
    }
    var cacheHitRate: Double? {
        let totalInput = inputTokens + (cacheReadIncludedInInput ? 0 : cacheReadTokens + (cacheWriteTokens ?? 0))
        guard totalInput > 0 else { return nil }
        return Double(cacheReadTokens) / Double(totalInput)
    }
}

struct ModelUsage: Identifiable, Sendable {
    let id: String
    let modelName: String
    let requestCount: Int
    let totalTokens: Int
    let cacheReadTokens: Int
    let cost: Decimal
}

struct UsageBucket: Identifiable, Sendable {
    let id: String
    let date: Date
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int?
    let cost: Decimal?
}

struct UsageQuery: Sendable, Hashable {
    var page: Int = 1
    var pageSize: Int = 20
    var modelName: String?
    var status: String?
}

struct UsageRecord: Identifiable, Sendable {
    let id: String
    let requestId: String?
    let requestTime: Date?
    let modelName: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int?
    let reasoningTokens: Int
    let cost: Decimal?
    let status: String
    let errorMessage: String?
    let keyName: String?
    let relayMode: String?
    let reasoningEffort: String?
    let groupName: String?
    let isStream: Bool?
    let durationMs: Int?
    let timeToFirstTokenMs: Int?
    let upstreamFirstEventMs: Int?
    var cacheReadIncludedInInput = true
    var groupID: String? = nil
    var groupMultiplier: Decimal? = nil

    var totalTokens: Int {
        inputTokens + outputTokens + (cacheReadIncludedInInput ? 0 : cacheReadTokens + (cacheWriteTokens ?? 0))
    }
    var cacheHitRate: Double? {
        let totalInput = inputTokens + (cacheReadIncludedInInput ? 0 : cacheReadTokens + (cacheWriteTokens ?? 0))
        guard totalInput > 0 else { return nil }
        return Double(cacheReadTokens) / Double(totalInput)
    }
}

struct UsagePage: Sendable {
    let records: [UsageRecord]
    let total: Int
}

struct GroupRate: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let multiplier: Decimal
    var usesAccountRate = false
    var peakDescription: String? = nil
    var displayMultiplier: String { Self.format(multiplier) }
    static func format(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue + "×"
    }
}

enum ProviderError: LocalizedError, Sendable {
    case invalidURL
    case unauthenticated
    case rateLimited(retryAfter: TimeInterval?)
    case server(String)
    case decoding(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务地址无效"
        case .unauthenticated: return "认证已失效，请重新登录"
        case .rateLimited: return "请求过于频繁，请稍后重试"
        case .server(let message): return message
        case .decoding(let message): return "接口数据格式异常：\(message)"
        case .unsupported(let message): return message
        }
    }
}

extension HTTPURLResponse {
    func retryAfterSeconds(now: Date = Date()) -> TimeInterval? {
        guard let value = value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

protocol UsageProvider: Sendable {
    var manifest: ProviderManifest { get }
    func capabilities(for session: AuthSession) -> ProviderCapabilities
    func authenticate(_ method: AuthMethod, secret: String, username: String?) async throws -> AuthSession
    func renewSession(_ session: AuthSession) async throws -> AuthSession
    func fetchOverview(session: AuthSession) async throws -> UsageOverview
    func fetchTrend(session: AuthSession, days: Int) async throws -> [UsageBucket]
    func fetchTrend(session: AuthSession, days: Int, fetchPage: @Sendable (UsageQuery) async throws -> UsagePage) async throws -> [UsageBucket]
    func fetchRecentUsage(session: AuthSession, query: UsageQuery) async throws -> UsagePage
    func fetchGroupRates(session: AuthSession) async throws -> [GroupRate]
}

extension UsageProvider {
    func fetchTrend(session: AuthSession, days: Int, fetchPage: @Sendable (UsageQuery) async throws -> UsagePage) async throws -> [UsageBucket] {
        try await fetchTrend(session: session, days: days)
    }
    func capabilities(for session: AuthSession) -> ProviderCapabilities { manifest.capabilities }
    func renewSession(_ session: AuthSession) async throws -> AuthSession { throw ProviderError.unauthenticated }
    func fetchGroupRates(session: AuthSession) async throws -> [GroupRate] { [] }
}

// Each refresh owns one batch. Concurrent consumers share both in-flight and completed pages.
actor UsageRecordBatch {
    private let provider: any UsageProvider
    private let session: AuthSession
    private var pages: [UsageQuery: Task<UsagePage, Error>] = [:]

    init(provider: any UsageProvider, session: AuthSession) {
        self.provider = provider
        self.session = session
    }

    func fetch(_ query: UsageQuery) async throws -> UsagePage {
        if let page = pages[query] { return try await page.value }
        let task = Task { try await provider.fetchRecentUsage(session: session, query: query) }
        pages[query] = task
        return try await task.value
    }
}


enum ErrorRecovery {
    static func hint(for error: Error) -> String {
        switch error {
        case ProviderError.invalidURL: "请在连接设置中检查服务地址。"
        case ProviderError.unauthenticated: "请打开连接设置，重新登录。"
        case ProviderError.rateLimited: "等待自动重试，无需连续点击刷新。"
        case ProviderError.decoding: "请检查站点类型和服务地址；网站升级后接口可能变化。"
        case let network as URLError:
            network.code == .timedOut ? "请求超时，可稍后重试。" : "请检查网络连接，稍后重试。"
        default: "可稍后重试；持续失败时请检查站点是否可用。"
        }
    }
}
