import SwiftUI

/// This device's own submitted landmarks, with real status (pending/approved, and
/// business-verified) — the entry point for a business owner to find their own listing
/// and, once verified, edit it, instead of having to hunt for their own pin on the map.
struct MyLandmarksView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var landmarks: [UserLandmark] = []
    @State private var isLoading = true
    @State private var detailTarget: UserLandmark?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if landmarks.isEmpty {
                    Text("你還沒有新增過地標").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(landmarks) { l in
                    Button { detailTarget = l } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: l.category.icon).foregroundStyle(l.category.color)
                                Text(l.name).foregroundStyle(.primary)
                                Spacer()
                                statusBadge(l)
                            }
                            if !l.description.isEmpty {
                                Text(l.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("我的地標")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
            }
            .task { landmarks = await UserLandmarkService.mine(); isLoading = false }
            .sheet(item: $detailTarget) { l in
                PlaceDetailView(name: l.name, coordinate: l.coordinate, subtitle: l.description,
                                 landmarkID: l.id, businessHours: l.businessVerified ? l.businessHours : nil,
                                 businessVerified: l.businessVerified)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ l: UserLandmark) -> some View {
        if l.approved == false {
            Text("待審核").font(.caption2).foregroundStyle(.orange)
        } else if l.isBusinessClaim == true {
            Text(l.businessVerified ? "已驗證店家" : "店家審核中").font(.caption2).foregroundStyle(l.businessVerified ? .green : .orange)
        } else {
            Text("已公開").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
