import SwiftUI

struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    let video: LibraryVideo

    @State private var controller = PlaybackController()

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            ZStack {
                Color.black
                    .ignoresSafeArea()

                PlayerLayerView(
                    player: controller.player,
                    videoGravity: controller.displayMode.videoGravity,
                    onPlayerLayerReady: controller.attachPlayerLayer
                )
                .ignoresSafeArea()

                PlayerInteractionLayer(controller: controller)
                    .ignoresSafeArea()

                if controller.controlsVisible {
                    PlayerChromeView(
                        controller: controller,
                        isLandscape: isLandscape,
                        canPlayPrevious: previousVideo != nil,
                        canPlayNext: nextVideo != nil,
                        onClose: close,
                        onPrevious: playPrevious,
                        onNext: playNext
                    )
                    .transition(.opacity)

                    if !controller.controlsLocked {
                        PlayerEdgeControlsOverlay(controller: controller)
                            .transition(.opacity)
                    }
                }

                PlayerStatusOverlay(
                    controller: controller,
                    onClose: close
                )

                PlayerFeedbackOverlay(controller: controller)

                SystemVolumeBridge(volume: controller.targetSystemVolume)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .accessibilityHidden(true)
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: controller.controlsVisible
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78),
                value: controller.seekFeedback
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82),
                value: controller.hud
            )
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .task(id: video.id) {
            await load(video)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = model.settings.keepScreenAwake
        }
        .onDisappear {
            controller.shutdown()
            UIApplication.shared.isIdleTimerDisabled = false
            PlayerOrientation.restoreAppOrientations()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: controller.seekFeedback?.id)
    }

    private var folderQueue: [LibraryVideo] {
        guard let folderID = controller.folderID else { return [] }
        return model.videos
            .filter { $0.folderID == folderID }
            .sorted { $0.downloadedAt < $1.downloadedAt }
    }

    private var currentQueueIndex: Int? {
        guard let videoID = controller.videoID else { return nil }
        return folderQueue.firstIndex(where: { $0.id == videoID })
    }

    private var previousVideo: LibraryVideo? {
        guard let index = currentQueueIndex, index > folderQueue.startIndex else {
            return nil
        }
        return folderQueue[folderQueue.index(before: index)]
    }

    private var nextVideo: LibraryVideo? {
        guard let index = currentQueueIndex else { return nil }
        let nextIndex = folderQueue.index(after: index)
        guard nextIndex < folderQueue.endIndex else { return nil }
        return folderQueue[nextIndex]
    }

    private func load(_ video: LibraryVideo) async {
        let url = await model.localURL(for: video)
        guard !Task.isCancelled else { return }
        controller.prepare(
            url: url,
            video: video,
            autoplay: model.settings.autoplay
        )
    }

    private func playPrevious() {
        guard let previousVideo else { return }
        Task {
            await load(previousVideo)
        }
    }

    private func playNext() {
        guard let nextVideo else { return }
        Task {
            await load(nextVideo)
        }
    }

    private func close() {
        controller.shutdown()
        dismiss()
    }
}
