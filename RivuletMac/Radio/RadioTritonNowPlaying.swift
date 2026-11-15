// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The songs a Triton Digital (StreamTheWorld) station has played, from Triton's
/// public now-playing feed. Its HLS streams carry the song only in each packed
/// AAC segment's ID3 tag, which AVPlayer reads for the timestamp and drops, and
/// its plain streams send no ICY title, so without this they show nothing.
/// Only the mount name goes to Triton, the host the stream already comes from.
nonisolated enum RadioTritonNowPlaying {
    struct Track: Equatable, Sendable {
        let artist: String?
        let title: String
        let start: Date
        let duration: TimeInterval?

        /// "Artist - Title", as `RadioSong` reads it.
        var text: String { artist.map { "\($0) - \(title)" } ?? title }
    }

    /// The mount a stream plays from, read off its address after redirects:
    /// `…streamtheworld.com/ARN_IHRT9AAC/HLS/playlist.m3u8` (HLS) or
    /// `…streamtheworld.com/SMOOTHRELAX_SYD_AAC128.aac` (plain). Nil for any other host.
    static func mount(of url: URL) -> String? {
        guard let host = url.host()?.lowercased(),
              host == "streamtheworld.com" || host.hasSuffix(".streamtheworld.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let name: String?
        if let redirect = parts.firstIndex(of: "livestream-redirect") {
            name = parts.indices.contains(redirect + 1) ? parts[redirect + 1] : nil
        } else {
            name = parts.first
        }
        guard let name else { return nil }
        let mount = (name as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !mount.isEmpty, mount.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return mount
    }

    /// The last few songs, newest first; empty when the feed has none or fails.
    @concurrent
    static func tracks(mount: String) async -> [Track] {
        var parts = URLComponents(string: "https://np.tritondigital.com/public/nowplaying")
        parts?.queryItems = [
            URLQueryItem(name: "mountName", value: mount),
            URLQueryItem(name: "numberToFetch", value: "5"),
            // Songs only: no ads, idents or station promos.
            URLQueryItem(name: "eventType", value: "track")
        ]
        guard let url = parts?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return FeedReader.tracks(in: data)
    }

    /// Reads `<nowplaying-info>` elements, each a list of `<property name="…">` values.
    private final class FeedReader: NSObject, XMLParserDelegate {
        private var tracks: [Track] = []
        private var properties: [String: String]?
        private var property: String?
        private var text = ""

        static func tracks(in data: Data) -> [Track] {
            let reader = FeedReader()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            return reader.tracks.sorted { $0.start > $1.start }
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch element {
            case "nowplaying-info":
                properties = [:]
            case "property":
                property = attributes["name"]
                text = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if property != nil { text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            if property != nil, let string = String(data: block, encoding: .utf8) { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName: String?) {
            switch element {
            case "property":
                if let property { properties?[property] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                property = nil
            case "nowplaying-info":
                if let properties, let track = Self.track(from: properties) { tracks.append(track) }
                properties = nil
            default:
                break
            }
        }

        private static func track(from properties: [String: String]) -> Track? {
            guard let title = properties["cue_title"], !title.isEmpty,
                  let startMS = properties["cue_time_start"].flatMap(Double.init) else { return nil }
            let artist = properties["track_artist_name"].flatMap { $0.isEmpty ? nil : $0 }
            // Seconds on some stations, milliseconds on others: no song runs an hour.
            let duration = properties["cue_time_duration"].flatMap(Double.init).map { $0 > 3600 ? $0 / 1000 : $0 }
            return Track(artist: artist, title: title,
                         start: Date(timeIntervalSince1970: startMS / 1000), duration: duration)
        }
    }
}
