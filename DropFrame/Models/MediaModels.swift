import Foundation

struct ResolvedMedia: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sourceURL: URL
    let title: String
    let thumbnailURL: URL?
    let duration: TimeInterval?
    let formats: [MediaFormat]

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        title: String,
        thumbnailURL: URL?,
        duration: TimeInterval?,
        formats: [MediaFormat]
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.formats = formats
    }
}

struct MediaFormat: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let url: URL
    let label: String
    let height: Int?
    let width: Int?
    let fileExtension: String
    let estimatedBytes: Int64?
    let isHLS: Bool
    let hasAudio: Bool
    let requestHeaders: [String: String]?

    init(
        id: String,
        url: URL,
        label: String,
        height: Int?,
        width: Int?,
        fileExtension: String,
        estimatedBytes: Int64?,
        isHLS: Bool,
        hasAudio: Bool,
        requestHeaders: [String: String]? = nil
    ) {
        self.id = id
        self.url = url
        self.label = label
        self.height = height
        self.width = width
        self.fileExtension = fileExtension
        self.estimatedBytes = estimatedBytes
        self.isHLS = isHLS
        self.hasAudio = hasAudio
        self.requestHeaders = requestHeaders
    }

    var isIOSCompatible: Bool {
        !isHLS && ["mp4", "m4v", "mov"].contains(fileExtension.lowercased())
    }

    var resolutionText: String {
        if let height {
            return "\(height)p"
        }
        return label.isEmpty ? "AUTO" : label.uppercased()
    }

    var detailText: String {
        var parts: [String] = []
        if let width, let height {
            parts.append("\(width)×\(height)")
        }
        parts.append(isHLS ? "HLS" : fileExtension.uppercased())
        if !hasAudio {
            parts.append("video only")
        }
        if let estimatedBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

struct MediaFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var symbol: String
    var tintHex: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "play.rectangle.fill",
        tintHex: String = "FF5E52",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tintHex = tintHex
        self.createdAt = createdAt
    }
}

struct LibraryVideo: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sourceURL: URL
    let title: String
    let localFilename: String
    let localPath: String?
    let thumbnailURL: URL?
    let folderID: UUID
    let formatLabel: String
    var fileSize: Int64
    let pixelWidth: Int?
    let pixelHeight: Int?
    let downloadedAt: Date

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        title: String,
        localFilename: String,
        localPath: String? = nil,
        thumbnailURL: URL?,
        folderID: UUID,
        formatLabel: String,
        fileSize: Int64,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        downloadedAt: Date = .now
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.localFilename = localFilename
        self.localPath = localPath
        self.thumbnailURL = thumbnailURL
        self.folderID = folderID
        self.formatLabel = formatLabel
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.downloadedAt = downloadedAt
    }

    var pixelSizeText: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return "\(pixelWidth)×\(pixelHeight)"
    }
}

struct DownloadJob: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case queued
        case downloading
        case finished
        case failed(String)
    }

    let id: UUID
    let mediaTitle: String
    let formatLabel: String
    let isAdaptive: Bool
    var phase: Phase
    var progress: Double?
    var receivedBytes: Int64

    init(
        id: UUID = UUID(),
        mediaTitle: String,
        formatLabel: String,
        isAdaptive: Bool = false,
        phase: Phase = .queued,
        progress: Double? = nil,
        receivedBytes: Int64 = 0
    ) {
        self.id = id
        self.mediaTitle = mediaTitle
        self.formatLabel = formatLabel
        self.isAdaptive = isAdaptive
        self.phase = phase
        self.progress = progress
        self.receivedBytes = receivedBytes
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home
    case library
    case queue
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Grab"
        case .library: "Library"
        case .queue: "Queue"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "sparkles.rectangle.stack.fill"
        case .library: "play.square.stack.fill"
        case .queue: "arrow.down.circle.fill"
        case .settings: "gearshape.fill"
        }
    }
}

enum DropFrameError: LocalizedError {
    case invalidURL
    case noMediaFound
    case companionUnavailable
    case companionRejected(String)
    case unsupportedResponse
    case downloadFailed
    case hlsDownloadFailed
    case incompatibleFormat(String)
    case rejectedMediaRequest(Int)
    case unexpectedDownloadContent
    case invalidMediaFile
    case downloadEngineRejected(String)
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "That doesn’t look like a complete web address."
        case .noMediaFound:
            "DropFrame couldn’t find a downloadable video in this page. The stream may be protected, expired, or use a format the site does not expose."
        case .companionUnavailable:
            "DropFrame couldn’t reach its download engine. Check the connection in Settings and keep the iPhone and computer on the same network."
        case .companionRejected(let detail):
            "The download engine couldn’t read this page: \(detail)"
        case .unsupportedResponse:
            "The resolver returned a response DropFrame couldn’t understand."
        case .downloadFailed:
            "The video could not be saved."
        case .hlsDownloadFailed:
            "This adaptive stream could not be saved for offline playback. The video host may have rejected or expired the stream."
        case .incompatibleFormat(let format):
            "\(format.uppercased()) could not be prepared as an iPhone-playable video."
        case .rejectedMediaRequest(let status):
            "The video host rejected the download request (HTTP \(status)). The link may be signed or expired."
        case .unexpectedDownloadContent:
            "The video host returned a web page instead of the video file after DropFrame retried the supported request methods."
        case .invalidMediaFile:
            "The selected quality returned an empty or invalid video. Nothing was added to your library."
        case .downloadEngineRejected(let detail):
            "The download engine couldn’t prepare this quality: \(detail)"
        case .deleteFailed:
            "DropFrame couldn’t delete that video from the device."
        }
    }
}
