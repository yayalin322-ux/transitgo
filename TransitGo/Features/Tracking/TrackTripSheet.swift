import SwiftUI

struct TrackTripSheet: View {
    let scope: BusScope
    let routeName: String
    let direction: Int
    let stops: [BusRouteStop]
    let initialBoardStop: BusRouteStop
    let initialAlightStop: BusRouteStop
    var plate: String?
    let destinationName: String

    @Environment(\.dismiss) private var dismiss
    @State private var seat: String = ""
    @State private var boardUID: String = ""
    @State private var alightUID: String = ""
    @State private var tracker = TripTracker.shared

    private var boardStop: BusRouteStop {
        stops.first { $0.stopUID == boardUID } ?? initialBoardStop
    }
    private var alightStop: BusRouteStop {
        stops.first { $0.stopUID == alightUID } ?? initialAlightStop
    }
    /// Alight stop must be after the board stop.
    private var alightChoices: [BusRouteStop] {
        stops.filter { $0.stopSequence > boardStop.stopSequence }
    }
    private var valid: Bool { alightStop.stopSequence > boardStop.stopSequence }
    /// Board stop is the very first stop of this direction — a terminus, where you can
    /// board whichever bus is sitting there rather than watching for one specific run.
    private var isOriginStop: Bool {
        boardStop.stopSequence == (stops.map(\.stopSequence).min() ?? boardStop.stopSequence)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("路線") {
                    LabeledContent("路線", value: routeName)
                    if let plate { LabeledContent("車牌", value: plate) }
                    LabeledContent("往", value: destinationName)
                }

                Section("站點") {
                    Picker("上車站", selection: $boardUID) {
                        ForEach(stops) { s in Text(s.stopName.display).tag(s.stopUID) }
                    }
                    Picker("下車站", selection: $alightUID) {
                        ForEach(alightChoices.isEmpty ? stops : alightChoices) { s in
                            Text(s.stopName.display).tag(s.stopUID)
                        }
                    }
                }

                Section("座位（選填）") {
                    TextField("例如 12車 5A", text: $seat)
                }

                Section {
                    Text(isOriginStop
                         ? "「\(boardStop.stopName.display)」是起站，隨時可上車——直接開始追蹤，快到「\(alightStop.stopName.display)」會提醒你按鈴下車。"
                         : plate == nil
                         ? "會盯著下一班到「\(boardStop.stopName.display)」的車：快到時提醒你舉手招車；上車後再提醒你在「\(alightStop.stopName.display)」按鈴下車。"
                         : "會盯著車牌 \(plate!)：到「\(boardStop.stopName.display)」提醒上車，快到「\(alightStop.stopName.display)」提醒按鈴下車。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !valid {
                    Section {
                        Label("下車站要在上車站之後", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                if !tracker.isActivitiesEnabled {
                    Section {
                        Label("即時動態未開啟，請到「設定 › 交通即時查」開啟。",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("開始追蹤")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("開始") {
                        let target = TripTracker.Target(
                            scope: scope,
                            routeName: routeName,
                            direction: direction,
                            boardStop: boardStop,
                            alightStop: alightStop,
                            destinationName: destinationName,
                            seat: seat.isEmpty ? nil : seat,
                            plate: plate,
                            isOriginStop: isOriginStop
                        )
                        Task { await tracker.start(target) }
                        dismiss()
                    }
                    .disabled(!tracker.isActivitiesEnabled || !valid)
                }
            }
            .onAppear {
                boardUID = initialBoardStop.stopUID
                alightUID = initialAlightStop.stopUID
            }
            .onChange(of: boardUID) { _, _ in
                // Keep the alight stop after the board stop.
                if alightStop.stopSequence <= boardStop.stopSequence {
                    alightUID = alightChoices.first?.stopUID ?? alightUID
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
