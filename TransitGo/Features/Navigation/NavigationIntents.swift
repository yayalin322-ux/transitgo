import AppIntents
import MapKit
import SwiftUI

/// How Siri / Shortcuts should get there. 開車 and 騎機車 both use MapKit's automobile routing (there is no scooter
/// type); the scooter one additionally avoids 國道 (scooters may not use freeways).
enum SiriTravelMode: String, AppEnum {
    case drive, scooter, walk

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "交通方式" }
    static var caseDisplayRepresentations: [SiriTravelMode: DisplayRepresentation] {
        [.drive: "開車", .scooter: "騎機車", .walk: "步行"]
    }

    var transportType: MKDirectionsTransportType { self == .walk ? .walking : .automobile }
    /// `nil` lets the navigation screen apply its own default (avoid 國道 for everything except a car).
    var avoidsHighways: Bool? { self == .scooter ? true : nil }
}

/// A destination Siri has handed to the app, waiting for the UI to pick it up. The intent runs before (cold launch)
/// or beside (app already open) the SwiftUI hierarchy, so it only records the request; `RootView` resolves and
/// presents it.
@MainActor
@Observable
final class PendingNavigation {
    static let shared = PendingNavigation()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let query: String
        let mode: SiriTravelMode
    }

    private(set) var request: Request?

    /// Ignores blank text; returns whether a request was recorded.
    @discardableResult
    func submit(query: String, mode: SiriTravelMode) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        request = Request(query: q, mode: mode)
        return true
    }

    func clear() { request = nil }
}

struct StartNavigationIntent: AppIntent {
    static var title: LocalizedStringResource { "開始導航" }
    static var description: IntentDescription {
        IntentDescription("導航到你說的地點，例如「竹北車站」或「新竹動物園」。")
    }
    /// Turn-by-turn needs the screen (map, voice, Live Activity), so the app opens.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "目的地", requestValueDialog: "要導航到哪裡？")
    var destination: String

    @Parameter(title: "交通方式", default: .drive)
    var mode: SiriTravelMode

    static var parameterSummary: some ParameterSummary {
        Summary("導航到 \(\.$destination)，\(\.$mode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard PendingNavigation.shared.submit(query: destination, mode: mode) else {
            throw $destination.needsValueError("要導航到哪裡？")
        }
        return .result(dialog: "好的，開始導航到\(destination)")
    }
}

struct TransitGoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartNavigationIntent(),
            phrases: [
                "用\(.applicationName)導航",
                "\(.applicationName)導航",
                "開始\(.applicationName)導航",
            ],
            shortTitle: "開始導航",
            systemImageName: "location.north.line.fill"
        )
    }
}

/// A place resolved from what was said, ready for `InAppNavigationView`.
struct SiriNavigationTarget: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let name: String
    let mode: SiriTravelMode
}

enum SiriDestinationResolver {
    /// Looks the spoken name up with MapKit: near the user first (a bare "全家" should mean the closest one), then
    /// anywhere in Taiwan. `nil` = nothing found; the caller says so instead of guessing.
    static func resolve(_ request: PendingNavigation.Request, near: CLLocationCoordinate2D?) async -> SiriNavigationTarget? {
        func search(center: CLLocationCoordinate2D, meters: Double) async -> MKMapItem? {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = request.query
            req.region = MKCoordinateRegion(center: center, latitudinalMeters: meters, longitudinalMeters: meters)
            req.resultTypes = [.address, .pointOfInterest]
            return try? await MKLocalSearch(request: req).start().mapItems.first
        }
        var item: MKMapItem?
        if let near { item = await search(center: near, meters: 30_000) }
        if item == nil { item = await search(center: CLLocationCoordinate2D(latitude: 23.7, longitude: 121.0), meters: 450_000) }
        guard let item else { return nil }
        return SiriNavigationTarget(coordinate: item.placemark.coordinate, name: item.name ?? request.query, mode: request.mode)
    }
}
