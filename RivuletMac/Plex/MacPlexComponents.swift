// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

// MARK: - Artwork

/// Remote image through MacArtworkCache. A cached image is in place on the
/// first frame, so recreated tiles do not flash.
struct MacPlexImage: View {
    let url: URL?
    @State private var image: NSImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap(MacArtworkCache.shared.cachedImage(for:)))
    }

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else { return }
                if let cached = MacArtworkCache.shared.cachedImage(for: url) {
                    image = cached
                    return
                }
                guard let loaded = await MacArtworkCache.shared.image(for: url), !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

/// An item's artwork, transcoded to the pixel size the tile draws at. Widths
/// round up to 120px steps so nearby tile sizes share one cache entry.
struct MacPlexArtwork: View {
    let item: PlexMetadata
    let kind: MacPlexSession.ArtworkKind
    /// Display width in points.
    let width: CGFloat
    /// Width over height of the requested image.
    let aspectRatio: CGFloat
    @Environment(MacPlexSession.self) private var plex
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        MacPlexImage(url: Self.url(plex, item: item, kind: kind, width: width, aspectRatio: aspectRatio, scale: displayScale))
    }

    static func url(_ plex: MacPlexSession, item: PlexMetadata, kind: MacPlexSession.ArtworkKind,
                    width: CGFloat, aspectRatio: CGFloat, scale: CGFloat) -> URL? {
        let pixels = max(1, Int((width * scale / 120).rounded(.up))) * 120
        return plex.artworkURL(for: item, kind: kind, width: pixels, height: Int(CGFloat(pixels) / aspectRatio))
    }
}

/// Clear logo with a text fallback. Always drawn over a dark scrim, so white.
struct MacPlexResolvedLogo: View {
    let item: PlexMetadata
    let fallbackTitle: String
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let fallbackFont: Font
    let alignment: Alignment
    let textAlignment: TextAlignment

    @Environment(MacPlexSession.self) private var plex
    @State private var loaded: (identity: String, image: NSImage)?

    private var sourceIdentity: String {
        let key = item.type == "episode"
            ? item.grandparentRatingKey
            : (item.type == "season" ? item.parentRatingKey : item.ratingKey)
        return "\(key ?? item.id)|\(item.clearLogoPath ?? "")"
    }

    var body: some View {
        let cached = plex.cachedLogoURL(for: item).flatMap(MacArtworkCache.shared.cachedImage(for:))
        let logo = cached ?? (loaded?.identity == sourceIdentity ? loaded?.image : nil)
        ZStack(alignment: alignment) {
            if let logo {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .transition(.opacity)
            } else {
                Text(fallbackTitle)
                    .font(fallbackFont)
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
        .animation(.easeInOut(duration: 0.2), value: logo != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fallbackTitle)
        .task(id: sourceIdentity) {
            let identity = sourceIdentity
            guard let url = await plex.logoURL(for: item),
                  !Task.isCancelled,
                  let image = await MacArtworkCache.shared.image(for: url),
                  !Task.isCancelled else { return }
            loaded = (identity, image)
        }
    }
}

// MARK: - Watch state

extension View {
    /// Progress bar along the bottom, or the watched check when there is no bar.
    func plexWatchState(_ item: PlexMetadata) -> some View {
        overlay(alignment: .bottom) {
            if let fraction = item.progressBarFraction {
                ProgressView(value: fraction)
                    .tint(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.progressBarFraction == nil, item.isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(6)
            }
        }
    }

    func plexPill() -> some View {
        font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary, lineWidth: 1))
    }
}

extension PlexMetadata {
    /// PlexMetadata's `==` compares only ratingKey, so SwiftUI skips a tile whose
    /// watch state changed. Tiles store this so the change reaches their body.
    var watchStamp: [Int] { [viewOffset ?? 0, viewCount ?? 0, viewedLeafCount ?? 0, lastViewedAt ?? 0] }
}

extension Array where Element == PlexMetadata {
    /// Drops repeats by id, keeping the first; ForEach needs unique ids.
    func uniqued() -> [PlexMetadata] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Tiles

enum MacTile {
    static let poster: CGFloat = 160
    static let landscape: CGFloat = 300
    static let person: CGFloat = 96
    static let gap: CGFloat = 16
    static let margin: CGFloat = 28
    /// How much of the next tile a row leaves showing, so it reads as scrollable.
    static let peek: CGFloat = 0.35
    /// A row's tiles grow to fill the width, up to this many times their size.
    static let growth: CGFloat = 1.3
}

struct MacPlexPosterCard: View {
    let item: PlexMetadata
    var width: CGFloat? = MacTile.poster
    private let watchStamp: [Int]

