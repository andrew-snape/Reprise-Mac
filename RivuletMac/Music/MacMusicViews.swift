// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

// MARK: - Actions

/// What a music tile or row offers.
enum MacMusicAction {
    case play, shuffle, playNext, addToQueue, radio
}

extension MacMusicPlayback {
    /// Plays, queues or starts radio from an artist, album, playlist or track.
    func perform(_ action: MacMusicAction, on item: PlexMetadata) {
        guard let plex else { return }
        if action == .play || action == .shuffle || action == .radio { MacMusicRecents.shared.record(item) }
        if action == .radio, item.type == "track" {
            startRadio(from: item)
            return
        }
        Task {
            guard let tracks = try? await plex.tracks(of: item), !tracks.isEmpty else { return }
            switch action {
            case .play: play(tracks, isAlbum: item.type == "album")
            case .shuffle: play(tracks, shuffled: true)
            case .playNext: playNext(tracks)
            case .addToQueue: addToQueue(tracks)
            case .radio: if let seed = tracks.randomElement() { startRadio(from: seed) }
            }
        }
    }
}

/// Right-click menu for any music item.
struct MacMusicItemMenu: View {
    let item: PlexMetadata
    @Environment(MacMusicPlayback.self) private var music
    @Environment(\.plexActions) private var actions

    var body: some View {
        Button("Play", systemImage: "play.fill") { music.perform(.play, on: item) }
        if item.type != "track" {
            Button("Shuffle", systemImage: "shuffle") { music.perform(.shuffle, on: item) }
        }
        Section {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { music.perform(.playNext, on: item) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { music.perform(.addToQueue, on: item) }
        }
        Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { music.perform(.radio, on: item) }
        if item.type == "track", let playing = music.track, playing.ratingKey != item.ratingKey {
            Button("Sonic Path to Here", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                music.playSonicPath(to: item)
            }
            .help("Up Next becomes songs that drift from what's playing to this one")
        }
        if item.type != "playlist" {
            Section {
                MacMusicLoveMenuItems(item: item)
                MacMusicRatingMenu(item: item)
            }
        }
        if item.type == "track" || item.type == "album" {
            Section {
                if let album = item.albumStub {
                    Button("Go to Album", systemImage: "square.stack") { actions.open(album) }
                }
                if let artist = item.artistStub {
                    Button("Go to Artist", systemImage: "music.mic") { actions.open(artist) }
                }
            }
        }
    }
}

// MARK: - Artwork

/// Square music art (round for an artist), at the size it draws.
struct MacMusicArtwork: View {
    let item: PlexMetadata
    let size: CGFloat
    /// Used when Plex has no art of its own.
    var fallbackURL: URL?
    /// Overrides the corner that follows the size (0 for square art).
    var cornerRadius: CGFloat?
    @Environment(MacPlexSession.self) private var plex
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let pixels = max(1, Int((size * displayScale / 120).rounded(.up))) * 120
        MacPlexImage(url: item.squareArtPath == nil ? fallbackURL : plex.imageURL(path: item.squareArtPath, width: pixels, height: pixels))
            .overlay {
                if item.squareArtPath == nil, fallbackURL == nil {
                    Image(systemName: item.type == "artist" ? "music.mic" : "music.note")
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(item.type == "artist"
                ? AnyShape(Circle())
                : AnyShape(RoundedRectangle(cornerRadius: cornerRadius ?? (size > 100 ? MacTheme.cardCorner : 6),
                                            style: .continuous)))
    }
}

// MARK: - Tiles

/// An artist, album or playlist in a grid or row.
struct MacMusicTile: View {
    let item: PlexMetadata
    var width: CGFloat = MacTile.poster

