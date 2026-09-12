import SwiftUI
import WidgetKit

@main
struct TransitGoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TimetableWidget()
        BusTripLiveActivity()
        RailTripLiveActivity()
        BikeTripLiveActivity()
        MetroTripLiveActivity()
    }
}
