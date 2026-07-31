import SwiftUI

struct PlayerTimelineView: View {
    @Bindable var controller: PlaybackController

    var body: some View {
        VStack(spacing: 10) {
            timeline

            HStack(spacing: 12) {
                Text(PlayerTimeText.string(controller.timelinePosition))
                    .frame(minWidth: 46, alignment: .leading)

                Spacer()

                PlayerSpeedMenu(controller: controller)

                if controller.hasMediaOptions {
                    PlayerTracksMenu(controller: controller)
                }

                Spacer()

                Text("-\(PlayerTimeText.string(max(controller.duration - controller.timelinePosition, 0)))")
                    .frame(minWidth: 46, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.84))
        }
    }

    private var timeline: some View {
        Slider(
            value: $controller.timelinePosition,
            in: 0...max(controller.duration, 1)
        ) { isEditing in
            if isEditing {
                controller.beginScrubbing()
            } else {
                controller.endScrubbing()
            }
        }
        .tint(DropFramePalette.signal)
        .disabled(!controller.canSeek)
        .onChange(of: controller.timelinePosition) {
            controller.scrubPositionChanged()
        }
        .accessibilityLabel("Playback position")
        .accessibilityValue(
            "\(PlayerTimeText.string(controller.timelinePosition)) of \(PlayerTimeText.string(controller.duration))"
        )
    }
}

private struct PlayerSpeedMenu: View {
    @Bindable var controller: PlaybackController

    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        Menu {
            ForEach(rates, id: \.self) { rate in
                Button {
                    controller.setPlaybackRate(rate)
                } label: {
                    if controller.playbackRate == rate {
                        Label("\(Double(rate).formatted())×", systemImage: "checkmark")
                    } else {
                        Text("\(Double(rate).formatted())×")
                    }
                }
            }
        } label: {
            Text("\(Double(controller.playbackRate).formatted())×")
                .playerMenuLabel()
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue("\(Double(controller.playbackRate).formatted()) times")
    }
}

private struct PlayerTracksMenu: View {
    @Bindable var controller: PlaybackController

    var body: some View {
        Menu {
            if controller.audioOptions.count > 1 {
                Section("Audio") {
                    ForEach(controller.audioOptions) { option in
                        Button {
                            controller.selectAudio(id: option.id)
                        } label: {
                            if controller.selectedAudioID == option.id {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
            }

            if !controller.subtitleOptions.isEmpty {
                Section("Subtitles") {
                    Button {
                        controller.selectSubtitle(id: nil)
                    } label: {
                        if controller.selectedSubtitleID == nil {
                            Label("Off", systemImage: "checkmark")
                        } else {
                            Text("Off")
                        }
                    }

                    ForEach(controller.subtitleOptions) { option in
                        Button {
                            controller.selectSubtitle(id: option.id)
                        } label: {
                            if controller.selectedSubtitleID == option.id {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble.fill")
                .playerMenuLabel()
        }
        .accessibilityLabel("Audio and subtitles")
    }
}

struct PlayerMoreMenu: View {
    @Bindable var controller: PlaybackController
    let isLandscape: Bool

    var body: some View {
        Menu {
            if !isLandscape {
                Button {
                    controller.toggleDisplayMode()
                } label: {
                    Label(
                        controller.displayMode == .fit
                            ? "Zoom to fill"
                            : "Fit entire video",
                        systemImage: controller.displayMode.symbol
                    )
                }
            }

            if controller.isPictureInPicturePossible {
                Button {
                    controller.togglePictureInPicture()
                } label: {
                    Label(
                        controller.isPictureInPictureActive ? "Stop PiP" : "Picture in Picture",
                        systemImage: controller.isPictureInPictureActive ? "pip.exit" : "pip.enter"
                    )
                }
            }

            Button {
                PlayerOrientation.toggle(isCurrentlyLandscape: isLandscape)
            } label: {
                Label(
                    isLandscape ? "Portrait layout" : "Landscape layout",
                    systemImage: "rectangle.landscape.rotate"
                )
            }

            Button {
                controller.toggleControlsLock()
            } label: {
                Label("Lock controls", systemImage: "lock.fill")
            }

            Section("Video") {
                Text(controller.formatLabel.uppercased())
                if let pixelSizeText = controller.pixelSizeText {
                    Text(pixelSizeText)
                }
                Text(controller.displayMode.title)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.14), in: .circle)
                .foregroundStyle(.white)
                .contentShape(.circle)
        }
        .accessibilityLabel("More player controls")
    }
}

private extension View {
    func playerMenuLabel() -> some View {
        frame(minWidth: 34, minHeight: 30)
            .padding(.horizontal, 4)
            .background(.white.opacity(0.15), in: .rect(cornerRadius: 9))
            .foregroundStyle(.white)
    }
}
