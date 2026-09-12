import SwiftUI
import SwiftData

@MainActor
@Observable
final class AddTicketViewModel {
    enum Mode: String, CaseIterable { case search, byNumber
        var label: String { self == .search ? "查詢車次" : "直接輸入車次" }
    }

    var mode: Mode = .search
    var system: RailSystem = .tra
    var origin: RailStation?
    var destination: RailStation?
    var date: Date = .now

    // search mode
    var runs: [TrainRun] = []
    var selectedRun: TrainRun?
    var isSearching = false
    var errorText: String?
    /// When a direct search comes back empty (TRA only) — a trunk-to-branch-line trip
    /// needs an actual transfer, which a plain OD search can't find on its own.
    var transferSuggestions: [RailItinerary] = []

    // by-number mode
    var trainNoInput = ""
    var resolvedType = ""
    var manualDep: Date = .now
    var manualArr: Date = Date().addingTimeInterval(3600)
    var lookedUp = false
    var lookupError: String?
    var isLookingUp = false

    var carNo = ""
    var seatNo = ""
    var reminderLead = 30

    var canSearch: Bool { origin != nil && destination != nil && origin?.id != destination?.id }

    var displayRuns: [TrainRun] {
        let hm = Calendar.current.dateComponents([.hour, .minute], from: date)
        let cutoff = String(format: "%02d:%02d", hm.hour ?? 0, hm.minute ?? 0)
        let after = runs.filter { $0.departure >= cutoff }
        return after.isEmpty ? runs : after
    }

