import SwiftUI

struct RouteInfoView: View {
    let routeName: String
    let scopeName: String
    let info: BusRouteInfo?
    let schedule: [BusScheduleEntry]

    @Environment(\.dismiss) private var dismiss

    private var directions: [Int] {
        Array(Set(schedule.map(\.direction))).sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                Section("路線") {
                    LabeledContent("路線", value: routeName)
                    LabeledContent("地區", value: scopeName)
                    if let ops = info?.operatorNames, !ops.isEmpty {
                        LabeledContent("營運業者", value: ops)
                    }
                    if let price = info?.ticketPriceDescriptionZh, !price.isEmpty {
                        LabeledContent("票價", value: price)
                    }
                }

                if let urlString = info?.routeMapImageUrl,
                   let url = URL(string: urlString) {
                    Section("路線圖") {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            case .failure:
                                Text("無法載入路線圖").foregroundStyle(.secondary).font(.footnote)
                            default:
                                ProgressView()
                            }
                        }
                    }
                }

                ForEach(directions, id: \.self) { dir in
                    Section(dir == 0 ? "時刻表．去程" : "時刻表．返程") {
                        let entries = schedule.filter { $0.direction == dir }
                        if entries.allSatisfy({ ($0.frequencys?.isEmpty ?? true) && ($0.timetables?.isEmpty ?? true) }) {
                            Text("無班表資料").foregroundStyle(.secondary).font(.footnote)
                        }
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            if let sub = entry.subRouteName?.display, !sub.isEmpty, entries.count > 1 {
                                Text(sub).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(entry.frequencys ?? []) { f in
                                HStack {
                                    Text("\(f.startTime)–\(f.endTime)")
                                        .monospacedDigit()
                                    if let day = f.serviceDay?.label, !day.isEmpty {
                                        Text(day)
                                            .font(.caption2)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.tint.opacity(0.15), in: Capsule())
                                    }
                                    Spacer()
                                    Text("每 \(f.headwayText)").foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                            if let tts = entry.timetables, !tts.isEmpty {
                                let byDay = Dictionary(grouping: tts.filter { $0.time != "—" },
                                                       by: \.serviceDayLabel)
                                ForEach(byDay.keys.sorted(), id: \.self) { day in
                                    VStack(alignment: .leading, spacing: 3) {
                                        if !day.isEmpty {
                                            Text(day)
                                                .font(.caption2)
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(.tint.opacity(0.15), in: Capsule())
                                        }
                                        Text((byDay[day] ?? []).map(\.time).sorted().joined(separator: "　"))
                                            .font(.callout.monospacedDigit())
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("路線資訊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
