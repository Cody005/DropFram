import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLockController.self) private var appLock

    @State private var isUpdatingAppLock = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    DropFrameHeader(
                        eyebrow: "Tune the machine",
                        title: "Settings",
                        trailingSymbol: "checkmark",
                        action: { model.saveSettings() },
                        foreground: DropFramePalette.paper,
                        eyebrowColor: DropFramePalette.paper.opacity(0.72)
                    )

                    SettingsSection(index: "01", title: "Private vault") {
                        AppLockSettingsCard(
                            isEnabled: model.settings.appLockEnabled,
                            isUpdating: isUpdatingAppLock,
                            authenticationName: appLock.authenticationMethodName,
                            onToggle: setAppLockEnabled,
                            onLockNow: lockNow
                        )
                    }

                    SettingsSection(index: "02", title: "On-device resolver") {
                        HStack(spacing: 13) {
                            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(DropFramePalette.cobalt)
                                .frame(width: 40, height: 40)
                                .background(
                                    DropFramePalette.cobalt.opacity(0.10),
                                    in: .rect(cornerRadius: 11)
                                )
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Runs on this iPhone")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                Text("No Mac, server, address, or private token required")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(DropFramePalette.muted)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(DropFramePalette.mint)
                        }
                        .padding(14)
                        .background(DropFramePalette.paper, in: .rect(cornerRadius: 14))

                        Text("DropFrame can inspect direct video links and webpages that expose standard MP4, MOV, M4V, or HLS media. DRM and private streams remain protected.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DropFramePalette.paper)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SettingsSection(index: "03", title: "Playback & transfer") {
                        SettingsToggle(
                            title: "Autoplay",
                            detail: "Start local videos immediately",
                            symbol: "play.fill",
                            isOn: $model.settings.autoplay
                        )
                        SettingsToggle(
                            title: "Keep screen awake",
                            detail: "Useful during longer playback",
                            symbol: "sun.max.fill",
                            isOn: $model.settings.keepScreenAwake
                        )
                    }

                    SettingsSection(index: "04", title: "Storage") {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.storageText)
                                    .font(.system(size: 27, weight: .black, design: .rounded))
                                EditorialLabel(text: "\(model.videos.count) downloaded videos")
                            }
                            Spacer()
                            Image(systemName: "internaldrive.fill")
                                .font(.system(size: 32, weight: .black))
                                .foregroundStyle(DropFramePalette.cobalt)
                        }
                        .padding(16)
                        .background(DropFramePalette.paper, in: .rect(cornerRadius: 14))
                    }

                    PrivacyCard()
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(
                DropFramePageCanvas(theme: .settings)
                    .ignoresSafeArea()
            )
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: model.settings) {
                model.saveSettings()
            }
        }
    }

    private func setAppLockEnabled(_ enabled: Bool) {
        guard !isUpdatingAppLock else { return }

        Task { @MainActor in
            isUpdatingAppLock = true
            defer { isUpdatingAppLock = false }

            let reason = enabled
                ? "Confirm your identity to enable the DropFrame private vault."
                : "Confirm your identity to turn off the DropFrame private vault."
            let authenticated = await appLock.authenticate(reason: reason)
            guard authenticated else {
                model.presentedError = appLock.failureMessage
                    ?? "DropFrame could not verify your identity."
                return
            }

            model.settings.appLockEnabled = enabled
            model.saveSettings()
        }
    }

    private func lockNow() {
        appLock.lock()
        Task {
            _ = await appLock.authenticate(
                reason: "Unlock your private DropFrame video archive."
            )
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let index: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionTitle(
                index: index,
                title: title,
                indexColor: DropFramePalette.signal,
                titleColor: DropFramePalette.paper
            )
            content
        }
    }
}

private struct SettingsToggle: View {
    let title: String
    let detail: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(DropFramePalette.cobalt)
                    .frame(width: 32, height: 32)
                    .background(DropFramePalette.cobalt.opacity(0.10), in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(detail)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DropFramePalette.muted)
                }
            }
        }
        .tint(DropFramePalette.cobalt)
        .padding(14)
        .background(DropFramePalette.paper, in: .rect(cornerRadius: 14))
    }
}

private struct AppLockSettingsCard: View {
    let isEnabled: Bool
    let isUpdating: Bool
    let authenticationName: String
    let onToggle: (Bool) -> Void
    let onLockNow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(DropFramePalette.cobalt)
                    Image(systemName: isEnabled ? "faceid" : "lock.shield.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(
                            isEnabled
                                ? DropFramePalette.mint
                                : DropFramePalette.signal
                        )
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(authenticationName) lock")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                    Text(
                        isEnabled
                            ? "Your archive locks when DropFrame leaves the screen"
                            : "Require biometrics or the iPhone passcode to enter"
                    )
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(DropFramePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isUpdating {
                    ProgressView()
                        .tint(DropFramePalette.cobalt)
                        .frame(width: 50)
                } else {
                    Toggle(
                        "App lock",
                        isOn: Binding(
                            get: { isEnabled },
                            set: onToggle
                        )
                    )
                    .labelsHidden()
                    .tint(DropFramePalette.cobalt)
                }
            }

            if isEnabled {
                Divider()
                    .padding(.vertical, 14)

                Button(action: onLockNow) {
                    HStack {
                        Image(systemName: "lock.fill")
                        Text("LOCK DROPFRAME NOW")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(0.5)
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .foregroundStyle(DropFramePalette.paper)
                    .padding(.horizontal, 15)
                    .frame(height: 46)
                    .background(DropFramePalette.coral, in: .rect(cornerRadius: 13))
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(15)
        .background(DropFramePalette.paper, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isEnabled
                        ? DropFramePalette.mint.opacity(0.7)
                        : DropFramePalette.hairline,
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PrivacyCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PERSONAL MODE")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1)
                Spacer()
                Image(systemName: "lock.shield.fill")
            }
            Text("Downloads stay in DropFrame’s private on-device container and the library keeps a recovery index. Only use it for media you are allowed to save; some sites protect streams or prohibit downloading.")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DropFramePalette.ink)
        .padding(18)
        .background(DropFramePalette.signal, in: .rect(cornerRadius: 16))
    }
}
