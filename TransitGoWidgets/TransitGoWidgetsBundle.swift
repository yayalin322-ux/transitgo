import SwiftUI
import WidgetKit

@main
struct TransitGoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TimetableWidget()
        RailBoardWidget()
        BusTripLiveActivity()
        RailTripLiveActivity()
        BikeTripLiveActivity()
        MetroTripLiveActivity()
        NavigationTripLiveActivity()
    }
}
