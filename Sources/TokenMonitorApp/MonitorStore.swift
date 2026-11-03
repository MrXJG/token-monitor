import Foundation
import SwiftUI
import AppKit

@MainActor
final class MonitorStore: ObservableObject {
    @Published var overview: UsageOverview?
    @Published var recentRecords: [UsageRecord] = []
    @Published var todayRecords: [UsageRecord] = []
    @Published var trend: [UsageBucket] = []
    @Published var modelUsage: [ModelUsage] = []
    @Published var isRefreshing = false
    @Published var isLoggingIn = false
    @Published var lastError: String?
    @Published var loginStatus: String?
    @Published var lastUpdated: Date?
    @Published var session: AuthSession?
    @Published var authMethod: AuthMethod = .apiKey
    @Published var username = ""
    @Published var secret = ""
    @Published var revealsSecret = false
    @Published var refreshSeconds = RefreshPolicy.defaultSeconds
    @Published private(set) var nextRefreshDate: Date?
    @Published private(set) var isPanelVisible = false
    @Published private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var trendUpdated: Date?
    private var isSystemSleeping = false
    private var usageAttempted: Date?
    private var trendAttempted: Date?
    private var ratesAttempted: Date?
    @Published private(set) var recentRecordsTotal = 0
    @Published private(set) var isLoadingMoreRecords = false
    @Published var overviewUpdated: Date?
    @Published var recordsUpdated: Date?
    @Published var overviewError: String?
    @Published var recordsError: String?
    @Published var trendError: String?
    @Published var recoveryHint: String?
    @Published var groupRates: [GroupRate] = []
    @Published var groupRatesUpdated: Date?
    @Published var groupRatesError: String?
    @Published var rateChanges: [GroupRateChange] = []
    @Published var hasUnreadRateChange = false
    @Published var rateNotificationsEnabled = true
    @Published var rateNotificationMessage: String?
    private var rateScope: String?
    private let rateNotifications = RateNotificationService()
    private var loadedRecordPages = 1
    @Published var menuBarDisplay: MenuBarDisplay = .balance
    @Published var selectedTab = 0
    @Published var isShowingRequestDetail = false
    @Published var siteAddress = "https://runok.ai"
    @Published var siteAlias = "柴哥 API"
    @Published var providerID = "cbc-runok"
    @Published private(set) var customSiteProfiles: [SiteProfile] = []

    @Published private(set) var provider: any UsageProvider
    private let credentials = CredentialVault(service: "com.tokenmonitor.credentials")
    private let defaults: UserDefaults
    private let siteProfilesKey = "customSiteProfiles"
    private let siteProfilesMigrationKey = "siteProfilesMigrationVersion"
    private let hiddenBuiltInSiteIDsKey = "hiddenBuiltInSiteIDs"
    private let autoLoadSavedCredentials: Bool
    private var timer: Task<Void, Never>?
    private var refreshBackoff = RefreshBackoff()
    private var refreshRevision = 0
    private var sessionAccount: String { sessionAccount(for: provider) }
    private var apiKeyAccount: String { apiKeyAccount(for: provider) }
    private var usernameAccount: String { usernameAccount(for: provider) }
    private var passwordAccount: String { passwordAccount(for: provider) }
    private var refreshAccount: String { refreshAccount(for: provider) }
    private func sessionAccount(for provider: any UsageProvider) -> String { "\(provider.manifest.id).session" }
    private func apiKeyAccount(for provider: any UsageProvider) -> String { "\(provider.manifest.id).apiKey" }
    private func usernameAccount(for provider: any UsageProvider) -> String { "\(provider.manifest.id).username" }
    private func passwordAccount(for provider: any UsageProvider) -> String { "\(provider.manifest.id).password" }
    private func refreshAccount(for provider: any UsageProvider) -> String { "\(provider.manifest.id).refresh" }

