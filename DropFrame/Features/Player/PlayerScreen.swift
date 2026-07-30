import AVFoundation
import SwiftUI

struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let video: LibraryVideo

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            DropFramePalette.night.ignoresSafeArea()
            if let player {
                PlayerControlsView(
                    player: player,
                    title: video.title,
                    autoplay: model.settings.autoplay,
                    onClose: { dismiss() }
                )
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .task {
            let url = await model.localURL(for: video)
            player = AVPlayer(url: url)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = model.settings.keepScreenAwake
        }
        .onDisappear {
            player?.pause()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

private struct PlayerControlsView: View {
    let player: AVPlayer
    let title: String
    let autoplay: Bool
    let onClose: () -> Void

    @State private var isPlaying = false
    @State private var controlsVisible = true
    @State private var currentTime = 0.0
    @State private var duration = 1.0
    @State private var isFillMode = false
    @State private var playbackRate: Float = 1
    @State private var controlsHideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            PlayerLayerView(player: player, videoGravity: isFillMode ? .resizeAspectFill : .resizeAspect)
                .ignoresSafeArea()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    controlsVisible.toggle()
                }
                scheduleControlsHide()
            } label: {
                Color.clear
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controlsVisible ? "Hide controls" : "Show controls")

            if controlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .task {
            if autoplay {
                player.play()
                isPlaying = true
            }
            scheduleControlsHide()
            while !Task.isCancelled {
                currentTime = player.currentTime().seconds.finiteOrZero
                duration = player.currentItem?.duration.seconds.finiteOrZero ?? 1
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 14) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 42, height: 42)
                }
                .accessibilityLabel("Close player")

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    EditorialLabel(text: "Playing from DropFrame", color: .white.opacity(0.56))
                }
                Spacer()
                AirPlayButton()
                    .frame(width: 42, height: 42)
                Button {
                    isFillMode.toggle()
                    scheduleControlsHide()
                } label: {
                    Image(systemName: isFillMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 42, height: 42)
                }
                .accessibilityLabel(isFillMode ? "Fit video" : "Fill screen")
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 36) {
                Button {
                    seek(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .accessibilityLabel("Back 10 seconds")

                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .black))
                        .frame(width: 68, height: 68)
                        .background(.white, in: .circle)
                        .foregroundStyle(DropFramePalette.night)
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                Button {
                    seek(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                }
                .accessibilityLabel("Forward 10 seconds")
            }
            .font(.system(size: 29, weight: .regular))
            .foregroundStyle(.white)

            Spacer()

            VStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { min(currentTime, max(duration, 1)) },
                        set: { value in
                            currentTime = value
                            player.seek(to: CMTime(seconds: value, preferredTimescale: 600))
                        }
                    ),
                    in: 0...max(duration, 1)
                )
                .tint(DropFramePalette.signal)
                .accessibilityLabel("Playback position")

                HStack {
                    Text(timeText(currentTime))
                    Spacer()
                    Menu {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                            Button("\(rate.formatted())×") {
                                playbackRate = Float(rate)
                                player.rate = isPlaying ? playbackRate : 0
                            }
                        }
                    } label: {
                        Text("\(Double(playbackRate).formatted())× SPEED")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.15), in: .rect(cornerRadius: 8))
                    }
                    Spacer()
                    Text("-\(timeText(max(duration - currentTime, 0)))")
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background {
            LinearGradient(
                colors: [
                    DropFramePalette.night.opacity(0.82),
                    .clear,
                    DropFramePalette.night.opacity(0.9)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.playImmediately(atRate: playbackRate)
        }
        isPlaying.toggle()
        scheduleControlsHide()
    }

    private func seek(by amount: Double) {
        let next = min(max(currentTime + amount, 0), duration)
        player.seek(to: CMTime(seconds: next, preferredTimescale: 600))
        currentTime = next
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        controlsHideTask?.cancel()
        guard controlsVisible, isPlaying else { return }
        controlsHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible = false
            }
        }
    }

    private func timeText(_ time: Double) -> String {
        let value = Int(time.finiteOrZero)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private extension Double {
    var finiteOrZero: Double {
        isFinite && !isNaN ? self : 0
    }
}
