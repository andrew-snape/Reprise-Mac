// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import AVKit
import CryptoKit
import NowPlaying
import Observation
import SwiftUI

/// App-level owner of the Plex item playing, shown over the whole window.
/// Starting one stops Live TV and radio, and pauses music (`onStart`), so only one stream plays at a time.
/// It also owns Now Playing and the media keys for radio, music and Live TV.
@MainActor
@Observable
final class MacPlaybackController {
    private static let nowPlayingUpdateInterval: TimeInterval = 5

    private(set) var session: MacPlexPlayback?
    private(set) var isAlwaysOnTop = false
    private(set) var isPictureInPicturePossible = false
    /// The picture is in its own floating window and the main window is free to browse.
    private(set) var isPictureInPictureActive = false
    /// The title plays on in the bottom bar, its picture there, while the window browses.
    private(set) var isMinimized = false
    /// A title covers the window: one is playing, not minimized and not in Picture in Picture.
    var isPresented: Bool { session != nil && !isPictureInPictureActive && !isMinimized }

    /// Needed to build sessions; the root view sets it.
    @ObservationIgnored weak var plex: MacPlexSession?
    @ObservationIgnored var onStart: (() -> Void)?

    @ObservationIgnored private var stateObservation: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingObservations: [Task<Void, Never>] = []
    @ObservationIgnored private let sleepGuard = MacSleepGuard()
    @ObservationIgnored private var liveObservation: Task<Void, Never>?
    @ObservationIgnored private var musicObservations: [Task<Void, Never>] = []
    /// What the system's Now Playing shows, and the session publishing it while anything is loaded.
    @ObservationIgnored private let nowPlaying = MacNowPlayingModel()
    @ObservationIgnored private var nowPlayingSession: MediaSession<MacNowPlayingModel>?
    @ObservationIgnored private var publishedID: String?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var videoShapeObservation: Task<Void, Never>?
    @ObservationIgnored private var hasConfiguredRemoteCommands = false
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var pipDelegate: MacPictureInPictureDelegate?
    @ObservationIgnored private var pipPossibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var pipSourceObservation: Task<Void, Never>?
    /// Set by the restore button, so the stop that follows returns to the player
    /// instead of ending the title.
    @ObservationIgnored private var isRestoringFromPictureInPicture = false
    /// The last title's volume and mute; the next title starts on them.
    @ObservationIgnored private var volume: Float = 1
    @ObservationIgnored private var isMuted = false

    /// Plays a Plex item: a show or season resolves to its next-up episode.
    /// The one way a title starts, from a tile, a menu or Siri.
    func play(item: PlexMetadata) async throws {
        guard let plex else { throw MacPlexSessionError.notConfigured }
        let target = try await plex.playableTarget(for: item)
        play(try await plex.playback(for: target))
    }

    func play(_ request: MacPlexPlaybackRequest) {
        guard let plex else { return }
        end()
        let newSession = MacPlexPlayback(request: request, plex: plex)
        newSession.player.setVolume(volume)
        newSession.player.setMuted(isMuted)
        session = newSession
        lockAspectRatio(true)
        onStart?()
        // Keep the display awake while something plays, as a video player should.
        let player = newSession.player
        stateObservation = Task { [weak self] in
            for await playing in Observations({ player.state == .playing }) {
                self?.sleepGuard.setAwake(playing)
            }
        }
        videoShapeObservation = Task { [weak self] in
            for await size in Observations({ player.videoSize }) {
                self?.fitWindow(toVideo: size)
            }
        }
        pipSourceObservation = Task { [weak self] in
            for await _ in Observations({ player.pictureInPictureRevision }) {
                self?.updatePictureInPicture(player.pictureInPictureSource)
            }
        }
        // The Picture in Picture window re-reads paused state only when told.
        let stateWatch = Task { [weak self] in
            for await _ in Observations({ player.state }) {
                self?.pip?.invalidatePlaybackState()
            }
        }
        observeNowPlaying(for: newSession)
        nowPlayingObservations.append(stateWatch)
        updateRemoteCommandAvailability(for: newSession)
        Task { await newSession.begin() }
    }

    // MARK: - Minimize

    /// Shrinks the title into the bottom bar and gives the window back to browsing.
    func minimize() {
        guard let session, isPresented else { return }
        if let window = MacAppDelegate.mainWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        session.pane = nil
        setAlwaysOnTop(false)
        // The browsing layout takes the window back, at its own sizes.
        MacAppDelegate.mainWindow?.contentResizeIncrements = NSSize(width: 1, height: 1)
        isMinimized = true
    }

    /// Brings a minimized title back over the window.
    func expand() {
        guard session != nil, isMinimized else { return }
        isMinimized = false
        MacAppDelegate.showMainWindow()
        refitWindow()
    }

