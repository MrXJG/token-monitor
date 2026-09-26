import AppKit
import Combine
import SwiftUI

@main
@MainActor
enum TokenMonitorApp {
    private static let delegate = TokenMonitorDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class TokenMonitorDelegate: NSObject, NSApplicationDelegate {
    private let store = MonitorStore()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var observation: AnyCancellable?
    private var menuTrackingObserver: NSObjectProtocol?
    private var shouldClosePopoverAfterMenu = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        configureMainMenu()
        configureStatusItem()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: MonitorLayout.panelWidth, height: MonitorLayout.panelHeight)
        popover.contentViewController = NSHostingController(rootView: OverviewView(
            store: store,
            onSettings: { [weak self] in self?.showSettings() },
            onProviderSwitch: { [weak self] in
                // SwiftUI's Menu invokes this action while NSMenu is still
                // tracking. Defer the close until didEndTracking so the menu
                // cannot restore a stale popover window after selection.
                self?.requestPopoverCloseAfterMenu()
            }
        ))
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopoverAfterMenuTracking()
            }
        }
        observation = store.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.updateStatusTitle() }
        }
        updateStatusTitle()
        if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            showSettings()
        } else if ProcessInfo.processInfo.arguments.contains("--show-overview"), let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "TokenMonitor")
        appMenu.addItem(withTitle: "退出 TokenMonitor", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "TokenMonitor")
        button.imagePosition = .imageLeft
        button.target = self
        button.action = #selector(handleStatusClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "TokenMonitor"
    }

    @objc private func handleStatusClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showContextMenu(relativeTo: sender)
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "刷新", action: #selector(refresh), keyEquivalent: "r").target = self
        let providers = NSMenu(title: "切换站点")
        for definition in ProviderCatalog.all {
            let item = providers.addItem(withTitle: definition.name, action: #selector(switchProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = definition.id
            item.state = store.providerID == definition.id ? .on : .off
        }
        let providerItem = NSMenuItem(title: "切换站点", action: nil, keyEquivalent: "")
        providerItem.submenu = providers
        menu.addItem(providerItem)
        menu.addItem(withTitle: "设置…", action: #selector(showSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 TokenMonitor", action: #selector(quit), keyEquivalent: "q").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    @objc private func refresh() { Task { await store.refresh() } }
    @objc private func switchProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.updateProviderID(id)
    }
    @objc private func showSettingsAction() { showSettings() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func showSettings() {
        shouldClosePopoverAfterMenu = false
        popover.close()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: MonitorLayout.settingsWidth, height: MonitorLayout.settingsHeight),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "TokenMonitor 设置"
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    private func requestPopoverCloseAfterMenu() {
        shouldClosePopoverAfterMenu = true

        // The native notification is the authoritative boundary. This
        // fallback covers macOS versions where SwiftUI's private menu does
        // not forward didEndTracking to the default notification center.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.shouldClosePopoverAfterMenu else { return }
            self.closePopoverAfterMenuTracking()
        }
    }

    private func closePopoverAfterMenuTracking() {
        guard shouldClosePopoverAfterMenu else { return }
        shouldClosePopoverAfterMenu = false
        guard popover.isShown else { return }
        popover.close()
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        button.toolTip = "TokenMonitor · \(store.provider.manifest.name)"
        guard let overview = store.overview else {
            button.title = "Token"
            return
        }
        let hasUsage = store.activeCapabilities.contains(.requestDetails)
        switch store.menuBarDisplay {
        case .balance:
            button.title = overview.availableBalance.map { "$\($0.formatted(.number.precision(.fractionLength(2))))" } ?? "余额 -"
        case .summary:
            let balance = overview.availableBalance.map { "$\($0.formatted(.number.precision(.fractionLength(2))))" } ?? "余额 -"
            button.title = hasUsage ? "\(balance) · \(compactTokens(overview.calculatedTokens))" : balance
        case .todayTokens:
            button.title = hasUsage ? "\(compactTokens(overview.calculatedTokens)) Token" : "Token -"
        case .inputTokens:
            button.title = hasUsage ? "I \(compactTokens(overview.inputTokens))" : "I -"
        case .outputTokens:
            button.title = hasUsage ? "O \(compactTokens(overview.outputTokens))" : "O -"
        case .cacheHitRate:
            button.title = hasUsage ? (overview.cacheHitRate.map { "缓存 \(Int($0 * 100))%" } ?? "缓存 -") : "缓存 -"
        case .requests:
            button.title = hasUsage ? "\(overview.todayRequests) 次" : "请求 -"
        case .todayCost:
            button.title = overview.todayCost.map { "今日 $\($0.formatted(.number.precision(.fractionLength(2))))" } ?? "今日费用 -"
        }
    }

    private func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 10_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return count.formatted()
    }

}
