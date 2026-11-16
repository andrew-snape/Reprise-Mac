// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// The system AirPlay button, shown only while there is somewhere else to send
/// the sound (`MacAirPlayRoutes`). With a player it sends that player to an Apple
/// TV or AirPlay speaker, picture included for video, and the Mac's other sounds
/// stay here; without one it picks the Mac's sound output for everything.
/// Radio uses it without one; music binds its player only while crossfade is
/// unused (`MacMusicPlayer.routePlayer`).
struct MacAirPlayButton: View {
    var player: AVPlayer?
    var tint: NSColor = .labelColor
    var size: CGFloat = 24

    @State private var routes = MacAirPlayRoutes.shared

    var body: some View {
        if routes.available {
            MacRoutePicker(player: player, tint: tint)
                .frame(width: size, height: size)
        }
    }
}

private struct MacRoutePicker: NSViewRepresentable {
    var player: AVPlayer?
    var tint: NSColor

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(tint, for: .normal)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        if view.player !== player { view.player = player }
        view.setRoutePickerButtonColor(tint, for: .normal)
    }
}

/// Whether the Mac can reach more than one output, from `AVRouteDetector`.
/// Detection starts with the first AirPlay button and stays on: a hidden button
/// has no view to say when it appears.
@MainActor
@Observable
final class MacAirPlayRoutes {
    static let shared = MacAirPlayRoutes()

    private(set) var available = false

    @ObservationIgnored private let detector = AVRouteDetector()
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVRouteDetectorMultipleRoutesDetectedDidChange,
            object: detector,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        detector.isRouteDetectionEnabled = true
        update()
    }

    private func update() {
        let detected = detector.multipleRoutesDetected
        if available != detected { available = detected }
    }
}
