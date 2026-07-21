//
//  ConnectionLibrary.swift
//  glas.sh
//
//  Transient projections over the existing connection and workgroup stores.
//

import Foundation

enum ConnectionLibraryMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case library
    case favorites
    case recent
    case collections
    case workgroups
    case network
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "Library"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        case .collections: return "Collections"
        case .workgroups: return "Workgroups"
        case .network: return "Network"
        case .settings: return "Settings"
        }
    }
}

enum ConnectionLibraryScope: Hashable, Identifiable, Sendable {
    case allConnections
    case favorites
    case recent
    case collection(String)
    case workgroups
    case network
    case settings

    var id: String {
        switch self {
        case .allConnections: return "all-connections"
        case .favorites: return "favorites"
        case .recent: return "recent"
        case .collection(let id): return "collection-\(id)"
        case .workgroups: return "workgroups"
        case .network: return "network"
        case .settings: return "settings"
        }
    }
}

struct ConnectionLibraryCollection: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let serverIDs: [UUID]

    var count: Int { serverIDs.count }
}

struct ConnectionLibraryProjection {
    let servers: [ServerConfiguration]
    let favoriteServerIDs: [UUID]
    let recentServerIDs: [UUID]
    let collections: [ConnectionLibraryCollection]
    let workgroups: [LayoutPreset]
    let networkIsConfigured: Bool

    private struct CollectionAccumulator {
        var names: Set<String> = []
        var serverIDs: [UUID] = []
    }

    init(
        servers: [ServerConfiguration],
        workgroups: [LayoutPreset],
        networkIsConfigured: Bool,
        recentLimit: Int = 10
    ) {
        var seenServerIDs = Set<UUID>()
        let uniqueServers = servers.filter { seenServerIDs.insert($0.id).inserted }
        self.servers = uniqueServers
        self.workgroups = workgroups
        self.networkIsConfigured = networkIsConfigured

        favoriteServerIDs = uniqueServers
            .filter(\.isFavorite)
            .sorted(by: Self.activityOrder)
            .map(\.id)

        recentServerIDs = uniqueServers
            .filter { $0.lastConnected != nil }
            .sorted(by: Self.recentOrder)
            .prefix(max(0, recentLimit))
            .map(\.id)

        var collectionsByID: [String: CollectionAccumulator] = [:]
        for server in uniqueServers {
            var serverCollectionIDs = Set<String>()
            for rawTag in server.tags {
                let name = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let id = Self.collectionID(for: name),
                      serverCollectionIDs.insert(id).inserted else {
                    continue
                }
                var accumulator = collectionsByID[id, default: CollectionAccumulator()]
                accumulator.names.insert(name)
                accumulator.serverIDs.append(server.id)
                collectionsByID[id] = accumulator
            }
        }

        collections = collectionsByID.map { id, accumulator in
            ConnectionLibraryCollection(
                id: id,
                name: accumulator.names.sorted(by: Self.displayOrder).first ?? id,
                serverIDs: accumulator.serverIDs
            )
        }
        .sorted { Self.displayOrder($0.name, $1.name) }
    }

    var availableModes: [ConnectionLibraryMode] {
        ConnectionLibraryMode.allCases.filter { mode in
            mode != .network || networkIsConfigured
        }
    }

    func scopes(for mode: ConnectionLibraryMode) -> [ConnectionLibraryScope] {
        switch mode {
        case .library: return [.allConnections]
        case .favorites: return [.favorites]
        case .recent: return [.recent]
        case .collections: return collections.map { .collection($0.id) }
        case .workgroups: return [.workgroups]
        case .network: return networkIsConfigured ? [.network] : []
        case .settings: return [.settings]
        }
    }

    func collection(named name: String) -> ConnectionLibraryCollection? {
        guard let id = Self.collectionID(for: name) else { return nil }
        return collections.first { $0.id == id }
    }

