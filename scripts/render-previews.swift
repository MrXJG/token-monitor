import AppKit
import SwiftUI

@main
@MainActor
struct RenderPreviews {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let full = sampleStore(provider: CBCProvider(), method: .password)
        try render(OverviewView(store: full, onSettings: {}, onProviderSwitch: {}), named: "overview-light", scheme: .light, in: directory)
        try render(OverviewView(store: full, onSettings: {}, onProviderSwitch: {}), named: "overview-dark", scheme: .dark, in: directory)
        full.selectedTab = 1
        try render(OverviewView(store: full, onSettings: {}, onProviderSwitch: {}), named: "requests-light", scheme: .light, in: directory)
        full.recentRecords = []
        try render(OverviewView(store: full, onSettings: {}, onProviderSwitch: {}), named: "requests-empty", scheme: .light, in: directory)

        let key = sampleStore(provider: ZhiyaoProvider(), method: .apiKey)
        key.trend = []
        try render(OverviewView(store: key, onSettings: {}, onProviderSwitch: {}), named: "key-light", scheme: .light, in: directory)

        let empty = MonitorStore(provider: CBCProvider(), loadSavedCredentials: false)
        empty.providerID = "cbc"
        empty.session = AuthSession(token: "preview", expiresAt: nil)
        empty.lastError = "读取数据失败，请稍后重试"
        try render(OverviewView(store: empty, onSettings: {}, onProviderSwitch: {}), named: "error-light", scheme: .light, in: directory)
        empty.lastError = nil
        empty.session = nil
        try render(OverviewView(store: empty, onSettings: {}, onProviderSwitch: {}), named: "overview-empty", scheme: .light, in: directory)

        full.authMethod = .password
        try render(SettingsView(store: full), named: "settings-password", scheme: .light, in: directory)
        try render(SettingsView(store: full), named: "settings-dark", scheme: .dark, in: directory)
        full.loginStatus = "登录成功，数据已更新"
        try render(SettingsView(store: full), named: "settings-success", scheme: .light, in: directory)
        full.loginStatus = nil
        full.lastError = "账号或密码错误"
        try render(SettingsView(store: full), named: "settings-error", scheme: .light, in: directory)
    }

    private static func sampleStore(provider: any UsageProvider, method: AuthMethod) -> MonitorStore {
        let store = MonitorStore(provider: provider, loadSavedCredentials: false)
        store.providerID = provider.manifest.id
        store.siteAddress = provider.manifest.id == "cbc" ? "https://cbc.icu" : "https://zyapi.tuluo.top:8888"
        store.session = AuthSession(token: "preview", expiresAt: nil, method: method)
        store.lastUpdated = Date(timeIntervalSince1970: 1_779_624_000)
        store.overview = UsageOverview(
            availableBalance: Decimal(string: "42.16"), balance: Decimal(string: "46.20"),
            frozenBalance: Decimal(string: "0.15"), usedBalance: Decimal(string: "8.62"),
            totalUncoveredAmount: Decimal(string: "0.40"), requestCount: 321,
            todayRequests: 32, totalTokens: 1_224_325, inputTokens: 386_420,
            outputTokens: 74_360, cacheReadTokens: 91_220, cacheWriteTokens: 12_000,
            reasoningTokens: 8_000, cost: Decimal(string: "8.22"),
            todayCost: Decimal(string: "2.38"), averageFirstTokenTimeMs: 420,
            averageResponseTimeMs: 2_200, apiKeyCount: 2, updatedAt: Date()
        )
        store.recentRecords = [
            UsageRecord(
                id: "1", requestId: "req-example-01", requestTime: Date(), modelName: "gpt-6-sol",
                inputTokens: 12_450, outputTokens: 3_162, cacheReadTokens: 5_430,
                cacheWriteTokens: 870, reasoningTokens: 330, cost: Decimal(string: "0.0824"),
                status: "成功", errorMessage: nil, keyName: "工作密钥", relayMode: "responses",
                reasoningEffort: "high", groupName: "default", isStream: true,
                durationMs: 2_450, timeToFirstTokenMs: 360, upstreamFirstEventMs: 280
            ),
            UsageRecord(
                id: "2", requestId: "req-example-02", requestTime: Date().addingTimeInterval(-3600),
                modelName: "very-long-model-name-for-layout-verification", inputTokens: 0,
                outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: nil, reasoningTokens: 0,
                cost: nil, status: "失败", errorMessage: "上游连接超时", keyName: "工作密钥",
                relayMode: nil, reasoningEffort: nil, groupName: nil, isStream: nil,
                durationMs: nil, timeToFirstTokenMs: nil, upstreamFirstEventMs: nil
            )
        ]
        store.trend = (0..<7).map { index in
            UsageBucket(
                id: "day-\(index)", date: Date().addingTimeInterval(Double(index - 6) * 86_400),
                requestCount: 13 + index, inputTokens: 20_000 + index * 2_100,
                outputTokens: 4_000 + index * 350, totalTokens: 24_000 + index * 2_450,
                cacheReadTokens: 3_000 + index * 400, cacheWriteTokens: nil,
                cost: Decimal(string: "1.\(index + 2)")
            )
        }
        store.modelUsage = [
            ModelUsage(id: "gpt-6-sol", modelName: "gpt-6-sol", requestCount: 20,
                       totalTokens: 293_456, cacheReadTokens: 61_420, cost: Decimal(string: "1.95")!)
        ]
        return store
    }

    private static func render<V: View>(_ view: V, named name: String, scheme: ColorScheme, in directory: URL) throws {
        let size = name.hasPrefix("settings")
            ? NSSize(width: MonitorLayout.settingsWidth, height: MonitorLayout.settingsHeight)
            : NSSize(width: MonitorLayout.panelWidth, height: MonitorLayout.panelHeight)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "RenderPreviews", code: 1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RenderPreviews", code: 2)
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}
