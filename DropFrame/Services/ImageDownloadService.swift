import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ImageDownloadService {
    private static let maximumBytes = 100 * 1_024 * 1_024

    private let store: ImageLibraryStore
    private let session: URLSession

    init(store: ImageLibraryStore) {
        self.store = store
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    func download(
        page: ResolvedImagePage,
        image: RemoteImageCandidate,
        folderID: UUID
    ) async throws -> LibraryImage {
        var request = URLRequest(url: image.url)
        for (header, value) in image.requestHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageDownloadError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ImageDownloadError.rejectedRequest(httpResponse.statusCode)
        }
        guard data.count <= Self.maximumBytes else {
            throw ImageDownloadError.imageTooLarge
        }
        guard !data.isEmpty,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = Self.integerValue(properties[kCGImagePropertyPixelWidth]),
            let height = Self.integerValue(properties[kCGImagePropertyPixelHeight]),
            width > 0,
            height > 0
        else {
            throw ImageDownloadError.invalidImage
        }

        let detectedType = CGImageSourceGetType(source)
            .flatMap { UTType($0 as String) }
        let fileExtension = Self.safeExtension(
            detectedType?.preferredFilenameExtension
                ?? image.fileExtension
        )
        let destinationURL = try await store.destinationURL(
            folderID: folderID,
            title: page.title,
            extension: fileExtension
        )
        try await store.write(data, to: destinationURL)

        return LibraryImage(
            sourceURL: image.url,
            pageURL: page.sourceURL,
            title: page.title,
            localFilename: destinationURL.lastPathComponent,
            folderID: folderID,
            formatLabel: fileExtension.uppercased(),
            fileSize: Int64(data.count),
            pixelWidth: width,
            pixelHeight: height
        )
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func safeExtension(_ value: String) -> String {
        let normalized = value.lowercased()
        let supported = Set([
            "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "tif", "tiff", "avif"
        ])
        return supported.contains(normalized) ? normalized : "jpg"
    }
}
