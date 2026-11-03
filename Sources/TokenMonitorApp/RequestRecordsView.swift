import AppKit
import SwiftUI

private typealias ViewState<Value> = SwiftUI.State<Value>

struct RequestRecordsView: View {
    @ObservedObject var store: MonitorStore
    @ViewState private var status = "全部"
    @ViewState private var model = "全部"
    @ViewState private var period = "全部时间"
    @ViewState private var sortByCost = false
    @ViewState private var selectedID: String?
    @ViewState private var copiedMessage: String?

    init(store: MonitorStore, selectedID: String? = nil) {
        self.store = store
        _selectedID = ViewState(initialValue: selectedID)
    }

    private var models: [String] { Array(Set(store.recentRecords.map(\.modelName))).sorted() }
    private var filtered: [UsageRecord] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.startOfDay(for: Date())
        let start = period == "今天" ? today : calendar.date(byAdding: .day, value: -6, to: today)!
        return store.recentRecords.filter {
            (status == "全部" || status == $0.status) && (model == "全部" || model == $0.modelName) &&
            (period == "全部时间" || ($0.requestTime.map { $0 >= start } ?? false))
        }.sorted {
            if sortByCost { return ($0.cost ?? 0) > ($1.cost ?? 0) }
            return ($0.requestTime ?? .distantPast) > ($1.requestTime ?? .distantPast)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selectedID, let record = store.recentRecords.first(where: { $0.id == selectedID }) {
                detail(record)
            } else {
                HStack {
                    Text("最近请求").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("显示 \(filtered.count) 条").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Picker("状态", selection: $status) {
                        ForEach(["全部", "成功", "失败", "处理中"], id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: .infinity)
                    Picker("模型", selection: $model) {
                        Text("全部模型").tag("全部")
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: .infinity)
                }.pickerStyle(.menu).font(.caption)
                HStack(spacing: 12) {
                    Picker("时间", selection: $period) {
                        ForEach(["全部时间", "今天", "近 7 天"], id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: .infinity)
                    Picker("排序", selection: $sortByCost) {
                        Text("最新优先").tag(false)
                        Text("费用最高").tag(true)
                    }.frame(maxWidth: .infinity)
                }.pickerStyle(.menu).font(.caption)
                Text("筛选已加载记录 · \(store.recentRecords.count) / \(max(store.recentRecordsTotal, store.recentRecords.count)) 条")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    Text(store.recordsUpdated.map { "记录更新于 \($0.formatted(.dateTime.hour().minute().second()))" } ?? "记录尚未更新")
                    Spacer()
                    if store.recordsError != nil { Label("保留旧记录", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }.font(.caption2).foregroundStyle(.secondary)
                Divider()
                if filtered.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.recentRecords.isEmpty ? "暂无请求记录" : "没有符合筛选条件的记录")
                            .font(.subheadline)
                        Text(store.canLoadMoreRecords ? "可加载更多历史记录后继续筛选。" : "尝试调整状态、模型或时间范围。")
                            .font(.caption).foregroundStyle(.secondary)
                        if status != "全部" || model != "全部" || period != "全部时间" {
                            Button("清除筛选") { status = "全部"; model = "全部"; period = "全部时间" }
                        }
                    }.padding(.vertical, 18)
                }
                ForEach(filtered) { record in
                    Button { selectedID = record.id; copiedMessage = nil } label: { row(record) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(record.modelName)，\(record.status)，查看请求详情")
                    Divider()
                }
                if store.canLoadMoreRecords {
                    Button { Task { await store.loadMoreRecentRecords() } } label: {
                        HStack {
                            if store.isLoadingMoreRecords { ProgressView().controlSize(.small) }
                            Text(store.isLoadingMoreRecords ? "加载中…" : "加载更多历史记录")
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                        .disabled(store.isLoadingMoreRecords || store.isRefreshing)
                } else if !store.recentRecords.isEmpty {
                    Text("已加载全部记录").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: selectedID) { _, value in store.isShowingRequestDetail = value != nil }
        .onDisappear { store.isShowingRequestDetail = false }
        .onChange(of: store.provider.manifest.id) { _, _ in
            status = "全部"; model = "全部"; period = "全部时间"; selectedID = nil
        }
        .onChange(of: store.recentRecords.map(\.id)) { _, values in
            if let selectedID, !values.contains(selectedID) { self.selectedID = nil }
        }
        .onChange(of: models) { _, values in if model != "全部", !values.contains(model) { model = "全部" } }
        .onExitCommand { selectedID = nil }
    }
    private func row(_ record: UsageRecord) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: record.status == "成功" ? "checkmark.circle.fill" : (record.status == "处理中" ? "clock" : "exclamationmark.circle.fill"))
                .foregroundStyle(record.status == "成功" ? MonitorPalette.balance : (record.status == "处理中" ? Color.orange : Color.red))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.modelName).font(.caption.weight(.semibold)).lineLimit(2)
                Text("\(record.status) · 输入 \(record.inputTokens.formatted()) · 输出 \(record.outputTokens.formatted())")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text("\(record.requestTime?.formatted(.dateTime.month().day().hour().minute()) ?? "时间未提供") · 缓存 \(record.cacheReadTokens.formatted())")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Text(money(record.cost)).font(.caption.monospacedDigit())
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5).contentShape(Rectangle())
    }
    private func detail(_ record: UsageRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { selectedID = nil } label: { Label("返回请求记录", systemImage: "chevron.left") }
                .buttonStyle(.bordered)
            Text(record.modelName).font(.headline).textSelection(.enabled)
            HStack { Text(record.status); Spacer(); Text(money(record.cost)).monospacedDigit() }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                field("时间", record.requestTime?.formatted(date: .abbreviated, time: .standard))
                field("请求 ID", record.requestId)
                field("API Key 名称", record.keyName)
                field("输入 Token", record.inputTokens.formatted())
                field("输出 Token", record.outputTokens.formatted())
                field("缓存读取", record.cacheReadTokens.formatted())
                field("缓存写入", record.cacheWriteTokens?.formatted())
                field("推理 Token", record.reasoningTokens.formatted())
                field("端点", record.relayMode)
                field("推理等级", record.reasoningEffort)
                field("分组", record.groupName)
                field("流式", record.isStream.map { $0 ? "是" : "否" })
                field("首 Token", milliseconds(record.timeToFirstTokenMs))
                field("上游首事件", milliseconds(record.upstreamFirstEventMs))
                field("总耗时", milliseconds(record.durationMs))
            }.font(.caption)
            if let error = record.errorMessage {
                Text(error).font(.caption).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(MonitorPalette.warningSurface, in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                if let id = record.requestId { Button("复制请求 ID") { copy(id, message: "已复制请求 ID") } }
                if let error = record.errorMessage { Button("复制错误信息") { copy(error, message: "已复制错误信息") } }
            }
            if let copiedMessage { Label(copiedMessage, systemImage: "checkmark").font(.caption).foregroundStyle(MonitorPalette.balance) }
        }
    }
    private func field(_ title: String, _ value: String?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value ?? "站点未提供").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func copy(_ value: String, message: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        copiedMessage = message
    }
    private func money(_ value: Decimal?) -> String { value.map { "$" + $0.formatted(.number.precision(.fractionLength(4))) } ?? "费用未提供" }
    private func milliseconds(_ value: Int?) -> String? { value.map { "\($0.formatted()) ms" } }
}
