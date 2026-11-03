import AppKit
import Foundation
import SwiftUI
import Charts

private typealias ViewState<Value> = SwiftUI.State<Value>

struct MetricTile: View {
    let title: String
    let value: String
    let detail: String?
    let tint: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 54, alignment: .topLeading)
    }
}

struct OverviewView: View {
    @ObservedObject var store: MonitorStore
    let onSettings: () -> Void
    let onProviderSwitch: () -> Void
    @ViewState private var showsRateDetails = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, MonitorLayout.panelGutter)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            if store.activeCapabilities.contains(.requestDetails) {
                Picker("视图", selection: $store.selectedTab) {
                    Text("概览").tag(0)
                    Text("请求记录").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: MonitorLayout.panelWidth - (MonitorLayout.panelGutter * 2))
                .padding(.horizontal, MonitorLayout.panelGutter)
                .padding(.vertical, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: MonitorLayout.sectionGap) {
                    if store.hasUnreadRateChange, let change = store.rateChanges.first {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("分组倍率已变化", systemImage: "bell.badge")
                                .font(.caption.weight(.semibold))
                            Text(change.summary).font(.caption.monospacedDigit())
                            HStack {
                                Button("查看变化") { showsRateDetails = true }
                                Button("知道了") { store.acknowledgeRateChanges() }
                            }.font(.caption)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(MonitorPalette.warningSurface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let error = store.lastError {
                        VStack(alignment: .leading, spacing: 7) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.primary)
                            if let hint = store.recoveryHint { Text(hint).foregroundStyle(.secondary) }
                            HStack {
                                Button("重试") { Task { await store.refresh() } }
                                    .disabled(store.isRefreshing || store.isLoadingMoreRecords || store.session == nil)
                                Button("连接设置", action: onSettings)
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(MonitorPalette.warningSurface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if store.selectedTab == 1, store.activeCapabilities.contains(.requestDetails) {
                        RequestRecordsView(store: store)
                    } else if let data = store.overview {
                        overviewGrid(data)
                        if store.activeCapabilities.contains(.usageTrend), !store.trend.isEmpty {
                            if let error = store.trendError {
                                Label("趋势未更新：\(error)", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            TrendStripView(buckets: store.trend)
                        }
                        if store.activeCapabilities.contains(.modelBreakdown) { modelSection }
                    } else if store.isRefreshing {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在读取用量").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: store.lastError == nil ? "chart.bar.xaxis" : "exclamationmark.arrow.triangle.2.circlepath")
                                .font(.system(size: 26)).foregroundStyle(.secondary)
                            Text(store.lastError == nil ? "尚未连接" : "数据尚不可用").font(.headline)
                            if store.session == nil {
                                Button("打开设置", action: onSettings)
                            } else {
                                Button("重试") { Task { await store.refresh() } }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    }
                }
                .padding(.horizontal, MonitorLayout.panelGutter)
                .padding(.vertical, 16)
            }
        }
        .frame(width: MonitorLayout.panelWidth, height: store.panelHeight)
        .background(MonitorMaterial(material: .popover))
        .onChange(of: store.provider.manifest.id) { _, _ in showsRateDetails = false }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                Text(store.displaySiteAlias)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("当前站点：\(store.displaySiteAlias)")
                if store.activeCapabilities.contains(.groupRates) {
                    Button { showsRateDetails.toggle() } label: {
                        HStack(spacing: 3) {
                            if let group = store.currentGroupRate {
                                Text(group.name).lineLimit(1).truncationMode(.middle)
                                Text((group.peakDescription == nil ? "" : "基础 ") + group.displayMultiplier).fixedSize()
                            } else if let latest = store.recentRecords.first, let name = latest.groupName {
                                Text(name).lineLimit(1).truncationMode(.middle)
                                if let multiplier = latest.groupMultiplier {
                                    Text(GroupRate.format(multiplier)).fixedSize()
                                }
                            } else {
                                Text(store.groupRatesError != nil ? "倍率未更新" : (store.groupRates.isEmpty ? (store.isRefreshing ? "读取倍率…" : "暂无倍率") : "\(store.groupRates.count) 个分组"))
                            }
                            if store.hasUnreadRateChange { Image(systemName: "bell.badge.fill") }
                            if store.groupRatesError != nil { Image(systemName: "exclamationmark.triangle") }
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }.font(.caption.monospacedDigit())
                        .foregroundStyle(store.hasUnreadRateChange || store.groupRatesError != nil ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("最近请求分组及当前倍率；点击查看全部分组倍率")
                    .accessibilityLabel("查看分组倍率")
                    .popover(isPresented: $showsRateDetails) { GroupRatesView(store: store) }
                } else if let name = store.recentRecords.first?.groupName {
                    HStack(spacing: 3) {
                        Text(name).lineLimit(1).truncationMode(.middle)
                        if let multiplier = store.recentRecords.first?.groupMultiplier {
                            Text(GroupRate.format(multiplier)).monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .help("最近请求分组及记录倍率；此站点尚未提供独立的当前倍率接口")
                }
                }
                statusSummary
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                providerSwitcher
                Button { Task { await store.refresh() } } label: {
                    Group {
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }.frame(width: MonitorLayout.iconTarget, height: MonitorLayout.iconTarget)
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing || store.isLoadingMoreRecords || store.session == nil)
                .help("刷新当前站点")
                .accessibilityLabel("刷新当前站点")
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: MonitorLayout.iconTarget, height: MonitorLayout.iconTarget)
                }
                .buttonStyle(.plain)
                .help("设置")
                .accessibilityLabel("设置")
            }
        }
    }

    private var statusSummary: some View {
        Group {
            if store.isPanelVisible {
                TimelineView(PeriodicTimelineSchedule(from: .now, by: 1)) { (context: TimelineViewDefaultContext) in
                    statusSummaryContent(date: context.date)
                }
            } else {
                statusSummaryContent(date: .now)
            }
        }
    }

    private func statusSummaryContent(date: Date) -> some View {
        HStack(spacing: 5) {
            Text(connectionStatus)
                .foregroundStyle(store.lastError == nil ? Color.secondary : Color.orange)
            Text("·")
            Text((store.selectedTab == 1 ? store.recordsUpdated : store.overviewUpdated).map {
                "更新于 \($0.formatted(.dateTime.hour().minute().second()))"
            } ?? "尚未更新")
            if store.session != nil, let next = store.nextRefreshDate, !store.isRefreshing {
                Text("· \(max(0, Int(ceil(next.timeIntervalSince(date))))) 秒后刷新")
            }
        }
        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var connectionStatus: String {
        store.isRefreshing ? "刷新中" : (store.lastError != nil ? (store.session == nil ? "连接异常" : "部分未更新") : (store.session == nil ? "未连接" : "已连接"))
    }

    private var providerSwitcher: some View {
        Menu {
            ForEach(store.siteProfiles) { profile in
                Button {
                    store.selectSiteProfile(profile)
                    onProviderSwitch()
                } label: {
                    HStack {
                        Text(profile.alias)
                        Spacer(minLength: 18)
                        if profile.providerID == store.providerID && profile.address == store.siteAddress {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .frame(width: MonitorLayout.iconTarget, height: MonitorLayout.iconTarget)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换站点")
        .accessibilityLabel("切换站点")
    }

    @ViewBuilder
    private func overviewGrid(_ data: UsageOverview) -> some View {
        let balance = data.availableBalance.map { "$\($0.formatted(.number.precision(.fractionLength(2...4))))" } ?? "-"
        let hitRate = data.cacheHitRate.map { "命中率 \(Int($0 * 100))%" }
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("可用余额").font(.caption).foregroundStyle(.secondary)
                    Text(balance)
                        .font(.system(size: 31, weight: .semibold, design: .rounded))
                        .foregroundStyle(MonitorPalette.balance)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(store.activeCapabilities.contains(.requestDetails) ? "今日费用" : "该 Key 今日费用")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(formatMoney(data.todayCost))
                        .font(.subheadline.weight(.medium)).monospacedDigit()
                }
            }
            Divider()
            if store.activeCapabilities.contains(.requestDetails) {
                HStack(alignment: .firstTextBaseline) {
                    Text("今日用量").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(data.calculatedTokens.formatted()) Token · \(data.todayRequests) 次请求")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], alignment: .leading, spacing: 10) {
                    MetricTile(title: "输入", value: data.inputTokens.formatted(), detail: nil, tint: MonitorPalette.input, symbol: "arrow.down.left")
                    MetricTile(title: "输出", value: data.outputTokens.formatted(), detail: nil, tint: MonitorPalette.output, symbol: "arrow.up.right")
                    MetricTile(title: "缓存读取", value: data.cacheReadTokens.formatted(), detail: hitRate, tint: MonitorPalette.cache, symbol: "tray.and.arrow.down")
                    MetricTile(title: "缓存写入", value: data.cacheWriteTokens.map { $0.formatted() } ?? "-", detail: data.cacheWriteTokens == nil ? "站点未提供" : nil, tint: .secondary, symbol: "tray.and.arrow.up")
                }
                if data.reasoningTokens > 0 {
                    HStack {
                        Text("推理 Token").foregroundStyle(.secondary)
                        Spacer()
                        Text(data.reasoningTokens.formatted()).monospacedDigit()
                    }.font(.caption)
                }
            } else {
                Text("该 API Key 可读取共享余额和 Key 费用；请求与 Token 明细需使用账号密码登录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            DisclosureGroup {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    summaryRow("账户余额", formatMoney(data.balance))
                    if store.activeCapabilities.contains(.requestDetails) {
                        summaryRow("冻结余额", formatMoney(data.frozenBalance))
                        summaryRow("累计请求", data.requestCount.formatted())
                        summaryRow("累计 Token", data.totalTokens.formatted())
                        summaryRow("累计应计", formatMoney(data.usedBalance))
                        summaryRow("累计实扣", formatMoney(data.cost))
                        summaryRow("未覆盖金额", formatMoney(data.totalUncoveredAmount))
                        summaryRow("API Key", data.apiKeyCount.formatted())
                        summaryRow("平均首 Token", formatMilliseconds(data.averageFirstTokenTimeMs))
                        summaryRow("平均响应", formatMilliseconds(data.averageResponseTimeMs))
                    }
                }.padding(.top, 8)
            } label: {
                HStack {
                    Text("账户累计")
                    Spacer()
                    Text("\(data.totalTokens.formatted()) Token")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日各模型用量").font(.subheadline.weight(.semibold))
            Text("按模型汇总今天的成功请求")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if store.modelUsage.isEmpty {
                Text("暂无模型统计").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.modelUsage) { model in
                    HStack(alignment: .top, spacing: 12) {
                        Text(model.modelName)
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(model.totalTokens.formatted()) Token")
                                .font(.caption.monospacedDigit())
                            Text("\(model.requestCount) 次请求 · \(formatMoney(model.cost))")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            if model.cacheReadTokens > 0 {
                                Text("缓存读取 \(model.cacheReadTokens.formatted())")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    private func formatMoney(_ value: Decimal?) -> String {
        guard let value else { return "-" }
        return "$\(value.formatted(.number.precision(.fractionLength(4))))"
    }

    private func formatMilliseconds(_ value: Double?) -> String {
        guard let value else { return "-" }
        return value >= 1000 ? String(format: "%.1fs", value / 1000) : "\(Int(value))ms"
    }
}

struct TrendStripView: View {
    let buckets: [UsageBucket]
    @ViewState private var hoveredID: String?
    @ViewState private var pinnedID: String?
    @FocusState private var chartFocused: Bool
    init(buckets: [UsageBucket], selectedID: String? = nil) {
        self.buckets = buckets
        _pinnedID = ViewState(initialValue: selectedID)
    }
    private var showsCost: Bool { buckets.allSatisfy { $0.totalTokens == 0 && $0.cost != nil } }
    private var selected: UsageBucket? { buckets.first { $0.id == (hoveredID ?? pinnedID) } }
    private func amount(_ bucket: UsageBucket) -> Double {
        showsCost ? NSDecimalNumber(decimal: bucket.cost ?? .zero).doubleValue : Double(bucket.totalTokens)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(showsCost ? "近 \(buckets.count) 天费用" : "近 \(buckets.count) 天 Token 用量")
                .font(.subheadline.weight(.semibold))
            Text("悬停查看 · 点击固定 · 方向键切换日期")
                .font(.caption2).foregroundStyle(.secondary)
            Chart {
                ForEach(buckets) { bucket in
                    LineMark(x: .value("日期", bucket.date), y: .value(showsCost ? "费用" : "Token", amount(bucket)))
                        .foregroundStyle(MonitorPalette.input)
                    PointMark(x: .value("日期", bucket.date), y: .value("用量", amount(bucket)))
                        .foregroundStyle(MonitorPalette.input)
                }
                if let selected {
                    RuleMark(x: .value("选中日期", selected.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                    PointMark(x: .value("日期", selected.date), y: .value("用量", amount(selected)))
                        .foregroundStyle(MonitorPalette.balance).symbolSize(55)
                }
            }
            .chartXScale(domain: (buckets.map(\.date).min() ?? .now).addingTimeInterval(-43_200)...(buckets.map(\.date).max() ?? .now).addingTimeInterval(43_200))
            .chartYScale(domain: 0...max(1, (buckets.map(amount).max() ?? 1) * 1.12))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.28))
                    AxisTick().foregroundStyle(.secondary.opacity(0.45))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(formatAxisValue(amount))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: buckets.map(\.date)) { _ in
                    AxisValueLabel(format: .dateTime.day())
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let position): hoveredID = nearestID(position.x, proxy: proxy, geometry: geometry)
                            case .ended: hoveredID = nil
                            }
                        }
                        .onTapGesture { position in
                            pinnedID = nearestID(position.x, proxy: proxy, geometry: geometry)
                            chartFocused = true
                        }
                }
            }
            .overlay(alignment: .topTrailing) {
                if let selected { tooltip(selected).allowsHitTesting(false).padding(3) }
            }
            .frame(height: 150)
            .focusable().focused($chartFocused)
            .onMoveCommand { direction in
                let current = buckets.firstIndex { $0.id == (pinnedID ?? hoveredID) } ?? buckets.count - 1
                let offset = direction == .left ? -1 : (direction == .right ? 1 : 0)
                guard !buckets.isEmpty else { return }
                hoveredID = nil
                pinnedID = buckets[min(max(current + offset, 0), buckets.count - 1)].id
            }
            .onExitCommand { pinnedID = nil; hoveredID = nil }
            .accessibilityLabel("每日用量趋势，使用左右方向键选择日期")
        }
    }
    private func nearestID(_ x: CGFloat, proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard let frame = proxy.plotFrame else { return nil }
        let plot = geometry[frame]
        guard let date: Date = proxy.value(atX: min(max(x - plot.minX, 0), plot.width)) else { return nil }
        return buckets.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.id
    }
    private func tooltip(_ bucket: UsageBucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(bucket.date.formatted(.dateTime.month().day())).fontWeight(.semibold)
            if !showsCost {
                Text("\(bucket.totalTokens.formatted()) Token").fontWeight(.semibold)
                Text("输入 \(bucket.inputTokens.formatted()) · 输出 \(bucket.outputTokens.formatted())")
                Text("缓存读取 \(bucket.cacheReadTokens.formatted())")
                if let write = bucket.cacheWriteTokens { Text("缓存写入 \(write.formatted())") }
            }
            Text("\(bucket.requestCount) 次 · \(bucket.cost.map { "$" + $0.formatted(.number.precision(.fractionLength(4))) } ?? "费用未提供")")
        }
        .font(.caption2.monospacedDigit())
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    private func formatAxisValue(_ value: Double) -> String {
        guard !showsCost else {
            return value.formatted(.number.precision(.fractionLength(0...2)))
        }
        guard value > 0 else { return "0" }
        if value >= 100_000_000 {
            return String(format: "%.1f亿", value / 100_000_000).replacingOccurrences(of: ".0亿", with: "亿")
        }
        if value >= 10_000 {
            return String(format: "%.1f万", value / 10_000).replacingOccurrences(of: ".0万", with: "万")
        }
        return Int(value.rounded()).formatted()
    }
}
