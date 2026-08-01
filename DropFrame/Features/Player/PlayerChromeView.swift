import SwiftUI

struct PlayerChromeView: View {
    @Bindable var controller: PlaybackController
    let isLandscape: Bool
    let canPlayPrevious: Bool
    let canPlayNext: Bool
    let onClose: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        if controller.controlsLocked {
            lockedChrome
        } else {
            VStack(spacing: 0) {
                PlayerTopBar(
                    controller: controller,
                    isLandscape: isLandscape,
                    onClose: onClose
                )

                Spacer(minLength: 18)

                PlayerTransportControls(
                    controller: controller,
                    compact: !isLandscape,
                    canPlayPrevious: canPlayPrevious,
                    canPlayNext: canPlayNext,
                    onPrevious: onPrevious,
                    onNext: onNext
                )

                Spacer(minLength: 18)

                PlayerTimelineView(controller: controller)
            }
            .padding(.horizontal, isLandscape ? 28 : 18)
            .padding(.vertical, isLandscape ? 14 : 12)
        }
    }

    private var lockedChrome: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    controller.toggleControlsLock()
                } label: {
                    Label("Unlock controls", systemImage: "lock.open.fill")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .foregroundStyle(DropFramePalette.night)
                        .background(DropFramePalette.signal, in: .capsule)
                }
                .buttonStyle(.playerPress)
                .accessibilityHint("Restores the playback controls")
            }
            Spacer()
        }
        .padding(isLandscape ? 18 : 14)
    }
}

private struct PlayerTopBar: View {
    @Bindable var controller: PlaybackController
    let isLandscape: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: isLandscape ? 10 : 7) {
            PlayerIconButton(
                symbol: "xmark",
                accessibilityLabel: "Close player",
                action: onClose
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(controller.formatLabel.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.58))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isLandscape {
                PlayerIconButton(
                    symbol: controller.displayMode.symbol,
                    accessibilityLabel: controller.displayMode == .fit
                        ? "Zoom video to fill screen"
                        : "Fit entire video on screen"
                ) {
                    controller.toggleDisplayMode()
                }
            }

            if controller.isPictureInPicturePossible {
                PlayerIconButton(
                    symbol: controller.isPictureInPictureActive
                        ? "pip.exit"
                        : "pip.enter",
                    accessibilityLabel: controller.isPictureInPictureActive
                        ? "Stop Picture in Picture"
                        : "Start Picture in Picture"
                ) {
                    controller.togglePictureInPicture()
                }
            }

            AirPlayButton()
                .frame(width: 42, height: 42)
                .accessibilityLabel("Choose AirPlay device")

            PlayerMoreMenu(controller: controller, isLandscape: isLandscape)
        }
    }
}

private struct PlayerTransportControls: View {
    @Bindable var controller: PlaybackController
    let compact: Bool
    let canPlayPrevious: Bool
    let canPlayNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: compact ? 22 : 32) {
            if !compact || canPlayPrevious {
                transportButton(
                    symbol: "backward.end.fill",
                    label: "Previous video",
                    isEnabled: canPlayPrevious,
                    action: onPrevious
                )
            }

            transportButton(
                symbol: "gobackward.10",
                label: "Back 10 seconds"
            ) {
                controller.seek(by: -10)
            }

            Button {
                controller.togglePlayback()
            } label: {
                playButtonLabel
            }
            .buttonStyle(.playerPress)
            .disabled(!canTogglePlayback)
            .accessibilityLabel(playAccessibilityLabel)

            transportButton(
                symbol: "goforward.10",
                label: "Forward 10 seconds"
            ) {
                controller.seek(by: 10)
            }

            if !compact || canPlayNext {
                transportButton(
                    symbol: "forward.end.fill",
                    label: "Next video",
                    isEnabled: canPlayNext,
                    action: onNext
                )
            }
        }
        .font(.system(size: compact ? 25 : 28, weight: .semibold))
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var playButtonLabel: some View {
        if #available(iOS 26, *) {
            playButtonContent
                .glassEffect(
                    .regular
                        .tint(DropFramePalette.signal.opacity(0.34))
                        .interactive(),
                    in: .circle
                )
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.34), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.3), radius: 13, y: 7)
        } else {
            playButtonContent
                .background(DropFramePalette.signal.opacity(0.3), in: .circle)
                .background(.ultraThinMaterial, in: .circle)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.34), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.3), radius: 13, y: 7)
        }
    }

    private var playButtonContent: some View {
        Image(systemName: playSymbol)
            .font(.system(size: 28, weight: .black))
            .frame(width: compact ? 70 : 76, height: compact ? 70 : 76)
            .foregroundStyle(.white)
            .contentShape(.circle)
    }

    private var playSymbol: String {
        switch controller.phase {
        case .finished:
            "arrow.counterclockwise"
        case .playing, .buffering:
            "pause.fill"
        default:
            "play.fill"
        }
    }

    private var playAccessibilityLabel: String {
        switch controller.phase {
        case .finished:
            "Replay"
        case .playing, .buffering:
            "Pause"
        default:
            "Play"
        }
    }

    private var canTogglePlayback: Bool {
        switch controller.phase {
        case .loading, .failed:
            false
        default:
            true
        }
    }

    private func transportButton(
        symbol: String,
        label: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.playerPress)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.32)
        .accessibilityLabel(label)
    }
}

private struct PlayerIconButton: View {
    let symbol: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.14), in: .circle)
                .foregroundStyle(.white)
        }
        .buttonStyle(.playerPress)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct PlayerPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.91 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private extension ButtonStyle where Self == PlayerPressButtonStyle {
    static var playerPress: PlayerPressButtonStyle { .init() }
}
