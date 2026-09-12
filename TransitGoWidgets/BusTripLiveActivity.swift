import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

/// Staged wording instead of a live-ticking mm:ss clock. TDX only refreshes every
/// 15-20s server-side, so a per-second countdown implies false precision and drifts
/// visibly out of sync with reality — a plain "即將進站" reads as accurate either way.
private func heroLabel(_ s: BusTripAttributes.ContentState) -> String {
    if let n = s.stopsAway, n <= 0 { return "即將進站" }
    if let eta = s.etaDate, eta.timeIntervalSinceNow < 60 { return "即將進站" }
    if let n = s.stopsAway, n <= 2 { return "即將到站" }
    if let eta = s.etaDate, eta.timeIntervalSinceNow < 180 { return "即將到站" }
    if let n = s.stopsAway { return "\(n) 站" }
    if let eta = s.etaDate {
        let mins = max(1, Int((eta.timeIntervalSinceNow / 60).rounded()))
        return "\(mins) 分"
    }
    return "—"
}

/// Lock Screen + Dynamic Island presentation for a tracked bus ride.
struct BusTripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BusTripAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.45))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "bus.fill").font(.title3).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.attributes.routeName).font(.headline)
                            Text("往 \(context.attributes.destinationName)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let crowd = context.state.crowdingLabel, context.state.onboard {
                        Text(crowd).font(.caption.weight(.bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.white.opacity(0.15), in: Capsule())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    islandBottom(context.state, attr: context.attributes)
                        .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: stageGlyph(context.state.stage)).foregroundStyle(stageTint(context.state.stage))
            } compactTrailing: {
                if context.state.stage == .rating || context.state.stage == .done {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                } else {
                    Text(heroLabel(context.state)).font(.caption2.bold()).frame(maxWidth: 46).lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } minimal: {
                Image(systemName: stageGlyph(context.state.stage)).foregroundStyle(stageTint(context.state.stage))
            }
            .keylineTint(stageTint(context.state.stage))
        }
    }

    @ViewBuilder
    private func islandBottom(_ s: BusTripAttributes.ContentState, attr: BusTripAttributes) -> some View {
        switch s.stage {
        case .rating, .done:
            VStack(spacing: 6) {
                Text(s.stage == .done ? "感謝評分！" : "為這趟行程評分").font(.subheadline.weight(.semibold))
                if s.stage == .rating { StarRow() }
            }
        case .awaitingBoard:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(spacing: 0) {
                        Text("上車").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(heroLabel(s)).font(.system(size: 26, weight: .heavy, design: .rounded))
                            .minimumScaleFactor(0.6).lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Label(attr.boardStopName, systemImage: "hand.wave.fill")
                            .font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.orange)
                        if let p = s.plate {
                            HStack(spacing: 4) {
                                Image(systemName: "bus.fill").font(.caption2)
                                Text(p).font(.caption.bold().monospaced())
                            }.foregroundStyle(.secondary)
                        } else {
                            Text(s.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                BoardButtons()
            }
        default:  // riding / awaitingAlight
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(spacing: 0) {
                        Text("下車").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(heroLabel(s)).font(.system(size: s.isArriving ? 30 : 26, weight: .heavy, design: .rounded))
                            .minimumScaleFactor(0.6).lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Label(attr.alightStopName, systemImage: "bell.fill")
                            .font(s.isArriving ? .headline : .subheadline.weight(.semibold)).lineLimit(1)
                            .foregroundStyle(s.isArriving ? .red : (s.stage == .awaitingAlight ? .red : .primary))
                        Text(s.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if s.stage == .awaitingAlight {
                    AlightButton()
                } else if let hint = s.hint {
                    Label(hint, systemImage: "info.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.blue).lineLimit(1)
                }
            }
        }
    }

    /// Stage-appropriate glyph/tint so the compact/minimal Dynamic Island reads at a glance
    /// which phase of the trip is active, not just "there's a bus tracked".
    private func stageGlyph(_ stage: TripStage) -> String {
        switch stage {
        case .awaitingBoard: return "hand.wave.fill"
        case .riding: return "bus.fill"
        case .awaitingAlight: return "bell.fill"
        case .rating, .done: return "star.fill"
        }
    }

    private func stageTint(_ stage: TripStage) -> Color {
        switch stage {
        case .awaitingBoard: return .orange
        case .riding: return .blue
        case .awaitingAlight: return .red
        case .rating, .done: return .yellow
        }
    }
}

// MARK: - Buttons

private struct BoardButtons: View {
    var body: some View {
        HStack(spacing: 10) {
            Button(intent: AdvanceTripIntent()) {
                Label("我上車了", systemImage: "checkmark.circle.fill").font(.footnote.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            Button(intent: NextBusTripIntent()) {
                Text("看下一班").font(.footnote)
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
    }
}

private struct AlightButton: View {
    var body: some View {
        HStack {
            Button(intent: AdvanceTripIntent()) {
                Label("我下車了", systemImage: "checkmark.circle.fill").font(.footnote.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Spacer(minLength: 0)
        }
    }
}

private struct StarRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { n in
                Button(intent: RateTripIntent(stars: n)) {
                    Image(systemName: "star.fill").font(.title3).foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let context: ActivityViewContext<BusTripAttributes>
    private var s: BusTripAttributes.ContentState { context.state }
    private var attr: BusTripAttributes { context.attributes }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "bus.fill").font(.headline).foregroundStyle(.blue)
                Text(attr.routeName).font(.title3.bold())
                Text(attr.scopeName)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.blue.opacity(0.2), in: Capsule())
                Spacer()
                Text("往 \(attr.destinationName)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            switch s.stage {
            case .rating, .done:
                VStack(alignment: .leading, spacing: 10) {
                    Text(s.stage == .done ? "感謝你的評分！" : "這趟 \(attr.routeName) 坐得如何？")
                        .font(.headline)
                    if s.stage == .rating { StarRow() }
                }

            case .awaitingBoard:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(heroLabel(s))
                            .font(.system(size: 36, weight: .heavy, design: .rounded))
                            .minimumScaleFactor(0.6).lineLimit(1).layoutPriority(1)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("上車").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                            Label(attr.boardStopName, systemImage: "hand.wave.fill")
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let p = s.plate {
                                HStack(spacing: 4) {
                                    Image(systemName: "bus.fill").font(.caption2)
                                    Text(p).font(.caption.bold().monospaced())
                                    Text("· 是這台嗎？").font(.caption2)
                                }.foregroundStyle(.secondary)
                            } else {
                                Text(s.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    BoardButtons()
                }

            default:  // riding / awaitingAlight
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(heroLabel(s))
                        .font(.system(size: s.isArriving ? 44 : 36, weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.6).lineLimit(1).layoutPriority(1)
                        .foregroundStyle(s.isArriving ? .red : (s.stage == .awaitingAlight ? .red : .primary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.isArriving ? "快下車" : "下車").font(.system(size: s.isArriving ? 12 : 10, weight: .bold))
                            .foregroundStyle(s.isArriving || s.stage == .awaitingAlight ? .red : .blue)
                        Label(attr.alightStopName, systemImage: "bell.fill")
                            .font(s.isArriving ? .headline : .subheadline.weight(.semibold)).lineLimit(1)
                        Text(s.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if s.stage == .awaitingAlight {
                    AlightButton()
                } else if let hint = s.hint {
                    Label(hint, systemImage: "info.circle.fill")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.blue).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
