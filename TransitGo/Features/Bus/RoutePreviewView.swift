import SwiftUI
import MapKit
import CoreLocation

/// What to preview: a drive/ride/walk from any start (not only where you are) to a destination.
struct RoutePreviewTarget: Identifiable {
    let id = UUID()
    let originName: String
    let origin: CLLocationCoordinate2D
    /// True when the start is the phone's own location — only then does "開始導航" match the preview.
    let originIsCurrentLocation: Bool
    let destinationName: String
    let destination: CLLocationCoordinate2D
    let transportType: MKDirectionsTransportType
    var avoidsHighways: Bool? = nil
    var departAt: Date = Date()
}

/// Preview a route before navigating, like other map apps: any start point, a departure time,
/// alternatives (with the one that avoids 巷／弄 marked), the roads it passes, and the arrival time.
struct RoutePreviewView: View {
    let target: RoutePreviewTarget
    @Environment(\.dismiss) private var dismiss
    @State private var departAt: Date
    @State private var departNow = true
    @State private var routes: [MKRoute] = []
    @State private var selected = 0
    @State private var recommended = 0
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var camera: MapCameraPosition = .automatic
    @State private var startNavigation = false
    @State private var confirmStart = false

    init(target: RoutePreviewTarget) {
        self.target = target
        _departAt = State(initialValue: target.departAt)
    }

    private var route: MKRoute? { routes.indices.contains(selected) ? routes[selected] : nil }
    private var departure: Date { departNow ? Date() : max(departAt, Date()) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $camera) {
                    ForEach(Array(routes.enumerated()), id: \.offset) { i, r in
                        MapPolyline(r.polyline)
                            .stroke(i == selected ? Color.blue : Color.gray.opacity(0.55), lineWidth: i == selected ? 7 : 4)
                    }
                    Marker(target.originName, coordinate: target.origin).tint(.green)
                    Marker(target.destinationName, coordinate: target.destination).tint(.red)
                }
                .frame(height: 260)

                List {
                    Section {
                        Toggle("現在出發", isOn: $departNow)
                        if !departNow {
                            DatePicker("出發時間", selection: $departAt, in: Date()...)
                        }
                    } footer: {
                        if target.transportType == .automobile {
                            Text("開車的預估時間會參考 Apple 地圖對該時段的預測；沒有資料時為一般路況。")
                        }
                    }

                    if isLoading {
                        Section { HStack { Spacer(); ProgressView("計算路線中…"); Spacer() } }
                    } else if let errorText {
                        Section { Text(errorText).foregroundStyle(.red) }
                    } else {
                        Section("路線") {
                            ForEach(Array(routes.enumerated()), id: \.offset) { i, r in
                                Button { selected = i; fit() } label: { routeRow(i, r) }.foregroundStyle(.primary)
                            }
                        }
                        if let route {
                            Section("沿途經過") {
                                ForEach(Array(route.steps.enumerated()), id: \.offset) { _, step in
                                    if !step.instructions.isEmpty {
                                        HStack {
                                            Text(step.instructions)
                                            Spacer()
                                            Text(distanceText(step.distance)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("路線預覽")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("開始導航") {
                        if target.originIsCurrentLocation { startNavigation = true } else { confirmStart = true }
                    }
                    .disabled(route == nil)
                }
            }
            .confirmationDialog("導航會從你目前的位置開始", isPresented: $confirmStart, titleVisibility: .visible) {
                Button("從目前位置導航到\(target.destinationName)") { startNavigation = true }
                Button("取消", role: .cancel) {}
            } message: { Text("預覽的起點是「\(target.originName)」，實際導航只能跟著你現在的位置走。") }
            .fullScreenCover(isPresented: $startNavigation) {
                InAppNavigationView(destination: target.destination, destinationName: target.destinationName,
                                    transportType: target.transportType, avoidsHighways: target.avoidsHighways)
            }
            .task(id: "\(departNow)-\(Int(departAt.timeIntervalSince1970 / 60))") { await load() }
        }
    }

    private func routeRow(_ i: Int, _ r: MKRoute) -> some View {
        let depart = departure
        let arrive = depart.addingTimeInterval(r.expectedTravelTime)
        return HStack {
            Image(systemName: i == selected ? "checkmark.circle.fill" : "circle").foregroundStyle(i == selected ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(durationText(r.expectedTravelTime)).font(.headline)
                    Text(distanceText(r.distance)).font(.subheadline).foregroundStyle(.secondary)
                    if i == recommended && routes.count > 1 { Text("推薦").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(.blue.opacity(0.15), in: Capsule()) }
                }
                Text("\(Self.clock.string(from: depart)) 出發 → \(Self.clock.string(from: arrive)) 抵達")
                    .font(.caption).foregroundStyle(.secondary)
                let lanes = RouteScoring.laneStepCount(RouteScoring.option(from: r))
                if lanes > 0 { Text("經過 \(lanes) 段巷／弄").font(.caption2).foregroundStyle(.orange) }
            }
        }
    }

    private func load() async {
        isLoading = true; errorText = nil
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: target.origin))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: RoadAnchors.anchor(for: target.destination)?.anchor ?? target.destination))
        req.transportType = target.transportType
        req.requestsAlternateRoutes = true
        if target.transportType == .automobile { req.departureDate = departure }
        guard let response = try? await MKDirections(request: req).calculate(), !response.routes.isEmpty else {
            routes = []; errorText = "找不到路線"; isLoading = false; return
        }
        var pool = response.routes
        if target.avoidsHighways == true {
            let free = pool.filter { !InAppNavigationView.usesHighway($0) }
            if !free.isEmpty { pool = free }
        }
        routes = pool
        recommended = target.transportType == .automobile ? (RouteScoring.bestIndex(pool.map(RouteScoring.option(from:))) ?? 0) : 0
        selected = recommended
        isLoading = false
        fit()
    }

    private func fit() {
        guard let route else { return }
        camera = .rect(route.polyline.boundingMapRect.insetBy(dx: -1500, dy: -1500))
    }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private func durationText(_ s: TimeInterval) -> String {
        let m = Int((s / 60).rounded())
        return m < 60 ? "\(m) 分鐘" : "\(m / 60) 小時 \(m % 60) 分"
    }
    private func distanceText(_ m: Double) -> String { m < 1000 ? "\(Int(m)) 公尺" : String(format: "%.1f 公里", m / 1000) }
}
