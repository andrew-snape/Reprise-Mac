// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import Foundation
import MusicUnderstanding

/// Where a downloaded song's music actually starts and ends, and its last bars,
/// read on this Mac by Music Understanding. Crossfade uses them: the next song
/// comes in at its first sound rather than its leading silence, the fade ends
/// where the playing song goes quiet rather than on its trailing silence, and it
/// begins on a bar line.
nonisolated struct MusicCues: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    /// Bar lines in the song's last minute.
    let bars: [TimeInterval]

    /// When a fade of `fade` seconds should begin so it finishes at `end`, moved
    /// to the nearest bar line within half a fade. At least 0.3 s of fade is kept.
    func fadeStart(for fade: TimeInterval) -> TimeInterval {
        let plain = end - fade
        let near = bars.filter { abs($0 - plain) <= fade / 2 && end - $0 >= 0.3 }
        return near.min { abs($0 - plain) < abs($1 - plain) } ?? plain
    }
}

/// Analyses downloaded songs once each (held for the session, by file name, never a
/// URL), at utility priority. Only local files: a stream would have to be read twice.
actor MacMusicCues {
    static let shared = MacMusicCues()

    /// nil: analysed, and nothing usable came back.
    private var known: [String: MusicCues?] = [:]
    private var running: [String: Task<MusicCues?, Never>] = [:]

    func cues(for key: MacMusicCacheKey, file: URL) async -> MusicCues? {
        let name = key.fileName
        if let hit = known[name] { return hit }
        if let task = running[name] { return await task.value }
        let task = Task.detached(priority: .utility) { await Self.analyse(file) }
        running[name] = task
        let result = await task.value
        running[name] = nil
        known[name] = result
        return result
    }

    func clear() {
        running.values.forEach { $0.cancel() }
        running = [:]
        known = [:]
    }

    /// Sound is anything within 35 LU of the song's integrated loudness, so only
    /// near-silence is trimmed, never a quiet ending; silence reads as -inf, which never passes.
    private static func analyse(_ file: URL) async -> MusicCues? {
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0,
              let session = try? await MusicUnderstandingSession(asset: asset),
              let result = try? await session.analyze(for: [.loudness, .rhythm]),
              let loudness = result.loudness else { return nil }
        let integrated = loudness.integrated.value
        guard integrated.isFinite else { return nil }
        let threshold = integrated - 35
        let audible = loudness.momentary
            .filter { $0.value.isFinite && $0.value > threshold }
            .map(\.time.seconds)
            .filter(\.isFinite)
        guard let first = audible.first, let last = audible.last, last > first else { return nil }
        // Only short real gaps: a song that starts or ends on sound keeps its whole
        // length, and a long silent stretch (before a hidden track) is left alone.
        let start = first > 0.4 && first < 10 ? max(first - 0.1, 0) : 0
        let end = duration - last > 0.8 && duration - last <= 12 ? min(last + 0.4, duration) : duration
        let bars = (result.rhythm?.bars ?? [])
            .map(\.seconds)
            .filter { $0.isFinite && $0 > end - 60 && $0 < end }
        return MusicCues(start: start, end: end, bars: bars)
    }
}
