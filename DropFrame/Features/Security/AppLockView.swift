import LocalAuthentication
import Observation
import SwiftUI

@MainActor
@Observable
final class AppLockController {
    enum VisualState: Equatable {
        case locked
        case scanning
        case verified
        case failed
    }

    private(set) var isLocked = true
    private(set) var isAuthenticating = false
    private(set) var visualState: VisualState = .locked
    private(set) var failureMessage: String?
    private(set) var authenticationMethodName = "Face ID or Passcode"
    private(set) var authenticationSymbol = "faceid"

    @ObservationIgnored private var activeContext: LAContext?

    var unlockButtonTitle: String {
        switch visualState {
        case .scanning:
            "SCANNING IDENTITY"
        case .verified:
            "IDENTITY VERIFIED"
        case .failed:
            "TRY \(authenticationMethodName.uppercased())"
        case .locked:
            "UNLOCK WITH \(authenticationMethodName.uppercased())"
        }
    }

    func refreshAuthenticationMethod() {
        let context = LAContext()
        var biometricError: NSError?
        _ = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &biometricError
        )

        switch context.biometryType {
        case .faceID:
            authenticationMethodName = "Face ID"
            authenticationSymbol = "faceid"
        case .touchID:
            authenticationMethodName = "Touch ID"
            authenticationSymbol = "touchid"
        case .opticID:
            authenticationMethodName = "Optic ID"
            authenticationSymbol = "person.badge.key.fill"
        case .none:
            authenticationMethodName = "iPhone Passcode"
            authenticationSymbol = "lock.shield.fill"
        @unknown default:
            authenticationMethodName = "Biometrics"
            authenticationSymbol = "person.badge.key.fill"
        }
    }

    func lock() {
        activeContext?.invalidate()
        activeContext = nil
        isAuthenticating = false
        isLocked = true
        visualState = .locked
        failureMessage = nil
    }

    func unlockWithoutAuthentication() {
        activeContext?.invalidate()
        activeContext = nil
        isAuthenticating = false
        isLocked = false
        visualState = .verified
        failureMessage = nil
    }

    @discardableResult
    func authenticate(reason: String) async -> Bool {
        guard !isAuthenticating else { return false }

        refreshAuthenticationMethod()
        let context = LAContext()
        context.localizedCancelTitle = "Keep Locked"
        context.localizedFallbackTitle = "Use Passcode"

        var policyError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &policyError
        ) else {
            isLocked = true
            visualState = .failed
            failureMessage = policyError.map(friendlyMessage(for:))
                ?? "Set an iPhone passcode before enabling the DropFrame vault."
            return false
        }

        activeContext = context
        isAuthenticating = true
        isLocked = true
        visualState = .scanning
        failureMessage = nil

        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            guard activeContext === context else { return false }
            guard authenticated else {
                isAuthenticating = false
                visualState = .failed
                failureMessage = "Identity could not be verified."
                return false
            }

            visualState = .verified
            try? await Task.sleep(for: .milliseconds(520))
            guard activeContext === context else { return false }

            activeContext = nil
            isAuthenticating = false
            isLocked = false
            failureMessage = nil
            return true
        } catch {
            guard activeContext === context else { return false }
            activeContext = nil
            isAuthenticating = false
            isLocked = true
            visualState = .failed
            failureMessage = friendlyMessage(for: error)
            return false
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        guard let localError = error as? LAError else {
            return "Authentication is unavailable. Please try again."
        }

        switch localError.code {
        case .userCancel, .systemCancel, .appCancel:
            return "DropFrame remains locked."
        case .authenticationFailed:
            return "Identity was not recognized. Try again or use your passcode."
        case .biometryLockout:
            return "Biometrics are temporarily locked. Use your iPhone passcode."
        case .biometryNotEnrolled:
            return "Set up biometrics in iPhone Settings, or use your passcode."
        case .passcodeNotSet:
            return "Set an iPhone passcode before enabling the DropFrame vault."
        case .biometryNotAvailable:
            return "Biometrics are unavailable. Use your iPhone passcode."
        default:
            return "Authentication could not finish. Please try again."
        }
    }
}