    init(provider: (any UsageProvider)? = nil, loadSavedCredentials: Bool = true, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoLoadSavedCredentials = loadSavedCredentials
        if defaults.integer(forKey: siteProfilesMigrationKey) < 1 {
            // Remove retired site profiles once. Credentials, aliases, addresses and
            // rate history remain untouched so the two retained sites keep working.
            customSiteProfiles = []
            defaults.removeObject(forKey: siteProfilesKey)
            defaults.set(2, forKey: siteProfilesMigrationKey)
        } else {
            var currentProfiles: [SiteProfile] = []
            if let data = defaults.data(forKey: siteProfilesKey),
               let profiles = try? JSONDecoder().decode([SiteProfile].self, from: data) {
                currentProfiles = Self.currentCustomProfiles(from: profiles)
                customSiteProfiles = currentProfiles
            }
            if defaults.integer(forKey: siteProfilesMigrationKey) < 2 {
                if let data = try? JSONEncoder().encode(currentProfiles) {
                    defaults.set(data, forKey: siteProfilesKey)
                }
                defaults.set(2, forKey: siteProfilesMigrationKey)
            }
        }
        self.rateNotificationsEnabled = defaults.object(forKey: "rateNotificationsEnabled") as? Bool ?? true
        let storedProviderID = defaults.string(forKey: "providerID")
        let selectedProviderID: String
        let storedAddress = storedProviderID.flatMap { defaults.string(forKey: "siteAddress.\($0)") }?.lowercased()
        if storedProviderID == "cbc-v2" || storedProviderID == "cbc"
            || (storedProviderID == nil && storedAddress == "https://cbc.icu") {
            selectedProviderID = "cbc-runok"
            defaults.set(selectedProviderID, forKey: "providerID")
        } else {
            selectedProviderID = storedProviderID ?? "cbc-runok"
        }
        let definition = ProviderCatalog.definition(for: selectedProviderID)
        let savedAddress = Self.migratedAddress(defaults.string(forKey: "siteAddress.\(definition.id)"), definition: definition)
        let selectedProvider = try? definition.makeProvider(savedAddress)
        self.providerID = definition.id
        self.siteAddress = selectedProvider == nil ? definition.defaultAddress : savedAddress
        self.siteAlias = Self.nonEmptyAlias(defaults.string(forKey: Self.siteAliasKey(providerID: definition.id, address: savedAddress)), fallback: definition.name)
        self.provider = provider ?? selectedProvider ?? CBCGatewayProvider()
        self.authMethod = AuthMethod(rawValue: defaults.string(forKey: "authMethod.\(self.provider.manifest.id)") ?? "")
            ?? self.provider.manifest.supportedAuthMethods.first ?? .apiKey
        let savedInterval = defaults.double(forKey: "refreshSeconds")
        if RefreshPolicy.isValid(savedInterval) { refreshSeconds = savedInterval }
        if let savedDisplay = defaults.string(forKey: "menuBarDisplay"),
           let display = MenuBarDisplay(rawValue: savedDisplay) { menuBarDisplay = display }
        if loadSavedCredentials {
            startAutoRefresh()
            Task { [weak self] in await self?.loadSavedCredentials() }
        }
    }

    var panelHeight: CGFloat {
        guard selectedTab == 1, activeCapabilities.contains(.requestDetails), !isShowingRequestDetail else { return 650 }
        return min(650, max(380, CGFloat(304 + recentRecords.count * 88)))
    }

    var isConfigured: Bool { session != nil }
    var displaySiteAlias: String {
        let value = siteAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? provider.manifest.name : value
    }
    var activeCapabilities: ProviderCapabilities {
        guard let session else { return [] }
        return provider.capabilities(for: session)
    }

    var siteProfiles: [SiteProfile] {
        let hiddenBuiltInIDs = Set(defaults.stringArray(forKey: hiddenBuiltInSiteIDsKey) ?? [])
        let builtIns = ProviderCatalog.builtInProfiles.map { profile in
            SiteProfile(id: profile.id, providerID: profile.providerID,
                        alias: Self.nonEmptyAlias(defaults.string(forKey: Self.siteAliasKey(providerID: profile.providerID,
                                                                                              address: profile.address)), fallback: profile.alias),
                        address: profile.address, isBuiltIn: true,
                        isHidden: hiddenBuiltInIDs.contains(profile.providerID))
        }
        return builtIns.filter { !$0.isHidden } + customSiteProfiles.filter { !$0.isHidden }
    }
    var hiddenSiteProfiles: [SiteProfile] {
        let hiddenIDs = Set(defaults.stringArray(forKey: hiddenBuiltInSiteIDsKey) ?? [])
        let builtIns = ProviderCatalog.builtInProfiles.filter { hiddenIDs.contains($0.providerID) }
            .map { profile in
                profile.with(address: profile.address,
                             alias: Self.nonEmptyAlias(defaults.string(forKey: Self.siteAliasKey(providerID: profile.providerID,
                                                                                                   address: profile.address)), fallback: profile.alias))
            }
        return builtIns + customSiteProfiles.filter(\.isHidden)
    }
    var canHideSite: Bool { siteProfiles.count > 1 }
    var currentSiteProfileIsBuiltIn: Bool {
        ProviderCatalog.definition(for: providerID).defaultAddress == siteAddress
    }
    var currentSiteProfileIsSaved: Bool {
        currentSiteProfileIsBuiltIn || customSiteProfiles.contains {
            $0.providerID == providerID && $0.address == siteAddress
        }
    }

