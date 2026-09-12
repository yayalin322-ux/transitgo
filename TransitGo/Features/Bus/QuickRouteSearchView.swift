import SwiftUI

/// Lightweight route search shown in a half-height sheet on the home page.
/// Picking a result hands the route back to the caller, which opens it as a
/// normal full page (same `BusRouteDetailView` reached from every other entry point).
struct QuickRouteSearchView: View {
    var onPick: (ScopedRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = BusSearchViewModel()

    var body: some View {
        NavigationStack {
            List {
                if model.keyword.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section("最近查詢") {
                        if SearchHistoryStore.shared.routes.isEmpty {
                            Text("輸入路線號碼，例如 307、1819")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(SearchHistoryStore.shared.routes) { item in
                                Button {
                                    pick(ScopedRoute(
                                        scope: item.scope,
                                        route: BusRoute(routeUID: item.routeUID,
                                                        routeName: LocalizedName(zhTw: item.name, en: nil),
                                                        departureStopNameZh: nil,
                                                        destinationStopNameZh: nil)))
                                } label: {
                                    routeRow(name: item.name, scope: item.scope.displayName, endpoints: item.endpoints)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    if model.partial {
                        Label("部分地區查詢忙碌中", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(model.results) { item in
                        Button {
                            pick(item)
                        } label: {
                            routeRow(name: item.route.name,
                                     scope: item.scope.displayName,
                                     endpoints: item.route.endpointsText)
                        }
                        .buttonStyle(.plain)
                    }
                    if model.results.isEmpty, !model.isLoading {
                        Text(model.partial ? "運輸資料平台暫時無回應" : "找不到路線")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $model.keyword, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "路線號碼")
            .onChange(of: model.keyword) { _, _ in model.search() }
            .overlay { if model.isLoading { ProgressView() } }
            .navigationTitle("搜尋路線")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func pick(_ route: ScopedRoute) {
        dismiss()
        onPick(route)
    }

    private func routeRow(name: String, scope: String, endpoints: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name).font(.headline).foregroundStyle(.primary)
                Text(scope)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            Text(endpoints).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