struct SecuredRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLockController.self) private var appLock
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLockRequired: Bool {
        model.settings.appLockEnabled && appLock.isLocked
    }

    private var shouldBlockContent: Bool {
        isLockRequired
    }

    private var shouldShowLock: Bool {
        isLockRequired && scenePhase != .background
    }

    private var shouldShowPrivacyShield: Bool {
        isLockRequired && scenePhase == .background
    }

    var body: some View {
        ZStack {
            RootView()
                .allowsHitTesting(!shouldBlockContent)
                .accessibilityHidden(shouldBlockContent)

            if shouldShowPrivacyShield {
                AppPrivacyShield()
                    .zIndex(90)
            }

            if shouldShowLock {
                AppLockView(controller: appLock)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 1.025).combined(with: .opacity)
                    )
                    .zIndex(100)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.28),
            value: shouldShowLock
        )
        .task {
            appLock.refreshAuthenticationMethod()
            guard model.settings.appLockEnabled else {
                appLock.unlockWithoutAuthentication()
                return
            }
            appLock.lock()
        }
        .onChange(of: model.settings.appLockEnabled) { _, enabled in
            if !enabled {
                appLock.unlockWithoutAuthentication()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        guard model.settings.appLockEnabled else { return }

        switch phase {
        case .inactive:
            // Keep the current screen in place during system overlays and the
            // swipe-home transition. The vault remains locked without prompting.
            break
        case .background:
            dismissSensitivePresentations()
            appLock.lock()
        case .active:
            // Keep the vault locked until the user explicitly taps the
            // existing Face ID button. This avoids expanding the system Face
            // ID interface every time DropFrame becomes active.
            break
        @unknown default:
            break
        }
    }

    private func dismissSensitivePresentations() {
        model.playerVideo = nil
        model.isResultPresented = false
        model.presentedError = nil
    }
}

