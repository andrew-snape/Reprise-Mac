// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

// MARK: - Waveform

/// Now Playing's seek bar drawn as the track's loudness over time, from Plex's
/// analysis. Falls back to the plain slider until (or unless) Plex has one.
struct MacMusicWaveformScrubber: View {
    @Environment(MacMusicPlayback.self) private var music
    @Environment(MacPlexSession.self) private var plex
    @State private var shape: [Double]?
    @State private var shapeKey: String?
    @State private var dragging: Double?

    private static let samples = 160

    var body: some View {
        let track = music.current?.track
        Group {
            if let shape, shapeKey == track?.ratingKey {
                waveform(shape)
            } else {
                MacMusicScrubber()
            }
        }
        .task(id: track?.ratingKey) {
            guard let track else { return }
            let found = await plex.loudnessShape(of: track, samples: Self.samples)
            guard !Task.isCancelled else { return }
            shape = found
            shapeKey = track.ratingKey
        }
    }

    private func waveform(_ shape: [Double]) -> some View {
        let player = music.player
        let duration = max(player.duration, 0)
        let time = dragging ?? min(player.currentTime, duration)
        let fraction = duration > 0 ? time / duration : 0
        return HStack(spacing: 8) {
            Text(MacMusicScrubber.format(time)).frame(width: 44, alignment: .trailing)
            GeometryReader { proxy in
                Canvas { context, size in
                    let count = shape.count
                    let step = size.width / CGFloat(count)
                    let bar = max(1, step * 0.6)
                    for (index, value) in shape.enumerated() {
                        let height = max(2, CGFloat(value) * size.height)
                        let x = CGFloat(index) * step + (step - bar) / 2
                        let rect = CGRect(x: x, y: (size.height - height) / 2, width: bar, height: height)
                        let played = (CGFloat(index) + 0.5) / CGFloat(count) <= fraction
                        context.fill(Path(roundedRect: rect, cornerRadius: bar / 2),
                                     with: .color(.white.opacity(played ? 0.95 : 0.28)))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            dragging = min(max(value.location.x / proxy.size.width, 0), 1) * duration
                        }
                        .onEnded { _ in
                            if let target = dragging { music.seek(to: target) }
                            dragging = nil
                        }
                )
            }
            .frame(height: 34)
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue(MacMusicScrubber.format(time))
            .accessibilityAdjustableAction { direction in
                let delta: TimeInterval = direction == .increment ? 10 : -10
                music.seek(to: min(max(player.currentTime + delta, 0), duration))
            }
            Text("-" + MacMusicScrubber.format(max(duration - time, 0))).frame(width: 44, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

// MARK: - Lyrics

/// The playing track's words. Timed lyrics follow the song, the sung line
/// brightest; clicking a line plays from it.
struct MacMusicLyricsView: View {
    let lyrics: MusicLyrics
    @Environment(MacMusicPlayback.self) private var music

    var body: some View {
        let playing = lyrics.lineIndex(at: music.player.currentTime + 0.2)
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: lyrics.isSynced ? 14 : 4) {
                    ForEach(lyrics.lines) { line in
                        lineView(line, isPlaying: line.id == playing, isPast: playing.map { line.id < $0 } ?? false)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onChange(of: playing) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.4)) { reader.scrollTo(index, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: MusicLyrics.Line, isPlaying: Bool, isPast: Bool) -> some View {
        if lyrics.isSynced {
            Button {
                if let time = line.time { music.seek(to: time) }
            } label: {
                Text(line.text.isEmpty ? "♪" : line.text)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white.opacity(isPlaying ? 1 : (isPast ? 0.35 : 0.5)))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.25), value: isPlaying)
        } else {
            Text(line.text.isEmpty ? " " : line.text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
        }
    }
}

/// Up Next, or the lyrics when the track has some.
struct MacMusicSidePane: View {
    enum Pane: String, CaseIterable, Identifiable {
        case queue = "Up Next", lyrics = "Lyrics"
        var id: String { rawValue }
    }

    @Environment(MacMusicPlayback.self) private var music
    @Environment(MacPlexSession.self) private var plex
    @State private var pane: Pane = .queue
    @State private var lyrics: MusicLyrics?

    var body: some View {
        VStack(spacing: 0) {
            if lyrics != nil {
                Picker("Show", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 56)
            }
            if pane == .lyrics, let lyrics {
                MacMusicLyricsView(lyrics: lyrics)
            } else {
                MacMusicQueueList(topInset: lyrics == nil ? 60 : 16)
            }
        }
        .task(id: music.current?.track.ratingKey) {
            guard let track = music.current?.track else {
                lyrics = nil
                return
            }
            let found = await plex.lyrics(for: track)
            guard !Task.isCancelled else { return }
            lyrics = found
        }
    }
}

// MARK: - Backdrop colours

/// Plex's UltraBlur colours for a cover as a soft four-corner gradient.
struct MacUltraBlurGradient: View {
    /// Top left, top right, bottom right, bottom left, as Plex sends them.
    let colors: [Color]

    var body: some View {
        MeshGradient(
            width: 2, height: 2,
            points: [[0, 0], [1, 0], [0, 1], [1, 1]],
            colors: [colors[0], colors[1], colors[3], colors[2]]
        )
    }
}

// MARK: - History

/// Every play of this profile's in the library, newest first, by day.
struct MacMusicHistoryList: View {
    let library: PlexLibrary
    @Environment(MacPlexSession.self) private var plex
    @Environment(MacMusicPlayback.self) private var music
    @State private var entries: [PlexHistoryEntry] = []
    @State private var total: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var loaded = false

    private static let pageSize = 100

    private struct Day: Identifiable {
        let id: Date
        let entries: [PlexHistoryEntry]
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(entry.viewedAt ?? 0)))
        }
        return grouped.keys.sorted(by: >).map { Day(id: $0, entries: grouped[$0] ?? []) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if entries.isEmpty, let error {
                MacPlexErrorView(title: "Couldn't Load History", message: error) { await reload() }
                    .frame(maxWidth: .infinity)
            } else if entries.isEmpty, loaded {
                ContentUnavailableView("No Plays Yet", systemImage: "clock",
                                       description: Text("Songs you play from this library appear here."))
                    .frame(maxWidth: .infinity)
            }
            ForEach(days) { day in
                Text(Self.dayTitle(day.id))
                    .font(.headline)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                ForEach(day.entries) { entry in
                    row(entry)
                        .onAppear { if entry.id == entries.last?.id { loadMore() } }
                }
            }
        }
        .padding(.horizontal, MacTile.margin)
        .task(id: "\(library.key)|\(plex.sessionGeneration)") { await reload() }
    }

    private func row(_ entry: PlexHistoryEntry) -> some View {
        let item = entry.asMetadata
        return HStack(spacing: 12) {
            MacMusicArtwork(item: item, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? "").lineLimit(1)
                Text([entry.grandparentTitle, entry.parentTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let viewedAt = entry.viewedAt {
                Text(Date(timeIntervalSince1970: TimeInterval(viewedAt)), style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard item.type == "track" else { return }
            MacMusicRecents.shared.record(item)
            music.play([item])
        }
        .contextMenu { MacMusicItemMenu(item: item) }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide)
                                      : .dateTime.day().month(.wide).year())
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await plex.listeningHistory(library, start: 0, size: Self.pageSize)
            entries = page.entries.filter { $0.type == "track" }
            fetched = page.entries.count
            total = page.total
            error = nil
        } catch let error where isCancellationError(error) {
            return
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func loadMore() {
        guard !isLoading, let total, offset < total else { return }
        isLoading = true
        let start = offset
        Task {
            defer { isLoading = false }
            guard let page = try? await plex.listeningHistory(library, start: start, size: Self.pageSize) else { return }
            fetched += page.entries.count
            let known = Set(entries.map(\.id))
            entries += page.entries.filter { $0.type == "track" && !known.contains($0.id) }
            if page.entries.isEmpty { self.total = start }
        }
    }

    /// Rows fetched so far, tracks or not, for the next page's start.
    @State private var fetched = 0
    private var offset: Int { fetched }
}

private extension PlexHistoryEntry {
    /// Enough of the track to draw it and play it; playing fetches the rest.
    var asMetadata: PlexMetadata {
        PlexMetadata(ratingKey: ratingKey, key: ratingKey.map { "/library/metadata/\($0)" }, type: type, title: title,
                     year: nil, thumb: thumb, parentRatingKey: nil, parentTitle: parentTitle, parentThumb: parentThumb,
                     grandparentRatingKey: nil, grandparentTitle: grandparentTitle, grandparentThumb: grandparentThumb)
    }
}