    func addCurrentSiteProfile() {
        guard (try? ProviderCatalog.definition(for: providerID).makeProvider(siteAddress)) != nil,
              !currentSiteProfileIsBuiltIn else { return }
        let normalizedAddress = siteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = customSiteProfiles.firstIndex(where: {
            $0.providerID == providerID && $0.address == normalizedAddress
        }) {
            customSiteProfiles[index].alias = displaySiteAlias
            customSiteProfiles[index].isHidden = false
        } else {
            customSiteProfiles.append(SiteProfile(id: UUID().uuidString, providerID: providerID,
                alias: displaySiteAlias, address: normalizedAddress, isBuiltIn: false))
        }
        persistSiteProfiles()
    }

    func selectSiteProfile(_ profile: SiteProfile) {
        guard !isLoggingIn else { return }
        let definition = ProviderCatalog.definition(for: profile.providerID)
        guard let candidate = try? definition.makeProvider(profile.address) else { return }
        refreshRevision += 1
        isRefreshing = false
        providerID = definition.id
        siteAddress = profile.address
        siteAlias = Self.nonEmptyAlias(profile.alias, fallback: definition.name)
        provider = candidate
        session = nil
        selectedTab = 0
        clearSnapshot()
        authMethod = AuthMethod(rawValue: defaults.string(forKey: "authMethod.\(candidate.manifest.id)") ?? "")
            ?? candidate.manifest.supportedAuthMethods.first ?? .apiKey
        username = ""; secret = ""; revealsSecret = false
        loginStatus = nil; lastError = nil
        defaults.set(definition.id, forKey: "providerID")
        defaults.set(profile.address, forKey: "siteAddress.\(definition.id)")
        defaults.set(siteAlias, forKey: Self.siteAliasKey(providerID: definition.id, address: profile.address))
        if autoLoadSavedCredentials { Task { await loadSavedCredentials() } }
    }

    func hideSiteProfile(_ profile: SiteProfile) {
        guard canHideSite, !isRefreshing, !isLoggingIn else { return }
        if profile.isBuiltIn {
            var hiddenIDs = Set(defaults.stringArray(forKey: hiddenBuiltInSiteIDsKey) ?? [])
            hiddenIDs.insert(profile.providerID)
            defaults.set(hiddenIDs.sorted(), forKey: hiddenBuiltInSiteIDsKey)
        } else {
            guard let profileIndex = customSiteProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
            customSiteProfiles[profileIndex].isHidden = true
            persistSiteProfiles()
        }
        if providerID == profile.providerID && siteAddress == profile.address {
            guard let fallback = siteProfiles.first else { return }
            selectSiteProfile(fallback)
        }
    }

    func restoreSiteProfile(_ profile: SiteProfile) {
        if profile.isBuiltIn {
            var hiddenIDs = Set(defaults.stringArray(forKey: hiddenBuiltInSiteIDsKey) ?? [])
            hiddenIDs.remove(profile.providerID)
            defaults.set(hiddenIDs.sorted(), forKey: hiddenBuiltInSiteIDsKey)
        } else {
            guard let profileIndex = customSiteProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
            customSiteProfiles[profileIndex].isHidden = false
            persistSiteProfiles()
        }
    }

    private func persistSiteProfiles() {
        if let data = try? JSONEncoder().encode(customSiteProfiles) {
            defaults.set(data, forKey: siteProfilesKey)
        }
    }

    private static func currentCustomProfiles(from profiles: [SiteProfile]) -> [SiteProfile] {
        let currentIDs = Set(ProviderCatalog.all.map(\.id))
        return profiles.filter { !$0.isBuiltIn && currentIDs.contains($0.providerID) }
    }

    var currentGroupRate: GroupRate? {
        if let latest = recentRecords.first {
            if let id = latest.groupID { return groupRates.first { $0.id == id } }
            if let name = latest.groupName {
                let matches = groupRates.filter { $0.name == name }
                return matches.count == 1 ? matches[0] : nil
            }
            return nil
        }
        return groupRates.count == 1 ? groupRates[0] : nil
    }

    func acknowledgeRateChanges() {
        hasUnreadRateChange = false
        if let rateScope { defaults.set(Date(), forKey: "groupRateSeen.\(rateScope)") }
    }

    func updateRateNotifications(_ enabled: Bool) {
        rateNotificationsEnabled = enabled
        defaults.set(enabled, forKey: "rateNotificationsEnabled")
        if enabled { Task { rateNotificationMessage = await rateNotifications.requestAuthorization() } }
        else { rateNotificationMessage = "系统通知已关闭，倍率变化仍会保留在面板中。" }
    }

