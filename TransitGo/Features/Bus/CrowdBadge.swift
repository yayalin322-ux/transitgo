import SwiftUI

struct CrowdBadge: View {
    let crowding: BusCrowding

    private var color: Color {
        switch crowding.level {
        case .comfortable: return .green
        case .moderate: return .orange
        case .crowded: return .red
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.3.fill")
                .font(.caption2)
            Text(crowding.level.label)
                .font(.caption2.weight(.semibold))
            if crowding.level == .comfortable, let seats = crowding.remainingSeats, seats > 0 {
                Text("剩\(seats)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if crowding.isDemo {
                Text("示範")
                    .font(.system(size: 9).weight(.bold))
                    .foregroundStyle(.secondary)
            } else if crowding.isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}
