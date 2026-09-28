import SwiftUI
import MapKit
import PhotosUI

/// A landmark's info page — real MapKit fields (address/phone/website/category; Apple
/// gives no reviews at all) plus our own user-submitted reviews (see PlaceReviewService).
struct PlaceDetailView: View {
    let name: String
    let coordinate: CLLocationCoordinate2D
    var subtitle: String?
    /// Non-nil only for our own user-submitted landmarks — enables "report this
    /// landmark" and, for a verified business, an edit button. Nil for Apple's own POIs
    /// (those can only be reviewed, not reported/edited — we don't own that data).
    var landmarkID: Int?
    var businessHours: String?
    var businessPhone: String?
    var businessVerified = false
    var businessStatus: BusinessStatus = .open
    /// Google-Maps-style extras — empty/nil the same way businessHours/businessPhone are for
    /// anything not yet a verified business.
    var photos: [LandmarkPhoto] = []
    var hours: LandmarkHours?
    var features: [LandmarkFeature] = []
    var openNow: OpenNowStatus?
    var links: LandmarkLinks?
    var priceRange: Int?

    @Environment(\.dismiss) private var dismiss
    @State private var mapItem: MKMapItem?
    @State private var stats: PlaceReviewStats?
    @State private var reviews: [PlaceReview] = []
    @State private var showAddReview = false
    @State private var showEditLandmark = false
    @State private var showClaim = false
    @State private var loading = true
    @State private var reportedReviewIDs: Set<Int> = []
    @State private var landmarkReported = false
    @State private var navTarget: PlaceNavTarget?
    /// `nil` = show every photo. Only offered when the gallery actually spans more than one
    /// category — a single-category (or uncategorized) gallery has nothing worth filtering.
    @State private var photoCategoryFilter: PhotoCategory?
    /// Which review (if any) in `reviews` this device itself posted — enables a "delete my
    /// review" button in place of the report menu on that one row.
    @State private var myReviewID: Int?

    var body: some View {
        NavigationStack {
            List {
                if !photos.isEmpty {
                    Section {
                        if photoCategories.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    photoCategoryChip(nil, label: "全部")
                                    ForEach(photoCategories) { category in
                                        photoCategoryChip(category, label: category.label)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.top, 8)
                            }
                        }
                        TabView {
                            ForEach(filteredPhotos, id: \.url) { photo in
                                LandmarkPhotoView(photo: photo)
                            }
                        }
                        .tabViewStyle(.page)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                    }
                }

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
                    if businessVerified, businessStatus != .open {
                        Label(businessStatus.label, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(businessStatus == .permanentlyClosed ? .red : .orange)
                    } else if businessVerified, let openNow {
                        // business_status (a long-term thing the owner sets, e.g. renovating)
                        // always wins over the computed schedule — this branch only ever shows
                        // once that's not in play.
                        Label(openNow.changesLabel, systemImage: "clock.fill")
                            .foregroundStyle(openNow.open ? .green : .secondary)
                    }
                    if !features.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(features) { feature in
                                    Label(feature.label, systemImage: feature.icon)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(.blue.opacity(0.12), in: Capsule())
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                    }
                    if let hours {
                        DisclosureGroup {
                            ForEach(hours.days, id: \.key) { day in
                                HStack {
                                    Text(day.label).foregroundStyle(.secondary)
                                    Spacer()
                                    if let h = day.hours {
                                        Text("\(h.open)–\(h.close)")
                                    } else {
                                        Text("公休").foregroundStyle(.secondary)
                                    }
                                }
                                .font(.subheadline)
                            }
                        } label: {
                            Label(openNow?.changesLabel ?? "營業時間", systemImage: "clock.fill")
                        }
                    } else if let hoursText = businessHours {
                        Label(hoursText, systemImage: "clock.fill")
                    }
                    if let priceRange {
                        Label(priceRangeLabel(priceRange), systemImage: "dollarsign.circle")
                    }
                    if let links, !links.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                linkButton(links.menu, label: "菜單", icon: "menucard")
                                linkButton(links.order, label: "線上點餐", icon: "cart.fill")
                                linkButton(links.website, label: "官網", icon: "safari.fill")
                                linkButton(links.delivery, label: "外送", icon: "bicycle")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                    }
                    if let bPhone = businessPhone {
                        Link(destination: URL(string: "tel:\(bPhone.filter { $0.isNumber })") ?? URL(string: "tel:")!) {
                            Label(bPhone, systemImage: "phone.fill")
                        }
                    }
                    if businessHours != nil || businessPhone != nil {
                        Text("店家自行提供，已由管理員驗證").font(.caption2).foregroundStyle(.secondary)
                    }
                    if mapItem == nil, !loading {
                        Text("沒有更多 Apple 地圖資訊").font(.footnote).foregroundStyle(.secondary)
                    }
                    // Only our own (approved) landmarks have a page there at all — an Apple-only
                    // place (landmarkID nil) has nothing to link to yet.
                    if let landmarkID, let shopURL = BackendConfig.shopURL(id: landmarkID) {
                        Link(destination: shopURL) {
                            Label("在網頁上查看", systemImage: "globe")
                        }
                    }
                }

