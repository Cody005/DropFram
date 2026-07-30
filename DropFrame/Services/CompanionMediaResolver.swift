import Foundation

actor CompanionMediaResolver: MediaResolving {
    private let baseURL: URL
    private let token: String

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        let endpoint = baseURL.appending(path: "resolve")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(ResolveRequest(url: url.absoluteString))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DropFrameError.companionUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw DropFrameError.unsupportedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw companionError(from: data, statusCode: http.statusCode)
        }

        let payload = try JSONDecoder().decode(ResolveResponse.self, from: data)
        let formats = payload.formats.compactMap { item -> MediaFormat? in
            guard let mediaURL = URL(string: item.url) else { return nil }
            return MediaFormat(
                id: item.id,
                url: mediaURL,
                label: item.label,
                height: item.height,
                width: item.width,
                fileExtension: item.ext,
                estimatedBytes: item.filesize,
                isHLS: item.isHLS,
                hasAudio: item.hasAudio
            )
        }

        guard !formats.isEmpty else {
            throw DropFrameError.noMediaFound
        }

        return ResolvedMedia(
            sourceURL: url,
            title: payload.title,
            thumbnailURL: payload.thumbnail.flatMap(URL.init(string:)),
            duration: payload.duration,
            formats: formats
        )
    }

    func healthSummary() async throws -> String {
        let endpoint = baseURL.appending(path: "health")
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DropFrameError.companionUnavailable
        }
        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw DropFrameError.companionUnavailable
        }

        let health = try JSONDecoder().decode(HealthResponse.self, from: data)
        guard let ytDlp = health.ytDlp, let hasFFmpeg = health.ffmpeg else {
            return "Connected · download engine update required"
        }
        let ffmpeg = hasFFmpeg ? "FFmpeg ready" : "FFmpeg missing"
        let browser = health.browserImpersonation == true ? "Browser ready" : "Browser missing"
        let pipeline = health.pipeline.map { "engine \($0)" } ?? "legacy engine"
        return "Connected · \(pipeline) · yt-dlp \(ytDlp) · \(browser) · \(ffmpeg)"
    }

    private func companionError(from data: Data, statusCode: Int) -> DropFrameError {
        if let response = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            return .companionRejected(response.detail)
        }
        return .companionRejected("The download engine returned HTTP \(statusCode).")
    }
}

private struct ResolveRequest: Encodable {
    let url: String
}

private struct ResolveResponse: Decodable {
    struct Format: Decodable {
        let id: String
        let url: String
        let label: String
        let height: Int?
        let width: Int?
        let ext: String
        let filesize: Int64?
        let isHLS: Bool
        let hasAudio: Bool
    }

    let title: String
    let thumbnail: String?
    let duration: TimeInterval?
    let formats: [Format]
}

private struct HealthResponse: Decodable {
    let status: String
    let pipeline: String?
    let ytDlp: String?
    let ffmpeg: Bool?
    let browserImpersonation: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case pipeline
        case ytDlp = "yt_dlp"
        case ffmpeg
        case browserImpersonation = "browser_impersonation"
    }
}

private struct ErrorResponse: Decodable {
    let detail: String
}
