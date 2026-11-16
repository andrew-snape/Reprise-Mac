// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import Combine
import Foundation
import Observation

/// Music through AVQueuePlayer: the playing track plus the next one already
/// queued, so an album plays without gaps between tracks. AetherPlayer stays
/// video only; AVFoundation opens every common audio format itself.
///
/// A crossfade needs two tracks sounding at once, which one queue player cannot
/// do. A track that is to fade in waits on a second player instead of in the
/// queue; near the end of the playing one the two swap roles and their volumes
/// cross. With no crossfade asked for, the second player is never made.
///
/// The player knows nothing of the queue. `MacMusicPlayback` loads a track,
/// queues the next, and hears back when playback moved on, ended or failed.
@MainActor
@Observable
final class MacMusicPlayer {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        /// The last queued track finished.
        case ended
        case failed
    }

    private(set) var state: State = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// The queue entry audible now.
    private(set) var currentID: UUID?
    /// Bumped by every seek, so Now Playing can resync its clock.
    private(set) var seekCount = 0
    private(set) var volume: Float = 1
    private(set) var isMuted = false
    /// Play was pressed (or a track started) and not paused since, loaded or not.
    private(set) var wantsToPlay = false

    /// The playing track finished and the queued one took over.
    @ObservationIgnored var onAdvance: ((UUID) -> Void)?
    /// A track could not be opened or stopped partway.
    @ObservationIgnored var onFailure: ((UUID) -> Void)?

    private struct Loaded {
        let item: AVPlayerItem
        let id: UUID
        let gain: Float
        let duration: TimeInterval
        var observations: [AnyCancellable]
    }

    /// The player that is audible, or the one fading in.
    @ObservationIgnored private var player = AVQueuePlayer()
    /// The player the AirPlay button binds to when AirPlay goes from the player
    /// (`MacAirPlayRoute`). Crossfade swaps players, so it is off meanwhile.
    var airPlayPlayer: AVPlayer { player }
    @ObservationIgnored private var loaded: [ObjectIdentifier: Loaded] = [:]
    @ObservationIgnored private var currentItem: ObjectIdentifier?
    @ObservationIgnored private var playerObservations: [AnyCancellable] = []
    @ObservationIgnored private var clocks: [Any] = []

    // Crossfade
    /// The other player: idle, holding the track that will fade in, or fading out.
    @ObservationIgnored private var spare: AVQueuePlayer?
    /// The track waiting on `spare`, and how long its fade in is to be.
    @ObservationIgnored private var standby: (item: ObjectIdentifier, fade: TimeInterval)?
    /// The track fading out on `spare`, and where its music ends (its length without cues).
    @ObservationIgnored private var outgoing: (item: ObjectIdentifier?, gain: Float, end: TimeInterval)?
    /// Each analysed entry's start, end and last bars (`MacMusicCues`). Without
    /// them a crossfade runs on the file's own length, as it always did.
    @ObservationIgnored private var cues: [UUID: MusicCues] = [:]
    /// A follow-on asked for while `spare` was still fading out; set once it is free.
    @ObservationIgnored private var deferredNext: (source: MacMusicSource, gain: Float, fade: TimeInterval)?
    /// 0 as a fade starts, 1 when it is over.
    @ObservationIgnored private var fadeProgress: Double = 1
    @ObservationIgnored private var fadeTask: Task<Void, Never>?

    init() {
        playerObservations = [
            Self.onMain(Self.items(posting: AVPlayerItem.didPlayToEndTimeNotification)) { [weak self] in
                self?.itemEnded($0)
            },
            Self.onMain(Self.items(posting: AVPlayerItem.failedToPlayToEndTimeNotification)) { [weak self] in
                self?.itemFailed($0)
            },
        ]
        observe(player)
    }

    /// Events count only from the player that is in front at the time.
    private func observe(_ observed: AVQueuePlayer) {
        observed.actionAtItemEnd = .advance
        let id = ObjectIdentifier(observed)
        playerObservations.append(Self.onMain(Self.currentItems(of: observed)) { [weak self] in
            guard let self, id == ObjectIdentifier(self.player) else { return }
            self.currentItemChanged($0)
        })
        playerObservations.append(Self.onMain(Self.timeControlChanges(of: observed)) { [weak self] _ in
            guard let self, id == ObjectIdentifier(self.player) else { return }
            self.updateState()
        })
        clocks.append(Self.addClock(to: observed) { [weak self] seconds in
            guard let self, id == ObjectIdentifier(self.player) else { return }
            self.clockTicked(seconds)
        })
    }

    // MARK: - Loading

    /// Replaces everything with `source`, starting at `time`.
    func load(_ source: MacMusicSource, gain: Float, at time: TimeInterval = 0, autoplay: Bool = true) {
        clear()
        let entry = makeItem(for: source, gain: gain)
        currentItem = ObjectIdentifier(entry.item)
        currentID = source.entryID
        duration = entry.duration
        currentTime = time
        player.insert(entry.item, after: nil)
        if time > 0 { seek(to: time) }
        applyVolume()
        wantsToPlay = autoplay
        state = .loading
        if autoplay { startPlaying() } else { player.pause() }
        updateState()
    }

    /// Shows `id` as loading while its URL is worked out.
    func prepare(_ id: UUID, duration: TimeInterval) {
        clear()
        currentID = id
        currentTime = 0
        self.duration = duration
        wantsToPlay = true
        state = .loading
    }

    /// A restored queue's track, shown paused before anything is loaded.
    func showPaused(_ id: UUID, duration: TimeInterval, at time: TimeInterval) {
        clear()
        currentID = id
        self.duration = duration
        currentTime = duration > 0 ? min(max(time, 0), duration) : max(time, 0)
        state = .paused
    }

    /// Queues `source` to follow the current track, replacing what was queued.
    /// With `crossfade` seconds it fades in under the end of the current track
    /// instead of following it without a gap.
    func setNext(_ source: MacMusicSource?, gain: Float, crossfade: TimeInterval = 0) {
        for item in player.items() where ObjectIdentifier(item) != currentItem {
            player.remove(item)
            loaded[ObjectIdentifier(item)] = nil
        }
        clearStandby()
        deferredNext = nil
        guard let source, let current = player.currentItem else { return }
        guard crossfade > 0 else {
            let entry = makeItem(for: source, gain: gain)
            player.insert(entry.item, after: current)
            return
        }
        // The other player is still fading the last track out.
        if outgoing != nil {
            deferredNext = (source, gain, crossfade)
            return
        }
        let waiting = sparePlayer()
        let entry = makeItem(for: source, gain: gain)
        waiting.volume = 0
        waiting.insert(entry.item, after: nil)
        waiting.pause()
        standby = (ObjectIdentifier(entry.item), crossfade)
    }

    /// The queued track's entry, if one is queued.
    var nextID: UUID? {
        if let standby { return loaded[standby.item]?.id }
        if let deferredNext { return deferredNext.source.entryID }
        return player.items().dropFirst().first.flatMap { loaded[ObjectIdentifier($0)]?.id }
    }

    private func sparePlayer() -> AVQueuePlayer {
        if let spare { return spare }
        let made = AVQueuePlayer()
        observe(made)
        spare = made
        return made
    }

    private func clearStandby() {
        guard let standby else { return }
        spare?.removeAllItems()
        loaded[standby.item] = nil
        self.standby = nil
    }

    // MARK: - Crossfade

    /// Cues for an entry, from `MacMusicCues`. Kept only for the entries in play.
    func setCues(_ found: MusicCues, for id: UUID) {
        let keep = Set([currentID, nextID].compactMap { $0 })
        guard keep.contains(id) else { return }
        cues = cues.filter { keep.contains($0.key) }
        cues[id] = found
    }

    /// Called on each clock tick: starts the fade once the playing track has no
    /// more left than the fade is long, and the waiting track can start at once.
    /// With cues the fade ends where the music does and starts on a bar line.
    private func beginFadeIfDue() {
        guard let standby, outgoing == nil, wantsToPlay, duration > 0 else { return }
        let marks = currentID.flatMap { cues[$0] }
        let end = min(marks?.end ?? duration, duration)
        let start = marks?.fadeStart(for: standby.fade) ?? end - standby.fade
        let remaining = end - currentTime
        guard currentTime >= start, remaining > 0.3,
              spare?.currentItem?.status == .readyToPlay else { return }
        swapToStandby(fade: remaining, end: end)
    }

    /// The waiting track takes over as the current one. With a `fade`, the track
    /// it replaces plays out underneath; with none it is cut, as when the waiting
    /// track was not ready in time.
    private func swapToStandby(fade: TimeInterval, end: TimeInterval? = nil) {
        guard let standby, let incoming = spare, let entry = loaded[standby.item] else { return }
        let previous = player
        let previousItem = currentItem
        self.standby = nil
        spare = previous
        player = incoming
        if fade > 0 {
            outgoing = (previousItem, previousItem.flatMap { loaded[$0]?.gain } ?? 1, end ?? duration)
            fadeProgress = 0
        } else {
            previous.pause()
            previous.removeAllItems()
            if let previousItem { loaded[previousItem] = nil }
        }
        currentItem = standby.item
        currentID = entry.id
        duration = entry.duration
        currentTime = 0
        // In at its first sound, past any leading silence, once it can seek.
        if let start = cues[entry.id]?.start, start > 0,
           incoming.currentItem?.status == .readyToPlay {
            incoming.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = start
        }
        applyVolume()
        if wantsToPlay { startPlaying() }
        updateState()
        onAdvance?(entry.id)
        if fade > 0 { runFade(over: fade) }
    }

    /// Crosses the two volumes on equal-power curves. Progress follows the
    /// outgoing track's own clock, so a pause holds the fade where it is.
    private func runFade(over length: TimeInterval) {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            var playedFor: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, !Task.isCancelled, let outgoing = self.outgoing, let fading = self.spare else { return }
                if self.wantsToPlay { playedFor += 0.03 }
                let time = fading.currentTime().seconds
                // Ended, or stalled on its last seconds: the new track is not held quiet for it.
                if fading.currentItem == nil || playedFor > length + 2 {
                    self.fadeProgress = 1
                } else if time.isFinite {
                    self.fadeProgress = max(self.fadeProgress, min(1 - (outgoing.end - time) / length, 1))
                }
                self.applyVolume()
                if self.fadeProgress >= 1 {
                    self.finishFade()
                    return
                }
            }
        }
    }

    private func finishFade() {
        fadeTask?.cancel()
        fadeTask = nil
        if let outgoing {
            spare?.pause()
            spare?.removeAllItems()
            if let item = outgoing.item { loaded[item] = nil }
        }
        outgoing = nil
        fadeProgress = 1
        applyVolume()
        if let next = deferredNext {
            deferredNext = nil
            setNext(next.source, gain: next.gain, crossfade: next.fade)
        }
    }

    /// Stops and forgets every track.
    func stop() {
        clear()
        currentID = nil
        currentTime = 0
        duration = 0
        state = .idle
    }

    private func clear() {
        wantsToPlay = false
        fadeTask?.cancel()
        fadeTask = nil
        outgoing = nil
        standby = nil
        deferredNext = nil
        cues = [:]
        fadeProgress = 1
        spare?.pause()
        spare?.removeAllItems()
        player.pause()
        player.removeAllItems()
        loaded = [:]
        currentItem = nil
    }

    private func makeItem(for source: MacMusicSource, gain: Float) -> Loaded {
        let asset = AVURLAsset(url: source.url)
        // Same trust as the Plex API session: a raw-IP or private certificate plays.
        if !source.url.isFileURL {
            asset.resourceLoader.setDelegate(MacMusicTrust.shared, queue: MacMusicTrust.queue)
        }
        let item = AVPlayerItem(asset: asset)
        let id = ObjectIdentifier(item)
        let entry = Loaded(
            item: item,
            id: source.entryID,
            gain: gain,
            duration: source.track.duration.map { TimeInterval($0) / 1000 } ?? 0,
            observations: [
                Self.onMain(Self.failures(of: item)) { [weak self] _ in
                    self?.itemFailed(id)
                },
                Self.onMain(Self.durations(of: item)) { [weak self] seconds in
                    guard let self, seconds.isFinite, seconds > 0, self.currentItem == id else { return }
                    self.duration = seconds
                },
            ]
        )
        loaded[id] = entry
        return entry
    }

    // MARK: - Transport

    func play() {
        wantsToPlay = true
        guard player.currentItem != nil else { return }
        startPlaying()
        updateState()
    }

    /// Starts on the first data in. Plain `play()` holds a direct file back until
    /// AVPlayer predicts it can reach the end without stalling, which for a large
    /// lossless file is many seconds. A later stall still waits and resumes on its own.
    private func startPlaying() {
        player.playImmediately(atRate: 1)
        if outgoing != nil { spare?.play() }
    }

    func pause() {
        wantsToPlay = false
        player.pause()
        if outgoing != nil { spare?.pause() }
        updateState()
    }

    func togglePlayPause() {
        wantsToPlay ? pause() : play()
    }

    func seek(to time: TimeInterval) {
        let target = max(0, duration > 0 ? min(time, duration) : time)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        seekCount += 1
    }

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        applyVolume()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyVolume()
    }

    /// The user's volume times the playing track's levelling gain, and during a
    /// crossfade each track's share of it.
    private func applyVolume() {
        let gain = currentItem.flatMap { loaded[$0]?.gain } ?? 1
        guard let outgoing else {
            player.volume = volume * gain
            player.isMuted = isMuted
            return
        }
        let angle = fadeProgress * .pi / 2
        player.volume = volume * gain * Float(sin(angle))
        player.isMuted = isMuted
        spare?.volume = volume * outgoing.gain * Float(cos(angle))
        spare?.isMuted = isMuted
    }

    // MARK: - Events

    private func currentItemChanged(_ id: ObjectIdentifier?) {
        guard let id, id != currentItem, let entry = loaded[id] else { return }
        // The queued track took over. The one just finished stays known until
        // the next change, since its end notice may still be on its way.
        let queued = Set(player.items().map(ObjectIdentifier.init))
        for key in loaded.keys where key != currentItem && !queued.contains(key)
            && key != standby?.item && key != outgoing?.item { loaded[key] = nil }
        currentItem = id
        currentID = entry.id
        duration = entry.duration
        currentTime = 0
        applyVolume()
        updateState()
        onAdvance?(entry.id)
    }

    /// With a track queued after it, the advance reports the end; without
    /// one, playback has run out.
    private func itemEnded(_ id: ObjectIdentifier) {
        guard id == currentItem else { return }
        // The track that was to fade in was not ready in time: it follows on a cut.
        if standby != nil {
            swapToStandby(fade: 0)
            return
        }
        guard player.items().allSatisfy({ ObjectIdentifier($0) == id }) else { return }
        wantsToPlay = false
        currentTime = duration
        state = .ended
    }

    private func itemFailed(_ id: ObjectIdentifier) {
        guard let entry = loaded[id] else { return }
        if id == currentItem {
            wantsToPlay = false
            state = .failed
        }
        onFailure?(entry.id)
    }

    private func clockTicked(_ seconds: TimeInterval) {
        guard seconds.isFinite, currentItem != nil else { return }
        currentTime = max(0, seconds)
        beginFadeIfDue()
    }

    private func updateState() {
        guard currentItem != nil, state != .ended, state != .failed else { return }
        switch player.timeControlStatus {
        case .playing: state = .playing
        case .waitingToPlayAtSpecifiedRate: state = .loading
        case .paused: state = wantsToPlay ? .loading : .paused
        @unknown default: break
        }
    }

    // MARK: - Observation plumbing

    // Nonisolated on purpose: AVFoundation calls these from its own threads,
    // and a closure built in a main-actor method would trap on that isolation check.

    private nonisolated static func onMain<P: Publisher>(
        _ publisher: P,
        _ handle: @escaping @MainActor @Sendable (P.Output) -> Void
    ) -> AnyCancellable where P.Failure == Never, P.Output: Sendable {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { value in MainActor.assumeIsolated { handle(value) } }
    }

    private nonisolated static func items(posting name: Notification.Name) -> AnyPublisher<ObjectIdentifier, Never> {
        NotificationCenter.default.publisher(for: name)
            .compactMap { ($0.object as? AVPlayerItem).map(ObjectIdentifier.init) }
            .eraseToAnyPublisher()
    }

    private nonisolated static func currentItems(of player: AVQueuePlayer) -> AnyPublisher<ObjectIdentifier?, Never> {
        player.publisher(for: \.currentItem).map { $0.map(ObjectIdentifier.init) }.eraseToAnyPublisher()
    }

    private nonisolated static func timeControlChanges(of player: AVPlayer) -> AnyPublisher<Int, Never> {
        player.publisher(for: \.timeControlStatus).map(\.rawValue).eraseToAnyPublisher()
    }

    private nonisolated static func failures(of item: AVPlayerItem) -> AnyPublisher<Int, Never> {
        item.publisher(for: \.status)
            .filter { $0 == .failed }
            .map(\.rawValue)
            .eraseToAnyPublisher()
    }

    private nonisolated static func durations(of item: AVPlayerItem) -> AnyPublisher<TimeInterval, Never> {
        item.publisher(for: \.duration).map(\.seconds).eraseToAnyPublisher()
    }

    private nonisolated static func addClock(
        to player: AVPlayer,
        _ handle: @escaping @MainActor @Sendable (TimeInterval) -> Void
    ) -> Any {
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
            let seconds = time.seconds
            MainActor.assumeIsolated { handle(seconds) }
        }
    }
}

/// Answers AVFoundation's certificate challenges with the Plex API session's rule.
nonisolated final class MacMusicTrust: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = MacMusicTrust()
    static let queue = DispatchQueue(label: "Rivulet.MusicTrust")

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge
    ) -> Bool {
        let space = authenticationChallenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              PlexCertificateDelegate.trustsUnverifiedCertificate(for: space) else { return false }
        authenticationChallenge.sender?.use(URLCredential(trust: trust), for: authenticationChallenge)
        return true
    }
}
