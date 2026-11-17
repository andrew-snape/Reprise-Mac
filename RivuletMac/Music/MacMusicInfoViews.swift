// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

// MARK: - Layout

/// Left to right, wrapping to a new row when one is full.
struct MacFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

// MARK: - Small parts

struct MacMusicChip: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.1), in: Capsule())
    }
}

/// Chips for each text, repeats (any case) dropped.
struct MacMusicChips: View {
    let texts: [String]

    private var unique: [String] {
        var seen = Set<String>()
        return texts.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        let texts = unique
        if !texts.isEmpty {
            MacFlowLayout(spacing: 6) {
                ForEach(texts, id: \.self) { MacMusicChip(text: $0) }
            }
        }
    }
}

/// Ratings set this session, by rating key, so every view of an item agrees
/// before Plex's lists are fetched again. 0 is a rating cleared.
@MainActor
@Observable
final class MacMusicRatings {
    static let shared = MacMusicRatings()
    private(set) var stars: [String: Int] = [:]

    func stars(for item: PlexMetadata) -> Double? {
        if let key = item.ratingKey, let set = stars[key] { return set == 0 ? nil : Double(set) }
        return PlexUserRating.stars(item.userRating)
    }

    /// Shows the new rating at once and puts the old one back if Plex refuses it.
    func set(_ value: Int?, on item: PlexMetadata, plex: MacPlexSession) {
        guard let key = item.ratingKey else { return }
        let before = stars[key]
        stars[key] = value ?? 0
        Task {
            if await plex.rate(item, stars: value) == false { stars[key] = before }
        }
    }
}

/// The listener's five stars. Click one to rate; click the rating again to clear it.
struct MacMusicStars: View {
    let item: PlexMetadata
    @Environment(MacPlexSession.self) private var plex
    @State private var hovered: Int?

    var body: some View {
        let current = MacMusicRatings.shared.stars(for: item) ?? 0
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                let shown = Double(hovered ?? 0) > 0 ? Double(hovered ?? 0) : current
                Button {
                    MacMusicRatings.shared.set(Int(current) == star ? nil : star, on: item, plex: plex)
                } label: {
                    Image(systemName: shown >= Double(star) ? "star.fill"
                          : (shown >= Double(star) - 0.5 ? "star.leadinghalf.filled" : "star"))
                        .foregroundStyle(shown >= Double(star) - 0.5 ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? star : (hovered == star ? nil : hovered) }
                .accessibilityLabel(star == 1 ? "1 star" : "\(star) stars")
            }
        }
        .font(.caption)
        .help(current > 0 ? "Your Rating. Click it again to clear." : "Rate")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Rating")
        .accessibilityValue(current > 0 ? "\(Int(current)) of 5" : "Not rated")
    }
}

/// The listener's stars, which can be set, and the critic's rating when there is one.
struct MacMusicRatingBadge: View {
    let item: PlexMetadata

    var body: some View {
        let critic = (item.rating ?? 0) > 0 ? item.rating : nil
        HStack(spacing: 12) {
            MacMusicStars(item: item)
            if let critic {
                Text("★ " + (critic / 2).formatted(.number.precision(.fractionLength(1))))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .help("Critic Rating")
            }
        }
    }
}

/// "Rating" in an item's right-click menu.
struct MacMusicRatingMenu: View {
    let item: PlexMetadata
    @Environment(MacPlexSession.self) private var plex

    var body: some View {
        let current = Int(MacMusicRatings.shared.stars(for: item) ?? 0)
        Menu("Rating", systemImage: "star") {
            ForEach((1...5).reversed(), id: \.self) { star in
                Toggle(String(repeating: "★", count: star), isOn: Binding(
                    get: { current == star },
                    set: { _ in MacMusicRatings.shared.set(star, on: item, plex: plex) }))
                    .accessibilityLabel(star == 1 ? "1 star" : "\(star) stars")
            }
            Divider()
            Button("No Rating") { MacMusicRatings.shared.set(nil, on: item, plex: plex) }
                .disabled(current == 0)
        }
    }
}

struct MacMusicQualityBadge: View {
    let quality: MusicAudioQuality

    var body: some View {
        Label(quality.label, systemImage: "waveform")
            .plexPill()
            .foregroundStyle(.secondary)
    }
}

/// A biography or review, cut to a few lines with More to open it.
struct MacMusicBio: View {
    let text: String
    var sourceName: String?
    var sourceURL: URL?
    var collapsedLines = 4
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var limitedHeight: CGFloat = 0

    private var isTruncated: Bool { fullHeight > limitedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : collapsedLines)
                .background {
                    // Hidden copies measure whether the limit cuts anything.
                    ZStack {
                        Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { Color.clear.preference(key: MacBioHeight.self, value: [0: $0.size.height]) })
                        Text(text).font(.callout).lineLimit(collapsedLines).fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { Color.clear.preference(key: MacBioHeight.self, value: [1: $0.size.height]) })
                    }
                    .hidden()
                }
                .onPreferenceChange(MacBioHeight.self) { heights in
                    fullHeight = heights[0] ?? 0
                    limitedHeight = heights[1] ?? 0
                }
            if isTruncated {
                Button(expanded ? "Less" : "More") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
            }
            if let sourceName {
                if let sourceURL {
                    Link("From \(sourceName)", destination: sourceURL)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("From \(sourceName)").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }
}

private struct MacBioHeight: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// How often Plex's listeners play a track against the artist's most played.
struct MacMusicPopularityBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 36, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(.secondary).frame(width: 36 * min(max(fraction, 0), 1), height: 4)
            }
            .help("Popularity")
    }
}

// MARK: - Hero

/// The top of an artist or album page: a wash of the cover's colour, and the
/// artist's backdrop behind it when there is one.
struct MacMusicHero<Content: View>: View {
    let tint: Color?
    /// The artist or album whose cover colours wash the top of the page.
    var item: PlexMetadata?
    var backdrop: URL?
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.top, 24)
            .padding(.horizontal, MacTile.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    LinearGradient(colors: [(tint ?? .clear).opacity(0.9), MacTheme.background],
                                   startPoint: .top, endPoint: .bottom)
                    // Plex's four colours over the single tint once they arrive.
                    MacMusicWash(item: item, fadesOut: true).opacity(0.9)
                    if let backdrop {
                        MacPlexImage(url: backdrop)
                            .opacity(0.5)
                            .overlay {
                                LinearGradient(colors: [.clear, MacTheme.background], startPoint: .top, endPoint: .bottom)
                            }
                            .frame(minHeight: 320)
                    }
                }
                .padding(.top, -200)
            }
            .animation(.easeInOut(duration: 0.4), value: tint)
    }
}

// MARK: - Elsewhere

/// Pages about the artist or album on other sites; nothing when there are none.
struct MacMusicLinksMenu: View {
    let links: [MusicLink]

    var body: some View {
        if !links.isEmpty {
            Menu("Elsewhere", systemImage: "link") {
                ForEach(links, id: \.self) { link in
                    Button(link.title) { NSWorkspace.shared.open(link.url) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Open this on another site")
        }
    }
}

// MARK: - Online gaps

extension PlexMetadata {
    /// Plex has no genre or style of its own.
    var hasNoMusicStyles: Bool {
        (Genre ?? []).isEmpty && (Style ?? []).isEmpty
    }
}
