import SwiftUI
import MapKit

/// Search-and-pick sheet for setting the "住家"/"公司" quick-select shortcuts.
struct SetSavedPlaceView: View {
    let role: SavedPlaceRole
    let near: CLLocationCoordinate2D

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var results: [DestinationCandidate] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if let current = SavedPlaceStore.get(role) {
                    Section("目前設定") {
                        Label(current.name, systemImage: role.icon)
                        Button("清除", role: .destructive) {
                            SavedPlaceStore.clear(role)
                            dismiss()
                        }
                    }
                }
                Section("搜尋地址或地標") {
                    TextField("例如：台北市信義區松高路1號", text: $text)
                        .onChange(of: text) { _, v in search(v) }
                    ForEach(results) { r in
                        Button {
                            SavedPlaceStore.set(role, name: r.name, coordinate: r.coordinate)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name)
                                if let sub = r.subtitle {
                                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("設定\(role.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func search(_ keyword: String) {
        searchTask?.cancel()
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            request.region = MKCoordinateRegion(center: near, span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3))
            request.resultTypes = [.pointOfInterest, .address]
            guard let response = try? await MKLocalSearch(request: request).start(), !Task.isCancelled else { return }
            results = response.mapItems.prefix(10).compactMap { item in
                guard let name = item.name else { return nil }
                return DestinationCandidate(name: name, subtitle: item.placemark.title, coordinate: item.placemark.coordinate, isLandmark: true)
            }
        }
    }
}
