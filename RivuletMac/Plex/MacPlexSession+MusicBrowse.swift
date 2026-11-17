// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// An artist's mix: their best known songs and those of the artists like them
/// in the library, then radio from there.
nonisolated struct MacMusicMix: Identifiable, Hashable, Sendable {
    let artist: PlexMetadata
    /// Artists like this one in the same library, for the caption and the songs.
    let similar: [PlexMetadata]

    var id: String { artist.ratingKey ?? artist.title ?? "" }
    var title: String { "\(artist.title ?? "") Mix" }
    var caption: String {
        similar.isEmpty ? "Songs like \(artist.title ?? "")'s" : similar.compactMap(\.title).joined(separator: ", ")
    }

    static func == (lhs: MacMusicMix, rhs: MacMusicMix) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The browse lists Plex does not send as rows: mixes, On This Day,
/// compilations and the songs kept on this Mac. Plexamp builds the first two
/// itself too; `/hubs/sections` has neither (measured on PMS 1.43).
extension MacPlexSession {
    // MARK: - Mixes

    /// Up to six mixes, from the artists played most and most lately here.
    func mixesForYou(_ library: PlexLibrary, recentlyPlayed: [PlexMetadata]) async -> [MacMusicMix] {
        guard let (serverURL, token) = try? configuration() else { return [] }
        let top = (try? await network.getHubItems(
            serverURL: serverURL, authToken: token,
            hubKey: "/library/sections/\(library.key)/all?type=8&sort=viewCount:desc&viewCount%3E%3E=0",
            start: 0, count: 8).items) ?? []
        // Lately played first, so the row changes with what is being listened to.
        var seen = Set<String>()
        let seeds = (recentlyPlayed.prefix(3) + top)
            .filter { $0.type == "artist" && $0.title != "Various Artists" && $0.ratingKey.map { seen.insert($0).inserted } ?? false }
            .prefix(6)
        let network = network
        return await withTaskGroup(of: (Int, MacMusicMix).self) { group in
            for (index, artist) in seeds.enumerated() {
                group.addTask {
                    let similar = (try? await network.getHubItems(
                        serverURL: serverURL, authToken: token,
                        hubKey: "/library/metadata/\(artist.ratingKey ?? "")/similar",
                        start: 0, count: 6).items) ?? []
                    return (index, MacMusicMix(artist: artist, similar: similar.filter { $0.type == "artist" }))
                }
            }
            var mixes: [(Int, MacMusicMix)] = []
            for await mix in group { mixes.append(mix) }
            return mixes.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// The mix's opening songs: ten of the artist's best known and five of each
    /// similar artist's, shuffled, starting with one of the artist's own.
    func tracks(of mix: MacMusicMix, sectionKey: String) async -> [PlexMetadata] {
        guard let (serverURL, token) = try? configuration() else { return [] }
        let artists = [mix.artist] + mix.similar.prefix(5)
        let network = network
        let lists = await withTaskGroup(of: (Int, [PlexMetadata]).self) { group in
            for (index, artist) in artists.enumerated() {
                group.addTask {
                    let tracks = (try? await network.getPopularTracks(
                        serverURL: serverURL, authToken: token, sectionId: sectionKey,
                        artistKey: artist.ratingKey ?? "", count: index == 0 ? 10 : 5)) ?? []
                    return (index, tracks)
                }
            }
            var lists: [(Int, [PlexMetadata])] = []
            for await list in group { lists.append(list) }
            return lists.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard var own = lists.first, !own.isEmpty else { return lists.flatMap { $0 }.shuffled() }
        own.shuffle()
        let opener = own.removeFirst()
        return [opener] + (own + lists.dropFirst().flatMap { $0 }).shuffled()
    }

    // MARK: - On This Day

    /// Albums released on this day in earlier years, newest first.
    func onThisDay(_ library: PlexLibrary, date: Date = .now) async -> [PlexMetadata] {
        guard let (serverURL, token) = try? configuration() else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let thisYear = parts.year, let month = parts.month, let day = parts.day else { return [] }
        // Every year since 1950: three small requests, where the library's own year
        // list would be one more round trip for little saving.
        let earlier = Array(1950..<thisYear)
        let monthDay = String(format: "-%02d-%02d", month, day)
        // One date per year, OR'd with Plex's push/pop groups, 25 years a request.
        var found: [PlexMetadata] = []
        for batch in stride(from: 0, to: earlier.count, by: 25).map({ Array(earlier[$0..<min($0 + 25, earlier.count)]) }) {
            let clauses = batch.map { year in
                "push=1&originallyAvailableAt%3E=\(year)\(monthDay)&originallyAvailableAt%3C=\(year)\(monthDay)&pop=1"
            }.joined(separator: "&or=1&")
            let key = "/library/sections/\(library.key)/all?type=9&sort=originallyAvailableAt:desc&\(clauses)"
            if let page = try? await network.getHubItems(serverURL: serverURL, authToken: token, hubKey: key, start: 0, count: 50) {
                found += page.items
            }
        }
        return found.uniqued().sorted { ($0.originallyAvailableAt ?? "") > ($1.originallyAvailableAt ?? "") }
    }

    // MARK: - Compilations

    /// Albums under Various Artists, or tagged as compilations.
    func compilationsPage(_ library: PlexLibrary, sort: LibrarySortOption, start: Int, size: Int)
        async throws -> (items: [PlexMetadata], totalSize: Int?) {
        let (serverURL, token) = try configuration()
        let key = "/library/sections/\(library.key)/all?type=9&sort=\(sort.apiParameter)"
            + "&push=1&artist.title=Various%20Artists&pop=1&or=1&push=1&subformat=Compilation&pop=1"
        return try await network.getHubItems(serverURL: serverURL, authToken: token, hubKey: key, start: start, count: size)
    }

    // MARK: - Downloaded

    /// The songs kept on this Mac that belong to this library, most recently
    /// played first. A file is matched to its track by rating key and part, so a
    /// file from another server never stands in for a song here.
    func downloadedTracks(_ library: PlexLibrary) async -> [PlexMetadata] {
        let kept = await MacMusicCache.shared.keptTracks()
        guard !kept.isEmpty, let (serverURL, token) = try? configuration() else { return [] }
        var tracks: [String: PlexMetadata] = [:]
        for start in stride(from: 0, to: kept.count, by: 100) {
            let keys = kept[start..<min(start + 100, kept.count)].map(\.ratingKey).joined(separator: ",")
            let page = (try? await network.getHubItems(serverURL: serverURL, authToken: token,
                                                       hubKey: "/library/metadata/\(keys)", start: 0, count: 100).items) ?? []
            for track in page { if let key = track.ratingKey { tracks[key] = track } }
        }
        return kept.compactMap { file in
            guard let track = tracks[file.ratingKey], track.type == "track",
                  (track.librarySectionID.map(String.init) ?? library.key) == library.key,
                  track.Media?.first?.Part?.first?.id == file.partID else { return nil }
            return track
        }
    }
}
