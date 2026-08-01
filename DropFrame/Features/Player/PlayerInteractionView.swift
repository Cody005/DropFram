import AVFoundation
import SwiftUI
import UIKit

struct PlayerInteractionLayer: View {
    @Bindable var controller: PlaybackController

    var body: some View {
        PlayerTouchSurface(controller: controller)
    }
}

private struct PlayerTouchSurface: UIViewRepresentable {
    let controller: PlaybackController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        view.accessibilityLabel = "Show or hide player controls"
        view.accessibilityHint = "Double tap the center to fit or zoom. Double tap the sides or swipe horizontally to seek. Swipe vertically to adjust brightness or volume."
        context.coordinator.installGestures(on: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.controller = controller
        uiView.accessibilityValue = controller.controlsVisible
            ? "Controls visible"
            : "Controls hidden"
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var controller: PlaybackController?

        private weak var touchView: UIView?
        private weak var verticalPan: UIPanGestureRecognizer?
        private weak var horizontalPan: UIPanGestureRecognizer?
        private var activeSide: Side?
        private var startingValue = 0.0
        private var startingSeekPosition = 0.0

        init(controller: PlaybackController) {
            self.controller = controller
        }

        func installGestures(on view: UIView) {
            touchView = view

            let singleTap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleSingleTap)
            )
            singleTap.cancelsTouchesInView = false
            singleTap.delegate = self

            let doubleTap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleDoubleTap)
            )
            doubleTap.numberOfTapsRequired = 2
            doubleTap.cancelsTouchesInView = false
            doubleTap.delegate = self
            singleTap.require(toFail: doubleTap)

            let verticalPan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleVerticalPan)
            )
            verticalPan.minimumNumberOfTouches = 1
            verticalPan.maximumNumberOfTouches = 1
            verticalPan.cancelsTouchesInView = false
            verticalPan.delegate = self

            let horizontalPan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleHorizontalPan)
            )
            horizontalPan.minimumNumberOfTouches = 1
            horizontalPan.maximumNumberOfTouches = 1
            horizontalPan.cancelsTouchesInView = false
            horizontalPan.delegate = self

            self.verticalPan = verticalPan
            self.horizontalPan = horizontalPan
            view.addGestureRecognizer(singleTap)
            view.addGestureRecognizer(doubleTap)
            view.addGestureRecognizer(verticalPan)
            view.addGestureRecognizer(horizontalPan)
        }

        @objc
        private func handleSingleTap() {
            controller?.syncSystemLevels()
            controller?.toggleControls()
        }

        @objc
        private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard
                let controller,
                !controller.controlsLocked,
                let view = touchView
            else {
                self.controller?.revealControls()
                return
            }

            controller.revealControls()
            let horizontalPosition = recognizer.location(in: view).x
                / max(view.bounds.width, 1)
            switch horizontalPosition {
            case ..<0.35:
                controller.seek(by: -10)
            case 0.65...:
                controller.seek(by: 10)
            default:
                controller.toggleDisplayMode()
            }
        }

        @objc
        private func handleVerticalPan(_ recognizer: UIPanGestureRecognizer) {
            guard
                let controller,
                !controller.controlsLocked,
                let view = touchView
            else {
                resetPan()
                return
            }

            switch recognizer.state {
            case .began:
                controller.syncSystemLevels()
                controller.revealControls()
                activeSide = recognizer.location(in: view).x < view.bounds.midX
                    ? .left
                    : .right
                startingValue = activeSide == .left
                    ? controller.screenBrightness
                    : Double(controller.targetSystemVolume)

            case .changed:
                guard let activeSide else { return }
                controller.revealControls()
                let translation = recognizer.translation(in: view)
                let sensitivity = max(view.bounds.height * 0.48, 220)
                let adjusted = startingValue - (translation.y / sensitivity)

                switch activeSide {
                case .left:
                    controller.setBrightness(adjusted)
                case .right:
                    controller.setSystemVolume(adjusted)
                }

            case .ended, .cancelled, .failed:
                resetPan()

            default:
                break
            }
        }

        @objc
        private func handleHorizontalPan(_ recognizer: UIPanGestureRecognizer) {
            guard
                let controller,
                !controller.controlsLocked,
                let view = touchView
            else {
                finishHorizontalSeek()
                return
            }

            switch recognizer.state {
            case .began:
                controller.beginScrubbing()
                guard controller.isScrubbing else { return }
                startingSeekPosition = controller.timelinePosition

            case .changed:
                guard controller.isScrubbing else { return }
                controller.revealControls()
                let translation = recognizer.translation(in: view).x
                let fullWidthSeekRange = min(
                    max(controller.duration * 0.12, 30),
                    180
                )
                controller.timelinePosition = startingSeekPosition
                    + (translation / max(view.bounds.width, 1)) * fullWidthSeekRange
                controller.scrubPositionChanged()

            case .ended, .cancelled, .failed:
                finishHorizontalSeek()

            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard
                gestureRecognizer is UIPanGestureRecognizer,
                let pan = gestureRecognizer as? UIPanGestureRecognizer,
                let view = touchView
            else {
                return true
            }

            let velocity = pan.velocity(in: view)
            if pan === horizontalPan {
                return controller?.canSeek == true
                    && abs(velocity.x) > abs(velocity.y)
            }
            if pan === verticalPan {
                return abs(velocity.y) > abs(velocity.x)
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        private func resetPan() {
            activeSide = nil
            startingValue = 0
        }

        private func finishHorizontalSeek() {
            if controller?.isScrubbing == true {
                controller?.endScrubbing()
            }
            startingSeekPosition = 0
        }
    }

    enum Side {
        case left
        case right
    }
}

struct PlayerEdgeControlsOverlay: View {
    @Bindable var controller: PlaybackController

    var body: some View {
        GeometryReader { proxy in
            let barHeight = min(max(proxy.size.height * 0.28, 104), 156)

            HStack {
                PlayerVerticalLevelControl(
                    kind: .brightness,
                    value: controller.screenBrightness,
                    barHeight: barHeight
                ) { value in
                    controller.revealControls()
                    controller.setBrightness(value)
                }

                Spacer(minLength: 0)
                    .allowsHitTesting(false)

                PlayerVerticalLevelControl(
                    kind: .volume,
                    value: Double(controller.targetSystemVolume),
                    barHeight: barHeight
                ) { value in
                    controller.revealControls()
                    controller.setSystemVolume(value)
                }
            }
            .padding(.horizontal, proxy.size.width > proxy.size.height ? 20 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PlayerVerticalLevelControl: View {
    let kind: PlayerHUDKind
    let value: Double
    let barHeight: CGFloat
    let onValueChanged: (Double) -> Void

    private var clampedValue: Double {
        min(max(value, 0), 1)
    }

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: kind == .brightness ? "sun.max.fill" : volumeSymbol)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(DropFramePalette.signal)
                .frame(width: 26, height: 24)

            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(.black.opacity(0.42))
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.28), lineWidth: 1)
                    }

                Capsule()
                    .fill(DropFramePalette.signal)
                    .frame(height: max(barHeight * clampedValue, 7))

                Circle()
                    .fill(.white)
                    .frame(width: 15, height: 15)
                    .overlay {
                        Circle()
                            .stroke(DropFramePalette.night.opacity(0.32), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                    .offset(y: -(barHeight - 15) * clampedValue)
            }
            .frame(width: 6, height: barHeight)
            .frame(width: 44, height: barHeight)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        setValue(from: gesture.location.y)
                    }
            )
        }
        .shadow(color: .black.opacity(0.42), radius: 5, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .brightness ? "Screen brightness" : "Volume")
        .accessibilityValue("\(Int((clampedValue * 100).rounded())) percent")
        .accessibilityHint("Swipe up or down to adjust")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onValueChanged(min(clampedValue + 0.05, 1))
            case .decrement:
                onValueChanged(max(clampedValue - 0.05, 0))
            @unknown default:
                break
            }
        }
    }

    private func setValue(from verticalLocation: CGFloat) {
        let normalizedValue = 1 - (verticalLocation / barHeight)
        onValueChanged(min(max(normalizedValue, 0), 1))
    }

    private var volumeSymbol: String {
        switch clampedValue {
        case ...0.01:
            "speaker.slash.fill"
        case ..<0.5:
            "speaker.wave.1.fill"
        default:
            "speaker.wave.2.fill"
        }
    }
}