    func servers(
        in scope: ConnectionLibraryScope,
        searchQuery: String = "",
        activeTagFilters: [String] = []
    ) -> [ServerConfiguration] {
        let candidates: [ServerConfiguration]
        switch scope {
        case .allConnections:
            candidates = servers
        case .favorites:
            candidates = servers(withIDs: favoriteServerIDs)
        case .recent:
            candidates = servers(withIDs: recentServerIDs)
        case .collection(let collectionID):
            candidates = servers(withIDs: collections.first { $0.id == collectionID }?.serverIDs ?? [])
        case .workgroups, .network, .settings:
            candidates = []
        }
        return matchingServers(
            from: candidates,
            searchQuery: searchQuery,
            activeTagFilters: activeTagFilters
        )
    }

    func matchingServers(
        from candidates: [ServerConfiguration],
        searchQuery: String = "",
        activeTagFilters: [String] = []
    ) -> [ServerConfiguration] {
        var seenServerIDs = Set<UUID>()
        var result = candidates.filter { seenServerIDs.insert($0.id).inserted }

        let activeCollectionIDs = Set(activeTagFilters.compactMap(Self.collectionID(for:)))
        if !activeCollectionIDs.isEmpty {
            result = result.filter { server in
                let serverCollectionIDs = Set(server.tags.compactMap(Self.collectionID(for:)))
                return !activeCollectionIDs.isDisjoint(with: serverCollectionIDs)
            }
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { server in
                server.name.localizedCaseInsensitiveContains(query)
                    || server.host.localizedCaseInsensitiveContains(query)
                    || server.username.localizedCaseInsensitiveContains(query)
                    || server.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        return result
    }

    func workgroups(matching searchQuery: String = "") -> [LayoutPreset] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workgroups }
        return workgroups.filter { preset in
            preset.name.localizedCaseInsensitiveContains(query)
                || preset.sessionIntents.contains { intent in
                    intent.label?.localizedCaseInsensitiveContains(query) == true
                        || intent.startupCommand?.localizedCaseInsensitiveContains(query) == true
                }
        }
    }

    func resolvedSelection(
        preferredServerID: UUID?,
        in scope: ConnectionLibraryScope,
        searchQuery: String = "",
        activeTagFilters: [String] = []
    ) -> UUID? {
        guard let preferredServerID else { return nil }
        return servers(
            in: scope,
            searchQuery: searchQuery,
            activeTagFilters: activeTagFilters
        ).contains { $0.id == preferredServerID } ? preferredServerID : nil
    }

    func itemCount(in scope: ConnectionLibraryScope) -> Int {
        switch scope {
        case .workgroups: return workgroups.count
        case .network: return networkIsConfigured ? 1 : 0
        case .settings: return 0
        default: return servers(in: scope).count
        }
    }

    private func servers(withIDs ids: [UUID]) -> [ServerConfiguration] {
        let serversByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        return ids.compactMap { serversByID[$0] }
    }

    static func collectionID(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func activityOrder(
        _ lhs: ServerConfiguration,
        _ rhs: ServerConfiguration
    ) -> Bool {
        let lhsDate = lhs.lastConnected ?? lhs.dateAdded
        let rhsDate = rhs.lastConnected ?? rhs.dateAdded
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return serverOrder(lhs, rhs)
    }

    private static func recentOrder(
        _ lhs: ServerConfiguration,
        _ rhs: ServerConfiguration
    ) -> Bool {
        if lhs.lastConnected != rhs.lastConnected {
            return (lhs.lastConnected ?? .distantPast) > (rhs.lastConnected ?? .distantPast)
        }
        return serverOrder(lhs, rhs)
    }

    private static func serverOrder(
        _ lhs: ServerConfiguration,
        _ rhs: ServerConfiguration
    ) -> Bool {
        if displayOrder(lhs.name, rhs.name) { return true }
        if displayOrder(rhs.name, lhs.name) { return false }
        if lhs.host != rhs.host { return lhs.host < rhs.host }
        if lhs.username != rhs.username { return lhs.username < rhs.username }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func displayOrder(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs < rhs
    }
}