    init(item: PlexMetadata, width: CGFloat? = MacTile.poster) {
        self.item = item
        self.width = width
        watchStamp = item.watchStamp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacPlexArtwork(item: item, kind: .poster, width: width ?? MacTile.poster, aspectRatio: 2 / 3)
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: width)
                .plexWatchState(item)
                .clipShape(RoundedRectangle(cornerRadius: MacTheme.cardCorner, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)

            Text(item.type == "episode" ? item.showTitle : item.displayTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let caption = item.type == "episode" ? item.episodeCode : item.subtitle {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .macCardHover()
    }
}

/// Continue Watching, the tvOS card: backdrop art, the logo centred, and
/// progress and "S2, E5 · 12 min left" along the bottom.
struct MacPlexContinueCard: View {
    static let aspectRatio: CGFloat = 16 / 9

    let item: PlexMetadata
    var width: CGFloat = MacTile.landscape
    private let watchStamp: [Int]

    init(item: PlexMetadata, width: CGFloat = MacTile.landscape) {
        self.item = item
        self.width = width
        watchStamp = item.watchStamp
    }

    private var height: CGFloat { width / Self.aspectRatio }

    private var info: String {
        [item.episodeCode, item.timeLeftText ?? item.runtimeText ?? item.year.map(String.init)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            MacPlexArtwork(item: item, kind: .backdrop, width: width, aspectRatio: Self.aspectRatio)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            MacPlexResolvedLogo(
                item: item,
                fallbackTitle: item.showTitle,
                maxWidth: width * 0.6,
                maxHeight: height * 0.35,
                fallbackFont: .title3.bold(),
                alignment: .center,
                textAlignment: .center
            )
            HStack(spacing: 6) {
                if let fraction = item.progressBarFraction {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(width: 40, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).frame(width: 40 * fraction)
                        }
                }
                Text(info)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: MacTheme.cardCorner, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
        .contentShape(Rectangle())
        .macCardHover()
    }
}

// MARK: - Rows

/// A See All destination: one hub, paged through its own key.
struct MacPlexHubRoute: Hashable {
    let hub: PlexHub

    /// Continue Watching is the cache-busted fetch, and a literal id list is a
    /// fixed set, so neither pages.
    var pages: Bool {
        guard !hub.isContinueWatching, let key = hub.key ?? hub.hubKey else { return false }
        return !key.hasPrefix("/library/metadata/")
    }
}

/// "Title ›" heading that opens the full grid.
struct MacPlexShelfHeader: View {
    let title: String
    var route: MacPlexHubRoute?

    var body: some View {
        if let route {
            NavigationLink(value: route) {
                HStack(spacing: 4) {
                    Text(title).font(.title2.bold())
                    Image(systemName: "chevron.right").font(.headline).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            Text(title).font(.title2.bold())
        }
    }
}

/// A titled horizontal row. Scroll sideways with a trackpad, Shift and the
/// wheel, or the arrows that show under the pointer.
///
/// Tiles grow from `base` so the row ends part-way through one (never on a
/// clean edge that hides there is more), and scrolling settles on a tile.
struct MacShelfRow<Items: RandomAccessCollection, Header: View, Tile: View>: View where Items.Element: Identifiable {
    let items: Items
    /// A tile's width before it is fitted to the row.
    var base: CGFloat = MacTile.poster
    @ViewBuilder let header: () -> Header
    /// The item and the width to draw it at.
    @ViewBuilder let tile: (Items.Element, CGFloat) -> Tile

    @State private var rowWidth: CGFloat = 0
    @State private var leading: Items.Element.ID?
    @State private var ends = Ends()
    @State private var isHovered = false

    private struct Ends: Equatable {
        var back = false
        var forward = false
    }

    /// The tile width for this row, and how many whole tiles show at once.
    private var fit: (width: CGFloat, page: Int) {
        let available = rowWidth - MacTile.margin * 2
        let stride = base + MacTile.gap
        guard available > stride else { return (base, 1) }
        let page = max(1, Int((available - base * MacTile.peek) / stride))
        // Everything already shows: nothing to hint at, so nothing to stretch.
        if CGFloat(items.count) * stride - MacTile.gap <= available { return (base, page) }
        let fitted = (available - CGFloat(page) * MacTile.gap) / (CGFloat(page) + MacTile.peek)
        return (min(max(fitted.rounded(.down), base), (base * MacTile.growth).rounded(.down)), page)
    }

    var body: some View {
        let fit = fit
        VStack(alignment: .leading, spacing: 10) {
            header().padding(.horizontal, MacTile.margin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: MacTile.gap) {
                    ForEach(items) { tile($0, fit.width) }
                }
                .scrollTargetLayout()
                .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, MacTile.margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $leading, anchor: .leading)
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: Ends.self) { geometry in
                // Slack of one margin: whether the margins count as content differs by edge.
                Ends(back: geometry.visibleRect.minX > 1,
                     forward: geometry.visibleRect.maxX < geometry.contentSize.width - MacTile.margin - 1)
            } action: { _, new in
                ends = new
            }
            .overlay(alignment: .leading) {
                if isHovered, ends.back {
                    arrow("chevron.left", label: "Scroll Back") { page(by: -fit.page) }
                }
            }
            .overlay(alignment: .trailing) {
                if isHovered, ends.forward {
                    arrow("chevron.right", label: "Scroll Forward") { page(by: fit.page) }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: ends)
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .padding(.horizontal, 10)
        // Level with the artwork rather than the captions under it.
        .offset(y: -18)
        .transition(.opacity)
    }

    /// Moves the row a screenful of tiles.
    private func page(by count: Int) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        let current = leading.flatMap { ids.firstIndex(of: $0) } ?? 0
        let target = min(max(current + count, 0), ids.count - 1)
        withAnimation(.snappy) { leading = ids[target] }
    }
}

/// One Home hub as a titled row.
struct MacPlexShelfView: View {
    let hub: PlexHub

    var body: some View {
        MacPlexRail(title: hub.displayTitle, route: MacPlexHubRoute(hub: hub), items: hub.items,
                    base: hub.isContinueWatching ? MacTile.landscape : MacTile.poster) { item, width in
            if hub.isContinueWatching {
                MacPlexContinueCard(item: item, width: width)
            } else {
                MacPlexPosterCard(item: item, width: width)
            }
        }
    }
}

/// Titled row of Plex items; each tile opens its detail and has the item menu.
struct MacPlexRail<Tile: View>: View {
    let title: String
    var route: MacPlexHubRoute?
    let items: [PlexMetadata]
    var base: CGFloat = MacTile.poster
    @ViewBuilder let tile: (PlexMetadata, CGFloat) -> Tile

    var body: some View {
        MacShelfRow(items: items, base: base) {
            MacPlexShelfHeader(title: title, route: route)
        } tile: { item, width in
            NavigationLink(value: item) { tile(item, width) }
                .buttonStyle(.plain)
                .plexContextMenu(item)
        }
    }
}

/// Adaptive poster grid for libraries and See All. Calls `loadMore` when the
/// last tile appears.
struct MacPlexPosterGrid: View {
    let items: [PlexMetadata]
    var loadMore: (() -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: MacTile.poster, maximum: MacTile.poster + 40),
                                     spacing: MacTile.gap, alignment: .top)],
                  spacing: 22) {
            ForEach(items) { item in
                NavigationLink(value: item) { MacPlexPosterCard(item: item, width: nil) }
                    .buttonStyle(.plain)
                    .plexContextMenu(item)
                    .onAppear {
                        if item.id == items.last?.id { loadMore?() }
                    }
            }
        }
        // Lets a scroll view report and set its top tile (the library's letter bar).
        .scrollTargetLayout()
        .padding(.horizontal, MacTile.margin)
        .padding(.vertical, 16)
    }
}

/// Error state with Retry, used by every content surface.
struct MacPlexErrorView: View {
    let title: String
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await retry() } }
        }
    }
}
