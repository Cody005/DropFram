import AVFoundation
import AVKit
import MediaPlayer
import Observation
import UIKit

@MainActor
@Observable
final class PlaybackController: NSObject {
    @ObservationIgnored let player = AVPlayer()

    private(set) var phase: PlaybackPhase = .loading
    private(set) var videoID: UUID?
    private(set) var folderID: UUID?
    private(set) var title = ""
    private(set) var formatLabel = ""
    private(set) var pixelSizeText: String?
    private(set) var currentTime = 0.0
    private(set) var duration = 0.0
    private(set) var audioOptions: [PlayerTrackOption] = []
    private(set) var subtitleOptions: [PlayerTrackOption] = []
    private(set) var selectedAudioID: String?
    private(set) var selectedSubtitleID: String?
    private(set) var isPictureInPicturePossible = false
    private(set) var isPictureInPictureActive = false
    private(set) var hud: PlayerHUDState?
    private(set) var seekFeedback: PlayerSeekFeedback?

    var timelinePosition = 0.0
    var playbackRate: Float = 1
    var displayMode: PlayerDisplayMode = .fit
    var controlsVisible = true
    var controlsLocked = false
    var isScrubbing = false
    var screenBrightness = Double(UIScreen.main.brightness)
    var targetSystemVolume = AVAudioSession.sharedInstance().outputVolume

    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var currentVideo: LibraryVideo?
    @ObservationIgnored private var pendingAutoplay = false
    @ObservationIgnored private var hasPreparedCurrentItem = false
    @ObservationIgnored private var wantsToPlay = false
    @ObservationIgnored private var resumeAfterScrubbing = false
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var lastStoredPosition = 0.0
    @ObservationIgnored private var lastNowPlayingUpdate = 0.0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemDurationObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemBufferObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemNotificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var audioNotificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var controlsHideTask: Task<Void, Never>?
    @ObservationIgnored private var hudHideTask: Task<Void, Never>?
    @ObservationIgnored private var seekFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var mediaOptionsTask: Task<Void, Never>?
    @ObservationIgnored private var audioOptionMap: [String: AVMediaSelectionOption] = [:]
    @ObservationIgnored private var subtitleOptionMap: [String: AVMediaSelectionOption] = [:]
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var subtitleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var pictureInPictureController: AVPictureInPictureController?
    @ObservationIgnored private var pictureInPictureObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var attachedPlayerLayer: AVPlayerLayer?

    var isPlaying: Bool {
        phase == .playing
    }

    var canSeek: Bool {
        duration.isFinite && duration > 0
    }

    var hasMediaOptions: Bool {
        audioOptions.count > 1 || !subtitleOptions.isEmpty
    }

    override init() {
        super.init()
        installTimeObserver()
        installTimeControlObserver()
        installAudioNotifications()
    }

    func prepare(
        url: URL,
        video: LibraryVideo,
        autoplay: Bool
    ) {
        saveProgress()
        tearDownCurrentItem()
        controlsHideTask?.cancel()
        hudHideTask?.cancel()
        seekFeedbackTask?.cancel()

        currentURL = url
        currentVideo = video
        videoID = video.id
        folderID = video.folderID
        title = video.title
        formatLabel = video.formatLabel
        pixelSizeText = video.pixelSizeText
        pendingAutoplay = autoplay
        hasPreparedCurrentItem = false
        wantsToPlay = autoplay
        currentTime = 0
        timelinePosition = 0
        duration = 0
        playbackRate = 1
        displayMode = .fit
        phase = .loading
        controlsVisible = true
        hud = nil
        seekFeedback = nil

        guard FileManager.default.fileExists(atPath: url.path) else {
            wantsToPlay = false
            phase = .failed(
                "The saved video file is unavailable. Download it again to restore this item."
            )
            return
        }

        configureAudioSession()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        configureItemObservers(item)
        player.replaceCurrentItem(with: item)
        configureNowPlayingCommands()

        if autoplay {
            player.play()
        }
    }

