import SwiftUI

enum DropFramePalette {
    static let canvas = Color(hex: "F5F8FF")
    static let ink = Color(hex: "172642")
    static let night = Color(hex: "091A33")
    static let paper = Color(hex: "FFFEFB")
    static let signal = Color(hex: "FFD60A")
    static let cobalt = Color(hex: "1755EC")
    static let coral = Color(hex: "FF5E52")
    static let mint = Color(hex: "7BE2B8")
    static let violet = Color(hex: "9A73FF")
    static let muted = Color(hex: "6E7890")
    static let hairline = Color(hex: "284269").opacity(0.14)
}

enum DropFramePageTheme {
    case library
    case downloads
    case settings

    fileprivate var background: Color {
        switch self {
        case .library:
            Color(hex: "FF665B")
        case .downloads:
            Color(hex: "4775D1")
        case .settings:
            Color(hex: "916AF2")
        }
    }

    fileprivate var motif: Color {
        switch self {
        case .library:
            DropFramePalette.cobalt
        case .downloads:
            DropFramePalette.signal
        case .settings:
            DropFramePalette.signal
        }
    }
}

struct DropFramePageCanvas: View {
    let theme: DropFramePageTheme

    var body: some View {
        theme.background
        .overlay(alignment: .topTrailing) {
            Circle()
                .stroke(theme.motif.opacity(0.15), lineWidth: 30)
                .frame(width: 210, height: 210)
                .offset(x: 74, y: -92)
        }
        .overlay(alignment: .bottomLeading) {
            Capsule()
                .fill(theme.motif.opacity(0.13))
                .frame(width: 190, height: 38)
                .rotationEffect(.degrees(-13))
                .offset(x: -52, y: -28)
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

struct EditorialLabel: View {
    let text: String
    var color: Color = DropFramePalette.muted

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(color)
    }
}

struct DropFrameHeader: View {
    let eyebrow: String
    let title: String
    let trailingSymbol: String?
    var action: (() -> Void)?
    var foreground: Color = DropFramePalette.ink
    var eyebrowColor: Color?
    var actionBackground: Color = DropFramePalette.paper

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                EditorialLabel(
                    text: eyebrow,
                    color: eyebrowColor ?? foreground.opacity(0.62)
                )
                Text(title)
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .tracking(-1.4)
                    .foregroundStyle(foreground)
            }
            Spacer()
            if let trailingSymbol, let action {
                Button(action: action) {
                    Image(systemName: trailingSymbol)
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(DropFramePalette.ink)
                        .background(actionBackground, in: .rect(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(DropFramePalette.hairline, lineWidth: 1)
                        }
                }
                .buttonStyle(.pressable)
            }
        }
    }
}

struct AsyncThumbnail: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @ViewBuilder
    var body: some View {
        if let url, url.isFileURL {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    placeholder
                        .overlay { ProgressView().tint(DropFramePalette.ink) }
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
            .animation(.easeInOut(duration: 0.22), value: url)
        }
    }

    private var placeholder: some View {
        DropFramePalette.violet
            .overlay {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(DropFramePalette.paper)
            }
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.smooth(duration: 0.18), value: configuration.isPressed)
    }
}

struct DepthButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(hex: "0C399E"))
                .offset(y: configuration.isPressed ? 2 : 7)

            configuration.label
                .background(DropFramePalette.cobalt, in: .rect(cornerRadius: 16))
                .offset(y: configuration.isPressed ? 4 : 0)
        }
            .scaleEffect(configuration.isPressed ? 0.992 : 1)
            .shadow(color: DropFramePalette.cobalt.opacity(0.24), radius: 9, y: 9)
            .animation(.smooth(duration: 0.16), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { .init() }
}

extension View {
    @ViewBuilder
    func dropFrameGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if interactive {
                glassEffect(.regular.interactive(), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(.white.opacity(0.65), lineWidth: 1)
                }
        }
    }
}