    private var caption: String? {
        switch item.type {
        case "album": [item.parentTitle, item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        case "playlist": item.leafCount.map { $0 == 1 ? "1 song" : "\($0) songs" }
        case "track": item.trackArtist
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: item.type == "artist" ? .center : .leading, spacing: 6) {
            MacMusicArtwork(item: item, size: width)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
            Text(item.displayTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: item.type == "artist" ? .center : .leading)
        .contentShape(Rectangle())
        .macCardHover()
    }
}

/// A tile that opens its page, or plays when it is a track.
struct MacMusicTileLink: View {
    let item: PlexMetadata
    var width: CGFloat = MacTile.poster
    @Environment(MacMusicPlayback.self) private var music

    var body: some View {
        Group {
            if item.type == "track" {
                Button {
                    MacMusicRecents.shared.record(item)
                    music.play([item])
                } label: { MacMusicTile(item: item, width: width) }
            } else {
                NavigationLink(value: item) { MacMusicTile(item: item, width: width) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { MacMusicItemMenu(item: item) }
    }
}

// MARK: - Library

/// A music library: mixes, Plex's own rows and On This Day, then artists,
/// albums, compilations, songs, favourites, playlists, downloads and history. The top of the
/// page takes on the colours of what is playing.
struct MacMusicLibraryView: View {
    let library: PlexLibrary
    @Environment(MacPlexSession.self) private var plex
    @Environment(MacMusicPlayback.self) private var music
    @AppStorage private var sortRaw: String
    @State private var kind: MacMusicKind = .artists
    @State private var hubs: [PlexHub] = []
    @State private var mixes: [MacMusicMix] = []
    @State private var onThisDay: [PlexMetadata] = []
    @State private var items: [PlexMetadata] = []
    @State private var favouriteArtists: [PlexMetadata] = []
    @State private var favouriteAlbums: [PlexMetadata] = []
    @State private var total: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedKey: String?

    private static let pageSize = 120

    init(library: PlexLibrary) {
        self.library = library
        _sortRaw = AppStorage(wrappedValue: LibrarySortOption.titleAsc.rawValue, "macLibrarySort.\(library.key)")
    }

    private var sorts: [(LibrarySortOption, String)] {
        kind == .albums || kind == .compilations
            ? [(.titleAsc, "Title"), (.addedAtDesc, "Date Added"), (.releaseDateDesc, "Release Date"),
               (.lastViewedAtDesc, "Last Played"), (.viewCountDesc, "Most Played")]
            : [(.titleAsc, "Title"), (.addedAtDesc, "Date Added"),
               (.lastViewedAtDesc, "Last Played"), (.viewCountDesc, "Most Played")]
    }

    private var sort: LibrarySortOption {
        let chosen = LibrarySortOption(rawValue: sortRaw) ?? .titleAsc
        return sorts.contains { $0.0 == chosen } ? chosen : .titleAsc
    }

    private var queryKey: String { "\(library.key)|\(kind.rawValue)|\(sort.rawValue)|\(plex.sessionGeneration)" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                let recents = MacMusicRecents.shared.items
                if !mixes.isEmpty {
                    MacShelfRow(items: mixes, base: MacMusicMixTile.width) {
                        Text("Mixes for You").font(.title2.bold())
                    } tile: { mix, width in
                        MacMusicMixTile(mix: mix, sectionKey: library.key, width: width)
                    }
                }
                if !recents.isEmpty {
                    MacShelfRow(items: recents) {
                        Text("Recently Played").font(.title2.bold())
                    } tile: { item, width in
                        MacMusicTileLink(item: item, width: width)
                    }
                }
                ForEach(recents.isEmpty ? hubs : hubs.filter { !$0.isRecentlyPlayed }) { hub in
                    MacShelfRow(items: hub.items) {
                        Text(hub.displayTitle).font(.title2.bold())
                    } tile: { item, width in
                        MacMusicTileLink(item: item, width: width)
                    }
                }
                if !onThisDay.isEmpty {
                    MacShelfRow(items: onThisDay) {
                        Text("On This Day").font(.title2.bold())
                    } tile: { item, width in
                        MacMusicTileLink(item: item, width: width)
                    }
                }
                // Segments while they fit; a narrow window gets a menu instead.
                ViewThatFits(in: .horizontal) {
                    kindPicker.pickerStyle(.segmented).fixedSize()
                    kindPicker.pickerStyle(.menu).fixedSize()
                }
                .labelsHidden()
                .padding(.horizontal, MacTile.margin)

                if items.isEmpty, let error {
                    MacPlexErrorView(title: "Couldn't Load Library", message: error) { await reload() }
                        .frame(maxWidth: .infinity)
                } else if kind == .history {
                    MacMusicHistoryList(library: library)
                } else if items.isEmpty, favouriteArtists.isEmpty, favouriteAlbums.isEmpty, !isLoading, loadedKey != nil {
                    if kind == .downloaded {
                        ContentUnavailableView("No Downloaded Songs", systemImage: "arrow.down.circle",
                                               description: Text("Songs you play are kept on this Mac as Settings > Music allows."))
                            .frame(maxWidth: .infinity)
                    } else if kind == .favourites {
                        ContentUnavailableView("No Favourites", systemImage: "star",
                                               description: Text("Songs, albums and artists rated four stars or more, here or in Plexamp, gather here."))
                            .frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("Nothing Here", systemImage: library.icon)
                            .frame(maxWidth: .infinity)
                    }
                } else if kind.isTracks {
                    if kind == .favourites { favouriteShelves }
                    trackRows
                } else {
                    MacMusicGrid(items: items, loadMore: loadMore)
                }
                if isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
            }
            .padding(.vertical, 20)
        }
        .background(alignment: .top) {
            MacMusicWash(item: music.track, fadesOut: true)
                .frame(height: 520)
                .opacity(0.55)
        }
        .navigationTitle(library.title)
        .toolbar {
            ToolbarItemGroup {
                Button("Library Radio", systemImage: "dot.radiowaves.left.and.right") {
                    music.startLibraryRadio(library)
                }
                .help("Shuffle the whole library, without end")
                if kind.isPaged {
                    Picker("Sort By", selection: $sortRaw) {
                        ForEach(sorts, id: \.0) { Text($0.1).tag($0.0.rawValue) }
                    }
                    .pickerStyle(.menu)
                    .help("Sort")
                }
            }
        }
        .task(id: "\(library.key)|\(plex.sessionGeneration)") {
            hubs = (try? await plex.musicHubs(library)) ?? []
            async let day = plex.onThisDay(library)
            async let made = plex.mixesForYou(library, recentlyPlayed: recentArtists)
            (onThisDay, mixes) = await (day, made)
        }
        .task(id: queryKey) {
            guard loadedKey != queryKey else { return }
            await reload()
        }
    }

    private func reload() async {
        let key = queryKey
        items = []
        favouriteArtists = []
        favouriteAlbums = []
        total = nil
        isLoading = true
        defer { if key == queryKey { isLoading = false } }
        guard kind != .history else {
            loadedKey = key
            return
        }
        do {
            if kind == .downloaded {
                let tracks = await plex.downloadedTracks(library)
                guard key == queryKey else { return }
                items = tracks
                total = tracks.count
            } else if kind == .playlists {
                let playlists = try await plex.audioPlaylists()
                guard key == queryKey else { return }
                items = playlists.uniqued()
                total = items.count
            } else {
                async let artists = kind == .favourites ? plex.favourites(library, type: 8) : []
                async let albums = kind == .favourites ? plex.favourites(library, type: 9) : []
                let page = try await plex.musicPage(library, kind: kind, sort: sort, start: 0, size: Self.pageSize)
                let (foundArtists, foundAlbums) = await (artists, albums)
                guard key == queryKey else { return }
                items = page.items.uniqued()
                total = page.totalSize
                favouriteArtists = foundArtists.uniqued()
                favouriteAlbums = foundAlbums.uniqued()
            }
            error = nil
            loadedKey = key
        } catch let error where isCancellationError(error) {
        } catch {
            guard key == queryKey else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadMore() {
        guard kind.isPaged, !isLoading, let total, items.count < total else { return }
        let key = queryKey
        isLoading = true
        Task {
            defer { isLoading = false }
            guard let page = try? await plex.musicPage(library, kind: kind, sort: sort, start: items.count, size: Self.pageSize),
                  key == queryKey else { return }
            items = (items + page.items).uniqued()
            self.total = page.items.isEmpty ? items.count : page.totalSize
        }
    }

    private var kindPicker: some View {
        Picker("Show", selection: $kind) {
            ForEach(MacMusicKind.allCases) { Text($0.title).tag($0) }
        }
    }

    /// The listed songs. Favourites drop one rated down this session at once,
    /// though Plex's list is not fetched again.
    private var shownTracks: [PlexMetadata] {
        kind == .favourites ? items.filter { MacMusicRatings.shared.isFavourite($0) } : items
    }

    /// Songs as rows; double-click or the row's Play plays from there on.
    private var trackRows: some View {
        let tracks = shownTracks
        return ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
            MacMusicTrackRow(track: track, number: offset + 1, showsArtwork: true) {
                MacMusicRecents.shared.record(track)
                music.play(tracks, from: offset)
            }
            .padding(.horizontal, MacTile.margin - 10)
            .onAppear { if offset == tracks.count - 1 { loadMore() } }
        }
    }

    /// Favourite artists and albums above the favourite songs.
    @ViewBuilder private var favouriteShelves: some View {
        let ratings = MacMusicRatings.shared
        let shelves = [("Artists", favouriteArtists.filter(ratings.isFavourite)),
                       ("Albums", favouriteAlbums.filter(ratings.isFavourite))]
        ForEach(shelves.filter { !$0.1.isEmpty }, id: \.0) { title, shelf in
            MacShelfRow(items: shelf) {
                Text(title).font(.title2.bold())
            } tile: { item, width in
                MacMusicTileLink(item: item, width: width)
            }
        }
        if !shownTracks.isEmpty, shelves.contains(where: { !$0.1.isEmpty }) {
            Text("Songs").font(.title2.bold()).padding(.horizontal, MacTile.margin)
        }
    }

    /// Artists played lately, here or anywhere Plex saw it, to seed the mixes.
    private var recentArtists: [PlexMetadata] {
        let local = MacMusicRecents.shared.items.compactMap { item in
            item.type == "artist" ? item : item.artistStub
        }
        let server = hubs.first { $0.isRecentlyPlayed }?.items ?? []
        return local + server
    }
}

private extension PlexHub {
    /// Plex's own recently played row, which the local list stands in for.
    var isRecentlyPlayed: Bool {
        let id = (hubIdentifier ?? "").lowercased()
        return id.contains("recent") && (id.contains("played") || id.contains("listen") || id.contains("viewed"))
            || title == "Recently Played"
    }
}

/// Square tiles for artists, albums and playlists.
struct MacMusicGrid: View {
    let items: [PlexMetadata]
    var loadMore: (() -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: MacTile.poster, maximum: MacTile.poster + 40),
                                     spacing: MacTile.gap, alignment: .top)],
                  spacing: 22) {
            ForEach(items) { item in
                MacMusicTileLink(item: item, width: MacTile.poster)
                    .onAppear {
                        if item.id == items.last?.id { loadMore?() }
                    }
            }
        }
        .padding(.horizontal, MacTile.margin)
    }
}

// MARK: - Artist

/// An artist: Play, Shuffle and Radio, the popular tracks, then the albums.
struct MacMusicArtistView: View {
    let artist: PlexMetadata
    @Environment(MacPlexSession.self) private var plex
    @State private var full: PlexMetadata?
    @State private var popular: [PlexMetadata] = []
    @State private var mostPlayed: [PlexMetadata] = []
    @State private var albums: [PlexMetadata] = []
    @State private var releaseGroups: [String: MusicReleaseGroup] = [:]
    @State private var similar: [PlexHub] = []
    @State private var fallbackSimilar: [PlexMetadata] = []
    @State private var tint: Color?
    @State private var online: MusicArtistInfo?
    @State private var error: String?
    @AppStorage(MusicInfoStore.enabledKey) private var onlineInfo = false