    func retry() {
        guard let currentURL, let currentVideo else { return }
        prepare(url: currentURL, video: currentVideo, autoplay: true)
    }

    func shutdown() {
        saveProgress()
        controlsHideTask?.cancel()
        hudHideTask?.cancel()
        seekFeedbackTask?.cancel()
        stopPictureInPicture()
        tearDownCurrentItem()
        removeRemoteCommandTargets()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player.pause()
        player.replaceCurrentItem(with: nil)

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            print("Player audio session deactivation failed: \(error.localizedDescription)")
        }
    }

    func togglePlayback() {
        switch phase {
        case .finished:
            seek(to: 0, playAfterSeeking: true)
        case .playing, .buffering:
            pause()
        case .failed, .loading:
            break
        case .ready, .paused:
            play()
        }
    }

    func play() {
        guard player.currentItem != nil else { return }
        wantsToPlay = true
        player.playImmediately(atRate: playbackRate)
        scheduleControlsHide()
    }

    func pause() {
        wantsToPlay = false
        player.pause()
        saveProgress()
        controlsHideTask?.cancel()
        controlsVisible = true
    }

    func seek(by seconds: Double) {
        let destination = min(max(timelinePosition + seconds, 0), max(duration, 0))
        seek(to: destination, playAfterSeeking: isPlaying || wantsToPlay)
        showSeekFeedback(seconds < 0 ? .backward : .forward)
    }

    func seek(to seconds: Double, playAfterSeeking: Bool? = nil) {
        guard canSeek else { return }
        let destination = min(max(seconds, 0), duration)
        let shouldPlay = playAfterSeeking ?? isPlaying
        timelinePosition = destination
        currentTime = destination

        player.seek(
            to: CMTime(seconds: destination, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if shouldPlay {
                    self.play()
                } else {
                    self.wantsToPlay = false
                    self.phase = .paused
                }
                self.updateNowPlayingInfo()
            }
        }
    }

    func beginScrubbing() {
        guard canSeek else { return }
        isScrubbing = true
        resumeAfterScrubbing = isPlaying || wantsToPlay
        player.pause()
        controlsHideTask?.cancel()
        controlsVisible = true
    }

    func scrubPositionChanged() {
        guard isScrubbing else { return }
        timelinePosition = min(max(timelinePosition, 0), max(duration, 0))
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        seek(to: timelinePosition, playAfterSeeking: resumeAfterScrubbing)
        resumeAfterScrubbing = false
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player.rate = rate
        }
        updateNowPlayingInfo()
        scheduleControlsHide()
    }

    func toggleDisplayMode() {
        displayMode = displayMode == .fit ? .zoom : .fit
        scheduleControlsHide()
    }

    func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible {
            scheduleControlsHide()
        } else {
            controlsHideTask?.cancel()
        }
    }

    func revealControls() {
        controlsVisible = true
        scheduleControlsHide()
    }

    func syncSystemLevels() {
        screenBrightness = Double(UIScreen.main.brightness)
        targetSystemVolume = AVAudioSession.sharedInstance().outputVolume
    }

    func toggleControlsLock() {
        controlsLocked.toggle()
        controlsVisible = true
        controlsHideTask?.cancel()
        if !controlsLocked {
            scheduleControlsHide()
        }
    }

    func setBrightness(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        UIScreen.main.brightness = clamped
        screenBrightness = clamped
        showHUD(kind: .brightness, value: clamped)
    }

    func setSystemVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        targetSystemVolume = Float(clamped)
        showHUD(kind: .volume, value: clamped)
    }

    func selectAudio(id: String) {
        guard
            let item = player.currentItem,
            let group = audioGroup,
            let option = audioOptionMap[id]
        else {
            return
        }
        item.select(option, in: group)
        selectedAudioID = id
    }

    func selectSubtitle(id: String?) {
        guard let item = player.currentItem, let group = subtitleGroup else {
            return
        }
        let option = id.flatMap { subtitleOptionMap[$0] }
        item.select(option, in: group)
        selectedSubtitleID = id
    }

    func attachPlayerLayer(_ layer: AVPlayerLayer) {
        guard attachedPlayerLayer !== layer else { return }
        attachedPlayerLayer = layer
        pictureInPictureObservation?.invalidate()
        pictureInPictureController?.delegate = nil

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            pictureInPictureController = nil
            isPictureInPicturePossible = false
            return
        }

        guard let controller = AVPictureInPictureController(playerLayer: layer) else {
            isPictureInPicturePossible = false
            return
        }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pictureInPictureController = controller
        pictureInPictureObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            let isPossible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                self?.isPictureInPicturePossible = isPossible
            }
        }
    }

    func togglePictureInPicture() {
        guard let pictureInPictureController else { return }
        if pictureInPictureController.isPictureInPictureActive {
            pictureInPictureController.stopPictureInPicture()
        } else if pictureInPictureController.isPictureInPicturePossible {
            pictureInPictureController.startPictureInPicture()
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            targetSystemVolume = session.outputVolume
        } catch {
            print("Player audio session setup failed: \(error.localizedDescription)")
        }
    }

    private func configureItemObservers(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                self.handleItemStatus(item)
            }
        }

        itemDurationObservation = item.observe(
            \.duration,
            options: [.initial, .new]
        ) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                self.updateDuration(from: item)
            }
        }

        itemBufferObservation = item.observe(
            \.isPlaybackBufferEmpty,
            options: [.new]
        ) { [weak self, weak item] observedItem, _ in
            let isEmpty = observedItem.isPlaybackBufferEmpty
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                if isEmpty && self.wantsToPlay {
                    self.phase = .buffering
                }
            }
        }

        itemNotificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item] _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.player.currentItem === item else {
                        return
                    }
                    self.handlePlaybackFinished()
                }
            }
        )

        itemNotificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.player.currentItem === item else {
                        return
                    }
                    self.phase = .failed(
                        error?.localizedDescription ?? "The video stopped before playback could finish."
                    )
                    self.wantsToPlay = false
                }
            }
        )
    }

    private func handleItemStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .unknown:
            phase = .loading
        case .readyToPlay:
            updateDuration(from: item)
            guard !hasPreparedCurrentItem else {
                syncPhaseWithPlayer()
                return
            }
            hasPreparedCurrentItem = true
            loadMediaOptions(for: item)
            restorePositionAndStart(item)
        case .failed:
            wantsToPlay = false
            phase = .failed(
                item.error?.localizedDescription ?? "This saved video could not be played."
            )
        @unknown default:
            phase = .failed("This video returned an unknown playback state.")
        }
    }

    private func restorePositionAndStart(_ item: AVPlayerItem) {
        let storedPosition = videoID.map(PlaybackProgressStore.position(for:)) ?? 0
        let safeResumePosition: Double
        if storedPosition > 5, duration > 0, storedPosition < duration - 10 {
            safeResumePosition = storedPosition
        } else {
            safeResumePosition = 0
        }

        currentTime = safeResumePosition
        timelinePosition = safeResumePosition
        lastStoredPosition = safeResumePosition

        let finishPreparation = { [weak self, weak item] in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                if self.pendingAutoplay {
                    self.play()
                } else {
                    self.wantsToPlay = false
                    self.phase = .paused
                    self.updateNowPlayingInfo()
                }
            }
        }

        guard safeResumePosition > 0 else {
            _ = finishPreparation()
            return
        }

        player.seek(
            to: CMTime(seconds: safeResumePosition, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { _ in
            _ = finishPreparation()
        }
    }

    private func updateDuration(from item: AVPlayerItem) {
        let seconds = item.duration.seconds
        guard seconds.isFinite, seconds > 0, abs(duration - seconds) > 0.01 else {
            return
        }
        duration = seconds
        timelinePosition = min(timelinePosition, seconds)
        updateNowPlayingInfo()
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                self?.updatePlaybackTime(seconds)
            }
        }
    }

    private func installTimeControlObserver() {
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.syncPhaseWithPlayer()
            }
        }
    }

    private func updatePlaybackTime(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        currentTime = seconds
        if !isScrubbing {
            timelinePosition = seconds
        }

        if abs(seconds - lastStoredPosition) >= 10 {
            saveProgress()
        }
        if abs(seconds - lastNowPlayingUpdate) >= 1 {
            lastNowPlayingUpdate = seconds
            updateNowPlayingInfo()
        }
    }

    private func syncPhaseWithPlayer() {
        guard player.currentItem != nil else { return }
        switch player.timeControlStatus {
        case .paused:
            switch phase {
            case .loading, .failed, .finished:
                break
            default:
                phase = hasPreparedCurrentItem ? .paused : .loading
            }
        case .waitingToPlayAtSpecifiedRate:
            phase = wantsToPlay ? .buffering : .paused
        case .playing:
            phase = .playing
            wantsToPlay = true
            scheduleControlsHide()
        @unknown default:
            break
        }
        updateNowPlayingInfo()
    }

    private func handlePlaybackFinished() {
        wantsToPlay = false
        phase = .finished
        currentTime = duration
        timelinePosition = duration
        controlsVisible = true
        controlsHideTask?.cancel()
        if let videoID {
            PlaybackProgressStore.removePosition(for: videoID)
        }
        updateNowPlayingInfo()
    }

    private func saveProgress() {
        guard let videoID, duration > 0 else { return }
        if currentTime >= duration - 10 {
            PlaybackProgressStore.removePosition(for: videoID)
            lastStoredPosition = 0
        } else {
            PlaybackProgressStore.save(currentTime, for: videoID)
            lastStoredPosition = currentTime
        }
    }

    private func scheduleControlsHide() {
        controlsHideTask?.cancel()
        guard
            controlsVisible,
            isPlaying,
            !controlsLocked,
            !isScrubbing,
            !UIAccessibility.isVoiceOverRunning,
            !UIAccessibility.isSwitchControlRunning
        else {
            return
        }

        controlsHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.controlsVisible = false
            }
        }
    }

    private func showHUD(kind: PlayerHUDKind, value: Double) {
        hudHideTask?.cancel()
        hud = PlayerHUDState(kind: kind, value: value)
        hudHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.hud = nil
            }
        }
    }

    private func showSeekFeedback(_ direction: PlayerSeekDirection) {
        seekFeedbackTask?.cancel()
        seekFeedback = PlayerSeekFeedback(direction: direction)
        seekFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.seekFeedback = nil
            }
        }
    }

    private func loadMediaOptions(for item: AVPlayerItem) {
        mediaOptionsTask?.cancel()
        mediaOptionsTask = Task { [weak self, weak item] in
            guard let self, let item else { return }
            let asset = item.asset
            let audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled, self.player.currentItem === item else {
                return
            }
            self.applyMediaOptions(
                audioGroup: audibleGroup,
                subtitleGroup: legibleGroup,
                item: item
            )
        }
    }

    private func applyMediaOptions(
        audioGroup: AVMediaSelectionGroup?,
        subtitleGroup: AVMediaSelectionGroup?,
        item: AVPlayerItem
    ) {
        self.audioGroup = audioGroup
        self.subtitleGroup = subtitleGroup

        audioOptionMap.removeAll()
        subtitleOptionMap.removeAll()

        audioOptions = audioGroup?.options.enumerated().map { index, option in
            let id = "audio-\(index)"
            audioOptionMap[id] = option
            return PlayerTrackOption(id: id, title: option.displayName)
        } ?? []

        subtitleOptions = subtitleGroup?.options.enumerated().map { index, option in
            let id = "subtitle-\(index)"
            subtitleOptionMap[id] = option
            return PlayerTrackOption(id: id, title: option.displayName)
        } ?? []

        if let audioGroup,
           let selected = item.currentMediaSelection.selectedMediaOption(in: audioGroup) {
            selectedAudioID = audioOptionMap.first(where: { $0.value == selected })?.key
        } else {
            selectedAudioID = nil
        }

        if let subtitleGroup,
           let selected = item.currentMediaSelection.selectedMediaOption(in: subtitleGroup) {
            selectedSubtitleID = subtitleOptionMap.first(where: { $0.value == selected })?.key
        } else {
            selectedSubtitleID = nil
        }
    }

    private func configureNowPlayingCommands() {
        removeRemoteCommandTargets()
        let center = MPRemoteCommandCenter.shared()

        addRemoteTarget(to: center.playCommand) { [weak self] in
            self?.play()
        }
        addRemoteTarget(to: center.pauseCommand) { [weak self] in
            self?.pause()
        }
        addRemoteTarget(to: center.togglePlayPauseCommand) { [weak self] in
            self?.togglePlayback()
        }
        center.skipForwardCommand.preferredIntervals = [10]
        addRemoteTarget(to: center.skipForwardCommand) { [weak self] in
            self?.seek(by: 10)
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        addRemoteTarget(to: center.skipBackwardCommand) { [weak self] in
            self?.seek(by: -10)
        }

        center.changePlaybackPositionCommand.isEnabled = true
        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                self?.seek(to: event.positionTime)
            }
            return .success
        }
        remoteCommandTargets.append((center.changePlaybackPositionCommand, positionTarget))
        updateNowPlayingInfo()
    }

    private func addRemoteTarget(
        to command: MPRemoteCommand,
        action: @escaping @MainActor () -> Void
    ) {
        command.isEnabled = true
        let target = command.addTarget { _ in
            Task { @MainActor in
                action()
            }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    private func removeRemoteCommandTargets() {
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        remoteCommandTargets.removeAll()
    }

    private func updateNowPlayingInfo() {
        guard videoID != nil else { return }
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if duration > 0 {
            information[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = information
    }

    private func installAudioNotifications() {
        audioNotificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleAudioInterruption(notification)
                }
            }
        )

        audioNotificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleAudioRouteChange(notification)
                }
            }
        )
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying || wantsToPlay
            wantsToPlay = false
            controlsVisible = true
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                configureAudioSession()
                play()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
        else {
            return
        }
        pause()
    }

    private func stopPictureInPicture() {
        if pictureInPictureController?.isPictureInPictureActive == true {
            pictureInPictureController?.stopPictureInPicture()
        }
        pictureInPictureObservation?.invalidate()
        pictureInPictureObservation = nil
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        isPictureInPicturePossible = false
        isPictureInPictureActive = false
    }

    private func tearDownCurrentItem() {
        mediaOptionsTask?.cancel()
        itemStatusObservation?.invalidate()
        itemDurationObservation?.invalidate()
        itemBufferObservation?.invalidate()
        itemStatusObservation = nil
        itemDurationObservation = nil
        itemBufferObservation = nil

        itemNotificationTokens.removeAll { token in
            NotificationCenter.default.removeObserver(token)
            return true
        }

        audioOptions = []
        subtitleOptions = []
        audioOptionMap.removeAll()
        subtitleOptionMap.removeAll()
        audioGroup = nil
        subtitleGroup = nil
        selectedAudioID = nil
        selectedSubtitleID = nil
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeControlObservation?.invalidate()
        for token in itemNotificationTokens + audioNotificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

extension PlaybackController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        controlsVisible = false
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActive = false
        controlsVisible = true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureActive = false
        controlsVisible = true
        print("Picture in Picture failed: \(error.localizedDescription)")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        controlsVisible = true
        completionHandler(true)
    }
}
