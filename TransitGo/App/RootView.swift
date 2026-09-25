import SwiftUI
import CoreLocation

struct RootView: View {
    @State private var pending = PendingNavigation.shared
    @State private var siriTarget: SiriNavigationTarget?
    @State private var siriNotFound: String?

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
        .adaptiveSidebar()
        .task {
            await RailAlertService.shared.refresh()
        }
        // "嘿 Siri，用交通即時查導航到…": the intent only records the request; resolve and open the navigation here.
        .task(id: pending.request?.id) {
            guard let request = pending.request else { return }
            pending.clear()
            let here = CLLocationManager().location?.coordinate
            if let target = await SiriDestinationResolver.resolve(request, near: here) {
                siriTarget = target
            } else {
                siriNotFound = request.query
            }
        }
        .fullScreenCover(item: $siriTarget) { target in
            InAppNavigationView(destination: target.coordinate, destinationName: target.name,
                                transportType: target.mode.transportType, avoidsHighways: target.mode.avoidsHighways)
        }
        .alert("找不到目的地", isPresented: Binding(get: { siriNotFound != nil }, set: { if !$0 { siriNotFound = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text("找不到「\(siriNotFound ?? "")」，換個說法再試一次。")
        }
    }
}

extension View {
    /// Wide screens (iPad, an unfolded / dual-screen iPhone, a large iPhone on its side) get a sidebar instead of a
    /// bottom tab bar, and the content fills the space beside it; a narrow screen keeps the tab bar. It is the SAME
    /// TabView adapting, not a second view tree, so folding or unfolding mid-trip cannot tear down a navigation that
    /// is on screen. iOS 17 has no adaptive style and simply keeps the tab bar.
    @ViewBuilder func adaptiveSidebar() -> some View {
        if #available(iOS 18.0, *) { tabViewStyle(.sidebarAdaptable) } else { self }
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
