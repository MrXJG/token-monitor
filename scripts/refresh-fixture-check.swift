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
        let credentialDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMonitor-CredentialFixture-\(UUID().uuidString)", isDirectory: true)
        let credentialVault = CredentialVault(service: "fixture", directory: credentialDirectory)
        defer { try? FileManager.default.removeItem(at: credentialDirectory) }
        try await credentialVault.saveLogin(
            sessionToken: "session-fixture",
            sessionAccount: "cbc-runok.session",
            apiKey: nil,
            apiKeyAccount: "cbc-runok.apiKey",
            username: "fixture-user",
            usernameAccount: "cbc-runok.username",
            password: "fixture-password",
            passwordAccount: "cbc-runok.password",
            refreshToken: nil,
            refreshAccount: "cbc-runok.refresh"
        )
        try check(try await credentialVault.read(account: "cbc-runok.username") == "fixture-user",
                  "password login username persists in encrypted vault")
        try check(try await credentialVault.read(account: "cbc-runok.password") == "fixture-password",
                  "password login secret persists in encrypted vault")
        await credentialVault.delete(sessionAccount: "cbc-runok.session", apiKeyAccount: "cbc-runok.apiKey",
                                     usernameAccount: "cbc-runok.username", passwordAccount: "cbc-runok.password",
                                     refreshAccount: "cbc-runok.refresh")
        try check(try await credentialVault.read(account: "cbc-runok.password") == nil,
                  "logout removes password login credentials")
        let store = MonitorStore(loadSavedCredentials: false, defaults: defaults)
        defaults.set("apiKey", forKey: "authMethod.cbc-runok")
        try check(MonitorStore(loadSavedCredentials: false, defaults: defaults).authMethod == .password,
                  "retired runok API Key preference switches to supported password login")
        let aliasSuite = "TokenMonitor.AliasFixture.\(UUID().uuidString)"
        let aliasDefaults = UserDefaults(suiteName: aliasSuite)!
        defer { aliasDefaults.removePersistentDomain(forName: aliasSuite) }
        aliasDefaults.set("zhiyao", forKey: "providerID")
        aliasDefaults.set("https://zhiyaoapi.top", forKey: "siteAddress.zhiyao")
        let aliasStore = MonitorStore(loadSavedCredentials: false, defaults: aliasDefaults)
        try check(aliasStore.displaySiteAlias == "知遥 API", "provider name is default site alias")
        aliasStore.updateSiteAlias("知遥主站")
        let restoredAlias = MonitorStore(loadSavedCredentials: false, defaults: aliasDefaults)
        try check(restoredAlias.displaySiteAlias == "知遥主站", "site alias persists by provider host")
        let sitesSuite = "TokenMonitor.SiteFixture.\(UUID().uuidString)"
        let sitesDefaults = UserDefaults(suiteName: sitesSuite)!
        defer { sitesDefaults.removePersistentDomain(forName: sitesSuite) }
        let staleProfile = SiteProfile(id: "stale", providerID: "cbc", alias: "CBC 旧版", address: "https://cbc.icu", isBuiltIn: false)
        sitesDefaults.set(try! JSONEncoder().encode([staleProfile]), forKey: "customSiteProfiles")
        let sitesStore = MonitorStore(loadSavedCredentials: false, defaults: sitesDefaults)
        try check(sitesStore.siteProfiles.map(\.providerID) == ["cbc-runok", "zhiyao"], "site catalog only exposes retained providers")
        try check(sitesStore.siteProfiles.allSatisfy { !$0.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "built-in aliases are never empty")
        try check(!sitesStore.siteProfiles.contains(where: { $0.alias == "CBC 旧版" }), "stale custom site is migrated out once")
        let builtinCBCNew = sitesStore.siteProfiles.first(where: { $0.providerID == "cbc-runok" })!
        sitesStore.hideSiteProfile(builtinCBCNew)
        try check(!sitesStore.siteProfiles.contains(where: { $0.providerID == "cbc-runok" }) && sitesStore.hiddenSiteProfiles.contains(where: { $0.providerID == "cbc-runok" }), "built-in site can be hidden")
        let hiddenBuiltinRestored = MonitorStore(loadSavedCredentials: false, defaults: sitesDefaults)
        try check(hiddenBuiltinRestored.hiddenSiteProfiles.contains(where: { $0.providerID == "cbc-runok" }), "hidden built-in persists across restart")
        sitesStore.restoreSiteProfile(builtinCBCNew)
        try check(sitesStore.siteProfiles.contains(where: { $0.providerID == "cbc-runok" }), "built-in site can be restored")
        sitesStore.beginAddingSite()
        sitesStore.updateSiteAddress("https://relay.example.test")
        sitesStore.updateSiteAlias("测试中转")
        sitesStore.addCurrentSiteProfile()
        try check(sitesStore.siteProfiles.contains(where: { $0.alias == "测试中转" && !$0.isBuiltIn }), "custom site profile is added")
        guard let testProfile = sitesStore.customSiteProfiles.first(where: { $0.alias == "测试中转" }) else {
            throw CheckFailure.failed("custom site profile can be looked up for hiding")
        }
        sitesStore.hideSiteProfile(testProfile)
        try check(!sitesStore.siteProfiles.contains(where: { $0.alias == "测试中转" }) && sitesStore.hiddenSiteProfiles.contains(where: { $0.alias == "测试中转" }), "custom site profile is hidden")
        let hiddenRestored = MonitorStore(loadSavedCredentials: false, defaults: sitesDefaults)
        try check(hiddenRestored.hiddenSiteProfiles.contains(where: { $0.alias == "测试中转" }), "hidden site state persists across restart")
        sitesStore.restoreSiteProfile(testProfile)
        try check(sitesStore.siteProfiles.contains(where: { $0.alias == "测试中转" }), "custom site profile is restored")
        let afterMigration = MonitorStore(loadSavedCredentials: false, defaults: sitesDefaults)
        try check(afterMigration.siteProfiles.contains(where: { $0.alias == "测试中转" }), "new custom site survives after migration")
        let staleAfterMigrationSuite = "TokenMonitor.StaleSiteFixture.\(UUID().uuidString)"
        let staleAfterMigrationDefaults = UserDefaults(suiteName: staleAfterMigrationSuite)!
        defer { staleAfterMigrationDefaults.removePersistentDomain(forName: staleAfterMigrationSuite) }
        staleAfterMigrationDefaults.set(1, forKey: "siteProfilesMigrationVersion")
        staleAfterMigrationDefaults.set(try! JSONEncoder().encode([staleProfile]), forKey: "customSiteProfiles")
        let staleAfterMigration = MonitorStore(loadSavedCredentials: false, defaults: staleAfterMigrationDefaults)
        try check(staleAfterMigration.siteProfiles.map(\.providerID) == ["cbc-runok", "zhiyao"], "stale profiles are filtered even after an earlier migration")
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
        let switchingProbe = RefreshProbe(delay: .milliseconds(200))
        let switchingStore = MonitorStore(provider: switchingProbe, loadSavedCredentials: false, defaults: defaults)
        switchingStore.session = session
        let switchingRefresh = Task { await switchingStore.refresh() }
        while !switchingStore.isRefreshing { await Task.yield() }
        guard let zhiyaoProfile = switchingStore.siteProfiles.first(where: { $0.providerID == "zhiyao" }) else {
            throw CheckFailure.failed("zhiyao built-in profile is available")
        }
        switchingStore.selectSiteProfile(zhiyaoProfile)
        try check(switchingStore.providerID == "zhiyao" && switchingStore.siteAddress == "https://zhiyaoapi.top",
                  "site switch is accepted while previous refresh is in flight")
        await switchingRefresh.value
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
        scheduled.setPanelVisible(true)
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
        let pages = RecordPagesProbe()
        let pagingStore = MonitorStore(provider: pages, loadSavedCredentials: false, defaults: defaults)
        pagingStore.session = session
        await pagingStore.refresh()
        try check(pagingStore.recentRecords.count == 20 && pagingStore.recentRecordsTotal == 45, "first page and total")
        await pagingStore.loadMoreRecentRecords()
        try check(pagingStore.recentRecords.count == 40, "second page appended")
        await pagingStore.refresh()
        try check(pagingStore.recentRecords.count == 40, "refresh retains loaded page window")
        await pagingStore.loadMoreRecentRecords()
        try check(pagingStore.recentRecords.count == 45 && !pagingStore.canLoadMoreRecords, "last page and exhausted state")
        let previousRecordsDate = pagingStore.recordsUpdated
        await pages.setFailure(records: true, summary: false)
        await pagingStore.refresh()
        try check(pagingStore.recordsUpdated == previousRecordsDate && pagingStore.recentRecords.count == 45, "record failure preserves data and timestamp")
        try check(pagingStore.overviewError == nil && pagingStore.recordsError != nil && pagingStore.overviewUpdated != nil, "independent section results")
        await pages.setFailure(records: false, summary: true)
        await pagingStore.refresh()
        try check(pagingStore.recordsError == nil && pagingStore.overviewError != nil && pagingStore.recordsUpdated != previousRecordsDate, "record success publishes despite overview failure")
        await pages.setFailure(records: false, summary: false)
        await pagingStore.refresh()
        try check(pagingStore.lastError == nil && pagingStore.overviewError == nil && pagingStore.recordsError == nil, "partial failure recovers")
        defaults.set(false, forKey: "rateNotificationsEnabled")
        let ratesProbe = GroupRatesProbe()
        let ratesStore = MonitorStore(provider: ratesProbe, loadSavedCredentials: false, defaults: defaults)
        ratesStore.session = session
        await ratesStore.refresh()
        try check(ratesStore.currentGroupRate?.name == "ultra" && ratesStore.rateChanges.isEmpty, "latest group and initial baseline")
        await ratesProbe.setRate(Decimal(string: "0.25")!)
        await ratesStore.refresh()
        try check(ratesStore.hasUnreadRateChange && ratesStore.rateChanges.count == 1, "rate change visible even when system notifications disabled")
        await ratesStore.refresh()
        try check(ratesStore.rateChanges.count == 1, "unchanged refresh does not duplicate alert")
        let previousRateDate = ratesStore.groupRatesUpdated
        await ratesProbe.setFailure(true)
        await ratesStore.refresh()
        try check(ratesStore.groupRatesError != nil && ratesStore.groupRatesUpdated == previousRateDate && ratesStore.currentGroupRate?.multiplier == Decimal(string: "0.25"), "rate failure retains known value and timestamp")
        try check(ratesStore.overviewError == nil && ratesStore.recordsError == nil, "rate failure does not discard other sections")
        await ratesProbe.setFailure(false)
        await ratesStore.refresh()
        try check(ratesStore.groupRatesError == nil && ratesStore.lastError == nil, "rate recovery")
        ratesStore.acknowledgeRateChanges()
        let restoredRates = MonitorStore(provider: ratesProbe, loadSavedCredentials: false, defaults: defaults)
        restoredRates.session = session
        await restoredRates.refresh()
        try check(!restoredRates.hasUnreadRateChange && restoredRates.rateChanges.count == 1, "acknowledgement and history survive restart")
        await ratesProbe.changeAccount()
        await restoredRates.refresh()
        try check(restoredRates.rateChanges.isEmpty && !restoredRates.hasUnreadRateChange, "different account gets independent baseline")
        print("refresh fixtures passed: input, persistence, Retry-After, all providers, backoff, overlap, in-flight interval changes, pagination, partial failure recovery and rate alerts")
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

private actor RecordPagesProbe: UsageProvider {
    nonisolated let manifest = ProviderManifest(id: "page-fixture", name: "Fixture", capabilities: [.balance], supportedAuthMethods: [.password])
    private var failRecords = false
    private var failSummary = false
    func setFailure(records: Bool, summary: Bool) { failRecords = records; failSummary = summary }
    func authenticate(_ method: AuthMethod, secret: String, username: String?) async throws -> AuthSession { throw ProviderError.unsupported("fixture") }
    func fetchOverview(session: AuthSession) async throws -> UsageOverview {
        if failSummary { throw ProviderError.server("overview unavailable") }
        return try await RefreshProbe().fetchOverview(session: session)
    }
    func fetchTrend(session: AuthSession, days: Int) async throws -> [UsageBucket] { [] }
    func fetchRecentUsage(session: AuthSession, query: UsageQuery) async throws -> UsagePage {
        if failRecords { throw ProviderError.server("records unavailable") }
        let start = (query.page - 1) * query.pageSize
        let records = (start..<min(start + query.pageSize, 45)).map { i in
            UsageRecord(id: String(i), requestId: nil, requestTime: Date().addingTimeInterval(-Double(i * 60)), modelName: "fixture",
                        inputTokens: 10, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: nil, reasoningTokens: 0,
                        cost: nil, status: "成功", errorMessage: nil, keyName: nil, relayMode: nil, reasoningEffort: nil,
                        groupName: nil, isStream: nil, durationMs: nil, timeToFirstTokenMs: nil, upstreamFirstEventMs: nil)
        }
        return UsagePage(records: records, total: 45)
    }
}

private actor GroupRatesProbe: UsageProvider {
    nonisolated let manifest = ProviderManifest(id: "rates-fixture", name: "Fixture", capabilities: [.balance, .groupRates], supportedAuthMethods: [.password])
    private var rate = Decimal(string: "0.2")!
    private var fail = false
    private var account = "first-account"
    func setRate(_ value: Decimal) { rate = value }
    func setFailure(_ value: Bool) { fail = value }
    func changeAccount() { account = "second-account"; rate = 1 }
    func authenticate(_ method: AuthMethod, secret: String, username: String?) async throws -> AuthSession { throw ProviderError.unsupported("fixture") }
    func fetchOverview(session: AuthSession) async throws -> UsageOverview {
        var overview = try await RefreshProbe().fetchOverview(session: session)
        overview.billingAccountID = account
        return overview
    }
    func fetchTrend(session: AuthSession, days: Int) async throws -> [UsageBucket] { [] }
    func fetchGroupRates(session: AuthSession) async throws -> [GroupRate] {
        if fail { throw ProviderError.server("rates unavailable") }
        return [GroupRate(id: "7", name: "ultra", multiplier: rate)]
    }
    func fetchRecentUsage(session: AuthSession, query: UsageQuery) async throws -> UsagePage {
        var record = try await RecordPagesProbe().fetchRecentUsage(session: session, query: UsageQuery(pageSize: 1)).records[0]
        record.groupID = "7"
        return UsagePage(records: [record], total: 1)
    }
}
