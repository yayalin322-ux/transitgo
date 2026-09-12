import SwiftUI

@MainActor
@Observable
final class MetroBrowserViewModel {
    var op: MetroOperator = .trtc
    var lines: [MetroLine] = []
    var stationsByLine: [String: [MetroLineStation]] = [:]
    var selectedLineID: String?
    var isLoading = false
    var errorText: String?

    func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            async let linesTask = MetroService.shared.lines(operator: op)
            async let solTask = MetroService.shared.stationsOfLine(operator: op)
            lines = try await linesTask
            let sol = try await solTask
            stationsByLine = Dictionary(sol.map { ($0.lineID, $0.stations.sorted { $0.sequence < $1.sequence }) },
                                        uniquingKeysWith: { a, _ in a })
            if selectedLineID == nil || !lines.contains(where: { $0.lineID == selectedLineID }) {
                selectedLineID = lines.first?.lineID
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    var currentStations: [MetroLineStation] {
        guard let id = selectedLineID else { return [] }
        return stationsByLine[id] ?? []
    }

    var currentLineColor: Color {
        lines.first(where: { $0.lineID == selectedLineID })?.color ?? .secondary
    }
}

struct MetroBrowserView: View {
    @State private var model = MetroBrowserViewModel()

    var body: some View {
        Form {
            Section {
                Picker("捷運系統", selection: $model.op) {
                    ForEach(MetroOperator.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: model.op) { _, _ in
                    model.selectedLineID = nil
                    Task { await model.load() }
                }
                if !model.op.hasLiveBoard {
                    Label("此系統 TDX 未提供即時到站，僅供站點瀏覽。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !model.lines.isEmpty {
                Section {
                    Picker("路線", selection: $model.selectedLineID) {
                        ForEach(model.lines) { line in
                            Label {
                                Text(line.name)
                            } icon: {
                                Circle().fill(line.color).frame(width: 10, height: 10)
                            }
                            .tag(Optional(line.lineID))
                        }
                    }
                }

                Section {
                    ForEach(model.currentStations) { station in
                        NavigationLink {
                            MetroStationDetailView(
                                operator: model.op,
                                stationID: station.stationID,
                                stationName: station.name
                            )
                        } label: {
                            Text(station.name)
                        }
                    }
                } header: {
                    Label("車站", systemImage: "circle.fill")
                        .foregroundStyle(model.currentLineColor)
                }
            }

            if let err = model.errorText {
                Section { Text(err).font(.footnote).foregroundStyle(.red) }
            }
        }
        .overlay { if model.isLoading, model.lines.isEmpty { ProgressView() } }
        .task { if model.lines.isEmpty { await model.load() } }
    }
}
