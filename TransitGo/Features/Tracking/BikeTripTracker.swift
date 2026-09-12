import Foundation
import ActivityKit
import UserNotifications

@MainActor
@Observable
final class BikeTripTracker {
    static let shared = BikeTripTracker()

    private(set) var isTracking = false
    private(set) var trackedUID: String?
    private(set) var lastError: String?

    private var activity: Activity<BikeTripAttributes>?
    private var pollTask: Task<Void, Never>?
    private var city: BikeCity = .taipei
    private var stationUID = ""
    private var notifiedEmpty = false

    var isActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(city: BikeCity, station: BikeStation, intent: String) async {
        guard isActivitiesEnabled else {
            lastError = "請到「設定 › 交通即時查」開啟即時動態。"
            return
        }
        await stop()
        self.city = city
        self.stationUID = station.stationUID
        notifiedEmpty = false
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])

        let attributes = BikeTripAttributes(
            stationName: station.name, cityName: city.displayName, intent: intent
        )
        let initial = BikeTripAttributes.ContentState(
            availableRent: 0, availableReturn: 0, generalBikes: nil, electricBikes: nil,
            inService: true, updatedAt: .now
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initial, staleDate: Date().addingTimeInterval(180)),
                pushType: nil
            )
            isTracking = true
            trackedUID = station.stationUID
            lastError = nil
            TripKeepAlive.shared.acquire()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh(intent: intent)
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() async {
        let wasTracking = isTracking
        pollTask?.cancel(); pollTask = nil
        if let activity { await activity.end(nil, dismissalPolicy: .immediate) }
        activity = nil
        isTracking = false
        trackedUID = nil
        if wasTracking { TripKeepAlive.shared.release() }
    }

    private func refresh(intent: String) async {
        guard let activity else { return }
        guard let a = try? await BikeService.shared.availability(city: city, stationUID: stationUID) else { return }
        let state = BikeTripAttributes.ContentState(
            availableRent: a.availableRentBikes ?? 0,
            availableReturn: a.availableReturnBikes ?? 0,
            generalBikes: a.availableRentBikesDetail?.generalBikes,
            electricBikes: a.availableRentBikesDetail?.electricBikes,
            inService: a.inService,
            updatedAt: .now
        )
        await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(180)))

        let critical = intent == "借車" ? state.availableRent : state.availableReturn
        if critical == 0, !notifiedEmpty {
            notifiedEmpty = true
            let content = UNMutableNotificationContent()
            content.title = intent == "借車" ? "目標站無車可借" : "目標站已滿，無位可還"
            content.body = activity.attributes.stationName
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "bike-\(stationUID)", content: content, trigger: nil)
            )
        }
    }
}
