import AppKit
import SwiftUI

// Disambiguate the property wrapper from the SDK's same-named State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct SettingsView: View {
    @ObservedObject var store: MonitorStore
    @FocusState private var focusedField: Field?
    @ViewState private var customRefreshText = ""
    @ViewState private var customRefreshError: String?
    @ViewState private var usesCustomRefresh = false
    @ViewState private var selectedSection: SettingsSection
    @ViewState private var showsAdvancedAddress = false
    @ViewState private var sitePendingHiding: SiteProfile?
    enum SettingsSection: String, CaseIterable, Identifiable {
        case connection = "连接", refresh = "刷新", menuBar = "菜单栏"
        var id: String { rawValue }
    }

    init(store: MonitorStore, section: SettingsSection = .connection) {
        self.store = store
        _selectedSection = ViewState(initialValue: section)
    }

    private enum Field { case username, secret, refreshInterval }

    private var isCurrentSite: Bool {
        guard let candidate = try? ProviderCatalog.definition(for: store.providerID).makeProvider(store.siteAddress) else { return false }
        return candidate.manifest.id == store.provider.manifest.id
    }

    private var selectedProvider: any UsageProvider {
        let definition = ProviderCatalog.definition(for: store.providerID)
        return (try? definition.makeProvider(store.siteAddress))
            ?? (try? definition.makeProvider(definition.defaultAddress))
            ?? store.provider
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.title3.weight(.semibold))
                Spacer()
                Label(store.session != nil && isCurrentSite ? "已登录" : "未登录", systemImage: store.session != nil && isCurrentSite ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(store.session != nil && isCurrentSite ? MonitorPalette.balance : Color.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            Divider()
            Picker("设置分类", selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if selectedSection == .connection {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("站点与登录").font(.headline)
                        Text("站点别名").font(.caption).foregroundStyle(.secondary)
                        TextField("例如：知遥 API", text: Binding(
                            get: { store.siteAlias }, set: { store.updateSiteAlias($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Text("别名只用于应用显示，不会改变连接地址。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button {
                                store.beginAddingSite()
                                showsAdvancedAddress = true
                            } label: {
                                Label("添加站点", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            if (try? ProviderCatalog.definition(for: store.providerID).makeProvider(store.siteAddress)) != nil,
                               !store.currentSiteProfileIsBuiltIn,
                               !store.currentSiteProfileIsSaved {
                                Button {
                                    store.addCurrentSiteProfile()
                                } label: {
                                    Label("保存为站点", systemImage: "plus")
                                }
                                .buttonStyle(.bordered)
                            }
                            if !store.currentSiteProfileIsBuiltIn && store.currentSiteProfileIsSaved {
                                Label("已保存为独立站点", systemImage: "checkmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !store.siteProfiles.filter(\.isBuiltIn).isEmpty {
                            Divider().padding(.vertical, 3)
                            Text("内置站点").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            ForEach(store.siteProfiles.filter(\.isBuiltIn)) { profile in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.alias).font(.body.weight(.medium)).lineLimit(1)
                                        Text(ProviderCatalog.definition(for: profile.providerID).name)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 6)
                                    Button { sitePendingHiding = profile } label: {
                                        Image(systemName: "eye.slash")
                                            .frame(width: MonitorLayout.iconTarget, height: MonitorLayout.iconTarget)
                                    }
                                    .buttonStyle(.plain)
                                    .help("隐藏 \(profile.alias)")
                                    .accessibilityLabel("隐藏内置站点 \(profile.alias)")
                                    .disabled(!store.canHideSite || store.isRefreshing || store.isLoggingIn)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        if !store.customSiteProfiles.filter({ !$0.isHidden }).isEmpty {
                            Divider().padding(.vertical, 3)
                            Text("自定义站点").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            ForEach(store.customSiteProfiles.filter { !$0.isHidden }) { profile in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.alias).font(.body.weight(.medium)).lineLimit(1)
                                        Text("\(ProviderCatalog.definition(for: profile.providerID).name) · \(profile.address)")
                                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    Button { sitePendingHiding = profile } label: {
                                        Image(systemName: "eye.slash")
                                            .frame(width: MonitorLayout.iconTarget, height: MonitorLayout.iconTarget)
                                    }
                                    .buttonStyle(.plain)
                                    .help("隐藏 \(profile.alias)")
                                    .accessibilityLabel("隐藏站点 \(profile.alias)")
                                    .disabled(!store.canHideSite || store.isRefreshing || store.isLoggingIn)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        if !store.hiddenSiteProfiles.isEmpty {
                            Divider().padding(.vertical, 3)
                            Text("已隐藏站点").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            ForEach(store.hiddenSiteProfiles) { profile in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.alias).font(.body.weight(.medium)).lineLimit(1)
                                        Text("\(ProviderCatalog.definition(for: profile.providerID).name) · \(profile.address)")
                                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    Button { store.restoreSiteProfile(profile) } label: {
                                        Label("恢复", systemImage: "eye")
                                    }
                                    .buttonStyle(.bordered)
                                    .help("恢复 \(profile.alias)")
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        if ProviderCatalog.all.count > 1 {
                            Picker("站点类型", selection: Binding(get: { store.providerID }, set: { store.updateProviderID($0) })) {
                                ForEach(ProviderCatalog.all, id: \.id) { definition in
                                    Text(definition.name).tag(definition.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        DisclosureGroup("自定义服务地址", isExpanded: $showsAdvancedAddress) {
                            TextField("https://example.com", text: Binding(
                                get: { store.siteAddress }, set: { store.updateSiteAddress($0) }
                            ))
                                .font(.body.monospaced())
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("服务地址")
                                .padding(.top, 6)
                            if (try? ProviderCatalog.definition(for: store.providerID).makeProvider(store.siteAddress)) == nil {
                                Label("请输入完整服务地址，例如 https://example.com", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                        .font(.caption)
                        if !showsAdvancedAddress {
                            Text(store.siteAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if selectedProvider.manifest.supportedAuthMethods.count > 1 {
                            Picker("登录方式", selection: $store.authMethod) {
                                ForEach(selectedProvider.manifest.supportedAuthMethods) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        if store.providerID == "zhiyao" && store.authMethod == .apiKey {
                            Text("API Key 仅提供共享余额和该 Key 费用；Token 明细请使用账号密码。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if store.authMethod == .password {
                            Text(store.providerID == "cbc-v2" ? "邮箱" : "账号")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField(store.providerID == "cbc-v2" ? "邮箱" : "账号", text: $store.username)
                                .textContentType(store.providerID == "cbc-v2" ? .emailAddress : .username)
                                .focused($focusedField, equals: .username)
                        }
                        Text(store.authMethod == .apiKey ? "API Key" : "密码")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Group {
                                if store.revealsSecret {
                                    TextField(store.authMethod == .apiKey ? "API Key" : "密码", text: $store.secret)
                                } else {
                                    SecureField(store.authMethod == .apiKey ? "API Key" : "密码", text: $store.secret)
                                }
                            }
                            .focused($focusedField, equals: .secret)
                            .onSubmit { Task { await store.login() } }
                            Button { store.revealsSecret.toggle() } label: {
                                Image(systemName: store.revealsSecret ? "eye.slash" : "eye")
                                    .frame(width: MonitorLayout.iconTarget, height: MonitorLayout.iconTarget)
                            }
                            .buttonStyle(.plain)
                            .help(store.revealsSecret ? "隐藏密钥" : "显示密钥")
                            .accessibilityLabel(store.revealsSecret ? "隐藏密钥" : "显示密钥")
                        }
                        HStack(spacing: 10) {
                            Button { Task { await store.login() } } label: {
                                HStack(spacing: 7) {
                                    if store.isLoggingIn { ProgressView().controlSize(.small) }
                                    Text(store.isLoggingIn ? "登录中…" : "登录并刷新")
                                }
                                .frame(width: 126)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MonitorPalette.balance)
                            .disabled(store.isLoggingIn || store.secret.isEmpty || (store.authMethod == .password && store.username.isEmpty) || (try? ProviderCatalog.definition(for: store.providerID).makeProvider(store.siteAddress)) == nil)
                            if store.session != nil && isCurrentSite {
                                Button("退出登录", role: .destructive) { store.logout() }
                            }
                            Spacer()
                        }
                        if let status = store.loginStatus, isCurrentSite {
                            Label(status, systemImage: store.lastError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(store.lastError == nil ? MonitorPalette.balance : Color.orange)
                        }
                        if let error = store.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(store.recoveryHint ?? "请检查登录信息和服务地址后重试。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    }
                    if selectedSection == .refresh {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("自动刷新").font(.headline)
                        Picker("间隔", selection: refreshOption) {
                            ForEach(RefreshPolicy.presets, id: \.self) { seconds in
                                Text(RefreshPolicy.title(for: seconds)).tag(String(Int(seconds)))
                            }
                            Text("自定义").tag("custom")
                        }
                        .pickerStyle(.menu)
                        if usesCustomRefresh {
                            HStack(spacing: 8) {
                                TextField("秒数", text: $customRefreshText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                    .focused($focusedField, equals: .refreshInterval)
                                    .accessibilityLabel("自定义刷新间隔，单位秒")
                                    .onSubmit { applyCustomRefresh() }
                                Text("秒")
                                    .foregroundStyle(.secondary)
                                Button("应用") { applyCustomRefresh() }
                                    .buttonStyle(.bordered)
                                Text("当前生效 \(Int(store.effectiveRefreshSeconds)) 秒")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let customRefreshError {
                                Text(customRefreshError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Text("建议不少于 15 秒，最短 5 秒；过于频繁可能触发站点限流。")
                            .font(.caption)
                            .foregroundStyle(store.refreshSeconds < RefreshPolicy.recommendedSeconds ? Color.orange : .secondary)
                        Text("面板打开时按设置刷新；后台至少 60 秒，低电量模式后台至少 5 分钟。趋势和倍率每 5 分钟更新，手动刷新立即更新。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { Task { await store.refresh() } } label: {
                            Label("立即刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.session == nil || !isCurrentSite || store.isRefreshing)
                        Divider().padding(.vertical, 4)
                        Toggle("分组倍率变化时发送系统通知", isOn: Binding(
                            get: { store.rateNotificationsEnabled }, set: { store.updateRateNotifications($0) }
                        ))
                        .font(.caption)
                        Text("倍率每 5 分钟检查，通知可能延迟约 5 分钟。首次读取建立基准；关闭通知后仍保留变化记录。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let message = store.rateNotificationMessage {
                            Text(message).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    }
                    if selectedSection == .menuBar {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("菜单栏").font(.headline)
                        Text("选择常驻菜单栏的指标，点击菜单栏仍可查看完整概览。")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("显示内容", selection: Binding(get: { store.menuBarDisplay }, set: { store.updateMenuBarDisplay($0) })) {
                            ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("TokenMonitor · 版本 \(appVersion)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("退出应用", role: .destructive) { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: MonitorLayout.settingsWidth, height: MonitorLayout.settingsHeight)
        .background(MonitorMaterial(material: .popover))
        .onAppear {
            focusedField = store.authMethod == .password ? .username : .secret
            usesCustomRefresh = !RefreshPolicy.presets.contains(store.refreshSeconds)
            customRefreshText = String(Int(store.refreshSeconds))
        }
        .onDisappear { store.revealsSecret = false }
        .onChange(of: selectedSection) { _, _ in focusedField = nil }
        .onChange(of: store.authMethod) { _, _ in
            store.secret = ""
            store.revealsSecret = false
            focusedField = store.authMethod == .password ? .username : .secret
        }
        .onChange(of: store.providerID) { _, _ in
            focusedField = store.authMethod == .password ? .username : .secret
        }
        .confirmationDialog("隐藏自定义站点？", item: $sitePendingHiding, titleVisibility: .visible) { profile in
            Button("隐藏 \(profile.alias)") { store.hideSiteProfile(profile) }
            Button("取消", role: .cancel) {}
        } message: { profile in
            Text("\(profile.alias) 会从切换列表隐藏，但连接配置、登录凭据、别名和倍率变化记录都会保留，可在设置中恢复。")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private var refreshOption: Binding<String> {
        Binding(
            get: {
                usesCustomRefresh ? "custom" : String(Int(store.refreshSeconds))
            },
            set: { value in
                if value == "custom" {
                    usesCustomRefresh = true
                    customRefreshText = String(Int(store.refreshSeconds))
                    customRefreshError = nil
                    focusedField = .refreshInterval
                } else if let seconds = Double(value) {
                    usesCustomRefresh = false
                    store.updateRefreshSeconds(seconds)
                    customRefreshError = nil
                }
            }
        )
    }

    private func applyCustomRefresh() {
        guard let seconds = RefreshPolicy.parse(customRefreshText) else {
            customRefreshError = "请输入 5 到 86400 之间的整数秒数。"
            return
        }
        store.updateRefreshSeconds(seconds)
        customRefreshError = nil
    }
}
