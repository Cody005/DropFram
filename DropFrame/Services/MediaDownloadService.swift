import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor MediaDownloadService {
    private enum RequestProfile: CaseIterable, Equatable {
        case captured
        case pageContext
        case minimal
    }

    private enum FetchedVideo {
        case file(URL, URLResponse)
        case adaptiveStream(URL)
    }

    private let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
    }

    func download(
        media: ResolvedMedia,
        format: MediaFormat,
        folderID: UUID,
        progress: (@Sendable (Double?, Int64) -> Void)? = nil
    ) async throws -> LibraryVideo {
        if format.isHLS {
            return try await downloadHLS(
                media: media,
                format: format,
                folderID: folderID,
                progress: progress
            )
        }
        guard format.isIOSCompatible else {
            throw DropFrameError.incompatibleFormat(format.fileExtension)
        }

        let fetchedVideo = try await fetchVideo(
            media: media,
            format: format,
            progress: progress
        )
        let temporaryURL: URL
        let response: URLResponse
        switch fetchedVideo {
        case .file(let fileURL, let fileResponse):
            temporaryURL = fileURL
            response = fileResponse
        case .adaptiveStream(let playlistURL):
            let detectedFormat = MediaFormat(
                id: "\(format.id)-detected-hls",
                url: playlistURL,
                label: format.label,
                height: format.height,
                width: format.width,
                fileExtension: "m3u8",
                estimatedBytes: nil,
                isHLS: true,
                hasAudio: true,
                requestHeaders: format.requestHeaders
            )
            return try await downloadHLS(
                media: media,
                format: detectedFormat,
                folderID: folderID,
                progress: progress
            )
        }

        let responseExtension = response.suggestedFilename
            .map { URL(fileURLWithPath: $0).pathExtension }
            .flatMap { $0.isEmpty ? nil : $0 }
        let supportedExtensions = Set(["mp4", "m4v", "mov"])
        let fileExtension = responseExtension
            .map { $0.lowercased() }
            .flatMap { supportedExtensions.contains($0) ? $0 : nil }
            ?? format.fileExtension
        let destination = try await store.destinationURL(
            folderID: folderID,
            title: media.title,
            extension: fileExtension
        )

        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        do {
            try await validateVideo(at: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mediaInfo = await inspectDownloadedMedia(at: destination)
        let thumbnailURL = await storedThumbnailURL(
            from: mediaInfo.thumbnailData,
            fallback: media.thumbnailURL
        )

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

    private func fetchVideo(
        media: ResolvedMedia,
        format: MediaFormat,
        progress: (@Sendable (Double?, Int64) -> Void)?
    ) async throws -> FetchedVideo {
        var lastFailure: DropFrameError = .downloadFailed

        for profile in RequestProfile.allCases {
            var request = URLRequest(url: format.url)
            request.timeoutInterval = 45
            request.allowsCellularAccess = true
            request.allowsExpensiveNetworkAccess = true
            request.allowsConstrainedNetworkAccess = true
            request.setValue(BrowserRequestHeaders.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("video/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            if profile != .minimal {
                for (name, value) in format.requestHeaders ?? [:] {
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }

            switch profile {
            case .captured:
                break
            case .pageContext:
                request.setValue(media.sourceURL.absoluteString, forHTTPHeaderField: "Referer")
                if let origin = originValue(for: media.sourceURL) {
                    request.setValue(origin, forHTTPHeaderField: "Origin")
                }
            case .minimal:
                break
            }

            do {
                progress?(nil, 0)
                let configuration = URLSessionConfiguration.default
                configuration.allowsCellularAccess = true
                configuration.allowsExpensiveNetworkAccess = true
                configuration.allowsConstrainedNetworkAccess = true
                configuration.timeoutIntervalForRequest = 45
                configuration.timeoutIntervalForResource = 1_200
                configuration.waitsForConnectivity = false
                let session = URLSession(configuration: configuration)
                defer { session.finishTasksAndInvalidate() }
                let observer = DownloadProgressObserver(progress: progress)
                let (temporaryURL, response) = try await session.download(
                    for: request,
                    delegate: observer
                )
                guard let http = response as? HTTPURLResponse else {
                    lastFailure = .downloadFailed
                    continue
                }
                if http.statusCode == 410 || http.statusCode == 422 {
                    lastFailure = .rejectedMediaRequest(http.statusCode)
                    break
                }
                guard (200..<300).contains(http.statusCode) else {
                    lastFailure = .rejectedMediaRequest(http.statusCode)
                    continue
                }
                if isHLSPlaylist(at: temporaryURL, response: response) {
                    let playlistURL = adaptiveStreamURL(
                        in: temporaryURL,
                        relativeTo: response.url ?? format.url,
                        preferredHeight: format.height
                            ?? resolutionHeight(in: format.label)
                    )
                    return .adaptiveStream(playlistURL)
                }
                guard !isWebPage(at: temporaryURL, response: response) else {
                    lastFailure = .unexpectedDownloadContent
                    continue
                }
                return .file(temporaryURL, response)
            } catch {
                lastFailure = .downloadFailed
            }
        }

        throw lastFailure
    }

    private func downloadHLS(
        media: ResolvedMedia,
        format: MediaFormat,
        folderID: UUID,
        progress: (@Sendable (Double?, Int64) -> Void)?
    ) async throws -> LibraryVideo {
        do {
            let packageURL = try await OfflineAdaptiveDownload.download(
                url: format.url,
                title: media.title,
                requestHeaders: format.requestHeaders,
                progress: progress
            )

            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: packageURL.path,
                    isDirectory: &isDirectory
                ),
                isDirectory.boolValue
            else {
                throw DropFrameError.invalidMediaFile
            }

            // AVFoundation has already validated and finalized this offline
            // package. Loading tracks, generating an image, or recursively
            // enumerating every HLS segment can block indefinitely for some
            // hosts, so none of that optional enrichment belongs on the save
            // completion path.
            let persistentPath = await store.persistentPath(
                for: packageURL
            )
            return LibraryVideo(
                sourceURL: media.sourceURL,
                title: media.title,
                localFilename: packageURL.lastPathComponent,
                localPath: persistentPath,
                thumbnailURL: media.thumbnailURL,
                folderID: folderID,
                formatLabel: format.resolutionText,
                fileSize: format.estimatedBytes ?? 0,
                pixelWidth: format.width,
                pixelHeight: format.height
            )
        } catch {
            if error is DropFrameError {
                throw error
            }
            throw DropFrameError.hlsDownloadFailed
        }
    }

    private func isWebPage(at fileURL: URL, response: URLResponse) -> Bool {
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.contains("text/html")
            || mimeType.contains("application/xhtml")
            || mimeType.contains("application/json")
            || mimeType.contains("text/plain") {
            return true
        }

        guard let prefix = textPrefix(at: fileURL) else { return false }
        return prefix.contains("<!doctype html")
            || prefix.contains("<html")
            || prefix.contains("<head")
            || prefix.contains("\"detail\"")
    }

    private func isHLSPlaylist(at fileURL: URL, response: URLResponse) -> Bool {
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.contains("mpegurl") {
            return true
        }
        return textPrefix(at: fileURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("#extm3u") == true
    }

    private func adaptiveStreamURL(
        in manifestURL: URL,
        relativeTo baseURL: URL,
        preferredHeight: Int?
    ) -> URL {
        guard let manifest = text(at: manifestURL, upToCount: 512_000) else {
            return baseURL
        }
        let lines = manifest
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var variants: [(height: Int?, url: URL)] = []

        for (index, line) in lines.enumerated()
        where line.uppercased().hasPrefix("#EXT-X-STREAM-INF:") {
            guard
                let path = lines.dropFirst(index + 1).first(where: {
                    !$0.isEmpty && !$0.hasPrefix("#")
                }),
                let url = URL(string: path, relativeTo: baseURL)?.absoluteURL
            else {
                continue
            }
            variants.append((
                height: resolutionHeight(in: line),
                url: url
            ))
        }

        if let preferredHeight,
           let exactMatch = variants.first(where: {
               $0.height == preferredHeight
           }) {
            return exactMatch.url
        }
        if preferredHeight == nil,
           let highestVariant = variants.max(by: {
               ($0.height ?? -1) < ($1.height ?? -1)
           }) {
            return highestVariant.url
        }
        return baseURL
    }

    private func resolutionHeight(in value: String) -> Int? {
        let uppercase = value.uppercased()
        if let resolutionRange = uppercase.range(of: "RESOLUTION=") {
            let suffix = uppercase[resolutionRange.upperBound...]
            let resolution = suffix.prefix {
                $0.isNumber || $0 == "X"
            }
            if let separator = resolution.firstIndex(of: "X") {
                return Int(resolution[resolution.index(after: separator)...])
            }
        }

        for height in [4320, 2160, 1440, 1080, 720, 576, 540, 480, 360, 240, 144]
        where uppercase.contains("\(height)P") {
            return height
        }
        return nil
    }

    private func textPrefix(at fileURL: URL) -> String? {
        text(at: fileURL, upToCount: 1_024)?.lowercased()
    }

    private func text(at fileURL: URL, upToCount count: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: count) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func validateVideo(at fileURL: URL) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= 4_096 else {
            throw DropFrameError.invalidMediaFile
        }

        do {
            let asset = AVURLAsset(url: fileURL)
            guard try await asset.load(.isPlayable) else {
                throw DropFrameError.invalidMediaFile
            }
        } catch let error as DropFrameError {
            throw error
        } catch {
            throw DropFrameError.invalidMediaFile
        }
    }

    private func inspectDownloadedMedia(at fileURL: URL) async -> DownloadedMediaInfo {
        let asset = AVURLAsset(url: fileURL)
        var pixelWidth: Int?
        var pixelHeight: Int?

        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let naturalSize = try? await track.load(.naturalSize),
           let preferredTransform = try? await track.load(.preferredTransform)
        {
            let transformed = CGRect(origin: .zero, size: naturalSize)
                .applying(preferredTransform)
            let width = Int(abs(transformed.width).rounded())
            let height = Int(abs(transformed.height).rounded())
            if width > 0, height > 0 {
                pixelWidth = width
                pixelHeight = height
            }
        }

        let thumbnailData = await makeThumbnailData(for: asset)
        return DownloadedMediaInfo(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            thumbnailData: thumbnailData
        )
    }

    private func makeThumbnailData(for asset: AVAsset) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let duration = try? await asset.load(.duration)
        let durationSeconds = duration
            .map(CMTimeGetSeconds)
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let preferredSeconds = durationSeconds
            .map { min(max($0 * 0.08, 0.5), 3) }
            ?? 0
        let requestedTimes = [
            CMTime(seconds: preferredSeconds, preferredTimescale: 600),
            .zero
        ]

        for time in requestedTimes {
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
            let options = [
                kCGImageDestinationLossyCompressionQuality: 0.82
            ] as CFDictionary
            CGImageDestinationAddImage(destination, image, options)
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

    private func originValue(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

private struct DownloadedMediaInfo: Sendable {
    let pixelWidth: Int?
    let pixelHeight: Int?
    let thumbnailData: Data?
}

private final class DownloadProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double?, Int64) -> Void)?

    init(progress: (@Sendable (Double?, Int64) -> Void)?) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            progress?(nil, totalBytesWritten)
            return
        }
        progress?(
            min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))),
            totalBytesWritten
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
