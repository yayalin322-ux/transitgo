import SwiftUI
import MapKit
import CoreLocation
import ActivityKit
import AVFoundation
import UIKit

/// High-frequency, high-accuracy location just for the duration of an active in-app
/// navigation — deliberately separate from the low-power `LocationManager` used
/// elsewhere (that one's a single-shot fix; this needs continuous updates + heading).
@MainActor
@Observable
final class NavigationLocationTracker: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var location: CLLocation?
    var headingDegrees: CLLocationDirection?
    var authorization: CLAuthorizationStatus = .notDetermined
    /// `CLLocation` isn't Equatable, so SwiftUI can't `.onChange(of: location)` — observe
    /// this monotonic counter instead (bumped on every fix).
    var updateTick = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5
        manager.activityType = .otherNavigation
        authorization = manager.authorizationStatus
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.start() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.location = loc
            self.updateTick += 1
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in self.headingDegrees = h }
    }
}

/// One leg of a (possibly multi-leg) in-app navigation trip — a "waypoint" is just where
/// the transport mode changes (e.g. walk → YouBike → walk), not a place navigation stops
/// and needs to be manually restarted.
struct NavigationLeg: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    /// This leg's immediate target — an intermediate waypoint's own name (e.g. a YouBike
    /// station), or the trip's final destination on the last leg.
    let name: String
    let transportType: MKDirectionsTransportType
    /// Spoken on reaching this leg's waypoint, right before continuing to the next leg.
    /// Only used for non-final legs — the final leg always gets the generic arrival line.
    var waypointAnnouncement: String?

    init(coordinate: CLLocationCoordinate2D, name: String, transportType: MKDirectionsTransportType, waypointAnnouncement: String? = nil) {
        self.coordinate = coordinate
        self.name = name
        self.transportType = transportType
        self.waypointAnnouncement = waypointAnnouncement
    }
}

/// A real in-app turn-by-turn navigation screen — we draw the route ourselves, follow the
/// user's live position, reroute when they stray off the path, and speak each actual
/// maneuver (`MKRoute.steps[].instructions` — turn-by-turn text *is* public MapKit API,
/// this app just wasn't using it before) as you approach it, instead of handing off to
/// Apple Maps. Also runs a Dynamic Island / Lock Screen Live Activity. Speed-camera alerts
/// are NOT implemented — there's no public data source for camera locations in Taiwan this
/// app has access to, so it doesn't pretend to warn about them.
///
/// Supports multiple sequential legs (e.g. walk to a YouBike station, cycle to another,
/// walk the rest of the way) as ONE continuous session — reaching an intermediate leg's
/// waypoint auto-advances to the next leg's route and transport mode in place, without
/// dismissing the screen or making the user re-launch navigation themselves.
struct InAppNavigationView: View {
    let legs: [NavigationLeg]
    /// Overall trip label for the Live Activity title — the final destination's name,
    /// stays fixed across leg transitions.
    let tripName: String

    init(destination: CLLocationCoordinate2D, destinationName: String, transportType: MKDirectionsTransportType) {
        self.legs = [NavigationLeg(coordinate: destination, name: destinationName, transportType: transportType)]
        self.tripName = destinationName
    }

    init(legs: [NavigationLeg], tripName: String) {
        precondition(!legs.isEmpty)
        self.legs = legs
        self.tripName = tripName
    }

