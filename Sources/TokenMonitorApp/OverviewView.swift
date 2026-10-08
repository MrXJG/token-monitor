import AppKit
import Foundation
import SwiftUI

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
        .frame(minHeight: 64, alignment: .topLeading)
    }
}

struct OverviewView: View {
    @ObservedObject var store: MonitorStore
    let onSettings: () -> Void
    let onProviderSwitch: () -> Void

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
                    if let error = store.lastError {
                        Label(store.overview == nil ? error : "更新失败，显示上次数据：\(error)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let data = store.overview {
                        if store.selectedTab == 0 || !store.activeCapabilities.contains(.requestDetails) {
                            overviewGrid(data)
                            if store.activeCapabilities.contains(.usageTrend), !store.trend.isEmpty {
                                TrendStripView(buckets: store.trend)
                            }
                            if store.activeCapabilities.contains(.modelBreakdown) { modelSection }
                        } else {
                            recentSection
                        }
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
        .frame(width: MonitorLayout.panelWidth, height: MonitorLayout.panelHeight)
        .background(MonitorMaterial(material: .popover))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 8) {
                Text(store.provider.manifest.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("当前站点：\(store.provider.manifest.name)")
                statusSummary
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                providerSwitcher
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: MonitorLayout.iconTarget, height: MonitorLayout.iconTarget)
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing || store.session == nil)
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
        HStack(spacing: 5) {
            HStack(spacing: 4) {
                Circle()
                    .fill(store.lastError != nil ? Color.orange : (store.session == nil ? Color.secondary : MonitorPalette.balance))
                    .frame(width: 6, height: 6)
                Text(connectionStatus)
            }
            Text("·")
                .foregroundStyle(.tertiary)
            Text(store.lastUpdated.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "尚未更新")
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private var connectionStatus: String {
        store.isRefreshing ? "刷新中" : (store.lastError != nil ? (store.session == nil ? "连接异常" : "更新失败") : (store.session == nil ? "未连接" : "已连接"))
    }

    private var providerSwitcher: some View {
        Menu {
            ForEach(ProviderCatalog.all, id: \.id) { definition in
                Button {
                    store.updateProviderID(definition.id)
                    onProviderSwitch()
                } label: {
                    HStack {
                        Text(definition.name)
                        Spacer(minLength: 18)
                        if definition.id == store.providerID {
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
            DisclosureGroup("账户累计") {
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

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近请求").font(.subheadline.weight(.semibold))
            if store.recentRecords.isEmpty {
                Text("暂无请求记录").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.recentRecords) { record in
                    DisclosureGroup {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                            detailRow("时间", record.requestTime?.formatted(date: .abbreviated, time: .standard) ?? "-")
                            detailRow("请求 ID", record.requestId ?? "-")
                            detailRow("API Key", record.keyName ?? "-")
                            detailRow("端点", record.relayMode ?? "-")
                            detailRow("推理等级", record.reasoningEffort ?? "-")
                            detailRow("分组", record.groupName ?? "-")
                            detailRow("流式", record.isStream.map { $0 ? "是" : "否" } ?? "-")
                            detailRow("缓存写入", record.cacheWriteTokens.map { $0.formatted() } ?? "站点未提供")
                            detailRow("推理 Token", record.reasoningTokens.formatted())
                            detailRow("首 Token", formatMilliseconds(record.timeToFirstTokenMs.map(Double.init)))
                            detailRow("上游首事件", formatMilliseconds(record.upstreamFirstEventMs.map(Double.init)))
                            detailRow("总耗时", formatMilliseconds(record.durationMs.map(Double.init)))
                        }
                        .font(.caption2)
                        .padding(.vertical, 8)
                        if let error = record.errorMessage {
                            Text(error).font(.caption2).foregroundStyle(.red).textSelection(.enabled)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(record.status == "成功" ? MonitorPalette.balance : (record.status == "处理中" ? .orange : .red))
                                .frame(width: 7, height: 7)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.modelName)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                                HStack(spacing: 5) {
                                    Text(record.status)
                                        .foregroundStyle(record.status == "成功" ? MonitorPalette.balance : (record.status == "处理中" ? .orange : .red))
                                    Text("· 输入 \(record.inputTokens.formatted()) · 输出 \(record.outputTokens.formatted())")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption2.monospacedDigit())
                                .fixedSize(horizontal: false, vertical: true)
                                Text("\(record.requestTime?.formatted(date: .omitted, time: .shortened) ?? "-") · 缓存读取 \(record.cacheReadTokens.formatted())")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formatMoney(record.cost))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
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
    private var showsCost: Bool { buckets.allSatisfy { $0.totalTokens == 0 && $0.cost != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(showsCost ? "近 \(buckets.count) 天费用" : "近 \(buckets.count) 天 Token 用量")
                        .font(.subheadline.weight(.semibold))
                    Text("移动鼠标查看每日用量")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(showsCost ? "费用" : "Token")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TrendChartRepresentable(buckets: buckets, showsCost: showsCost)
                .frame(height: 96)
                .accessibilityLabel("近 \(buckets.count) 天\(showsCost ? "费用" : "Token 用量")趋势")
            HStack {
                ForEach(buckets) { bucket in
                    Text(bucket.date.formatted(.dateTime.day()))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 2)
    }
}

struct TrendChartRepresentable: NSViewRepresentable {
    let buckets: [UsageBucket]
    let showsCost: Bool

    func makeNSView(context: Context) -> TrendChartNSView {
        TrendChartNSView(buckets: buckets, showsCost: showsCost)
    }

    func updateNSView(_ nsView: TrendChartNSView, context: Context) {
        nsView.buckets = buckets
        nsView.showsCost = showsCost
        nsView.needsDisplay = true
    }
}

final class TrendChartNSView: NSView {
    var buckets: [UsageBucket]
    var showsCost: Bool
    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?

    init(buckets: [UsageBucket], showsCost: Bool) {
        self.buckets = buckets
        self.showsCost = showsCost
        super.init(frame: .zero)
        wantsLayer = true
        updateTrackingArea()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard !buckets.isEmpty, bounds.width > 0 else { return }
        let position = convert(event.locationInWindow, from: nil)
        let step = bounds.width / CGFloat(max(buckets.count - 1, 1))
        hoveredIndex = min(max(Int((position.x / step).rounded()), 0), buckets.count - 1)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !buckets.isEmpty else { return }
        let chartRect = bounds.insetBy(dx: 2, dy: 7)
        let maximum = max(buckets.map(amount).max() ?? 1, 1)
        let step = chartRect.width / CGFloat(max(buckets.count - 1, 1))
        let points = buckets.enumerated().map { index, bucket in
            CGPoint(
                x: chartRect.minX + step * CGFloat(index),
                y: chartRect.maxY - (chartRect.height - 6) * CGFloat(amount(bucket) / maximum)
            )
        }

        NSColor.controlAccentColor.setStroke()
        let line = NSBezierPath()
        for (index, point) in points.enumerated() {
            if index == 0 { line.move(to: point) } else { line.line(to: point) }
        }
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.stroke()

        for (index, point) in points.enumerated() {
            let radius: CGFloat = hoveredIndex == index ? 4 : 2.5
            (hoveredIndex == index ? NSColor.systemGreen : NSColor.controlAccentColor).setFill()
            NSBezierPath(
                ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            ).fill()
        }

        guard let hoveredIndex, buckets.indices.contains(hoveredIndex) else { return }
        let point = points[hoveredIndex]
        NSColor.controlAccentColor.withAlphaComponent(0.22).setStroke()
        let guide = NSBezierPath()
        guide.move(to: CGPoint(x: point.x, y: chartRect.minY))
        guide.line(to: CGPoint(x: point.x, y: chartRect.maxY))
        guide.lineWidth = 1
        guide.stroke()

        let bucket = buckets[hoveredIndex]
        let lines = [
            bucket.date.formatted(date: .abbreviated, time: .omitted),
            valueText(bucket),
            "\(bucket.requestCount) 次请求"
        ]
        let font = NSFont.systemFont(ofSize: 11)
        let boldFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let tooltipWidth: CGFloat = 132
        let tooltipHeight: CGFloat = 51
        let originX = min(max(point.x - tooltipWidth / 2, bounds.minX + 4), bounds.maxX - tooltipWidth - 4)
        let origin = CGPoint(x: originX, y: chartRect.minY + 2)
        NSColor.controlBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(
            roundedRect: NSRect(origin: origin, size: CGSize(width: tooltipWidth, height: tooltipHeight)),
            xRadius: 7,
            yRadius: 7
        ).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(
            roundedRect: NSRect(origin: origin, size: CGSize(width: tooltipWidth, height: tooltipHeight)),
            xRadius: 7,
            yRadius: 7
        ).stroke()
        lines.enumerated().forEach { index, line in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: index == 1 ? boldFont : font,
                .foregroundColor: index == 2 ? NSColor.secondaryLabelColor : NSColor.labelColor
            ]
            line.draw(
                at: CGPoint(x: origin.x + 8, y: origin.y + 6 + CGFloat(index * 15)),
                withAttributes: attributes
            )
        }
    }

    private func amount(_ bucket: UsageBucket) -> Double {
        showsCost ? NSDecimalNumber(decimal: bucket.cost ?? .zero).doubleValue : Double(bucket.totalTokens)
    }

    private func valueText(_ bucket: UsageBucket) -> String {
        if showsCost {
            return "$\((bucket.cost ?? .zero).formatted(.number.precision(.fractionLength(4))))"
        }
        return "\(bucket.totalTokens.formatted()) Token"
    }
}
