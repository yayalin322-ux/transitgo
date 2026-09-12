import SwiftUI
import WidgetKit
import ActivityKit

struct MetroTripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MetroTripAttributes.self) { context in
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "tram.circle.fill").font(.headline).foregroundStyle(.indigo)
                    Text(context.attributes.stationName).font(.title3.bold())
                    Text(context.attributes.lineName).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.indigo.opacity(0.2), in: Capsule())
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    metroCountdown(context)
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .layoutPriority(1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.attributes.heading).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let f = context.state.followingEtaMinutes {
                            Text("下一班約 \(f) 分").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .activityBackgroundTint(Color.black.opacity(0.45))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "tram.circle.fill").font(.title2).foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.attributes.stationName).font(.title3.bold())
                            Text(context.attributes.lineName).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let f = context.state.followingEtaMinutes {
                        Text("下一班 \(f) 分").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(spacing: 0) {
                            Text("進站倒數").font(.system(size: 10)).foregroundStyle(.secondary)
                            metroCountdown(context)
                                .font(.system(size: 32, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.heading).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(context.state.statusText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "tram.fill").foregroundStyle(.indigo)
            } compactTrailing: {
                metroCountdown(context).font(.caption.bold().monospacedDigit()).frame(maxWidth: 46)
            } minimal: {
                Image(systemName: "tram.fill").foregroundStyle(.indigo)
            }
            .keylineTint(.indigo)
        }
    }

    @ViewBuilder
    private func metroCountdown(_ context: ActivityViewContext<MetroTripAttributes>) -> some View {
        if let arr = context.state.nextArrival, arr > .now, (context.state.nextEtaMinutes ?? 0) > 0 {
            Text(timerInterval: Date.now...arr)
        } else {
            Text(context.state.statusText)
        }
    }
}
