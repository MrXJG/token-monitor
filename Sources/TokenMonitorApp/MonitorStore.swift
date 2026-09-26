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
    @Published var refreshSeconds = 60.0
    @Published var menuBarDisplay: MenuBarDisplay = .balance
    @Published var selectedTab = 0
    @Published var siteAddress = "https://cbc.icu"
    @Published var providerID = "cbc"

    @Published private(set) var provider: any UsageProvider
    private let credentials = CredentialVault(service: "com.tokenmonitor.credentials")
    private var timer: Task<Void, Never>?
    private var refreshRevision = 0
    private var sessionAccount: String { sessionAccount(for: provider) }
    private var apiKeyAccount: String { apiKeyAccount(for: provider) }
    private func sessionAccount(for provider: any UsageProvider) -> String { "\(provider.manifest.id).session" }
    private func apiKeyAccount(for provider: any UsageProvider) -> String { "\(provider.manifest.id).apiKey" }

    init(provider: (any UsageProvider)? = nil, loadSavedCredentials: Bool = true) {
        let definition = ProviderCatalog.definition(for: UserDefaults.standard.string(forKey: "providerID") ?? "cbc")
        let savedAddress = UserDefaults.standard.string(forKey: "siteAddress.\(definition.id)") ?? definition.defaultAddress
        let selectedProvider = try? definition.makeProvider(savedAddress)
        self.providerID = definition.id
        self.siteAddress = selectedProvider == nil ? definition.defaultAddress : savedAddress
        self.provider = provider ?? selectedProvider ?? CBCProvider()
        self.authMethod = AuthMethod(rawValue: UserDefaults.standard.string(forKey: "authMethod.\(self.provider.manifest.id)") ?? "")
            ?? self.provider.manifest.supportedAuthMethods.first ?? .apiKey
        let savedInterval = UserDefaults.standard.double(forKey: "refreshSeconds")
        if [30.0, 60.0, 300.0].contains(savedInterval) { refreshSeconds = savedInterval }
        if let savedDisplay = UserDefaults.standard.string(forKey: "menuBarDisplay"),
           let display = MenuBarDisplay(rawValue: savedDisplay) { menuBarDisplay = display }
        if loadSavedCredentials {
            startAutoRefresh()
            Task { [weak self] in await self?.loadSavedCredentials() }
        }
    }

    var isConfigured: Bool { session != nil }
    var activeCapabilities: ProviderCapabilities {
        guard let session else { return [] }
        return provider.capabilities(for: session)
    }

    func login() async {
        guard !isLoggingIn else { return }
        let startingRevision = refreshRevision
        isLoggingIn = true
        defer { isLoggingIn = false }
        loginStatus = nil
        lastError = nil
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
                apiKeyAccount: apiKeyAccount(for: candidate)
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
            UserDefaults.standard.set(selectedID, forKey: "providerID")
            UserDefaults.standard.set(submittedAddress, forKey: "siteAddress.\(selectedID)")
            UserDefaults.standard.set(method.rawValue, forKey: "authMethod.\(candidate.manifest.id)")
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
        Task { await credentials.delete(sessionAccount: currentSessionAccount, apiKeyAccount: currentAPIKeyAccount) }
        loginStatus = "已退出登录"
    }

    func refresh() async {
        guard !isRefreshing else { return }
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
            try await loadSnapshot(session: currentSession, provider: activeProvider, revision: revision)
        } catch ProviderError.unauthenticated {
            guard revision == refreshRevision else { return }
            session = nil
            guard let renewedSession = await restoreSession(provider: activeProvider, revision: revision) else { return }
            do {
                try await loadSnapshot(session: renewedSession, provider: activeProvider, revision: revision)
            } catch {
                if revision == refreshRevision { lastError = error.localizedDescription }
            }
        } catch {
            if revision == refreshRevision { lastError = error.localizedDescription }
        }
    }

    private func loadSnapshot(session: AuthSession, provider: any UsageProvider, revision: Int) async throws {
        async let overviewRequest = provider.fetchOverview(session: session)
        async let recordsRequest = provider.fetchRecentUsage(session: session, query: UsageQuery(pageSize: 20))
        async let trendRequest = provider.fetchTrend(session: session, days: 7)
        let summary = try await overviewRequest
        let latest = try await recordsRequest.records
        let dailyTrend = try await trendRequest
        let dailyRecords = provider.capabilities(for: session).contains(.requestDetails)
            ? try await fetchTodayRecords(session: session, provider: provider) : []
        guard revision == refreshRevision else { return }
        let (dailyOverview, models) = provider.capabilities(for: session).contains(.requestDetails)
            ? UsageAggregator.today(overview: summary, records: dailyRecords) : (summary, [])
        overview = dailyOverview
        recentRecords = latest
        trend = dailyTrend
        todayRecords = dailyRecords
        modelUsage = models
        lastUpdated = Date()
        lastError = nil
    }

    private func restoreSession(provider: any UsageProvider, revision: Int) async -> AuthSession? {
        do {
            guard let apiKey = try await credentials.read(account: apiKeyAccount(for: provider)), !apiKey.isEmpty else {
                if revision == refreshRevision { lastError = "认证已失效，请重新登录" }
                return nil
            }
            let newSession = try await provider.authenticate(.apiKey, secret: apiKey, username: nil)
            guard revision == refreshRevision else { return nil }
            try await credentials.saveSession(newSession.token, account: sessionAccount(for: provider))
            guard revision == refreshRevision else { return nil }
            session = newSession
            return newSession
        } catch {
            if revision == refreshRevision { lastError = error.localizedDescription }
            return nil
        }
    }

    private func loadSavedCredentials() async {
        let revision = refreshRevision
        do {
            if let token = try await credentials.read(account: sessionAccount), !token.isEmpty {
                guard revision == refreshRevision else { return }
                let method = AuthMethod(rawValue: UserDefaults.standard.string(forKey: "authMethod.\(provider.manifest.id)") ?? "apiKey") ?? .apiKey
                session = AuthSession(token: token, expiresAt: nil, method: method)
                await refresh()
            } else if let apiKey = try await credentials.read(account: apiKeyAccount), !apiKey.isEmpty {
                guard revision == refreshRevision else { return }
                await refresh()
            }
        } catch {
            if revision == refreshRevision { lastError = error.localizedDescription }
        }
    }

    private func clearSnapshot() {
        overview = nil
        recentRecords = []
        todayRecords = []
        trend = []
        modelUsage = []
        lastUpdated = nil
        lastError = nil
    }

    func updateRefreshSeconds(_ value: Double) {
        refreshSeconds = value
        UserDefaults.standard.set(value, forKey: "refreshSeconds")
        startAutoRefresh()
    }

    func updateProviderID(_ value: String) {
        guard value != providerID else { return }
        let definition = ProviderCatalog.definition(for: value)
        let address = UserDefaults.standard.string(forKey: "siteAddress.\(value)") ?? definition.defaultAddress
        guard let candidate = try? definition.makeProvider(address) else { return }
        refreshRevision += 1
        isRefreshing = false
        providerID = value
        siteAddress = address
        provider = candidate
        session = nil
        selectedTab = 0
        clearSnapshot()
        authMethod = AuthMethod(rawValue: UserDefaults.standard.string(forKey: "authMethod.\(candidate.manifest.id)") ?? "")
            ?? candidate.manifest.supportedAuthMethods.first ?? .apiKey
        username = ""
        secret = ""
        revealsSecret = false
        loginStatus = nil
        lastError = nil
        UserDefaults.standard.set(value, forKey: "providerID")
        Task { await loadSavedCredentials() }
    }

    func updateMenuBarDisplay(_ value: MenuBarDisplay) {
        menuBarDisplay = value
        UserDefaults.standard.set(value.rawValue, forKey: "menuBarDisplay")
    }

    private func fetchTodayRecords(session: AuthSession, provider: any UsageProvider) async throws -> [UsageRecord] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let startOfToday = calendar.startOfDay(for: Date())
        var all: [UsageRecord] = []
        for page in 1...100 {
            let result = try await provider.fetchRecentUsage(session: session, query: UsageQuery(page: page, pageSize: 100))
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
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.refreshSeconds ?? 60))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    deinit { timer?.cancel() }
}
