import SwiftUI
import MapKit
import CoreLocation

/// Picks a real YouBike leg: a station that actually has bikes near where you start, AND
/// a station that actually has empty docks near where you're going — you can't just ride
/// straight to an arbitrary destination and leave the bike there, you dock it, then walk
/// the last stretch. Also keeps a live distance readout to the chosen pickup station and
/// nudges the user to switch stations if they're visibly moving away from it.
struct YouBikeLegPickerView: View {
    let destination: CLLocationCoordinate2D
    /// The trip's actual starting point — may be a searched/overridden origin far from
    /// where the phone physically is right now (e.g. planning a trip in a different
    /// county). Station candidates search around *this*, not live GPS, or a cross-county
    /// trip would only ever show bike stations near wherever the user happens to be
    /// standing, which looked exactly like "YouBike can't do cross-county trips".
    var anchor: CLLocationCoordinate2D?

    @Environment(\.dismiss) private var dismiss
    @State private var location = LocationManager()

    @State private var rentCandidates: [BikeStationLive] = []
    @State private var selectedRent: BikeStationLive?
    @State private var isLoadingRent = true
    @State private var requireElectric = false
    @State private var initialDistance: CLLocationDistance?
    @State private var driftedAway = false

    @State private var returnCandidates: [BikeStationLive] = []
    @State private var selectedReturn: BikeStationLive?
    @State private var isLoadingReturn = true

    @State private var startNavigation = false
    private let poll = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    /// The full walk → cycle → walk trip as ONE continuous navigation session — reaching
    /// the rent/return station is just a speed change mid-route, not a stop the user has to
    /// manually restart navigation at.
    private var legs: [NavigationLeg] {
        guard let rent = selectedRent, let rentCoord = rent.station.coordinate,
              let ret = selectedReturn, let retCoord = ret.station.coordinate else { return [] }
        return [
            NavigationLeg(coordinate: rentCoord, name: rent.station.name, transportType: .walking,
                          waypointAnnouncement: "已抵達\(rent.station.name)，借車後繼續前往下一站"),
            NavigationLeg(coordinate: retCoord, name: ret.station.name, transportType: .cycling,
                          waypointAnnouncement: "已抵達\(ret.station.name)，還車後繼續步行前往目的地"),
            NavigationLeg(coordinate: destination, name: "目的地", transportType: .walking),
        ]
    }

    private var filteredRent: [BikeStationLive] {
        guard requireElectric else { return rentCandidates }
        return rentCandidates.filter { ($0.availability?.availableRentBikesDetail?.electricBikes ?? 0) > 0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("借車站一定要有電輔車", isOn: $requireElectric)
                }

                Section("1. 借車站（附近有車）") {
                    if let s = selectedRent {
                        stationRow(s, countLabel: "輛可借")
                            .listRowBackground(Color.accentColor.opacity(0.08))
                        if let d = currentDistance(to: s) {
                            Label("距離約 \(Int(d)) 公尺", systemImage: "location.fill")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if driftedAway {
                            Label("你好像越走越遠了，要不要換一個更近的站？", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    if isLoadingRent {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if filteredRent.isEmpty {
                        Text(requireElectric ? "附近沒有電輔車站點，可以取消勾選試試" : "附近查不到有車的站點")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredRent) { s in
                            if s.id != selectedRent?.id {
                                Button { selectRent(s) } label: { stationRow(s, countLabel: "輛可借") }
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }

                Section("2. 還車站（目的地附近有空位）") {
                    if let s = selectedReturn {
                        stationRow(s, countLabel: "個空位", useReturn: true)
                            .listRowBackground(Color.accentColor.opacity(0.08))
                    }
                    if isLoadingReturn {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if returnCandidates.isEmpty {
                        Text("目的地附近查不到有空位可還車的站點").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(returnCandidates) { s in
                            if s.id != selectedReturn?.id {
                                Button { selectedReturn = s } label: { stationRow(s, countLabel: "個空位", useReturn: true) }
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }

                if selectedRent != nil, selectedReturn != nil {
                    Section {
                        Button { startNavigation = true } label: {
                            Label("開始導航（走路→騎車→走路，全程不中斷）", systemImage: "location.north.line.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } footer: {
                        Text("一路導航到底：走去借車站、騎到還車站、還車後走到目的地會自動接續，不用中途手動切換。")
                    }
                }
            }
            .navigationTitle("YouBike 路段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
            }
            .onAppear {
                location.request()
                Prewarm.wakeBackend()
            }
            .task { await loadRentCandidates() }
            .task { await loadReturnCandidates() }
            .onReceive(poll) { _ in
                location.request()
                checkDrift()
            }
            .fullScreenCover(isPresented: $startNavigation) {
                InAppNavigationView(legs: legs, tripName: "目的地")
            }
        }
    }

    private func stationRow(_ s: BikeStationLive, countLabel: String, useReturn: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.station.name).font(.subheadline.weight(.semibold))
                if let d = s.availability?.availableRentBikesDetail, !useReturn {
                    Text("一般 \(d.generalBikes ?? 0)・電輔 \(d.electricBikes ?? 0)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(useReturn ? s.ret : s.rent) \(countLabel)").font(.caption.weight(.semibold)).foregroundStyle(useReturn ? .blue : .green)
        }
    }

    private func selectRent(_ s: BikeStationLive) {
        selectedRent = s
        initialDistance = currentDistance(to: s)
        driftedAway = false
    }

    private func currentDistance(to s: BikeStationLive) -> CLLocationDistance? {
        guard let here = location.location, let c = s.station.coordinate else { return nil }
        return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here)
    }

    private func checkDrift() {
        guard let s = selectedRent, let initial = initialDistance, let now = currentDistance(to: s) else { return }
        driftedAway = now > initial + 100   // clearly moving the wrong way, not just GPS noise
    }

    private func loadRentCandidates() async {
        let origin = anchor ?? location.location?.coordinate
        guard let coord = origin else {
            try? await Task.sleep(for: .seconds(1))
            guard let retry = location.location?.coordinate else { isLoadingRent = false; return }
            await loadRentCandidates(near: retry)
            return
        }
        await loadRentCandidates(near: coord)
    }

    private func loadRentCandidates(near coord: CLLocationCoordinate2D) async {
        isLoadingRent = true
        defer { isLoadingRent = false }
        var list = await nearby(coord)
        list = list.filter { $0.rent > 0 }.sorted { $0.distance < $1.distance }
        rentCandidates = list
        if selectedRent == nil, let first = list.first { selectRent(first) }
    }

    private func loadReturnCandidates() async {
        isLoadingReturn = true
        defer { isLoadingReturn = false }
        var list = await nearby(destination)
        list = list.filter { $0.ret > 0 }.sorted { $0.distance < $1.distance }
        returnCandidates = list
        if selectedReturn == nil { selectedReturn = list.first }
    }

    /// The shared backend cache (one fast, already-pooled request, cross-city already —
    /// see round 26) first; TDX direct only as a fallback when there's no backend or it's
    /// empty. Going straight to TDX (the old behaviour here) meant fetching each nearby
    /// city's *entire* availability table directly, which is slow — especially doubled up
    /// for both the rent and return searches running at once.
    private func nearby(_ coord: CLLocationCoordinate2D) async -> [BikeStationLive] {
        if let shared = await SharedBikeService.nearby(near: coord, radius: 700, city: nil), !shared.isEmpty {
            return shared
        }
        let cities = BikeCity.nearest(to: coord, count: 2)
        return await BikeService.shared.nearbyLive(cities: cities, near: coord, radius: 700)
    }
}
