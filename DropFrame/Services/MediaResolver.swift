import Foundation
import WebKit

protocol MediaResolving: Sendable {
    func resolve(_ url: URL) async throws -> ResolvedMedia
}

actor MediaResolver: MediaResolving {
    private let onDevice = OnDeviceMediaResolver()
    private let ytDLP = YTDLPOnDeviceResolver()
    private let youtube = YouTubeMediaResolver()
    private let instagram = InstagramMediaResolver()

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        try await resolve(url, settings: AppSettings())
    }

    func resolve(_ url: URL, settings: AppSettings) async throws -> ResolvedMedia {
        _ = settings
        if OnDeviceMediaResolver.isDirectMediaURL(url) {
            return try playableResult(from: try await onDevice.resolve(url))
        }

        if YouTubeURLMatcher.matches(url) {
            return try playableResult(from: try await youtube.resolve(url))
        }

        if InstagramURLMatcher.matches(url) {
            return try playableResult(from: try await instagram.resolve(url))
        }

        do {
            return try playableResult(from: try await ytDLP.resolve(url))
        } catch {
            return try playableResult(from: try await onDevice.resolve(url))
        }
    }

    private func playableResult(from result: ResolvedMedia) throws -> ResolvedMedia {
        let formats = result.formats.filter { $0.isIOSCompatible || $0.isHLS }
        guard !formats.isEmpty else {
            throw DropFrameError.noMediaFound
        }
        return ResolvedMedia(
            id: result.id,
            sourceURL: result.sourceURL,
            title: result.title,
            thumbnailURL: result.thumbnailURL,
            duration: result.duration,
            formats: formats
        )
    }
}