    @Environment(\.dismiss) private var dismiss
    @State private var tracker = NavigationLocationTracker()
    @State private var camera: MapCameraPosition = .automatic
    @State private var route: MKRoute?
    @State private var isRouting = true
    @State private var offRoute = false
    @State private var errorText: String?
    @State private var lastRerouteAt = Date.distantPast
    @State private var followUser = true
    @State private var activity: Activity<NavigationTripAttributes>?
    @State private var arrived = false
    @State private var announcedMilestones: Set<Int> = []
    @State private var announcedStart = false
    @State private var currentStepIndex = 0
    @State private var announcedStepIndices: Set<Int> = []
    @State private var currentLegIndex = 0
    @State private var nearbyCams: [SpeedCam] = []
    @State private var announcedCamIDs: Set<String> = []
    @State private var upcomingCam: SpeedCam?
    @State private var camFetchCenter: CLLocationCoordinate2D?
    @State private var legInitialDistance: CLLocationDistance?
    private let speech = AVSpeechSynthesizer()
    /// Distance milestones (metres) to call out, checked in descending order.
    private static let milestones = [1000, 500, 200, 100, 50]
    private static let arrivalThreshold: CLLocationDistance = 20

    private var currentLeg: NavigationLeg { legs[currentLegIndex] }
    private var destination: CLLocationCoordinate2D { currentLeg.coordinate }
    private var destinationName: String { currentLeg.name }
    private var transportType: MKDirectionsTransportType { currentLeg.transportType }
    private var isLastLeg: Bool { currentLegIndex == legs.count - 1 }
    private var legProgressText: String? { legs.count > 1 ? "\(currentLegIndex + 1)/\(legs.count)" : nil }

    /// How far into the *current* leg we are, 0...1 — for the little progress bar under the
    /// metrics card. Nil until we know both the leg's starting distance and where we are now.
    private var legProgressFraction: Double? {
        guard let start = legInitialDistance, start > 0, let loc = tracker.location else { return nil }
        let remaining = loc.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
        return min(1, max(0, 1 - remaining / start))
    }

    /// Show current speed for anything faster than walking — 開車 and 騎機車 both map to
    /// `.automobile` (MapKit has no separate scooter transport type).
    private var showsSpeed: Bool { transportType == .automobile }

