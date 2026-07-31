import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HomeMasthead {
                        model.selectedTab = .settings
                    }
                    EditorialDownloadHero()
                    URLDownloadDesk()
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 22)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .background(HomeCanvas())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct HomeMasthead: View {
    let settingsAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 23, weight: .black))
                .foregroundStyle(HomeColors.yellow)
                .frame(width: 45, height: 45)
                .background(HomeColors.blue, in: .rect(cornerRadius: 13))
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(HomeColors.inkBlue.opacity(0.28), lineWidth: 1)
                        .offset(y: 3)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text("DROPFRAME")
                    .font(.system(size: 22, weight: .black))
                    .fontWidth(.condensed)
                    .tracking(-0.4)
                    .foregroundStyle(HomeColors.inkBlue)
                Text("YOUR POCKET VIDEO ARCHIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(HomeColors.inkBlue.opacity(0.58))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: settingsAction) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(HomeColors.inkBlue)
                    .frame(width: 45, height: 45)
                    .background(HomeColors.coral, in: .circle)
                    .overlay {
                        Circle()
                            .stroke(HomeColors.inkBlue.opacity(0.16), lineWidth: 1)
                    }
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Settings")
        }
    }
}

private struct EditorialDownloadHero: View {
    var body: some View {
        ZStack(alignment: .leading) {
            HeroGraphic()

            VStack(alignment: .leading, spacing: 11) {
                Text("PASTE • PICK • PLAY")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(HomeColors.blue)

                Text("DROP IT.\nKEEP IT.")
                    .font(.system(size: 49, weight: .black))
                    .fontWidth(.condensed)
                    .tracking(-2.4)
                    .foregroundStyle(HomeColors.inkBlue)
                    .lineSpacing(-7)

                Rectangle()
                    .fill(HomeColors.coral)
                    .frame(width: 94, height: 7)
                    .rotationEffect(.degrees(-2))

                Text("One link in.\nEvery available quality\nready for your iPhone.")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HomeColors.inkBlue.opacity(0.72))
                    .lineSpacing(2)
                    .frame(width: 165, alignment: .leading)
            }
            .frame(width: 228, alignment: .leading)
            .padding(.leading, 2)
            .zIndex(2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 306)
        .clipped()
        .accessibilityElement(children: .combine)
    }
}

private struct HeroGraphic: View {
    var body: some View {
        VStack(spacing: -27) {
            Image("HeroCutout", bundle: .main)
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 270)
                .accessibilityHidden(true)

            Text("LOCAL ONLY")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(HomeColors.blue, in: .capsule)
                .rotationEffect(.degrees(4))
                .offset(x: 31)
        }
        .offset(x: 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct URLDownloadDesk: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isLinkFocused: Bool

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 10) {
                Text("01")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(HomeColors.inkBlue)
                    .frame(width: 34, height: 27)
                    .background(HomeColors.yellow, in: .capsule)

                VStack(alignment: .leading, spacing: 1) {
                    Text("PASTE THE VIDEO LINK")
                        .font(.system(size: 17, weight: .black))
                        .fontWidth(.condensed)
                        .tracking(0.2)
                    Text("A webpage or a direct media address")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .foregroundStyle(.white)

                Spacer(minLength: 0)

                Image(systemName: "link.badge.plus")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(HomeColors.mint)
            }

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(HomeColors.blue)

                TextField("https://website.com/video", text: $model.linkText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HomeColors.inkBlue)
                    .tint(HomeColors.coral)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .focused($isLinkFocused)
                    .submitLabel(.go)
                    .onSubmit(inspectLink)

                PasteButton(payloadType: String.self) { values in
                    guard let value = values.first else { return }
                    model.linkText = value
                    isLinkFocused = false
                }
                .labelStyle(.iconOnly)
                .tint(HomeColors.blue)
                .accessibilityLabel("Paste link")
            }
            .padding(.horizontal, 14)
            .frame(height: 55)
            .background(HomeColors.cream, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isLinkFocused ? HomeColors.coral : .white.opacity(0.38),
                        lineWidth: isLinkFocused ? 2 : 1
                    )
            }

            Button(action: inspectLink) {
                HStack(spacing: 10) {
                    if model.isResolving {
                        ProgressView()
                            .tint(HomeColors.inkBlue)
                    } else {
                        Image(systemName: "arrow.down.to.line.compact")
                            .font(.system(size: 18, weight: .black))
                    }

                    Text(model.isResolving ? "FETCHING VIDEO…" : "FETCH VIDEO")
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22, weight: .black))
                }
                .font(.system(size: 16, weight: .black))
                .fontWidth(.condensed)
                .tracking(0.3)
                .foregroundStyle(HomeColors.inkBlue)
                .padding(.horizontal, 17)
                .frame(height: 56)
            }
            .buttonStyle(YellowDepthButtonStyle())
            .disabled(model.isResolving)

            Text("QUALITY CHOOSER  •  THUMBNAIL  •  OFFLINE SAVE")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.55)
                .foregroundStyle(.white.opacity(0.54))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(HomeColors.blue)
                .shadow(color: HomeColors.inkBlue.opacity(0.22), radius: 0, y: 7)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }

    private var trimmedLinkIsEmpty: Bool {
        model.linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func inspectLink() {
        guard !model.isResolving else { return }
        guard !trimmedLinkIsEmpty else {
            isLinkFocused = true
            return
        }
        isLinkFocused = false
        Task { await model.inspectLink() }
    }
}

private struct YellowDepthButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(HomeColors.yellowShadow)
                .offset(y: configuration.isPressed ? 2 : 6)

            configuration.label
                .background(HomeColors.yellow, in: .rect(cornerRadius: 14))
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.56), lineWidth: 1)
                }
                .offset(y: configuration.isPressed ? 4 : 0)
        }
        .scaleEffect(configuration.isPressed ? 0.993 : 1)
        .animation(.smooth(duration: 0.16), value: configuration.isPressed)
    }
}

private struct HomeCanvas: View {
    var body: some View {
        HomeColors.yellow
            .overlay(alignment: .topTrailing) {
                Circle()
                    .stroke(HomeColors.inkBlue.opacity(0.08), lineWidth: 28)
                    .frame(width: 190, height: 190)
                    .offset(x: 76, y: -80)
            }
            .overlay(alignment: .bottomLeading) {
                Rectangle()
                    .fill(HomeColors.coral.opacity(0.18))
                    .frame(width: 130, height: 28)
                    .rotationEffect(.degrees(-12))
                    .offset(x: -34, y: -30)
            }
            .ignoresSafeArea()
    }
}

private enum HomeColors {
    static let yellow = Color(hex: "FFE000")
    static let yellowShadow = Color(hex: "C89F00")
    static let inkBlue = Color(hex: "102D69")
    static let blue = Color(hex: "1854D8")
    static let coral = Color(hex: "FF665B")
    static let mint = Color(hex: "74E3BA")
    static let cream = Color(hex: "FFF8DE")
}