    private func recordGroupRates(accountID: String?, site: String, revision: Int) {
        guard !groupRates.isEmpty else { return }
        let accountID = accountID
            ?? (providerID == "zhiyao" ? "public" : nil)
            ?? (providerID == "cbc" || providerID == "cbc-runok" || providerID.hasPrefix("cbc:") ? "site" : nil)
        guard let accountID else { return }
        let scope = "\(provider.manifest.id):\(accountID)"
        rateScope = scope
        let tracker = GroupRateTracker(defaults: defaults)
        let changes = tracker.observe(groupRates, scope: scope)
        rateChanges = tracker.history(scope: scope)
        let seen = defaults.object(forKey: "groupRateSeen.\(scope)") as? Date ?? .distantPast
        hasUnreadRateChange = rateChanges.contains { $0.detectedAt > seen }
        guard rateNotificationsEnabled else { return }
        // A system permission prompt must never hold up refresh completion.
        Task { [weak self] in
            guard let self, rateNotificationsEnabled, revision == refreshRevision else { return }
            var message = await rateNotifications.requestAuthorization()
            guard rateNotificationsEnabled, revision == refreshRevision else { return }
            if message == nil, !changes.isEmpty { message = await rateNotifications.send(changes, site: site) }
            guard revision == refreshRevision else { return }
            rateNotificationMessage = message
        }
    }

    func login() async {
        guard !isLoggingIn else { return }
        let startingRevision = refreshRevision
        isLoggingIn = true
        defer { isLoggingIn = false }
        loginStatus = nil
        lastError = nil
        recoveryHint = nil
        do {
            let submittedAddress = siteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let selectedID = providerID
            let definition = ProviderCatalog.definition(for: selectedID)
            let candidate = try definition.makeProvider(submittedAddress)
            let method = authMethod
            let submittedSecret = secret
            let newSession = try await candidate.authenticate(method, secret: submittedSecret, username: username.isEmpty ? nil : username)
            guard startingRevision == refreshRevision,
                  providerID == selectedID,
                  siteAddress.trimmingCharacters(in: .whitespacesAndNewlines) == submittedAddress else { return }
            try await credentials.saveLogin(
                sessionToken: newSession.token,
                sessionAccount: sessionAccount(for: candidate),
                apiKey: method == .apiKey ? submittedSecret : nil,
                apiKeyAccount: apiKeyAccount(for: candidate),
                username: method == .password ? (username.isEmpty ? nil : username) : nil,
                usernameAccount: usernameAccount(for: candidate),
                password: method == .password ? submittedSecret : nil,
                passwordAccount: passwordAccount(for: candidate),
                refreshToken: newSession.refreshToken,
                refreshAccount: refreshAccount(for: candidate)
            )
            guard startingRevision == refreshRevision else { return }
            refreshRevision += 1
            isRefreshing = false
            clearSnapshot()
            provider = candidate
            session = newSession
            selectedTab = 0
            secret = ""
            siteAddress = submittedAddress
            siteAlias = Self.nonEmptyAlias(defaults.string(forKey: Self.siteAliasKey(providerID: selectedID, address: submittedAddress)), fallback: definition.name)
            defaults.set(selectedID, forKey: "providerID")
            defaults.set(submittedAddress, forKey: "siteAddress.\(selectedID)")
            defaults.set(method.rawValue, forKey: "authMethod.\(candidate.manifest.id)")
            addCurrentSiteProfile()
            loginStatus = "登录成功，正在同步数据"
            let loginRevision = refreshRevision
            await refresh()
            if loginRevision == refreshRevision, lastError == nil, lastUpdated != nil {
                loginStatus = "登录成功，数据已更新"
            } else if loginRevision == refreshRevision, lastError != nil {
                loginStatus = "登录成功，数据更新失败"
            }
        } catch {
            if startingRevision == refreshRevision {
                loginStatus = nil
                lastError = error.localizedDescription
                recoveryHint = ErrorRecovery.hint(for: error)
            }
        }
    }

    func logout() {
        refreshRevision += 1
        isRefreshing = false
        session = nil
        clearSnapshot()
        let currentSessionAccount = sessionAccount
        let currentAPIKeyAccount = apiKeyAccount
        let currentRefreshAccount = refreshAccount
        let currentUsernameAccount = usernameAccount
        let currentPasswordAccount = passwordAccount
        Task { await credentials.delete(sessionAccount: currentSessionAccount, apiKeyAccount: currentAPIKeyAccount,
                                        usernameAccount: currentUsernameAccount, passwordAccount: currentPasswordAccount,
                                        refreshAccount: currentRefreshAccount) }
        loginStatus = "已退出登录"
    }

