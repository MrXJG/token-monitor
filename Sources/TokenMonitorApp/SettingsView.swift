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
                Label(store.session != nil && isCurrentSite ? "已连接" : "未连接", systemImage: store.session != nil && isCurrentSite ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(store.session != nil && isCurrentSite ? MonitorPalette.balance : Color.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("站点与登录").font(.headline)
                        if ProviderCatalog.all.count > 1 {
                            Picker("站点类型", selection: Binding(get: { store.providerID }, set: { store.updateProviderID($0) })) {
                                ForEach(ProviderCatalog.all, id: \.id) { definition in
                                    Text(definition.name).tag(definition.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("服务地址").font(.caption).foregroundStyle(.secondary)
                            TextField("https://example.com", text: $store.siteAddress)
                                .font(.body.monospaced())
                                .textFieldStyle(.roundedBorder)
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
                            .disabled(store.isLoggingIn || store.secret.isEmpty || (store.authMethod == .password && store.username.isEmpty))
                            if store.session != nil && isCurrentSite {
                                Button("退出登录", role: .destructive) { store.logout() }
                            }
                            Spacer()
                        }
                        if let status = store.loginStatus, isCurrentSite {
                            Label(status, systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(MonitorPalette.balance)
                        }
                        if let error = store.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
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
                                Text("当前 \(Int(store.refreshSeconds)) 秒")
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
                        Button { Task { await store.refresh() } } label: {
                            Label("立即刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.session == nil || !isCurrentSite || store.isRefreshing)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("菜单栏").font(.headline)
                        Picker("显示内容", selection: Binding(get: { store.menuBarDisplay }, set: { store.updateMenuBarDisplay($0) })) {
                            ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("TokenMonitor").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出应用", role: .destructive) { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: MonitorLayout.settingsWidth, height: MonitorLayout.settingsHeight)
        .background(MonitorMaterial(material: .popover))
        .onAppear {
            focusedField = .secret
            usesCustomRefresh = !RefreshPolicy.presets.contains(store.refreshSeconds)
            customRefreshText = String(Int(store.refreshSeconds))
        }
        .onDisappear { store.revealsSecret = false }
        .onChange(of: store.authMethod) { _, _ in
            store.secret = ""
            store.revealsSecret = false
            focusedField = store.authMethod == .password ? .username : .secret
        }
        .onChange(of: store.providerID) { _, _ in
            focusedField = store.authMethod == .password ? .username : .secret
        }
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
