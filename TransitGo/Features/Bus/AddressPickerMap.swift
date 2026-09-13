import SwiftUI
import MapKit

/// A real "drop pin at map center" address picker, plus a text search that geocodes a
/// typed address/road name via Apple's own MKLocalSearch and jumps the map there — so
/// fixing the location doesn't require manually dragging to somewhere far away.
struct AddressPickerMap: View {
    @Binding var coordinate: CLLocationCoordinate2D
    @State private var camera: MapCameraPosition
    @State private var query = ""
    @State private var isSearching = false
    @State private var searchErrorText: String?

    init(coordinate: Binding<CLLocationCoordinate2D>) {
        self._coordinate = coordinate
        self._camera = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate.wrappedValue, span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
        )))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("輸入地址、路名或門牌號讓地圖跳過去", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button {
                    Task { await search() }
                } label: {
                    if isSearching { ProgressView() } else { Text("搜尋") }
                }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }
            if let searchErrorText {
                Text(searchErrorText).font(.caption2).foregroundStyle(.red)
            }
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
            Text("找到地址後仍可拖動地圖微調，圖釘固定在畫面中心").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func search() async {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        isSearching = true
        searchErrorText = nil
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = keyword
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 20000, longitudinalMeters: 20000)
        request.resultTypes = [.address, .pointOfInterest]
        guard let response = try? await MKLocalSearch(request: request).start(), let first = response.mapItems.first else {
            searchErrorText = "找不到這個地址"
            return
        }
        let c = first.placemark.coordinate
        coordinate = c
        withAnimation {
            camera = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)))
        }
    }
}
