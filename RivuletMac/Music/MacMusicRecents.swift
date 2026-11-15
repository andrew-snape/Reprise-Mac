// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Observation

/// What was chosen to play here, newest first: the album, artist, playlist or
/// song that was picked, not every track that then played. Plex's own
/// "recently played" lists tracks and albums only, whatever started them.
///
/// Kept in Application Support with the server and profile it belongs to, so
/// one profile never sees another's. Titles, rating keys and art paths only:
/// no address and no token. Plays started in another app are not in it.
@MainActor
@Observable
final class MacMusicRecents {
    static let shared = MacMusicRecents()

    private static let limit = 40
    private static let kinds: Set<String> = ["artist", "album", "track", "playlist"]

    private nonisolated struct Saved: Codable, Sendable {
        var owner: String
        var items: [PlexMetadata]
    }

    @ObservationIgnored private var loadedOwner: String?
    @ObservationIgnored private var stored: [PlexMetadata] = []
    /// Bumped on every change, so views reading `items` redraw.
    private var revision = 0

    private var owner: String {
        let server = PlexAuthManager.shared.savedServerName ?? ""
        let profile = PlexUserProfileManager.shared.selectedUserId.map(String.init) ?? ""
        return "\(server)|\(profile)"
    }

    private static var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "MusicRecents.json")
    }

    /// The current profile's list.
    var items: [PlexMetadata] {
        _ = revision
        loadIfNeeded()
        return stored
    }

    /// Puts `item` at the front. Anything but an artist, album, song or playlist is ignored.
    func record(_ item: PlexMetadata) {
        guard let key = item.ratingKey, Self.kinds.contains(item.type ?? "") else { return }
        loadIfNeeded()
        stored.removeAll { $0.ratingKey == key }
        stored.insert(item.forRecents, at: 0)
        if stored.count > Self.limit { stored.removeLast(stored.count - Self.limit) }
        revision += 1
        save()
    }

    /// Forgets everything, on sign-out.
    func clear() {
        stored = []
        loadedOwner = nil
        revision += 1
        if let file = Self.file { try? FileManager.default.removeItem(at: file) }
    }

    /// Reads the file once per server and profile; another owner's list is not shown.
    private func loadIfNeeded() {
        let owner = owner
        guard loadedOwner != owner else { return }
        loadedOwner = owner
        stored = []
        guard let file = Self.file, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.owner == owner else { return }
        stored = saved.items
    }

    private func save() {
        guard let file = Self.file else { return }
        let record = Saved(owner: owner, items: stored)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(record) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

private extension PlexMetadata {
    /// Just what a tile draws and a page or the player needs to start from.
    var forRecents: PlexMetadata {
        var slim = PlexMetadata(ratingKey: ratingKey, key: key, type: type, title: title, year: year, thumb: thumb,
                                parentRatingKey: parentRatingKey, parentTitle: parentTitle, parentThumb: parentThumb,
                                grandparentRatingKey: grandparentRatingKey, grandparentTitle: grandparentTitle,
                                grandparentThumb: grandparentThumb)
        slim.composite = composite
        slim.leafCount = leafCount
        slim.duration = duration
        slim.originalTitle = originalTitle
        return slim
    }
}