    var canSave: Bool {
        guard origin != nil, destination != nil, origin?.id != destination?.id else { return false }
        switch mode {
        case .search: return selectedRun != nil
        case .byNumber: return !trainNoInput.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func search() async {
        guard let origin, let destination else { return }
        isSearching = true; errorText = nil; selectedRun = nil; transferSuggestions = []
        defer { isSearching = false }
        do {
            runs = try await RailService.shared.timetable(system: system, from: origin, to: destination, date: date)
        } catch {
            errorText = error.localizedDescription; runs = []
        }
        if runs.isEmpty, system == .tra {
            transferSuggestions = await RailTransferPlanner.plan(from: origin, to: destination, date: date)
            if !transferSuggestions.isEmpty {
                errorText = "沒有直達車次，但可以轉乘"
            }
        }
    }

    /// Builds a ticket for one leg of a transfer suggestion (not the picked `selectedRun`).
    func ticket(for leg: RailLeg) -> RailTicket {
        RailTicket(
            system: .tra, serviceDate: Calendar.current.startOfDay(for: date),
            trainNo: leg.train.trainNo, trainType: leg.train.trainType,
            fromStationID: leg.fromStation.id, fromName: leg.fromStation.name,
            toStationID: leg.toStation.id, toName: leg.toStation.name,
            depTime: leg.train.departure, arrTime: leg.train.arrival,
            carNo: "", seatNo: "", reminderLeadMinutes: reminderLead
        )
    }

    func lookup() async {
        let no = trainNoInput.trimmingCharacters(in: .whitespaces)
        guard let origin, let destination, !no.isEmpty else { return }
        isLookingUp = true; lookupError = nil
        defer { isLookingUp = false }
        do {
            guard let d = try await RailService.shared.trainDetail(system: system, trainNo: no) else {
                lookupError = "查無此車次（TDX 僅提供「當日」車次時刻，其他日期請直接填寫時間）"
                return
            }
            resolvedType = d.trainType
            let dep = d.departure(atStationID: origin.id)
            let arr = d.arrival(atStationID: destination.id)
            if let dep, let x = RailTime.combine(date, dep) { manualDep = x }
            if let arr, let x = RailTime.combine(date, arr) { manualArr = x }
            lookedUp = true
            if dep == nil || arr == nil {
                lookupError = "此車次停靠站不含所選起訖站，請確認或手動填寫時間"
            }
        } catch {
            lookupError = error.localizedDescription
        }
    }

    func makeTicket() -> RailTicket? {
        guard let origin, let destination else { return nil }
        let serviceDate = Calendar.current.startOfDay(for: date)
        switch mode {
        case .search:
            guard let run = selectedRun else { return nil }
            return RailTicket(
                system: system, serviceDate: serviceDate,
                trainNo: run.trainNo, trainType: run.trainType,
                fromStationID: origin.id, fromName: origin.name,
                toStationID: destination.id, toName: destination.name,
                depTime: run.departure, arrTime: run.arrival,
                carNo: carNo.trimmingCharacters(in: .whitespaces),
                seatNo: seatNo.trimmingCharacters(in: .whitespaces),
                reminderLeadMinutes: reminderLead
            )
        case .byNumber:
            return RailTicket(
                system: system, serviceDate: serviceDate,
                trainNo: trainNoInput.trimmingCharacters(in: .whitespaces),
                trainType: resolvedType,
                fromStationID: origin.id, fromName: origin.name,
                toStationID: destination.id, toName: destination.name,
                depTime: Self.hhmm(manualDep), arrTime: Self.hhmm(manualArr),
                carNo: carNo.trimmingCharacters(in: .whitespaces),
                seatNo: seatNo.trimmingCharacters(in: .whitespaces),
                reminderLeadMinutes: reminderLead
            )
        }
    }

    private static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

struct AddTicketView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var model = AddTicketViewModel()
    @State private var store = RailStationStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("方式", selection: $model.mode) {
                        ForEach(AddTicketViewModel.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("行程") {
                    Picker("系統", selection: $model.system) {
                        ForEach(RailSystem.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.system) { _, _ in resetTrip() }

                    if model.mode == .byNumber {
                        TextField("車次，例如 123 / 0803", text: $model.trainNoInput)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    stationPicker("起站", selection: $model.origin)
                    stationPicker("到站", selection: $model.destination)
                    DatePicker("日期／出發時間", selection: $model.date, in: dateRange,
                              displayedComponents: [.date, .hourAndMinute])

                    if model.mode == .search {
                        Button {
                            Task { await model.search() }
                        } label: {
                            HStack { Spacer(); Text("查詢車次"); Spacer() }
                        }
                        .disabled(!model.canSearch || model.isSearching)
                    } else {
                        Button {
                            Task { await model.lookup() }
                        } label: {
                            HStack { Spacer(); Text("帶入時刻（當日）"); Spacer() }
                        }
                        .disabled(!model.canSearch || model.trainNoInput.isEmpty || model.isLookingUp)
                    }
                }

                if let err = model.errorText ?? model.lookupError {
                    Section { Text(err).font(.footnote).foregroundStyle(.orange) }
                }

                if model.mode == .search {
                    if model.isSearching {
                        Section { HStack { Spacer(); ProgressView(); Spacer() } }
                    } else if !model.transferSuggestions.isEmpty {
                        ForEach(model.transferSuggestions) { itinerary in
                            Section {
                                ForEach(Array(itinerary.legs.enumerated()), id: \.element.id) { index, leg in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(index + 1). \(leg.train.trainType) \(leg.train.trainNo)")
                                            .font(.subheadline.weight(.medium))
                                        Text("\(leg.fromStation.name) \(leg.train.departure) → \(leg.toStation.name) \(leg.train.arrival)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Button {
                                    let tickets = itinerary.legs.map { model.ticket(for: $0) }
                                    for t in tickets { context.insert(t) }
                                    Task {
                                        await TicketReminders.requestAuthIfNeeded()
                                        for t in tickets { TicketReminders.reschedule(for: t) }
                                    }
                                    dismiss()
                                } label: {
                                    Label("兩段都加入車票", systemImage: "plus.circle.fill")
                                }
                            } header: {
                                if let wait = itinerary.transferWaitMinutes {
                                    Text("在 \(itinerary.legs[0].toStation.name) 轉車・等 \(wait) 分鐘")
                                } else {
                                    Text("轉乘一次")
                                }
                            }
                        }
                    } else if !model.runs.isEmpty {
                        Section("選擇車次") {
                            ForEach(model.displayRuns) { run in
                                Button {
                                    model.selectedRun = run
                                } label: {
                                    HStack {
                                        Image(systemName: model.selectedRun?.id == run.id
                                              ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(.tint)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(run.trainType.isEmpty ? "車次 \(run.trainNo)" : "\(run.trainType) \(run.trainNo)")
                                                .font(.subheadline.weight(.medium))
                                            Text("\(run.departure) → \(run.arrival)　\(run.durationText)")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Section("時刻") {
                        DatePicker("發車時間", selection: $model.manualDep, displayedComponents: .hourAndMinute)
                        DatePicker("抵達時間", selection: $model.manualArr, displayedComponents: .hourAndMinute)
                        if !model.resolvedType.isEmpty {
                            LabeledContent("車種", value: model.resolvedType)
                        }
                    }
                }

                if model.canSave {
                    Section("座位（選填）") {
                        TextField("車廂，例如 10", text: $model.carNo)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("座位，例如 5A", text: $model.seatNo)
                    }
                    Section {
                        Picker("發車提醒", selection: $model.reminderLead) {
                            ForEach(TicketReminders.leadChoices, id: \.self) { m in
                                Text(TicketReminders.label(forLead: m)).tag(m)
                            }
                        }
                    } footer: {
                        Text("到時間會推播提醒你準備上車。")
                    }
                }
            }
            .navigationTitle("新增車票")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        if let ticket = model.makeTicket() {
                            context.insert(ticket)
                            Task {
                                await TicketReminders.requestAuthIfNeeded()
                                TicketReminders.reschedule(for: ticket)
                            }
                            dismiss()
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
            .task { await store.loadIfNeeded() }
        }
    }

    private func resetTrip() {
        model.origin = nil; model.destination = nil
        model.runs = []; model.selectedRun = nil
        model.lookedUp = false; model.resolvedType = ""
    }

    private var dateRange: ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: .now)
        return today...Calendar.current.date(byAdding: .day, value: 29, to: today)!
    }

    @ViewBuilder
    private func stationPicker(_ title: String, selection: Binding<RailStation?>) -> some View {
        Picker(title, selection: selection) {
            Text("請選擇").tag(RailStation?.none)
            ForEach(store.stations(for: model.system)) { s in
                Text(s.name).tag(RailStation?.some(s))
            }
        }
    }
}
