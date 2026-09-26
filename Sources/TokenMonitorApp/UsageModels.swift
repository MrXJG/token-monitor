import Foundation

struct ProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let balance = Self(rawValue: 1 << 0)
    static let usageTrend = Self(rawValue: 1 << 1)
    static let requestDetails = Self(rawValue: 1 << 2)
    static let cacheUsage = Self(rawValue: 1 << 3)
    static let modelBreakdown = Self(rawValue: 1 << 4)
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

struct UsageQuery: Sendable {
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

enum ProviderError: LocalizedError, Sendable {
    case invalidURL
    case unauthenticated
    case server(String)
    case decoding(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务地址无效"
        case .unauthenticated: return "认证已失效，请重新登录"
        case .server(let message): return message
        case .decoding(let message): return "接口数据格式异常：\(message)"
        case .unsupported(let message): return message
        }
    }
}

protocol UsageProvider: Sendable {
    var manifest: ProviderManifest { get }
    func capabilities(for session: AuthSession) -> ProviderCapabilities
    func authenticate(_ method: AuthMethod, secret: String, username: String?) async throws -> AuthSession
    func fetchOverview(session: AuthSession) async throws -> UsageOverview
    func fetchTrend(session: AuthSession, days: Int) async throws -> [UsageBucket]
    func fetchRecentUsage(session: AuthSession, query: UsageQuery) async throws -> UsagePage
}

extension UsageProvider {
    func capabilities(for session: AuthSession) -> ProviderCapabilities { manifest.capabilities }
}
