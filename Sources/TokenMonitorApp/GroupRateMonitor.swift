import Foundation
import UserNotifications

struct GroupRateChange: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let groupName: String
    let previous: Decimal
    let current: Decimal
    let detectedAt: Date
    var summary: String { "\(groupName)：\(GroupRate.format(previous)) → \(GroupRate.format(current))" }
}

/// Baselines are isolated by site and authenticated account, never by a rotating token.
@MainActor
struct GroupRateTracker {
    let defaults: UserDefaults
    private struct Baseline: Codable {
        var rates: [String: Decimal]
        var changes: [GroupRateChange]
    }
    private func key(_ scope: String) -> String { "groupRateBaseline.\(scope)" }
    private func read(_ scope: String) -> Baseline? {
        defaults.data(forKey: key(scope)).flatMap { try? JSONDecoder().decode(Baseline.self, from: $0) }
    }
    func history(scope: String) -> [GroupRateChange] { read(scope)?.changes ?? [] }
    func observe(_ groups: [GroupRate], scope: String, now: Date = .now) -> [GroupRateChange] {
        let previous = read(scope)
        let changes = groups.compactMap { group -> GroupRateChange? in
            guard let old = previous?.rates[group.id], old != group.multiplier else { return nil }
            return GroupRateChange(id: UUID(), groupName: group.name, previous: old,
                                   current: group.multiplier, detectedAt: now)
        }
        var rates = previous?.rates ?? [:]
        for group in groups { rates[group.id] = group.multiplier }
        if let previous, previous.rates == rates, changes.isEmpty { return [] }
        let baseline = Baseline(rates: rates, changes: Array((changes + (previous?.changes ?? [])).prefix(20)))
        if let data = try? JSONEncoder().encode(baseline), data != defaults.data(forKey: key(scope)) {
            defaults.set(data, forKey: key(scope))
        }
        return changes
    }
}

@MainActor
final class RateNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private var authorizationTask: Task<String?, Never>?
    override init() {
        super.init()
        // Command-line fixtures and preview renderers have no notification bundle.
        if Bundle.main.bundleIdentifier != nil { center.delegate = self }
    }
    func requestAuthorization() async -> String? {
        guard Bundle.main.bundleIdentifier != nil else { return "请在已安装的应用中开启通知。" }
        if let authorizationTask { return await authorizationTask.value }
        let authorizationTask = Task<String?, Never> {
        let status = await center.notificationSettings().authorizationStatus
        if status == .authorized || status == .provisional { return nil }
        if status == .denied { return "系统通知未获允许，倍率变化仍会保留在面板中。" }
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            return allowed ? nil : "系统通知未获允许，倍率变化仍会保留在面板中。"
        } catch { return "系统通知暂不可用，倍率变化仍会保留在面板中。" }
        }
        self.authorizationTask = authorizationTask
        let message = await authorizationTask.value
        self.authorizationTask = nil
        return message
    }
    func send(_ changes: [GroupRateChange], site: String) async -> String? {
        guard !changes.isEmpty else { return nil }
        if let message = await requestAuthorization() { return message }
        let content = UNMutableNotificationContent()
        content.title = "\(site) 分组倍率变化"
        content.body = changes.map(\.summary).joined(separator: "；")
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return nil
        } catch { return "系统通知发送失败，倍率变化已保留在面板中。" }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
