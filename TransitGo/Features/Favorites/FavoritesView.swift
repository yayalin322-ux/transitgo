import SwiftUI
import SwiftData

/// The ★ sheet on the home page. Picking a favourite hands it back so the caller
/// opens it as a normal full page (same `BusRouteDetailView` / `BikeStationDetailView`
/// reached from every other entry point).
struct FavoritesView: View {
    var onOpen: (FavoriteItem) -> Void
    /// Opens a saved journey (the caller records the use and plans it again).
    var onOpenTrip: ((FavoriteTrip) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \FavoriteItem.createdAt, order: .reverse) private var items: [FavoriteItem]
    @Query private var trips: [FavoriteTrip]
    @State private var editing: FavoriteTrip?

    /// Favorites are grouped by what they are — journeys, bus routes, stops, bike stations — never one mixed list.
    private func items(of kinds: [FavoriteKind]) -> [FavoriteItem] {
        items.filter { kinds.contains(FavoriteKind(rawValue: $0.kind) ?? .busRoute) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty && trips.isEmpty {
                    ContentUnavailableView("尚無最愛", systemImage: "star",
                                           description: Text("在路線頁或 YouBike 站點頁點星號、或在轉乘規劃儲存常用旅程"))
                } else {
                    List {
                        if !trips.isEmpty {
                            Section("常用旅程") {
                                ForEach(TripStore(context: context).favorites()) { trip in
                                    Button { onOpenTrip?(trip); dismiss() } label: { FavoriteTripRow(trip: trip) }
                                        .buttonStyle(.plain)
                                        .swipeActions {
                                            Button("刪除", role: .destructive) { try? TripStore(context: context).delete(trip) }
                                            Button("編輯") { editing = trip }.tint(.blue)
                                        }
                                }
                            }
                        }
                        favoriteSection("公車路線", items(of: [.busRoute]))
                        favoriteSection("站牌", items(of: [.busStop]))
                        favoriteSection("YouBike 站點", items(of: [.bikeStation]))
                    }
                }
            }
            .navigationTitle("我的最愛")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $editing) { trip in
            FavoriteTripEditor(existing: trip, initial: nil, context: TripEditorContext(city: nil, near: nil))
        }
    }

    @ViewBuilder
    private func favoriteSection(_ title: String, _ list: [FavoriteItem]) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list) { item in
                    Button { onOpen(item); dismiss() } label: { row(item) }.buttonStyle(.plain)
                }
                .onDelete { offsets in for i in offsets { context.delete(list[i]) } }
            }
        }
    }

    private func row(_ item: FavoriteItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: FavoriteKind(rawValue: item.kind) == .bikeStation ? "bicycle" : "bus.fill")
                .foregroundStyle(FavoriteKind(rawValue: item.kind) == .bikeStation ? .green : .blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline).foregroundStyle(.primary)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// Builds the destination for a favourite. Shared by the home nav stack.
@MainActor
enum FavoriteDestination {
    @ViewBuilder
    static func view(for item: FavoriteItem) -> some View {
        if FavoriteKind(rawValue: item.kind) == .bikeStation, let bikeCity = BikeCity(rawValue: item.city) {
            BikeStationDetailView(
                city: bikeCity,
                station: BikeStation(
                    stationUID: item.routeName,
                    stationName: LocalizedName(zhTw: item.title, en: nil),
                    stationPosition: (item.lat != 0 || item.lon != 0)
                        ? GeoPoint(lat: item.lat, lon: item.lon) : nil,
                    stationAddress: LocalizedName(zhTw: item.subtitle, en: nil),
                    bikesCapacity: nil
                )
            )
        } else if let scope = item.busScope {
            BusRouteDetailView(
                scope: scope,
                route: BusRoute(
                    routeUID: item.routeName,
                    routeName: LocalizedName(zhTw: item.routeName, en: nil),
                    departureStopNameZh: nil,
                    destinationStopNameZh: nil
                )
            )
        } else {
            ContentUnavailableView("無法開啟", systemImage: "exclamationmark.triangle")
        }
    }
}
