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
    @State private var photoItem: PhotosPickerItem?
    @State private var photoImage: UIImage?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("地標名稱", text: $name)
                    TextField("簡介（可留空）", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("新增地標")
                } footer: {
                    Text("會先送到後台審核，核准後其他使用者才會在「附近」看到。位置使用你目前的定位。")
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
                            UserLandmarkService.submit(name: name, description: description, coordinate: coordinate, photo: photo)
                            onDone()
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}
