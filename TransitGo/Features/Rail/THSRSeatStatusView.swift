import SwiftUI

struct THSRSeatStatusView: View {
    let stationID: String
    let stationName: String

    @State private var trains: [THSRSeatTrain] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var lastUpdated: Date?
    @State private var now = Date()

    /// Sorted by departure, upcoming first (past trains fall to the end).
    private var displayTrains: [THSRSeatTrain] {
        let hm = Calendar.current.dateComponents([.hour, .minute], from: now)
        let cutoff = String(format: "%02d:%02d", hm.hour ?? 0, hm.minute ?? 0)
        return trains.sorted { a, b in
            let ta = a.departureTime ?? "99:99", tb = b.departureTime ?? "99:99"
            let ua = ta >= cutoff, ub = tb >= cutoff
            if ua != ub { return ua }          // upcoming before already-departed
            return ta < tb
        }
    }

    var body: some View {
        List {
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            Section {
                ForEach(displayTrains) { train in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(train.trainNo) 次").font(.subheadline.weight(.semibold))
                            Spacer()
                            if let dep = train.departureTime {
                                Text("\(dep) 發").monospacedDigit().font(.callout)
                            }
                        }
                        HStack(spacing: 6) {
                            if let dest = train.endingStationName?.display {
                                Text("往 \(dest)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let dep = train.departureTime, dep < currentHHMM {
                                Text("已發車").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(train.stopStations) { stop in
                                    let s = SeatStatus(stop.standardSeatStatus)
                                    VStack(spacing: 2) {
                                        Circle().fill(color(s)).frame(width: 10, height: 10)
                                        Text(stop.stationName.display).font(.caption2)
                                        Text(s.label).font(.system(size: 9)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                if trains.isEmpty, !isLoading {
                    Text("目前無資料（可能非營運時間）").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("近期班次．標準車廂餘位")
                    Spacer()
                    if let lastUpdated {
                        Text("更新 \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                    }
                }
            } footer: {
                HStack(spacing: 14) {
                    legend(.green, "有位")
                    legend(.orange, "有限")
                    legend(.red, "已滿")
                }
                .font(.caption2)
            }
        }
        .navigationTitle("\(stationName)　座位狀態")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading { ProgressView() } }
        .task {
            while !Task.isCancelled {
                now = Date()
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .refreshable { now = Date(); await load() }
    }

    private var currentHHMM: String {
        let hm = Calendar.current.dateComponents([.hour, .minute], from: now)
        return String(format: "%02d:%02d", hm.hour ?? 0, hm.minute ?? 0)
    }

    private func load() async {
        do {
            trains = try await RailService.shared.thsrSeatStatus(stationID: stationID)
            lastUpdated = Date()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    private func color(_ s: SeatStatus) -> Color {
        switch s {
        case .available: return .green
        case .limited: return .orange
        case .full: return .red
        case .unknown: return .gray
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 8, height: 8); Text(t) }
    }
}
