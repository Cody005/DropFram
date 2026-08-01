import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var selectedTab: AppTab = .home
    var linkText = ""
    var resolvedMedia: ResolvedMedia?
    var resolvedImagePage: ResolvedImagePage?
    var isResolving = false
    var isResolvingImages = false
    var folders: [MediaFolder] = []
    var videos: [LibraryVideo] = []
    var images: [LibraryImage] = []
    var jobs: [DownloadJob] = []
    var settings = AppSettings()
    var presentedError: String?
    var isResultPresented = false
    var isImageResultPresented = false
    var playerVideo: LibraryVideo?
    var presentedImage: LibraryImage?

    private let store: LibraryStore
    private let resolver: MediaResolver
    private let downloader: MediaDownloadService
    private let imageStore: ImageLibraryStore
    private let imageResolver: ImageLinkResolver
    private let imageDownloader: ImageDownloadService
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    init() {
        let store = LibraryStore()
        let imageStore = ImageLibraryStore()
        self.store = store
        self.imageStore = imageStore
        resolver = MediaResolver()
        downloader = MediaDownloadService(store: store)
        imageResolver = ImageLinkResolver()
        imageDownloader = ImageDownloadService(store: imageStore)
        settings = AppSettingsCache.load() ?? AppSettings()

        restoreTask = Task { [weak self] in
            await self?.restoreLibrary()
        }
    }

    var storageText: String {
        ByteCountFormatter.string(
            fromByteCount: videos.reduce(0) { $0 + $1.fileSize }
                + images.reduce(0) { $0 + $1.fileSize },
            countStyle: .file
        )
    }

    var libraryItemCount: Int {
        videos.count + images.count
    }

    var latestItem: LibraryItem? {
        let latestVideo = videos.first.map(LibraryItem.video)
        let latestImage = images.first.map(LibraryItem.image)
        return [latestVideo, latestImage]
            .compactMap { $0 }
            .max { $0.downloadedAt < $1.downloadedAt }
    }

    func inspectLink() async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }

        do {
            await restoreTask?.value
            let url = try normalizedURL(from: linkText)
            resolvedMedia = nil
            isResultPresented = false
            resolvedMedia = try await resolver.resolve(url, settings: settings)
            isResultPresented = true
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func inspectImages() async {
        guard !isResolvingImages else { return }
        isResolvingImages = true
        defer { isResolvingImages = false }

        do {
            await restoreTask?.value
            let url = try normalizedURL(from: linkText)
            resolvedImagePage = nil
            isImageResultPresented = false
            resolvedImagePage = try await imageResolver.resolve(url)
            isImageResultPresented = true
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func download(format: MediaFormat, to folder: MediaFolder) async {
        guard let resolvedMedia else { return }
        var job = DownloadJob(
            mediaTitle: resolvedMedia.title,
            formatLabel: format.resolutionText,
            isAdaptive: format.isHLS,
            phase: .downloading
        )
        jobs.insert(job, at: 0)
        let jobID = job.id
        isResultPresented = false
        selectedTab = .queue

        do {
            let video = try await downloader.download(
                media: resolvedMedia,
                format: format,
                folderID: folder.id,
                progress: { [weak self] value, receivedBytes in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(
                            value,
                            receivedBytes: receivedBytes,
                            for: jobID
                        )
                    }
                }
            )
            videos.insert(video, at: 0)
            job.phase = .finished
            replace(job)
            await persist()
            if video.fileSize <= 0 {
                refreshFileSizeLater(for: video.id)
            }
        } catch {
            job.phase = .failed(error.localizedDescription)
            replace(job)
            presentedError = error.localizedDescription
        }
    }

    func download(
        image: RemoteImageCandidate,
        from page: ResolvedImagePage,
        to folder: MediaFolder
    ) async {
        var job = DownloadJob(
            mediaTitle: page.title,
            formatLabel: image.fileExtension.isEmpty
                ? "IMAGE"
                : image.fileExtension.uppercased(),
            phase: .downloading
        )
        jobs.insert(job, at: 0)
        isImageResultPresented = false
        selectedTab = .queue

        do {
            let savedImage = try await imageDownloader.download(
                page: page,
                image: image,
                folderID: folder.id
            )
            images.insert(savedImage, at: 0)
            job.phase = .finished
            replace(job)
            await persistImages()
        } catch {
            job.phase = .failed(error.localizedDescription)
            replace(job)
            presentedError = error.localizedDescription
        }
    }

    func createFolder(named rawName: String, symbol: String, tintHex: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        folders.append(MediaFolder(name: name, symbol: symbol, tintHex: tintHex))
        Task { await persist() }
    }

    func saveSettings() {
        AppSettingsCache.save(settings)
        Task { await persist() }
    }

    func videos(in folder: MediaFolder) -> [LibraryVideo] {
        videos.filter { $0.folderID == folder.id }
    }

    func images(in folder: MediaFolder) -> [LibraryImage] {
        images.filter { $0.folderID == folder.id }
    }

    func items(in folder: MediaFolder) -> [LibraryItem] {
        let folderVideos = videos(in: folder).map(LibraryItem.video)
        let folderImages = images(in: folder).map(LibraryItem.image)
        return (folderVideos + folderImages)
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }

    func localURL(for video: LibraryVideo) async -> URL {
        await store.localURL(for: video)
    }

    func localURL(for image: LibraryImage) async -> URL {
        await imageStore.localURL(for: image)
    }

    func play(_ video: LibraryVideo) {
        playerVideo = video
    }

    func view(_ image: LibraryImage) {
        presentedImage = image
    }

    func delete(_ video: LibraryVideo) async {
        do {
            try await store.delete(video)
            videos.removeAll { $0.id == video.id }
            if playerVideo?.id == video.id {
                playerVideo = nil
            }
            await persist()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func delete(_ image: LibraryImage) async {
        do {
            try await imageStore.delete(image)
            images.removeAll { $0.id == image.id }
            if presentedImage?.id == image.id {
                presentedImage = nil
            }
            await persistImages()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    @discardableResult
    func move(_ video: LibraryVideo, to folder: MediaFolder) async -> Bool {
        guard video.folderID != folder.id else { return true }

        do {
            let movedVideo = try await store.move(
                video,
                toFolderID: folder.id
            )
            guard let index = videos.firstIndex(where: { $0.id == video.id }) else {
                return false
            }
            videos[index] = movedVideo
            if playerVideo?.id == video.id {
                playerVideo = movedVideo
            }
            await persist()
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func move(_ image: LibraryImage, to folder: MediaFolder) async -> Bool {
        guard image.folderID != folder.id else { return true }

        do {
            let movedImage = try await imageStore.move(
                image,
                toFolderID: folder.id
            )
            guard let index = images.firstIndex(where: { $0.id == image.id }) else {
                return false
            }
            images[index] = movedImage
            if presentedImage?.id == image.id {
                presentedImage = movedImage
            }
            await persistImages()
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    private func replace(_ job: DownloadJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
    }

    private func updateProgress(
        _ progress: Double?,
        receivedBytes: Int64,
        for jobID: UUID
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].progress = progress
        jobs[index].receivedBytes = receivedBytes
    }

    private func normalizedURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DropFrameError.invalidURL }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard
            let url = URL(string: candidate),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            throw DropFrameError.invalidURL
        }
        return url
    }

    private func restoreLibrary() async {
        async let librarySnapshot = store.load()
        async let imageSnapshot = imageStore.load()
        let (snapshot, restoredImages) = await (librarySnapshot, imageSnapshot)
        folders = snapshot.folders
        videos = snapshot.videos
        images = restoredImages

        let knownFolderIDs = Set(folders.map(\.id))
        let recoveredImageFolderIDs = Set(images.map(\.folderID))
            .subtracting(knownFolderIDs)
        for (index, folderID) in recoveredImageFolderIDs.enumerated() {
            folders.append(
                MediaFolder(
                    id: folderID,
                    name: index == 0 ? "Recovered images" : "Recovered images \(index + 1)",
                    symbol: "photo.stack.fill",
                    tintHex: "9A73FF"
                )
            )
        }

        // Prefer the independently cached copy. On the first run after this
        // migration, fall back to the settings already stored in library.json.
        settings = AppSettingsCache.load() ?? snapshot.settings
        AppSettingsCache.save(settings)
        restoreTask = nil

        if !recoveredImageFolderIDs.isEmpty {
            let repairedSnapshot = LibrarySnapshot(
                folders: folders,
                videos: videos,
                settings: settings
            )
            try? await store.save(repairedSnapshot)
        }

        for video in videos where video.fileSize <= 0 {
            refreshFileSizeLater(for: video.id)
        }
    }

    private func refreshFileSizeLater(for videoID: UUID) {
        Task { @MainActor [weak self] in
            await self?.refreshFileSize(for: videoID)
        }
    }

    private func refreshFileSize(for videoID: UUID) async {
        guard let video = videos.first(where: { $0.id == videoID }) else {
            return
        }
        let url = await store.localURL(for: video)
        let actualSize = await store.itemSize(at: url)
        guard
            actualSize > 0,
            let index = videos.firstIndex(where: { $0.id == videoID })
        else {
            return
        }

        videos[index].fileSize = actualSize
        await persist()
    }

    private func persist() async {
        AppSettingsCache.save(settings)
        let snapshot = LibrarySnapshot(folders: folders, videos: videos, settings: settings)
        do {
            try await store.save(snapshot)
        } catch {
            presentedError = "DropFrame couldn’t save its library: \(error.localizedDescription)"
        }
    }

    private func persistImages() async {
        do {
            try await imageStore.save(images)
        } catch {
            presentedError = "DropFrame couldn’t save its image library: \(error.localizedDescription)"
        }
    }
}
