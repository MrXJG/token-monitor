import SwiftUI

struct GroupRatesView: View {
    @ObservedObject var store: MonitorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("分组倍率").font(.headline)
                Spacer()
                if store.hasUnreadRateChange {
                    Button("标为已读") { store.acknowledgeRateChanges() }.font(.caption)
                }
            }
            Text("标题显示最近请求使用的分组，倍率读取站点最新配置。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.groupRatesError {
                Label("倍率未更新：\(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let updated = store.groupRatesUpdated {
                Text("倍率更新于 \(updated.formatted(.dateTime.hour().minute().second()))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.groupRates.isEmpty {
                        Text(store.isRefreshing ? "正在读取分组倍率…" : "站点未提供可用分组倍率")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.groupRates) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(group.name).font(.subheadline.weight(.medium)).textSelection(.enabled)
                                if store.currentGroupRate?.id == group.id {
                                    Text(store.recentRecords.isEmpty ? "唯一可用分组" : "最近使用")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(group.displayMultiplier).font(.subheadline.monospacedDigit()).fixedSize()
                            }
                            if group.usesAccountRate { Text("账户专属倍率").font(.caption2).foregroundStyle(.secondary) }
                            if let peak = group.peakDescription { Text("基础倍率如上；\(peak)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Divider()
                    }
                    Text("分组倍率不包含模型单价、长上下文及其他附加计费。")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !store.rateChanges.isEmpty {
                        Text("最近倍率变化").font(.subheadline.weight(.semibold))
                        ForEach(store.rateChanges) { change in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(change.summary).font(.caption.monospacedDigit())
                                Text("发现于 \(change.detectedAt.formatted(date: .abbreviated, time: .standard))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("首次读取建立基准，此后倍率变化会保留在这里。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxHeight: 300)
            if let message = store.rateNotificationMessage {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(16).frame(width: 330)
    }
}
