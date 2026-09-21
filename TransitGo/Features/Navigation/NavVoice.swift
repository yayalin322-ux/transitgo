import Foundation
import CoreLocation

// Voice modes + the wording of two-stage maneuver prompts, and curated road-side arrival points.
// Pure logic (no AVFoundation) so it is unit-tested.

/// How talkative the navigation voice is.
enum VoiceMode: String, CaseIterable, Identifiable {
    case detailed, standard, concise, alertsOnly, muted
    var id: String { rawValue }
    var label: String {
        switch self {
        case .detailed: return "詳細"
        case .standard: return "標準"
        case .concise: return "精簡"
        case .alertsOnly: return "只報警示"
        case .muted: return "靜音"
        }
    }
    var symbol: String { self == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill" }

    func allows(_ kind: AnnouncementKind) -> Bool {
        switch self {
        case .muted: return false
        case .alertsOnly: return [.offRoute, .reroute, .arrival, .camera].contains(kind)
        case .concise: return [.start, .farManeuver, .waypoint, .offRoute, .reroute, .arrival, .camera].contains(kind)
        case .standard: return ![.straightReminder, .laneCue].contains(kind)
        case .detailed: return true
        }
    }
}

enum AnnouncementKind {
    case start, farManeuver, nowManeuver, laneCue, straightReminder
    case milestone, waypoint, offRoute, reroute, arrival, camera, parking
}

/// Wording of the maneuver prompts. A prompt used to be said once ("前方 100 公尺右轉"); now it is said
/// twice — a heads-up, then again AT the junction ("此路口右轉") — because one call-out is easy to miss.
enum VoiceScript {
    /// The heads-up. `cue` adds a lane/structure hint when the instruction is about a ramp or bridge.
    static func far(distance: Int, instruction: String, withCue: Bool) -> String {
        var text = "前方\(max(distance, 10))公尺，\(instruction)"
        if withCue, let cue = structureCue(instruction) { text += "，\(cue)" }
        return text
    }

    /// The prompt at the junction itself.
    static func now(instruction: String) -> String { "此路口\(instruction)" }

    /// MapKit gives no lane data. What can honestly be said: when the step is about a ramp, interchange,
    /// bridge or elevated road, remind the driver to get into the matching lane early — and never claim
    /// which side, because that is not known.
    static func structureCue(_ instruction: String) -> String? {
        if instruction.contains("匝道") || instruction.contains("交流道") { return "請提早切換到匝道的車道" }
        if instruction.contains("橋") || instruction.contains("高架") { return "請提早靠近上橋的車道" }
        if instruction.contains("隧道") { return "前方進入隧道" }
        return nil
    }

    /// For a long stretch with nothing to do: without this the voice is silent for minutes and a driver
    /// wonders whether guidance is still running.
    static func straight(meters: Double) -> String? {
        guard meters >= 1500 else { return nil }
        return meters >= 10_000 ? "接下來直行約\(Int((meters / 1000).rounded()))公里" : String(format: "接下來直行約%.1f公里", meters / 1000)
    }
}

// MARK: - Road-side arrival points

/// A place whose map pin sits inside an area no road reaches (a school campus, a park, a big lot), with the
/// point on the road where you actually arrive. Curated and sourced — not guessed: MapKit routes INTO such a
/// campus (its route ended 7 m from the pin for 成功國中), so the pin cannot be snapped to a road automatically.
struct RoadAnchor {
    let name: String
    let pin: CLLocationCoordinate2D
    let anchor: CLLocationCoordinate2D
    let note: String
}

enum RoadAnchors {
    static let all: [RoadAnchor] = [
        RoadAnchor(
            name: "成功國中（竹北市成功八路 99 號）",
            pin: CLLocationCoordinate2D(latitude: 24.8189739, longitude: 121.0172329),
            // 校門（barrier=gate）在成功八路旁，離道路中心線約 17–18 m，與地址「成功八路 99 號」相符。
            anchor: CLLocationCoordinate2D(latitude: 24.8182366, longitude: 121.0173934),
            note: "OSM school relation 5395600 (pin) + gate node on 成功八路; MapKit route ended 7 m from the pin, inside the campus"
        ),
    ]

    /// The anchor for a requested destination, if it is (within `radius` m) one of the curated places.
    static func anchor(for coordinate: CLLocationCoordinate2D, radius: CLLocationDistance = 120) -> RoadAnchor? {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return all
            .map { ($0, here.distance(from: CLLocation(latitude: $0.pin.latitude, longitude: $0.pin.longitude))) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }
}


/// When the screen may offer "navigate to a nearby parking lot first?". The offer used to fire in three places (before
/// driving off, 50 m from the destination, on arrival) and again inside the navigation to the parking lot itself — which
/// is also a drive and also a last leg — so choosing a lot started the same questions over, forever.
enum ParkingPolicy {
    static func mayOffer(isLastLeg: Bool, isDriving: Bool, isParkingLeg: Bool, parkingAlreadyChosen: Bool) -> Bool {
        isLastLeg && isDriving && !isParkingLeg && !parkingAlreadyChosen
    }
}
