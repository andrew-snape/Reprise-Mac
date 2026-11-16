// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct MacMusicSettings: View {
    @AppStorage(MacMusicPlayback.loudnessKey) private var loudnessLevelling = true
    @AppStorage(MacMusicPlayback.crossfadeKey) private var crossfade = 0
    @AppStorage(MusicInfoStore.enabledKey) private var onlineInfo = false
    @AppStorage(MacMusicCache.limitKey) private var cacheLimit = MacMusicCache.limitDefault
    @AppStorage(MacMusicPrecache.countKey) private var precacheCount = MacMusicPrecache.countDefault
    @AppStorage(MusicOutputRate.key) private var outputRate = MusicOutputRate.dontChange
    @State private var cacheSize: Int64 = 0
    @State private var deviceRates: [Int] = []

    var body: some View {
        Form {
            Section {
                Toggle("Loudness Levelling", isOn: $loudnessLevelling)
                Picker("Crossfade", selection: $crossfade) {
                    Text("Off").tag(0)
                    Text("2 Seconds").tag(2)
                    Text("4 Seconds").tag(4)
                    Text("6 Seconds").tag(6)
                    Text("8 Seconds").tag(8)
                }
                .disabled(outputRate != MusicOutputRate.dontChange)
            } header: {
                Text("Playback")
            } footer: {
                Text("Loudness Levelling evens out volume between tracks using your Plex server's analysis; an album played in order keeps its own quiet and loud songs. Crossfade blends each song into the next, except songs that run together on an album. Both apply from the next track. Crossfade needs Sample Rate set to Don't Change.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Sample Rate", selection: $outputRate) {
                    Text("Don't Change").tag(MusicOutputRate.dontChange)
                    Text("Match Each Track").tag(MusicOutputRate.matchTrack)
                    Divider()
                    ForEach(rateChoices, id: \.self) { Text(MusicOutputRate.label($0)).tag($0) }
                }
            } header: {
                Text("Output")
            } footer: {
                Text("Match Each Track sets your Mac's sound output to each song's sample rate, so it plays without conversion. This affects every app until music stops. Bluetooth and AirPlay keep their own rate, and a change of rate leaves a short gap.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep Downloaded Music", selection: $cacheLimit) {
                    Text("Off").tag(0)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("5 GB").tag(5120)
                    Text("10 GB").tag(10240)
                    Text("20 GB").tag(20480)
                    Text("50 GB").tag(51200)
                    Text("100 GB").tag(102400)
                }
                .onChange(of: cacheLimit) {
                    Task {
                        await MacMusicCache.shared.trim()
                        await reloadCacheSize()
                    }
                }
                Picker("Download Ahead", selection: $precacheCount) {
                    Text("Off").tag(0)
                    Text("1 Song").tag(1)
                    Text("3 Songs").tag(3)
                    Text("5 Songs").tag(5)
                }
                LabeledContent("Downloaded Music") {
                    HStack {
                        Text(cacheSize, format: .byteCount(style: .file))
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            Task {
                                await MacMusicCache.shared.clear()
                                await reloadCacheSize()
                            }
                        }
                    }
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Songs you play and the ones coming up are kept on this Mac, so they start at once and survive a slow connection. Download Ahead fetches whole songs before they play, except on a metered connection or in Low Data Mode. Songs Plex converts are never kept.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Look Up Missing Artist and Album Details", isOn: $onlineInfo)
                    .onChange(of: onlineInfo) { _, on in
                        if !on { Task { await MusicInfoStore.shared.clear() } }
                    }
            } header: {
                Text("Music Details")
            } footer: {
                Text("When Plex has no biography, photo, cover or links, Reprise looks for them on MusicBrainz, Wikipedia and TheAudioDB. The artist and album names, or their MusicBrainz IDs, are sent to them; nothing else is. Turning this off forgets what was found. Radio song covers are looked up separately, on Apple's iTunes search, which is sent the artist and song title.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            deviceRates = MacAudioOutput.supportedRates()
            await reloadCacheSize()
        }
    }

    /// The rates the output offers, plus a stored one it lacks, so the picker always shows its selection.
    private var rateChoices: [Int] {
        var rates = deviceRates
        if MusicOutputRate.fixedChoices.contains(outputRate), !rates.contains(outputRate) { rates.append(outputRate) }
        return rates.sorted()
    }

    private func reloadCacheSize() async {
        cacheSize = await MacMusicCache.shared.size()
    }
}
