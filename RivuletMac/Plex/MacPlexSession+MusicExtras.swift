// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Lyrics, loudness, colours, history, sonic paths and play queues from Plex,
/// each held for the session by rating key (never by URL: URLs carry the token).
@MainActor
final class MacMusicExtrasCache {
    static let shared = MacMusicExtrasCache()
    var lyrics: [String: MusicLyrics] = [:]
    var levels: [String: [Double]] = [:]
    var colors: [String: [Color]] = [:]
    /// Asked and found nothing, so not asked again this session.
    var misses: Set<String> = []

    func clear() {
        lyrics = [:]
        levels = [:]
        colors = [:]
        misses = []
    }
}

extension MacPlexSession {
    private var extras: MacMusicExtrasCache { .shared }

    /// The track's lyrics, when its server has any. `track` needs full metadata
    /// (the lyric stream is only listed there), as a playing source has.
    func lyrics(for track: PlexMetadata) async -> MusicLyrics? {
        guard let key = track.ratingKey else { return nil }
        let cacheKey = "lyrics|\(key)"
        if let hit = extras.lyrics[cacheKey] { return hit }
        guard !extras.misses.contains(cacheKey), let streamKey = track.lyricStream?.key,
              let (serverURL, token) = try? configuration() else { return nil }
        do {
            let text = try await network.getLyrics(serverURL: serverURL, authToken: token, streamKey: streamKey)
            guard let lyrics = MusicLyrics(text: text) else {
                extras.misses.insert(cacheKey)
                return nil
            }
            extras.lyrics[cacheKey] = lyrics
            return lyrics
        } catch {
            if !isCancellationError(error) { extras.misses.insert(cacheKey) }
            return nil
        }
    }

    /// The track's loudness across its length, scaled 0...1 (quietest to loudest
    /// in this track), `samples` values. Nil before Plex has analysed it.
    func loudnessShape(of track: PlexMetadata, samples: Int) async -> [Double]? {
        guard let key = track.ratingKey, let stream = track.audioStream?._id else { return nil }
        let cacheKey = "levels|\(key)|\(samples)"
        if let hit = extras.levels[cacheKey] { return hit }
        guard !extras.misses.contains(cacheKey), let (serverURL, token) = try? configuration() else { return nil }
        guard let levels = try? await network.getLoudnessLevels(serverURL: serverURL, authToken: token,
                                                                 streamID: stream, samples: samples),
              levels.count > 8 else {
            extras.misses.insert(cacheKey)
            return nil
        }
        // Silence reads as a very low dB; a 40 dB window below the loudest point
        // keeps quiet passages visible without flattening the loud ones.
        let top = levels.max() ?? 0
        let floor = top - 40
        let shape = levels.map { min(1, max(0, ($0 - floor) / 40)) }
        extras.levels[cacheKey] = shape
        return shape
    }

    /// Plex's four UltraBlur colours for the item's cover: top left, top right,
    /// bottom right, bottom left.
    func ultraBlurColors(of item: PlexMetadata) async -> [Color]? {
        guard let path = item.squareArtPath, let key = item.ratingKey else { return nil }
        let cacheKey = "\(key)|\(path)"
        if let hit = extras.colors[cacheKey] { return hit }
        guard !extras.misses.contains(cacheKey), let (serverURL, token) = try? configuration() else { return nil }
        let hex = (try? await network.getUltraBlurColors(serverURL: serverURL, authToken: token, path: path)) ?? []
        let colors = hex.compactMap(Color.init(plexHex:))
        guard colors.count == 4 else {
            extras.misses.insert(cacheKey)
            return nil
        }
        extras.colors[cacheKey] = colors
        return colors
    }

    /// This profile's plays in a music library, newest first.
    func listeningHistory(_ library: PlexLibrary, start: Int, size: Int) async throws -> (entries: [PlexHistoryEntry], total: Int?) {
        let (serverURL, token) = try configuration()
        return try await network.getListeningHistory(serverURL: serverURL, authToken: token, sectionID: library.key,
                                                     accountID: historyAccountID, start: start, size: size)
    }

    /// The server's own number for this profile. The owner is always 1 on their
    /// server; a Home member keeps their plex.tv ID. On someone else's server
    /// Plex shows only the signed-in account's plays, so no filter is needed.
    private var historyAccountID: Int? {
        guard PlexAuthManager.shared.selectedServer?.owned ?? true else { return nil }
        let profiles = PlexUserProfileManager.shared
        guard let user = profiles.selectedUser, !profiles.isAdminUser else { return 1 }
        return user.id
    }

    /// Tracks leading from `start` to `end`, close in sound all the way.
    func sonicPath(from start: PlexMetadata, to end: PlexMetadata) async -> [PlexMetadata] {
        guard let startKey = start.ratingKey, let endKey = end.ratingKey,
              let section = (end.librarySectionID ?? start.librarySectionID).map(String.init),
              let (serverURL, token) = try? configuration() else { return [] }
        return (try? await network.getSonicPath(serverURL: serverURL, authToken: token, sectionID: section,
                                                startKey: startKey, endKey: endKey)) ?? []
    }

    /// A server play queue mirroring `ratingKeys`, so Plex and its other apps
    /// see what is queued here.
    func createPlayQueue(ratingKeys: [String], selectedKey: String) async -> PlexPlayQueue? {
        guard let machine = PlexAuthManager.shared.selectedServer?.clientIdentifier,
              let (serverURL, token) = try? configuration() else { return nil }
        return try? await network.createPlayQueue(serverURL: serverURL, authToken: token, machineIdentifier: machine,
                                                  ratingKeys: ratingKeys, selectedKey: selectedKey)
    }
}

extension Color {
    /// "9a3936" (Plex's UltraBlur form) or "#9a3936".
    init?(plexHex: String) {
        let hex = plexHex.hasPrefix("#") ? String(plexHex.dropFirst()) : plexHex
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}