    private var shown: PlexMetadata { full ?? artist }

    private var chips: [String] {
        var styles = Array(((shown.Genre ?? []) + (shown.Style ?? [])).compactMap(\.tag).prefix(4))
        if shown.hasNoMusicStyles, let genres = online?.genres { styles = Array(genres.prefix(4)) }
        let country = shown.Country?.compactMap(\.tag) ?? []
        let moods = (shown.Mood ?? []).compactMap(\.tag).prefix(2)
        return styles + country + Array(moods)
    }

    /// The albums by release type, in the order record shops shelve them. Until
    /// the types are known, and when every album is a plain album, one group.
    private var albumSections: [(group: MusicReleaseGroup, albums: [PlexMetadata])] {
        let grouped = Dictionary(grouping: albums) { album in
            album.ratingKey.flatMap { releaseGroups[$0] } ?? .albums
        }
        return MusicReleaseGroup.allCases.compactMap { group in
            grouped[group].map { (group, $0) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                MacMusicHero(tint: tint, item: shown, backdrop: shown.art != nil ? plex.imageURL(path: shown.art, width: 1600, height: 900) : online?.backdropURL) {
                    HStack(alignment: .center, spacing: 24) {
                        MacMusicArtwork(item: shown, size: 180, fallbackURL: online?.imageURL)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(shown.displayTitle).font(.largeTitle.bold()).lineLimit(2)
                            MacMusicChips(texts: chips)
                            MacMusicRatingBadge(item: shown)
                            if let history = shown.historyLine {
                                Text(history).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 12) {
                                MacMusicPlayButtons(item: shown)
                                MacMusicLinksMenu(links: online?.links ?? [])
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }

                if let summary = shown.summary, !summary.isEmpty {
                    MacMusicBio(text: summary).padding(.horizontal, MacTile.margin)
                } else if let bio = online?.biography {
                    MacMusicBio(text: bio.text, sourceName: bio.source.displayName, sourceURL: bio.url)
                        .padding(.horizontal, MacTile.margin)
                }
                if !popular.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Popular").font(.title2.bold()).padding(.horizontal, MacTile.margin)
                        MacMusicTrackList(tracks: popular, showsArtwork: true, showsPopularity: true)
                    }
                }
                if !mostPlayed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Most Played").font(.title2.bold()).padding(.horizontal, MacTile.margin)
                        MacMusicTrackList(tracks: mostPlayed, showsArtwork: true, showsPlays: true)
                    }
                }
                if !albums.isEmpty {
                    ForEach(albumSections, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.group.title).font(.title2.bold()).padding(.horizontal, MacTile.margin)
                            MacMusicGrid(items: section.albums)
                        }
                    }
                } else if let error {
                    MacPlexErrorView(title: "Couldn't Load Artist", message: error) { await load() }
                        .frame(maxWidth: .infinity)
                }
                ForEach(similar) { hub in
                    MacShelfRow(items: hub.items) {
                        Text(hub.displayTitle).font(.title2.bold())
                    } tile: { item, width in
                        MacMusicTileLink(item: item, width: width)
                    }
                }
                if similar.isEmpty, !fallbackSimilar.isEmpty {
                    MacShelfRow(items: fallbackSimilar) {
                        Text("Similar Artists").font(.title2.bold())
                    } tile: { item, width in
                        MacMusicTileLink(item: item, width: width)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(shown.displayTitle)
        .task(id: "\(artist.ratingKey ?? "")|\(onlineInfo)") { await load() }
    }

    private func load() async {
        do {
            let loaded = try await plex.musicDetail(for: artist)
            guard !Task.isCancelled else { return }
            full = loaded
            let loadedAlbums = try await plex.albums(of: loaded)
            guard !Task.isCancelled else { return }
            albums = loadedAlbums
            error = nil
            if let section = loaded.librarySectionID {
                let tracks = Array(((try? await plex.popularTracks(of: loaded, sectionKey: String(section))) ?? []).prefix(5))
                guard !Task.isCancelled else { return }
                popular = tracks
                let played = await plex.mostPlayedTracks(of: loaded, sectionKey: String(section))
                guard !Task.isCancelled else { return }
                // One or two plays say little; a list of them is not a favourites list.
                mostPlayed = played.count >= 3 ? played : []
            }
            let groups = await plex.releaseGroups(of: loadedAlbums)
            guard !Task.isCancelled else { return }
            releaseGroups = groups
            let related = await plex.musicRelated(to: loaded, kind: "artist")
            guard !Task.isCancelled else { return }
            similar = related
            let names = (loaded.Similar ?? []).compactMap(\.tag)
            if related.isEmpty, !names.isEmpty, let section = loaded.librarySectionID {
                let found = await plex.libraryArtists(named: names, sectionKey: String(section))
                guard !Task.isCancelled else { return }
                fallbackSimilar = found
            }
            let color = await plex.artworkTint(of: loaded)
            guard !Task.isCancelled else { return }
            tint = color
            if onlineInfo {
                let info = await MusicInfoStore.shared.artistInfo(name: loaded.displayTitle, musicBrainzID: loaded.musicBrainzID)
                guard !Task.isCancelled else { return }
                online = info
            } else {
                online = nil
            }
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Play, Shuffle and a menu with the rest.
struct MacMusicPlayButtons: View {
    let item: PlexMetadata
    @Environment(MacMusicPlayback.self) private var music

    var body: some View {
        HStack(spacing: 10) {
            Button { music.perform(.play, on: item) } label: {
                Label("Play", systemImage: "play.fill").frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            Button { music.perform(.shuffle, on: item) } label: {
                Label("Shuffle", systemImage: "shuffle").frame(minWidth: 70)
            }
            .buttonStyle(.bordered)
            Button { music.perform(.radio, on: item) } label: {
                Label("Radio", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)
            .help("Play tracks like these, without end")
            Menu {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { music.perform(.playNext, on: item) }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { music.perform(.addToQueue, on: item) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .controlSize(.large)
    }
}

// MARK: - Album and playlist

/// An album or playlist: its art, Play and Shuffle, then the tracks.
struct MacMusicAlbumView: View {
    let item: PlexMetadata
    @Environment(MacPlexSession.self) private var plex
    @Environment(\.plexActions) private var actions
    @State private var full: PlexMetadata?
    @State private var tracks: [PlexMetadata] = []
    @State private var quality: MusicAudioQuality?
    @State private var related: [PlexHub] = []
    @State private var tint: Color?
    @State private var online: MusicAlbumInfo?
    @State private var error: String?
    @State private var isLoading = true
    @AppStorage(MusicInfoStore.enabledKey) private var onlineInfo = false

    private var shown: PlexMetadata { full ?? item }
    private var isPlaylist: Bool { item.type == "playlist" }

    private var chips: [String] {
        let minutes = tracks.compactMap(\.duration).reduce(0, +) / 60_000
        let count = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        let length = minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
        var genres = Array(((shown.Genre ?? []) + (shown.Style ?? [])).compactMap(\.tag).prefix(3))
        if shown.hasNoMusicStyles, let found = online?.genres { genres = Array(found.prefix(3)) }
        let moods = (shown.Mood ?? []).compactMap(\.tag).prefix(2)
        return [shown.year.map(String.init), tracks.isEmpty ? nil : count, minutes > 0 ? length : nil].compactMap { $0 }
            + Array(genres) + Array(moods)
    }

    private var review: PlexReview? {
        shown.Review?.first { !($0.text ?? "").isEmpty }
    }

    private var releaseLine: String? {
        let date = shown.originallyAvailableAt.flatMap(MacPlexInformationSection.formattedDate)
        let parts = [date.map { "Released \($0)" }, shown.studio].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MacMusicHero(tint: tint, item: shown) {
                    HStack(alignment: .bottom, spacing: 24) {
                        MacMusicArtwork(item: shown, size: 220, fallbackURL: online?.coverURL)
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isPlaylist ? "Playlist" : "Album")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Text(shown.displayTitle).font(.largeTitle.bold()).lineLimit(2)
                            if !isPlaylist, let artist = shown.artistStub {
                                Button(artist.displayTitle) { actions.open(artist) }
                                    .buttonStyle(.plain)
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                            }
                            MacMusicChips(texts: chips)
                            HStack(spacing: 12) {
                                if let quality { MacMusicQualityBadge(quality: quality) }
                                if !isPlaylist { MacMusicRatingBadge(item: shown) }
                            }
                            if !isPlaylist, let history = MacMusicHistory.line(album: shown, tracks: tracks) {
                                Text(history).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 12) {
                                MacMusicPlayButtons(item: shown)
                                MacMusicLinksMenu(links: online?.links ?? [])
                            }
                            .padding(.top, 6)
                        }
                    }
                    .padding(.bottom, 8)
                }

                if let error, tracks.isEmpty {
                    MacPlexErrorView(title: "Couldn't Load", message: error) { await load() }
                        .frame(maxWidth: .infinity)
                } else if isLoading, tracks.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    MacMusicTrackList(
                        tracks: tracks,
                        isAlbum: !isPlaylist,
                        showsArtwork: isPlaylist,
                        albumArtist: isPlaylist ? nil : shown.parentTitle,
                        showsPopularity: !isPlaylist,
                        container: shown
                    )
                }
                if let summary = shown.summary, !summary.isEmpty {
                    MacMusicBio(text: summary).padding(.horizontal, MacTile.margin)
                } else if let text = online?.summary {
                    MacMusicBio(text: text.text, sourceName: text.source.displayName, sourceURL: text.url)
                        .padding(.horizontal, MacTile.margin)
                }
                if let review, let text = review.text {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Review").font(.title2.bold())
                        MacMusicBio(text: text, sourceName: review.source ?? review.tag,
                                    sourceURL: review.link.flatMap(URL.init(string:)))
                    }
                    .padding(.horizontal, MacTile.margin)
                }
                if let releaseLine {
                    Text(releaseLine)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, MacTile.margin)
                }
                ForEach(related) { hub in
                    MacShelfRow(items: hub.items) {
                        Text(hub.displayTitle).font(.title2.bold())
                    } tile: { item, width in
                        MacMusicTileLink(item: item, width: width)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(shown.displayTitle)
        .task(id: "\(item.ratingKey ?? "")|\(onlineInfo)") { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let loadedTracks = plex.tracks(of: item)
            let detail = isPlaylist ? nil : try? await plex.musicDetail(for: item)
            let loaded = try await loadedTracks
            guard !Task.isCancelled else { return }
            if let detail { full = detail }
            tracks = loaded
            error = nil
            guard !isPlaylist else { return }
            let found = await plex.albumQuality(of: loaded)
            guard !Task.isCancelled else { return }
            quality = found
            let hubs = await plex.musicRelated(to: item, kind: "album")
            guard !Task.isCancelled else { return }
            related = hubs
            let color = await plex.artworkTint(of: detail ?? item)
            guard !Task.isCancelled else { return }
            tint = color
            let source = detail ?? item
            if onlineInfo {
                let info = await MusicInfoStore.shared.albumInfo(
                    title: source.displayTitle, artist: source.parentTitle ?? "", musicBrainzID: source.musicBrainzID)
                guard !Task.isCancelled else { return }
                online = info
            } else {
                online = nil
            }
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Tracks

/// Numbered tracks; an album with more than one disc gets a heading per disc.
/// Double-click a row, or its number, to play from there.
struct MacMusicTrackList: View {
    let tracks: [PlexMetadata]
    var isAlbum = false
    var showsArtwork = false
    /// Hidden on rows by the same artist.
    var albumArtist: String?
    var showsPopularity = false
    /// The listener's own play count on each row.
    var showsPlays = false
    /// The album or playlist the list is, remembered as what was played;
    /// without one the row's own song is.
    var container: PlexMetadata?
    @Environment(MacMusicPlayback.self) private var music

    /// Play counts on a log scale against the most played; nil with no counts.
    private func popularity(of track: PlexMetadata) -> Double? {
        guard showsPopularity,
              let top = tracks.compactMap(\.ratingCount).max(), top > 0 else { return nil }
        return log1p(Double(track.ratingCount ?? 0)) / log1p(Double(top))
    }

    private struct Row: Identifiable {
        let offset: Int
        let track: PlexMetadata
        var id: Int { offset }
    }

    private struct Disc: Identifiable {
        let number: Int
        let rows: [Row]
        var id: Int { number }
    }

    private var discs: [Disc] {
        let rows = tracks.enumerated().map { Row(offset: $0.offset, track: $0.element) }
        guard isAlbum else { return [Disc(number: 0, rows: rows)] }
        let grouped = Dictionary(grouping: rows) { $0.track.parentIndex ?? 1 }
        return grouped.keys.sorted().map { Disc(number: $0, rows: grouped[$0] ?? []) }
    }

    var body: some View {
        let discs = discs
        VStack(alignment: .leading, spacing: 0) {
            ForEach(discs) { disc in
                if discs.count > 1 {
                    Label("Disc \(disc.number)", systemImage: "opticaldisc")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .padding(.horizontal, MacTile.margin)
                }
                ForEach(disc.rows) { row in
                    MacMusicTrackRow(
                        track: row.track,
                        number: isAlbum ? row.track.index : row.offset + 1,
                        showsArtwork: showsArtwork,
                        showsArtist: row.track.trackArtist != albumArtist,
                        popularity: popularity(of: row.track),
                        showsPlays: showsPlays,
                        play: {
                            MacMusicRecents.shared.record(container ?? row.track)
                            music.play(tracks, from: row.offset, isAlbum: isAlbum)
                        }
                    )
                }
            }
        }
        .padding(.horizontal, MacTile.margin - 10)
    }
}

struct MacMusicTrackRow: View {
    let track: PlexMetadata
    let number: Int?
    var showsArtwork = false
    var showsArtist = true
    var popularity: Double?
    var showsPlays = false
    let play: () -> Void
    @Environment(MacMusicPlayback.self) private var music
    @State private var hovering = false

    /// The listener's stars on the track, when it has any.
    private var stars: Int { Int(MacMusicRatings.shared.stars(for: track) ?? 0) }

    private var isCurrent: Bool { music.track?.ratingKey != nil && music.track?.ratingKey == track.ratingKey }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if hovering {
                    Button(action: play) { Image(systemName: "play.fill") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play")
                        .help("Play")
                } else if isCurrent {
                    Image(systemName: music.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(.tint)
                } else if let number {
                    Text("\(number)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 26)
            if showsArtwork {
                MacMusicArtwork(item: track, size: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                if showsArtist, let artist = track.trackArtist {
                    Text(artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if stars > 0 {
                Text(String(repeating: "★", count: stars))
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(stars == 1 ? "1 star" : "\(stars) stars")
            }
            if showsPlays, let plays = track.viewCount, plays > 0 {
                Text(plays == 1 ? "1 play" : "\(plays.formatted()) plays")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let popularity { MacMusicPopularityBar(fraction: popularity) }
            if let time = track.trackTime {
                Text(time).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, showsArtwork ? 6 : 9)
        .background(hovering ? MacTheme.surface.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu { MacMusicItemMenu(item: track) }
        .help(track.historyLine ?? "")
    }
}
