import Foundation

enum GrabKind: String, CaseIterable, Identifiable, Sendable {
    case video
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Video"
        case .image: "Images"
        }
    }

    var symbol: String {
        switch self {
        case .video: "play.rectangle.fill"
        case .image: "photo.on.rectangle.angled"
        }
    }
}

struct ResolvedImagePage: Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceURL: URL
    let title: String
    let images: [RemoteImageCandidate]

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        title: String,
        images: [RemoteImageCandidate]
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.images = images
    }
}

struct RemoteImageCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let label: String
    let fileExtension: String
    let requestHeaders: [String: String]

    init(
        url: URL,
        label: String,
        fileExtension: String,
        requestHeaders: [String: String]
    ) {
        id = url.absoluteString
        self.url = url
        self.label = label
        self.fileExtension = fileExtension
        self.requestHeaders = requestHeaders
    }
}

struct LibraryImage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sourceURL: URL
    let pageURL: URL
    let title: String
    let localFilename: String
    var folderID: UUID
    let formatLabel: String
    let fileSize: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    let downloadedAt: Date

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        pageURL: URL,
        title: String,
        localFilename: String,
        folderID: UUID,
        formatLabel: String,
        fileSize: Int64,
        pixelWidth: Int,
        pixelHeight: Int,
        downloadedAt: Date = .now
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.title = title
        self.localFilename = localFilename
        self.folderID = folderID
        self.formatLabel = formatLabel
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.downloadedAt = downloadedAt
    }

    var pixelSizeText: String {
        "\(pixelWidth)×\(pixelHeight)"
    }
}

enum LibraryItem: Identifiable, Hashable, Sendable {
    case video(LibraryVideo)
    case image(LibraryImage)

    var id: String {
        switch self {
        case .video(let video): "video-\(video.id.uuidString)"
        case .image(let image): "image-\(image.id.uuidString)"
        }
    }

    var downloadedAt: Date {
        switch self {
        case .video(let video): video.downloadedAt
        case .image(let image): image.downloadedAt
        }
    }
}

enum ImageDownloadError: LocalizedError {
    case noImagesFound
    case rejectedRequest(Int)
    case invalidResponse
    case imageTooLarge
    case invalidImage
    case saveFailed
    case deleteFailed
    case moveFailed

    var errorDescription: String? {
        switch self {
        case .noImagesFound:
            "DropFrame couldn’t find a downloadable picture on this page. Try opening the picture itself and copying its image address."
        case .rejectedRequest(let status):
            "The image host rejected the request (HTTP \(status)). The link may be private or expired."
        case .invalidResponse:
            "The link did not return a public webpage or image."
        case .imageTooLarge:
            "This image is larger than DropFrame’s 100 MB safety limit."
        case .invalidImage:
            "The selected link did not return a valid image file."
        case .saveFailed:
            "DropFrame couldn’t save that image on this iPhone."
        case .deleteFailed:
            "DropFrame couldn’t delete that image from the device."
        case .moveFailed:
            "DropFrame couldn’t move that image to the selected folder."
        }
    }
}
