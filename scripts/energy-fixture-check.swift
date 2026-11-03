import Foundation

@main
@MainActor
enum EnergyFixtureCheck {
    static func main() async throws {
        let suite = "TokenMonitor.EnergyFixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "rateNotificationsEnabled")
        let probe = EnergyProbe()
        let store = MonitorStore(provider: probe, loadSavedCredentials: false, defaults: defaults)
        store.session = AuthSession(token: "fixture", expiresAt: nil, method: .password)
        await store.refresh()
        let firstQueries = await probe.queries
        try check(firstQueries.filter { $0.page == 1 }.count == 1,
                  "one shared first-page request for summary, records and trend")
        try check(store.recentRecords.count == 20 && store.todayRecords.count == 45,
                  "shared 100-record page preserves 20-record UI and full daily summary")

        #if !ENERGY_BASELINE
        let firstDate = store.overviewUpdated!
        let trendDate = store.trendUpdated
        let ratesDate = store.groupRatesUpdated
        await probe.setStatus("成功")
        await store.refresh(forceDetails: false, now: firstDate.addingTimeInterval(10))
        let cachedQueries = await probe.queries
        let cachedTrends = await probe.trendCalls
        let cachedRates = await probe.rateCalls
        try check(cachedQueries.count == 2 && cachedTrends == 1 && cachedRates == 1,
                  "routine refresh fetches daily records once and reuses five-minute details")
        try check(store.trendUpdated == trendDate && store.groupRatesUpdated == ratesDate,
                  "cached sections retain their actual update timestamps")
        try check(store.overview?.inputTokens == 450 && store.recentRecords.first?.status == "成功",
                  "pending requests settle in both daily totals and visible records")

        let overviewDate = store.overviewUpdated
        let overviewCalls = await probe.overviewCalls
        await store.refresh(forceDetails: false, now: firstDate.addingTimeInterval(301), updateUsage: false)
        let expiredTrends = await probe.trendCalls
        let expiredRates = await probe.rateCalls
        let metadataOverviewCalls = await probe.overviewCalls
        try check(expiredTrends == 2 && expiredRates == 2,
                  "expired trend and group rates refresh independently")
        try check(store.overviewUpdated == overviewDate && metadataOverviewCalls == overviewCalls,
                  "metadata-only refresh does not poll or retimestamp usage")
        await store.refresh(now: firstDate.addingTimeInterval(302))
        let manualTrends = await probe.trendCalls
        try check(manualTrends == 3, "manual refresh bypasses detail cache")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: firstDate))!
        await probe.setRecordDate(tomorrow)
        await store.refresh(forceDetails: false, now: tomorrow)
        let midnightTrends = await probe.trendCalls
        try check(midnightTrends == 4 && store.todayRecords.count == 45,
                  "Shanghai midnight invalidates the previous day's trend and daily summary")
        let afterMidnightRates = await probe.rateCalls
        await store.refresh(forceDetails: false, now: tomorrow.addingTimeInterval(1))
        let warmMidnightRates = await probe.rateCalls
        try check(afterMidnightRates == warmMidnightRates, "warm cache remains effective after day rollover")

        store.logout()
        store.session = AuthSession(token: "second-fixture", expiresAt: nil, method: .password)
        await store.refresh(forceDetails: false)
        let switchedTrends = await probe.trendCalls
        try check(switchedTrends == 5, "logout and new session do not reuse the previous snapshot")

        for (requested, visible, lowPower, expected) in [
            (10.0, true, false, 10.0), (10, false, false, 60),
            (10, false, true, 300), (10, true, true, 10),
            (600, false, false, 600), (600, false, true, 600)
        ] {
            try check(RefreshPolicy.effectiveSeconds(requested, panelVisible: visible, lowPower: lowPower) == expected,
                      "visibility and low-power policy preserve requested longer intervals")
        }
        store.session = nil
        store.updateRefreshSeconds(10)
        try check(store.effectiveRefreshSeconds >= 60, "hidden panel uses background policy")
        store.setPanelVisible(true)
        try check(store.effectiveRefreshSeconds == 10, "opening panel restores saved interval")
        store.setPanelVisible(false)
        store.updatePowerState(lowPower: true, sleeping: false)
        try check(store.effectiveRefreshSeconds == 300, "low-power event changes background interval")
        store.updatePowerState(lowPower: true, sleeping: true)
        try check(store.nextRefreshDate == nil, "sleep cancels the timer")
        store.updatePowerState(lowPower: false, sleeping: false)

        await probe.setTotal(240)
        store.session = AuthSession(token: "fixture", expiresAt: nil, method: .password)
        await store.refresh()
        for _ in 0..<5 { await store.loadMoreRecentRecords() }
        try check(store.recentRecords.count == 120, "history can extend beyond the shared first page")
        let beforeHistory = await probe.queries.count
        await store.refresh(forceDetails: false)
        let historyQueries = await probe.queries
        // Three 100-record pages are required by today's summary, independent of the loaded UI window.
        try check(historyQueries.count - beforeHistory == 3 && store.recentRecords.count == 120,
                  "history window does not add duplicate downloads to daily aggregation")
        try check(Set(store.recentRecords.map(\.id)).count == 120, "cached history remains duplicate-free")
        await probe.insertRecords(150)
        await store.refresh(forceDetails: false)
        try check(store.recentRecords.count == 120 && store.recentRecords.first?.id == "new-0",
                  "refresh preserves history even after more than one new API page arrives")
        await probe.setRateFailure(true)
        await store.refresh(now: Date())
        let failedRates = await probe.rateCalls
        let failedRatesDate = store.groupRatesUpdated
        await store.refresh(forceDetails: false, now: Date().addingTimeInterval(10))
        let cachedFailedRates = await probe.rateCalls
        try check(failedRates == cachedFailedRates && store.groupRatesError != nil && store.groupRatesUpdated == failedRatesDate,
                  "failed metadata waits for its retry interval and preserves stale-data warnings")
        // The timer must use the attempt time, so failure cannot turn a 60-second poll into a one-second loop.
        store.updateRefreshSeconds(10)
        await Task.yield()
        try check((store.nextRefreshDate?.timeIntervalSinceNow ?? 0) > 40,
                  "failure keeps the background timer near 60 seconds")
        await probe.setRateFailure(false)
        await store.refresh()
        try check(store.groupRatesError == nil, "manual refresh recovers failed metadata immediately")
        #endif
        print("energy fixtures passed: shared pages, cache expiry, metadata scheduling, manual refresh, pending requests, midnight, session isolation, power policy and history")
    }

    private static func check(_ value: Bool, _ label: String) throws {
        if !value { throw EnergyFailure.failed(label) }
    }
}