    /// The window takes the picture's shape again, as it leaves browsing.
    private func refitWindow() {
        guard let session else { return }
        let size = session.player.videoSize
        if size.width > 0, size.height > 0 {
            MacAppDelegate.mainWindow?.fit(toVideo: size)
        } else {
            MacAppDelegate.mainWindow?.contentAspectRatio = NSSize(width: 16, height: 9)
        }
    }

    // MARK: - Picture in Picture

    /// Moves the picture into the system's floating window and frees the main window.
    /// Its restore button returns to the player; its close button ends the title.
    func startPictureInPicture() {
        guard let pip, pip.isPictureInPicturePossible, !pip.isPictureInPictureActive else { return }
        if let window = MacAppDelegate.mainWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        pip.startPictureInPicture()
    }

    private func updatePictureInPicture(_ source: AVPictureInPictureController.ContentSource?) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if let pip {
            // Keep a live window through a reload's passing nil; a new layer replaces a dead one.
            if source != nil || !pip.isPictureInPictureActive { pip.contentSource = source }
            return
        }
        guard let source else { return }
        let controller = AVPictureInPictureController(contentSource: source)
        let delegate = MacPictureInPictureDelegate(
            didStart: { [weak self] in self?.pictureInPictureDidStart() },
            restore: { [weak self] in self?.isRestoringFromPictureInPicture = true },
            didStop: { [weak self] in self?.pictureInPictureDidStop() })
        controller.delegate = delegate
        pipDelegate = delegate
        pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPictureInPicturePossible = possible }
        }
        pip = controller
    }

    private func pictureInPictureDidStart() {
        guard let session else { return }
        session.player.setPictureInPictureActive(true)
        session.pane = nil
        setAlwaysOnTop(false)
        // The browsing layout takes the window back, at its own sizes.
        MacAppDelegate.mainWindow?.contentResizeIncrements = NSSize(width: 1, height: 1)
        // The floating window holds the picture now; restoring returns to the full player.
        isMinimized = false
        isPictureInPictureActive = true
    }

    private func pictureInPictureDidStop() {
        let restoring = isRestoringFromPictureInPicture
        isRestoringFromPictureInPicture = false
        guard isPictureInPictureActive, let session else { return }
        session.player.setPictureInPictureActive(false)
        isPictureInPictureActive = false
        // Anything withheld while the window was up.
        pip?.contentSource = session.player.pictureInPictureSource
        guard restoring else {
            // The floating window's close button.
            end()
            return
        }
        MacAppDelegate.showMainWindow()
        refitWindow()
    }

    private func endPictureInPicture() {
        pipSourceObservation?.cancel()
        pipSourceObservation = nil
        pipPossibleObservation = nil
        pip?.delegate = nil
        pip?.stopPictureInPicture()
        pip = nil
        pipDelegate = nil
        isRestoringFromPictureInPicture = false
        isPictureInPicturePossible = false
        isPictureInPictureActive = false
    }

    private func fitWindow(toVideo size: CGSize) {
        // Browsing (minimized or in Picture in Picture) keeps its own window shape.
        guard isPresented else { return }
        MacAppDelegate.mainWindow?.fit(toVideo: size)
    }

    /// Ends playback and leaves the player. The task ends once Plex has the final report.
    @discardableResult
    func close() -> Task<Void, Never>? {
        end()
    }

    @discardableResult
    private func end() -> Task<Void, Never>? {
        guard let session else { return nil }
        volume = session.player.volume
        isMuted = session.player.isMuted
        let reported = session.end()
        endPictureInPicture()
        isMinimized = false
        session.player.stop()
        stateObservation?.cancel()
        stateObservation = nil
        cancelNowPlayingObservations()
        setAlwaysOnTop(false)
        lockAspectRatio(false)
        sleepGuard.setAwake(false)
        self.session = nil
        updateRemoteCommandAvailability(for: nil)
        // Music or a channel left underneath takes Now Playing back.
        updateBackgroundNowPlaying()
        return reported
    }

    /// Pinning is a per-session choice and resets when playback ends.
    func setAlwaysOnTop(_ enabled: Bool) {
        isAlwaysOnTop = enabled
        MacAppDelegate.mainWindow?.level = windowLevel
    }

    /// The window keeps the picture's 16:9 shape while a title plays. Setting
    /// resize increments back to 1 is how AppKit clears an aspect ratio.
    private func lockAspectRatio(_ locked: Bool) {
        guard let window = MacAppDelegate.mainWindow else { return }
        if locked {
            window.contentAspectRatio = NSSize(width: 16, height: 9)
        } else {
            videoShapeObservation?.cancel()
            videoShapeObservation = nil
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
        }
    }

    func applyWindowLevel(to window: NSWindow) {
        window.level = windowLevel
    }

    private var windowLevel: NSWindow.Level {
        isAlwaysOnTop ? .floating : .normal
    }

    /// Starts publishing to the system's Now Playing (the widget, the media keys,
    /// headphone buttons) through the Now Playing framework: one session for the
    /// app's lifetime, whose model this controller fills from whatever is in front.
    func configureRemoteCommands() {
        guard !hasConfiguredRemoteCommands else { return }
        hasConfiguredRemoteCommands = true
        // Playback Siri started in the background claims the system once the app is in front.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.claimNowPlaying() }
        }
        updateRemoteCommandAvailability(for: nil)
        observeLive()
        observeMusic()
        observeRadio()
        observeLogo()
        updateBackgroundNowPlaying()
    }

    /// Music, when it is in front of any channel and no Plex title is up.
    private var music: MacMusicPlayback? {
        MacAppDelegate.musicInFront ? MacAppDelegate.music : nil
    }

    /// The channel on screen: Now Playing and the media keys follow it while no Plex title is up.
    private var live: MacLivePlayback? {
        MacAppDelegate.playback.flatMap { $0.channel == nil ? nil : $0 }
    }

    /// The station loaded, with no Plex title up. Radio stops a channel and
    /// pauses music as it starts, so nothing else is in front of it.
    private var radio: MacRadioPlayback? {
        guard session == nil, let radio = MacAppDelegate.radio, radio.station != nil else { return nil }
        return radio
    }

    /// The player in front: the Plex title, else the channel.
    private var activePlayer: AetherPlayer? {
        session?.player ?? live?.player
    }

    private func observeLive() {
        guard let playback = MacAppDelegate.playback else { return }
        liveObservation = Task { [weak self] in
            for await _ in Observations({
                _ = (playback.channel?.id, playback.player.state, playback.programme?.title)
            }) {
                guard let self, self.session == nil else { continue }
                self.updateBackgroundNowPlaying()
                self.updateRemoteCommandAvailability(for: nil)
            }
        }
    }

    private func observeMusic() {
        guard let music = MacAppDelegate.music else { return }
        let player = music.player
        // Anything but the clock: the track, transport, length, seeks and the queue's ends.
        musicObservations.append(Task { [weak self] in
            for await _ in Observations({
                _ = (music.track?.ratingKey, player.state, player.duration, player.seekCount,
                     music.queue.hasNext, music.queue.hasPrevious, MacAppDelegate.musicInFront)
            }) {
                guard let self, self.session == nil else { continue }
                self.updateBackgroundNowPlaying()
                self.updateRemoteCommandAvailability(for: nil)
            }
        })
    }

    private func observeRadio() {
        guard let radio = MacAppDelegate.radio else { return }
        musicObservations.append(Task { [weak self] in
            for await _ in Observations({ _ = (radio.station?.name, radio.state, radio.streamTitle, radio.cover) }) {
                guard let self, self.session == nil else { continue }
                self.updateBackgroundNowPlaying()
                self.updateRemoteCommandAvailability(for: nil)
            }
        })
    }

    /// A station's or channel's logo is what Now Playing shows when there is no better picture.
    private func observeLogo() {
        guard let radio = MacAppDelegate.radio, let live = MacAppDelegate.playback else { return }
        musicObservations.append(Task { [weak self] in
            for await _ in Observations({ _ = (radio.station?.tvgLogo, live.channel?.id) }) {
                guard let self, self.session == nil else { continue }
                self.updateBackgroundNowPlaying()
            }
        })
    }

    // MARK: - Now Playing

    /// Publishes `content` and `snapshot`, or withdraws the session when nothing is
    /// loaded. A new item claims the system, as a press of Play does.
    private func publish(_ content: (any MediaContentRepresentable)?, _ snapshot: MediaPlaybackSnapshot?) {
        guard let content else {
            nowPlayingSession = nil
            nowPlaying.content = nil
            nowPlaying.playbackSnapshot = nil
            publishedID = nil
            return
        }
        nowPlaying.content = content
        nowPlaying.playbackSnapshot = snapshot
        if nowPlayingSession == nil { nowPlayingSession = MediaSession(nowPlaying) }
        if publishedID != content.id {
            publishedID = content.id
            claimNowPlaying()
        }
    }

    /// Makes this the app's session, so the system's Now Playing and the media keys
    /// follow it. (Asking to be the system's primary session is not offered on macOS.)
    private func claimNowPlaying() {
        guard let session = nowPlayingSession else { return }
        Task { try? await session.requestToBecomeApplicationPrimary() }
    }

    private static func snapshot(playing: Bool, stopped: Bool, rate: Float = 1,
                                 elapsed: TimeInterval? = nil) -> MediaPlaybackSnapshot {
        let state: MediaPlaybackSnapshot.PlaybackState = stopped ? .stopped : (playing ? .playing(rate: rate) : .paused)
        let time = elapsed.flatMap { $0.isFinite ? max(0, $0) : nil }
        return MediaPlaybackSnapshot(state: state, defaultPlaybackRate: 1, elapsedTime: time,
                                     timestamp: time == nil ? nil : .now)
    }

    private static func isStopped(_ state: AetherPlayer.State) -> Bool {
        switch state {
        case .ended, .failed, .idle: true
        default: false
        }
    }

    private static func length(_ seconds: TimeInterval) -> MediaDuration? {
        seconds.isFinite && seconds > 0 ? .finite(seconds) : nil
    }

    /// Artwork the framework fetches when it wants it. The id never holds a URL
    /// (Plex URLs carry the token); the loader keeps it to itself.
    private static func artwork(id: String, url: URL?, square: Bool = false) -> Artwork? {
        guard let url else { return nil }
        return Artwork(id: id) { _ in
            guard let image = await MacNowPlayingArt.image(for: url, square: square) else {
                throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
            }
            return try ArtworkRepresentation(cgImage: image)
        }
    }

    private static func artwork(id: String, image: NSImage) -> Artwork? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return Artwork(id: id) { _ in try ArtworkRepresentation(cgImage: cgImage) }
    }

    /// The station's or channel's logo, centred on a square: Now Playing crops a wide one.
    private var logoArtwork: Artwork? {
        let url: URL?
        if let station = MacAppDelegate.radio?.station {
            url = station.tvgLogo.flatMap(URL.init(string:))
        } else {
            url = MacAppDelegate.playback?.channel?.logoURL
        }
        return url.flatMap { Self.artwork(id: "logo-" + MacNowPlayingArt.digest($0), url: $0, square: true) }
    }

    /// Now Playing with no Plex title up: a station, else music in front, else the channel.
    private func updateBackgroundNowPlaying() {
        if let radio {
            updateRadioNowPlaying(radio)
        } else if let music {
            updateMusicNowPlaying(music)
        } else {
            updateLiveNowPlaying()
        }
    }

    /// The song the station names, if it sends one, with its artist and the station
    /// as its album; else the station alone.
    private func updateRadioNowPlaying(_ radio: MacRadioPlayback) {
        let stationName = radio.station?.name ?? ""
        let stationID = "station-" + MacNowPlayingArt.digest(stationName)
        let picture = radio.cover.flatMap { Self.artwork(id: stationID + "-" + (radio.song?.text ?? ""), image: $0) }
            ?? logoArtwork
        let content: any MediaContentRepresentable
        if let song = radio.song {
            content = MusicContent(id: stationID + "-" + song.text, songTitle: song.title,
                                   artistName: song.artist ?? stationName,
                                   albumName: song.artist == nil ? "" : stationName,
                                   type: .audio, duration: .live, artwork: picture)
        } else {
            content = RadioContent(id: stationID, stationName: stationName, artwork: picture)
        }
        let stopped: Bool
        switch radio.state {
        case .idle, .failed: stopped = true
        default: stopped = false
        }
        publish(content, Self.snapshot(playing: radio.state == .playing, stopped: stopped))
    }

    private func updateMusicNowPlaying(_ music: MacMusicPlayback) {
        guard let track = music.track else { return publish(nil, nil) }
        let player = music.player
        let duration = player.duration > 0 ? player.duration : track.durationSeconds
        let key = track.ratingKey ?? ""
        let content = MusicContent(
            id: "track-" + key, songTitle: track.displayTitle, artistName: track.trackArtist ?? "",
            albumName: track.parentTitle ?? "", type: .audio, duration: Self.length(duration),
            artwork: Self.artwork(id: "track-" + key,
                                  url: plex?.imageURL(path: track.squareArtPath, width: 600, height: 600)))
        let stopped: Bool
        switch player.state {
        case .ended, .failed, .idle: stopped = true
        default: stopped = false
        }
        publish(content, Self.snapshot(playing: player.state == .playing, stopped: stopped,
                                       elapsed: player.currentTime))
    }

    private func updateLiveNowPlaying() {
        guard let playback = live, let channel = playback.channel else { return publish(nil, nil) }
        let content = GenericContent(
            id: "channel-" + MacNowPlayingArt.digest(channel.id),
            title: playback.programme?.displayTitle ?? channel.name,
            subtitle: channel.numberAndName, type: .video, duration: .live, artwork: logoArtwork)
        let state = playback.player.state
        publish(content, Self.snapshot(playing: state == .playing, stopped: Self.isStopped(state)))
    }

    private func cancelNowPlayingObservations() {
        nowPlayingObservations.forEach { $0.cancel() }
        nowPlayingObservations.removeAll()
    }

    private func observeNowPlaying(for session: MacPlexPlayback) {
        cancelNowPlayingObservations()
        let player = session.player
        // Anything but the clock: transport, seek, length, speed, and the item itself (Up Next swaps it).
        nowPlayingObservations.append(Task { [weak self] in
            for await _ in Observations({
                _ = (player.state, player.pendingSeekTarget, player.duration, player.rate, session.request.item.ratingKey)
            }) {
                self?.updateNowPlaying()
            }
        })
        // Now Playing runs the clock on from the rate between updates; this keeps it honest.
        nowPlayingObservations.append(Task { [weak self] in
            for await _ in Observations({ _ = player.currentTime }) {
                self?.updateNowPlaying()
                try? await Task.sleep(for: .seconds(Self.nowPlayingUpdateInterval))
            }
        })
        nowPlayingObservations.append(Task { [weak self] in
            for await _ in Observations({ session.nextEpisode?.ratingKey }) {
                guard let self else { return }
                self.updateRemoteCommandAvailability(for: self.session)
            }
        })
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard let session else { return }
        let item = session.request.item
        let player = session.player
        let duration = Self.length(player.duration > 0 ? player.duration : item.durationSeconds)
        let key = item.ratingKey ?? ""
        let poster = Self.artwork(id: "poster-" + key,
                                  url: plex?.artworkURL(for: item, kind: .poster, width: 600, height: 900))
        let content: any MediaContentRepresentable = item.type == "episode"
            ? TVShowContent(id: "title-" + key, episodeTitle: item.displayTitle, showName: item.showTitle,
                            duration: duration, artwork: poster)
            : MovieContent(id: "title-" + key, title: item.displayTitle, duration: duration, artwork: poster)
        let state = player.state
        publish(content, Self.snapshot(playing: state == .playing,
                                       stopped: Self.isStopped(state),
                                       rate: player.rate,
                                       elapsed: player.pendingSeekTarget ?? player.currentTime))
    }

    /// The controls Now Playing offers for what is in front. Music skips by track
    /// rather than by seconds; Live TV skips inside its DVR window only.
    private func updateRemoteCommandAvailability(for session: MacPlexPlayback?) {
        let available = session != nil
        let musicUp = session == nil ? music : nil
        let liveUp = session == nil ? live : nil
        let liveCanSkip = liveUp?.player.liveWindow.seekableRange != nil
        let liveCanSkipForward = liveCanSkip && liveUp?.player.liveWindow.isAtLiveEdge == false
        let playing = available || musicUp != nil || live != nil || radio != nil
        // Read again each time, so a change in Settings reaches the next title.
        let back = TimeInterval(MacSkipInterval.back)
        let forward = TimeInterval(MacSkipInterval.forward)
        // Explicitly main-actor: the framework may call from its own queue.
        nowPlaying.commands = [
            .play { @MainActor [weak self] in _ = self?.remotePlay() }.enabled(playing),
            .pause { @MainActor [weak self] in _ = self?.remotePause() }.enabled(playing),
            .togglePlayPause { @MainActor [weak self] in _ = self?.remoteToggle() }.enabled(playing),
            .stop { @MainActor [weak self] in _ = self?.remoteStop() }.enabled(playing),
            .skipBackward(preferredIntervals: [back]) { @MainActor [weak self] interval in
                _ = self?.remoteSkip(by: -abs(interval.isFinite ? interval : back))
            }.enabled(available || liveCanSkip),
            .skipForward(preferredIntervals: [forward]) { @MainActor [weak self] interval in
                _ = self?.remoteSkip(by: abs(interval.isFinite ? interval : forward))
            }.enabled(available || liveCanSkipForward),
            .seekToPosition { @MainActor [weak self] position in
                self?.remoteSeek(to: position)
            }.enabled(available || musicUp != nil),
            .next { @MainActor [weak self] in _ = self?.remoteNext() }
                .enabled(session?.nextEpisode != nil || musicUp?.queue.hasNext == true),
            .previous { @MainActor [weak self] in _ = self?.remotePrevious() }.enabled(musicUp != nil),
        ]
    }

    // MARK: - Transport (Now Playing, the media keys, Siri)

    @discardableResult
    func remotePlay() -> Bool {
        if let radio {
            if radio.state != .playing, radio.state != .loading { radio.togglePlayPause() }
            return true
        }
        if session == nil, let music {
            music.resume()
            return true
        }
        guard let player = activePlayer else { return false }
        switch player.state {
        case .playing:
            return true
        case .paused:
            player.togglePlayPause()
            return true
        default:
            return false
        }
    }

    @discardableResult
    func remotePause() -> Bool {
        if let radio {
            if radio.state == .playing || radio.state == .loading { radio.togglePlayPause() }
            return true
        }
        if session == nil, let music {
            music.pause()
            return true
        }
        guard let player = activePlayer else { return false }
        if player.state == .playing { player.togglePlayPause() }
        return true
    }

    @discardableResult
    func remoteToggle() -> Bool {
        if let radio {
            radio.togglePlayPause()
            return true
        }
        if session == nil, let music {
            music.togglePlayPause()
            return true
        }
        guard let player = activePlayer else { return false }
        player.togglePlayPause()
        return true
    }

    private func remoteStop() -> Bool {
        if session != nil {
            close()
        } else if let radio {
            radio.stop()
        } else if let music {
            music.stop()
        } else if let live {
            live.stop()
        } else {
            return false
        }
        return true
    }

    private func remoteSkip(by seconds: Double) -> Bool {
        if let player = session?.player {
            Task { await player.skip(by: seconds) }
            return true
        }
        guard let player = live?.player, player.liveWindow.seekableRange != nil,
              !(seconds > 0 && player.liveWindow.isAtLiveEdge) else { return false }
        Task { await player.skip(by: seconds) }
        return true
    }

    private func remoteSeek(to position: TimeInterval) {
        guard position.isFinite else { return }
        if session == nil, let music {
            music.seek(to: max(position, 0))
            return
        }
        guard let player = session?.player else { return }
        let target = player.duration > 0 ? min(max(position, 0), player.duration) : max(position, 0)
        Task { await player.seek(to: target) }
    }

    @discardableResult
    func remoteNext() -> Bool {
        if session == nil, let music, music.queue.hasNext {
            music.skipToNext()
            return true
        }
        guard let session, session.nextEpisode != nil else { return false }
        session.playNext()
        return true
    }

    @discardableResult
    func remotePrevious() -> Bool {
        guard session == nil, let music else { return false }
        music.skipToPrevious()
        return true
    }
}

