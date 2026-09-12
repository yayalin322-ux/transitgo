import SwiftUI
import WidgetKit
import ActivityKit

struct BikeTripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BikeTripAttributes.self) { context in
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "bicycle").font(.headline).foregroundStyle(.green)
                    Text(context.attributes.stationName).font(.title3.bold()).lineLimit(1)
                    Spacer()
                    Text("前往\(context.attributes.intent)")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: Capsule())
                }
                HStack(spacing: 0) {
                    bigCount("可借", context.state.availableRent, .green)
                    Divider().frame(height: 44).overlay(.white.opacity(0.2))
                    bigCount("可還", context.state.availableReturn, .blue)
                }
                HStack {
                    if let g = context.state.generalBikes, let e = context.state.electricBikes {
                        Text("一般 \(g)　電動 \(e)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(context.state.inService ? context.attributes.cityName : "暫停營運")
                        .font(.caption2)
                        .foregroundStyle(context.state.inService ? Color.secondary : Color.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .activityBackgroundTint(Color.black.opacity(0.45))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "bicycle").font(.title2).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.attributes.stationName).font(.title3.bold()).lineLimit(1)
                            Text("前往\(context.attributes.intent)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.inService ? context.attributes.cityName : "暫停營運")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(context.state.inService ? Color.secondary : Color.orange)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        HStack(spacing: 0) {
                            bigCount("可借", context.state.availableRent, .green)
                            Divider().frame(height: 40).overlay(.white.opacity(0.2))
                            bigCount("可還", context.state.availableReturn, .blue)
                        }
                        if let g = context.state.generalBikes, let e = context.state.electricBikes {
                            Text("一般 \(g)　電動 \(e)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "bicycle").foregroundStyle(.green)
            } compactTrailing: {
                Text("\(context.state.availableRent)").font(.caption.bold().monospacedDigit())
            } minimal: {
                Image(systemName: "bicycle").foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }

    private func countPill(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(value)").font(.title2.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func bigCount(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
