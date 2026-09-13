import SwiftUI
import PhotosUI
import CoreLocation

/// Lets a user submit a real landmark of their own (e.g. a small shop Apple's POI index
/// doesn't have) at their current location. Goes into transitgo-server's moderation
/// queue — nobody else sees it until an admin approves it (see /v1/admin/landmarks).
struct AddLandmarkView: View {
    let coordinate: CLLocationCoordinate2D
    var onDone: () -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var category: LandmarkCategory = .other
    @State private var photoItem: PhotosPickerItem?
    @State private var photoImage: UIImage?
    @State private var isBusinessClaim = false
    @State private var businessHours = ""
    @State private var phone = ""
    @State private var isSubmitting = false
    @State private var pinCoordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D, onDone: @escaping () -> Void) {
        self.coordinate = coordinate
        self.onDone = onDone
        self._pinCoordinate = State(initialValue: coordinate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("地標名稱", text: $name)
                    Picker("類型", selection: $category) {
                        ForEach(LandmarkCategory.allCases) { c in
                            Label(c.label, systemImage: c.icon).tag(c)
                        }
                    }
                    TextField("簡介（可留空）", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("新增地標")
                } footer: {
                    Text("會先送到後台審核，核准後其他使用者才會在「附近」看到。")
                }
                Section("地址") {
                    AddressPickerMap(coordinate: $pinCoordinate)
                }
                Section {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        if let photoImage {
                            Image(uiImage: photoImage).resizable().scaledToFill()
                                .frame(height: 140).frame(maxWidth: .infinity)
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
                }
                Section {
                    Toggle("我是這裡的店家", isOn: $isBusinessClaim)
                    if isBusinessClaim {
                        TextField("營業時間，例如：週一至週日 11:00–21:00", text: $businessHours, axis: .vertical)
                            .lineLimit(2...4)
                        TextField("電話", text: $phone)
                            .keyboardType(.phonePad)
                    }
                } footer: {
                    Text(isBusinessClaim
                         ? "店家身分需要後台人工審核通過後，營業時間才會顯示給其他使用者——任何人都能新增地標，所以未經驗證的內容不會直接視為真實店家資訊。"
                         : "如果你是這個地點的店家本人，可以打開這個選項填寫營業時間（需審核）。")
                }
            }
            .navigationTitle("新增地標")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("送出") {
                            isSubmitting = true
                            let photo = photoImage.flatMap { PhotoUpload.encode($0) }
                            UserLandmarkService.submit(
                                name: name, description: description, category: category, coordinate: pinCoordinate,
                                photo: photo, isBusinessClaim: isBusinessClaim,
                                businessHours: isBusinessClaim ? businessHours : nil,
                                phone: isBusinessClaim ? phone : nil
                            )
                            onDone()
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}