/// The model the Now Playing framework observes: what is in front, its state and its controls.
@MainActor
@Observable
final class MacNowPlayingModel: MediaSessionRepresentable {
    nonisolated let id = "reprise"
    var content: (any MediaContentRepresentable)?
    var playbackSnapshot: MediaPlaybackSnapshot?
    var commands: [MediaCommand] = []
}

/// Artwork loading for Now Playing, off the views' cache.
enum MacNowPlayingArt {
    static func image(for url: URL, square: Bool) async -> CGImage? {
        guard let image = await MacArtworkCache.shared.image(for: url) else { return nil }
        let shaped = square ? image.centredOnSquare() : image
        return shaped.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// A short stable name for an id, so no address or token ends up in one.
    nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func digest(_ url: URL) -> String { digest(url.absoluteString) }
}

/// AVKit's delegate is an NSObject protocol; this passes its three moments on.
private final class MacPictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    private let didStart: () -> Void
    private let restore: () -> Void
    private let didStop: () -> Void

    init(didStart: @escaping () -> Void, restore: @escaping () -> Void, didStop: @escaping () -> Void) {
        self.didStart = didStart
        self.restore = restore
        self.didStop = didStop
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        didStart()
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        restore()
        completionHandler(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        didStop()
    }
}

// MARK: - Player

/// A Plex title over the whole window: the video, captions, and controls that
/// show while the pointer moves.
struct MacVODPlayerView: View {
    var session: MacPlexPlayback
    var player: AetherPlayer
    let close: () -> Void
    @Environment(MacPlaybackController.self) private var controller
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @AppStorage(MacSkipInterval.backKey) private var skipBackSetting = MacSkipInterval.backDefault
    @AppStorage(MacSkipInterval.forwardKey) private var skipForwardSetting = MacSkipInterval.forwardDefault

