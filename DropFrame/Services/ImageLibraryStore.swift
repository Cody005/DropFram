import Foundation

actor ImageLibraryStore {
    private struct Snapshot: Codable {
        var images: [LibraryImage]
    }

    private let fileManager = FileManager.default
    private let metadataURL: URL
    private let backupURL: URL
    private let mediaURL: URL

    init() {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let rootURL = applicationSupport.appending(
            path: "DropFrame",
            directoryHint: .isDirectory
        )
        mediaURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appending(path: "DropFrame Media", directoryHint: .isDirectory)
        metadataURL = rootURL.appending(path: "image-library.json")
        backupURL = mediaURL.appending(path: ".dropframe-image-library-backup.json")
    }

    func load() -> [LibraryImage] {
        guard (try? createDirectoriesIfNeeded()) != nil else { return [] }
        var images = decodedSnapshot(at: metadataURL)?.images
            ?? decodedSnapshot(at: backupURL)?.images
            ?? []
        mergeOrphanedImages(into: &images)
        try? save(images)
        return images.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    func save(_ images: [LibraryImage]) throws {
        try createDirectoriesIfNeeded()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Snapshot(images: images))
        try data.write(to: metadataURL, options: .atomic)
        try data.write(to: backupURL, options: .atomic)
    }

    func destinationURL(
        folderID: UUID,
        title: String,
        extension fileExtension: String
    ) throws -> URL {
        try createDirectoriesIfNeeded()
        let folderURL = mediaURL.appending(
            path: folderID.uuidString,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let safeName = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(8)
            .joined(separator: "-")
            .prefix(70)
        let baseName = safeName.isEmpty ? "image" : String(safeName)
        let filename = "\(baseName)-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        return folderURL.appending(path: filename)
    }

    func write(_ data: Data, to destinationURL: URL) throws {
        let expectedParent = destinationURL.deletingLastPathComponent().standardizedFileURL
        let mediaRoot = mediaURL.standardizedFileURL
        guard expectedParent.deletingLastPathComponent() == mediaRoot else {
            throw ImageDownloadError.saveFailed
        }
        do {
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            throw ImageDownloadError.saveFailed
        }
    }

    func localURL(for image: LibraryImage) -> URL {
        mediaURL
            .appending(path: image.folderID.uuidString, directoryHint: .isDirectory)
            .appending(path: image.localFilename)
    }

    func delete(_ image: LibraryImage) throws {
        let folderURL = mediaURL
            .appending(path: image.folderID.uuidString, directoryHint: .isDirectory)
            .standardizedFileURL
        let fileURL = folderURL
            .appending(path: image.localFilename)
            .standardizedFileURL
        guard fileURL.deletingLastPathComponent() == folderURL else {
            throw ImageDownloadError.deleteFailed
        }
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw ImageDownloadError.deleteFailed
        }
    }

    func move(
        _ image: LibraryImage,
        toFolderID destinationFolderID: UUID
    ) throws -> LibraryImage {
        guard image.folderID != destinationFolderID else { return image }
        try createDirectoriesIfNeeded()

        let sourceFolderURL = mediaURL
            .appending(path: image.folderID.uuidString, directoryHint: .isDirectory)
            .standardizedFileURL
        let sourceURL = sourceFolderURL
            .appending(path: image.localFilename)
            .standardizedFileURL
        let destinationFolderURL = mediaURL
            .appending(path: destinationFolderID.uuidString, directoryHint: .isDirectory)
            .standardizedFileURL
        let destinationURL = destinationFolderURL
            .appending(path: image.localFilename)
            .standardizedFileURL

        guard sourceURL.deletingLastPathComponent() == sourceFolderURL,
            destinationURL.deletingLastPathComponent() == destinationFolderURL,
            fileManager.fileExists(atPath: sourceURL.path),
            !fileManager.fileExists(atPath: destinationURL.path)
        else {
            throw ImageDownloadError.moveFailed
        }

        do {
            try fileManager.createDirectory(
                at: destinationFolderURL,
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            throw ImageDownloadError.moveFailed
        }

        var movedImage = image
        movedImage.folderID = destinationFolderID
        return movedImage
    }

    private func createDirectoriesIfNeeded() throws {
        try fileManager.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: mediaURL, withIntermediateDirectories: true)
    }

    private func decodedSnapshot(at url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    private func mergeOrphanedImages(into images: inout [LibraryImage]) {
        let indexedFiles = Set(images.map { "\($0.folderID.uuidString)/\($0.localFilename)" })
        let recovered = recoverOrphanedImages().filter {
            !indexedFiles.contains("\($0.folderID.uuidString)/\($0.localFilename)")
        }
        guard !recovered.isEmpty else { return }
        images.append(contentsOf: recovered)
        images.sort { $0.downloadedAt > $1.downloadedAt }
    }

    private func recoverOrphanedImages() -> [LibraryImage] {
        let supportedExtensions = Set([
            "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "tif", "tiff", "avif"
        ])
        guard let directories = try? fileManager.contentsOfDirectory(
            at: mediaURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var recovered: [LibraryImage] = []
        for directory in directories {
            guard
                (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                let folderID = UUID(uuidString: directory.lastPathComponent),
                let files = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                continue
            }

            for fileURL in files where supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                let values = try? fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                )
                recovered.append(
                    LibraryImage(
                        sourceURL: fileURL,
                        pageURL: fileURL,
                        title: recoveredTitle(from: fileURL),
                        localFilename: fileURL.lastPathComponent,
                        folderID: folderID,
                        formatLabel: fileURL.pathExtension.uppercased(),
                        fileSize: Int64(values?.fileSize ?? 0),
                        pixelWidth: 0,
                        pixelHeight: 0,
                        downloadedAt: values?.contentModificationDate ?? .now
                    )
                )
            }
        }
        return recovered
    }

    private func recoveredTitle(from fileURL: URL) -> String {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let components = baseName.split(separator: "-")
        guard let suffix = components.last,
            suffix.count == 8,
            components.count > 1
        else {
            return baseName
        }
        return components.dropLast().joined(separator: " ")
    }
}