struct PlayerStatusOverlay: View {
    @Bindable var controller: PlaybackController
    let onClose: () -> Void

    var body: some View {
        switch controller.phase {
        case .loading:
            statusPill(symbol: nil, title: "Preparing video")
        case .buffering:
            statusPill(symbol: nil, title: "Buffering")
        case let .failed(message):
            failureCard(message: message)
        default:
            EmptyView()
        }
    }

    private func statusPill(symbol: String?, title: String) -> some View {
        HStack(spacing: 11) {
            if let symbol {
                Image(systemName: symbol)
            } else {
                ProgressView()
                    .tint(DropFramePalette.signal)
            }
            Text(title)
                .font(.system(size: 13, weight: .black, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(DropFramePalette.night.opacity(0.82), in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private func failureCard(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(DropFramePalette.coral)

            Text("Couldn’t play this video")
                .font(.system(size: 19, weight: .black, design: .rounded))
                .foregroundStyle(DropFramePalette.night)

            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DropFramePalette.muted)
                .multilineTextAlignment(.center)
                .lineLimit(4)

            HStack(spacing: 10) {
                Button("Close", action: onClose)
                    .buttonStyle(.bordered)
                Button("Try again") {
                    controller.retry()
                }
                .buttonStyle(.borderedProminent)
                .tint(DropFramePalette.cobalt)
            }
        }
        .padding(22)
        .frame(maxWidth: 320)
        .background(DropFramePalette.paper, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.32), radius: 20, y: 12)
        .padding(24)
    }
}

struct PlayerFeedbackOverlay: View {
    @Bindable var controller: PlaybackController

    var body: some View {
        ZStack {
            if let feedback = controller.seekFeedback {
                seekFeedback(feedback)
                    .transition(.scale(scale: 0.75).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func seekFeedback(_ feedback: PlayerSeekFeedback) -> some View {
        VStack(spacing: 6) {
            Image(systemName: feedback.direction == .backward ? "gobackward.10" : "goforward.10")
                .font(.system(size: 30, weight: .black))
            Text(feedback.direction == .backward ? "BACK 10" : "FORWARD 10")
                .font(.system(size: 10, weight: .black, design: .monospaced))
        }
        .foregroundStyle(DropFramePalette.night)
        .frame(width: 106, height: 88)
        .background(DropFramePalette.signal, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
    }
}
