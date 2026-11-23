// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

/// What the sidebar opens.
enum MacSection: Hashable {
    var isPlaylist: Bool { if case .playlist = self { true } else { false } }

    case home
    case search
    /// A library; a music library's Home (its shelves).
    case library(String)
    /// One of a music library's own lists (Artists, Albums, Songs, ...).
    case musicPage(String, MacMusicKind)
    /// A music playlist, by rating key.
    case playlist(String)
    case liveTV
    case radio
}

/// The main window: Plex, Live TV and Radio in the sidebar, the chosen page
/// beside it, the music bar along the bottom, and a Plex title playing over
/// the whole window.
struct MacRootView: View {
    @Environment(MacPlexSession.self) private var plex
    @Environment(MacPlaybackController.self) private var playback
    @Environment(MacLivePlayback.self) private var live
    @Environment(MacMultiview.self) private var multiview
    @Environment(MacMusicPlayback.self) private var music
    @Environment(MacRadioPlayback.self) private var radio
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MacSidebarLayout.orderKey) private var sidebarOrder = ""
    @AppStorage(MacSidebarLayout.hiddenKey) private var sidebarHidden = ""
    @State private var section: MacSection? = .home
    @State private var path = NavigationPath()
    @State private var searchQuery = ""
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var isFullScreen = false
    @State private var choosingProfile = false
    @State private var showingSignIn = false
    @State private var accountHovering = false
    @State private var whatsNew: MacWhatsNew.Notice?
    /// Listed by name under Playlists, as in Apple Music.
    @State private var playlists: [PlexMetadata] = []

    var body: some View {
        ZStack {
            ZStack {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebar
                } detail: {
                    detail
                        // One bar floats over the bottom of the page, as Apple Music's player: a
                        // minimized Plex title, else the station while one is loaded (music stays
                        // paused under either), else music. An overlay on the detail column, so it
                        // covers pushed pages too, but not the sidebar.
                        .overlay(alignment: .bottom) {
                            bottomBar
                                .padding(.horizontal, 16)
                                .padding(.bottom, MacMusicBar.floatingMargin)
                        }
                }
                // Scroll views keep their last row clear of the bar. Environment on the split
                // view, not the detail stack: pushed pages miss environment set inside it.
                .contentMargins(.bottom, hasBottomBar ? MacMusicBar.reservedHeight : 0, for: .scrollContent)
                // On the split view, so the field sits in the window toolbar for every page,
                // not only inside the detail column's stack.
                .searchable(text: $searchQuery, placement: .toolbar, prompt: searchPrompt)
                if music.isNowPlayingShown {
                    MacMusicNowPlayingView()
                        .transition(.move(edge: .bottom))
                }
            }
            // Around the split view, not the detail stack: the split view hosts the
            // stack's pushed pages, which miss environment set inside its detail column.
            .macPlexActionHost(open: { path.append($0) })
            .animation(.easeInOut(duration: 0.25), value: music.isNowPlayingShown)
            if let session = playback.session {
                // Kept in the window while the picture is in Picture in Picture, so the
                // engine's surface stays alive, and while minimized (the bar then holds the
                // surface); it is only out of sight and out of reach.
                MacVODPlayerView(session: session, player: session.player, close: { playback.close() })
                    .opacity(playback.isPresented ? 1 : 0)
                    .allowsHitTesting(playback.isPresented)
                    .accessibilityHidden(!playback.isPresented)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playback.isPresented)
        // A Plex title has the window to itself: the sidebar and back buttons step aside.
        .toolbarVisibility(!playback.isPresented && !music.isNowPlayingShown ? .automatic : .hidden, for: .windowToolbar)
        // The playback keys act only in this window, not in a sheet or Settings.
        .background(MacWindowReader {
            MacAppDelegate.mainWindow = $0
            MacAppDelegate.vod?.applyWindowLevel(to: $0)
        })
        .onAppear {
            playback.plex = plex
            let section = $section
            MacAppDelegate.navigate = { section.wrappedValue = $0 }
            let openWindow = openWindow
            MacAppDelegate.openMainWindow = { openWindow(id: "main") }
            playback.onStart = { [live, multiview, radio, music] in
                live.stop()
                multiview.stopAll()
                radio.stop()
                music.pause()
            }
            // Music under a popped-out channel or a station would play over it.
            music.onStart = { [live, multiview, radio, playback] in
                // A title in Picture in Picture leaves the window free to start music.
                playback.close()
                live.stop()
                multiview.stopAll()
                radio.stop()
            }
        }
        .task { await plex.verifyConnection() }
        // Last launch's music queue comes back, paused, once its profile is in.
        .task(id: "\(plex.isSignedIn)|\(profiles.needsProfileSelection)") {
            if plex.isSignedIn, !profiles.needsProfileSelection { music.restoreQueue() }
        }
        .onChange(of: section) { old, new in
            path = NavigationPath()
            // Live TV plays inside its page; leaving the page stops it, unless
            // the picture has its own window.
            if old == .liveTV, new != .liveTV {
                multiview.stopAll()
                if !live.isPoppedOut { live.stop() }
            }
        }
        // Closing the floating window off the Live TV page ends the stream.
        .onChange(of: live.isPoppedOut) { was, isNow in
            if was, !isNow, section != .liveTV { live.stop() }
        }
        // One stream at a time: a channel or a multiview tile takes the sound from radio.
        .onChange(of: live.channel?.id) { _, channelID in
            if channelID != nil {
                radio.stop()
                playback.close()
            }
        }
        .onChange(of: multiview.tiles.count) { _, count in
            if count > 0 {
                radio.stop()
                playback.close()
            }
        }
        // Hiding the row that is open moves to the first one left.
        .onChange(of: sidebarHidden) {
            let hiddenIDs = MacSidebarLayout.ids(sidebarHidden)
            let musicKeys = Set(plex.libraries.filter(\.isMusicLibrary).map { MacSection.library($0.key) })
            let visible = MacSidebarLayout.plexItems(libraries: plex.libraries, order: sidebarOrder)
                .filter { !hiddenIDs.contains($0.id) }
                .map(\.section)
            let liveVisible = !hiddenIDs.contains(MacSidebarLayout.liveTVID)
            let radioVisible = !hiddenIDs.contains(MacSidebarLayout.radioID)
            let stillShown = section.map {
                visible.contains(Self.owner(of: $0)) || ($0 == .liveTV && liveVisible) || ($0 == .radio && radioVisible)
                    || ($0.isPlaylist && visible.contains { musicKeys.contains($0) })
            } ?? false
            if !stillShown {
                section = visible.first ?? (liveVisible ? .liveTV : radioVisible ? .radio : .home)
            }
        }
        .onChange(of: plex.sessionGeneration) { path = NavigationPath() }
        // Signing out, from the sidebar or from Settings, ends the Plex title playing.
        .onChange(of: plex.isSignedIn) { _, signedIn in
            if !signedIn {
                playback.close()
                music.stop()
            }
        }
        // Live TV and Radio search their own lists; elsewhere the field searches Plex.
        .onChange(of: searchQuery) { _, query in
            if !query.isEmpty, !searchesOwnList(section), section != .search { section = .search }
        }
        // A filter typed on Live TV or Radio does not follow to another page.
        .onChange(of: section) { old, new in
            if searchesOwnList(old) || searchesOwnList(new) { searchQuery = "" }
        }
        // Content is withheld until a profile is entered: ask who is watching,
        // and nothing of the locked profile's keeps playing.
        .onChange(of: profiles.needsProfileSelection, initial: true) { _, needed in
            if needed {
                playback.close()
                music.stop(keepingSavedQueue: true)
            }
            choosingProfile = needed && profiles.hasLoadedProfiles
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await plex.refreshIfStale() } }
        }
        // Full screen is for watching: the sidebar steps aside, and comes back on exit.
        // This window only: the popped-out Live TV window goes full screen on its own.
        .task {
            for await note in NotificationCenter.default.notifications(named: NSWindow.didEnterFullScreenNotification) {
                guard (note.object as? NSWindow) === MacAppDelegate.mainWindow else { continue }
                isFullScreen = true
                withAnimation { columns = .detailOnly }
            }
        }
        .task {
            for await note in NotificationCenter.default.notifications(named: NSWindow.didExitFullScreenNotification) {
                guard (note.object as? NSWindow) === MacAppDelegate.mainWindow else { continue }
                isFullScreen = false
                withAnimation { columns = .all }
            }
        }
        .sheet(isPresented: $choosingProfile) { MacProfilePickerSheet() }
        .sheet(isPresented: $showingSignIn) { MacPlexSignInSheet() }
        .sheet(item: $whatsNew) { MacWhatsNewSheet(notice: $0) }
        .task { whatsNew = MacWhatsNew.pending() }
        .task(id: "\(plex.sessionGeneration)|\(plex.libraries.contains(where: \.isMusicLibrary))") {
            playlists = plex.libraries.contains(where: \.isMusicLibrary) ? ((try? await plex.audioPlaylists()) ?? []).uniqued() : []
        }
    }

    /// The sidebar row a section belongs to: a music page belongs to its library.
    private static func owner(of section: MacSection) -> MacSection {
        if case .musicPage(let key, _) = section { return .library(key) }
        return section
    }

    private var hasBottomBar: Bool {
        (playback.isMinimized && playback.session != nil) || radio.station != nil || music.track != nil
    }

    @ViewBuilder
    private var bottomBar: some View {
        if playback.isMinimized, let session = playback.session {
            MacVideoBar(session: session, player: session.player)
        } else if radio.station != nil {
            MacRadioBar()
        } else {
            MacMusicBar()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            let hiddenIDs = MacSidebarLayout.ids(sidebarHidden)
            let items = MacSidebarLayout.plexItems(libraries: plex.libraries, order: sidebarOrder)
                .filter { !hiddenIDs.contains($0.id) }
            let musicKeys = Set(plex.libraries.filter(\.isMusicLibrary).map { MacSection.library($0.key) })
            let plexRows = items.filter { !musicKeys.contains($0.section) }
            let musicRows = items.filter { musicKeys.contains($0.section) }
            if !plexRows.isEmpty {
                Section("Plex") {
                    ForEach(plexRows) { item in
                        Label(item.title, systemImage: item.icon).tag(item.section)
                    }
                }
            }
            // Each music library lists its pages as Apple Music does, then the playlists.
            ForEach(musicRows) { item in
                if case .library(let key) = item.section {
                    Section(item.title) {
                        Label("Home", systemImage: "house").tag(item.section)
                        ForEach(MacMusicKind.sidebarPages) { page in
                            Label(page.title, systemImage: page.icon).tag(MacSection.musicPage(key, page))
                        }
                    }
                }
            }
            if !musicRows.isEmpty, case .library(let key)? = musicRows.first?.section {
                Section("Playlists") {
                    Label("All Playlists", systemImage: "square.grid.2x2").tag(MacSection.musicPage(key, .playlists))
                    ForEach(playlists, id: \.id) { playlist in
                        Label(playlist.title ?? "Playlist", systemImage: "music.note.list")
                            .tag(MacSection.playlist(playlist.ratingKey ?? ""))
                            .contextMenu { MacMusicItemMenu(item: playlist) }
                    }
                }
            }
            if !hiddenIDs.contains(MacSidebarLayout.liveTVID) {
                Section("Live TV") {
                    Label("Channels", systemImage: "play.tv").tag(MacSection.liveTV)
                }
            }
            if !hiddenIDs.contains(MacSidebarLayout.radioID) {
                Section("Radio") {
                    Label("Stations", systemImage: "radio").tag(MacSection.radio)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        .safeAreaInset(edge: .bottom) { accountButton.padding(10) }
    }

    @ViewBuilder
    private var accountButton: some View {
        if plex.isSignedIn {
            Menu {
                if let server = plex.selectedServerName {
                    Text(server)
                }
                if profiles.hasMultipleProfiles {
                    Button("Switch Profile…") { choosingProfile = true }
                }
                Divider()
                Button("Sign Out of Plex", role: .destructive) { plex.signOut() }
            } label: {
                HStack(spacing: 10) {
                    MacPlexAvatar(url: profiles.selectedUser?.avatarURL ?? plex.profileImageURL, size: 30)
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profiles.selectedUser?.displayName ?? plex.profileDisplayName ?? "Plex")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if let server = plex.selectedServerName {
                            Text(server)
                                .font(.caption)
                                .foregroundStyle(MacTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
                .background(MacTheme.surface.opacity(accountHovering ? 0.8 : 0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
                .onHover { accountHovering = $0 }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        } else {
            Button {
                showingSignIn = true
            } label: {
                Label("Sign In to Plex…", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Detail

    private func searchesOwnList(_ section: MacSection?) -> Bool {
        section == .liveTV || section == .radio
    }

    private var searchPrompt: String {
        switch section {
        case .liveTV: "Channels and Programmes"
        case .radio: "Stations"
        default: "Movies, Shows and Episodes"
        }
    }

    @ViewBuilder
    private var detail: some View {
        if section == .liveTV {
            // The channel's picture is no scroll view: it stops above the bar.
            MacLiveTVView(isFullScreen: isFullScreen, query: searchQuery)
                .padding(.bottom, hasBottomBar ? MacMusicBar.reservedHeight : 0)
        } else if section == .radio {
            MacRadioView(query: searchQuery)
        } else {
            NavigationStack(path: $path) {
                plexRoot
                    .navigationDestination(for: PlexMetadata.self) { destination(for: $0) }
                    .navigationDestination(for: PlexLibrary.self) { MacPlexLibraryView(library: $0) }
                    .navigationDestination(for: MacPlexHubRoute.self) { MacPlexHubGridView(route: $0) }
            }
            .macScreen()
        }
    }

    @ViewBuilder
    private var plexRoot: some View {
        if !plex.isConfigured {
            MacPlexConnectView()
        } else {
            switch section ?? .home {
            case .home, .liveTV, .radio:
                MacPlexHomeView()
            case .musicPage(let key, let page):
                if let library = plex.libraries.first(where: { $0.key == key }) {
                    MacMusicLibraryView(library: library, page: page).id("\(key)|\(page.rawValue)")
                } else {
                    ContentUnavailableView("Library Not Found", systemImage: "rectangle.stack")
                }
            case .playlist(let key):
                if let playlist = playlists.first(where: { $0.ratingKey == key }) {
                    MacMusicAlbumView(item: playlist).id(key)
                } else {
                    ContentUnavailableView("Playlist Not Found", systemImage: "music.note.list")
                }
            case .search:
                MacPlexSearchView(query: $searchQuery)
            case .library(let key):
                if let library = plex.libraries.first(where: { $0.key == key }) {
                    if library.isMusicLibrary {
                        MacMusicLibraryView(library: library).id(key)
                    } else {
                        MacPlexLibraryView(library: library).id(key)
                    }
                } else {
                    ContentUnavailableView("Library Not Found", systemImage: "rectangle.stack")
                }
            }
        }
    }

    /// Music items open their own pages; everything else the title detail.
    @ViewBuilder
    private func destination(for item: PlexMetadata) -> some View {
        switch item.type {
        case "artist": MacMusicArtistView(artist: item)
        case "album", "playlist": MacMusicAlbumView(item: item)
        default: MacPlexDetailView(item: item)
        }
    }
}
