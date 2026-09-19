import SwiftUI
import MapKit
import CoreLocation

/// The trip screen. Deliberately plain: what to do now, what comes next, one warning line when something is wrong.
/// All logic lives in `TripNavigationService`/`TripEngine`; this only renders `TripSession` through `TripInstructionText`.
struct TripNavigationView: View {
    let service: TripNavigationService
    var onClose: () -> Void

    @State private var showMap = false
    @State private var confirmEnd = false

    var body: some View {
        NavigationStack {
            Group {
                if let s = service.session { content(s) } else { ContentUnavailableView("沒有進行中的行程", systemImage: "figure.walk") }
            }
            .navigationTitle("行程導航")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("收合") { onClose() } }
                ToolbarItem(placement: .primaryAction) { Button { showMap = true } label: { Image(systemName: "map") } }
            }
            .sheet(isPresented: $showMap) { if let s = service.session { TripMapView(session: s) } }
            .confirmationDialog("結束這趟行程？", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("結束行程", role: .destructive) { service.cancel(); onClose() }
            }
        }
    }

    @ViewBuilder
    private func content(_ s: TripSession) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(s.origin.name) → \(s.destination.name)").font(.headline)
                    ProgressView(value: s.progress).tint(.blue)
                    if let remaining = s.remainingDurationSeconds {
                        Text(remainingText(remaining, meters: s.remainingDistanceMeters)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let banner = service.banner {
                Section {
                    HStack { Text(banner.text).font(.subheadline).foregroundStyle(banner.isWarning ? .orange : .primary); Spacer(); Button("關閉") { service.dismissBanner() }.font(.caption) }
                }
            }
            if !s.locationAuthorized {
                Section { Text("TransitGo 需要你的所在位置，才能提供即時行程導航。目前只顯示行程內容，不會跟隨你的位置。").font(.footnote).foregroundStyle(.orange) }
            }
            if s.status == .arrived {
                Section { Label("已抵達\(s.destination.name)", systemImage: "flag.checkered").font(.title3.weight(.semibold)) }
            } else {
                if let cur = s.current {
                    Section("現在") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(TripInstructionText.title(cur)).font(.title3.weight(.semibold))
                            ForEach(TripInstructionText.details(cur), id: \.self) { Text($0).font(.body).foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let next = s.nextAction {
                    Section("下一步") {
                        Text(TripInstructionText.nextLine(next)).font(.subheadline)
                        if let t = s.nextTransfer { Text(TripInstructionText.transferLine(t)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }

            Section {
                if s.isOffline { Label("目前無網路，使用最近一次路線資料", systemImage: "wifi.slash").font(.footnote).foregroundStyle(.orange) }
                else if s.realtime == .unavailable { Label("即時資訊暫時無法更新，依時刻表導航", systemImage: "clock.badge.exclamationmark").font(.footnote).foregroundStyle(.secondary) }
                if let reason = service.suggestedReroute {
                    Text(reason == .cancelled ? "此班次已取消" : "嚴重延誤").font(.footnote).foregroundStyle(.orange)
                }
                if service.isRerouting { HStack { ProgressView(); Text("正在重新規劃…").font(.footnote) } }
                if !s.isFinished {
                    Button { service.rerouteNow() } label: { Label("重新規劃", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(service.isRerouting || !s.locationAuthorized)
                    Button(role: .destructive) { confirmEnd = true } label: { Label("結束行程", systemImage: "xmark.circle") }
                } else {
                    Button("完成") { onClose() }
                }
            }
        }
    }

    private func remainingText(_ seconds: Int, meters: Double?) -> String {
        let m = max(1, Int((Double(seconds) / 60).rounded()))
        var parts = ["剩餘約 \(m) 分鐘"]
        if let meters { parts.append(meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1000)) }
        return parts.joined(separator: "・")
    }
}

// MARK: - Map (SwiftUI MapKit, like the rest of the app)

/// Shows the route being followed: the legs' endpoints joined in order (a straight line between boarding points — the
/// engine has no vehicle path geometry, and this does not pretend to), the next node, the transfer points, the
/// destination and — only if the user allowed location — the user's own position.
struct TripMapView: View {
    let session: TripSession
    @Environment(\.dismiss) private var dismiss

    private var points: [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for leg in session.plan.legs {
            if let f = leg.from?.coordinate, out.isEmpty || TripGeometry.distance(TripCoordinate(out.last!), TripCoordinate(f)) > 1 { out.append(f) }
            if let t = leg.to?.coordinate { out.append(t) }
        }
        return out
    }
    private var transferPoints: [(String, CLLocationCoordinate2D)] {
        session.plan.legs.filter { $0.kind.isVehicle }.dropFirst().compactMap { l in l.from.map { (l.fromName, $0.coordinate) } }
    }

    var body: some View {
        NavigationStack {
            Map {
                UserAnnotation()
                MapPolyline(coordinates: points).stroke(.blue, lineWidth: 4)
                if let next = session.currentLeg?.to?.coordinate {
                    Annotation(session.currentLeg?.toName ?? "下一個節點", coordinate: next) { Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.orange) }
                }
                ForEach(Array(transferPoints.enumerated()), id: \.offset) { _, item in
                    Annotation(item.0, coordinate: item.1) { Image(systemName: "arrow.triangle.swap").padding(4).background(.white, in: Circle()) }
                }
                if let last = session.plan.legs.last?.to?.coordinate {
                    Marker(session.destination.name, systemImage: "flag.fill", coordinate: last).tint(.red)
                }
            }
            .mapControls { MapUserLocationButton(); MapCompass() }
            .navigationTitle("路線地圖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - Home: resume banner

struct ResumeTripRow: View {
    let session: TripSession
    var onResume: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("正在進行的旅程").font(.footnote.weight(.semibold))
            Text("\(session.origin.name) → \(session.destination.name)").font(.subheadline)
            if let cur = session.current { Text("目前：\(TripInstructionText.title(cur))").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("恢復導航", action: onResume).buttonStyle(.borderedProminent).controlSize(.small)
                Button("結束", role: .destructive, action: onDiscard).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
