import Foundation

struct LibrarySnapshot: Codable, Sendable {
    var folders: [MediaFolder]
    var videos: [LibraryVideo]
    var settings: AppSettings
}

actor LibraryStore {
    private let fileManager = FileManager.default
    private let rootURL: URL
    private let mediaURL: URL
    private let thumbnailsURL: URL
    private let snapshotURL: URL

    init() {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = applicationSupport.appending(path: "DropFrame", directoryHint: .isDirectory)
        mediaURL = documents.appending(path: "DropFrame Media", directoryHint: .isDirectory)
        thumbnailsURL = rootURL.appending(path: "Thumbnails", directoryHint: .isDirectory)
        snapshotURL = rootURL.appending(path: "library.json")
    }

    func load() -> LibrarySnapshot {
        guard (try? createDirectoriesIfNeeded()) != nil else {
            return .starter
        }

        guard
            let data = try? Data(contentsOf: snapshotURL),
            var snapshot = try? JSONDecoder.dropFrame.decode(LibrarySnapshot.self, from: data)
        else {
            var snapshot = LibrarySnapshot.starter
            let recovered = recoverOrphanedDownloads()
            snapshot.folders.insert(contentsOf: recovered.folders, at: 0)
            snapshot.videos = recovered.videos
            try? save(snapshot)
            return snapshot
        }

        let invalidVideos = snapshot.videos.filter { video in
            let fileURL = localURL(for: video)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
                return true
            }
            if isDirectory.boolValue {
                return fileURL.pathExtension.lowercased() != "movpkg"
            }
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
            return ((attributes?[.size] as? NSNumber)?.int64Value ?? 0) < 4_096
        }
        if !invalidVideos.isEmpty {
            for video in invalidVideos {
                try? delete(video)
            }
            let invalidIDs = Set(invalidVideos.map(\.id))
            snapshot.videos.removeAll { invalidIDs.contains($0.id) }
            try? save(snapshot)
        }
        return snapshot
    }

    func save(_ snapshot: LibrarySnapshot) throws {
        try createDirectoriesIfNeeded()
        let data = try JSONEncoder.dropFrame.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    func destinationURL(folderID: UUID, title: String, extension ext: String) throws -> URL {
        try createDirectoriesIfNeeded()
        let folderURL = mediaURL.appending(path: folderID.uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let safeName = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(8)
            .joined(separator: "-")
            .prefix(70)
        let filename = "\(safeName.isEmpty ? "video" : safeName)-\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "mp4" : ext)"
        return folderURL.appending(path: filename)
    }

    func storeThumbnail(_ data: Data) throws -> URL {
        try createDirectoriesIfNeeded()
        let destination = thumbnailsURL
            .appending(path: "\(UUID().uuidString).jpg")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func localURL(for video: LibraryVideo) -> URL {
        if let localPath = video.localPath, !localPath.isEmpty {
            if !localPath.hasPrefix("/") {
                return URL(
                    fileURLWithPath: NSHomeDirectory(),
                    isDirectory: true
                )
                .appending(path: localPath)
                .standardizedFileURL
            }
            return URL(fileURLWithPath: localPath).standardizedFileURL
        }
        return mediaURL
            .appending(path: video.folderID.uuidString, directoryHint: .isDirectory)
            .appending(path: video.localFilename)
    }

    func delete(_ video: LibraryVideo) throws {
        if let localPath = video.localPath, !localPath.isEmpty {
            let fileURL = localURL(for: video)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard
                fileURL.isFileURL,
                fileURL.pathExtension.lowercased() == "movpkg",
                fileURL.lastPathComponent == video.localFilename
            else {
                throw DropFrameError.deleteFailed
            }
            guard fileManager.fileExists(atPath: fileURL.path) else {
                deleteLocalThumbnail(for: video)
                return
            }
            do {
                try fileManager.removeItem(at: fileURL)
                deleteLocalThumbnail(for: video)
            } catch {
                throw DropFrameError.deleteFailed
            }
            return
        }

        let folderURL = mediaURL
            .appending(path: video.folderID.uuidString, directoryHint: .isDirectory)
            .standardizedFileURL
        let fileURL = folderURL
            .appending(path: video.localFilename)
            .standardizedFileURL

        guard fileURL.deletingLastPathComponent() == folderURL else {
            throw DropFrameError.deleteFailed
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            deleteLocalThumbnail(for: video)
            return
        }
        do {
            try fileManager.removeItem(at: fileURL)
            deleteLocalThumbnail(for: video)
        } catch {
            throw DropFrameError.deleteFailed
        }
    }

    func move(_ video: LibraryVideo, toFolderID destinationFolderID: UUID) throws -> LibraryVideo {
        guard video.folderID != destinationFolderID else {
            return video
        }

        var movedVideo = video

        // AVFoundation owns the physical location of an offline HLS package.
        // Reassign its collection metadata without relocating the package.
        if let localPath = video.localPath, !localPath.isEmpty {
            let packageURL = localURL(for: video)
            guard
                packageURL.pathExtension.lowercased() == "movpkg",
                fileManager.fileExists(atPath: packageURL.path)
            else {
                throw DropFrameError.moveFailed
            }
            movedVideo.folderID = destinationFolderID
            return movedVideo
        }

        try createDirectoriesIfNeeded()
        let sourceFolderURL = mediaURL
            .appending(path: video.folderID.uuidString, directoryHint: .isDirectory)
            .standardizedFileURL
        let sourceURL = sourceFolderURL
            .appending(path: video.localFilename)
            .standardizedFileURL
        let destinationFolderURL = mediaURL
            .appending(path: destinationFolderID.uuidString, directoryHint: .isDirectory)
            .standardizedFileURL
        let destinationURL = destinationFolderURL
            .appending(path: video.localFilename)
            .standardizedFileURL

        guard
            sourceURL.deletingLastPathComponent() == sourceFolderURL,
            destinationURL.deletingLastPathComponent() == destinationFolderURL,
            fileManager.fileExists(atPath: sourceURL.path),
            !fileManager.fileExists(atPath: destinationURL.path)
        else {
            throw DropFrameError.moveFailed
        }

        do {
            try fileManager.createDirectory(
                at: destinationFolderURL,
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            throw DropFrameError.moveFailed
        }

        movedVideo.folderID = destinationFolderID
        return movedVideo
    }

    func persistentPath(for downloadedPackageURL: URL) -> String {
        let packageURL = downloadedPackageURL.standardizedFileURL
        let homeURL = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        ).standardizedFileURL
        let homePrefix = homeURL.path.hasSuffix("/")
            ? homeURL.path
            : homeURL.path + "/"

        guard packageURL.path.hasPrefix(homePrefix) else {
            return packageURL.path
        }
        return String(packageURL.path.dropFirst(homePrefix.count))
    }

    func totalStorageBytes(for videos: [LibraryVideo]) -> Int64 {
        videos.reduce(0) { $0 + $1.fileSize }
    }

    func itemSize(at url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        guard isDirectory.boolValue else {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                ),
                values.isRegularFile == true
            else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func createDirectoriesIfNeeded() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
    }

    private func deleteLocalThumbnail(for video: LibraryVideo) {
        guard let thumbnailURL = video.thumbnailURL, thumbnailURL.isFileURL else {
            return
        }
        let resolvedThumbnailURL = thumbnailURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedThumbnailsDirectory = thumbnailsURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard resolvedThumbnailURL.deletingLastPathComponent() == resolvedThumbnailsDirectory else {
            return
        }
        guard fileManager.fileExists(atPath: resolvedThumbnailURL.path) else {
            return
        }
        try? fileManager.removeItem(at: resolvedThumbnailURL)
    }

    private func recoverOrphanedDownloads() -> (folders: [MediaFolder], videos: [LibraryVideo]) {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: mediaURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }

        var recoveredFolders: [MediaFolder] = []
        var recoveredVideos: [LibraryVideo] = []
        let supportedExtensions = Set(["mp4", "mov", "m4v", "webm", "movpkg"])

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

            let videoFiles = files.filter {
                supportedExtensions.contains($0.pathExtension.lowercased())
            }
            guard !videoFiles.isEmpty else { continue }

            let folderNumber = recoveredFolders.count + 1
            recoveredFolders.append(
                MediaFolder(
                    id: folderID,
                    name: folderNumber == 1 ? "Recovered downloads" : "Recovered downloads \(folderNumber)",
                    symbol: "arrow.counterclockwise.circle.fill",
                    tintHex: "7BE2B8"
                )
            )

            for fileURL in videoFiles {
                let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                recoveredVideos.append(
                    LibraryVideo(
                        sourceURL: fileURL,
                        title: recoveredTitle(from: fileURL),
                        localFilename: fileURL.lastPathComponent,
                        localPath: fileURL.pathExtension.lowercased() == "movpkg"
                            ? fileURL.path
                            : nil,
                        thumbnailURL: nil,
                        folderID: folderID,
                        formatLabel: fileURL.pathExtension.uppercased(),
                        fileSize: itemSize(at: fileURL),
                        downloadedAt: values?.contentModificationDate ?? .now
                    )
                )
            }
        }

        return (
            recoveredFolders,
            recoveredVideos.sorted { $0.downloadedAt > $1.downloadedAt }
        )
    }

    private func recoveredTitle(from fileURL: URL) -> String {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let components = baseName.split(separator: "-")
        guard
            let suffix = components.last,
            suffix.count == 8,
            components.count > 1
        else {
            return baseName
        }
        return components.dropLast().joined(separator: " ")
    }
}

private extension LibrarySnapshot {
    static let starter = LibrarySnapshot(
        folders: [
            MediaFolder(name: "All saves", symbol: "sparkles.tv.fill", tintHex: "FFD60A"),
            MediaFolder(name: "Watch later", symbol: "bookmark.fill", tintHex: "2B5BFF")
        ],
        videos: [],
        settings: AppSettings()
    )
}

private extension JSONEncoder {
    static var dropFrame: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var dropFrame: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