private enum EnergyFailure: Error { case failed(String) }

private actor EnergyProbe: UsageProvider {
    nonisolated let manifest = ProviderManifest(id: "energy-fixture", name: "Fixture",
        capabilities: [.balance, .requestDetails, .usageTrend, .groupRates], supportedAuthMethods: [.password])
    private(set) var queries: [UsageQuery] = []
    private(set) var trendCalls = 0
    private(set) var rateCalls = 0
    private(set) var overviewCalls = 0
    private var status = "处理中"
    private var total = 45
    private var insertedCount = 0
    private var rateFailure = false
    private var recordDate = Date()
    func setStatus(_ value: String) { status = value }
    func setRecordDate(_ value: Date) { recordDate = value }
    func setTotal(_ value: Int) { total = value; recordDate = Date() }
    func insertRecords(_ count: Int) { insertedCount = count; total += count; recordDate = Date() }
    func setRateFailure(_ value: Bool) { rateFailure = value }
    func authenticate(_ method: AuthMethod, secret: String, username: String?) async throws -> AuthSession {
        throw ProviderError.unsupported("fixture")
    }
    func fetchOverview(session: AuthSession) async throws -> UsageOverview {
        overviewCalls += 1
        return UsageOverview(availableBalance: 42, balance: nil, frozenBalance: nil, usedBalance: nil,
            totalUncoveredAmount: nil, requestCount: total, todayRequests: total, totalTokens: 0,
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: nil,
            reasoningTokens: 0, cost: nil, todayCost: nil, averageFirstTokenTimeMs: nil,
            averageResponseTimeMs: nil, apiKeyCount: 0, updatedAt: Date())
    }
    func fetchTrend(session: AuthSession, days: Int) async throws -> [UsageBucket] {
        trendCalls += 1
        _ = try await fetchRecentUsage(session: session, query: UsageQuery(pageSize: 100))
        return []
    }
    func fetchTrend(session: AuthSession, days: Int,
                    fetchPage: @Sendable (UsageQuery) async throws -> UsagePage) async throws -> [UsageBucket] {
        trendCalls += 1
        _ = try await fetchPage(UsageQuery(pageSize: 100))
        return []
    }
    func fetchGroupRates(session: AuthSession) async throws -> [GroupRate] {
        rateCalls += 1
        if rateFailure { throw ProviderError.server("fixture unavailable") }
        return [GroupRate(id: "7", name: "fixture", multiplier: 1)]
    }
    func fetchRecentUsage(session: AuthSession, query: UsageQuery) async throws -> UsagePage {
        queries.append(query)
        let start = min(total, (query.page - 1) * query.pageSize)
        return UsagePage(records: (start..<min(start + query.pageSize, total)).map { i in
            UsageRecord(id: i < insertedCount ? "new-\(i)" : String(i - insertedCount),
                requestId: i < insertedCount ? "new-\(i)" : String(i - insertedCount), requestTime: recordDate, modelName: "fixture",
                inputTokens: 10, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: nil, reasoningTokens: 0,
                cost: Decimal(1) / 4, status: i == 0 ? status : "成功", errorMessage: nil, keyName: nil,
                relayMode: nil, reasoningEffort: nil, groupName: nil, isStream: nil, durationMs: nil,
                timeToFirstTokenMs: nil, upstreamFirstEventMs: nil)
        }, total: total)
    }
}