actor OnDeviceMediaResolver: MediaResolving {
    private static let directExtensions = ["mp4", "mov", "m4v", "webm", "m3u8"]
    private static let candidatePattern = #"(?i)(?:(?:https?:)?//|/)[^"'\s<>\\]+?\.(?:mp4|m4v|mov|webm|m3u8)(?:\?[^"'\s<>\\]*)?"#
    private static let mediaTagPattern = #"(?is)<(?:source|video)\b[^>]*>"#

    static func isDirectMediaURL(_ url: URL) -> Bool {
        directExtensions.contains(url.pathExtension.lowercased())
    }

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        if Self.isDirectMediaURL(url) {
            let ext = url.pathExtension.lowercased()
            let format = MediaFormat(
                id: url.absoluteString,
                url: url,
                label: qualityLabel(in: url.absoluteString) ?? "Original",
                height: qualityHeight(in: url.absoluteString),
                width: nil,
                fileExtension: ext,
                estimatedBytes: nil,
                isHLS: ext == "m3u8",
                hasAudio: true
            )
            return ResolvedMedia(
                sourceURL: url,
                title: url.deletingPathExtension().lastPathComponent.nonEmpty ?? "Untitled video",
                thumbnailURL: nil,
                duration: nil,
                formats: [format]
            )
        }

        let webSnapshotTask = Task<WebProbeSnapshot?, Never> {
            try? await WebPageMediaProbe.inspect(url)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.allowsCellularAccess = true
        request.allowsExpensiveNetworkAccess = true
        request.allowsConstrainedNetworkAccess = true
        request.setValue(BrowserRequestHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let html: String?
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if
                let http = response as? HTTPURLResponse,
                (200..<400).contains(http.statusCode),
                data.count < 25_000_000
            {
                html = String(data: data, encoding: .utf8)
            } else {
                html = nil
            }
        } catch {
            html = nil
        }

        let cleanedHTML = decodeEmbeddedText(html ?? "")
        let percentDecodedHTML = cleanedHTML.removingPercentEncoding ?? cleanedHTML
        let mediaTags = matches(pattern: Self.mediaTagPattern, in: cleanedHTML)
        let taggedCandidates = mediaTags.compactMap { tag -> MediaCandidate? in
            guard let source = attribute("src", in: tag) else { return nil }
            let label = attribute("label", in: tag)
                ?? attribute("res", in: tag)
                ?? attribute("data-quality", in: tag)
                ?? attribute("title", in: tag)
            return MediaCandidate(
                rawURL: source,
                labelHint: label,
                source: .dom
            )
        }
        let discoveredCandidates = (
            matches(pattern: Self.candidatePattern, in: cleanedHTML)
            + matches(pattern: Self.candidatePattern, in: percentDecodedHTML)
        ).map {
            MediaCandidate(
                rawURL: $0,
                labelHint: nil,
                source: .page
            )
        }

        var pageTitle = metaContent(property: "og:title", in: cleanedHTML)
            ?? title(in: cleanedHTML)
            ?? url.host
            ?? "Untitled video"
        var pageThumbnail = metaContent(property: "og:image", in: cleanedHTML)
            .flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        var discoveredFormats = rankedFormats(
            from: taggedCandidates + discoveredCandidates,
            relativeTo: url,
            requestHeaders: ["Referer": url.absoluteString]
        )

        let directFormats = preferredFormatsByQuality(
            await verifiedFormats(await expandingHLSVariants(in: discoveredFormats))
        )
        if directFormats.count == 1,
           let directFormat = directFormats.first,
           directFormat.isIOSCompatible,
           !directFormat.isHLS {
            webSnapshotTask.cancel()
            return ResolvedMedia(
                sourceURL: url,
                title: pageTitle,
                thumbnailURL: pageThumbnail,
                duration: nil,
                formats: [directFormat]
            )
        }

        if let webSnapshot = await webSnapshotTask.value {
            discoveredFormats.append(contentsOf: rankedFormats(
                from: webSnapshot.candidates,
                relativeTo: url,
                requestHeaders: webSnapshot.requestHeaders
            ))
            pageTitle = webSnapshot.title.nonEmpty ?? pageTitle
            pageThumbnail = webSnapshot.thumbnailURL ?? pageThumbnail
        }

        let expandedFormats = await expandingHLSVariants(in: discoveredFormats)
        let verifiedFormats = await verifiedFormats(expandedFormats)
        let compatibleCandidates = expandedFormats.filter {
            $0.isIOSCompatible || $0.isHLS
        }
        let uniqueFormats = preferredFormatsByQuality(
            verifiedFormats.isEmpty ? compatibleCandidates : verifiedFormats
        )

        guard !uniqueFormats.isEmpty else {
            throw DropFrameError.noMediaFound
        }

        return ResolvedMedia(
            sourceURL: url,
            title: pageTitle,
            thumbnailURL: pageThumbnail,
            duration: nil,
            formats: uniqueFormats
        )
    }

    private func rankedFormats(
        from candidates: [MediaCandidate],
        relativeTo pageURL: URL,
        requestHeaders: [String: String]?
    ) -> [MediaFormat] {
        let usableCandidates = candidates.filter {
            !isLikelyAuxiliaryMediaURL($0.rawURL)
        }

        let formats = usableCandidates.compactMap { candidate -> MediaFormat? in
            let normalized = decodeEmbeddedText(candidate.rawURL)
            guard
                let mediaURL = URL(string: normalized, relativeTo: pageURL)?.absoluteURL,
                ["http", "https"].contains(mediaURL.scheme?.lowercased() ?? "")
            else {
                return nil
            }
            let ext = mediaURL.pathExtension.lowercased()
            guard Self.directExtensions.contains(ext) else { return nil }
            let qualitySource = [candidate.labelHint, normalized]
                .compactMap { $0 }
                .joined(separator: " ")
            let label = qualityLabel(in: qualitySource)
                ?? normalizedQualityName(in: qualitySource)
                ?? (ext == "m3u8" ? "Adaptive" : "Original")
            return MediaFormat(
                id: mediaURL.absoluteString,
                url: mediaURL,
                label: label,
                height: qualityHeight(in: qualitySource),
                width: nil,
                fileExtension: ext.isEmpty ? "mp4" : ext,
                estimatedBytes: nil,
                isHLS: ext == "m3u8",
                hasAudio: true,
                requestHeaders: requestHeaders
            )
        }

        let exactFormats = Dictionary(grouping: formats, by: \.url.absoluteString)
            .compactMap(\.value.first)
        return exactFormats.sorted {
            if ($0.height ?? -1) == ($1.height ?? -1) {
                return formatPriority($0) < formatPriority($1)
            }
            return ($0.height ?? -1) > ($1.height ?? -1)
        }
    }

    private func isLikelyAuxiliaryMediaURL(_ value: String) -> Bool {
        firstMatch(
            pattern: #"(?i)(?:^|[/_.?&=-])(?:advert|ads?|ima|preroll|promo|preview|storyboard|sprite|trailer|vast)(?:[/_.?&=-]|$)"#,
            in: value
        ) != nil
    }

    private func expandingHLSVariants(in formats: [MediaFormat]) async -> [MediaFormat] {
        var expanded: [MediaFormat] = []

        for format in formats {
            guard format.isHLS else {
                expanded.append(format)
                continue
            }

            var request = URLRequest(url: format.url)
            request.timeoutInterval = 20
            request.allowsCellularAccess = true
            request.allowsExpensiveNetworkAccess = true
            request.allowsConstrainedNetworkAccess = true
            request.setValue(BrowserRequestHeaders.userAgent, forHTTPHeaderField: "User-Agent")
            for (name, value) in format.requestHeaders ?? [:] {
                request.setValue(value, forHTTPHeaderField: name)
            }

            guard
                let (data, response) = try? await URLSession.shared.data(for: request),
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                data.count < 5_000_000,
                let manifest = String(data: data, encoding: .utf8)
            else {
                expanded.append(format)
                continue
            }

            let lines = manifest
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var variants: [MediaFormat] = []

            for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
                guard
                    let relativePath = lines.dropFirst(index + 1).first(where: {
                        !$0.isEmpty && !$0.hasPrefix("#")
                    }),
                    let variantURL = URL(string: relativePath, relativeTo: format.url)?.absoluteURL
                else {
                    continue
                }

                let width = firstCapture(pattern: #"(?i)RESOLUTION=(\d+)x\d+"#, in: line)
                    .flatMap(Int.init)
                let height = firstCapture(pattern: #"(?i)RESOLUTION=\d+x(\d+)"#, in: line)
                    .flatMap(Int.init)
                    ?? qualityHeight(in: line + " " + relativePath)
                variants.append(
                    MediaFormat(
                        id: variantURL.absoluteString,
                        url: variantURL,
                        label: height.map { "\($0)p" } ?? "Adaptive",
                        height: height,
                        width: width,
                        fileExtension: "m3u8",
                        estimatedBytes: nil,
                        isHLS: true,
                        hasAudio: true,
                        requestHeaders: format.requestHeaders
                    )
                )
            }

            expanded.append(contentsOf: variants.isEmpty ? [format] : variants)
        }

        return Dictionary(grouping: expanded, by: \.url.absoluteString)
            .compactMap(\.value.first)
            .sorted { ($0.height ?? -1) > ($1.height ?? -1) }
    }

    private func verifiedFormats(_ formats: [MediaFormat]) async -> [MediaFormat] {
        await withTaskGroup(of: (Int, MediaFormat?).self) { group in
            for (index, format) in formats.enumerated() {
                group.addTask {
                    let isValid = await Self.preflight(format)
                    return (index, isValid ? format : nil)
                }
            }

            var results: [(Int, MediaFormat)] = []
            for await (index, format) in group {
                if let format {
                    results.append((index, format))
                }
            }
            return results
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    private nonisolated static func preflight(_ format: MediaFormat) async -> Bool {
        let headerProfiles: [[String: String]?] = [
            format.requestHeaders,
            nil
        ]

        for headers in headerProfiles {
            if await preflight(format, headers: headers, requestsRange: true) {
                return true
            }
            if !format.isHLS,
               await preflight(format, headers: headers, requestsRange: false) {
                return true
            }
        }
        return false
    }

    private nonisolated static func preflight(
        _ format: MediaFormat,
        headers: [String: String]?,
        requestsRange: Bool
    ) async -> Bool {
        var request = URLRequest(url: format.url)
        request.timeoutInterval = 15
        request.allowsCellularAccess = true
        request.allowsExpensiveNetworkAccess = true
        request.allowsConstrainedNetworkAccess = true
        request.setValue(BrowserRequestHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            format.isHLS ? "application/vnd.apple.mpegurl,*/*;q=0.8" : "video/*,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        if !format.isHLS && requestsRange {
            request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        }
        for (name, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                return false
            }

            var prefix = Data()
            prefix.reserveCapacity(4_096)
            for try await byte in bytes {
                prefix.append(byte)
                if prefix.count >= 4_096 {
                    break
                }
            }
            guard !prefix.isEmpty else { return false }

            if format.isHLS {
                return String(data: prefix, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("#EXTM3U") == true
            }

            let textPrefix = String(data: prefix, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if textPrefix.contains("wrong key")
                || textPrefix.hasPrefix("<!doctype html")
                || textPrefix.hasPrefix("<html")
                || textPrefix.hasPrefix("{\"")
            {
                return false
            }

            let mimeType = response.mimeType?.lowercased() ?? ""
            if mimeType.hasPrefix("video/") || mimeType == "application/octet-stream" {
                return true
            }
            return prefix.range(of: Data("ftyp".utf8)) != nil
                || prefix.range(of: Data("moov".utf8)) != nil
                || prefix.range(of: Data("moof".utf8)) != nil
        } catch {
            return false
        }
    }

    private func preferredFormatsByQuality(_ formats: [MediaFormat]) -> [MediaFormat] {
        Dictionary(grouping: formats, by: qualityIdentity)
            .compactMap { _, choices in
                choices.min { formatPriority($0) < formatPriority($1) }
            }
            .sorted {
                if ($0.height ?? -1) == ($1.height ?? -1) {
                    return formatPriority($0) < formatPriority($1)
                }
                return ($0.height ?? -1) > ($1.height ?? -1)
            }
    }

    private func qualityHeight(in value: String) -> Int? {
        let heights = [4320, 2160, 1440, 1080, 720, 576, 540, 480, 360, 240, 144]
        for height in heights {
            let patterns = [
                #"(?i)(?:height|quality|resolution|res|label|q)[^0-9]{0,8}"# + "\(height)",
                #"(?i)(?:^|[/_.-])"# + "\(height)" + #"p?(?:[/_.?&=-]|$)"#,
                #"(?i)[?&](?:height|quality|resolution|res|q)="# + "\(height)" + #"(?:[&#]|$)"#,
                #"(?i)[0-9]{3,4}x"# + "\(height)" + #"(?:[^0-9]|$)"#
            ]
            if patterns.contains(where: { firstMatch(pattern: $0, in: value) != nil }) {
                return height
            }
        }
        return nil
    }

    private func qualityLabel(in value: String) -> String? {
        qualityHeight(in: value).map { "\($0)p" }
    }

    private func normalizedQualityName(in value: String) -> String? {
        let uppercase = value.uppercased()
        if uppercase.contains("UHD") || uppercase.contains("4K") { return "2160p" }
        if uppercase.contains("QHD") || uppercase.contains("2K") { return "1440p" }
        if uppercase.contains("FHD") || uppercase.contains("FULL HD") { return "1080p" }
        if uppercase.contains("HD") { return "720p" }
        if uppercase.contains("HQ") { return "HQ" }
        if uppercase.contains("LQ") { return "LQ" }
        if uppercase.contains("SOURCE") || uppercase.contains("ORIGINAL") { return "Original" }
        return nil
    }

    private func qualityIdentity(for format: MediaFormat) -> String {
        if let height = format.height {
            return "height:\(height)"
        }
        return "label:\(format.label.lowercased()):\(format.fileExtension.lowercased())"
    }

    private func formatPriority(_ format: MediaFormat) -> Int {
        switch format.fileExtension.lowercased() {
        case "mp4": 0
        case "m4v": 1
        case "mov": 2
        case "m3u8": 3
        case "webm": 4
        default: 5
        }
    }

    private func title(in html: String) -> String? {
        guard let value = firstCapture(pattern: #"(?is)<title[^>]*>(.*?)</title>"#, in: html) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func metaContent(property: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let forward = #"(?is)<meta[^>]+(?:property|name)\s*=\s*["']"# + escaped + #"["'][^>]+content\s*=\s*["']([^"']+)["']"#
        let reverse = #"(?is)<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]+(?:property|name)\s*=\s*["']"# + escaped + #"["']"#
        return firstCapture(pattern: forward, in: html) ?? firstCapture(pattern: reverse, in: html)
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?is)\b"# + escaped + #"\s*=\s*["']([^"']+)["']"#
        return firstCapture(pattern: pattern, in: tag)
    }

    private func matches(pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    private func firstCapture(pattern: String, in value: String) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[range])
    }

    private func firstMatch(pattern: String, in value: String) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
            let range = Range(match.range, in: value)
        else {
            return nil
        }
        return String(value[range])
    }

    private func decodeEmbeddedText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u003A", with: ":", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u003F", with: "?", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u003D", with: "=", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u0026", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

enum BrowserRequestHeaders {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
}

private struct MediaCandidate: Sendable {
    let rawURL: String
    let labelHint: String?
    let source: MediaCandidateSource
}

private enum MediaCandidateSource: String, Sendable {
    case page
    case network
    case dom
    case player
    case metadata

    var isPlayerMetadata: Bool {
        self == .player || self == .metadata
    }
}

private struct WebProbeSnapshot: Sendable {
    let title: String
    let thumbnailURL: URL?
    let candidates: [MediaCandidate]
    let requestHeaders: [String: String]?
}

@MainActor
private final class WebPageMediaProbe: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<WebProbeSnapshot, Error>?
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var bestSnapshot: WebProbeSnapshot?

    static func inspect(_ url: URL) async throws -> WebProbeSnapshot {
        let probe = WebPageMediaProbe()
        return try await withTaskCancellationHandler {
            try await probe.run(url)
        } onCancel: {
            Task { @MainActor in
                probe.cancelInspection()
            }
        }
    }

    private func cancelInspection() {
        finish(throwing: CancellationError())
    }

    private func run(_ url: URL) async throws -> WebProbeSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.mediaTypesRequiringUserActionForPlayback = []

            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            webView.customUserAgent = BrowserRequestHeaders.userAgent
            self.webView = webView

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.allowsCellularAccess = true
            request.allowsExpensiveNetworkAccess = true
            request.allowsConstrainedNetworkAccess = true
            request.setValue(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )
            webView.load(request)

            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let bestSnapshot {
                    finish(returning: bestSnapshot)
                } else {
                    finish(throwing: DropFrameError.noMediaFound)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            _ = try? await webView.callAsyncJavaScript(
                """
                document.querySelectorAll("video").forEach(video => {
                    video.muted = true;
                    const playAttempt = video.play();
                    if (playAttempt) playAttempt.catch(() => {});
                });
                """,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )

            for delay in [1.0, 1.5, 2.0, 2.5, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                if await self?.capture(from: webView) == true {
                    return
                }
            }

            guard let self else { return }
            if let bestSnapshot {
                finish(returning: bestSnapshot)
            } else {
                finish(throwing: DropFrameError.noMediaFound)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(throwing: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(throwing: error)
    }

    private func capture(from webView: WKWebView) async -> Bool {
        let script = EmbeddedPlayerSourceStrategy.captureScript

        do {
            let rawValue = try await webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            guard
                let result = rawValue as? [String: Any],
                let rawCandidates = result["candidates"] as? [[String: Any]]
            else {
                return false
            }

            let candidates = rawCandidates.compactMap { item -> MediaCandidate? in
                guard let rawURL = item["url"] as? String, !rawURL.isEmpty else {
                    return nil
                }
                let label: String?
                if let string = item["label"] as? String {
                    label = string
                } else if let number = item["label"] as? NSNumber {
                    label = "\(number.intValue)p"
                } else {
                    label = nil
                }
                let source = (item["source"] as? String)
                    .flatMap(MediaCandidateSource.init(rawValue:))
                    ?? .dom
                return MediaCandidate(
                    rawURL: rawURL,
                    labelHint: label,
                    source: source
                )
            }
            guard !candidates.isEmpty else {
                return false
            }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
            var headers = ["Referer": webView.url?.absoluteString ?? ""]
            if let url = webView.url,
               let scheme = url.scheme,
               let host = url.host {
                if let port = url.port {
                    headers["Origin"] = "\(scheme)://\(host):\(port)"
                } else {
                    headers["Origin"] = "\(scheme)://\(host)"
                }
            }
            if let cookieHeader, !cookieHeader.isEmpty {
                headers["Cookie"] = cookieHeader
            }
            headers = headers.filter { !$0.value.isEmpty }

            let snapshot = WebProbeSnapshot(
                title: result["title"] as? String ?? "",
                thumbnailURL: (result["thumbnail"] as? String)
                    .flatMap { URL(string: $0, relativeTo: webView.url)?.absoluteURL },
                candidates: candidates,
                requestHeaders: headers.isEmpty ? nil : headers
            )
            bestSnapshot = mergedSnapshot(bestSnapshot, with: snapshot)
            return false
        } catch {
            return false
        }
    }

    private func mergedSnapshot(
        _ existing: WebProbeSnapshot?,
        with incoming: WebProbeSnapshot
    ) -> WebProbeSnapshot {
        guard let existing else { return incoming }

        var seen = Set<String>()
        let candidates = (existing.candidates + incoming.candidates).filter { candidate in
            let key = candidate.rawURL + "|" + (candidate.labelHint ?? "")
            return seen.insert(key).inserted
        }

        return WebProbeSnapshot(
            title: incoming.title.nonEmpty ?? existing.title,
            thumbnailURL: incoming.thumbnailURL ?? existing.thumbnailURL,
            candidates: candidates,
            requestHeaders: incoming.requestHeaders ?? existing.requestHeaders
        )
    }

    private func finish(returning snapshot: WebProbeSnapshot) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        captureTask?.cancel()
        captureTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        bestSnapshot = nil
        continuation.resume(returning: snapshot)
    }

    private func finish(throwing error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        captureTask?.cancel()
        captureTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        bestSnapshot = nil
        continuation.resume(throwing: error)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
