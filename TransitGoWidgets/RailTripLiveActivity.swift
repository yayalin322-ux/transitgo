import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

/// Stage-dependent buttons for the rail Live Activity.
private struct RailActionRow: View {
    let stage: TripStage
    let hint: String?

    var body: some View {
        switch stage {
        case .awaitingBoard:
            Button(intent: AdvanceTripIntent()) {
                Label("我上車了", systemImage: "checkmark.circle.fill").font(.footnote.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
        case .awaitingAlight:
            Button(intent: AdvanceTripIntent()) {
                Label("我到站了", systemImage: "checkmark.circle.fill").font(.footnote.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
        case .rating:
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { n in
                    Button(intent: RateTripIntent(stars: n)) {
                        Image(systemName: "star.fill").font(.title3).foregroundStyle(.yellow)
                    }
                    .buttonStyle(.plain)
                }
            }
        default:
            if let hint {
                Label(hint, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }
}

struct RailTripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RailTripAttributes.self) { context in
            RailLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.45))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "tram.fill").font(.title2).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.attributes.trainLabel).font(.title3.bold())
                            Text(context.attributes.systemName)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(context.state.delayText)
                            .font(.callout.weight(.bold))
                            .foregroundStyle(context.state.delayMinutes <= 0 ? .green : .orange)
                        if let p = context.state.platform {
                            Text("第 \(p) 月台").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(context.attributes.fromName)
                                    .font(.system(size: 18, weight: .bold)).lineLimit(1)
                                Text(context.attributes.depTime)
                                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer(minLength: 8)
                            VStack(spacing: 0) {
                                Text(context.state.phase)
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                if let t = context.state.targetDate, t > .now {
                                    Text(timerInterval: Date.now...t)
                                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                                        .monospacedDigit()
                                        .frame(width: 112)
                                } else {
                                    Text(context.state.phase).font(.title3.bold())
                                }
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(context.attributes.toName)
                                    .font(.system(size: 18, weight: .bold)).lineLimit(1)
                                Text(context.attributes.arrTime)
                                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        GeometryReader { geo in
                            let p = context.state.progress
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.22)).frame(height: 5)
                                Capsule().fill(.orange).frame(width: max(5, geo.size.width * p), height: 5)
                                Circle().fill(.white).frame(width: 11, height: 11)
                                    .offset(x: min(geo.size.width - 11, max(0, geo.size.width * p - 5.5)))
                            }
                        }
                        .frame(height: 11)
                        HStack(spacing: 8) {
                            RailActionRow(stage: context.state.stage, hint: context.state.hint)
                            Spacer(minLength: 0)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "tram.fill").foregroundStyle(.orange)
            } compactTrailing: {
                railCountdown(context).font(.caption.bold().monospacedDigit()).frame(maxWidth: 46)
            } minimal: {
                Image(systemName: "tram.fill").foregroundStyle(.orange)
            }
            .keylineTint(.orange)
        }
    }

    @ViewBuilder
    private func railCountdown(_ context: ActivityViewContext<RailTripAttributes>) -> some View {
        if let target = context.state.targetDate, target > .now {
            Text(timerInterval: Date.now...target)
        } else {
            Text("—")
        }
    }
}

private struct RailLockScreenView: View {
    let context: ActivityViewContext<RailTripAttributes>
    private var state: RailTripAttributes.ContentState { context.state }
    private var attr: RailTripAttributes { context.attributes }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "tram.fill").font(.subheadline).foregroundStyle(.orange)
                Text(attr.trainLabel).font(.title3.bold())
                Text(attr.systemName)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.orange.opacity(0.2), in: Capsule())
                if let p = state.platform {
                    Text("第 \(p) 月台")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(state.delayText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(state.delayMinutes <= 0 ? .green : .orange)
            }

            // Stations
            HStack(alignment: .firstTextBaseline) {
                Text(attr.fromName).font(.system(size: 20, weight: .bold))
                Spacer()
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(attr.toName).font(.system(size: 20, weight: .bold))
            }
            .lineLimit(1).minimumScaleFactor(0.7)

            // Progress bar
            GeometryReader { geo in
                let p = state.progress
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: 5)
                    Capsule().fill(.orange).frame(width: max(5, geo.size.width * p), height: 5)
                    Circle().fill(.white).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.orange, lineWidth: 3))
                        .offset(x: min(geo.size.width - 12, max(0, geo.size.width * p - 6)))
                }
            }
            .frame(height: 12)

            // Times + big countdown
            HStack(alignment: .firstTextBaseline) {
                Text(attr.depTime).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                VStack(spacing: -1) {
                    Text(state.phase).font(.system(size: 9)).foregroundStyle(.secondary)
                    Group {
                        if let target = state.targetDate, target > .now {
                            Text(timerInterval: Date.now...target)
                                .font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
                        } else {
                            Text(state.phase).font(.system(size: 22, weight: .heavy, design: .rounded))
                        }
                    }
                    .minimumScaleFactor(0.6).lineLimit(1)
                }
                Spacer()
                if !attr.seatLabel.isEmpty {
                    Text(attr.seatLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(attr.arrTime).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            RailActionRow(stage: state.stage, hint: state.hint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
