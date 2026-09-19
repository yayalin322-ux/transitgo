import SwiftUI
import SwiftData
import CoreLocation

// MARK: - Home: 常用旅程

/// The "常用旅程" block on the home page: a compact list (no cards), the "加入常用旅程?" suggestion, and
/// "＋ 新增旅程". A row shows only what does not go stale (the two places, when it was last used) —
/// never a duration; that appears after the trip is re-planned.
struct FavoriteTripsSection: View {
    /// A favorite was tapped: the caller records the use and opens the planner.
    var onOpen: (FavoriteTrip) -> Void
    var onAdd: () -> Void
    var onEdit: (FavoriteTrip) -> Void

    @Environment(\.modelContext) private var context
    @Query private var trips: [FavoriteTrip]
    @Query(sort: \RecentTrip.searchedAt, order: .reverse) private var recents: [RecentTrip]
    @AppStorage("favoriteTrips.sort") private var sortRaw = "recent"

    private var sorted: [FavoriteTrip] {
        TripStore(context: context).favorites(sortedBy: sortRaw == "count" ? .mostUsed : .recentlyUsed)
    }

    var body: some View {
        Section {
            ForEach(sorted.prefix(5)) { trip in
                Button { onOpen(trip) } label: { FavoriteTripRow(trip: trip) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("刪除", role: .destructive) { try? TripStore(context: context).delete(trip) }
                        Button("編輯") { onEdit(trip) }.tint(.blue)
                    }
            }
            if let recent = TripStore(context: context).suggestion() {
                TripSuggestionRow(recent: recent)
            }
            Button { onAdd() } label: { Label("新增旅程", systemImage: "plus.circle") }
        } header: {
            HStack {
                Text("常用旅程")
                Spacer()
                if trips.count > 1 {
                    Menu {
                        Button("最近使用") { sortRaw = "recent" }
                        Button("使用次數") { sortRaw = "count" }
                    } label: { Text(sortRaw == "count" ? "使用次數" : "最近使用").font(.caption) }
                }
            }
        }
    }
}