    func refresh(forceDetails: Bool = true, now: Date = Date(), updateUsage: Bool = true) async {
        guard !isRefreshing, !isLoadingMoreRecords else { return }
        if refreshBackoff.remaining() > 0 {
            let seconds = ceil(refreshBackoff.remaining()).formatted(.number.precision(.fractionLength(0)))
            lastError = "请求过于频繁，已暂停刷新，请等待 \(seconds) 秒"
            return
        }
        let revision = refreshRevision
        let activeProvider = provider
        isRefreshing = true
        defer { if revision == refreshRevision { isRefreshing = false } }
        let currentSession: AuthSession?
        if let session {
            currentSession = session
        } else {
            currentSession = await restoreSession(provider: activeProvider, revision: revision)
        }
        guard revision == refreshRevision, let currentSession else { return }
        do {
            try await loadSnapshot(session: currentSession, provider: activeProvider, revision: revision, forceDetails: forceDetails, now: now, updateUsage: updateUsage)
        } catch ProviderError.unauthenticated {
            guard revision == refreshRevision else { return }
            var renewedSession: AuthSession
            do {
                renewedSession = try await activeProvider.renewSession(currentSession)
                guard revision == refreshRevision else { return }
                try await credentials.saveSession(renewedSession.token,
                                                  account: sessionAccount(for: activeProvider),
                                                  refreshToken: renewedSession.refreshToken,
                                                  refreshAccount: refreshAccount(for: activeProvider))
                session = renewedSession
            } catch ProviderError.unauthenticated {
                guard revision == refreshRevision else { return }
                session = nil
                guard let restored = await restoreSession(provider: activeProvider, revision: revision) else { return }
                renewedSession = restored
            } catch {
                handleRefreshError(error, revision: revision)
                return
            }
            do {
                try await loadSnapshot(session: renewedSession, provider: activeProvider, revision: revision, forceDetails: forceDetails, now: now, updateUsage: updateUsage)
            } catch {
                handleRefreshError(error, revision: revision)
            }
        } catch {
            handleRefreshError(error, revision: revision)
        }
    }

    private func loadSnapshot(session: AuthSession, provider: any UsageProvider, revision: Int, forceDetails: Bool, now: Date, updateUsage: Bool) async throws {
        let pages = loadedRecordPages
        let updateUsage = updateUsage || overview == nil || recordsUpdated == nil
        let cachedSummary = overview.map { ($0, todayRecords, modelUsage) }
        let cachedRecords = UsagePage(records: recentRecords, total: recentRecordsTotal)
        let batch = UsageRecordBatch(provider: provider, session: session)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let refreshTrend = forceDetails || trendAttempted == nil
            || now.timeIntervalSince(trendAttempted ?? .distantPast) >= RefreshPolicy.detailSeconds
            || !calendar.isDate(trendAttempted ?? .distantPast, inSameDayAs: now)
        let refreshRates = forceDetails || ratesAttempted == nil
            || now.timeIntervalSince(ratesAttempted ?? .distantPast) >= RefreshPolicy.detailSeconds
        if updateUsage { usageAttempted = now }
        if refreshTrend { trendAttempted = now }
        if refreshRates { ratesAttempted = now }
        let cachedTrend = trend
        let cachedRates = groupRates
        async let summaryResult = capture {
            if !updateUsage, let cachedSummary { return cachedSummary }
            return try await self.fetchDailySummary(session: session, provider: provider, batch: batch, now: now)
        }
        async let recordsResult = capture {
            if !updateUsage { return cachedRecords }
            return try await self.fetchRecordPages(pages: pages, batch: batch, retainHistory: !forceDetails)
        }
        async let trendResult = capture {
            refreshTrend ? try await provider.fetchTrend(session: session, days: 7, fetchPage: { try await batch.fetch($0) }) : cachedTrend
        }
        async let ratesResult = capture { refreshRates ? try await provider.fetchGroupRates(session: session) : cachedRates }
        let (summary, records, dailyTrend, rates) = await (summaryResult, recordsResult, trendResult, ratesResult)
        guard revision == refreshRevision else { return }
        // Authentication failure renews the session once before retrying all sections.
        let errors = [summary.failure, records.failure, dailyTrend.failure, rates.failure].compactMap { $0 }
        if errors.contains(where: { if case ProviderError.unauthenticated = $0 { return true }; return false }) {
            throw ProviderError.unauthenticated
        }
        switch summary {
        case .success(let snapshot):
            if updateUsage {
                overview = snapshot.0; todayRecords = snapshot.1; modelUsage = snapshot.2
                overviewUpdated = now; overviewError = nil
            }
        case .failure(let error): overviewError = error.localizedDescription
        }
        switch records {
        case .success(let page):
            if updateUsage {
                recentRecords = page.records; recentRecordsTotal = page.total
                loadedRecordPages = max(1, (page.records.count + 19) / 20)
                recordsUpdated = now; recordsError = nil
            }
        case .failure(let error): recordsError = error.localizedDescription
        }
        switch dailyTrend {
        case .success(let buckets):
            if refreshTrend { trend = buckets; trendUpdated = now; trendError = nil }
        case .failure(let error): trendError = error.localizedDescription
        }
        switch rates {
        case .success(let values):
            if refreshRates { groupRates = values; groupRatesUpdated = now; groupRatesError = nil }
        case .failure(let error): groupRatesError = error.localizedDescription
        }
        if errors.isEmpty, overviewError == nil, recordsError == nil, trendError == nil, groupRatesError == nil {
            if updateUsage || refreshTrend || refreshRates { lastUpdated = now }
            lastError = nil; recoveryHint = nil
            refreshBackoff.reset()
        } else if !errors.isEmpty {
            // Retain each failed section's previous data while publishing successful sections.
            let error = errors.first(where: { if case ProviderError.rateLimited = $0 { return true }; return false }) ?? errors[0]
            handleRefreshError(error, revision: revision)
            let messages = [overviewError.map { "概览更新失败：" + $0 }, recordsError.map { "请求记录更新失败：" + $0 }, trendError.map { "趋势更新失败：" + $0 }, groupRatesError.map { "分组倍率更新失败：" + $0 }].compactMap { $0 }
            if case ProviderError.rateLimited = error { lastError = messages.joined(separator: "；") + "。" + (lastError ?? "") }
            else { lastError = messages.joined(separator: "；") }
        }
        if refreshRates, case .success = rates {
            recordGroupRates(accountID: overview?.billingAccountID, site: provider.manifest.name, revision: revision)
        }
    }

