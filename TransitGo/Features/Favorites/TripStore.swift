import Foundation
import SwiftData

enum FavoriteTripSort { case recentlyUsed, mostUsed }

/// All reads/writes of saved and recent journeys. A thin layer over one `ModelContext` so the views,
/// the planner and the tests share the exact same rules (de-duplication, the recents cap, the
/// suggestion threshold) — and none of it touches the network.
@MainActor
struct TripStore {
    let context: ModelContext

    /// Recents kept before the oldest is dropped.
    static let maxRecents = 10
    /// Searches of the same journey before we ask "add to favorites?".
    static let suggestionThreshold = 3

    enum StoreError: Error, Equatable { case invalidTrip, duplicate(UUID) }

    // MARK: Favorites — create / read / update / delete

    /// Saves a journey. The same origin+destination can only be saved once (its preference/name can be
    /// edited instead): a second attempt throws `.duplicate` carrying the existing one's id.
    @discardableResult
    func addFavorite(name: String? = nil, spec: TripSpec, at date: Date = .now) throws -> FavoriteTrip {
        guard spec.isValid else { throw StoreError.invalidTrip }
        if let existing = favorites().first(where: { $0.spec.identity == spec.identity }) { throw StoreError.duplicate(existing.id) }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trip = FavoriteTrip(name: trimmed.isEmpty ? Self.defaultName(for: spec) : trimmed, spec: spec, createdAt: date)
        context.insert(trip)
        try context.save()
        return trip
    }

    func favorites(sortedBy sort: FavoriteTripSort = .recentlyUsed) -> [FavoriteTrip] {
        let all = (try? context.fetch(FetchDescriptor<FavoriteTrip>())) ?? []
        switch sort {
        case .recentlyUsed:
            return all.sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
        case .mostUsed:
            return all.sorted { $0.useCount != $1.useCount ? $0.useCount > $1.useCount : ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
        }
    }

    func favorite(id: UUID) -> FavoriteTrip? { favorites().first { $0.id == id } }

    /// Rename / change either end / change the preference. Editing never touches use history, and never
    /// creates a second favorite for the same journey.
    func update(_ trip: FavoriteTrip, name: String? = nil, spec: TripSpec? = nil) throws {
        if let spec {
            guard spec.isValid else { throw StoreError.invalidTrip }
            if let clash = favorites().first(where: { $0.id != trip.id && $0.spec.identity == spec.identity }) { throw StoreError.duplicate(clash.id) }
            trip.spec = spec
        }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            trip.name = trimmed.isEmpty ? Self.defaultName(for: trip.spec) : trimmed
        }
        try context.save()
    }

    func delete(_ trip: FavoriteTrip) throws {
        context.delete(trip)
        try context.save()
    }

    /// Called when the user starts a favorite: `useCount += 1`, `lastUsedAt = now` — nothing else.
    func recordUse(_ trip: FavoriteTrip, at date: Date = .now) throws {
        trip.useCount += 1
        trip.lastUsedAt = date
        try context.save()
    }

    static func defaultName(for spec: TripSpec) -> String { "\(spec.origin.name) → \(spec.destination.name)" }

    // MARK: Recents

    /// Notes that a journey was searched. Same journey (by endpoint identity, not name) → its time and
    /// count are refreshed; a new one is added and the list is cut back to `maxRecents`.
    func recordSearch(_ spec: TripSpec, at date: Date = .now) throws {
        guard spec.isValid else { return }
        if let existing = try recentRecords().first(where: { $0.identity == spec.identity }) {
            existing.searchedAt = date
            existing.searchCount += 1
            // keep the latest display names (a place can be renamed)
            existing.originName = spec.origin.name
            existing.destinationName = spec.destination.name
        } else {
            context.insert(RecentTrip(spec: spec, at: date))
        }
        try context.save()
        try pruneRecents()
    }

    /// Newest first.
    func recents() -> [RecentTrip] {
        ((try? recentRecords()) ?? []).sorted { $0.searchedAt > $1.searchedAt }
    }

    func clearRecents() throws {
        for r in try recentRecords() { context.delete(r) }
        try context.save()
    }

    func deleteRecent(_ recent: RecentTrip) throws {
        context.delete(recent)
        try context.save()
    }

    private func recentRecords() throws -> [RecentTrip] { try context.fetch(FetchDescriptor<RecentTrip>()) }

    private func pruneRecents() throws {
        let sorted = recents()
        guard sorted.count > Self.maxRecents else { return }
        for r in sorted.dropFirst(Self.maxRecents) { context.delete(r) }
        try context.save()
    }

    // MARK: "Add to favorites?" suggestion

    /// One journey searched at least `suggestionThreshold` times that is not already a favorite and that
    /// the user hasn't dismissed. A suggestion only — nothing is ever added automatically.
    func suggestion() -> RecentTrip? {
        let saved = Set(favorites().map { $0.spec.identity })
        return recents()
            .filter { $0.searchCount >= Self.suggestionThreshold && !$0.suggestionDismissed && !saved.contains($0.identity) }
            .max { $0.searchCount != $1.searchCount ? $0.searchCount < $1.searchCount : $0.searchedAt < $1.searchedAt }
    }

    func dismissSuggestion(_ recent: RecentTrip) throws {
        recent.suggestionDismissed = true
        try context.save()
    }

    /// True when this journey is already a saved favorite (for the ☆/★ state on the planner).
    func isFavorite(_ spec: TripSpec) -> Bool { favorites().contains { $0.spec.identity == spec.identity } }
}