struct FavoriteTripRow: View {
    let trip: FavoriteTrip
    var body: some View {
        let spec = trip.spec
        HStack(spacing: 10) {
            Text(spec.destination.emoji)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(spec.origin.emoji) \(spec.origin.name) → \(spec.destination.emoji) \(spec.destination.name)")
                    .font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                Text(TripDateText.lastUsed(trip.lastUsedAt)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// "你最近常查詢：家 → 學校 [加入常用旅程] [不用了]". Only ever a question — nothing is added on its own.
struct TripSuggestionRow: View {
    let recent: RecentTrip
    @Environment(\.modelContext) private var context

    var body: some View {
        let spec = recent.spec
        VStack(alignment: .leading, spacing: 6) {
            Text("要加入常用旅程嗎？").font(.footnote.weight(.semibold))
            Text("你最近常查詢：\(spec.origin.name) → \(spec.destination.name)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("加入常用旅程") { _ = try? TripStore(context: context).addFavorite(spec: spec) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("不用了") { try? TripStore(context: context).dismissSuggestion(recent) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Planner: 最近搜尋

struct RecentTripsSection: View {
    var onSelect: (TripSpec) -> Void
    @Query(sort: \RecentTrip.searchedAt, order: .reverse) private var recents: [RecentTrip]
    @Environment(\.modelContext) private var context

    var body: some View {
        if !recents.isEmpty {
            Section {
                ForEach(recents) { r in
                    Button { onSelect(r.spec) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.originName) → \(r.destinationName)").font(.subheadline).foregroundStyle(.primary)
                            Text(TripDateText.recent(r.searchedAt)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("移除", role: .destructive) { try? TripStore(context: context).deleteRecent(r) } }
                }
            } header: {
                HStack {
                    Text("最近搜尋")
                    Spacer()
                    Button("清除") { try? TripStore(context: context).clearRecents() }.font(.caption)
                }
            }
        }
    }
}

// MARK: - Create / edit a favorite

/// Where the editor is opened from — decides the search area for the place pickers.
struct TripEditorContext {
    var city: BusCity?
    var near: CLLocationCoordinate2D?
}

struct FavoriteTripEditor: View {
    /// nil = creating. Editing changes the saved places/preference only; it never touches use history.
    var existing: FavoriteTrip?
    var initial: TripSpec?
    var context: TripEditorContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var nameEdited = false
    @State private var origin: TripEndpoint = .currentLocation
    @State private var destination: TripEndpoint?
    @State private var profile: TripProfile = .fastest
    @State private var picking: TripSide?
    @State private var errorText: String?
    @State private var confirmDelete = false
    @State private var loaded = false

    private var spec: TripSpec? { destination.map { TripSpec(origin: origin, destination: $0, profile: profile) } }

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱") {
                    TextField("例如：家 → 學校", text: $name).onChange(of: name) { _, _ in nameEdited = true }
                }
                Section("起點") {
                    endpointRow(origin, side: .origin)
                    endpointNaming(for: .origin)
                }
                Section {
                    Button { swapEnds() } label: { Label("互換起點與終點", systemImage: "arrow.up.arrow.down") }
                        .disabled(destination == nil || origin.isCurrentLocation && destination?.isCurrentLocation == true)
                }
                Section("終點") {
                    if let destination { endpointRow(destination, side: .destination); endpointNaming(for: .destination) }
                    else { Button { picking = .destination } label: { Label("選擇終點", systemImage: "magnifyingglass") } }
                }
                Section {
                    ForEach(TripProfile.allCases) { p in
                        Button {
                            if p.isSelectable { profile = p }
                        } label: {
                            HStack {
                                Text(p.title).foregroundStyle(p.isSelectable ? Color.primary : Color.secondary)
                                Spacer()
                                if profile == p { Image(systemName: "checkmark").foregroundStyle(.blue) }
                            }
                        }
                        .disabled(!p.isSelectable)
                    }
                } header: { Text("偏好") } footer: { Text("儲存的是起點、終點與偏好；每次開啟都會依當下時間重新規劃。") }
                if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
                if existing != nil {
                    Section { Button("刪除這個旅程", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(existing == nil ? "新增常用旅程" : "編輯旅程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存") { save() }.disabled(spec == nil) }
            }
            .sheet(item: Binding(get: { picking.map(PickingSide.init) }, set: { picking = $0?.side })) { p in
                EndpointPickerSheet(side: p.side, context: context) { endpoint in
                    if p.side == .origin { origin = endpoint } else { destination = endpoint }
                    refreshAutoName()
                }
            }
            .confirmationDialog("刪除這個常用旅程？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let existing { try? TripStore(context: modelContext).delete(existing) }
                    dismiss()
                }
            }
            .onAppear(perform: load)
        }
    }

    private struct PickingSide: Identifiable { let side: TripSide; var id: Int { side == .origin ? 0 : 1 } }

    @ViewBuilder
    private func endpointRow(_ endpoint: TripEndpoint, side: TripSide) -> some View {
        Button { picking = side } label: {
            HStack {
                Text(endpoint.emoji)
                Text(endpoint.name).foregroundStyle(.primary)
                Spacer()
                Text("更換").font(.caption).foregroundStyle(.blue)
            }
        }
    }

    /// 家 / 學校 / 公司 / 其他 — quick labels for the place, or any text of your own. The label is only a
    /// name; which place it is stays the stop/coordinate underneath.
    private func endpointNaming(for side: TripSide) -> some View {
        let binding = Binding<String>(
            get: { side == .origin ? origin.name : (destination?.name ?? "") },
            set: { v in
                if side == .origin { origin.name = v } else { destination?.name = v }
                refreshAutoName()
            })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                ForEach(TripNamePreset.allCases) { preset in
                    Button(preset.rawValue) { binding.wrappedValue = preset.rawValue }.buttonStyle(.bordered).controlSize(.mini)
                }
            }
            TextField("自訂名稱，例如：補習班、阿嬤家", text: binding).font(.footnote)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let existing {
            let s = existing.spec
            origin = s.origin; destination = s.destination; profile = s.profile
            name = existing.name; nameEdited = existing.name != TripStore.defaultName(for: s)
        } else if let initial {
            origin = initial.origin; destination = initial.destination; profile = initial.profile
            name = TripStore.defaultName(for: initial); nameEdited = false
        }
    }

    private func refreshAutoName() {
        guard !nameEdited, let destination else { return }
        name = "\(origin.name) → \(destination.name)"
        nameEdited = false
    }

    private func swapEnds() {
        guard let destination else { return }
        let o = origin
        origin = destination
        self.destination = o
        refreshAutoName()
    }

    private func save() {
        guard let spec else { return }
        let store = TripStore(context: modelContext)
        do {
            if let existing { try store.update(existing, name: name, spec: spec) }
            else { try store.addFavorite(name: name, spec: spec) }
            dismiss()
        } catch TripStore.StoreError.duplicate {
            errorText = "已經有這個起點與終點的常用旅程了"
        } catch {
            errorText = "起點與終點不能相同，且必須是有效的地點"
        }
    }
}

// MARK: - Place picker

struct EndpointPickerSheet: View {
    var side: TripSide
    var context: TripEditorContext
    var onPick: (TripEndpoint) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var results: [DestinationCandidate] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if side == .origin {
                    Button { onPick(.currentLocation); dismiss() } label: { Label("目前位置", systemImage: "location.fill") }
                }
                Section("快速選擇") {
                    HStack {
                        ForEach(SavedPlaceRole.allCases) { role in
                            if let place = SavedPlaceStore.get(role) {
                                Button {
                                    onPick(TripEndpoint(name: role == .home ? "家" : "公司", kind: .address, coordinate: place.coordinate)); dismiss()
                                } label: { Label(role.label, systemImage: role.icon).font(.caption) }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                Section("搜尋") {
                    TextField("站名或地標，例如 台北101、台北車站", text: $text)
                        .onChange(of: text) { _, v in search(v) }
                    if searching { ProgressView() }
                    ForEach(results) { c in
                        Button { onPick(c.endpoint); dismiss() } label: {
                            VStack(alignment: .leading) {
                                Text(c.name).foregroundStyle(.primary)
                                if let sub = c.subtitle { Text(sub).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(side == .origin ? "選擇起點" : "選擇終點")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func search(_ value: String) {
        task?.cancel()
        let keyword = value.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { results = []; return }
        let near = context.near ?? CLLocationCoordinate2D(latitude: 25.0478, longitude: 121.5170)
        task = Task {
            searching = true
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            let city = context.city
            async let stops: [DestinationCandidate] = {
                guard let city else { return [] }
                return await TransferPlannerViewModel.searchStops(keyword, city: city)
            }()
            async let places = TransferPlannerViewModel.searchLandmarks(keyword, near: near)
            let combined = await stops + places
            if !Task.isCancelled { results = combined; searching = false }
        }
    }
}
