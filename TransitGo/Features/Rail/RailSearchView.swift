import SwiftUI

@MainActor
@Observable
final class RailSearchViewModel {
    var system: RailSystem = .tra
    var origin: RailStation?
    var destination: RailStation?
    var date: Date = .now

    var runs: [TrainRun] = []
    var isLoading = false
    var errorText: String?
    var hasSearched = false

    func swap() { (origin, destination) = (destination, origin) }

    var canSearch: Bool { origin != nil && destination != nil && origin?.id != destination?.id }

    func search() async {
        guard let origin, let destination else { return }
        isLoading = true
        errorText = nil
        hasSearched = true
        defer { isLoading = false }
        do {
            runs = try await RailService.shared.timetable(system: system, from: origin, to: destination, date: date)
        } catch {
            errorText = error.localizedDescription
            runs = []
        }
    }

    /// Trains departing at or after the chosen time-of-day (falls back to all).
    var displayRuns: [TrainRun] {
        let hm = Calendar.current.dateComponents([.hour, .minute], from: date)
        let cutoff = String(format: "%02d:%02d", hm.hour ?? 0, hm.minute ?? 0)
        let after = runs.filter { $0.departure >= cutoff }
        return after.isEmpty ? runs : after
    }
}

struct RailSearchView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model = RailSearchViewModel()
    @State private var store = RailStationStore.shared
    @State private var selectedRun: TrainRun?

    var body: some View {
        if sizeClass == .regular {
            // Wide screen (iPad, unfolded / dual-screen iPhone): the search and its results on the left, the chosen
            // train's stops on the right, instead of pushing a full-screen page.
            HStack(spacing: 0) {
                searchForm.frame(width: 420)
                Divider()
                Group {
                    if let run = selectedRun {
                        TrainDetailView(system: model.system, trainNo: run.trainNo,
                                        highlightFromID: model.origin?.id, highlightToID: model.destination?.id)
                            .id(run.id)
                    } else {
                        ContentUnavailableView("選一班列車", systemImage: "tram", description: Text("查詢後從左邊挑一班，這裡會顯示停靠站與時間"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            searchForm
        }
    }

    private var searchForm: some View {
        Form {
                Section {
                    Picker("系統", selection: $model.system) {
                        ForEach(RailSystem.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.system) { _, _ in
                        model.origin = nil
                        model.destination = nil
                        model.runs = []
                        model.hasSearched = false
                    }
                }

                Section {
                    stationPicker("起站", selection: $model.origin)
                    stationPicker("到站", selection: $model.destination)
                    Button {
                        model.swap()
                    } label: {
                        Label("對調起訖", systemImage: "arrow.up.arrow.down")
                    }
                    DatePicker("出發時間", selection: $model.date, in: dateRange,
                              displayedComponents: [.date, .hourAndMinute])

                    if model.system == .thsr, let origin = model.origin {
                        NavigationLink {
                            THSRSeatStatusView(stationID: origin.id, stationName: origin.name)
                        } label: {
                            Label("高鐵座位狀態（\(origin.name)）", systemImage: "chair.lounge")
                        }
                    }
                }

                Section {
                    Button {
                        selectedRun = nil
                        Task { await model.search() }
                    } label: {
                        HStack { Spacer(); Text("查詢時刻").bold(); Spacer() }
                    }
                    .disabled(!model.canSearch || model.isLoading)
                }

                if let errorText = model.errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
                }

                if model.hasSearched {
                    Section("班次（\(model.displayRuns.count)）") {
                        if model.displayRuns.isEmpty, !model.isLoading {
                            Text("查無班次").foregroundStyle(.secondary)
                        }
                        ForEach(model.displayRuns) { run in
                            if sizeClass == .regular {
                                Button { selectedRun = run } label: {
                                    TrainRunRow(run: run, system: model.system)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(selectedRun?.id == run.id ? Color.accentColor.opacity(0.15) : nil)
                            } else {
                                NavigationLink {
                                    TrainDetailView(
                                        system: model.system,
                                        trainNo: run.trainNo,
                                        highlightFromID: model.origin?.id,
                                        highlightToID: model.destination?.id
                                    )
                                } label: {
                                    TrainRunRow(run: run, system: model.system)
                                }
                            }
                        }
                    }
                }
            }
        .navigationTitle("台鐵 / 高鐵")
        .overlay { if model.isLoading { ProgressView() } }
        .task { await store.loadIfNeeded() }
    }

    private var dateRange: ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: .now)
        return today...Calendar.current.date(byAdding: .day, value: 29, to: today)!
    }

    @ViewBuilder
    private func stationPicker(_ title: String, selection: Binding<RailStation?>) -> some View {
        Picker(title, selection: selection) {
            Text("請選擇").tag(RailStation?.none)
            ForEach(store.stations(for: model.system)) { station in
                Text(station.name).tag(RailStation?.some(station))
            }
        }
    }
}

struct TrainRunRow: View {
    let run: TrainRun
    let system: RailSystem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(system == .tra ? run.trainType : "高鐵") \(run.trainNo)")
                    .font(.subheadline.weight(.semibold))
                if let note = run.note {
                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(run.departure) → \(run.arrival)").monospacedDigit()
                Text(run.durationText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
