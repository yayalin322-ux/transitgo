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
        // Unfiltered heading fires on every tiny magnetometer jitter (many times/sec) —
        // re-animating the camera that often is wasted battery for no visible benefit.
        // 3° is well below what's perceptible as "the compass lagging".
        manager.headingFilter = 3
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

/// Reference-counted screen-stays-awake lock — a parking leg can open a second
/// `InAppNavigationView` on top of the first (see `navigateToParking`), and naive
/// true/false toggling would let the inner screen's dismissal re-enable auto-lock while
/// the outer navigation session is still very much active underneath it.
@MainActor
enum IdleTimerLock {
    private static var count = 0
    static func acquire() {
        count += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }
    static func release() {
        count = max(0, count - 1)
        UIApplication.shared.isIdleTimerDisabled = count > 0
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
    /// Taiwan law bans scooters/motorcycles, bicycles, and pedestrians from freeways
    /// (國道) — but MapKit has no separate scooter transport type (騎機車 uses
    /// `.automobile` same as 開車) and no public "avoid highways" request flag at all, so
    /// this can't be expressed to MKDirections directly. computeRoute checks the
    /// resulting route's steps for highway wording and, when this is true, tries
    /// alternates that avoid it instead of just accepting whatever MapKit picked first.
    /// Defaults to true for anything that isn't `.automobile` (walking/cycling routes
    /// already shouldn't include one, but this is a real legal-safety issue, not just a
    /// preference, so it gets checked regardless of whether MapKit "should" have avoided
    /// it already) — pass `false` explicitly for an actual car trip.
    var avoidsHighways: Bool
    /// Non-nil marks this a "ride" leg — the user is a passenger on real public transit
    /// (e.g. "公車 THB5900"), not someone MapKit can turn-by-turn navigate. There's no
    /// real route line to draw (this app doesn't have live bus-shape data plugged into
    /// navigation) and no maneuvers to announce — computeRoute skips the MKDirections
    /// call entirely for these, and the screen shows a simple "riding" card that
    /// auto-advances once GPS says you're near the alight stop, same arrival logic as
    /// any other leg.
    var transitLabel: String?
    /// The route's real TDX display name + scope, e.g. ("20", "City/Hsinchu") — needed to
    /// query TDX's live vehicle-position endpoint for this leg's real plate number.
    /// Nil if the backend couldn't resolve them; the ride still works, just without a
    /// plate shown (never guessed).
    var transitRouteName: String?
    var transitScopePath: String?

    init(coordinate: CLLocationCoordinate2D, name: String, transportType: MKDirectionsTransportType, waypointAnnouncement: String? = nil, avoidsHighways: Bool? = nil, transitLabel: String? = nil, transitRouteName: String? = nil, transitScopePath: String? = nil) {
        self.coordinate = coordinate
        self.name = name
        self.transportType = transportType
        self.waypointAnnouncement = waypointAnnouncement
        self.avoidsHighways = avoidsHighways ?? (transportType != .automobile)
        self.transitLabel = transitLabel
        self.transitRouteName = transitRouteName
        self.transitScopePath = transitScopePath
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

    init(destination: CLLocationCoordinate2D, destinationName: String, transportType: MKDirectionsTransportType, avoidsHighways: Bool? = nil) {
        self.legs = [NavigationLeg(coordinate: destination, name: destinationName, transportType: transportType, avoidsHighways: avoidsHighways)]
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
    @State private var offRouteStreak = 0
    /// Real TDX live-position match for a "ride" leg's vehicle — the one currently
    /// closest to the user, on that real route. This is an inference, not a confirmed
    /// boarding scan, so the UI always labels it "推測" (inferred).
    @State private var currentVehiclePlate: String?
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
    /// Guards handleLocationUpdate's milestone/arrival logic until premarking has
    /// actually run — see computeRoute's comment on why this matters for short trips.
    @State private var milestonesInitialized = false
    /// How many consecutive fixes have read "close enough to arrive/advance" — GPS in
    /// dense areas easily reports 10-30m of error, so a single close reading isn't
    /// trusted for anything irreversible (arriving, advancing past a turn). This is what
    /// was causing announcements to fire before actually there / jump around.
    @State private var closeFixStreak = 0
    @State private var maneuverPassStreak = 0
    @State private var followResumeTask: Task<Void, Never>?
    /// Camera changes made by recenter() itself (called on every heading/location tick)
    /// shouldn't be mistaken for a manual drag — see the mapCameraChange comment.
    @State private var suppressFollowDetectionUntil = Date.distantPast
    @State private var nearbyParking: [MKMapItem] = []
    @State private var earlyParkingTriggered = false
    private struct ParkingDetailTarget: Identifiable {
        let id = UUID()
        let name: String
        let coordinate: CLLocationCoordinate2D
        let subtitle: String?
    }
    @State private var parkingDetailTarget: ParkingDetailTarget?
    @State private var parkingLeg: NavigationLeg?
    @State private var showRating = false
    @State private var photoSpots: [RoutePhotoSpot] = []
    @State private var photoFetchCenter: CLLocationCoordinate2D?
    private let speech = AVSpeechSynthesizer()
    private let maneuverHaptic = UIImpactFeedbackGenerator(style: .light)
    private let notificationHaptic = UINotificationFeedbackGenerator()
    private let legTransitionHaptic = UIImpactFeedbackGenerator(style: .medium)
    /// Distance milestones (metres) to call out, checked in descending order.
    private static let milestones = [1000, 500, 200, 100, 50]
    private static let arrivalThreshold: CLLocationDistance = 20
    /// Consecutive fixes required inside a threshold before acting on it.
    private static let requiredCloseFixes = 2
    /// Fixes worse than this are too noisy to trust for arrival/maneuver decisions.
    private static let maxTrustedAccuracy: CLLocationDistance = 35

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
    // Driving's threshold is wider than walking's for the same reason maneuver/arrival
    // decisions elsewhere in this file need a streak, not a single fix: at wide
    // intersections, highway interchanges, and roads with an elevated/frontage-road
    // twin running alongside, simply being in a different lane than MapKit's chosen
    // polyline can momentarily read tens of metres away — that's normal lane choice,
    // not having left the route.
    private var offRouteThreshold: CLLocationDistance { transportType == .walking ? 40 : 120 }
    private static let requiredOffRouteFixes = 3

    @Namespace private var mapScope

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera, scope: mapScope) {
                // `UserAnnotation()` draws its own heading cone on the blue dot — but the
                // camera itself is already rotated to match travel direction (see
                // recenter()), so that cone plus the MapCompass button both showing
                // direction at once read as two redundant compasses. A plain dot with no
                // heading indicator of its own removes the duplicate.
                if let userCoord = tracker.location?.coordinate {
                    Annotation("", coordinate: userCoord) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(radius: 2)
                    }
                }
                if let route {
                    // A white "casing" under the blue line — same trick real nav apps use
                    // so the route stays visible against both light and dark roads/water.
                    MapPolyline(route.polyline).stroke(.white, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                    MapPolyline(route.polyline).stroke(.blue, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                }
                Marker(destinationName, coordinate: destination).tint(.red)
                ForEach(photoSpots) { spot in
                    Annotation(spot.name, coordinate: spot.coordinate) {
                        AsyncImage(url: spot.imageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.3)
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(radius: 2)
                    }
                }
                // Every known camera nearby gets a marker, not just the one currently
                // close enough to alert about — seeing them ahead of time on the map is
                // the point, the voice/banner alert is just the "right now" reminder.
                ForEach(nearbyCams) { cam in
                    Annotation("", coordinate: cam.coordinate) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(cam.kind == "speed" ? .red : .orange, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll, showsTraffic: transportType == .automobile))
            // MapKit adds its own default top-trailing compass automatically unless this
            // is overridden — left alone, it showed up *alongside* the custom
            // MapCompass(scope:) below as two redundant compasses. Suppressing the
            // defaults here leaves exactly the one we've deliberately positioned.
            .mapControls {}
            .onMapCameraChange(frequency: .continuous) { _ in
                // Without the suppression check below, recenter()'s OWN camera update
                // (every heading tick — several times a second while turning) counted as
                // a "manual drag" here, which immediately flipped followUser back to
                // false and cancelled the follow — so the compass/camera only actually
                // rotated once every ~4s (whenever the resume timer briefly won the
                // race), not live. `.continuous` fires repeatedly through a single
                // animated change, so the suppression window has to cover the whole
                // animation, not just its first frame.
                guard Date() >= suppressFollowDetectionUntil else { return }
                // A real manual drag pauses auto-follow so the user can look around, but
                // this is navigation — nobody wants to remember to tap "recenter" every
                // time, so it resumes on its own a few seconds after they stop touching
                // the map.
                followUser = false
                followResumeTask?.cancel()
                followResumeTask = Task {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    followUser = true
                    recenter()
                }
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
                if let transitLabel = currentLeg.transitLabel {
                    HStack(spacing: 10) {
                        Image(systemName: "bus.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("乘車中：\(transitLabel)").font(.headline)
                            if let plate = currentVehiclePlate {
                                Text("推測車牌：\(plate)").font(.caption)
                            }
                            Text("抵達\(destinationName)後會自動繼續").font(.caption2)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.indigo, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)
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
                    // Some destinations sit in the middle of a road with nothing to
                    // physically stand at — "附近" matches what a 20m-radius arrival
                    // actually means instead of implying an exact-point arrival.
                    Text("已抵達\(tripName)附近").font(.title3.bold())

                    if !nearbyParking.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("附近停車場").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(nearbyParking.enumerated()), id: \.offset) { _, item in
                                HStack {
                                    Button {
                                        navigateToParking(item)
                                    } label: {
                                        HStack {
                                            Image(systemName: "parkingsign.circle.fill").foregroundStyle(.blue)
                                            Text(item.name ?? "停車場").lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                    }
                                    .foregroundStyle(.primary)
                                    Button {
                                        parkingDetailTarget = ParkingDetailTarget(
                                            name: item.name ?? "停車場",
                                            coordinate: item.placemark.coordinate,
                                            subtitle: item.placemark.title
                                        )
                                    } label: {
                                        Image(systemName: "info.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button { showRating = true } label: {
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
                    // Shown from 50m out (see handleLocationUpdate) so there's actually
                    // time to act on it, not just a list that appears once already
                    // stopped at the destination.
                    if earlyParkingTriggered, !nearbyParking.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("即將抵達・附近停車場").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(nearbyParking.prefix(3).enumerated()), id: \.offset) { _, item in
                                Button {
                                    navigateToParking(item)
                                } label: {
                                    HStack {
                                        Image(systemName: "parkingsign.circle.fill").foregroundStyle(.blue)
                                        Text(item.name ?? "停車場").lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

            // MapKit's default .mapControls placement (top-trailing) sat right under the
            // leg-progress/turn/camera banners stacked at the top — moved to the trailing
            // edge, vertically centered, well clear of both those and the bottom card.
            HStack {
                Spacer()
                MapCompass(scope: mapScope)
                    .padding(.trailing, 10)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .navigationBarBackButtonHidden()
        .onAppear {
            tracker.start()
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            // An unprepared UIFeedbackGenerator can silently miss its first hit or two —
            // the Taptic Engine needs a moment to spin up. Preparing once up front (and
            // again after each firing, below) is what actually makes haptics reliable.
            maneuverHaptic.prepare()
            notificationHaptic.prepare()
            legTransitionHaptic.prepare()
            // The whole point of this screen is running unattended while driving/walking —
            // the screen auto-locking mid-navigation (killing the live map + voice) is a
            // real bug, not acceptable default iOS behaviour here.
            IdleTimerLock.acquire()
            // Without this, backgrounding the app mid-navigation (home button/swipe up)
            // had no keep-alive running — this screen's own CLLocationManager isn't
            // background-enabled, so iOS could suspend and, under memory pressure,
            // terminate the whole app while backgrounded. Reopening it then launched a
            // fresh process that lands on the main screen instead of resuming navigation,
            // because there was no state left to resume. Same technique already used for
            // trip tracking elsewhere (TripKeepAlive) — low-power background location
            // keeps the process alive for the duration of the nav session.
            TripKeepAlive.shared.acquire()
            // Without this, reopening the screen with a location the tracker already has
            // (e.g. from before it was dismissed) left the camera on `.automatic` — a
            // generic wide view — until the next fresh GPS fix arrived, which read as
            // "current location jumped away". Jump straight to the known position now;
            // .onChange(of: tracker.updateTick) below keeps it current after that.
            if tracker.location != nil { recenter() }
        }
        .onDisappear {
            tracker.stop()
            IdleTimerLock.release()
            TripKeepAlive.shared.release()
        }
        .task { await computeRoute(from: tracker.location?.coordinate) }
        .onChange(of: tracker.updateTick) { _, _ in
            guard let newLoc = tracker.location else { return }
            if followUser { recenter() }
            checkOffRoute(newLoc)
            handleLocationUpdate(newLoc)
            checkManeuvers(newLoc)
            checkSpeedCams(newLoc)
            checkRoutePhotos(newLoc)
        }
        // Location fixes only arrive every `distanceFilter` (5m) of movement, so turning
        // in place — or moving slowly — left the compass/camera heading frozen until the
        // next real position change. Heading updates fire far more often; re-rotating the
        // camera on those too (without re-running the heavier per-location checks above)
        // is what actually makes the compass track live turning.
        .onChange(of: tracker.headingDegrees) { _, _ in
            if followUser { recenter() }
        }
        .fullScreenCover(item: $parkingLeg) { leg in
            InAppNavigationView(destination: leg.coordinate, destinationName: leg.name, transportType: leg.transportType)
        }
        .sheet(isPresented: $showRating) {
            TripRatingSheet(tripName: tripName, modeLabel: modeLabel) {
                showRating = false
                finish()
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $parkingDetailTarget) { target in
            PlaceDetailView(name: target.name, coordinate: target.coordinate, subtitle: target.subtitle)
        }
    }

    private var modeLabel: String {
        if let transitLabel = currentLeg.transitLabel { return transitLabel }
        switch transportType {
        case .walking: return "走路"
        case .automobile: return "開車"
        case .cycling: return "騎腳踏車"
        default: return "導航"
        }
    }

    private var modeSymbol: String {
        if currentLeg.transitLabel != nil { return "bus.fill" }
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

    /// Destination point `meters` along `bearingDegrees` from `start` — spherical-earth
    /// approximation, plenty accurate at the tens-of-metres scale this is used for.
    private static func coordinate(_ start: CLLocationCoordinate2D, movedMeters meters: Double, bearingDegrees: CLLocationDirection) -> CLLocationCoordinate2D {
        let earthRadius = 6371000.0
        let bearing = bearingDegrees * .pi / 180
        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180
        let angularDistance = meters / earthRadius
        let lat2 = asin(sin(lat1) * cos(angularDistance) + cos(lat1) * sin(angularDistance) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angularDistance) * cos(lat1), cos(angularDistance) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    /// Best-effort detection since MapKit exposes no "this route uses a controlled-access
    /// highway" flag — Taiwan's freeway step instructions reliably name the road (e.g.
    /// "走 國道1號" / "Merge onto 國道3號"), which is what this actually checks for.
    private static func usesHighway(_ route: MKRoute) -> Bool {
        route.steps.contains {
            $0.instructions.contains("國道") || $0.instructions.contains("快速道路") || $0.instructions.contains("高速公路")
        }
    }

    /// The real camera data's `direction` field is free-text Chinese from several
    /// different sources (MOI: "東向西"/"往南"/"北上"/"南下"; Kaohsiung: "南向北"; Hsinchu:
    /// "雙向") — it was never actually checked against the way the user is driving, which
    /// is exactly why a camera facing the opposite direction still triggered a warning.
    /// This parses out a target compass bearing and compares it to the real current
    /// heading; anything bidirectional, unparseable, or with no heading data yet falls
    /// back to "applies" — a false alert once in a while is far better than silently
    /// dropping a real speed-camera warning because the text didn't match a pattern.
    private static func speedCamDirectionApplies(_ direction: String?, heading: CLLocationDirection?) -> Bool {
        guard let direction, !direction.isEmpty, direction != "雙向" else { return true }
        guard let target = speedCamTargetBearing(direction) else { return true }
        guard let heading, heading >= 0 else { return true }
        let diff = abs((heading - target).truncatingRemainder(dividingBy: 360))
        let angularDiff = min(diff, 360 - diff)
        return angularDiff <= 70   // generous — GPS heading noise + road curvature, not a precise compass reading
    }

    private static let compassBearings: [(String, Double)] = [
        ("東北", 45), ("東南", 135), ("西南", 225), ("西北", 315),
        ("北", 0), ("南", 180), ("東", 90), ("西", 270),
    ]

    /// "東向西"/"西往東" style: the SECOND direction is the one the camera watches traffic
    /// travel toward. "北上"/"南下" are highway-specific shorthand for the same idea.
    private static func speedCamTargetBearing(_ direction: String) -> Double? {
        if direction.contains("北上") { return 0 }
        if direction.contains("南下") { return 180 }
        if let range = direction.range(of: "向") ?? direction.range(of: "往") {
            let after = String(direction[range.upperBound...])
            for (name, bearing) in compassBearings where after.hasPrefix(name) { return bearing }
        }
        for (name, bearing) in compassBearings where direction == name { return bearing }
        return nil   // e.g. "往國道二號方向" — no cardinal direction to parse, treat as always-applies
    }

    private func recenter() {
        guard let loc = tracker.location else { return }
        let heading: CLLocationDirection = tracker.headingDegrees ?? (loc.course >= 0 ? loc.course : 0)
        // recenter() runs on every heading/location tick — the change handler above
        // needs to know this particular camera update isn't a manual drag. `withAnimation`
        // with no explicit duration runs ~0.35s; padding to 0.5s covers it with margin.
        suppressFollowDetectionUntil = Date().addingTimeInterval(0.5)
        withAnimation {
            camera = .camera(MapCamera(
                centerCoordinate: loc.coordinate,
                // Closer + flatter — a car-nav-style view, not an overview: tighter zoom
                // and a shallower tilt read as "close to the road ahead" instead of
                // looking down at the map from height.
                distance: transportType == .walking ? 160 : 260,
                heading: heading,
                pitch: 15
            ))
        }
    }

    private func finish() {
        tracker.stop()
        endActivity()
        dismiss()
    }

    /// Same in-app navigation as the primary trip — our own drawn route, live tracking,
    /// voice, reroute — rather than handing off to Apple Maps for this last stretch.
    private func navigateToParking(_ item: MKMapItem) {
        parkingLeg = NavigationLeg(
            coordinate: item.placemark.coordinate,
            name: item.name ?? "停車場",
            transportType: .automobile
        )
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
        // computeRoute hasn't premarked the starting milestones yet (still awaiting the
        // first MKDirections response) — acting on distance now would announce every
        // milestone a short trip already starts inside of, all at once.
        guard milestonesInitialized else { return }
        let distance = loc.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
        // A noisy fix (common between buildings) can read 20-30m closer than reality —
        // trusting a single such reading is exactly what caused "already arrived" to
        // fire before actually there. Require the close reading to repeat, and only
        // count it at all if this particular fix's own accuracy is good enough to trust.
        let fixIsTrustworthy = loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= Self.maxTrustedAccuracy
        let isClose = distance <= Self.arrivalThreshold && fixIsTrustworthy
        closeFixStreak = isClose ? closeFixStreak + 1 : 0

        if !arrived, closeFixStreak >= Self.requiredCloseFixes {
            if isLastLeg {
                withAnimation(.spring(response: 0.4)) { arrived = true }
                notificationHaptic.notificationOccurred(.success)
                notificationHaptic.prepare()
                // Some destinations sit in the middle of a road with no exact building to
                // stand at — "抵達附近" is honest about that instead of implying you
                // should be standing on the exact pin.
                speak("您已抵達\(tripName)附近")
                if transportType == .automobile { Task { await loadNearbyParking() } }
            } else {
                // Reaching an intermediate waypoint (e.g. a YouBike station) isn't trip
                // completion — announce it and roll straight into the next leg's route and
                // transport mode, same screen, no manual restart.
                let finishedLeg = currentLeg
                currentLegIndex += 1
                closeFixStreak = 0
                let newLegDistance = loc.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
                legInitialDistance = newLegDistance
                // Same fix as the trip-start case: a leg that begins under 1km/500m/etc
                // didn't "cross" those milestones by approach, so don't announce them —
                // pre-mark whichever ones the new leg already starts inside of.
                announcedMilestones = Set(Self.milestones.filter { Double($0) >= newLegDistance })
                legTransitionHaptic.impactOccurred()
                legTransitionHaptic.prepare()
                speak(finishedLeg.waypointAnnouncement ?? "已抵達，繼續前往下一段")
                Task { await computeRoute(from: loc.coordinate) }
            }
        } else if !arrived {
            for m in Self.milestones where distance <= Double(m) && !announcedMilestones.contains(m) {
                announcedMilestones.insert(m)
                speak(m >= 1000 ? "距離目的地還有一公里" : "距離目的地還有\(m)公尺")
            }
            // Surface parking options a little before arrival, not only after — by the
            // time you're actually stopped, you'd rather already know where to go than
            // start searching. 50m still leaves room to react before pulling in.
            if isLastLeg, transportType == .automobile, distance <= 50, !earlyParkingTriggered {
                earlyParkingTriggered = true
                speak("即將抵達，附近有停車場可以選擇")
                Task { await loadNearbyParking() }
            }
        }
        updateActivity()
    }

    /// A destination in the middle of a road (no exact building to walk to) is exactly
    /// when "where do I actually put the car" matters most — a couple of nearby parking
    /// options right on the arrival card beats making the user open Maps separately.
    private func loadNearbyParking() async {
        let region = MKCoordinateRegion(center: destination, latitudinalMeters: 800, longitudinalMeters: 800)
        let destLoc = CLLocation(latitude: destination.latitude, longitude: destination.longitude)

        // Two real sources, merged: Apple's own "停車場" text search (catches places
        // literally named that) AND its dedicated .parking category filter (catches
        // real parking lots Apple has categorized but didn't name "停車場" — a plain
        // keyword search misses those).
        async let byName: [MKMapItem] = {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = "停車場"
            request.region = region
            request.resultTypes = [.pointOfInterest]
            return (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        }()
        async let byCategory: [MKMapItem] = {
            let request = MKLocalPointsOfInterestRequest(center: destination, radius: 800)
            var withFilter = request
            withFilter.pointOfInterestFilter = MKPointOfInterestFilter(including: [.parking])
            return (try? await MKLocalSearch(request: withFilter).start())?.mapItems ?? []
        }()
        let (a, b) = await (byName, byCategory)

        var seen = Set<String>()
        var merged: [MKMapItem] = []
        for item in a + b {
            let key = "\(item.placemark.coordinate.latitude)_\(item.placemark.coordinate.longitude)_\(item.name ?? "")"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(item)
        }
        nearbyParking = Array(merged.sorted {
            CLLocation(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude).distance(from: destLoc)
                < CLLocation(latitude: $1.placemark.coordinate.latitude, longitude: $1.placemark.coordinate.longitude).distance(from: destLoc)
        }.prefix(8))
    }

    /// Real TDX live vehicle positions for this ride leg's real route, filtered to the
    /// one closest to the user right now — the best available inference for "which bus
    /// is this", not a confirmed boarding scan (there's no such data source). Silently
    /// does nothing if the backend couldn't resolve a real route name/scope for this leg,
    /// or if TDX has no live position for it right now — never fabricates a plate.
    private func lookupVehiclePlate() async {
        guard let routeName = currentLeg.transitRouteName, let scopePath = currentLeg.transitScopePath,
              let userLoc = tracker.location else { return }
        let escaped = routeName.replacingOccurrences(of: "'", with: "''")
        guard let list: [BusRealTimeFreq] = try? await TDXClient.shared.get(
            "v2/Bus/RealTimeByFrequency/\(scopePath)",
            query: ["$filter": "RouteName/Zh_tw eq '\(escaped)'"]
        ) else { return }
        let candidates = list.compactMap { b -> (String, CLLocation)? in
            guard b.plateNumb != "-1", !b.plateNumb.isEmpty,
                  let lat = b.busPosition?.positionLat, let lon = b.busPosition?.positionLon else { return nil }
            return (b.plateNumb, CLLocation(latitude: lat, longitude: lon))
        }
        guard let nearest = candidates.min(by: { $0.1.distance(from: userLoc) < $1.1.distance(from: userLoc) }) else { return }
        currentVehiclePlate = nearest.0
        updateActivity()
    }

    // MARK: - Live Activity

    private func currentState() -> NavigationTripAttributes.ContentState {
        let meters = tracker.location.map {
            Int($0.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude)))
        } ?? 0
        return NavigationTripAttributes.ContentState(
            distanceMeters: meters, etaMinutes: etaMinutes ?? 0, offRoute: offRoute, arrived: arrived,
            modeLabel: modeLabel, modeSymbol: modeSymbol, legProgress: legProgressText,
            transitLabel: currentLeg.transitLabel, transitAlightName: currentLeg.transitLabel != nil ? destinationName : nil,
            transitPlate: currentVehiclePlate
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

    /// `preferContinueForward`: when rerouting mid-drive/ride after straying off path,
    /// requesting directions from the literal GPS point can lead MapKit to propose
    /// turning around right where you are — technically shortest, but the ask was
    /// explicitly "don't suggest a U-turn, find the nearest way forward instead". There's
    /// no public MapKit flag for that, so this nudges the request's origin a short
    /// distance further along the current heading first, biasing the result toward a
    /// route that continues forward rather than doubling back immediately.
    private func computeRoute(from origin: CLLocationCoordinate2D?, preferContinueForward: Bool = false) async {
        guard let origin else {
            // No fix yet — try again shortly rather than failing outright.
            try? await Task.sleep(for: .seconds(1))
            await computeRoute(from: tracker.location?.coordinate, preferContinueForward: preferContinueForward)
            return
        }
        isRouting = true
        defer { isRouting = false }

        // Pre-mark milestones the trip *starts* inside of BEFORE the network round-trip
        // below, not after. GPS updates (and handleLocationUpdate's milestone check) keep
        // firing the whole time this function awaits MKDirections — if premarking waited
        // until the response came back, a short trip would see every applicable milestone
        // fire back-to-back off an empty `announcedMilestones` set in the meantime, which
        // is exactly what was happening.
        if !milestonesInitialized {
            milestonesInitialized = true
            let initialDistance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
            for m in Self.milestones where Double(m) >= initialDistance {
                announcedMilestones.insert(m)
            }
            legInitialDistance = initialDistance
        }

        // "Ride" legs (real bus/train from the multimodal route planner) have no route for
        // MapKit to compute — the user is a passenger, not someone to turn-by-turn direct.
        // Just mark the leg started; handleLocationUpdate's normal arrival-distance check
        // (same one every other leg uses) is what actually advances past this once GPS
        // says we're near the alight stop.
        if let transitLabel = currentLeg.transitLabel {
            route = nil
            currentVehiclePlate = nil
            if !announcedStart {
                announcedStart = true
                startActivityIfNeeded()
            }
            speak("請搭乘\(transitLabel)，抵達後會自動繼續導航")
            updateActivity()
            Task { await lookupVehiclePlate() }
            return
        }

        var effectiveOrigin = origin
        if preferContinueForward, transportType != .walking,
           let heading = tracker.headingDegrees ?? (tracker.location?.course).flatMap({ $0 >= 0 ? $0 : nil }) {
            effectiveOrigin = Self.coordinate(origin, movedMeters: 40, bearingDegrees: heading)
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: effectiveOrigin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = transportType
        // MapKit's public API has no "avoid highways" flag — the only lever is asking for
        // alternates and picking one ourselves that doesn't use one.
        request.requestsAlternateRoutes = currentLeg.avoidsHighways
        guard let response = try? await MKDirections(request: request).calculate(), !response.routes.isEmpty else {
            errorText = "找不到路線"
            return
        }
        var first = response.routes[0]
        var highwayWarning: String?
        if currentLeg.avoidsHighways {
            if let highwayFree = response.routes.first(where: { !Self.usesHighway($0) }) {
                first = highwayFree
            } else if Self.usesHighway(first) {
                // Legally can't use the only route MapKit found (機車/腳踏車/行人 on a
                // 國道) — say so plainly rather than silently sending them onto it.
                highwayWarning = "找不到避開國道的路線，請注意目前路線可能不適用於您的交通方式"
            }
        }
        errorText = highwayWarning
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
        let strayedThisFix = minDistance > offRouteThreshold
        offRouteStreak = strayedThisFix ? offRouteStreak + 1 : 0
        let strayed = offRouteStreak >= Self.requiredOffRouteFixes
        if strayed, !offRoute { speak("已偏離路線，重新規劃路線中") }
        offRoute = strayed
        // Throttle recalculation — don't fire a new MKDirections request on every 5m tick.
        if strayed, Date().timeIntervalSince(lastRerouteAt) > 12 {
            Task { await computeRoute(from: loc.coordinate, preferContinueForward: true) }
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
        let fixIsTrustworthy = loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= Self.maxTrustedAccuracy

        // A fixed 150m warning felt premature at low/parking-lot speed and late on a
        // fast road — scaling it off the real current speed (≈8 real seconds of
        // lead time, clamped to a sane range) is what turn-by-turn apps actually do.
        let announceThreshold: CLLocationDistance
        if transportType == .walking {
            announceThreshold = 60
        } else if loc.speed >= 0 {
            announceThreshold = min(220, max(50, loc.speed * 8))
        } else {
            announceThreshold = 150
        }
        let passThreshold: CLLocationDistance = transportType == .walking ? 20 : 35

        if distanceToManeuver <= announceThreshold, !announcedStepIndices.contains(nextIndex), !nextStep.instructions.isEmpty {
            announcedStepIndices.insert(nextIndex)
            maneuverHaptic.impactOccurred()
            maneuverHaptic.prepare()
            // "前方 X 公尺，[實際指示]" — a bare instruction with no distance reads like
            // it's happening right now; the distance is what makes it a heads-up.
            let roundedDistance = Int((distanceToManeuver / 10).rounded()) * 10
            speak("前方\(max(roundedDistance, 10))公尺，\(nextStep.instructions)")
        }
        // Advancing past a maneuver is irreversible (the old step's instructions won't be
        // shown again), so — same reasoning as arrival — don't act on a single noisy fix
        // that happens to read closer than reality.
        let isPastManeuver = distanceToManeuver <= passThreshold && fixIsTrustworthy
        maneuverPassStreak = isPastManeuver ? maneuverPassStreak + 1 : 0
        if maneuverPassStreak >= Self.requiredCloseFixes {
            currentStepIndex = nextIndex
            maneuverPassStreak = 0
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
        let heading: CLLocationDirection? = tracker.headingDegrees ?? (loc.course >= 0 ? loc.course : nil)
        var stillAhead: SpeedCam?
        for cam in nearbyCams {
            guard Self.speedCamDirectionApplies(cam.direction, heading: heading) else { continue }
            let d = loc.distance(from: CLLocation(latitude: cam.lat, longitude: cam.lon))
            if d <= announceThreshold, !announcedCamIDs.contains(cam.id) {
                announcedCamIDs.insert(cam.id)
                notificationHaptic.notificationOccurred(.warning)
                notificationHaptic.prepare()
                var text = cam.announcement
                // Only a real, current GPS speed compared against this camera's own real
                // posted limit — never a guessed or rounded-for-effect number.
                if let limit = cam.speedLimit, loc.speed >= 0 {
                    let currentKmh = Int((loc.speed * 3.6).rounded())
                    if currentKmh > limit {
                        text += "，您已超速，目前時速\(currentKmh)公里，測速限速\(limit)公里"
                    }
                }
                speak(text)
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

    // MARK: - Route photos

    /// Same "refetch only after moving far enough" pattern as speed cams — this data
    /// barely exists anywhere yet (one city's dataset), so the fetch is cheap and the
    /// filtering is the only real per-tick cost.
    private func checkRoutePhotos(_ loc: CLLocation) {
        if photoFetchCenter == nil || loc.distance(from: CLLocation(latitude: photoFetchCenter!.latitude, longitude: photoFetchCenter!.longitude)) > 800 {
            photoFetchCenter = loc.coordinate
            Task {
                photoSpots = await RoutePhotoService.nearby(loc.coordinate, radius: 600)
            }
        }
    }
}
