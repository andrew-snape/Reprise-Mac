// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import AVFoundation
import AVKit
import CoreAudio
import Observation
import SwiftUI

/// The system AirPlay button. With a player it sends that player to an Apple
/// TV or AirPlay speaker, picture included for video; without one it picks the
/// Mac's sound output, so the sound goes and the picture stays here. Music and
/// radio use it without one: bound to an audio player, the picker never leaves
/// its pulsing "connecting" state even once the speaker is playing.
///
/// Without a player the system button pulses anyway while the output is an AirPlay
/// device, so it is drawn clear and still takes the clicks, under an icon of our own
/// (Apple's symbol, as the guidelines ask) in the system button's states: accent while
/// the Mac's sound goes to AirPlay, dimmed while no other output is in reach.
struct MacAirPlayButton: View {
    var player: AVPlayer?
    var tint: NSColor = .labelColor

    var body: some View {
        if player == nil {
            let output = MacAirPlayOutput.shared
            ZStack {
                MacRoutePicker(player: nil, tint: .clear, activeTint: .clear)
                Image(systemName: "airplay.audio")
                    .font(.system(size: 15))
                    .foregroundStyle(output.isAirPlay ? Color.accentColor : Color(nsColor: tint))
                    .opacity(output.isAirPlay || output.routesAvailable ? 1 : 0.4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onAppear { output.buttonAppeared() }
            .onDisappear { output.buttonDisappeared() }
        } else {
            MacRoutePicker(player: player, tint: tint, activeTint: .controlAccentColor)
        }
    }
}

private struct MacRoutePicker: NSViewRepresentable {
    var player: AVPlayer?
    var tint: NSColor
    var activeTint: NSColor

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(tint, for: .normal)
        view.setRoutePickerButtonColor(activeTint, for: .active)
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        if view.player !== player { view.player = player }
        view.setRoutePickerButtonColor(tint, for: .normal)
        view.setRoutePickerButtonColor(activeTint, for: .active)
    }
}

/// Music and radio AirPlay: by default the button switches the Mac's sound output.
/// With `fromPlayerKey` on (Settings > Music, still on trial) it is bound to the
/// player instead, so only Reprise goes to the speaker, with AirPlay 2's enhanced
/// buffering and multi-room, and the system button shows as it is, pulse and all.
enum MacAirPlayRoute {
    static let fromPlayerKey = "musicAirPlayFromPlayer"
    static var fromPlayer: Bool { UserDefaults.standard.bool(forKey: fromPlayerKey) }
}

/// Whether the Mac's default sound output is an AirPlay device, and whether any
/// other output is in reach (`AVRouteDetector`, run only while a button is showing:
/// detection costs power), kept current.
@MainActor
@Observable
final class MacAirPlayOutput {
    static let shared = MacAirPlayOutput()

    private(set) var isAirPlay = false
    private(set) var routesAvailable = true

    @ObservationIgnored private let detector = AVRouteDetector()
    @ObservationIgnored private var visibleButtons = 0
    @ObservationIgnored private var detectorObserver: NSObjectProtocol?

    private init() {
        refresh()
        Self.listen { [weak self] in self?.refresh() }
        detectorObserver = NotificationCenter.default.addObserver(
            forName: .AVRouteDetectorMultipleRoutesDetectedDidChange, object: detector, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRoutes() }
        }
    }

    func buttonAppeared() {
        visibleButtons += 1
        if visibleButtons == 1 { detector.isRouteDetectionEnabled = true }
    }

    func buttonDisappeared() {
        visibleButtons = max(visibleButtons - 1, 0)
        if visibleButtons == 0 { detector.isRouteDetectionEnabled = false }
    }

    private func refreshRoutes() {
        routesAvailable = detector.multipleRoutesDetected
    }

    private func refresh() {
        let device = CoreAudioDevice.defaultOutput()
        isAirPlay = device.flatMap(CoreAudioDevice.transportType) == kAudioDeviceTransportTypeAirPlay
    }

    // Nonisolated on purpose: Core Audio calls the block on the queue given (see MacAudioOutput).
    private nonisolated static func listen(_ handler: @escaping @MainActor @Sendable () -> Void) {
        var address = CoreAudioDevice.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
