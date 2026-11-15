// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Observation

/// App-level owner of the music playing: the queue, the player, and what
/// Plex hears about it. Music plays under everything else. Starting it stops
/// Live TV (`onStart`); starting a film, an episode or a channel pauses it.
@MainActor
@Observable
final class MacMusicPlayback {
    /// What radio keeps adding to the queue from.
    enum Radio: Equatable {
        /// Tracks like the one playing.
        case similar
        /// Anything from a library.
        case library(String)
    }

    static let loudnessKey = "musicLoudnessLevelling"
    /// Seconds of crossfade between songs; 0 is off.
    static let crossfadeKey = "musicCrossfadeSeconds"

    let player = MacMusicPlayer()
    @ObservationIgnored private let output = MacAudioOutput()
    private(set) var queue = MusicQueue()
    private(set) var radio: Radio?
    /// A track that could not be played, shown in the bar until the next one starts.
    private(set) var problem: String?
    /// The sound output's rate and depth for the playing track, e.g. "96 kHz · 24-bit".
    private(set) var outputDescription: String?
    /// The full Now Playing view is open.
    var isNowPlayingShown = false

    /// Needed to fetch and report; the app sets it.
    @ObservationIgnored weak var plex: MacPlexSession? {
        didSet { precache.plex = plex }
    }
    @ObservationIgnored var onStart: (() -> Void)?