    private func fetchDailySummary(session: AuthSession, provider: any UsageProvider, batch: UsageRecordBatch, now: Date) async throws -> (UsageOverview, [UsageRecord], [ModelUsage]) {
        let summary = try await provider.fetchOverview(session: session)
        guard provider.capabilities(for: session).contains(.requestDetails) else { return (summary, [], []) }
        let records = try await fetchTodayRecords(batch: batch, now: now)
        let (daily, models) = UsageAggregator.today(overview: summary, records: records)
        return (daily, records, models)
    }

    private func fetchRecordPages(pages: Int, batch: UsageRecordBatch, retainHistory: Bool) async throws -> UsagePage {
        var records: [UsageRecord] = []
        var total = 0
        let limit = max(1, pages) * 20
        for page in 1...max(1, (limit + 99) / 100) {
            let result = try await batch.fetch(UsageQuery(page: page, pageSize: 100))
            total = result.total
            records.append(contentsOf: result.records)
            if retainHistory, page == 1, !recentRecords.isEmpty {
                if result.records.count >= total {
                    return UsagePage(records: Array(uniqueRecords(records).prefix(limit)), total: total)
                }
                let ids = Set(records.map(\.id))
                // Reuse the old window only when the new head overlaps it; otherwise reload the visible range.
                if recentRecords.contains(where: { ids.contains($0.id) }) {
                    return UsagePage(records: Array(uniqueRecords(records + recentRecords).prefix(limit)), total: total)
                }
            }
            if result.records.isEmpty || page * 100 >= total { break }
        }
        return UsagePage(records: Array(uniqueRecords(records).prefix(limit)), total: total)
    }

