import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首頁", systemImage: "house.fill") }

            BusSearchView()
                .tabItem { Label("公車", systemImage: "bus.fill") }

            NearbyStopsView()
                .tabItem { Label("附近", systemImage: "location.fill") }

            RailHubView()
                .tabItem { Label("軌道", systemImage: "tram.fill") }

            TicketsView()
                .tabItem { Label("車票", systemImage: "ticket.fill") }
        }
        .task {
            await RailAlertService.shared.refresh()
        }
    }
}

/// 台鐵 / 高鐵 / 捷運 hub, with the live-notification bell.
struct RailHubView: View {
    @State private var section = 0
    @State private var showAnnouncements = false
    @State private var announcements = AnnouncementService.shared
    @State private var railAlerts = RailAlertService.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $section) {
                    Text("台鐵高鐵").tag(0)
                    Text("捷運").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)

                AnnouncementBanner(categories: ["rail", "metro"], includeRailAlerts: true)

                if section == 0 {
                    RailSearchView()
                } else {
                    MetroBrowserView()
                        .navigationTitle("捷運")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAnnouncements = true
                    } label: {
                        Image(systemName: announcements.unreadCount > 0
                              ? "bell.badge.fill" : "bell")
                    }
                }
            }
            .sheet(isPresented: $showAnnouncements) { AnnouncementsView() }
            .task {
                await announcements.refresh()
                await railAlerts.refresh()
            }
        }
    }
}

#Preview {
    RootView()
}
