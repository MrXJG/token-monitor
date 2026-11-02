import Foundation

@main
@MainActor
enum RefreshFixtureCheck {
    static func main() async throws {
        for value in [5.0, 7, 10, 30, 60, 300, 86_400] {
            try check(RefreshPolicy.isValid(value), "valid interval \(value)")
        }
        for value in [0.0, 4, -10, 7.5, 86_401, .nan, .infinity] {
            try check(!RefreshPolicy.isValid(value), "invalid interval \(value)")
        }
        try check(RefreshPolicy.parse(" 7 ") == 7, "custom input")
        for value in ["", "abc", "4", "7.5", "999999999999999999999999999"] {
            try check(RefreshPolicy.parse(value) == nil, "invalid input \(value)")
        }

        let now = Date(timeIntervalSince1970: 1_000)
        var backoff = RefreshBackoff()
        try check(backoff.register(retryAfter: nil, interval: 5, now: now) == 15, "minimum backoff")
        try check(backoff.register(retryAfter: nil, interval: 5, now: now) == 30, "repeated limit")
        try check(backoff.remaining(now: now.addingTimeInterval(10)) == 20, "cooldown remaining")
        for _ in 0..<10 { _ = backoff.register(retryAfter: nil, interval: 5, now: now) }
        try check(backoff.remaining(now: now) == 900, "fallback cap")
        try check(backoff.register(retryAfter: 3_600, interval: 5, now: now) == 3_600, "server delay preserved")
        backoff.reset()
        try check(backoff.remaining(now: now) == 0, "reset cooldown")
        try check(backoff.register(retryAfter: .nan, interval: 5, now: now) == 15, "invalid server delay")

        let url = URL(string: "https://fixture.example.test")!
        for (header, expected) in [("90", 90.0), ("0", 0), ("Thu, 01 Jan 1970 00:18:40 GMT", 120)] {
            let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": header])!
            try check(response.retryAfterSeconds(now: now) == expected, "Retry-After \(header)")
        }
        for header in ["invalid", "-5", "nan", "infinity"] {
            let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": header])!
            try check(response.retryAfterSeconds(now: now) == nil, "invalid Retry-After")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitFixtureProtocol.self]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        let providers: [any UsageProvider] = [CBCProvider(session: network), CBCGatewayProvider(session: network), ZhiyaoProvider(session: network)]
        let session = AuthSession(token: "fixture", expiresAt: nil, method: .password)
        for provider in providers {
            do {
                _ = try await provider.fetchRecentUsage(session: session, query: UsageQuery())
                throw CheckFailure.failed("429 not recognized by \(provider.manifest.id)")
            } catch ProviderError.rateLimited(let delay) {
                try check(delay == 90, "429 Retry-After \(provider.manifest.id)")
            }
        }
        RateLimitFixtureProtocol.status = 200
        for provider in providers.prefix(2) {
            do {
                _ = try await provider.fetchRecentUsage(session: session, query: UsageQuery())
                throw CheckFailure.failed("business limit not recognized")
            } catch ProviderError.rateLimited {}
        }

        let suite = "TokenMonitor.RefreshFixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(loadSavedCredentials: false, defaults: defaults)
        store.updateRefreshSeconds(7)
        let restored = MonitorStore(loadSavedCredentials: false, defaults: defaults)
        try check(restored.refreshSeconds == 7, "custom interval persists")
        store.updateRefreshSeconds(4)
        try check(store.refreshSeconds == 7 && defaults.double(forKey: "refreshSeconds") == 7, "invalid setting preserves value")
        for value in [10.0, 30, 60, 300] {
            defaults.set(value, forKey: "refreshSeconds")
            try check(MonitorStore(loadSavedCredentials: false, defaults: defaults).refreshSeconds == value, "preset restoration")
        }
        defaults.set(1, forKey: "refreshSeconds")
        try check(MonitorStore(loadSavedCredentials: false, defaults: defaults).refreshSeconds == 60, "invalid saved value falls back")

        let probe = RefreshProbe()
        let monitored = MonitorStore(provider: probe, loadSavedCredentials: false, defaults: defaults)
        monitored.session = session
        let first = Task { await monitored.refresh() }
        while !monitored.isRefreshing { await Task.yield() }
        await monitored.refresh()
        monitored.updateRefreshSeconds(10)
        await first.value
        let calls = await probe.calls
        try check(calls == 1 && monitored.lastUpdated != nil, "overlap prevention and interval change preserves in-flight request")
        let updated = monitored.lastUpdated
        await probe.limitNextRequest()
        await monitored.refresh()
        let limitedCalls = await probe.calls
        await monitored.refresh()
        let blockedCalls = await probe.calls
        try check(limitedCalls == 2 && blockedCalls == 2, "cooldown blocks repeated request")
        try check(monitored.lastUpdated == updated && monitored.overview != nil, "limit preserves last successful data")

        let scheduledProbe = RefreshProbe(delay: .milliseconds(200))
        let scheduled = MonitorStore(provider: scheduledProbe, loadSavedCredentials: false, defaults: defaults)
        scheduled.session = session
        scheduled.updateRefreshSeconds(5)
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        while !scheduled.isRefreshing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(scheduled.isRefreshing, "5-second timer fires")
        scheduled.updateRefreshSeconds(7)
        while scheduled.isRefreshing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(scheduled.lastUpdated != nil, "timer replacement does not cancel scheduled request")
        print("refresh fixtures passed: input, persistence, Retry-After, all providers, backoff, overlap and in-flight interval changes")
    }

    private static func check(_ condition: Bool, _ label: String) throws {
        if !condition { throw CheckFailure.failed(label) }
    }
}

private enum CheckFailure: Error { case failed(String) }

private final class RateLimitFixtureProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 429
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Retry-After": "90", "Content-Type": Self.status == 429 ? "text/html" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":429,"msg":"rate limit","message":"rate limit"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor RefreshProbe: UsageProvider {
    nonisolated let manifest = ProviderManifest(id: "fixture", name: "Fixture", capabilities: [.balance], supportedAuthMethods: [.password])
    private(set) var calls = 0
    private var limited = false
    private let delay: Duration
    init(delay: Duration = .milliseconds(30)) { self.delay = delay }
    func limitNextRequest() { limited = true }
    func authenticate(_ method: AuthMethod, secret: String, username: String?) async throws -> AuthSession { throw ProviderError.unsupported("fixture") }
    func fetchOverview(session: AuthSession) async throws -> UsageOverview {
        calls += 1
        try await Task.sleep(for: delay)
        if limited { throw ProviderError.rateLimited(retryAfter: 90) }
        return UsageOverview(availableBalance: 42, balance: nil, frozenBalance: nil, usedBalance: nil,
                             totalUncoveredAmount: nil, requestCount: 0, todayRequests: 0, totalTokens: 0,
                             inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: nil,
                             reasoningTokens: 0, cost: nil, todayCost: nil, averageFirstTokenTimeMs: nil,
                             averageResponseTimeMs: nil, apiKeyCount: 0, updatedAt: Date())
    }
    func fetchTrend(session: AuthSession, days: Int) async throws -> [UsageBucket] { [] }
    func fetchRecentUsage(session: AuthSession, query: UsageQuery) async throws -> UsagePage { UsagePage(records: [], total: 0) }
}
