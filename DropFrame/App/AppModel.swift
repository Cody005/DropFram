import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var selectedTab: AppTab = .home
    var linkText = ""
    var resolvedMedia: ResolvedMedia?
    var isResolving = false
    var folders: [MediaFolder] = []
    var videos: [LibraryVideo] = []
    var jobs: [DownloadJob] = []
    var settings = AppSettings()
    var presentedError: String?
    var isResultPresented = false
    var playerVideo: LibraryVideo?

    private let store: LibraryStore
    private let resolver: MediaResolver
    private let downloader: MediaDownloadService
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    init() {
        let store = LibraryStore()
        self.store = store
        resolver = MediaResolver()
        downloader = MediaDownloadService(store: store)
        settings = AppSettingsCache.load() ?? AppSettings()

        restoreTask = Task { [weak self] in
            await self?.restoreLibrary()
        }
    }

    var storageText: String {
        ByteCountFormatter.string(
            fromByteCount: videos.reduce(0) { $0 + $1.fileSize },
            countStyle: .file
        )
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

    func localURL(for video: LibraryVideo) async -> URL {
        await store.localURL(for: video)
    }

    func play(_ video: LibraryVideo) {
        playerVideo = video
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
        let snapshot = await store.load()
        folders = snapshot.folders
        videos = snapshot.videos

        // Prefer the independently cached copy. On the first run after this
        // migration, fall back to the settings already stored in library.json.
        settings = AppSettingsCache.load() ?? snapshot.settings
        AppSettingsCache.save(settings)
        restoreTask = nil

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
}
