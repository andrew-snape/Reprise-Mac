// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// A minimized Plex title along the bottom of the window, in the music bar's place:
/// the picture small at the left (hover to expand), transport and seek bar in the
/// middle, volume, expand and stop at the right.
struct MacVideoBar: View {
    var session: MacPlexPlayback
    var player: AetherPlayer
    @Environment(MacPlaybackController.self) private var controller
    @State private var scrubbing: Double?
    @State private var hoveringPicture = false
    @AppStorage(MacSkipInterval.backKey) private var skipBackSetting = MacSkipInterval.backDefault
    @AppStorage(MacSkipInterval.forwardKey) private var skipForwardSetting = MacSkipInterval.forwardDefault

    private var skipBack: Int { MacSkipInterval.checked(skipBackSetting, fallback: MacSkipInterval.backDefault) }
    private var skipForward: Int { MacSkipInterval.checked(skipForwardSetting, fallback: MacSkipInterval.forwardDefault) }

    private var duration: Double {
        player.duration > 0 ? player.duration : session.request.item.durationSeconds
    }

    private var position: Double { player.pendingSeekTarget ?? player.currentTime }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: controller.expand) {
                HStack(spacing: 10) {
                    picture
                    titles
                }
                .frame(width: 300, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringPicture = $0 }
            .help("Expand Player")

            VStack(spacing: 4) {
                transport
                scrubber
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Button { player.setMuted(!player.isMuted) } label: {
                    Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20)
                }
                .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
                .help(player.isMuted ? "Unmute" : "Mute")
                Slider(value: Binding(get: { Double(player.isMuted ? 0 : player.volume) },
                                      set: { player.setVolume(Float($0)) }),
                       in: 0...1)
                    .frame(width: 80)
                    .controlSize(.small)
                Button(action: controller.expand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Expand Player")
                .help("Expand Player")
                Button { controller.close() } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Stop")
                .help("Stop (⌘.)")
            }
            .buttonStyle(.borderless)
            .frame(width: 196, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .macFloatingBar()
        .contextMenu {
            Button("Expand Player", systemImage: "arrow.up.left.and.arrow.down.right", action: controller.expand)
            Button("Stop", systemImage: "stop.fill") { controller.close() }
        }
    }

    /// The playing picture itself: the engine's surface moves here while the player is minimized.
    private var picture: some View {
        ZStack {
            Color.black
            player.surface
                .allowsHitTesting(false)
            // Above the engine's view, so its NSView never takes the click or the hover.
            Color.clear.contentShape(Rectangle())
            if hoveringPicture {
                Color.black.opacity(0.6)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
            } else if player.isBuffering || player.state == .loading || player.state == .idle {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: hoveringPicture)
    }

    private var titles: some View {
        let item = session.request.item
        let episode = item.type == "episode"
        return VStack(alignment: .leading, spacing: 2) {
            Text(episode ? item.showTitle : item.displayTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else if episode {
                Text([item.episodeCode, item.displayTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// A stop or failure shows here in short; expanding shows it in full, with its buttons.
    private var problem: String? {
        if session.serverStopReason != nil { return "Playback stopped" }
        if case .failed = player.state { return "Couldn't play" }
        return nil
    }

    private var transport: some View {
        HStack(spacing: 22) {
            Button { Task { await player.skip(by: -Double(skipBack)) } } label: {
                Image(systemName: "gobackward.\(skipBack)")
            }
            .accessibilityLabel("Back \(skipBack) Seconds")
            .help("Back \(skipBack) Seconds")
            Button(action: player.togglePlayPause) {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 28)
            }
            .accessibilityLabel(player.state == .playing ? "Pause" : "Play")
            .help(player.state == .playing ? "Pause (Space)" : "Play (Space)")
            Button { Task { await player.skip(by: Double(skipForward)) } } label: {
                Image(systemName: "goforward.\(skipForward)")
            }
            .accessibilityLabel("Forward \(skipForward) Seconds")
            .help("Forward \(skipForward) Seconds")
            Button { session.playNext() } label: { Image(systemName: "forward.end.fill") }
                .disabled(session.nextEpisode == nil)
                .accessibilityLabel("Next Episode")
                .help("Next Episode")
        }
        .buttonStyle(.borderless)
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(MacVODPlayerView.format(scrubbing ?? position))
                .frame(width: 52, alignment: .trailing)
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
            Text("-" + MacVODPlayerView.format(max(0, duration - (scrubbing ?? position))))
                .frame(width: 52, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}