    private var skipBack: Int { MacSkipInterval.checked(skipBackSetting, fallback: MacSkipInterval.backDefault) }
    private var skipForward: Int { MacSkipInterval.checked(skipForwardSetting, fallback: MacSkipInterval.forwardDefault) }

    var body: some View {
        ZStack {
            // The picture fills the window, title bar included.
            GeometryReader { proxy in
                ZStack {
                    Color.black
                    // Minimized, the bottom bar shows the picture: the surface lives in one place only.
                    if !controller.isMinimized { player.surface }
                    MacCaptionOverlay(player: player, container: proxy.size)
                        .allowsHitTesting(false)
                    // Clicks on the picture, under the controls: double for full screen, single for play/pause.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
                        .onTapGesture { player.togglePlayPause() }
                }
            }
            .ignoresSafeArea()
            // The rest keeps below the title bar, whose window buttons would take the close
            // button's clicks, and above the click layer, so the failure's buttons take clicks.
            status
            VStack(spacing: 0) {
                topBar
                    .opacity(chromeVisible ? 1 : 0)
                Spacer()
                // Skip and Up Next stay up with the controls hidden, so they can be clicked at once.
                HStack(alignment: .bottom) {
                    Spacer()
                    contextualButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                if session.pane != nil {
                    MacPlayerPaneCard(
                        session: session, player: player, detail: session.detail,
                        chapters: session.chapters,
                        pane: Binding(get: { session.pane }, set: { session.pane = $0 })
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .opacity(chromeVisible ? 1 : 0)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                controls
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                    .opacity(chromeVisible ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.25), value: controlsVisible)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: showControls()
            case .ended: scheduleHide(after: .seconds(1))
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { scheduleHide(after: .seconds(3)) }
        .task(id: session.request.item.ratingKey) { await session.loadDetail() }
        .animation(.easeOut(duration: 0.2), value: session.pane)
        // A slow start or a resume from the keyboard leaves the pointer still, so fade from here too.
        .onChange(of: player.state) { _, state in
            if state == .playing { scheduleHide(after: .seconds(3)) }
        }
    }

    private var chromeVisible: Bool { controlsVisible || player.state != .playing || session.pane != nil }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        if let reason = session.serverStopReason {
            VStack(spacing: 12) {
                Image(systemName: "stop.circle.fill").font(.largeTitle)
                Text("Playback Stopped").font(.headline)
                Text(reason).multilineTextAlignment(.center).frame(maxWidth: 380)
                Button("Close", action: close)
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        } else if case .failed(let message) = player.state {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 380)
                HStack {
                    if player.canRetry { Button("Try Again", action: session.retry) }
                    Button("Close", action: close)
                }
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        } else if player.state == .idle || player.state == .loading || player.isBuffering
                    || (player.isStarting && player.state == .playing) {
            ProgressView().controlSize(.large).tint(.white)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        let item = session.request.item
        return HStack(alignment: .top, spacing: 14) {
            Button(action: close) {
                Image(systemName: "chevron.backward")
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .help("Back (Esc)")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.type == "episode" ? item.showTitle : item.displayTitle)
                    .font(.title3.weight(.semibold))
                if item.type == "episode" {
                    Text([item.episodeCode, item.displayTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 4)
            Spacer()
            Button(action: controller.minimize) {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize Player")
            .help("Minimize Player (⌃⌘M)")
        }
        .padding(20)
        .foregroundStyle(.white)
    }

    // MARK: Contextual action

    @ViewBuilder
    private var contextualButton: some View {
        if let next = session.nextEpisode,
           session.upNextCountdown != nil || (!session.upNextDismissed && session.isNearEnd) {
            MacUpNextCard(session: session, next: next)
        } else if let marker = session.activeMarker {
            Button { session.skip(marker) } label: {
                Label("Skip \(marker.displayName)", systemImage: marker.isCommunity ? "person.3.fill" : "forward.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: Controls

    private var duration: Double {
        player.duration > 0 ? player.duration : session.request.item.durationSeconds
    }

    private var position: Double { player.pendingSeekTarget ?? player.currentTime }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(Self.format(scrubbing ?? position))
                    .monospacedDigit()
                Slider(
                    value: Binding(get: { min(scrubbing ?? position, max(duration, 1)) },
                                   set: { scrubbing = $0 }),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        guard !editing, let target = scrubbing else { return }
                        scrubbing = nil
                        Task { await player.seek(to: target) }
                    }
                )
                .controlSize(.small)
                Text("-" + Self.format(max(0, duration - (scrubbing ?? position))))
                    .monospacedDigit()
            }
            .font(.caption)

            // A shrunken window drops the volume slider first, then folds the panes into one menu.
            ViewThatFits(in: .horizontal) {
                buttonRow(spacing: 16, volumeSlider: true, foldPanes: false)
                buttonRow(spacing: 12, volumeSlider: false, foldPanes: false)
                buttonRow(spacing: 10, volumeSlider: false, foldPanes: true)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 980)
    }

    private var visiblePanes: [MacPlayerPane] {
        MacPlayerPane.allCases.filter { $0 != .chapters || !session.chapters.isEmpty }
    }

    private func buttonRow(spacing: CGFloat, volumeSlider: Bool, foldPanes: Bool) -> some View {
        HStack(spacing: spacing) {
                Button { Task { await player.skip(by: -Double(skipBack)) } } label: {
                    Image(systemName: "gobackward.\(skipBack)")
                }
                .accessibilityLabel("Back \(skipBack) Seconds")
                .help("Back \(skipBack) Seconds (←)")
                Button(action: player.togglePlayPause) {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 26)
                }
                .accessibilityLabel(player.state == .playing ? "Pause" : "Play")
                .help(player.state == .playing ? "Pause (Space)" : "Play (Space)")
                Button { Task { await player.skip(by: Double(skipForward)) } } label: {
                    Image(systemName: "goforward.\(skipForward)")
                }
                .accessibilityLabel("Forward \(skipForward) Seconds")
                .help("Forward \(skipForward) Seconds (→)")
                if session.nextEpisode != nil {
                    Button { session.playNext() } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("Next Episode")
                        .help("Next Episode")
                }

                Spacer()

                trackMenus
                qualityMenu
                speedMenu

                if foldPanes {
                    Menu {
                        ForEach(visiblePanes) { pane in
                            Toggle(pane.rawValue, isOn: Binding(get: { session.pane == pane },
                                                                set: { session.pane = $0 ? pane : nil }))
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Info")
                    .help("Info")
                } else {
                    ForEach(visiblePanes) { pane in
                        Button { session.pane = session.pane == pane ? nil : pane } label: {
                            Image(systemName: pane.icon)
                                .foregroundStyle(session.pane == pane ? Color.accentColor : .primary)
                        }
                        .accessibilityLabel(pane.rawValue)
                        .help(pane.rawValue)
                    }
                }

                Button { player.setMuted(!player.isMuted) } label: {
                    Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20)
                }
                .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
                .help(player.isMuted ? "Unmute" : "Mute")
                if volumeSlider {
                    Slider(value: Binding(get: { Double(player.isMuted ? 0 : player.volume) },
                                          set: { player.setVolume(Float($0)) }),
                           in: 0...1)
                        .frame(width: 90)
                        .controlSize(.small)
                }

                MacAirPlayButton(player: player.airPlayPlayer)
                    .frame(width: 24, height: 24)
                    .help(player.airPlayPlayer == nil
                          ? "AirPlay: sound only at Original quality. Pick another quality to send the picture too."
                          : "AirPlay")

                Button { controller.startPictureInPicture() } label: {
                    Image(systemName: "pip.enter")
                }
                .disabled(!controller.isPictureInPicturePossible)
                .accessibilityLabel("Picture in Picture")
                .help("Picture in Picture (⌃⌘P)")

                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Full Screen")
                .help("Full Screen")
        }
        .font(.title3)
    }

    @ViewBuilder
    private var trackMenus: some View {
        if session.audioTracks.count > 1 {
            Menu {
                ForEach(session.audioTracks) { track in
                    Toggle(isOn: Binding(get: { session.selectedAudioID == track.id },
                                         set: { if $0 { session.selectAudio(track.id) } })) {
                        Text(track.name)
                        if !track.detail.isEmpty { Text(track.detail) }
                    }
                }
            } label: {
                Image(systemName: "speaker.wave.2.bubble")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Audio")
            .help("Audio")
        }

        if !session.subtitleTracks.isEmpty {
            Menu {
                Toggle("Off", isOn: Binding(get: { session.selectedSubtitleID == nil },
                                            set: { if $0 { session.selectSubtitle(nil) } }))
                Divider()
                ForEach(session.subtitleTracks) { track in
                    Toggle(isOn: Binding(get: { session.selectedSubtitleID == track.id },
                                         set: { if $0 { session.selectSubtitle(track.id) } })) {
                        Text(track.name)
                        if !track.detail.isEmpty { Text(track.detail) }
                    }
                }
            } label: {
                Image(systemName: session.selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Subtitles")
            .help("Subtitles")
        }
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(StreamingQuality.allChoices, id: \.self) { quality in
                Toggle(quality.label, isOn: Binding(get: { session.request.quality == quality },
                                                    set: { if $0 { session.switchQuality(quality) } }))
            }
        } label: {
            Text(session.qualityLabel).font(.caption.weight(.semibold))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Quality")
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { speed in
                Toggle(Self.speedLabel(speed), isOn: Binding(get: { player.rate == speed },
                                                             set: { if $0 { player.setRate(speed) } }))
            }
        } label: {
            Text(Self.speedLabel(player.rate)).font(.caption.weight(.semibold))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Speed")
    }

    // MARK: Helpers

    private static func speedLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func showControls() {
        controlsVisible = true
        scheduleHide(after: .seconds(3))
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, player.state == .playing, scrubbing == nil else { return }
            controlsVisible = false
        }
    }
}
