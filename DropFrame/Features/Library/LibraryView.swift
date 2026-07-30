import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var isNewFolderPresented = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 24) {
                    DropFrameHeader(
                        eyebrow: "\(model.videos.count) saved · \(model.storageText)",
                        title: "Your library",
                        trailingSymbol: "folder.badge.plus",
                        action: { isNewFolderPresented = true }
                    )

                    LibraryStatsCard()

                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(
                            index: "01",
                            title: "Collections",
                            trailing: "\(model.folders.count) TOTAL",
                            indexColor: DropFramePalette.cobalt,
                            trailingColor: DropFramePalette.ink.opacity(0.62)
                        )
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.folders) { folder in
                                NavigationLink(value: folder) {
                                    FolderCard(
                                        folder: folder,
                                        videos: model.videos(in: folder)
                                    )
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                    }

                    if let latestVideo = model.videos.first {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionTitle(
                                index: "02",
                                title: "Latest drop",
                                indexColor: DropFramePalette.cobalt
                            )
                            VideoRow(video: latestVideo)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(
                DropFramePageCanvas(theme: .library)
                    .ignoresSafeArea()
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MediaFolder.self) { folder in
                FolderDetailView(folder: folder)
            }
        }
        .sheet(isPresented: $isNewFolderPresented) {
            NewFolderSheet()
                .environment(model)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct LibraryStatsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            stat(value: "\(model.videos.count)", label: "VIDEOS", color: DropFramePalette.signal)
            Rectangle()
                .fill(DropFramePalette.paper.opacity(0.22))
                .frame(width: 1, height: 54)
            stat(value: model.storageText, label: "ON DEVICE", color: DropFramePalette.mint)
            Rectangle()
                .fill(DropFramePalette.paper.opacity(0.22))
                .frame(width: 1, height: 54)
            stat(value: "\(model.folders.count)", label: "SHELVES", color: DropFramePalette.coral)
        }
        .padding(.vertical, 18)
        .background(DropFramePalette.ink, in: .rect(cornerRadius: 18))
    }

    private func stat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(DropFramePalette.paper.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FolderCard: View {
    let folder: MediaFolder
    let videos: [LibraryVideo]

    private var colorway: FolderColorway {
        FolderColorway(tintHex: folder.tintHex)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            FolderBackShape()
                .fill(colorway.back)
                .overlay {
                    FolderBackShape()
                        .stroke(.white.opacity(0.34), lineWidth: 1)
                }

            FolderDocumentStack(videos: videos)
                .padding(.horizontal, 25)
                .padding(.bottom, 67)

            FolderPocketShape()
                .fill(colorway.depth)
                .offset(y: 8)

            FolderPocketShape()
                .fill(
                    LinearGradient(
                        colors: [colorway.frontTop, colorway.frontBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    FolderPocketShape()
                        .stroke(.white.opacity(0.32), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(folder.name)
                            .font(.system(size: 17, weight: .black, design: .rounded))
                            .tracking(-0.35)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Text("\(videos.count) VIDEO\(videos.count == 1 ? "" : "S")")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(0.75)
                            .opacity(0.66)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: folder.symbol)
                        .font(.system(size: 20, weight: .black))
                }
            }
            .foregroundStyle(colorway.foreground)
            .padding(.horizontal, 15)
            .padding(.bottom, 15)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 184)
        .shadow(color: colorway.depth.opacity(0.24), radius: 9, y: 10)
        .compositingGroup()
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct FolderDocumentStack: View {
    let videos: [LibraryVideo]

    var body: some View {
        ZStack {
            FolderPaper()
                .rotationEffect(.degrees(-7))
                .offset(x: -23, y: 6)
            FolderPaper()
                .rotationEffect(.degrees(5))
                .offset(x: 22, y: 2)

            ForEach(
                Array(videos.prefix(2).enumerated()),
                id: \.element.id
            ) { index, video in
                AsyncThumbnail(url: video.thumbnailURL)
                    .frame(width: 58, height: 76)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.8), lineWidth: 2)
                    }
                    .rotationEffect(.degrees(index == 0 ? -4 : 4))
                    .offset(x: index == 0 ? -12 : 12, y: index == 0 ? 3 : 0)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 86)
    }
}

private struct FolderPaper: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Capsule()
                .fill(DropFramePalette.ink.opacity(0.12))
                .frame(width: 30, height: 5)
            Capsule()
                .fill(DropFramePalette.ink.opacity(0.08))
                .frame(height: 4)
            Capsule()
                .fill(DropFramePalette.ink.opacity(0.08))
                .frame(width: 40, height: 4)
            Spacer()
        }
        .padding(9)
        .frame(width: 61, height: 79)
        .background(.white.opacity(0.96), in: .rect(cornerRadius: 8))
        .shadow(color: DropFramePalette.night.opacity(0.1), radius: 4, y: 3)
        .accessibilityHidden(true)
    }
}