private struct AppPrivacyShield: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(hex: "12366A")
                    .ignoresSafeArea()

                CyberGrid()
                    .opacity(0.18)
                    .ignoresSafeArea()

                Circle()
                    .stroke(DropFramePalette.signal.opacity(0.14), lineWidth: 24)
                    .frame(width: 210, height: 210)
                    .offset(x: proxy.size.width * 0.43, y: -proxy.size.height * 0.42)

                Capsule()
                    .fill(DropFramePalette.coral.opacity(0.2))
                    .frame(width: 180, height: 24)
                    .rotationEffect(.degrees(-14))
                    .offset(x: -proxy.size.width * 0.4, y: proxy.size.height * 0.43)

                VStack(spacing: 14) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(DropFramePalette.night)
                        .frame(width: 68, height: 68)
                        .background(DropFramePalette.signal, in: .rect(cornerRadius: 19))
                        .overlay {
                            RoundedRectangle(cornerRadius: 19)
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.2), radius: 0, y: 6)

                    VStack(spacing: 5) {
                        Text("DROPFRAME")
                            .font(.system(size: 29, weight: .black, design: .rounded))
                            .tracking(0.5)

                        Text("PRIVATE VIDEO VAULT")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(1.7)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AppLockView: View {
    @Bindable var controller: AppLockController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scanPosition = -1.0
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            let portraitScannerSize = min(
                max(min(proxy.size.width * 0.66, proxy.size.height * 0.31), 200),
                292
            )
            let landscapeScannerSize = min(
                max(proxy.size.height * 0.48, 160),
                210
            )

            ZStack {
                Color(hex: "12366A")
                    .ignoresSafeArea()

                InteractiveDotField(authenticationState: controller.visualState)
                    .ignoresSafeArea()

                if isLandscape {
                    VStack(spacing: 16) {
                        lockHeader

                        HStack(spacing: 30) {
                            scanner(size: landscapeScannerSize)

                            VStack(spacing: 14) {
                                statusCopy
                                unlockButton
                                securityFooter
                            }
                            .frame(maxWidth: 390)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.leading, max(proxy.safeAreaInsets.leading, 24) + 8)
                    .padding(.trailing, max(proxy.safeAreaInsets.trailing, 24) + 8)
                    .padding(.vertical, 16)
                } else {
                    VStack(spacing: 0) {
                        lockHeader

                        Spacer(minLength: 26)

                        scanner(size: portraitScannerSize)

                        statusCopy
                            .padding(.top, 28)

                        Spacer(minLength: 22)

                        unlockButton

                        securityFooter
                            .padding(.top, 16)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, max(proxy.safeAreaInsets.top, 18) + 8)
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom, 18) + 8)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard !reduceMotion else { return }
            scanPosition = -1
            pulse = false
            withAnimation(
                .easeInOut(duration: 1.75)
                    .repeatForever(autoreverses: true)
            ) {
                scanPosition = 1
            }
            withAnimation(
                .easeInOut(duration: 1.15)
                    .repeatForever(autoreverses: true)
            ) {
                pulse = true
            }
        }
    }

    private var lockHeader: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(DropFramePalette.night)
                    .frame(width: 38, height: 38)
                    .background(DropFramePalette.signal, in: .rect(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 2) {
                    Text("DROPFRAME")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                    Text("PRIVATE VIDEO VAULT")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.54))
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(DropFramePalette.mint)
                    .frame(width: 7, height: 7)
                Text("DEVICE SECURE")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(0.7)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.white.opacity(0.1), in: .capsule)
        }
        .foregroundStyle(.white)
    }

    private func scanner(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.08), lineWidth: 1)
                .frame(width: size, height: size)

            Circle()
                .stroke(DropFramePalette.mint.opacity(0.24), lineWidth: 10)
                .frame(width: size * 0.82, height: size * 0.82)
                .scaleEffect(pulse ? 1.025 : 0.98)

            Circle()
                .trim(from: 0.08, to: 0.34)
                .stroke(
                    DropFramePalette.signal,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(controller.visualState == .verified ? 220 : 24))
                .frame(width: size * 0.93, height: size * 0.93)
                .animation(.smooth(duration: 0.5), value: controller.visualState)

            Image(
                systemName: controller.visualState == .verified
                    ? "checkmark"
                    : controller.authenticationSymbol
            )
            .font(.system(size: size * 0.25, weight: .light))
            .symbolEffect(.bounce, value: controller.visualState == .verified)
            .foregroundStyle(
                controller.visualState == .verified
                    ? DropFramePalette.mint
                    : .white
            )

            if controller.visualState == .scanning {
                Capsule()
                    .fill(DropFramePalette.mint)
                    .frame(width: size * 0.57, height: 3)
                    .shadow(color: DropFramePalette.mint, radius: 11)
                    .offset(y: scanPosition * size * 0.25)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var statusCopy: some View {
        VStack(spacing: 9) {
            EditorialLabel(
                text: controller.visualState == .verified
                    ? "Access granted"
                    : "Identity gate 01",
                color: controller.visualState == .verified
                    ? DropFramePalette.mint
                    : DropFramePalette.signal
            )

            Text(statusTitle)
                .font(.system(size: 31, weight: .black, design: .rounded))
                .tracking(-1)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(
                controller.failureMessage
                    ?? "Your folders, downloads, and playback history stay hidden until you authenticate."
            )
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.68))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 330)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch controller.visualState {
        case .locked:
            "Archive locked."
        case .scanning:
            "Reading identity…"
        case .verified:
            "Welcome back."
        case .failed:
            "Still protected."
        }
    }

    private var unlockButton: some View {
        Button {
            Task {
                _ = await controller.authenticate(
                    reason: "Unlock your private DropFrame video archive."
                )
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: controller.authenticationSymbol)
                    .font(.system(size: 18, weight: .black))
                Text(controller.unlockButtonTitle)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(0.5)
                    .frame(maxWidth: .infinity)
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .black))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 17)
            .frame(maxWidth: 390)
            .frame(height: 58)
            .background(DropFramePalette.cobalt.opacity(0.48), in: .rect(cornerRadius: 18))
            .dropFrameGlass(in: RoundedRectangle(cornerRadius: 18), interactive: true)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(DropFramePalette.mint.opacity(0.58), lineWidth: 1)
            }
        }
        .buttonStyle(.pressable)
        .disabled(controller.isAuthenticating)
        .accessibilityHint("Uses the iPhone system authentication screen")
    }

    private var securityFooter: some View {
        Text("LOCAL AUTHENTICATION • NOTHING LEAVES THIS IPHONE")
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .tracking(0.9)
            .foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.center)
    }
}

