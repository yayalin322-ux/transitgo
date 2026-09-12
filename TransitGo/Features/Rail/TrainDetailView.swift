import SwiftUI

struct TrainDetailView: View {
    let system: RailSystem
    let trainNo: String
    var highlightFromID: String? = nil
    var highlightToID: String? = nil

    @State private var detail: RailTrainDetail?
    @State private var live: TrainLiveStatus?
    @State private var fare: RailFareInfo?
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let detail {
                Section {
                    LabeledContent("車次", value: "\(detail.trainType) \(detail.trainNo)".trimmingCharacters(in: .whitespaces))
                    LabeledContent("行駛", value: "\(detail.origin) → \(detail.destination)")
                    LabeledContent("停靠站數", value: "\(detail.stops.count) 站")
                    if let line = detail.tripLineText {
                        LabeledContent("經由", value: line)
                    }
                    if let live {
                        LabeledContent("即時") {
                            Text(live.delayMinutes <= 0 ? "準點" : "誤點 \(live.delayMinutes) 分")
                                .foregroundStyle(live.delayMinutes <= 0 ? .green : .orange)
                                .fontWeight(.semibold)
                        }
                        LabeledContent("位置", value: live.statusText)
                    }
                }

                if let fare, !fare.isEmpty {
                    Section {
                        ForEach(fare.groups) { group in
                            RailFareGroupRow(group: group)
                        }
                        if let km = fare.distanceKm {
                            LabeledContent("行駛里程", value: String(format: "約 %.0f 公里", km))
                        }
                    } header: {
                        Text(fare.groups.isEmpty ? "行程" : "票價")
                    } footer: {
                        Text(system == .thsr
                             ? "高鐵 TDX 票價，實際以購票為準。"
                             : "台鐵票價依實際搭乘車種（自強／莒光／區間）計算，以購票金額為準。")
                    }
                }

                if !detail.amenities.isEmpty || detail.note != nil {
                    Section("列車資訊") {
                        if !detail.amenities.isEmpty {
                            WrapChips(items: detail.amenities)
                        }
                        if let note = detail.note {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("各站到開時刻") {
                    ForEach(detail.stops) { stop in
                        HStack {
                            Circle()
                                .fill(isHighlighted(stop) ? Color.accentColor : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(stop.stationName)
                                .fontWeight(isHighlighted(stop) ? .semibold : .regular)
                            Spacer()
                            Text(stop.timeText)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(isHighlighted(stop) ? .primary : .secondary)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "查無班次資料",
                    systemImage: "tram",
                    description: Text(errorText ?? "TDX 僅提供「當日」單一車次的各站時刻；非當日車次請用起訖站查詢。")
                )
            }
        }
        .navigationTitle("車次 \(trainNo)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func isHighlighted(_ stop: RailTrainStop) -> Bool {
        guard let f = highlightFromID, let t = highlightToID,
              let fi = detail?.stops.firstIndex(where: { $0.stationID == f }),
              let ti = detail?.stops.firstIndex(where: { $0.stationID == t }) else { return false }
        guard let si = detail?.stops.firstIndex(where: { $0.id == stop.id }) else { return false }
        return si >= min(fi, ti) && si <= max(fi, ti)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            detail = try await RailService.shared.trainDetail(system: system, trainNo: trainNo)
            live = try? await RailService.shared.liveStatus(system: system, trainNo: trainNo)
        } catch {
            errorText = error.localizedDescription
        }
        if let f = highlightFromID, let t = highlightToID {
            fare = await RailFareService.shared.fare(system: system, fromID: f, toID: t)
        }
    }
}

/// One fare category (全票 / 半票 / 早鳥) with its per-cabin prices.
struct RailFareGroupRow: View {
    let group: RailFareGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(group.rows, id: \.label) { row in
                HStack {
                    Text(row.label)
                    Spacer()
                    Text("$\(row.price)").font(.body.weight(.semibold)).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Simple wrapping row of amenity chips.
struct WrapChips: View {
    let items: [(String, String)]
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.1) { icon, label in
                Label(label, systemImage: icon)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.tint.opacity(0.12), in: Capsule())
            }
        }
    }
}

/// Minimal flow layout (iOS 16+).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
