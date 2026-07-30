import AVFoundation
import Foundation

final class OfflineAdaptiveDownload: NSObject, AVAssetDownloadDelegate, @unchecked Sendable {
    private let stateLock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloadLocation: URL?
    private var session: AVAssetDownloadURLSession?
    private var task: AVAssetDownloadTask?
    private var hasFinished = false
    private let progress: (@Sendable (Double?, Int64) -> Void)?

    private init(progress: (@Sendable (Double?, Int64) -> Void)?) {
        self.progress = progress
    }

    static func download(
        url: URL,
        title: String,
        requestHeaders: [String: String]?,
        progress: (@Sendable (Double?, Int64) -> Void)?
    ) async throws -> URL {
        let download = OfflineAdaptiveDownload(progress: progress)
        return try await download.start(
            url: url,
            title: title,
            requestHeaders: requestHeaders
        )
    }

    private func start(
        url: URL,
        title: String,
        requestHeaders: [String: String]?
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                stateLock.withLock {
                    self.continuation = continuation
                }

                let configuration = URLSessionConfiguration.background(
                    withIdentifier: "com.personal.DropFrame.adaptive.\(UUID().uuidString)"
                )
                configuration.allowsCellularAccess = true
                configuration.allowsExpensiveNetworkAccess = true
                configuration.allowsConstrainedNetworkAccess = true
                configuration.waitsForConnectivity = false
                configuration.timeoutIntervalForRequest = 45
                configuration.timeoutIntervalForResource = 1_200

                let session = AVAssetDownloadURLSession(
                    configuration: configuration,
                    assetDownloadDelegate: self,
                    delegateQueue: nil
                )
                stateLock.withLock {
                    self.session = session
                }

                var assetOptions: [String: Any] = [
                    AVURLAssetAllowsCellularAccessKey: true
                ]
                if let requestHeaders, !requestHeaders.isEmpty {
                    assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = requestHeaders
                }
                let asset = AVURLAsset(url: url, options: assetOptions)
                let downloadConfiguration = AVAssetDownloadConfiguration(
                    asset: asset,
                    title: title
                )
                downloadConfiguration.auxiliaryContentConfigurations = []

                let task = session.makeAssetDownloadTask(
                    downloadConfiguration: downloadConfiguration
                )
                stateLock.withLock {
                    self.task = task
                }
                progress?(nil, 0)
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        stateLock.withLock {
            downloadLocation = location
        }
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        let expectedStart = CMTimeGetSeconds(timeRangeExpectedToLoad.start)
        let expectedSeconds = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        guard
            expectedStart.isFinite,
            expectedSeconds.isFinite,
            expectedSeconds > 0
        else {
            progress?(nil, 0)
            return
        }

        let loadedSeconds = uniqueLoadedSeconds(
            loadedTimeRanges,
            expectedStart: expectedStart,
            expectedEnd: expectedStart + expectedSeconds
        )
        guard loadedSeconds > 0 else { return }

        // The loaded ranges can overlap. Counting each range independently can
        // report 100% long before the stream has actually finished. Reserve the
        // last two percent for AVFoundation's successful completion callback.
        progress?(min(0.98, max(0, loadedSeconds / expectedSeconds)), 0)
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        stateLock.withLock {
            downloadLocation = location
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        let completedLocation = stateLock.withLock {
            downloadLocation
        }
        guard let completedLocation else {
            finish(.failure(DropFrameError.hlsDownloadFailed))
            return
        }
        finish(.success(completedLocation))
    }

    func urlSession(
        _ session: URLSession,
        didBecomeInvalidWithError error: Error?
    ) {
        stateLock.withLock {
            task = nil
            self.session = nil
        }
    }

    private func cancel() {
        let activeTask = stateLock.withLock {
            task
        }
        activeTask?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, Error>) {
        let completion: (
            continuation: CheckedContinuation<URL, Error>,
            session: AVAssetDownloadURLSession?
        )? = stateLock.withLock {
            guard !hasFinished, let continuation else {
                return nil
            }
            hasFinished = true
            self.continuation = nil
            return (continuation, session)
        }
        guard let completion else { return }

        // AVFoundation may still be unwinding this object's delegate callback.
        // Keep the task, session, and delegate alive until session invalidation.
        completion.session?.finishTasksAndInvalidate()
        completion.continuation.resume(with: result)
    }

    private func uniqueLoadedSeconds(
        _ loadedTimeRanges: [NSValue],
        expectedStart: Double,
        expectedEnd: Double
    ) -> Double {
        let intervals = loadedTimeRanges.compactMap { value -> (Double, Double)? in
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let duration = CMTimeGetSeconds(range.duration)
            guard
                start.isFinite,
                duration.isFinite,
                duration > 0
            else {
                return nil
            }

            let clippedStart = max(expectedStart, start)
            let clippedEnd = min(expectedEnd, start + duration)
            guard clippedEnd > clippedStart else { return nil }
            return (clippedStart, clippedEnd)
        }
        .sorted { $0.0 < $1.0 }

        guard let first = intervals.first else { return 0 }

        var total = 0.0
        var currentStart = first.0
        var currentEnd = first.1

        for interval in intervals.dropFirst() {
            if interval.0 <= currentEnd {
                currentEnd = max(currentEnd, interval.1)
            } else {
                total += currentEnd - currentStart
                currentStart = interval.0
                currentEnd = interval.1
            }
        }

        return total + currentEnd - currentStart
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
