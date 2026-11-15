// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The music queue as kept between launches, with whose it is.
nonisolated struct MacMusicSavedQueue: Codable, Sendable {
    /// The server and profile it was built on; another's never restores it.
    var owner: String
    var queue: MusicQueue.Saved
    /// "similar", or "library:<key>", while radio was adding to it.
    var radio: String?
}

/// Keeps the queue in Application Support, so quitting does not lose it.
/// Titles and rating keys only: no address and no token.
nonisolated enum MacMusicQueueStore {
    /// Seconds into the saved queue's first track.
    static let positionKey = "musicQueuePosition"

    private static var file: URL? {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return folder.appending(path: "MusicQueue.json")
    }

    static func write(_ saved: MacMusicSavedQueue) {
        guard let file, let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func read() -> MacMusicSavedQueue? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(MacMusicSavedQueue.self, from: data)
    }

    static func clear() {
        if let file { try? FileManager.default.removeItem(at: file) }
        UserDefaults.standard.removeObject(forKey: positionKey)
    }
}
