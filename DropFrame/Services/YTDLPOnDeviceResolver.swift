import Foundation
import OSLog
import PythonKit

actor YTDLPOnDeviceResolver: MediaResolving {
    private let worker = PythonResolverWorker.shared

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        let payload: String

        do {
            payload = try await worker.resolve(url.absoluteString)
        } catch {
            throw DropFrameError.downloadEngineRejected(
                "The on-device resolver could not start: \(error.localizedDescription)"
            )
        }

        guard
            let data = payload.data(using: .utf8),
            let response = try? JSONDecoder().decode(YTDLPResponse.self, from: data)
        else {
            throw DropFrameError.unsupportedResponse
        }

        guard response.success else {
            throw DropFrameError.downloadEngineRejected(
                response.errorMessage ?? "yt-dlp did not return video formats."
            )
        }

        var seen = Set<String>()
        let formats = response.formats.compactMap { format -> MediaFormat? in
            guard
                let mediaURL = URL(string: format.url),
                ["http", "https"].contains(mediaURL.scheme?.lowercased() ?? "")
            else {
                return nil
            }

            let protocolName = format.protocolName.lowercased()
            let isHLS = protocolName.contains("m3u8")
                || mediaURL.pathExtension.lowercased() == "m3u8"
            let fileExtension = isHLS
                ? "m3u8"
                : format.fileExtension.lowercased()
            let isProgressive = ["mp4", "m4v", "mov"].contains(fileExtension)

            // Separate DASH video/audio tracks require a muxer. Until the native
            // muxing stage lands, do not offer a quality that would save silently
            // without sound.
            guard isHLS || (isProgressive && format.hasAudio) else {
                return nil
            }

            let identity = [
                String(format.height ?? 0),
                isHLS ? "hls" : fileExtension,
                format.height == nil ? format.id : ""
            ].joined(separator: "|")
            guard seen.insert(identity).inserted else {
                return nil
            }

            let label = format.height.map { "\($0)p" }
                ?? format.formatNote.nonEmpty
                ?? format.resolution.nonEmpty
                ?? "Original"

            return MediaFormat(
                id: "yt-dlp-\(format.id)-\(formatsStableHash(identity))",
                url: mediaURL,
                label: label,
                height: format.height,
                width: format.width,
                fileExtension: fileExtension,
                estimatedBytes: format.fileSize,
                isHLS: isHLS,
                hasAudio: format.hasAudio,
                requestHeaders: format.httpHeaders
            )
        }
        .sorted {
            if ($0.height ?? -1) == ($1.height ?? -1) {
                return $0.isHLS && !$1.isHLS
            }
            return ($0.height ?? -1) > ($1.height ?? -1)
        }

        guard !formats.isEmpty else {
            throw DropFrameError.noMediaFound
        }

        return ResolvedMedia(
            sourceURL: url,
            title: response.title.nonEmpty ?? url.host ?? "Untitled video",
            thumbnailURL: response.thumbnail.flatMap(URL.init(string:)),
            duration: response.duration,
            formats: formats
        )
    }

    private func formatsStableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

/// PythonKit forwards directly to CPython's reference-counting API without
/// acquiring the GIL. A Swift actor serializes calls, but it does not guarantee
/// that consecutive calls run on the same OS thread. Keep Python initialization,
/// PythonObject use, and PythonObject destruction on one permanent thread.
private final class PythonResolverWorker: @unchecked Sendable {
    static let shared = PythonResolverWorker()

    private struct Job {
        let id: UUID
        let sourceURL: String
        let continuation: CheckedContinuation<
            Result<String, PythonResolverWorkerError>,
            Never
        >
    }

    private let condition = NSCondition()
    private let logger = Logger(
        subsystem: "com.personal.DropFrame",
        category: "OnDeviceResolver"
    )
    private var jobs: [Job] = []
    private var workerThread: Thread?

    private init() {
        let thread = Thread { [weak self] in
            self?.runLoop()
        }
        thread.name = "DropFrame Python resolver"
        thread.qualityOfService = .userInitiated
        workerThread = thread
        thread.start()
    }

    func resolve(_ sourceURL: String) async throws -> String {
        let result = await withCheckedContinuation { continuation in
            let job = Job(
                id: UUID(),
                sourceURL: sourceURL,
                continuation: continuation
            )
            condition.lock()
            jobs.append(job)
            condition.signal()
            condition.unlock()
        }
        return try result.get()
    }

    private func runLoop() {
        while true {
            condition.lock()
            while jobs.isEmpty {
                condition.wait()
            }
            let job = jobs.removeFirst()
            condition.unlock()

            logger.info(
                "yt-dlp request \(job.id.uuidString, privacy: .public) started"
            )
            let result = autoreleasepool {
                execute(sourceURL: job.sourceURL)
            }
            logger.info(
                "yt-dlp request \(job.id.uuidString, privacy: .public) completed"
            )
            job.continuation.resume(returning: result)
        }
    }

    private func execute(
        sourceURL: String
    ) -> Result<String, PythonResolverWorkerError> {
        do {
            let module = try Python.attemptImport("dropframe_ytdlp")
            let result = try module.resolve.throwing.dynamicallyCall(
                withArguments: [sourceURL]
            )
            return .success(String(result) ?? "")
        } catch {
            // Convert the Python error while still on the Python thread. A
            // PythonError can retain PythonObject instances that must not be
            // destroyed later on a Swift cooperative thread.
            return .failure(
                PythonResolverWorkerError(message: String(describing: error))
            )
        }
    }
}

private struct PythonResolverWorkerError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private struct YTDLPResponse: Decodable {
    let success: Bool
    let title: String
    let thumbnail: String?
    let duration: TimeInterval?
    let formats: [YTDLPFormatPayload]
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case success
        case title
        case thumbnail
        case duration
        case formats
        case errorMessage = "error_message"
    }
}

private struct YTDLPFormatPayload: Decodable {
    let id: String
    let url: String
    let protocolName: String
    let fileExtension: String
    let resolution: String
    let formatNote: String
    let width: Int?
    let height: Int?
    let fileSize: Int64?
    let hasAudio: Bool
    let httpHeaders: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case protocolName = "protocol"
        case fileExtension = "extension"
        case resolution
        case formatNote = "format_note"
        case width
        case height
        case fileSize = "filesize"
        case hasAudio = "has_audio"
        case httpHeaders = "http_headers"
    }
}
