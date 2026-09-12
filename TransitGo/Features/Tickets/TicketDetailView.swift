import SwiftUI

struct TicketDetailView: View {
    @Bindable var ticket: RailTicket

    @State private var tracker = RailTripTracker.shared
    @State private var live: TrainLiveStatus?
    @State private var checkingLive = false
    @State private var fare: RailFareInfo?
    @State private var now = Date()

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var accent: Color { ticket.system == .tra ? .blue : .orange }
    private var isThisTracked: Bool {
        tracker.isTracking && tracker.trackedTrainNo == ticket.trainNo
    }

    var body: some View {
        List {
            Section {
                heroCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("發車提醒") {
                Picker("提前提醒", selection: $ticket.reminderLeadMinutes) {
                    ForEach(TicketReminders.leadChoices, id: \.self) { m in
                        Text(TicketReminders.label(forLead: m)).tag(m)
                    }
                }
                .onChange(of: ticket.reminderLeadMinutes) { _, _ in
                    Task {
                        await TicketReminders.requestAuthIfNeeded()
                        TicketReminders.reschedule(for: ticket)
                    }
                }
            }

            Section {
                NavigationLink {
                    TrainDetailView(
                        system: ticket.system,
                        trainNo: ticket.trainNo,
                        highlightFromID: ticket.fromStationID,
                        highlightToID: ticket.toStationID
                    )
                } label: {
                    Label("各站時刻・票價・列車資訊", systemImage: "list.bullet.rectangle")
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
                    Text(ticket.system == .thsr ? "含半票與早鳥參考價，實際以購票為準。" : "實際票價以購票金額為準。")
                }
            }

            if ticket.system == .tra {
                Section("即時狀態") {
                    if checkingLive {
                        HStack { Text("查詢中"); Spacer(); ProgressView() }
                    } else if let live {
                        LabeledContent("誤點") {
                            Text(live.delayMinutes <= 0 ? "準點" : "誤點 \(live.delayMinutes) 分")
                                .foregroundStyle(live.delayMinutes <= 0 ? .green : .orange)
                                .fontWeight(.semibold)
                        }
                        LabeledContent("位置", value: live.statusText)
                    } else {
                        Text("目前查無這班車的即時動態（可能尚未發車或已到終點）。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("重新整理") { Task { await loadLive() } }
                        .disabled(checkingLive)
                }
            }

            Section {
                if isThisTracked {
                    Button(role: .destructive) {
                        Task { await tracker.stop() }
                    } label: {
                        Label("停止追蹤", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        Task { await tracker.start(ticket: ticket) }
                    } label: {
                        Label("開始追蹤（靈動島）", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(!tracker.isActivitiesEnabled)
                }
                if let err = tracker.lastError {
                    Text(err).font(.footnote).foregroundStyle(.orange)
                }
            } footer: {
                Text("追蹤後會在鎖定畫面與靈動島顯示發車／抵達倒數、誤點與座位。")
            }
        }
        .navigationTitle(ticket.trainLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLive() }
        .task {
            fare = await RailFareService.shared.fare(
                system: ticket.system, fromID: ticket.fromStationID, toID: ticket.toStationID
            )
        }
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text(ticket.system.displayName)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.25), in: Capsule())
                Text(ticket.trainLabel).font(.title3.bold())
                Spacer()
                Text(ticket.serviceDate.formatted(.dateTime.year().month().day().weekday()))
                    .font(.caption)
            }
            .foregroundStyle(.white)

            HStack(alignment: .top) {
                journeyEnd(ticket.fromName, ticket.depTime, align: .leading)
                Spacer()
                VStack(spacing: 4) {
                    Text(headlineText)
                        .font(.headline).foregroundStyle(.white)
                        .monospacedDigit()
                    progressBar
                }
                .frame(maxWidth: 150)
                Spacer()
                journeyEnd(ticket.toName, ticket.arrTime, align: .trailing)
            }

            HStack {
                if !ticket.seatLabel.isEmpty {
                    Label(ticket.seatLabel, systemImage: "chair.lounge.fill")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                if let live, ticket.system == .tra {
                    Text(live.delayMinutes <= 0 ? "準點" : "誤點 \(live.delayMinutes) 分")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.22), in: Capsule())
                }
            }
            .foregroundStyle(.white)
        }
        .padding(18)
        .background(accent.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let p = ticket.progress
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(.white).frame(width: max(4, geo.size.width * p), height: 4)
                Circle().fill(.white).frame(width: 9, height: 9)
                    .offset(x: min(geo.size.width - 9, max(0, geo.size.width * p - 4.5)))
            }
        }
        .frame(height: 10)
    }

    private var headlineText: String {
        _ = now
        switch ticket.phase {
        case .upcoming: return ticket.countdownText
        case .enRoute:
            guard let arr = ticket.arrivalDate else { return "行駛中" }
            let m = max(1, Int(arr.timeIntervalSinceNow / 60))
            return m < 60 ? "距抵達 \(m) 分" : "行駛中"
        case .arrived: return "已抵達"
        }
    }

    private func journeyEnd(_ name: String, _ time: String, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 3) {
            Text(name).font(.subheadline.weight(.semibold))
            Text(time).font(.title2.bold().monospacedDigit())
        }
        .foregroundStyle(.white)
    }

    private func loadLive() async {
        guard ticket.system == .tra else { return }
        checkingLive = true
        defer { checkingLive = false }
        live = try? await RailService.shared.liveStatus(system: .tra, trainNo: ticket.trainNo)
    }
}
