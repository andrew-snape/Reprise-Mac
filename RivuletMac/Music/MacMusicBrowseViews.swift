// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

// MARK: - Colour

/// The one source of colour for the music pages: Plex's four UltraBlur colours
/// for the item's cover as a soft gradient, else the cover's single tint, else
/// nothing. Now Playing, the bar, the library page and the artist and album
/// heroes all take their wash from here, so they always agree.
struct MacMusicWash: View {
    let item: PlexMetadata?
    /// Fades to clear toward the bottom, for the top of a page.
    var fadesOut = false
    @Environment(MacPlexSession.self) private var plex
    @State private var colors: [Color]?
    @State private var tint: Color?
    @State private var loadedKey: String?

    /// The art, not the item: songs of one album share a wash, so it never blinks between them.
    private var key: String? { item?.squareArtPath }

    var body: some View {
        ZStack {
            if let colors, loadedKey == key {
                MacUltraBlurGradient(colors: colors)
            } else if let tint, loadedKey == key {
                tint
            }
        }
        .mask {
            if fadesOut {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.6), location: 0.45),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Rectangle()
            }
        }
        .animation(.easeInOut(duration: 0.6), value: loadedKey)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: key) {
            guard let item, let key else {
                colors = nil
                tint = nil
                loadedKey = nil
                return
            }
            async let blur = plex.ultraBlurColors(of: item)
            async let average = plex.artworkTint(of: item)
            let (found, single) = await (blur, average)
            guard !Task.isCancelled else { return }
            colors = found
            tint = single
            loadedKey = key
        }
    }
}

// MARK: - Mixes

/// A mix as a card: the artist's picture under the mix's name, the artists it
/// draws on beneath, on the picture's own colours. Clicking plays it.
struct MacMusicMixTile: View {
    static let width: CGFloat = 250

    let mix: MacMusicMix
    let sectionKey: String
    var width: CGFloat = MacMusicMixTile.width
    @Environment(MacPlexSession.self) private var plex
    @Environment(MacMusicPlayback.self) private var music
    @Environment(\.plexActions) private var actions
    @Environment(\.displayScale) private var displayScale
    @State private var isStarting = false

    var body: some View {
        let pixels = max(1, Int((width * displayScale / 120).rounded(.up))) * 120
        Button(action: start) {
            VStack(alignment: .leading, spacing: 0) {
                MacPlexImage(url: plex.imageURL(path: mix.artist.thumb, width: pixels, height: pixels))
                    .frame(width: width, height: width * 0.62)
                    .overlay(alignment: .bottomLeading) {
                        Text(mix.title)
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 6)
                            .lineLimit(1)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    }
                    .overlay {
                        if isStarting { ProgressView().controlSize(.small) }
                    }
                Text(mix.caption)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2, reservesSpace: true)
                    .padding(12)
                    .frame(width: width, alignment: .leading)
                    .background {
                        ZStack {
                            MacTheme.surface
                            MacMusicWash(item: mix.artist).opacity(0.75)
                            Color.black.opacity(0.2)
                        }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: MacTheme.cardCorner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: MacTheme.cardCorner, style: .continuous))
            .macCardHover()
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .help("Play \(mix.title)")
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: start)
            Button("Go to Artist", systemImage: "music.mic") { actions.open(mix.artist) }
        }
    }

    private func start() {
        isStarting = true
        Task {
            defer { isStarting = false }
            let tracks = await plex.tracks(of: mix, sectionKey: sectionKey)
            guard !tracks.isEmpty else { return }
            MacMusicRecents.shared.record(mix.artist)
            music.startMix(tracks)
        }
    }
}
