import AVFoundation
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

enum YouTubeURLMatcher {
    static func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be"
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com")
    }
}

actor YouTubeMediaResolver: MediaResolving {
    private let worker = PythonResolverWorker.shared
    private let registry = YouTubeDownloadRegistry.shared

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        let payload: String
        do {
            payload = try await worker.resolve(url.absoluteString)
        } catch {
            throw DropFrameError.downloadEngineRejected(
                "The YouTube resolver could not start: \(error.localizedDescription)"
            )
        }

        guard
            let data = payload.data(using: .utf8),
            let response = try? JSONDecoder().decode(
                YouTubeResolverResponse.self,
                from: data
            )
        else {
            throw DropFrameError.unsupportedResponse
        }

        guard response.success else {
            throw DropFrameError.downloadEngineRejected(
                response.errorMessage
                    ?? "YouTube did not return a playable video and audio pair."
            )
        }

        var downloadSpecs: [String: YouTubeDownloadSpec] = [:]
        var formats: [MediaFormat] = []
        var seenHeights = Set<Int>()

        for item in response.formats {
            guard
                let videoURL = URL(string: item.url),
                ["http", "https"].contains(videoURL.scheme?.lowercased() ?? "")
            else {
                continue
            }

            let heightKey = item.height ?? 0
            guard seenHeights.insert(heightKey).inserted else { continue }

            let audioURL = item.audioURL.flatMap(URL.init(string:))
            if item.needsMuxing, audioURL == nil {
                continue
            }

            let identity = "\(url.absoluteString)|\(item.id)|\(heightKey)"
            let formatID = "youtube-\(stableHash(identity))"
            let format = MediaFormat(
                id: formatID,
                url: videoURL,
                label: item.height.map { "\($0)p" } ?? "Original",
                height: item.height,
                width: item.width,
                fileExtension: "mp4",
                estimatedBytes: item.fileSize,
                isHLS: false,
                hasAudio: true,
                requestHeaders: item.videoHeaders
            )
            formats.append(format)
            downloadSpecs[formatID] = YouTubeDownloadSpec(
                sourceURL: url,
                videoURL: videoURL,
                audioURL: audioURL,
                videoHeaders: item.videoHeaders,
                audioHeaders: item.audioHeaders,
                videoFileSize: item.videoFileSize,
                audioFileSize: item.audioFileSize
            )
        }

        guard !formats.isEmpty else {
            throw DropFrameError.downloadEngineRejected(
                "YouTube did not expose an iPhone-compatible video and audio pair."
            )
        }

        await registry.replaceEntries(
            for: url,
            with: downloadSpecs
        )

        return ResolvedMedia(
            sourceURL: url,
            title: response.title.nonEmpty ?? "YouTube video",
            thumbnailURL: response.thumbnail.flatMap(URL.init(string:)),
            duration: response.duration,
            formats: formats.sorted {
                ($0.height ?? -1) > ($1.height ?? -1)
            }
        )
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

actor YouTubeMediaDownloader {
    private let store: LibraryStore
    private let registry = YouTubeDownloadRegistry.shared
    private let logger = Logger(
        subsystem: "com.personal.DropFrame",
        category: "YouTubeDownload"
    )

    init(store: LibraryStore) {
        self.store = store
    }

    func download(
        media: ResolvedMedia,
        format: MediaFormat,
        folderID: UUID,
        progress: (@Sendable (Double?, Int64) -> Void)?
    ) async throws -> LibraryVideo {
        guard
            format.id.hasPrefix("youtube-"),
            let spec = await registry.entry(
                for: format.id,
                sourceURL: media.sourceURL
            )
        else {
            throw DropFrameError.downloadEngineRejected(
                "This YouTube selection expired. Fetch the video again and retry."
            )
        }

        let hasSeparateAudio = spec.audioURL != nil
        let weights = progressWeights(for: spec)
        let videoURL = try await downloadTrack(
            from: spec.videoURL,
            headers: spec.videoHeaders,
            sourceURL: media.sourceURL,
            fileExtension: "mp4",
            expectedBytes: spec.videoFileSize,
            progressBase: 0,
            progressWeight: hasSeparateAudio ? weights.video * 0.94 : 0.96,
            receivedBytesBase: 0,
            progress: progress
        )
        var temporaryFiles = [videoURL]
        defer {
            for url in temporaryFiles {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let preparedURL: URL
        if let audioURL = spec.audioURL {
            let videoBytes = fileSize(at: videoURL)
            let audioFile = try await downloadTrack(
                from: audioURL,
                headers: spec.audioHeaders,
                sourceURL: media.sourceURL,
                fileExtension: "m4a",
                expectedBytes: spec.audioFileSize,
                progressBase: weights.video * 0.94,
                progressWeight: weights.audio * 0.94,
                receivedBytesBase: videoBytes,
                progress: progress
            )
            temporaryFiles.append(audioFile)
            progress?(0.95, videoBytes + fileSize(at: audioFile))

            preparedURL = try await muxVideo(
                videoURL: videoURL,
                audioURL: audioFile
            )
            temporaryFiles.append(preparedURL)
        } else {
            preparedURL = videoURL
        }

        let destination = try await store.destinationURL(
            folderID: folderID,
            title: media.title,
            extension: "mp4"
        )
        try FileManager.default.moveItem(at: preparedURL, to: destination)

        do {
            try await validateVideoAndAudio(at: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let size = fileSize(at: destination)
        let mediaInfo = await inspectDownloadedMedia(at: destination)
        let thumbnailURL = await storedThumbnailURL(
            from: mediaInfo.thumbnailData,
            fallback: media.thumbnailURL
        )
        progress?(1, size)

        return LibraryVideo(
            sourceURL: media.sourceURL,
            title: media.title,
            localFilename: destination.lastPathComponent,
            thumbnailURL: thumbnailURL,
            folderID: folderID,
            formatLabel: format.resolutionText,
            fileSize: size,
            pixelWidth: mediaInfo.pixelWidth,
            pixelHeight: mediaInfo.pixelHeight
        )
    }

    private func downloadTrack(
        from url: URL,
        headers: [String: String]?,
        sourceURL: URL,
        fileExtension: String,
        expectedBytes: Int64?,
        progressBase: Double,
        progressWeight: Double,
        receivedBytesBase: Int64,
        progress: (@Sendable (Double?, Int64) -> Void)?
    ) async throws -> URL {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let stableURL = FileManager.default.temporaryDirectory
            .appending(path: "youtube-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        guard FileManager.default.createFile(
            atPath: stableURL.path,
            contents: nil
        ) else {
            throw DropFrameError.downloadFailed
        }

        do {
            try await downloadTrackInRanges(
                from: url,
                headers: headers,
                sourceURL: sourceURL,
                expectedBytes: expectedBytes,
                to: stableURL,
                session: session,
                progressBase: progressBase,
                progressWeight: progressWeight,
                receivedBytesBase: receivedBytesBase,
                progress: progress
            )
        } catch {
            try? FileManager.default.removeItem(at: stableURL)
            throw error
        }

        guard fileSize(at: stableURL) >= 4_096 else {
            try? FileManager.default.removeItem(at: stableURL)
            throw DropFrameError.invalidMediaFile
        }
        return stableURL
    }

    private func downloadTrackInRanges(
        from url: URL,
        headers: [String: String]?,
        sourceURL: URL,
        expectedBytes: Int64?,
        to destinationURL: URL,
        session: URLSession,
        progressBase: Double,
        progressWeight: Double,
        receivedBytesBase: Int64,
        progress: (@Sendable (Double?, Int64) -> Void)?
    ) async throws {
        let chunkSize: Int64 = 8 * 1_024 * 1_024
        var offset: Int64 = 0
        var totalBytes = expectedBytes.flatMap { $0 > 0 ? $0 : nil }
        progress?(progressBase, receivedBytesBase)

        logger.info(
            "YouTube track download started; expected bytes: \(totalBytes ?? 0, privacy: .public)"
        )

        while totalBytes == nil || offset < totalBytes! {
            let requestedEnd = totalBytes.map {
                min(offset + chunkSize - 1, $0 - 1)
            } ?? (offset + chunkSize - 1)
            var lastError: Error = DropFrameError.downloadFailed
            var completedChunk = false

            for attempt in 0..<3 {
                do {
                    var request = trackRequest(
                        url: url,
                        headers: headers,
                        sourceURL: sourceURL
                    )
                    request.setValue(
                        "bytes=\(offset)-\(requestedEnd)",
                        forHTTPHeaderField: "Range"
                    )

                    let observer = YouTubeRangeProgressObserver(
                        trackOffset: offset,
                        totalTrackBytes: totalBytes,
                        base: progressBase,
                        weight: progressWeight,
                        receivedBytesBase: receivedBytesBase,
                        progress: progress
                    )
                    let (temporaryURL, response) = try await session.download(
                        for: request,
                        delegate: observer
                    )
                    guard let http = response as? HTTPURLResponse else {
                        throw DropFrameError.downloadFailed
                    }
                    guard http.statusCode == 206 || http.statusCode == 200 else {
                        throw DropFrameError.rejectedMediaRequest(http.statusCode)
                    }
                    guard !isWebPage(at: temporaryURL, response: response) else {
                        throw DropFrameError.unexpectedDownloadContent
                    }

                    let chunkBytes = fileSize(at: temporaryURL)
                    guard chunkBytes > 0 else {
                        throw DropFrameError.invalidMediaFile
                    }

                    if let responseTotal = totalLength(from: http) {
                        totalBytes = responseTotal
                    } else if http.statusCode == 200 {
                        totalBytes = chunkBytes
                    }

                    try appendFile(at: temporaryURL, to: destinationURL)
                    offset += chunkBytes
                    let fraction = totalBytes.map {
                        min(1, max(0, Double(offset) / Double($0)))
                    }
                    progress?(
                        fraction.map { progressBase + $0 * progressWeight },
                        receivedBytesBase + offset
                    )
                    completedChunk = true

                    // A 200 response ignored Range and returned the complete
                    // track in one disk-backed download.
                    if http.statusCode == 200 {
                        totalBytes = offset
                    }
                    break
                } catch {
                    lastError = error
                    logger.warning(
                        "YouTube range request failed at byte \(offset, privacy: .public), attempt \(attempt + 1, privacy: .public)"
                    )
                }
            }

            guard completedChunk else { throw lastError }
        }

        logger.info(
            "YouTube track download completed; bytes: \(offset, privacy: .public)"
        )
    }

    private func trackRequest(
        url: URL,
        headers: [String: String]?,
        sourceURL: URL
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.allowsCellularAccess = true
        request.allowsExpensiveNetworkAccess = true
        request.allowsConstrainedNetworkAccess = true
        request.setValue(
            BrowserRequestHeaders.userAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("video/*,audio/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(sourceURL.absoluteString, forHTTPHeaderField: "Referer")
        for (name, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func totalLength(from response: HTTPURLResponse) -> Int64? {
        guard
            let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
            let slash = contentRange.lastIndex(of: "/"),
            let total = Int64(contentRange[contentRange.index(after: slash)...]),
            total > 0
        else {
            return nil
        }
        return total
    }

    private func appendFile(at sourceURL: URL, to destinationURL: URL) throws {
        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? source.close()
            try? destination.close()
        }
        try destination.seekToEnd()

        while let data = try source.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try destination.write(contentsOf: data)
        }
    }

    private func muxVideo(videoURL: URL, audioURL: URL) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard
            let videoTrack = try await videoAsset.loadTracks(
                withMediaType: .video
            ).first,
            let audioTrack = try await audioAsset.loadTracks(
                withMediaType: .audio
            ).first
        else {
            throw DropFrameError.invalidMediaFile
        }

        let videoTimeRange = try await videoTrack.load(.timeRange)
        let audioTimeRange = try await audioTrack.load(.timeRange)
        guard
            videoTimeRange.duration.isNumeric,
            audioTimeRange.duration.isNumeric,
            CMTimeCompare(videoTimeRange.duration, .zero) > 0,
            CMTimeCompare(audioTimeRange.duration, .zero) > 0
        else {
            throw DropFrameError.invalidMediaFile
        }

        let composition = AVMutableComposition()
        guard
            let compositionVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ),
            let compositionAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw DropFrameError.downloadFailed
        }

        try compositionVideo.insertTimeRange(
            videoTimeRange,
            of: videoTrack,
            at: .zero
        )
        compositionVideo.preferredTransform = try await videoTrack.load(
            .preferredTransform
        )

        let audioDuration = CMTimeMinimum(
            videoTimeRange.duration,
            audioTimeRange.duration
        )
        try compositionAudio.insertTimeRange(
            CMTimeRange(start: audioTimeRange.start, duration: audioDuration),
            of: audioTrack,
            at: .zero
        )

        guard
            let exporter = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetPassthrough
            ),
            exporter.supportedFileTypes.contains(.mp4)
        else {
            throw DropFrameError.downloadEngineRejected(
                "This YouTube quality could not be combined without recompressing it."
            )
        }

        exporter.shouldOptimizeForNetworkUse = true
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "youtube-merged-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        do {
            if #available(iOS 18.0, *) {
                try await exporter.export(to: outputURL, as: .mp4)
            } else {
                try await exportLegacy(
                    exporter,
                    to: outputURL,
                    fileType: .mp4
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw DropFrameError.downloadEngineRejected(
                "The YouTube video and audio tracks could not be combined on this iPhone."
            )
        }
        return outputURL
    }

    private func exportLegacy(
        _ exporter: AVAssetExportSession,
        to outputURL: URL,
        fileType: AVFileType
    ) async throws {
        exporter.outputURL = outputURL
        exporter.outputFileType = fileType
        let exporterBox = LegacyExportSessionBox(exporter)
        try await withCheckedThrowingContinuation { continuation in
            exporterBox.exporter.exportAsynchronously {
                let exporter = exporterBox.exporter
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(
                        throwing: exporter.error ?? DropFrameError.downloadFailed
                    )
                default:
                    continuation.resume(throwing: DropFrameError.downloadFailed)
                }
            }
        }
    }

    private func validateVideoAndAudio(at fileURL: URL) async throws {
        guard fileSize(at: fileURL) >= 4_096 else {
            throw DropFrameError.invalidMediaFile
        }
        let asset = AVURLAsset(url: fileURL)
        guard
            try await asset.load(.isPlayable),
            !(try await asset.loadTracks(withMediaType: .video)).isEmpty,
            !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        else {
            throw DropFrameError.downloadEngineRejected(
                "YouTube returned a video without a playable audio track."
            )
        }
    }

    private func inspectDownloadedMedia(at fileURL: URL) async -> YouTubeMediaInfo {
        let asset = AVURLAsset(url: fileURL)
        var pixelWidth: Int?
        var pixelHeight: Int?

        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let naturalSize = try? await track.load(.naturalSize),
           let preferredTransform = try? await track.load(.preferredTransform) {
            let transformed = CGRect(origin: .zero, size: naturalSize)
                .applying(preferredTransform)
            let width = Int(abs(transformed.width).rounded())
            let height = Int(abs(transformed.height).rounded())
            if width > 0, height > 0 {
                pixelWidth = width
                pixelHeight = height
            }
        }

        return YouTubeMediaInfo(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            thumbnailData: await makeThumbnailData(for: asset)
        )
    }

    private func makeThumbnailData(for asset: AVAsset) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        for time in [CMTime(seconds: 1, preferredTimescale: 600), .zero] {
            guard let image = try? await generator.image(at: time).image else {
                continue
            }
            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data,
                    UTType.jpeg.identifier as CFString,
                    1,
                    nil
                )
            else {
                continue
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
            )
            if CGImageDestinationFinalize(destination) {
                return data as Data
            }
        }
        return nil
    }

    private func storedThumbnailURL(
        from thumbnailData: Data?,
        fallback: URL?
    ) async -> URL? {
        guard let thumbnailData else { return fallback }
        return (try? await store.storeThumbnail(thumbnailData)) ?? fallback
    }

    private func progressWeights(
        for spec: YouTubeDownloadSpec
    ) -> (video: Double, audio: Double) {
        guard spec.audioURL != nil else { return (1, 0) }
        let videoBytes = max(spec.videoFileSize ?? 0, 0)
        let audioBytes = max(spec.audioFileSize ?? 0, 0)
        let total = videoBytes + audioBytes
        guard total > 0 else { return (0.84, 0.16) }
        let videoWeight = min(
            0.94,
            max(0.65, Double(videoBytes) / Double(total))
        )
        return (videoWeight, 1 - videoWeight)
    }

    private func isWebPage(at fileURL: URL, response: URLResponse) -> Bool {
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.contains("text/html")
            || mimeType.contains("application/json")
            || mimeType.contains("text/plain") {
            return true
        }
        guard
            let handle = try? FileHandle(forReadingFrom: fileURL),
            let data = try? handle.read(upToCount: 1_024)
        else {
            return false
        }
        try? handle.close()
        let prefix = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        return prefix.contains("<!doctype html") || prefix.contains("<html")
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

private final class LegacyExportSessionBox: @unchecked Sendable {
    let exporter: AVAssetExportSession

    init(_ exporter: AVAssetExportSession) {
        self.exporter = exporter
    }
}

private actor YouTubeDownloadRegistry {
    static let shared = YouTubeDownloadRegistry()

    private var entries: [String: YouTubeDownloadSpec] = [:]
    private var formatIDsBySource: [URL: Set<String>] = [:]

    func replaceEntries(
        for sourceURL: URL,
        with newEntries: [String: YouTubeDownloadSpec]
    ) {
        for formatID in formatIDsBySource[sourceURL] ?? [] {
            entries.removeValue(forKey: formatID)
        }
        entries.merge(newEntries) { _, new in new }
        formatIDsBySource[sourceURL] = Set(newEntries.keys)
    }

    func entry(for formatID: String, sourceURL: URL) -> YouTubeDownloadSpec? {
        guard let entry = entries[formatID], entry.sourceURL == sourceURL else {
            return nil
        }
        return entry
    }
}

private struct YouTubeDownloadSpec: Sendable {
    let sourceURL: URL
    let videoURL: URL
    let audioURL: URL?
    let videoHeaders: [String: String]?
    let audioHeaders: [String: String]?
    let videoFileSize: Int64?
    let audioFileSize: Int64?
}

private struct YouTubeResolverResponse: Decodable {
    let success: Bool
    let title: String
    let thumbnail: String?
    let duration: TimeInterval?
    let formats: [YouTubeFormatPayload]
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

private struct YouTubeFormatPayload: Decodable {
    let id: String
    let url: String
    let audioURL: String?
    let width: Int?
    let height: Int?
    let fileSize: Int64?
    let videoFileSize: Int64?
    let audioFileSize: Int64?
    let videoHeaders: [String: String]?
    let audioHeaders: [String: String]?
    let needsMuxing: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case audioURL = "audio_url"
        case width
        case height
        case fileSize = "filesize"
        case videoFileSize = "video_filesize"
        case audioFileSize = "audio_filesize"
        case videoHeaders = "video_headers"
        case audioHeaders = "audio_headers"
        case needsMuxing = "needs_muxing"
    }
}

private struct YouTubeMediaInfo: Sendable {
    let pixelWidth: Int?
    let pixelHeight: Int?
    let thumbnailData: Data?
}

private final class YouTubeRangeProgressObserver: NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable {
    private let trackOffset: Int64
    private let totalTrackBytes: Int64?
    private let base: Double
    private let weight: Double
    private let receivedBytesBase: Int64
    private let progress: (@Sendable (Double?, Int64) -> Void)?

    init(
        trackOffset: Int64,
        totalTrackBytes: Int64?,
        base: Double,
        weight: Double,
        receivedBytesBase: Int64,
        progress: (@Sendable (Double?, Int64) -> Void)?
    ) {
        self.trackOffset = trackOffset
        self.totalTrackBytes = totalTrackBytes
        self.base = base
        self.weight = weight
        self.receivedBytesBase = receivedBytesBase
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let trackBytesWritten = trackOffset + totalBytesWritten
        let received = receivedBytesBase + trackBytesWritten
        guard let totalTrackBytes, totalTrackBytes > 0 else {
            progress?(nil, received)
            return
        }
        let fraction = min(
            1,
            max(0, Double(trackBytesWritten) / Double(totalTrackBytes))
        )
        progress?(base + fraction * weight, received)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
