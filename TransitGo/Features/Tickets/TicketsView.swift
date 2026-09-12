import SwiftUI
import SwiftData

struct TicketsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\RailTicket.serviceDate), SortDescriptor(\RailTicket.depTime)])
    private var tickets: [RailTicket]

    @State private var showAdd = false

    private var upcoming: [RailTicket] { tickets.filter { !$0.isPast } }
    private var past: [RailTicket] { tickets.filter(\.isPast).reversed() }

    var body: some View {
        NavigationStack {
            Group {
                if tickets.isEmpty {
                    ContentUnavailableView {
                        Label("尚無車票", systemImage: "ticket")
                    } description: {
                        Text("新增台鐵／高鐵車票，選擇日期、車次與座位，即可追蹤發車與誤點。")
                    } actions: {
                        Button("新增車票") { showAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if !upcoming.isEmpty {
                            Section("即將出發") {
                                ForEach(upcoming) { ticket in
                                    ZStack {
                                        TicketCard(ticket: ticket)
                                        NavigationLink { TicketDetailView(ticket: ticket) } label: { EmptyView() }
                                            .opacity(0)
                                    }
                                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                    .listRowSeparator(.hidden)
                                }
                                .onDelete { delete($0, from: upcoming) }
                            }
                        }
                        if !past.isEmpty {
                            Section("已結束") {
                                ForEach(past) { ticket in
                                    NavigationLink { TicketDetailView(ticket: ticket) } label: {
                                        pastRow(ticket)
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                .onDelete { delete($0, from: past) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("我的車票")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddTicketView() }
        }
    }

    private func pastRow(_ t: RailTicket) -> some View {
        HStack {
            Text(t.system.displayName)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.tint.opacity(0.12), in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(t.fromName) → \(t.toName)").font(.subheadline)
                Text("\(t.serviceDate.formatted(.dateTime.month().day()))　\(t.depTime)–\(t.arrTime)")
                    .font(.caption).monospacedDigit()
            }
            Spacer()
            Text(t.trainLabel).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func delete(_ offsets: IndexSet, from list: [RailTicket]) {
        for i in offsets {
            TicketReminders.cancel(for: list[i])
            context.delete(list[i])
        }
    }
}

/// Boarding-pass style card for an upcoming ticket.
private struct TicketCard: View {
    let ticket: RailTicket

    private var accent: Color { ticket.system == .tra ? .blue : .orange }

    var body: some View {
        VStack(spacing: 0) {
            // Top: train + date + countdown
            HStack(alignment: .firstTextBaseline) {
                Text(ticket.system.displayName)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.white.opacity(0.25), in: Capsule())
                Text(ticket.trainLabel).font(.headline)
                Spacer()
                Text(ticket.serviceDate.formatted(.dateTime.month().day().weekday(.short)))
                    .font(.caption)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)

            // Body: OD + times
            HStack(alignment: .center) {
                stationEnd(ticket.fromName, ticket.depTime)
                VStack(spacing: 2) {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                    Text(Fmt.duration(from: ticket.depTime, to: ticket.arrTime))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                stationEnd(ticket.toName, ticket.arrTime)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.background)

            Divider()

            // Footer: seat + countdown + reminder
            HStack(spacing: 10) {
                if !ticket.seatLabel.isEmpty {
                    Label(ticket.seatLabel, systemImage: "chair.lounge.fill")
                        .font(.caption.weight(.medium))
                }
                if ticket.reminderLeadMinutes > 0 {
                    Label("\(ticket.reminderLeadMinutes) 分", systemImage: "bell.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ticket.countdownText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.background)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.gradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.black.opacity(0.06))
        )
    }

    private func stationEnd(_ name: String, _ time: String) -> some View {
        VStack(spacing: 3) {
            Text(name).font(.callout.weight(.semibold)).lineLimit(1)
            Text(time).font(.title3.bold().monospacedDigit())
        }
    }
}
