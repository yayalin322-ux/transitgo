import SwiftUI
import WidgetKit
import ActivityKit

struct NavigationTripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavigationTripAttributes.self) { context in
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: context.state.modeSymbol).font(.headline)
                        .foregroundStyle(context.state.offRoute ? .orange : .blue)
                    Text(context.attributes.destinationName).font(.title3.bold()).lineLimit(1)
                    Spacer()
                    if let progress = context.state.legProgress {
                        Text(progress)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.gray.opacity(0.25), in: Capsule())
                    }
                    Text(context.state.modeLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.blue.opacity(0.2), in: Capsule())
                }
                if context.state.arrived {
                    Text("已抵達目的地").font(.title2.bold()).foregroundStyle(.green)
                } else if let transitLabel = context.state.transitLabel {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("乘車中：\(transitLabel)").font(.title3.bold())
                        if let plate = context.state.transitPlate {
                            Text("推測車牌：\(plate)").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let alight = context.state.transitAlightName {
                            Text("下車：\(alight)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(distanceText(context.state.distanceMeters))
                                .font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit()
                            Text("剩餘距離").font(.caption2).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(context.state.etaMinutes) 分")
                                .font(.system(size: 26, weight: .heavy, design: .rounded)).monospacedDigit()
                            Text("預估時間").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if context.state.offRoute {
                    Label("已偏離路線，重新規劃中", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .activityBackgroundTint(Color.black.opacity(0.45))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: context.state.modeSymbol).font(.title3)
                            .foregroundStyle(context.state.offRoute ? .orange : .blue)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.attributes.destinationName).font(.headline).lineLimit(1)
                            HStack(spacing: 4) {
                                Text(context.state.modeLabel).font(.caption2).foregroundStyle(.secondary)
                                if let progress = context.state.legProgress {
                                    Text(progress).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.offRoute {
                        Label("偏離路線", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.bold)).foregroundStyle(.orange)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.arrived {
                        Text("已抵達目的地").font(.headline).foregroundStyle(.green).padding(.top, 2)
                    } else if let transitLabel = context.state.transitLabel {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("乘車中：\(transitLabel)").font(.headline)
                            if let alight = context.state.transitAlightName {
                                Text("下車：\(alight)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(distanceText(context.state.distanceMeters))
                                    .font(.system(size: 28, weight: .heavy, design: .rounded)).monospacedDigit()
                                Text("剩餘距離").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(context.state.etaMinutes) 分")
                                    .font(.system(size: 22, weight: .heavy, design: .rounded)).monospacedDigit()
                                Text("預估時間").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.modeSymbol)
                    .foregroundStyle(context.state.offRoute ? .orange : .blue)
            } compactTrailing: {
                Text(distanceText(context.state.distanceMeters))
                    .font(.caption2.bold()).frame(maxWidth: 50).lineLimit(1).minimumScaleFactor(0.7)
            } minimal: {
                Image(systemName: context.state.modeSymbol)
                    .foregroundStyle(context.state.offRoute ? .orange : .blue)
            }
            .keylineTint(context.state.offRoute ? .orange : .blue)
        }
    }

    private func distanceText(_ meters: Int) -> String {
        meters < 1000 ? "\(meters) 公尺" : String(format: "%.1f 公里", Double(meters) / 1000)
    }
}
