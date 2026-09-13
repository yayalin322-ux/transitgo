import SwiftUI
import MapKit
import PhotosUI

/// A landmark's info page — real MapKit fields (address/phone/website/category; Apple
/// gives no reviews at all) plus our own user-submitted reviews (see PlaceReviewService).
struct PlaceDetailView: View {
    let name: String
    let coordinate: CLLocationCoordinate2D
    var subtitle: String?

    @Environment(\.dismiss) private var dismiss
    @State private var mapItem: MKMapItem?
    @State private var stats: PlaceReviewStats?
    @State private var reviews: [PlaceReview] = []
    @State private var showAddReview = false
    @State private var loading = true
    @State private var reportedReviewIDs: Set<Int> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)))) {
                        Marker(name, coordinate: coordinate).tint(.red)
                    }
                    .frame(height: 160)
                    .listRowInsets(EdgeInsets())
                    .disabled(true)
                }

                Section {
                    if let addr = subtitle ?? mapItem?.placemark.title {
                        Label(addr, systemImage: "mappin.and.ellipse")
                    }
                    if let phone = mapItem?.phoneNumber {
                        Link(destination: URL(string: "tel:\(phone.filter { $0.isNumber })") ?? URL(string: "tel:")!) {
                            Label(phone, systemImage: "phone.fill")
                        }
                    }
                    if let url = mapItem?.url {
                        Link(destination: url) {
                            Label(url.host ?? url.absoluteString, systemImage: "safari.fill")
                        }
                    }
                    if mapItem == nil, !loading {
                        Text("沒有更多 Apple 地圖資訊").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        if let stats, stats.count > 0 {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                            Text(String(format: "%.1f", stats.avg ?? 0)).font(.headline)
                            Text("· \(stats.count) 則評論").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("還沒有評論").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("寫評論") { showAddReview = true }
                    }
                } header: {
                    Text("使用者評論（本 App 內建，非 Google/Apple 資料）")
                }

                if !reviews.isEmpty {
                    Section {
                        ForEach(reviews) { r in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 2) {
                                        ForEach(1...5, id: \.self) { n in
                                            Image(systemName: n <= r.stars ? "star.fill" : "star")
                                                .font(.caption2).foregroundStyle(.yellow)
                                        }
                                    }
                                    if !r.comment.isEmpty {
                                        Text(r.comment).font(.subheadline)
                                    }
                                    if let photo = r.photo, let image = DataURIImage.decode(photo) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                            .frame(width: 120, height: 90)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                Spacer()
                                if reportedReviewIDs.contains(r.id) {
                                    Text("已檢舉").font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    Button {
                                        PlaceReviewService.report(id: r.id)
                                        reportedReviewIDs.insert(r.id)
                                    } label: {
                                        Image(systemName: "flag").font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } footer: {
                        Text("看到不當內容可以按旗子檢舉，管理員會審核處理。")
                    }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
            }
            .task {
                async let detail = loadMapItem()
                async let review = PlaceReviewService.fetch(name: name, coordinate: coordinate)
                mapItem = await detail
                if let result = await review { stats = result.stats; reviews = result.reviews }
                loading = false
            }
            .sheet(isPresented: $showAddReview) {
                AddPlaceReviewView(name: name, coordinate: coordinate) {
                    showAddReview = false
                    Task {
                        if let result = await PlaceReviewService.fetch(name: name, coordinate: coordinate) {
                            stats = result.stats; reviews = result.reviews
                        }
                    }
                }
            }
        }
    }

    private func loadMapItem() async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return response.mapItems.min {
            CLLocation(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude).distance(from: here)
                < CLLocation(latitude: $1.placemark.coordinate.latitude, longitude: $1.placemark.coordinate.longitude).distance(from: here)
        }
    }
}

private struct AddPlaceReviewView: View {
    let name: String
    let coordinate: CLLocationCoordinate2D
    var onDone: () -> Void

    @State private var stars = 0
    @State private var comment = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoImage: UIImage?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(name).font(.headline)
                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { n in
                        Button {
                            withAnimation(.spring(response: 0.25)) { stars = n }
                        } label: {
                            Image(systemName: n <= stars ? "star.fill" : "star")
                                .font(.system(size: 30)).foregroundStyle(n <= stars ? .yellow : .secondary)
                        }
                    }
                }
                TextField("留下你的評論（可留空）", text: $comment, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    if let photoImage {
                        Image(uiImage: photoImage).resizable().scaledToFill()
                            .frame(height: 120).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Label("加一張照片（可留空）", systemImage: "camera")
                    }
                }
                .onChange(of: photoItem) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                            photoImage = img
                        }
                    }
                }
                Spacer()
                Button {
                    isSubmitting = true
                    let photo = photoImage.flatMap { PhotoUpload.encode($0) }
                    if stars > 0 { PlaceReviewService.submit(name: name, coordinate: coordinate, stars: stars, comment: comment, photo: photo) }
                    onDone()
                } label: {
                    if isSubmitting { ProgressView() } else { Text("送出").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(stars == 0 || isSubmitting)
            }
            .padding()
            .navigationTitle("寫評論")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onDone) }
            }
        }
        .presentationDetents([.medium])
    }
}