    /// Off-route threshold — walking needs a tighter tolerance than driving (bigger roads,
    /// bigger GPS error) or it'll false-positive on every street crossing.
    private var offRouteThreshold: CLLocationDistance { transportType == .walking ? 40 : 80 }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                UserAnnotation()
                if let route {
                    MapPolyline(route.polyline).stroke(.blue, lineWidth: 7)
                }
                Marker(destinationName, coordinate: destination).tint(.red)
            }
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .continuous) { _ in
                // Any manual drag turns off auto-follow so the user can look around;
                // the "回到目前位置" button below brings it back.
                followUser = false
            }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                if let progress = legProgressText {
                    HStack(spacing: 6) {
                        Image(systemName: modeSymbol).font(.footnote)
                        Text("第 \(progress) 段・前往\(destinationName)").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.top, 8)
                }
                if let instruction = upcomingInstruction {
                    HStack(spacing: 10) {
                        Image(systemName: maneuverIcon(instruction)).font(.title2)
                        Text(instruction).font(.headline).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)
                }
                if let cam = upcomingCam {
                    HStack(spacing: 10) {
                        Image(systemName: "camera.fill").font(.title3)
                        Text(cam.announcement).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.red, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal)
                }
                Spacer()
            }

            if arrived {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                    Text("已抵達\(tripName)").font(.title3.bold())
                    Button { finish() } label: {
                        Label("完成", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                VStack(spacing: 10) {
                    if offRoute {
                        Label("已偏離路線，重新規劃中…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.orange, in: Capsule())
                    }
                    if let err = errorText {
                        Text(err).font(.footnote).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.red, in: Capsule())
                    }

                    VStack(spacing: 10) {
                        if let fraction = legProgressFraction {
                            ProgressView(value: fraction)
                                .tint(.blue)
                        }
                        HStack(spacing: 20) {
                            metric(distanceText, label: "剩餘距離")
                            Divider().frame(height: 34)
                            metric(etaText, label: "預估時間")
                            if showsSpeed {
                                Divider().frame(height: 34)
                                metric(speedText, label: "目前時速")
                            }
                            Spacer()
                            Button {
                                followUser = true
                                recenter()
                            } label: {
                                Image(systemName: "location.fill")
                                    .frame(width: 36, height: 36)
                                    .background(followUser ? .blue.opacity(0.5) : .blue, in: Circle())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Button(role: .destructive) { finish() } label: {
                        Label("結束導航", systemImage: "xmark.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding()
            }

            if isRouting {
                ProgressView("規劃路線中…")
                    .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .navigationBarBackButtonHidden()
        .onAppear {
            tracker.start()
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        .onDisappear { tracker.stop() }
        .task { await computeRoute(from: tracker.location?.coordinate) }
        .onChange(of: tracker.updateTick) { _, _ in
            guard let newLoc = tracker.location else { return }
            if followUser { recenter() }
            checkOffRoute(newLoc)
            handleLocationUpdate(newLoc)
            checkManeuvers(newLoc)
            checkSpeedCams(newLoc)
        }
    }

    private var modeLabel: String {
        switch transportType {
        case .walking: return "走路"
        case .automobile: return "開車"
        case .cycling: return "騎腳踏車"
        default: return "導航"
        }
    }

    private var modeSymbol: String {
        switch transportType {
        case .walking: return "figure.walk"
        case .automobile: return "car.fill"
        case .cycling: return "bicycle"
        default: return "location.fill"
        }
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var distanceText: String {
        guard let loc = tracker.location else { return "—" }
        let d = loc.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
        return d < 1000 ? "\(Int(d)) 公尺" : String(format: "%.1f 公里", d / 1000)
    }

    private var etaText: String {
        guard let mins = etaMinutes else { return "—" }
        return mins < 60 ? "\(mins) 分" : "\(mins / 60) 小時 \(mins % 60) 分"
    }

    /// For walking, this uses the *learned* personal pace against the live remaining
    /// distance (so it counts down as you actually get closer, not just on reroute) rather
    /// than the static route estimate from MapKit's generic walking-speed assumption.
    private var etaMinutes: Int? {
        if transportType == .walking, let loc = tracker.location {
            let remaining = loc.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
            return WalkingSpeedLearner.estimatedMinutes(forMeters: remaining)
        }
        guard let route else { return nil }
        return max(0, Int((route.expectedTravelTime / 60).rounded()))
    }

    private var speedText: String {
        guard let s = tracker.location?.speed, s >= 0 else { return "—" }
        return "\(Int((s * 3.6).rounded())) km/h"   // m/s → km/h
    }

    /// The instruction for the *next* maneuver ahead — announced by voice as you approach
    /// it (see `checkManeuvers`) and shown here as the on-screen turn banner, same idea.
    private var upcomingInstruction: String? {
        guard let route else { return nil }
        let steps = route.steps
        let nextIndex = currentStepIndex + 1
        guard nextIndex < steps.count else { return nil }
        let text = steps[nextIndex].instructions
        return text.isEmpty ? nil : text
    }

    private func maneuverIcon(_ instruction: String) -> String {
        if instruction.contains("左") { return "arrow.turn.up.left" }
        if instruction.contains("右") { return "arrow.turn.up.right" }
        if instruction.contains("迴轉") || instruction.contains("掉頭") { return "arrow.uturn.left" }
        if instruction.contains("隧道") { return "mountain.2.fill" }
        if instruction.contains("交流道") || instruction.contains("匝道") { return "arrow.triangle.merge" }
        if instruction.contains("圓環") { return "arrow.triangle.2.circlepath" }
        return "arrow.up"
    }

    private func recenter() {
        guard let loc = tracker.location else { return }
        let heading: CLLocationDirection = tracker.headingDegrees ?? (loc.course >= 0 ? loc.course : 0)
        withAnimation {
            camera = .camera(MapCamera(
                centerCoordinate: loc.coordinate,
                distance: transportType == .walking ? 350 : 700,
                heading: heading,
                pitch: 55
            ))
        }
    }

    private func finish() {
        tracker.stop()
        endActivity()
        dismiss()
    }

    // MARK: - Voice announcements

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        speech.speak(utterance)
    }

    private func handleLocationUpdate(_ loc: CLLocation) {
        // Feed real walking-pace samples back into the learner (see WalkingSpeedLearner) —
        // `speed < 0` means CoreLocation couldn't compute it for this fix, skip those.
        if transportType == .walking, loc.speed >= 0 {
            WalkingSpeedLearner.record(loc.speed)
        }
        let distance = loc.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
        if !arrived, distance <= Self.arrivalThreshold {
            if isLastLeg {
                withAnimation(.spring(response: 0.4)) { arrived = true }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                speak("您已經抵達目的地")
            } else {
                // Reaching an intermediate waypoint (e.g. a YouBike station) isn't trip
                // completion — announce it and roll straight into the next leg's route and
                // transport mode, same screen, no manual restart.
                let finishedLeg = currentLeg
                currentLegIndex += 1
                announcedMilestones = []
                legInitialDistance = loc.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                speak(finishedLeg.waypointAnnouncement ?? "已抵達，繼續前往下一段")
                Task { await computeRoute(from: loc.coordinate) }
            }
        } else if !arrived {
            for m in Self.milestones where distance <= Double(m) && !announcedMilestones.contains(m) {
                announcedMilestones.insert(m)
                speak(m >= 1000 ? "距離目的地還有一公里" : "距離目的地還有\(m)公尺")
            }
        }
        updateActivity()
    }

    // MARK: - Live Activity

    private func currentState() -> NavigationTripAttributes.ContentState {
        let meters = tracker.location.map {
            Int($0.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude)))
        } ?? 0
        return NavigationTripAttributes.ContentState(
            distanceMeters: meters, etaMinutes: etaMinutes ?? 0, offRoute: offRoute, arrived: arrived,
            modeLabel: modeLabel, modeSymbol: modeSymbol, legProgress: legProgressText
        )
    }

    private func startActivityIfNeeded() {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = NavigationTripAttributes(destinationName: tripName)
        activity = try? Activity.request(
            attributes: attrs,
            content: ActivityContent(state: currentState(), staleDate: Date().addingTimeInterval(120)),
            pushType: nil
        )
    }

    private func updateActivity() {
        guard let activity else { return }
        let state = currentState()
        Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))) }
    }

    private func endActivity() {
        guard let activity else { return }
        let state = currentState()
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(30))) }
        self.activity = nil
    }

    private func computeRoute(from origin: CLLocationCoordinate2D?) async {
        guard let origin else {
            // No fix yet — try again shortly rather than failing outright.
            try? await Task.sleep(for: .seconds(1))
            await computeRoute(from: tracker.location?.coordinate)
            return
        }
        isRouting = true
        defer { isRouting = false }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = transportType
        guard let response = try? await MKDirections(request: request).calculate(), let first = response.routes.first else {
            errorText = "找不到路線"
            return
        }
        errorText = nil
        route = first
        let wasOffRoute = offRoute
        offRoute = false
        lastRerouteAt = .now
        // A reroute means a brand new step list — start tracking maneuvers from its
        // beginning again, not wherever the old route's index happened to be.
        currentStepIndex = 0
        announcedStepIndices = []
        if followUser { recenter() }
        if !announcedStart {
            announcedStart = true
            // Milestones the trip *starts* inside of aren't a real "crossing" — pre-mark
            // them done so e.g. starting 600m away doesn't immediately announce "1 km"
            // (there was no approach from beyond 1 km to announce).
            if let loc = tracker.location {
                let initialDistance = loc.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
                for m in Self.milestones where Double(m) >= initialDistance {
                    announcedMilestones.insert(m)
                }
                legInitialDistance = initialDistance
            }
            speak("開始導航前往\(tripName)")
            startActivityIfNeeded()
        } else {
            if wasOffRoute { speak("已重新規劃路線") }
            updateActivity()
        }
    }

    /// Distance from `loc` to the nearest point on the current route's polyline.
    private func checkOffRoute(_ loc: CLLocation) {
        guard let route, !isRouting else { return }
        let points = route.polyline.points()
        let count = route.polyline.pointCount
        guard count > 0 else { return }
        let here = MKMapPoint(loc.coordinate)
        var minDistance = CLLocationDistance.greatestFiniteMagnitude
        for i in 0..<count {
            let d = here.distance(to: points[i])
            if d < minDistance { minDistance = d }
        }
        let strayed = minDistance > offRouteThreshold
        if strayed, !offRoute { speak("已偏離路線，重新規劃路線中") }
        offRoute = strayed
        // Throttle recalculation — don't fire a new MKDirections request on every 5m tick.
        if strayed, Date().timeIntervalSince(lastRerouteAt) > 12 {
            Task { await computeRoute(from: loc.coordinate) }
        }
    }

    /// Real turn-by-turn: announces the *next* maneuver's instructions as the user
    /// approaches the point where it happens, then advances to watching for the one after
    /// that once they've passed it.
    private func checkManeuvers(_ loc: CLLocation) {
        guard let route, !isRouting else { return }
        let steps = route.steps
        let nextIndex = currentStepIndex + 1
        guard nextIndex < steps.count else { return }   // already on the final leg
        let nextStep = steps[nextIndex]
        guard nextStep.polyline.pointCount > 0 else { return }
        let maneuverCoord = nextStep.polyline.points()[0].coordinate
        let distanceToManeuver = loc.distance(from: CLLocation(latitude: maneuverCoord.latitude, longitude: maneuverCoord.longitude))

        let announceThreshold: CLLocationDistance = transportType == .walking ? 60 : 150
        let passThreshold: CLLocationDistance = transportType == .walking ? 20 : 35

        if distanceToManeuver <= announceThreshold, !announcedStepIndices.contains(nextIndex), !nextStep.instructions.isEmpty {
            announcedStepIndices.insert(nextIndex)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            speak(nextStep.instructions)
        }
        if distanceToManeuver <= passThreshold {
            currentStepIndex = nextIndex
        }
    }

    // MARK: - Speed cameras

    /// Only for 開車/騎機車 (both map to `.automobile`) — walking/cycling speeds don't
    /// warrant a "there's a speed camera ahead" warning the way driving does.
    private func checkSpeedCams(_ loc: CLLocation) {
        guard transportType == .automobile else { return }

        // Refetch the candidate list once we've actually moved far enough that the old
        // center's radius might not cover us anymore — not on every 5m location tick.
        if camFetchCenter == nil || loc.distance(from: CLLocation(latitude: camFetchCenter!.latitude, longitude: camFetchCenter!.longitude)) > 1500 {
            camFetchCenter = loc.coordinate
            Task {
                if let cams = await SpeedCamService.nearby(near: loc.coordinate) {
                    nearbyCams = cams
                }
            }
        }

        let announceThreshold: CLLocationDistance = 300
        let passThreshold: CLLocationDistance = 60
        var stillAhead: SpeedCam?
        for cam in nearbyCams {
            let d = loc.distance(from: CLLocation(latitude: cam.lat, longitude: cam.lon))
            if d <= announceThreshold, !announcedCamIDs.contains(cam.id) {
                announcedCamIDs.insert(cam.id)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                speak(cam.announcement)
            }
            if announcedCamIDs.contains(cam.id), d <= announceThreshold, d > passThreshold {
                // Prefer the closest still-relevant camera for the on-screen banner.
                if stillAhead == nil || d < loc.distance(from: CLLocation(latitude: stillAhead!.lat, longitude: stillAhead!.lon)) {
                    stillAhead = cam
                }
            }
        }
        upcomingCam = stillAhead
    }
}
