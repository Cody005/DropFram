import Foundation
import WebKit

enum InstagramURLMatcher {
    static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else {
            return false
        }

        return host == "instagram.com"
            || host.hasSuffix(".instagram.com")
            || host == "instagr.am"
            || host.hasSuffix(".instagr.am")
    }
}

actor InstagramMediaResolver: MediaResolving {
    func resolve(_ url: URL) async throws -> ResolvedMedia {
        guard InstagramURLMatcher.matches(url) else {
            throw DropFrameError.invalidURL
        }

        let result: InstagramWebResult
        do {
            result = try await InstagramWebResolutionSession.resolve(url)
        } catch let error as DropFrameError {
            throw error
        } catch {
            throw DropFrameError.downloadEngineRejected(
                "Instagram could not prepare this public link. Check that the post or Story is still available and try again."
            )
        }

        guard let mediaURL = URL(string: result.mediaURL),
              ["http", "https"].contains(mediaURL.scheme?.lowercased() ?? "")
        else {
            throw DropFrameError.unsupportedResponse
        }

        let title = result.title?.nonEmpty
            ?? instagramFilename(from: mediaURL)
            ?? "Instagram video"
        let thumbnailURL = result.thumbnailURL
            .flatMap(URL.init(string:))
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let identity = "\(url.absoluteString)|\(mediaURL.absoluteString)"

        return ResolvedMedia(
            sourceURL: url,
            title: title,
            thumbnailURL: thumbnailURL,
            duration: nil,
            formats: [
                MediaFormat(
                    id: "instagram-\(stableInstagramHash(identity))",
                    url: mediaURL,
                    label: "Original",
                    height: nil,
                    width: nil,
                    fileExtension: "mp4",
                    estimatedBytes: nil,
                    isHLS: false,
                    hasAudio: true,
                    requestHeaders: [
                        "Referer": "https://sssinstagram.com/"
                    ]
                )
            ]
        )
    }

    private func instagramFilename(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let filename = components.queryItems?.first(where: { $0.name == "filename" })?.value
        else {
            return nil
        }

        let title = URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.nonEmpty
    }

    private func stableInstagramHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private struct InstagramWebResult: Decodable {
    let mediaURL: String
    let thumbnailURL: String?
    let title: String?
}

@MainActor
private final class InstagramWebResolutionSession {
    private static let pageLoadAttempts = 80
    private static let resultAttempts = 120
    private static let pollNanoseconds: UInt64 = 250_000_000

    private let webView: WKWebView

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = BrowserRequestHeaders.userAgent
    }

    static func resolve(_ sourceURL: URL) async throws -> InstagramWebResult {
        let session = InstagramWebResolutionSession()
        return try await session.resolve(sourceURL)
    }

    private func resolve(_ sourceURL: URL) async throws -> InstagramWebResult {
        defer { webView.stopLoading() }

        let resolverURL = resolverPage(for: sourceURL)
        var request = URLRequest(url: resolverURL)
        request.timeoutInterval = 20
        request.allowsCellularAccess = true
        request.allowsExpensiveNetworkAccess = true
        request.allowsConstrainedNetworkAccess = true
        webView.load(request)

        try await waitForPage()
        try await submit(sourceURL)

        for _ in 0..<Self.resultAttempts {
            try Task.checkCancellation()
            do {
                if let result = try await currentResult() {
                    return result
                }
            } catch {
                // The page replaces its result area while resolving. Retry until
                // that short navigation/script transition has completed.
            }
            try await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }

        throw DropFrameError.downloadEngineRejected(
            "Instagram did not return a downloadable video. The post may be private, expired, or temporarily unavailable."
        )
    }

    private func resolverPage(for sourceURL: URL) -> URL {
        let path = sourceURL.path.lowercased()
        let destination: String
        if path.contains("/stories/") {
            destination = "https://sssinstagram.com/story-saver"
        } else if path.contains("/reel/") || path.contains("/reels/") {
            destination = "https://sssinstagram.com/reels-downloader"
        } else {
            destination = "https://sssinstagram.com/en1/video-downloader"
        }
        return URL(string: destination)!
    }

    private func waitForPage() async throws {
        for _ in 0..<Self.pageLoadAttempts {
            try Task.checkCancellation()
            do {
                let state = try await evaluate("document.readyState") as? String
                if state == "interactive" || state == "complete" {
                    let hasInput = try await evaluate(
                        "Boolean(document.querySelector('input[placeholder=\"Paste link here\"]'))"
                    ) as? Bool
                    if hasInput == true {
                        return
                    }
                }
            } catch {
                // WebKit can briefly reject scripts during the initial redirect.
            }
            try await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }

        throw DropFrameError.downloadEngineRejected(
            "Instagram’s resolver page did not finish loading."
        )
    }

    private func submit(_ sourceURL: URL) async throws {
        let encodedURL = try javascriptString(sourceURL.absoluteString)
        let script = """
        (() => {
            const input = document.querySelector('input[placeholder="Paste link here"]');
            const button = Array.from(document.querySelectorAll('button'))
                .find(element => element.textContent.trim() === 'Download');
            if (!input || !button) return false;

            const setter = Object.getOwnPropertyDescriptor(
                HTMLInputElement.prototype,
                'value'
            ).set;
            setter.call(input, \(encodedURL));
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            button.click();
            return true;
        })()
        """

        guard try await evaluate(script) as? Bool == true else {
            throw DropFrameError.downloadEngineRejected(
                "Instagram’s resolver form was unavailable."
            )
        }
    }

    private func currentResult() async throws -> InstagramWebResult? {
        let script = """
        (() => {
            const candidates = Array.from(document.querySelectorAll('a[href]'));
            const link = candidates.find(element => {
                try {
                    const url = new URL(element.href);
                    if (url.hostname !== 'media.sssinstagram.com') return false;
                    const filename = url.searchParams.get('filename') || '';
                    const media = url.searchParams.get('uri') || '';
                    return /\\.(mp4|m4v|mov)$/i.test(filename)
                        || /\\.(mp4|m4v|mov)(?:\\?|$)/i.test(media);
                } catch (_) {
                    return false;
                }
            });
            if (!link) return null;

            let parsed;
            try { parsed = new URL(link.href); } catch (_) { return null; }
            const filename = parsed.searchParams.get('filename') || '';
            const title = filename.replace(/\\.(mp4|m4v|mov)$/i, '').trim();
            const preview = document.querySelector('img[alt="preview"]');
            const thumbnail = preview && /^https?:/i.test(preview.src)
                ? preview.src
                : null;

            return JSON.stringify({
                mediaURL: link.href,
                thumbnailURL: thumbnail,
                title: title || null
            });
        })()
        """

        guard let payload = try await evaluate(script) as? String,
              let data = payload.data(using: .utf8)
        else {
            return nil
        }
        return try JSONDecoder().decode(InstagramWebResult.self, from: data)
    }

    private func javascriptString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw DropFrameError.unsupportedResponse
        }
        return encoded
    }

    private func evaluate(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
