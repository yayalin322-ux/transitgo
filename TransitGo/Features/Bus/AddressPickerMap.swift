import SwiftUI
import MapKit

/// A real "drop pin at map center" address picker — the same interaction pattern real
/// map apps use, since MapKit's SwiftUI `Map` has no built-in freely-draggable
/// annotation before iOS 18. The pin stays fixed at screen-center; panning the map
/// changes which real coordinate it points at.
struct AddressPickerMap: View {
    @Binding var coordinate: CLLocationCoordinate2D
    @State private var camera: MapCameraPosition

    init(coordinate: Binding<CLLocationCoordinate2D>) {
        self._coordinate = coordinate
        self._camera = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate.wrappedValue, span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
        )))
    }

    var body: some View {
        ZStack {
            Map(position: $camera)
                .onMapCameraChange(frequency: .continuous) { context in
                    coordinate = context.region.center
                }
            Image(systemName: "mappin")
                .font(.system(size: 30))
                .foregroundStyle(.red)
                .offset(y: -15)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
