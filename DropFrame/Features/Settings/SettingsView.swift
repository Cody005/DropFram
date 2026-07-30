import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

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

                    SettingsSection(index: "01", title: "On-device resolver") {
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

                    SettingsSection(index: "02", title: "Playback & transfer") {
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

                    SettingsSection(index: "03", title: "Storage") {
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
            Text("Downloads stay in DropFrame’s Documents container. Only use it for media you are allowed to save; some sites protect streams or prohibit downloading.")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DropFramePalette.ink)
        .padding(18)
        .background(DropFramePalette.signal, in: .rect(cornerRadius: 16))
    }
}