private struct InteractiveDotField: View {
    let authenticationState: AppLockController.VisualState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fingerLocation = CGPoint.zero
    @State private var fingerStrength: CGFloat = 0

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: reduceMotion ? 1 : 1 / 30,
                paused: reduceMotion
            )
        ) { timeline in
            Canvas { context, size in
                drawDots(
                    context: &context,
                    size: size,
                    time: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if distance(from: fingerLocation, to: value.location) > 1.5 {
                        fingerLocation = value.location
                    }
                    if fingerStrength < 1 {
                        fingerStrength = 1
                    }
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.55)) {
                        fingerStrength = 0
                    }
                }
        )
        .accessibilityHidden(true)
    }

    private func drawDots(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval
    ) {
        let spacing: CGFloat = size.width > size.height ? 21 : 19
        let columns = Int(ceil(size.width / spacing)) + 2
        let rows = Int(ceil(size.height / spacing)) + 2
        let fieldOrigin = CGPoint(x: size.width * 0.5, y: size.height * 0.43)
        let phase = reduceMotion ? 0 : CGFloat(time.truncatingRemainder(dividingBy: 120))

        for row in 0..<rows {
            for column in 0..<columns {
                let gridX = CGFloat(column) * spacing - spacing * 0.5
                let gridY = CGFloat(row) * spacing - spacing * 0.5
                let seed = CGFloat(column) * 0.47 + CGFloat(row) * 0.31
                let wave = sin(phase * 0.92 + seed)
                let crossWave = cos(phase * 0.54 - seed * 1.37)

                var point = CGPoint(
                    x: gridX + crossWave * 1.15,
                    y: gridY + wave * 1.65
                )
                var radius = 1.55 + (wave + 1) * 0.30
                var opacity = 0.28 + (crossWave + 1) * 0.055

                let originDistance = distance(from: point, to: fieldOrigin)
                let statePulse = authenticationPulse(
                    distance: originDistance,
                    time: phase
                )
                radius += statePulse * 1.45
                opacity += statePulse * 0.34

                let touchDistance = distance(from: point, to: fingerLocation)
                if fingerStrength > 0, touchDistance < 126 {
                    let influence = (1 - touchDistance / 126) * fingerStrength
                    let directionX = (point.x - fingerLocation.x) / max(touchDistance, 1)
                    let directionY = (point.y - fingerLocation.y) / max(touchDistance, 1)
                    point.x += directionX * influence * 24
                    point.y += directionY * influence * 24
                    radius += influence * 2.5
                    opacity += influence * 0.62
                }

                let isAccentDot = (row + column * 3).isMultiple(of: 13)
                let color = isAccentDot
                    ? DropFramePalette.signal
                    : stateColor
                let dotRect = CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )

                context.fill(
                    Path(ellipseIn: dotRect),
                    with: .color(color.opacity(min(opacity, 0.92)))
                )
            }
        }
    }

    private var stateColor: Color {
        switch authenticationState {
        case .locked:
            .white
        case .scanning:
            DropFramePalette.mint
        case .verified:
            DropFramePalette.signal
        case .failed:
            DropFramePalette.coral
        }
    }

    private func authenticationPulse(distance: CGFloat, time: CGFloat) -> CGFloat {
        switch authenticationState {
        case .locked:
            return max(0, 1 - distance / 360) * 0.16
        case .scanning:
            let waveRadius = (time * 74).truncatingRemainder(dividingBy: 310)
            return max(0, 1 - abs(distance - waveRadius) / 46)
        case .verified:
            let waveRadius = (time * 118).truncatingRemainder(dividingBy: 430)
            return max(0, 1 - abs(distance - waveRadius) / 68)
        case .failed:
            return max(0, sin(time * 5.5)) * max(0, 1 - distance / 290) * 0.72
        }
    }

    private func distance(from first: CGPoint, to second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}

private struct CyberGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 30

            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }

            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }

            context.stroke(
                path,
                with: .color(.white.opacity(0.12)),
                lineWidth: 0.7
            )
        }
        .accessibilityHidden(true)
    }
}
