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
    private let backupSnapshotURL: URL

    init() {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = applicationSupport.appending(path: "DropFrame", directoryHint: .isDirectory)
        mediaURL = documents.appending(path: "DropFrame Media", directoryHint: .isDirectory)
        thumbnailsURL = rootURL.appending(path: "Thumbnails", directoryHint: .isDirectory)
        snapshotURL = rootURL.appending(path: "library.json")
        backupSnapshotURL = mediaURL.appending(path: ".dropframe-library-backup.json")
    }

    func load() -> LibrarySnapshot {
        guard (try? createDirectoriesIfNeeded()) != nil else {
            return .starter
        }

        guard var snapshot = decodedSnapshot(at: snapshotURL)
            ?? decodedSnapshot(at: backupSnapshotURL)
        else {
            var snapshot = LibrarySnapshot.starter
            mergeOrphanedDownloads(into: &snapshot)
            try? save(snapshot)
            return snapshot
        }

        // Never destroy metadata during startup. A system-managed HLS package
        // can be temporarily unavailable while iOS reconnects its offline
        // asset storage. The user can still explicitly remove a missing item.
        repairPersistentPaths(in: &snapshot)
        mergeOrphanedDownloads(into: &snapshot)
        try? save(snapshot)
        return snapshot
    }

    func save(_ snapshot: LibrarySnapshot) throws {
        try createDirectoriesIfNeeded()
        let data = try JSONEncoder.dropFrame.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
        try data.write(to: backupSnapshotURL, options: .atomic)
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
            if let relativePath = hlsContainerRelativePath(from: localPath) {
                let candidate = homeURL
                    .appending(path: relativePath)
                    .standardizedFileURL
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }

                // iOS may rename its UserManagedAssets directory between
                // installs while keeping the finalized package. Match the
                // package by its stable filename instead of an old directory
                // suffix before declaring it unavailable.
                if let recovered = systemManagedPackageURL(
                    named: video.localFilename
                ) {
                    return recovered
                }

                return candidate
            }

            let absoluteURL = URL(fileURLWithPath: localPath).standardizedFileURL
            if fileManager.fileExists(atPath: absoluteURL.path) {
                return absoluteURL
            }

            if let recovered = systemManagedPackageURL(
                named: video.localFilename
            ) {
                return recovered
            }

            return absoluteURL
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
        if let relativePath = hlsContainerRelativePath(from: packageURL.path) {
            return relativePath
        }

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

    private var homeURL: URL {
        URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        ).standardizedFileURL
    }

    private func hlsContainerRelativePath(from storedPath: String) -> String? {
        if !storedPath.hasPrefix("/") {
            return storedPath
        }

        // AVFoundation can report finalized offline packages through a
        // transient "/.nofollow/private/var/..." URL. Persisting that literal
        // URL works only in the callback process and buffers after relaunch.
        // Everything from Library onward is stable inside the app container.
        guard let libraryRange = storedPath.range(
            of: "/Library/com.apple.UserManagedAssets"
        ) else {
            return nil
        }

        return String(storedPath[libraryRange.lowerBound...].dropFirst())
    }

    private func systemManagedPackageURL(named filename: String) -> URL? {
        let libraryURL = homeURL.appending(
            path: "Library",
            directoryHint: .isDirectory
        )
        guard let directories = try? fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for directory in directories
        where directory.lastPathComponent.hasPrefix("com.apple.UserManagedAssets") {
            let candidate = directory
                .appending(path: filename)
                .standardizedFileURL
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func repairPersistentPaths(in snapshot: inout LibrarySnapshot) {
        for index in snapshot.videos.indices {
            guard
                let storedPath = snapshot.videos[index].localPath,
                let relativePath = hlsContainerRelativePath(from: storedPath),
                storedPath != relativePath
            else {
                continue
            }
            snapshot.videos[index].localPath = relativePath
        }
    }

    private func decodedSnapshot(at url: URL) -> LibrarySnapshot? {
        guard
            let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder.dropFrame.decode(
                LibrarySnapshot.self,
                from: data
            )
        else {
            return nil
        }
        return snapshot
    }

    private func mergeOrphanedDownloads(into snapshot: inout LibrarySnapshot) {
        let recovered = recoverOrphanedDownloads()
        let indexedFiles = Set(
            snapshot.videos.compactMap { video -> String? in
                guard video.localPath == nil else { return nil }
                return "\(video.folderID.uuidString)/\(video.localFilename)"
            }
        )
        let missingVideos = recovered.videos.filter { video in
            !indexedFiles.contains(
                "\(video.folderID.uuidString)/\(video.localFilename)"
            )
        }
        guard !missingVideos.isEmpty else { return }

        let missingFolderIDs = Set(missingVideos.map(\.folderID))
        let existingFolderIDs = Set(snapshot.folders.map(\.id))
        let newFolders = recovered.folders.filter {
            missingFolderIDs.contains($0.id) && !existingFolderIDs.contains($0.id)
        }

        snapshot.folders.insert(contentsOf: newFolders, at: 0)
        snapshot.videos.append(contentsOf: missingVideos)
        snapshot.videos.sort { $0.downloadedAt > $1.downloadedAt }
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
