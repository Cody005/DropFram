import Foundation

actor ImageLinkResolver {
    private struct CandidateSeed {
        let url: URL
        let label: String
        let priority: Int
    }

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
    private static let supportedExtensions = Set([
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "tif", "tiff", "avif"
    ])

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    func resolve(_ sourceURL: URL) async throws -> ResolvedImagePage {
        var request = URLRequest(url: sourceURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,image/avif,image/webp,image/*,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageDownloadError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ImageDownloadError.rejectedRequest(httpResponse.statusCode)
        }

        let finalURL = httpResponse.url ?? sourceURL
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""

        if contentType.hasPrefix("image/")
            || (!contentType.contains("html") && Self.isImageURL(finalURL))
        {
            let candidate = makeCandidate(
                url: finalURL,
                label: "Direct image",
                pageURL: sourceURL
            )
            return ResolvedImagePage(
                sourceURL: sourceURL,
                title: Self.directTitle(from: finalURL),
                images: [candidate]
            )
        }

        guard contentType.contains("html") || Self.looksLikeHTML(data) else {
            throw ImageDownloadError.invalidResponse
        }

        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !html.isEmpty else {
            throw ImageDownloadError.invalidResponse
        }

        let title = pageTitle(in: html, fallbackURL: finalURL)
        let seeds = imageSeeds(in: html, baseURL: finalURL)
        let images = rankedCandidates(
            from: seeds,
            pageURL: finalURL,
            restrictToPrimaryPinImage: Self.isPinterestPinPage(finalURL)
        )
        guard !images.isEmpty else {
            throw ImageDownloadError.noImagesFound
        }

        return ResolvedImagePage(
            sourceURL: sourceURL,
            title: title,
            images: images
        )
    }

    private func imageSeeds(in html: String, baseURL: URL) -> [CandidateSeed] {
        var seeds: [CandidateSeed] = []

        for tag in matches(pattern: #"<meta\b[^>]*>"#, in: html) {
            let attributes = attributes(in: tag)
            let key = (attributes["property"] ?? attributes["name"] ?? "")
                .lowercased()
            guard [
                "og:image", "og:image:url", "og:image:secure_url",
                "twitter:image", "twitter:image:src"
            ].contains(key), let value = attributes["content"],
                let url = resolvedURL(value, relativeTo: baseURL)
            else {
                continue
            }
            seeds.append(CandidateSeed(url: url, label: "Featured image", priority: 1_000))
        }

        for tag in matches(pattern: #"<link\b[^>]*>"#, in: html) {
            let attributes = attributes(in: tag)
            let relationship = (attributes["rel"] ?? "").lowercased()
            guard relationship.contains("image_src"),
                let value = attributes["href"],
                let url = resolvedURL(value, relativeTo: baseURL)
            else {
                continue
            }
            seeds.append(CandidateSeed(url: url, label: "Page image", priority: 900))
        }

        for tag in matches(pattern: #"<img\b[^>]*>"#, in: html) {
            let tagAttributes = attributes(in: tag)
            let alt = cleanedText(tagAttributes["alt"] ?? "")
            let label = alt.isEmpty ? "Page image" : alt

            for name in ["src", "data-src", "data-original", "data-lazy-src"] {
                guard let value = tagAttributes[name],
                    let url = resolvedURL(value, relativeTo: baseURL)
                else {
                    continue
                }
                seeds.append(CandidateSeed(url: url, label: label, priority: 700))
            }

            for name in ["srcset", "data-srcset"] {
                guard let srcset = tagAttributes[name] else { continue }
                for component in srcset.split(separator: ",") {
                    let value = component
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(whereSeparator: { $0.isWhitespace })
                        .first
                        .map(String.init) ?? ""
                    guard let url = resolvedURL(value, relativeTo: baseURL) else {
                        continue
                    }
                    seeds.append(CandidateSeed(url: url, label: label, priority: 760))
                }
            }
        }

        let normalizedHTML = html
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\u002F"#, with: "/", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&")
        let rawPattern = #"https?://[^\s\"'<>\\]+?\.(?:jpe?g|png|webp|gif|heic|heif|tiff?|avif)(?:\?[^\s\"'<>\\]*)?"#
        for value in matches(pattern: rawPattern, in: normalizedHTML) {
            guard let url = resolvedURL(value, relativeTo: baseURL) else {
                continue
            }
            seeds.append(CandidateSeed(url: url, label: "Embedded image", priority: 300))
        }

        return seeds
    }

    private func rankedCandidates(
        from seeds: [CandidateSeed],
        pageURL: URL,
        restrictToPrimaryPinImage: Bool
    ) -> [RemoteImageCandidate] {
        let primaryPinKeys = Set(
            seeds.compactMap { seed -> String? in
                guard seed.priority >= 1_000 else { return nil }
                return Self.pinAssetKey(for: seed.url)
            }
        )
        let strongPinKeys = Set(
            seeds.compactMap { seed -> String? in
                guard seed.priority >= 700 else { return nil }
                return Self.pinAssetKey(for: seed.url)
            }
        )
        var bestSeedByKey: [String: CandidateSeed] = [:]

        for seed in seeds {
            if restrictToPrimaryPinImage,
                !primaryPinKeys.isEmpty,
                !primaryPinKeys.contains(Self.pinAssetKey(for: seed.url) ?? "")
            {
                continue
            }
            let isDeclaredPageImage = seed.priority >= 700
            guard (Self.isImageURL(seed.url) || isDeclaredPageImage),
                !Self.looksLikeInterfaceAsset(seed.url)
            else {
                continue
            }
            if let pinKey = Self.pinAssetKey(for: seed.url),
                seed.priority < 700,
                !strongPinKeys.contains(pinKey)
            {
                continue
            }

            let key = Self.pinAssetKey(for: seed.url) ?? seed.url.absoluteString
            guard let existing = bestSeedByKey[key] else {
                bestSeedByKey[key] = seed
                continue
            }
            if score(seed) > score(existing) {
                bestSeedByKey[key] = seed
            }
        }

        return bestSeedByKey.values
            .sorted { lhs, rhs in
                let lhsScore = score(lhs)
                let rhsScore = score(rhs)
                if lhsScore == rhsScore {
                    return lhs.url.absoluteString < rhs.url.absoluteString
                }
                return lhsScore > rhsScore
            }
            .prefix(30)
            .map { seed in
                makeCandidate(
                    url: seed.url,
                    label: qualityLabel(for: seed),
                    pageURL: pageURL
                )
            }
    }

    private func score(_ seed: CandidateSeed) -> Int {
        let path = seed.url.path.lowercased()
        let qualityBonus: Int
        if path.contains("/originals/") || path.contains("/original/") {
            qualityBonus = 1_200
        } else if path.contains("/1200x/") || path.contains("/2000x/") {
            qualityBonus = 550
        } else if path.contains("/736x/") {
            qualityBonus = 240
        } else {
            qualityBonus = 0
        }
        return seed.priority + qualityBonus
    }

    private func qualityLabel(for seed: CandidateSeed) -> String {
        let path = seed.url.path.lowercased()
        if path.contains("/originals/") || path.contains("/original/") {
            return "Original image"
        }
        if path.contains("/1200x/") || path.contains("/2000x/") {
            return "Large image"
        }
        return seed.label
    }

    private func makeCandidate(
        url: URL,
        label: String,
        pageURL: URL
    ) -> RemoteImageCandidate {
        RemoteImageCandidate(
            url: url,
            label: label,
            fileExtension: Self.fileExtension(for: url),
            requestHeaders: [
                "User-Agent": Self.userAgent,
                "Referer": pageURL.absoluteString,
                "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
            ]
        )
    }

    private func pageTitle(in html: String, fallbackURL: URL) -> String {
        for tag in matches(pattern: #"<meta\b[^>]*>"#, in: html) {
            let tagAttributes = attributes(in: tag)
            let key = (tagAttributes["property"] ?? tagAttributes["name"] ?? "")
                .lowercased()
            if ["og:title", "twitter:title"].contains(key),
                let content = tagAttributes["content"]
            {
                let title = cleanedText(content)
                if !title.isEmpty { return title }
            }
        }

        if let titleTag = matches(
            pattern: #"<title\b[^>]*>(.*?)</title>"#,
            in: html,
            captureGroup: 1
        ).first {
            let title = cleanedText(titleTag)
            if !title.isEmpty { return title }
        }
        return fallbackURL.host ?? "Saved image"
    }

    private func attributes(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*([\"'])(.*?)\2"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return [:]
        }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        var result: [String: String] = [:]
        for match in expression.matches(in: tag, range: range) {
            guard
                let nameRange = Range(match.range(at: 1), in: tag),
                let valueRange = Range(match.range(at: 3), in: tag)
            else {
                continue
            }
            result[String(tag[nameRange]).lowercased()] = cleanedText(String(tag[valueRange]))
        }
        return result
    }

    private func matches(
        pattern: String,
        in text: String,
        captureGroup: Int = 0
    ) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard captureGroup < match.numberOfRanges,
                let resultRange = Range(match.range(at: captureGroup), in: text)
            else {
                return nil
            }
            return String(text[resultRange])
        }
    }

    private func resolvedURL(_ rawValue: String, relativeTo baseURL: URL) -> URL? {
        let decoded = cleanedText(rawValue)
            .replacingOccurrences(of: #"\/"#, with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]{}.,;"))
        guard !decoded.isEmpty,
            let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            return nil
        }
        return url
    }

    private func cleanedText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: #"\u0026"#, with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: #"\u003D"#, with: "=", options: .caseInsensitive)
            .replacingOccurrences(of: #"\u002F"#, with: "/", options: .caseInsensitive)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isImageURL(_ url: URL) -> Bool {
        supportedExtensions.contains(fileExtension(for: url))
    }

    private static func fileExtension(for url: URL) -> String {
        url.pathExtension.lowercased().split(separator: "?").first.map(String.init) ?? ""
    }

    private static func directTitle(from url: URL) -> String {
        let title = url.deletingPathExtension().lastPathComponent
            .removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
        return title.isEmpty ? "Saved image" : title
    }

    private static func looksLikeHTML(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return prefix.contains("<!doctype html") || prefix.contains("<html") || prefix.contains("<head")
    }

    private static func pinAssetKey(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.hasSuffix("pinimg.com") else {
            return nil
        }
        let filename = url.deletingPathExtension().lastPathComponent.lowercased()
        return filename.isEmpty ? nil : "pinimg-\(filename)"
    }

    private static func isPinterestPinPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
            host == "pinterest.com" || host.hasSuffix(".pinterest.com")
        else {
            return false
        }
        return url.pathComponents.contains("pin")
    }

    private static func looksLikeInterfaceAsset(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        return ["logo", "icon", "avatar", "sprite", "favicon", "badge", "emoji"]
            .contains { filename.contains($0) }
    }
}