    /// The playing track's source, with its full metadata.
    private(set) var current: MacMusicSource?
    @ObservationIgnored private var next: MacMusicSource?
    /// The playing track's downloaded file, for when its stream stalls.
    @ObservationIgnored private var currentFile: (id: UUID, url: URL)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var nextTask: Task<Void, Never>?
    @ObservationIgnored private var refillTask: Task<Void, Never>?
    @ObservationIgnored private var observationTasks: [Task<Void, Never>] = []
    @ObservationIgnored private let precache = MacMusicPrecache()
    @ObservationIgnored private var reportedStopped = true
    @ObservationIgnored private var lastReportBucket = -1
    /// Where a restored queue's track picks up; set until it is first played.
    @ObservationIgnored private var resumeTime: TimeInterval?
    /// The saved queue has been looked at this launch, so saving may replace it.
    @ObservationIgnored private var hasRestored = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        player.onAdvance = { [weak self] in self?.playerAdvanced(to: $0) }
        player.onFailure = { [weak self] in self?.playerFailed($0) }
        precache.onCached = { [weak self] in self?.precached($0, file: $1) }
        observePlayer()
        Task { await MacMusicCache.shared.purgeLeftovers() }
    }

    /// The track playing or paused, nil when nothing is queued.
    var track: PlexMetadata? { current?.track ?? queue.current?.track }
    /// Playing, or about to: the play/pause buttons show Pause.
    var isPlaying: Bool { player.state == .playing || (player.state == .loading && player.wantsToPlay) }
    /// Something is loaded, playing or not.
    var isActive: Bool { queue.current != nil }

    // MARK: - Starting

    /// Plays `tracks` from `index`. An album in order keeps its album gain.
    func play(_ tracks: [PlexMetadata], from index: Int = 0, shuffled: Bool = false, isAlbum: Bool = false) {
        guard !tracks.isEmpty else { return }
        radio = nil
        queue.replace(with: tracks, startIndex: shuffled ? Int.random(in: tracks.indices) : index,
                      shuffled: shuffled, isAlbum: isAlbum)
        loadCurrent()
    }

    /// Plays the track, then keeps going with tracks that sound like it.
    func startRadio(from seed: PlexMetadata) {
        queue.replace(with: [seed], isRadio: true)
        radio = .similar
        loadCurrent()
    }

    /// Shuffles a whole library, endlessly.
    func startLibraryRadio(_ library: PlexLibrary) {
        guard let plex else { return }
        radio = .library(library.key)
        problem = nil
        Task {
            let tracks = await plex.randomTracks(sectionKey: library.key)
            guard radio == .library(library.key), !tracks.isEmpty else { return }
            queue.replace(with: tracks, isRadio: true)
            loadCurrent()
        }
    }

    func playNext(_ tracks: [PlexMetadata]) {
        let wasEmpty = queue.isEmpty
        queue.playNext(tracks)
        wasEmpty ? loadCurrent() : queueChanged()
    }

    func addToQueue(_ tracks: [PlexMetadata]) {
        let wasEmpty = queue.isEmpty
        queue.append(tracks)
        wasEmpty ? loadCurrent() : queueChanged()
    }

    // MARK: - Saved queue

    /// The server and profile the queue belongs to.
    private var owner: String {
        let server = PlexAuthManager.shared.savedServerName ?? ""
        let profile = PlexUserProfileManager.shared.selectedUserId.map(String.init) ?? ""
        return "\(server)|\(profile)"
    }

    /// Brings back the queue from the last launch, paused where it stopped.
    /// Nothing is fetched until Play is pressed. Once per launch.
    func restoreQueue() {
        guard !hasRestored else { return }
        hasRestored = true
        guard queue.isEmpty, let saved = MacMusicQueueStore.read() else { return }
        guard saved.owner == owner, !saved.queue.tracks.isEmpty else {
            MacMusicQueueStore.clear()
            return
        }
        queue = MusicQueue(saved.queue)
        if let radio = saved.radio {
            self.radio = radio == "similar" ? .similar : radio.hasPrefix("library:") ? .library(String(radio.dropFirst(8))) : nil
        }
        guard let entry = queue.current else { return }
        let time = UserDefaults.standard.double(forKey: MacMusicQueueStore.positionKey)
        let length = entry.track.durationSeconds
        // A track left in its last seconds starts over.
        resumeTime = length > 0 && time > length - 5 ? 0 : max(time, 0)
        player.showPaused(entry.id, duration: length, at: resumeTime ?? 0)
    }

    private func scheduleSave() {
        guard hasRestored else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveQueue(waiting: false)
        }
    }

    /// Writes the queue and the position. `waiting` holds the caller until the
    /// file is down, for a quit.
    private func saveQueue(waiting: Bool) {
        guard hasRestored else { return }
        saveTask?.cancel()
        guard let saved = queue.saved() else {
            MacMusicQueueStore.clear()
            return
        }
        savePosition()
        let radioName: String? = switch radio {
        case .similar: "similar"
        case .library(let key): "library:\(key)"
        case nil: nil
        }
        let record = MacMusicSavedQueue(owner: owner, queue: saved, radio: radioName)
        if waiting {
            MacMusicQueueStore.write(record)
        } else {
            Task.detached(priority: .utility) { MacMusicQueueStore.write(record) }
        }
    }

    private func savePosition() {
        guard hasRestored, queue.current != nil else { return }
        UserDefaults.standard.set(resumeTime ?? player.currentTime, forKey: MacMusicQueueStore.positionKey)
    }

    /// Quitting: the queue is kept for next time, and Plex hears the track stopped.
    @discardableResult
    func quit() -> Task<Void, Never>? {
        saveQueue(waiting: true)
        return stop(keepingSavedQueue: true)
    }

    // MARK: - Transport

    func togglePlayPause() {
        // A restored queue loads its track on the first Play.
        if let time = resumeTime, isActive {
            loadCurrent(at: time)
            return
        }
        switch player.state {
        case .ended, .failed, .idle:
            if isActive { loadCurrent() }
        default:
            player.togglePlayPause()
        }
    }

    func resume() {
        guard player.state != .playing else { return }
        togglePlayPause()
    }

    /// Other playback took over; the queue stays for later.
    func pause() {
        if player.state == .playing || player.state == .loading { player.pause() }
    }

    func seek(to time: TimeInterval) {
        if resumeTime != nil { resumeTime = max(time, 0) }
        player.seek(to: time)
        report(player.state == .playing ? "playing" : "paused")
    }

    func skipToNext() {
        guard queue.skipToNext() != nil else { return }
        loadCurrent()
    }

    /// A few seconds in, Previous restarts the track; otherwise it goes back one.
    func skipToPrevious() {
        if player.currentTime > 3 || !queue.hasPrevious {
            seek(to: 0)
            return
        }
        queue.skipToPrevious()
        loadCurrent()
    }

    func jump(to entry: MusicQueue.Entry) {
        guard queue.jump(to: entry.id) != nil else { return }
        loadCurrent()
    }

    func remove(_ entry: MusicQueue.Entry) {
        queue.remove(entry.id)
        queueChanged()
    }

    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.moveUpNext(fromOffsets: source, toOffset: destination)
        queueChanged()
    }

    func setShuffled(_ on: Bool) {
        queue.setShuffled(on)
        queueChanged()
    }

    func cycleRepeat() {
        let modes = MusicQueue.RepeatMode.allCases
        queue.repeatMode = modes[(modes.firstIndex(of: queue.repeatMode)! + 1) % modes.count]
        queueChanged()
    }

    /// Stops and empties the queue. The task ends once Plex has the final report.
    @discardableResult
    func stop(keepingSavedQueue: Bool = false) -> Task<Void, Never>? {
        let reported = finishCurrent()
        saveTask?.cancel()
        resumeTime = nil
        // Stop means the queue is done with; before the saved one was looked at
        // (a locked profile at launch) there is nothing of this launch's to forget.
        if keepingSavedQueue {
            // Kept for the next launch, or for this profile once it is back in.
            hasRestored = false
        } else if hasRestored {
            MacMusicQueueStore.clear()
        }
        generation += 1
        loadTask?.cancel()
        nextTask?.cancel()
        refillTask?.cancel()
        player.stop()
        precache.stop()
        output.restore()
        outputDescription = nil
        Task { await MacMusicCache.shared.trim() }
        queue.clear()
        radio = nil
        current = nil
        next = nil
        problem = nil
        isNowPlayingShown = false
        return reported
    }

    // MARK: - Loading

    /// Opens the queue's current entry. A direct-play file that fails gets
    /// one more try as a transcode.
    private func loadCurrent(forceTranscode: Bool = false, at time: TimeInterval = 0) {
        guard let plex, let entry = queue.current else { return }
        finishCurrent()
        resumeTime = nil
        hasRestored = true
        generation += 1
        let generation = generation
        loadTask?.cancel()
        nextTask?.cancel()
        current = nil
        next = nil
        problem = nil
        player.prepare(entry.id, duration: entry.track.durationSeconds)
        onStart?()
        loadTask = Task {
            do {
                let source = try await plex.musicSource(for: entry.id, track: entry.track, forceTranscode: forceTranscode)
                guard generation == self.generation else { return }
                current = source
                await output.apply(for: source)
                guard generation == self.generation else { return }
                outputDescription = output.describe()
                reportedStopped = false
                lastReportBucket = -1
                // A pause while the track was being fetched holds.
                player.load(source, gain: gain(for: source), at: time, autoplay: player.wantsToPlay)
                queueChanged()
            } catch {
                guard generation == self.generation, !isCancellationError(error) else { return }
                skipUnplayable(entry)
            }
        }
    }

    /// The queued follow-on no longer matches the queue: queue the right one.
    private func queueChanged() {
        defer { updatePrecache() }
        scheduleSave()
        refillRadioIfNeeded()
        guard let current else { return }
        let wanted = queue.entryAfterCurrent
        if let next, next.entryID == wanted?.id, player.nextID == next.entryID {
            return
        }
        nextTask?.cancel()
        next = nil
        player.setNext(nil, gain: 1)
        guard let wanted, let plex else { return }
        let generation = generation
        // Repeat One queues the same file again.
        if wanted.id == current.entryID {
            next = current
            player.setNext(current, gain: gain(for: current))
            return
        }
        nextTask = Task {
            guard let source = try? await plex.musicSource(for: wanted.id, track: wanted.track),
                  generation == self.generation, queue.entryAfterCurrent?.id == wanted.id else { return }
            next = source
            player.setNext(source, gain: gain(for: source), crossfade: crossfade(into: source))
        }
    }

    /// How long `next` fades in under the end of the playing track; 0 for none.
    /// An album's own run of tracks stays gapless, as it was mastered. Songs
    /// too short to carry a fade are cut as before, and so is everything while
    /// the output's sample rate follows the music: retuning the device mid-fade clicks.
    private func crossfade(into next: MacMusicSource) -> TimeInterval {
        let seconds = TimeInterval(UserDefaults.standard.integer(forKey: Self.crossfadeKey))
        guard seconds > 0, let current, next.entryID != current.entryID,
              MusicOutputRate.setting == MusicOutputRate.dontChange else { return 0 }
        let (playing, coming) = (current.track, next.track)
        if let album = playing.parentRatingKey, album == coming.parentRatingKey,
           (playing.parentIndex ?? 1) == (coming.parentIndex ?? 1),
           let index = playing.index, coming.index == index + 1 {
            return 0
        }
        guard playing.durationSeconds > seconds * 3, coming.durationSeconds > seconds * 3 else { return 0 }
        return seconds
    }

    /// While the track is starting or stalled only its own file downloads: a
    /// whole-file fetch outruns AVPlayer's stream, and the file then takes over.
    private func updatePrecache() {
        let waiting = player.state == .loading
        precache.update(
            current: current,
            upcoming: waiting ? [] : queue.upcoming(MacMusicPrecache.count),
            canDownload: current != nil && (waiting || player.state == .playing || player.state == .paused))
    }

    /// The playing track's file has arrived while its stream is not keeping up
    /// (or has not started): play the file from the same place.
    private func playCurrentFromFile() {
        guard let current, !current.isCached, let file = currentFile, file.id == current.entryID else { return }
        currentFile = nil
        let cached = current.withURL(file.url)
        self.current = cached
        next = nil
        player.load(cached, gain: gain(for: cached), at: player.currentTime, autoplay: player.wantsToPlay)
        queueChanged()
    }

    /// A queued song finished downloading: swap its network URL for the file,
    /// unless it is about to start.
    private func precached(_ id: UUID, file: URL) {
        if let current, current.entryID == id, !current.isCached {
            // Left alone while it plays; a later stall picks the file up.
            currentFile = (id, file)
            if player.state != .playing { playCurrentFromFile() }
            return
        }
        guard let next, next.entryID == id, !next.isCached, player.nextID == id,
              player.duration - player.currentTime > 10 else { return }
        let cached = next.withURL(file)
        self.next = cached
        player.setNext(cached, gain: gain(for: cached), crossfade: crossfade(into: cached))
    }

    private func gain(for source: MacMusicSource) -> Float {
        let levelling = UserDefaults.standard.object(forKey: Self.loudnessKey) as? Bool ?? true
        guard levelling else { return 1 }
        return LoudnessLevelling.volume(for: source.track.audioStream, preferAlbum: queue.prefersAlbumGain)
    }

    /// Moves past a track the server would not hand over.
    private func skipUnplayable(_ entry: MusicQueue.Entry) {
        problem = "Couldn't play \(entry.track.displayTitle)."
        guard queue.current?.id == entry.id, queue.skipToNext() != nil else {
            player.stop()
            return
        }
        loadCurrent()
    }

    // MARK: - Player events

    private func playerAdvanced(to id: UUID) {
        finishCurrent(completed: true)
        // The follow-on is the queue's next entry (or the same one, under Repeat One).
        if queue.entryAfterCurrent?.id == id {
            queue.advance()
        } else {
            queue.jump(to: id)
        }
        if let next, next.entryID == id {
            current = next
        }
        next = nil
        reportedStopped = false
        lastReportBucket = -1
        problem = nil
        report("playing")
        queueChanged()
        if let current {
            Task {
                await output.apply(for: current)
                outputDescription = output.describe()
            }
        }
    }

    /// Nothing was queued behind the track that finished: the queue ran
    /// out, or its next track was not ready in time.
    private func playerRanOut() {
        finishCurrent(completed: true)
        guard queue.entryAfterCurrent != nil else { return }
        queue.advance()
        loadCurrent()
    }

    private func playerFailed(_ id: UUID) {
        if let current, current.entryID == id {
            guard let entry = queue.current, entry.id == id else { return }
            if current.isCached {
                // The kept file is bad: forget it and play from the server.
                let time = player.currentTime
                let generation = generation
                let key = current.cacheKey
                Task {
                    if let key { await MacMusicCache.shared.remove(key) }
                    guard generation == self.generation, queue.current?.id == id else { return }
                    loadCurrent(at: time)
                }
            } else if current.isTranscode {
                skipUnplayable(entry)
            } else {
                loadCurrent(forceTranscode: true, at: player.currentTime)
            }
        } else if let next, next.entryID == id {
            self.next = nil
            player.setNext(nil, gain: 1)
            guard !next.isTranscode, let plex, let wanted = queue.entryAfterCurrent, wanted.id == id else { return }
            let generation = generation
            let wasCached = next.isCached
            let key = next.cacheKey
            nextTask = Task {
                if wasCached, let key { await MacMusicCache.shared.remove(key) }
                guard let source = try? await plex.musicSource(for: wanted.id, track: wanted.track, forceTranscode: !wasCached),
                      generation == self.generation, queue.entryAfterCurrent?.id == wanted.id else { return }
                self.next = source
                player.setNext(source, gain: gain(for: source), crossfade: crossfade(into: source))
            }
        }
    }

    // MARK: - Radio

    private func refillRadioIfNeeded() {
        guard let radio, let plex, refillTask == nil, queue.radioRemaining < 5, let seed = track else { return }
        let played = Set(queue.entries.compactMap(\.track.ratingKey))
        refillTask = Task {
            defer { refillTask = nil }
            let candidates: [PlexMetadata]
            switch radio {
            case .similar:
                candidates = await plex.radioTracks(after: seed, sectionKey: current?.track.librarySectionID.map(String.init))
            case .library(let key):
                candidates = await plex.randomTracks(sectionKey: key)
            }
            guard self.radio == radio else { return }
            var seen = played
            let fresh = candidates.shuffled().filter { $0.ratingKey.map { seen.insert($0).inserted } ?? false }
            guard !fresh.isEmpty else { return }
            queue.append(Array(fresh.prefix(15)), isRadio: true)
            queueChanged()
        }
    }

    // MARK: - Plex reporting

    private func observePlayer() {
        let player = player
        observationTasks.append(Task { [weak self] in
            var last: MacMusicPlayer.State?
            for await state in Observations({ player.state }) {
                if state == last { continue }
                last = state
                self?.stateChanged(state)
            }
        })
        observationTasks.append(Task { [weak self] in
            for await time in Observations({ player.currentTime }) {
                self?.tick(time)
            }
        })
    }

    private func stateChanged(_ state: MacMusicPlayer.State) {
        updatePrecache()
        switch state {
        case .playing: report("playing")
        case .paused:
            report("paused")
            savePosition()
        case .ended: playerRanOut()
        case .loading: playCurrentFromFile()
        default: break
        }
    }

    private func tick(_ time: TimeInterval) {
        guard player.state == .playing else { return }
        let bucket = Int(time) / 10
        if bucket != lastReportBucket {
            lastReportBucket = bucket
            report("playing")
            savePosition()
        }
    }

    private func report(_ state: String) {
        guard !reportedStopped, let current, let plex else { return }
        let time = player.currentTime
        Task { await plex.reportMusic(current, time: time, state: state) }
    }

    /// Stopped, then a play counted when the track got past the watched
    /// ceiling. `completed` is a track that played to its end.
    @discardableResult
    private func finishCurrent(completed: Bool = false) -> Task<Void, Never>? {
        guard !reportedStopped, let current, let plex else { return nil }
        reportedStopped = true
        let runtime = current.track.durationSeconds > 0 ? current.track.durationSeconds : player.duration
        let time = completed ? runtime : player.currentTime
        let played = completed || (WatchProgressPolicy.progress(offsetSeconds: time, runtimeSeconds: runtime) ?? 0)
            >= WatchProgressPolicy.completionThreshold
        return Task {
            await plex.reportMusic(current, time: time, state: "stopped")
            await plex.finishMusic(current, played: played)
        }
    }
}
