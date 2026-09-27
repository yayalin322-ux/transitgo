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
    /// Which review (if any) in `reviews` this device itself posted — enables a "delete my
    /// review" button in place of the report menu on that one row.
    @State private var myReviewID: Int?

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
                    if businessVerified, businessStatus != .open {
                        Label(businessStatus.label, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(businessStatus == .permanentlyClosed ? .red : .orange)
                    }
                    if let hours = businessHours {
                        Label(hours, systemImage: "clock.fill")
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
                        phone: businessPhone ?? "", businessStatus: businessStatus, coordinate: coordinate
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

    @State private var photoItem: PhotosPickerItem?
    @State private var photoImage: UIImage?
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var pinCoordinate: CLLocationCoordinate2D

    init(
        landmarkID: Int, description: String, businessHours: String, phone: String,
        businessStatus: BusinessStatus, coordinate: CLLocationCoordinate2D, onDone: @escaping () -> Void
    ) {
        self.landmarkID = landmarkID
        self._description = State(initialValue: description)
        self._businessHours = State(initialValue: businessHours)
        self._phone = State(initialValue: phone)
        self._businessStatus = State(initialValue: businessStatus)
        self.coordinate = coordinate
        self.onDone = onDone
        self._pinCoordinate = State(initialValue: coordinate)
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
                Section("營業時間") {
                    TextField("例如：週一至週日 11:00–21:00", text: $businessHours, axis: .vertical).lineLimit(2...4)
                }
                Section("電話") {
                    TextField("電話", text: $phone).keyboardType(.phonePad)
                }
                Section("地址") {
                    AddressPickerMap(coordinate: $pinCoordinate)
                }
                Section("照片") {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        if let photoImage {
                            Image(uiImage: photoImage).resizable().scaledToFill()
                                .frame(height: 140).frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            Label("更換照片（可留空）", systemImage: "camera")
                        }
                    }
                    .onChange(of: photoItem) { _, item in
                        Task {
                            if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                                photoImage = img
                            }
                        }
                    }
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
                                let photo = photoImage.flatMap { PhotoUpload.encode($0) }
                                let ok = await UserLandmarkService.update(
                                    id: landmarkID, description: description, businessHours: businessHours,
                                    phone: phone, businessStatus: businessStatus, photo: photo, coordinate: pinCoordinate
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