private struct FolderBackShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 8, y: rect.minY + 42))
        path.addLine(to: CGPoint(x: rect.minX + 8, y: rect.minY + 24))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 20, y: rect.minY + 12),
            control: CGPoint(x: rect.minX + 8, y: rect.minY + 12)
        )
        path.addLine(to: CGPoint(x: rect.minX + 61, y: rect.minY + 12))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 72, y: rect.minY + 18),
            control: CGPoint(x: rect.minX + 68, y: rect.minY + 12)
        )
        path.addLine(to: CGPoint(x: rect.minX + 84, y: rect.minY + 30))
        path.addLine(to: CGPoint(x: rect.maxX - 20, y: rect.minY + 30))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - 8, y: rect.minY + 42),
            control: CGPoint(x: rect.maxX - 8, y: rect.minY + 30)
        )
        path.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.maxY - 14))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - 20, y: rect.maxY - 2),
            control: CGPoint(x: rect.maxX - 8, y: rect.maxY - 2)
        )
        path.addLine(to: CGPoint(x: rect.minX + 20, y: rect.maxY - 2))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 8, y: rect.maxY - 14),
            control: CGPoint(x: rect.minX + 8, y: rect.maxY - 2)
        )
        path.closeSubpath()
        return path
    }
}

private struct FolderPocketShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 8, y: rect.minY + 72))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 22, y: rect.minY + 58),
            control: CGPoint(x: rect.minX + 8, y: rect.minY + 58)
        )
        path.addLine(to: CGPoint(x: rect.minX + 65, y: rect.minY + 58))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 82, y: rect.minY + 49),
            control: CGPoint(x: rect.minX + 76, y: rect.minY + 58)
        )
        path.addLine(to: CGPoint(x: rect.minX + 92, y: rect.minY + 42))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 108, y: rect.minY + 48),
            control: CGPoint(x: rect.minX + 100, y: rect.minY + 37)
        )
        path.addLine(to: CGPoint(x: rect.minX + 119, y: rect.minY + 56))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 130, y: rect.minY + 58),
            control: CGPoint(x: rect.minX + 124, y: rect.minY + 58)
        )
        path.addLine(to: CGPoint(x: rect.maxX - 22, y: rect.minY + 58))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - 8, y: rect.minY + 72),
            control: CGPoint(x: rect.maxX - 8, y: rect.minY + 58)
        )
        path.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.maxY - 14))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - 22, y: rect.maxY),
            control: CGPoint(x: rect.maxX - 8, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + 22, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 8, y: rect.maxY - 14),
            control: CGPoint(x: rect.minX + 8, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private struct FolderColorway {
    let frontTop: Color
    let frontBottom: Color
    let back: Color
    let depth: Color
    let foreground: Color

    init(tintHex: String) {
        switch tintHex.uppercased() {
        case "FFD60A":
            frontTop = Color(hex: "FFE76A")
            frontBottom = Color(hex: "FFC928")
            back = Color(hex: "3156D9")
            depth = Color(hex: "B98A00")
            foreground = DropFramePalette.ink
        case "1755EC", "2B5BFF":
            frontTop = Color(hex: "4D87FF")
            frontBottom = Color(hex: "1755EC")
            back = Color(hex: "79C7FF")
            depth = Color(hex: "0E338F")
            foreground = DropFramePalette.paper
        case "7BE2B8":
            frontTop = Color(hex: "A0F0D1")
            frontBottom = Color(hex: "4FCF9E")
            back = Color(hex: "17A96F")
            depth = Color(hex: "257A5D")
            foreground = DropFramePalette.ink
        case "9A73FF":
            frontTop = Color(hex: "C092FF")
            frontBottom = Color(hex: "8A5CE8")
            back = Color(hex: "5140C9")
            depth = Color(hex: "51328F")
            foreground = DropFramePalette.paper
        default:
            frontTop = Color(hex: "FF806D")
            frontBottom = Color(hex: tintHex)
            back = Color(hex: "FF9E36")
            depth = Color(hex: "B7352E")
            foreground = DropFramePalette.paper
        }
    }
}

struct VideoRow: View {
    @Environment(AppModel.self) private var model
    @State private var isDeleteConfirmationPresented = false
    @State private var isMovePresented = false
    let video: LibraryVideo

    var body: some View {
        HStack(spacing: 7) {
            Button {
                model.play(video)
            } label: {
                HStack(spacing: 13) {
                    thumbnail

                    VStack(alignment: .leading, spacing: 5) {
                        Text(video.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 7) {
                            Text(video.formatLabel)
                            Text(ByteCountFormatter.string(fromByteCount: video.fileSize, countStyle: .file))
                        }
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(DropFramePalette.muted)
                        if let pixelSizeText = video.pixelSizeText {
                            Text(pixelSizeText)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(DropFramePalette.muted)
                        }
                    }
                    Spacer()
                }
                .foregroundStyle(DropFramePalette.ink)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Menu {
                Button("Play", systemImage: "play.fill") {
                    model.play(video)
                }
                Button("Move to folder", systemImage: "folder") {
                    isMovePresented = true
                }
                Button("Delete video", systemImage: "trash", role: .destructive) {
                    isDeleteConfirmationPresented = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DropFramePalette.muted)
                    .frame(width: 42, height: 52)
                    .contentShape(.rect)
            }
            .accessibilityLabel("More actions for \(video.title)")
        }
        .padding(10)
        .background(DropFramePalette.paper, in: .rect(cornerRadius: 15))
        .sheet(isPresented: $isMovePresented) {
            MoveVideoSheet(video: video)
                .environment(model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Delete this video?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete video", role: .destructive) {
                Task { await model.delete(video) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(video.title) from DropFrame and deletes its local file.")
        }
    }

    private var thumbnail: some View {
                AsyncThumbnail(url: video.thumbnailURL)
                    .frame(width: 104, height: 72)
                    .compositingGroup()
                    .clipShape(.rect(cornerRadius: 11))
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(DropFramePalette.night.opacity(0.74), in: .circle)
                    }
    }
}

private struct MoveVideoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var movingFolderID: UUID?
    let video: LibraryVideo

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 11) {
                    ForEach(model.folders) { folder in
                        destinationButton(for: folder)
                    }
                }
                .padding(18)
            }
            .background(
                DropFramePageCanvas(theme: .library)
                    .ignoresSafeArea()
            )
            .navigationTitle("Move to folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func destinationButton(for folder: MediaFolder) -> some View {
        let isCurrentFolder = folder.id == video.folderID
        let isMovingHere = movingFolderID == folder.id

        return Button {
            movingFolderID = folder.id
            Task {
                let didMove = await model.move(video, to: folder)
                movingFolderID = nil
                if didMove {
                    dismiss()
                }
            }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: folder.symbol)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(DropFramePalette.ink)
                    .frame(width: 42, height: 42)
                    .background(
                        Color(hex: folder.tintHex),
                        in: .rect(cornerRadius: 12)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(isCurrentFolder ? "Current folder" : "\(model.videos(in: folder).count) videos")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(DropFramePalette.muted)
                }

                Spacer()

                if isMovingHere {
                    ProgressView()
                        .tint(DropFramePalette.cobalt)
                } else {
                    Image(systemName: isCurrentFolder ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(
                            isCurrentFolder
                                ? DropFramePalette.mint
                                : DropFramePalette.cobalt
                        )
                }
            }
            .foregroundStyle(DropFramePalette.ink)
            .padding(13)
            .background(DropFramePalette.paper, in: .rect(cornerRadius: 15))
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .stroke(
                        isCurrentFolder
                            ? DropFramePalette.mint
                            : DropFramePalette.hairline,
                        lineWidth: isCurrentFolder ? 2 : 1
                    )
            }
        }
        .buttonStyle(.pressable)
        .disabled(isCurrentFolder || movingFolderID != nil)
        .accessibilityHint(
            isCurrentFolder
                ? "This video is already in this folder."
                : "Moves the video into this folder."
        )
    }
}
