import Foundation
import SwiftData

/// The app's SwiftData schema history. V1 is exactly what shipped before favorite trips existed
/// (`FavoriteItem` + `RailTicket`, no migration plan); V2 adds `FavoriteTrip` and `RecentTrip`.
/// Adding entities is a lightweight migration: existing rows in the old tables are untouched.
enum AppSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [FavoriteItem.self, RailTicket.self] }
}

enum AppSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [FavoriteItem.self, RailTicket.self, FavoriteTrip.self, RecentTrip.self] }
}

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [AppSchemaV1.self, AppSchemaV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2.self)] }
}

enum AppStore {
    /// The one container the app uses. `inMemory` is for tests and previews.
    static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: AppSchemaV2.self)
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        }
        return try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self, configurations: [configuration])
    }
}
