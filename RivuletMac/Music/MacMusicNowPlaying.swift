// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

// MARK: - Bar

/// The player floating over the bottom of the page while music is queued, as
/// Apple Music's, in one row: the cover flush to the capsule's edge, title, artist and album, the transport,
/// the waveform, Favourite and Dislike, and volume. The cover and title open Now
/// Playing; the artist and album go to their pages. A narrow window drops the
/// volume slider.
struct MacMusicBar: View {
    /// The bottom bar's height, shared by the radio bar so switching never jumps.
    static let height: CGFloat = 70
    /// How far the bar and its margins reach up from the bottom of the page, which
    /// every scroll view keeps clear so its last row can scroll out from under the bar.
    static let reservedHeight: CGFloat = height + 2 * floatingMargin
    static let floatingMargin: CGFloat = 12

    @Environment(MacMusicPlayback.self) private var music
    @Environment(\.plexActions) private var actions
    @AppStorage(MacAirPlayRoute.fromPlayerKey) private var airPlayFromPlayer = false
    @State private var width: CGFloat = 1200

    var body: some View {
        if let track = music.track {
            HStack(spacing: 14) {
                Button { music.isNowPlayingShown = true } label: {
                    MacMusicArtwork(item: track, size: Self.height, cornerRadius: 0)
                }
                .buttonStyle(.plain)
                .help("Show Now Playing")

                info(track)
                    .frame(width: width >= 1100 ? 230 : 180, alignment: .leading)

                MacMusicTransport(size: .small)

                MacMusicWaveformScrubber(height: 26, played: .accentColor,
                                         unplayed: Color(nsColor: .tertiaryLabelColor))
                    .frame(minWidth: 140, maxWidth: .infinity)

                HStack(spacing: 12) {
                    MacMusicLoveButtons(item: track)
                    MacMusicVolume(showsSlider: width >= 1020).frame(width: width >= 1020 ? 120 : 18)
                    MacAirPlayButton(player: airPlayFromPlayer ? music.player.airPlayPlayer : nil,
                                     tint: .secondaryLabelColor)
                        .frame(width: 22, height: 22)
                        .help("AirPlay")
                    Button { music.isNowPlayingShown = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Queue")
                    .help("Queue")
                    Menu {
                        menu(for: track)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More")
                    .help("More")
                }
                .foregroundStyle(.secondary)
            }
            .padding(.trailing, 14)
            .frame(height: Self.height)
            // A faint wash of the cover's colours in the glass.
            .background { MacMusicWash(item: track).opacity(0.22) }
            .macFloatingBar()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contextMenu { menu(for: track) }
        }
    }

    private func info(_ track: PlexMetadata) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { music.isNowPlayingShown = true } label: {
                Text(track.displayTitle).font(.callout.weight(.semibold))
            }
            .help("Show Now Playing")
            if let problem = music.problem {
                Text(problem).foregroundStyle(.orange)
            } else {
                if let artist = track.trackArtist {
                    Button(artist) { if let stub = track.artistStub { actions.open(stub) } }
                        .help("Go to Artist")
                }
                if let album = track.parentTitle {
                    Button(album) { if let stub = track.albumStub { actions.open(stub) } }
                        .foregroundStyle(.tertiary)
                        .help("Go to Album")
                }
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The playing song's own actions. Not `MacMusicItemMenu`: its Play would
    /// replace the queue with this one song.
    @ViewBuilder
    private func menu(for track: PlexMetadata) -> some View {
        Button("Show Now Playing", systemImage: "music.note") { music.isNowPlayingShown = true }
        Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { music.perform(.radio, on: track) }
        Section {
            MacMusicLoveMenuItems(item: track)
            MacMusicRatingMenu(item: track)
        }
        Section {
            if let album = track.albumStub {
                Button("Go to Album", systemImage: "square.stack") { actions.open(album) }
            }
            if let artist = track.artistStub {
                Button("Go to Artist", systemImage: "music.mic") { actions.open(artist) }
            }
        }
        Button("Stop", systemImage: "stop.fill") { music.stop() }
    }
}

// MARK: - Floating

extension View {
    /// A bottom bar as a floating glass capsule, as Apple Music's player.
    func macFloatingBar() -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return self
            // Glass alone lets the page's artwork show through the titles; the bar
            // material under it keeps them legible, as Apple Music's player is.
            .background(.bar)
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

// MARK: - Controls

/// Shuffle, Previous, Play/Pause, Next and Repeat.
struct MacMusicTransport: View {
    enum Size { case small, large }
    let size: Size
    @Environment(MacMusicPlayback.self) private var music

    private var repeatSymbol: String { music.queue.repeatMode == .one ? "repeat.1" : "repeat" }

    var body: some View {
        let large = size == .large
        HStack(spacing: large ? 34 : 18) {
            Button { music.setShuffled(!music.queue.isShuffled) } label: {
                Image(systemName: "shuffle")
            }
            .foregroundStyle(music.queue.isShuffled ? Color.accentColor : .secondary)
            .accessibilityLabel(music.queue.isShuffled ? "Shuffle Off" : "Shuffle")
            .help(music.queue.isShuffled ? "Shuffle Off" : "Shuffle")

            Button { music.skipToPrevious() } label: {
                Image(systemName: "backward.fill")
            }
            .accessibilityLabel("Previous")
            .help("Previous")

            Button { music.togglePlayPause() } label: {
                if large {
                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34))
                        .frame(width: 44)
                } else {
                    // The bar's Play sits in a disc, as the button to find.
                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(.quaternary, in: Circle())
                        .contentShape(Circle())
                }
            }
            .accessibilityLabel(music.isPlaying ? "Pause" : "Play")
            .help(music.isPlaying ? "Pause" : "Play")

            Button { music.skipToNext() } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(!music.queue.hasNext)
            .accessibilityLabel("Next")
            .help("Next")

            Button { music.cycleRepeat() } label: {
                Image(systemName: repeatSymbol)
            }
            .foregroundStyle(music.queue.repeatMode == .off ? .secondary : Color.accentColor)
            .accessibilityLabel(music.queue.repeatMode == .off ? "Repeat" : (music.queue.repeatMode == .all ? "Repeat One" : "Repeat Off"))
            .help(music.queue.repeatMode == .off ? "Repeat" : (music.queue.repeatMode == .all ? "Repeat One" : "Repeat Off"))
        }
        .font(large ? .title2 : .body)
        .buttonStyle(.borderless)
    }
}

/// Elapsed and remaining time around a seek bar. Dragging previews the time;
/// letting go seeks.
struct MacMusicScrubber: View {
    var showsTimes = true
    @Environment(MacMusicPlayback.self) private var music
    @State private var dragging: Double?

    var body: some View {
        let player = music.player
        let duration = max(player.duration, 0)
        let time = dragging ?? min(player.currentTime, duration)
        HStack(spacing: 8) {
            Text(Self.format(time)).frame(width: 44, alignment: .trailing)
            Slider(
                value: Binding(get: { time }, set: { dragging = $0 }),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = dragging {
                        music.seek(to: target)
                        dragging = nil
                    }
                }
            )
            .controlSize(.small)
            .disabled(duration <= 0)
            Text("-" + Self.format(max(duration - time, 0))).frame(width: 44, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct MacMusicVolume: View {
    var showsSlider = true
    @Environment(MacMusicPlayback.self) private var music

    var body: some View {
        let player = music.player
        HStack(spacing: 6) {
            Button { player.setMuted(!player.isMuted) } label: {
                Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
            .help(player.isMuted ? "Unmute" : "Mute")
            if showsSlider {
                Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                    .controlSize(.mini)
            }
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Now Playing

/// The whole window for the track playing: its artwork over its own colours,
/// the controls beneath, and the queue beside them. Everything scales with the
/// window, so nothing is cut off in a small one.
struct MacMusicNowPlayingView: View {
    @Environment(MacMusicPlayback.self) private var music
    @Environment(\.plexActions) private var actions

    /// Room for the title bar's buttons, which sit over this view.
    private static let topInset: CGFloat = 52
    /// Title, scrubber, transport and volume under the artwork.
    private static let controlsHeight: CGFloat = 250
    private static let queueWidth: CGFloat = 340

    var body: some View {
        GeometryReader { proxy in
            let showsQueue = proxy.size.width >= 820
            let playerWidth = proxy.size.width - (showsQueue ? Self.queueWidth : 0)
            let artwork = max(140, min(
                proxy.size.height - Self.topInset - Self.controlsHeight - 40,
                playerWidth - 120,
                560
            ))
            ZStack {
                if let track = music.track {
                    MacMusicBackdrop(track: track)
                    HStack(spacing: 0) {
                        player(for: track, artwork: artwork)
                            .frame(width: playerWidth)
                        if showsQueue {
                            MacMusicSidePane()
                                .frame(width: Self.queueWidth)
                                .background(.black.opacity(0.18))
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .topLeading) { closeButton }
        }
        // Under the title bar too: the insets keep clear of its buttons.
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var closeButton: some View {
        Button { music.isNowPlayingShown = false } label: {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close Now Playing")
        .help("Close Now Playing")
        .padding(.leading, 18)
        .padding(.top, Self.topInset)
    }

    private func player(for track: PlexMetadata, artwork: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: Self.topInset)
            MacMusicArtwork(item: track, size: artwork)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .id(track.ratingKey)
                .transition(.opacity)
            VStack(spacing: 18) {
                VStack(spacing: 3) {
                    Text(track.displayTitle)
                        .font(.title2.bold())
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Button(track.trackArtist ?? "") {
                            if let artist = track.artistStub { open(artist) }
                        }
                        if let album = track.parentTitle {
                            Text("·").foregroundStyle(.tertiary)
                            Button(album) {
                                if let stub = track.albumStub { open(stub) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .multilineTextAlignment(.center)
                VStack(spacing: 4) {
                    HStack(spacing: 18) {
                        MacMusicLoveButtons(item: track, spacing: 18)
                        MacMusicStars(item: track)
                    }
                    if let history = track.historyLine {
                        Text(history).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                MacMusicWaveformScrubber()
                    .tint(.white)
                MacMusicTransport(size: .large)
                HStack {
                    HStack(spacing: 8) {
                        if let quality = formatQuality { MacMusicQualityBadge(quality: quality) }
                        Text(formatDetail ?? "")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    MacMusicVolume().frame(width: 150)
                }
            }
            .frame(width: max(artwork, 380))
            .padding(.top, 28)
            Spacer(minLength: 28)
        }
        .padding(.horizontal, 40)
        .animation(.easeInOut(duration: 0.3), value: track.ratingKey)
    }

    /// "FLAC · 24-bit · 96 kHz" for a file played as it is.
    private var formatDetail: String? {
        guard let source = music.current else { return nil }
        if source.isTranscode { return "AAC · 320 kbps" }
        let stream = source.track.audioStream
        let codec = (source.track.Media?.first?.audioCodec ?? stream?.codec)?.uppercased()
        let rate = stream?.samplingRate.map { String(format: "%g kHz", Double($0) / 1000) }
        let depth = stream?.bitDepth.map { "\($0)-bit" }
        let parts = [codec, depth, rate].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let file = parts.joined(separator: " · ")
        guard let output = music.outputDescription else { return file }
        return "\(file) → \(output)"
    }

    /// Lossless or Hi-Res Lossless for a file played as it is.
    private var formatQuality: MusicAudioQuality? {
        guard let source = music.current, !source.isTranscode else { return nil }
        let stream = source.track.audioStream
        return MusicAudioQuality.classify(
            codec: source.track.Media?.first?.audioCodec ?? stream?.codec,
            bitDepth: stream?.bitDepth, samplingRate: stream?.samplingRate)
    }

    private func open(_ item: PlexMetadata) {
        music.isNowPlayingShown = false
        actions.open(item)
    }
}

/// The artwork blown up and blurred into a wash of its own colours, darkened
/// enough for white text.
private struct MacMusicBackdrop: View {
    let track: PlexMetadata
    @Environment(MacPlexSession.self) private var plex
    @State private var tint: Color?
    /// Plex's UltraBlur colours for the cover, when the server offers them.
    @State private var colors: [Color]?

    var body: some View {
        ZStack {
            if let colors {
                MacUltraBlurGradient(colors: colors)
            } else {
                tint ?? MacTheme.background
            }
            MacPlexImage(url: plex.imageURL(path: track.squareArtPath, width: 240, height: 240))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(1.4)
                .blur(radius: 90)
                .saturation(1.4)
                .opacity(colors == nil ? 0.7 : 0.35)
                .id(track.ratingKey)
                .transition(.opacity)
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.6), value: track.ratingKey)
        .animation(.easeInOut(duration: 0.6), value: tint)
        .animation(.easeInOut(duration: 0.6), value: colors)
        .task(id: track.ratingKey) {
            async let blur = plex.ultraBlurColors(of: track)
            async let color = plex.artworkTint(of: track)
            let (found, average) = await (blur, color)
            guard !Task.isCancelled else { return }
            colors = found
            tint = average
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Up Next: drag to reorder, double-click to play, the menu to remove.
struct MacMusicQueueList: View {
    var topInset: CGFloat = 60
    @Environment(MacMusicPlayback.self) private var music

    var body: some View {
        let upNext = music.queue.upNext
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next").font(.title3.bold())
                if music.radio != nil {
                    Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !upNext.isEmpty {
                    Text(upNext.count == 1 ? "1 song" : "\(upNext.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            if upNext.isEmpty {
                Text("Nothing else is queued.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(upNext) { entry in
                        MacMusicQueueRow(entry: entry)
                            .onTapGesture(count: 2) { music.jump(to: entry) }
                            .contextMenu {
                                Button("Play Now", systemImage: "play.fill") { music.jump(to: entry) }
                                Button("Remove from Queue", systemImage: "minus.circle") { music.remove(entry) }
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    }
                    .onMove { music.moveUpNext(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top, topInset)
        .padding(.bottom, 12)
    }
}

private struct MacMusicQueueRow: View {
    let entry: MusicQueue.Entry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            MacMusicArtwork(item: entry.track, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.track.displayTitle).lineLimit(1)
                Text(entry.track.trackArtist ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let time = entry.track.trackTime {
                Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovering ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