    private func uniqueRecords(_ records: [UsageRecord]) -> [UsageRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.id).inserted }
    }

    var canLoadMoreRecords: Bool { loadedRecordPages * 20 < recentRecordsTotal }

    func loadMoreRecentRecords() async {
        guard !isRefreshing, !isLoadingMoreRecords, canLoadMoreRecords,
              refreshBackoff.remaining() == 0, let currentSession = session else { return }
        let revision = refreshRevision
        let activeProvider = provider
        isLoadingMoreRecords = true
        defer { if revision == refreshRevision { isLoadingMoreRecords = false } }
        do {
            let nextPage = loadedRecordPages + 1
            let page = try await activeProvider.fetchRecentUsage(session: currentSession, query: UsageQuery(page: nextPage, pageSize: 20))
            guard revision == refreshRevision else { return }
            recentRecords = uniqueRecords(recentRecords + page.records)
            loadedRecordPages = nextPage
            recentRecordsTotal = page.records.isEmpty ? recentRecords.count : page.total
            // Loading historical pages does not update the timestamp of the latest page.
            recordsError = nil
        } catch {
            guard revision == refreshRevision else { return }
            recordsError = error.localizedDescription
            handleRefreshError(error, revision: revision)
        }
    }

    private func restoreSession(provider: any UsageProvider, revision: Int) async -> AuthSession? {
        do {
            let savedMethod = AuthMethod(rawValue: defaults.string(forKey: "authMethod.\(provider.manifest.id)") ?? "")
                ?? provider.manifest.supportedAuthMethods.first ?? .apiKey
            let newSession: AuthSession
            switch savedMethod {
            case .apiKey:
                guard let apiKey = try await credentials.read(account: apiKeyAccount(for: provider)), !apiKey.isEmpty else {
                    if revision == refreshRevision { lastError = "认证已失效，请重新登录" }
                    return nil
                }
                newSession = try await provider.authenticate(.apiKey, secret: apiKey, username: nil)
            case .password:
                guard let username = try await credentials.read(account: usernameAccount(for: provider)), !username.isEmpty,
                      let password = try await credentials.read(account: passwordAccount(for: provider)), !password.isEmpty else {
                    if revision == refreshRevision { lastError = "认证已失效，请重新登录" }
                    return nil
                }
                newSession = try await provider.authenticate(.password, secret: password, username: username)
            }
            guard revision == refreshRevision else { return nil }
            try await credentials.saveSession(newSession.token, account: sessionAccount(for: provider),
                                              refreshToken: newSession.refreshToken,
                                              refreshAccount: refreshAccount(for: provider))
            guard revision == refreshRevision else { return nil }
            session = newSession
            return newSession
        } catch {
            handleRefreshError(error, revision: revision)
            return nil
        }
    }

    private func loadSavedCredentials() async {
        let revision = refreshRevision
        do {
            if let token = try await credentials.read(account: sessionAccount), !token.isEmpty {
                let refreshToken = try await credentials.read(account: refreshAccount)
                guard revision == refreshRevision else { return }
                let method = AuthMethod(rawValue: defaults.string(forKey: "authMethod.\(provider.manifest.id)") ?? "")
                    ?? provider.manifest.supportedAuthMethods.first ?? .apiKey
                session = AuthSession(token: token, expiresAt: nil, method: method, refreshToken: refreshToken)
                await refresh()
            } else if let apiKey = try await credentials.read(account: apiKeyAccount), !apiKey.isEmpty {
                guard revision == refreshRevision else { return }
                await refresh()
            } else if let username = try await credentials.read(account: usernameAccount), !username.isEmpty,
                      let password = try await credentials.read(account: passwordAccount), !password.isEmpty {
                guard revision == refreshRevision else { return }
                await refresh()
            }
        } catch {
            if revision == refreshRevision { lastError = error.localizedDescription }
        }
    }

    private func clearSnapshot() {
        groupRates = []; groupRatesUpdated = nil; groupRatesError = nil
        rateChanges = []; rateScope = nil; hasUnreadRateChange = false; rateNotificationMessage = nil
        overview = nil
        recentRecords = []
        todayRecords = []
        trend = []
        trendUpdated = nil
        usageAttempted = nil; trendAttempted = nil; ratesAttempted = nil
        modelUsage = []
        lastUpdated = nil
        recentRecordsTotal = 0
        loadedRecordPages = 1
        isLoadingMoreRecords = false
        isShowingRequestDetail = false
        overviewUpdated = nil; recordsUpdated = nil
        overviewError = nil; recordsError = nil; trendError = nil; recoveryHint = nil
        lastError = nil
        refreshBackoff.reset()
    }

    func updateRefreshSeconds(_ value: Double) {
        guard RefreshPolicy.isValid(value) else { return }
        refreshSeconds = value
        defaults.set(value, forKey: "refreshSeconds")
        startAutoRefresh()
    }

    private func handleRefreshError(_ error: Error, revision: Int) {
        guard revision == refreshRevision, !(error is CancellationError) else { return }
        if case ProviderError.rateLimited(let retryAfter) = error {
            let delay = refreshBackoff.register(retryAfter: retryAfter, interval: refreshSeconds)
            let seconds = ceil(delay).formatted(.number.precision(.fractionLength(0)))
            lastError = "请求过于频繁，已暂停刷新约 \(seconds) 秒"
            recoveryHint = "等待倒计时结束后自动重试，无需重复点击刷新。"
            startAutoRefresh()
        } else {
            lastError = error.localizedDescription
            recoveryHint = ErrorRecovery.hint(for: error)
        }
    }

    func updateProviderID(_ value: String) {
        guard value != providerID else { return }
        let definition = ProviderCatalog.definition(for: value)
        let address = Self.migratedAddress(defaults.string(forKey: "siteAddress.\(value)"), definition: definition)
        guard let profile = ProviderCatalog.builtInProfiles.first(where: { $0.providerID == value }) else { return }
        selectSiteProfile(profile.with(address: address,
                                       alias: Self.nonEmptyAlias(defaults.string(forKey: Self.siteAliasKey(providerID: value, address: address)), fallback: definition.name)))
    }

    func beginAddingSite() {
        guard !isRefreshing, !isLoggingIn else { return }
        refreshRevision += 1
        session = nil
        clearSnapshot()
        siteAddress = ""
        siteAlias = "新站点"
        username = ""
        secret = ""
        revealsSecret = false
        loginStatus = nil
        lastError = nil
    }

    func updateSiteAddress(_ value: String) {
        siteAddress = value
        siteAlias = Self.nonEmptyAlias(defaults.string(forKey: Self.siteAliasKey(providerID: providerID, address: value)),
                                       fallback: ProviderCatalog.definition(for: providerID).name)
    }

    func updateSiteAlias(_ value: String) {
        siteAlias = value
        defaults.set(value, forKey: Self.siteAliasKey(providerID: providerID, address: siteAddress))
        if let index = customSiteProfiles.firstIndex(where: {
            $0.providerID == providerID && $0.address == siteAddress
        }) {
            customSiteProfiles[index].alias = value
            persistSiteProfiles()
        }
    }

    private static func siteAliasKey(providerID: String, address: String) -> String {
        let host = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? "default"
        return "siteAlias.\(providerID).\(host)"
    }

    private static func nonEmptyAlias(_ value: String?, fallback: String) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return value
    }

    private static func migratedAddress(_ value: String?, definition: ProviderDefinition) -> String {
        guard definition.id == "zhiyao", let value,
              URLComponents(string: value)?.host?.lowercased() == "zyapi.tuluo.top" else {
            return value ?? definition.defaultAddress
        }
        return definition.defaultAddress
    }

    func updateMenuBarDisplay(_ value: MenuBarDisplay) {
        menuBarDisplay = value
        defaults.set(value.rawValue, forKey: "menuBarDisplay")
    }

    private func fetchTodayRecords(batch: UsageRecordBatch, now: Date) async throws -> [UsageRecord] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let startOfToday = calendar.startOfDay(for: now)
        var all: [UsageRecord] = []
        for page in 1...100 {
            let result = try await batch.fetch(UsageQuery(page: page, pageSize: 100))
            all.append(contentsOf: result.records)
            if result.records.isEmpty || all.count >= result.total || result.records.contains(where: { record in
                guard let date = record.requestTime else { return false }
                return date < startOfToday
            }) {
                return all.filter { record in
                    guard let date = record.requestTime else { return false }
                    return date >= startOfToday
                }
            }
        }
        throw ProviderError.server("今日请求过多，无法完整统计")
    }

    func startAutoRefresh() {
        timer?.cancel()
        nextRefreshDate = nil
        guard !isSystemSleeping else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                let delay = self?.nextRefreshDelay() ?? RefreshPolicy.defaultSeconds
                let scheduledDate = Date().addingTimeInterval(delay)
                self?.nextRefreshDate = scheduledDate
                do {
                    try await Task.sleep(for: .seconds(delay), tolerance: .seconds(min(5, delay / 10)))
                } catch {
                    if !Task.isCancelled { self?.nextRefreshDate = nil }
                    return
                }
                guard !Task.isCancelled else { return }
                self?.nextRefreshDate = nil
                // Changing the interval cancels only the timer, not an in-flight request.
                let refreshTask = Task { [weak self] in
                    guard self?.session != nil else { return }
                    guard let self else { return }
                    let usageDue = Date().timeIntervalSince(usageAttempted ?? .distantPast) >= effectiveRefreshSeconds
                    await refresh(forceDetails: false, updateUsage: usageDue)
                }
                await refreshTask.value
            }
        }
    }

    private func nextRefreshDelay() -> TimeInterval {
        let now = Date()
        let usageDelay = max(1, effectiveRefreshSeconds - now.timeIntervalSince(usageAttempted ?? now))
        let trendDelay = max(1, RefreshPolicy.detailSeconds - now.timeIntervalSince(trendAttempted ?? now))
        let ratesDelay = max(1, RefreshPolicy.detailSeconds - now.timeIntervalSince(ratesAttempted ?? now))
        return max(min(usageDelay, trendDelay, ratesDelay), refreshBackoff.remaining())
    }

    var effectiveRefreshSeconds: Double {
        RefreshPolicy.effectiveSeconds(refreshSeconds, panelVisible: isPanelVisible, lowPower: isLowPowerMode)
    }

    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        startAutoRefresh()
        if visible, session != nil, Date().timeIntervalSince(overviewUpdated ?? .distantPast) >= refreshSeconds {
            Task { await refresh(forceDetails: false) }
        }
    }

    func updatePowerState(lowPower: Bool, sleeping: Bool) {
        guard isLowPowerMode != lowPower || isSystemSleeping != sleeping else { return }
        let waking = isSystemSleeping && !sleeping
        isLowPowerMode = lowPower
        isSystemSleeping = sleeping
        startAutoRefresh()
        if waking, session != nil { Task { await refresh(forceDetails: false) } }
    }

    deinit { timer?.cancel() }
}

// Capture independent sections without discarding all data on one endpoint failure.
private func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
}
private extension Result {
    var failure: Failure? { if case .failure(let error) = self { return error }; return nil }
}
