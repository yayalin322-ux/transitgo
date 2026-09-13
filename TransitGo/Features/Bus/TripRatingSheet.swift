import SwiftUI

/// Shown once a navigation trip (walk/drive/scooter/cycle) actually finishes — the same
/// idea as the existing Live Activity board/alight rating flow for bus/rail trips
/// (see TripInteraction.swift/RateTripIntent), just for the in-app-navigation path which
/// didn't have one. Stars go through the same `/v1/ratings` the bus/rail flow already
/// uses; the optional note goes to `/v1/reports` as real, attributable feedback — not
/// just a number with no way to say what to actually improve.
struct TripRatingSheet: View {
    let tripName: String
    let modeLabel: String
    var onDone: () -> Void

    @State private var stars = 0
    @State private var note = ""
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("這趟\(modeLabel)前往\n\(tripName)\n覺得如何？")
                    .font(.headline).multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { n in
                        Button {
                            withAnimation(.spring(response: 0.25)) { stars = n }
                        } label: {
                            Image(systemName: n <= stars ? "star.fill" : "star")
                                .font(.system(size: 32))
                                .foregroundStyle(n <= stars ? .yellow : .secondary)
                        }
                    }
                }

                if stars > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(stars <= 3 ? "哪裡可以改善？（可留空）" : "有什麼想告訴我們的嗎？（可留空）")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("例如：路線繞遠、語音太慢、地圖不夠清楚…", text: $note, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...5)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer()

                Button {
                    submit()
                } label: {
                    Text(stars == 0 ? "略過" : "送出").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(submitted)
            }
            .padding()
            .navigationTitle("行程評分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { onDone() }
                }
            }
        }
        .interactiveDismissDisabled(false)
    }

    private func submit() {
        guard !submitted else { return }
        submitted = true
        if stars > 0 {
            RatingService.submit(stars: stars, kind: "navigation", route: modeLabel, from: "", to: tripName, system: "")
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                RatingService.submitFeedback(message: trimmed, context: ["tripName": tripName, "mode": modeLabel, "stars": stars])
            }
        }
        onDone()
    }
}