                Section {
                    Menu {
                        Button { navTarget = PlaceNavTarget(coordinate: coordinate, name: name, transportType: .walking) } label: {
                            Label("走路", systemImage: "figure.walk")
                        }
                        Button { navTarget = PlaceNavTarget(coordinate: coordinate, name: name, transportType: .automobile) } label: {
                            Label("開車", systemImage: "car.fill")
                        }
                        Button { navTarget = PlaceNavTarget(coordinate: coordinate, name: name, transportType: .automobile, avoidsHighways: true) } label: {
                            Label("騎機車", systemImage: "figure.outdoor.cycle")
                        }
                    } label: {
                        Label("導航到這裡", systemImage: "location.fill")
                    }
                }

                Section {
                    if businessVerified, let landmarkID {
                        Button { showEditLandmark = true } label: {
                            Label("編輯店家資訊", systemImage: "pencil")
                        }
                    } else {
                        // Not yet a verified business — either nobody's claimed it, someone claimed
                        // it but never verified their Email, or this place only ever existed as an
                        // Apple Maps result (landmarkID is nil — it isn't in our own landmarks table
                        // at all yet). All three end up here: claiming with a verified Email is what
                        // actually unlocks hours/phone/editing, whether that's an instant claim on an
                        // existing row or, for the Apple-only case, submitting it as a new one.
                        Button { showClaim = true } label: {
                            Label("這是我的店家", systemImage: "checkmark.seal")
                        }
                    }
                    if let landmarkID {
                        if landmarkReported {
                            Text("已檢舉").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Menu {
                                ForEach(ReportReason.allCases) { reason in
                                    Button(reason.label) {
                                        UserLandmarkService.report(id: landmarkID, reason: reason)
                                        landmarkReported = true
                                    }
                                }
                            } label: {
                                Label("檢舉這個地標", systemImage: "flag")
                            }
                        }
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
                                if myReviewID == r.id {
                                    Button(role: .destructive) {
                                        Task {
                                            if await PlaceReviewService.deleteMine(id: r.id) {
                                                reviews.removeAll { $0.id == r.id }
                                                myReviewID = nil
                                                if let result = await PlaceReviewService.fetch(name: name, coordinate: coordinate) {
                                                    stats = result.stats
                                                }
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "trash").font(.caption)
                                    }
                                } else if reportedReviewIDs.contains(r.id) {
                                    Text("已檢舉").font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    Menu {
                                        ForEach(ReportReason.allCases) { reason in
                                            Button(reason.label) {
                                                PlaceReviewService.report(id: r.id, reason: reason)
                                                reportedReviewIDs.insert(r.id)
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "flag").font(.caption)
                                    }
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
                async let mine = PlaceReviewService.mine()
                mapItem = await detail
                if let result = await review { stats = result.stats; reviews = result.reviews }
                let placeKey = PlaceReviewService.key(name: name, coordinate: coordinate)
                myReviewID = await mine.first { $0.placeKey == placeKey }?.id
                loading = false
            }
            .sheet(isPresented: $showAddReview) {
                AddPlaceReviewView(name: name, coordinate: coordinate) {
                    showAddReview = false
                    Task {
                        if let result = await PlaceReviewService.fetch(name: name, coordinate: coordinate) {
                            stats = result.stats; reviews = result.reviews
                        }
                        let placeKey = PlaceReviewService.key(name: name, coordinate: coordinate)
                        myReviewID = await PlaceReviewService.mine().first { $0.placeKey == placeKey }?.id
                    }
                }
            }
            .sheet(isPresented: $showEditLandmark) {
                if let landmarkID {
                    EditLandmarkView(
                        landmarkID: landmarkID, description: subtitle ?? "", businessHours: businessHours ?? "",
                        phone: businessPhone ?? "", businessStatus: businessStatus, coordinate: coordinate,
                        photos: photos, hours: hours, features: features, links: links ?? LandmarkLinks(), priceRange: priceRange
                    ) {
                        showEditLandmark = false
                    }
                }
            }
            .sheet(isPresented: $showClaim) {
                ClaimLandmarkView(landmarkID: landmarkID, placeName: name, coordinate: coordinate) {
                    showClaim = false
                }
            }
            .fullScreenCover(item: $navTarget) { target in
                InAppNavigationView(destination: target.coordinate, destinationName: target.name, transportType: target.transportType, avoidsHighways: target.avoidsHighways)
            }
        }
    }

    private var photoCategories: [PhotoCategory] {
        var seen: [PhotoCategory] = []
        for photo in photos where !seen.contains(photo.category) { seen.append(photo.category) }
        return seen
    }

    private var filteredPhotos: [LandmarkPhoto] {
        guard let photoCategoryFilter else { return photos }
        return photos.filter { $0.category == photoCategoryFilter }
    }

    @ViewBuilder
    private func photoCategoryChip(_ category: PhotoCategory?, label: String) -> some View {
        let isOn = photoCategoryFilter == category
        Button { photoCategoryFilter = category } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(isOn ? .blue : Color(.secondarySystemBackground), in: Capsule())
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func linkButton(_ urlString: String?, label: String, icon: String) -> some View {
        if let urlString, let url = URL(string: urlString) {
            Link(destination: url) {
                Label(label, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.blue.opacity(0.12), in: Capsule())
                    .foregroundStyle(.blue)
            }
        }
    }

    private func priceRangeLabel(_ level: Int) -> String {
        String(repeating: "$", count: max(1, min(4, level)))
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

/// Drives PlaceDetailView's own "導航到這裡" — a single-leg `fullScreenCover(item:)`
/// target, same pattern as TransferPlannerView's `NavTarget`/RoutePreviewView's target.
private struct PlaceNavTarget: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let name: String
    let transportType: MKDirectionsTransportType
    var avoidsHighways: Bool? = nil
}

/// One photo in a landmark's gallery — `data:` URIs (what the app itself uploads) decode
/// locally; a plain https URL (room for a future non-app upload path) loads over the network.
/// Either way, filling the whole page-view frame so the gallery reads as a real photo carousel.
private struct LandmarkPhotoView: View {
    let photo: LandmarkPhoto

    var body: some View {
        Group {
            if photo.url.hasPrefix("data:"), let image = DataURIImage.decode(photo.url) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = URL(string: photo.url) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { Color.gray.opacity(0.2) }
                }
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            if photo.category != .other {
                Text(photo.category.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(10)
            }
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
    @State private var email = ""
    @State private var code = ""
    @State private var isSubmitting = false
    @State private var errorText: String?

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
                // Every留言 now needs a verified Email — see PlaceReviewService.submit.
                EmailCodeField(email: $email, code: $code)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button {
                    Task {
                        isSubmitting = true
                        errorText = nil
                        let photo = photoImage.flatMap { PhotoUpload.encode($0) }
                        let result = await PlaceReviewService.submit(
                            name: name, coordinate: coordinate, stars: stars, comment: comment,
                            email: email, code: code, photo: photo
                        )
                        isSubmitting = false
                        switch result {
                        case .ok: onDone()
                        case .invalidCode: errorText = "驗證碼不正確或已過期，請重新按「寄驗證碼」。"
                        case .failed: errorText = "送出失敗，請稍後再試一次。"
                        }
                    }
                } label: {
                    if isSubmitting { ProgressView() } else { Text("送出").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(stars == 0 || code.count != 6 || isSubmitting)
            }
            .padding()
            .navigationTitle("寫評論")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onDone) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Claiming a place as a verified business. Two different things happen underneath depending on
/// whether this place is already one of our own landmarks:
/// - `landmarkID` set: it's an existing, already-approved row — a verified Email claims it
///   instantly (see `claimUserLandmark`; refused outright if someone else already holds a
///   verified claim, so this can't silently take over a real business's listing).
/// - `landmarkID` nil: this place only ever existed as an Apple Maps result — it isn't in our
///   landmarks table at all yet, so there is nothing to "claim" until it's submitted as a new
///   business-claim landmark (same moderation queue as any other new landmark, see
///   `createUserLandmark` — a verified Email alone doesn't skip review for a brand-new place,
///   only for claiming one that already passed review).
private struct ClaimLandmarkView: View {
    let landmarkID: Int?
    let placeName: String
    let coordinate: CLLocationCoordinate2D
    var onDone: () -> Void

    @State private var email = ""
    @State private var code = ""
    @State private var businessHours = ""
    @State private var phone = ""
    @State private var category: LandmarkCategory = .other
    @State private var isSubmitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(placeName).font(.headline)
                    Text(landmarkID != nil
                         ? "驗證信箱之後就會標示為已驗證店家，之後可以自己編輯營業時間、電話、營業狀態。"
                         : "這個地點目前不在我們自己的地標資料裡（來自 Apple 地圖），驗證信箱後會送出審核；通過後就會標示為已驗證店家，可以自己編輯營業時間、電話、營業狀態。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if landmarkID == nil {
                    Section("類型") {
                        Picker("類型", selection: $category) {
                            ForEach(LandmarkCategory.allCases) { c in
                                Label(c.label, systemImage: c.icon).tag(c)
                            }
                        }
                    }
                }
                Section("營業時間（選填）") {
                    TextField("例如：週一至週日 11:00–21:00", text: $businessHours, axis: .vertical).lineLimit(2...4)
                }
                Section("電話（選填）") {
                    TextField("電話", text: $phone).keyboardType(.phonePad)
                }
                Section("驗證信箱") {
                    EmailCodeField(email: $email, code: $code)
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle(landmarkID != nil ? "認領這個地標" : "認領為新地標")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button(landmarkID != nil ? "認領" : "送出審核") {
                            Task {
                                isSubmitting = true
                                errorText = nil
                                let result: UserLandmarkService.SubmitResult
                                if let landmarkID {
                                    result = await UserLandmarkService.claim(
                                        id: landmarkID, email: email, code: code,
                                        businessHours: businessHours, phone: phone
                                    )
                                } else {
                                    result = await UserLandmarkService.submit(
                                        name: placeName, description: "", category: category, coordinate: coordinate,
                                        photo: nil, isBusinessClaim: true, businessHours: businessHours, phone: phone,
                                        email: email, code: code
                                    )
                                }
                                isSubmitting = false
                                switch result {
                                case .ok: onDone()
                                case .invalidCode: errorText = landmarkID != nil
                                    ? "驗證碼不正確／已過期，或這個地標已經被別人認領了。"
                                    : "驗證碼不正確／已過期。"
                                case .failed: errorText = landmarkID != nil ? "認領失敗，請稍後再試一次。" : "送出失敗，請稍後再試一次。"
                                }
                            }
                        }
                        .disabled(code.count != 6 || isSubmitting)
                    }
                }
            }
        }
    }
}

/// Only reachable from a landmark PlaceDetailView already showed as `businessVerified`
/// — but the actual write still only succeeds server-side if this device matches the
/// one that originally submitted it (see UserLandmarkService.update / the server's
/// updateMyUserLandmark). A mismatch surfaces as a clear error, not a silent no-op.
private struct EditLandmarkView: View {
    let landmarkID: Int
    @State var description: String
    @State var businessHours: String
    @State var phone: String
    @State var businessStatus: BusinessStatus
    let coordinate: CLLocationCoordinate2D
    var onDone: () -> Void

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var editablePhotos: [EditablePhoto]
    @State private var useStructuredHours: Bool
    @State private var hours: LandmarkHours
    @State private var features: Set<LandmarkFeature>
    @State private var linkMenu: String
    @State private var linkOrder: String
    @State private var linkWebsite: String
    @State private var linkDelivery: String
    @State private var priceRange: Int?
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var pinCoordinate: CLLocationCoordinate2D

    /// One selected/existing photo plus the category the owner assigns it — the picker only
    /// hands back plain UIImages, so this is what pairs a category onto each one for editing.
    private struct EditablePhoto: Identifiable {
        let id = UUID()
        var image: UIImage
        var category: PhotoCategory
    }

    init(
        landmarkID: Int, description: String, businessHours: String, phone: String,
        businessStatus: BusinessStatus, coordinate: CLLocationCoordinate2D,
        photos: [LandmarkPhoto], hours: LandmarkHours?, features: [LandmarkFeature],
        links: LandmarkLinks, priceRange: Int?, onDone: @escaping () -> Void
    ) {
        self.landmarkID = landmarkID
        self._description = State(initialValue: description)
        self._businessHours = State(initialValue: businessHours)
        self._phone = State(initialValue: phone)
        self._businessStatus = State(initialValue: businessStatus)
        self.coordinate = coordinate
        self.onDone = onDone
        self._pinCoordinate = State(initialValue: coordinate)
        self._editablePhotos = State(initialValue: photos.compactMap { photo in
            DataURIImage.decode(photo.url).map { EditablePhoto(image: $0, category: photo.category) }
        })
        self._useStructuredHours = State(initialValue: hours != nil)
        self._hours = State(initialValue: hours ?? LandmarkHours())
        self._features = State(initialValue: Set(features))
        self._linkMenu = State(initialValue: links.menu ?? "")
        self._linkOrder = State(initialValue: links.order ?? "")
        self._linkWebsite = State(initialValue: links.website ?? "")
        self._linkDelivery = State(initialValue: links.delivery ?? "")
        self._priceRange = State(initialValue: priceRange)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("營業狀態") {
                    Picker("營業狀態", selection: $businessStatus) {
                        ForEach(BusinessStatus.allCases) { s in Text(s.label).tag(s) }
                    }
                }
                Section("簡介") {
                    TextField("簡介", text: $description, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    Toggle("每天分別設定（自動顯示現在有沒有開）", isOn: $useStructuredHours)
                    if useStructuredHours {
                        ForEach(hours.days, id: \.key) { day in
                            DayHoursEditRow(label: day.label, hours: Binding(
                                get: { hours.days.first { $0.key == day.key }?.hours },
                                set: { hours.setHours($0, forKey: day.key) }
                            ))
                        }
                    } else {
                        TextField("例如：週一至週日 11:00–21:00", text: $businessHours, axis: .vertical).lineLimit(2...4)
                    }
                } header: {
                    Text("營業時間")
                }
                Section("電話") {
                    TextField("電話", text: $phone).keyboardType(.phonePad)
                }
                Section("地址") {
                    AddressPickerMap(coordinate: $pinCoordinate)
                }
                Section {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: MAX_LANDMARK_PHOTOS, matching: .images) {
                        Label(editablePhotos.isEmpty ? "選擇相簿" : "重新選擇（會取代整本相簿）", systemImage: "photo.on.rectangle")
                    }
                    .onChange(of: photoItems) { _, items in
                        Task {
                            var loaded: [EditablePhoto] = []
                            for item in items {
                                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                                    loaded.append(EditablePhoto(image: img, category: .other))
                                }
                            }
                            editablePhotos = loaded
                        }
                    }
                    ForEach($editablePhotos) { $photo in
                        HStack(spacing: 12) {
                            Image(uiImage: photo.image).resizable().scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Picker("分類", selection: $photo.category) {
                                ForEach(PhotoCategory.allCases) { c in Text(c.label).tag(c) }
                            }
                            .labelsHidden()
                        }
                    }
                } header: {
                    Text("相簿（最多 \(MAX_LANDMARK_PHOTOS) 張，可分別標分類）")
                }
                Section("特色標籤") {
                    FeatureChipPicker(selected: $features)
                }
                Section("價位（選填）") {
                    Picker("價位", selection: $priceRange) {
                        Text("未提供").tag(Int?.none)
                        ForEach(1...4, id: \.self) { level in
                            Text(String(repeating: "$", count: level)).tag(Int?.some(level))
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("外部連結（選填）") {
                    TextField("菜單連結", text: $linkMenu).keyboardType(.URL).textInputAutocapitalization(.never)
                    TextField("線上點餐連結", text: $linkOrder).keyboardType(.URL).textInputAutocapitalization(.never)
                    TextField("官網連結", text: $linkWebsite).keyboardType(.URL).textInputAutocapitalization(.never)
                    TextField("外送連結", text: $linkDelivery).keyboardType(.URL).textInputAutocapitalization(.never)
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("編輯店家資訊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("儲存") {
                            isSubmitting = true
                            Task {
                                let photos: [LandmarkPhoto] = editablePhotos.compactMap { ep in
                                    PhotoUpload.encode(ep.image).map { LandmarkPhoto(url: $0, category: ep.category) }
                                }
                                let links = LandmarkLinks(
                                    menu: linkMenu.trimmingCharacters(in: .whitespaces).isEmpty ? nil : linkMenu,
                                    order: linkOrder.trimmingCharacters(in: .whitespaces).isEmpty ? nil : linkOrder,
                                    website: linkWebsite.trimmingCharacters(in: .whitespaces).isEmpty ? nil : linkWebsite,
                                    delivery: linkDelivery.trimmingCharacters(in: .whitespaces).isEmpty ? nil : linkDelivery
                                )
                                let ok = await UserLandmarkService.update(
                                    id: landmarkID, description: description, businessHours: businessHours,
                                    phone: phone, businessStatus: businessStatus, photo: nil, coordinate: pinCoordinate,
                                    photos: photos.isEmpty ? nil : photos,
                                    hours: useStructuredHours ? hours : nil,
                                    features: features.isEmpty ? nil : Array(features),
                                    links: links.isEmpty ? nil : links,
                                    priceRange: .some(priceRange)
                                )
                                if ok {
                                    onDone()
                                } else {
                                    isSubmitting = false
                                    errorText = "無法儲存 — 你不是這個地標已驗證的店家擁有者"
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

let MAX_LANDMARK_PHOTOS = 6

/// One day's row in the structured-hours editor: a toggle for "open at all today", plus the
/// open/close time pickers only shown while it is. Works off "HH:mm" strings (what the server
/// stores) via a small Date bridge, defaulting to a sensible 09:00–18:00 the first time a
/// previously-closed day gets turned on.
private struct DayHoursEditRow: View {
    let label: String
    @Binding var hours: DayHours?

    private static let timeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static func date(from hhmm: String) -> Date { Self.timeFormat.date(from: hhmm) ?? Date() }
    private static func string(from date: Date) -> String { Self.timeFormat.string(from: date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(label, isOn: Binding(
                get: { hours != nil },
                set: { on in hours = on ? (hours ?? DayHours(open: "09:00", close: "18:00")) : nil }
            ))
            if let dayHours = hours {
                HStack {
                    DatePicker("開店", selection: Binding(
                        get: { Self.date(from: dayHours.open) },
                        set: { hours = DayHours(open: Self.string(from: $0), close: dayHours.close) }
                    ), displayedComponents: .hourAndMinute)
                    DatePicker("打烊", selection: Binding(
                        get: { Self.date(from: dayHours.close) },
                        set: { hours = DayHours(open: dayHours.open, close: Self.string(from: $0)) }
                    ), displayedComponents: .hourAndMinute)
                }
                .font(.subheadline)
                .labelsHidden()
            }
        }
    }
}

/// Multi-select chip grid for the fixed feature vocabulary — tap to toggle, matching the visual
/// language of the read-only chips shown on PlaceDetailView itself.
private struct FeatureChipPicker: View {
    @Binding var selected: Set<LandmarkFeature>

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(LandmarkFeature.allCases) { feature in
                let isOn = selected.contains(feature)
                Button {
                    if isOn { selected.remove(feature) } else { selected.insert(feature) }
                } label: {
                    Label(feature.label, systemImage: feature.icon)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(isOn ? .blue.opacity(0.15) : Color(.secondarySystemBackground), in: Capsule())
                        .foregroundStyle(isOn ? .blue : .primary)
                        .overlay(Capsule().strokeBorder(isOn ? .blue : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
