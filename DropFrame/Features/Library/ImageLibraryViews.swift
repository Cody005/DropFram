import ImageIO
import SwiftUI
import UIKit

struct LibraryItemRow: View {
    let item: LibraryItem

    var body: some View {
        VStack(spacing: 0) {
            switch item {
            case .video(let video):
                VideoRow(video: video)
            case .image(let image):
                ImageRow(image: image)
            }
        }
    }
}

struct SavedImageThumbnail: View {
    @Environment(AppModel.self) private var model
    let image: LibraryImage
    var contentMode: ContentMode = .fill

    @State private var renderedImage: UIImage?

    var body: some View {
        ZStack {
            DropFramePalette.violet.opacity(0.28)
            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: "photo.fill")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(DropFramePalette.paper)
            }
        }
        .task(id: "\(image.folderID.uuidString)/\(image.localFilename)") {
            let url = await model.localURL(for: image)
            let decoded = await Task.detached(priority: .utility) {
                ImageFileDecoder.thumbnail(at: url, maximumPixelSize: 900)
            }.value
            guard !Task.isCancelled else { return }
            renderedImage = decoded
        }
    }
}

struct ImageRow: View {
    @Environment(AppModel.self) private var model
    @State private var isDeleteConfirmationPresented = false
    @State private var isMovePresented = false
    let image: LibraryImage

    var body: some View {
        HStack(spacing: 7) {
            Button {
                model.view(image)
            } label: {
                HStack(spacing: 13) {
                    SavedImageThumbnail(image: image)
                        .frame(width: 104, height: 72)
                        .compositingGroup()
                        .clipShape(.rect(cornerRadius: 11))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "photo.fill")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 27, height: 27)
                                .background(DropFramePalette.cobalt.opacity(0.88), in: .circle)
                                .padding(5)
                        }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(image.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 7) {
                            Text(image.formatLabel)
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: image.fileSize,
                                    countStyle: .file
                                )
                            )
                        }
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(DropFramePalette.muted)
                        if image.pixelWidth > 0, image.pixelHeight > 0 {
                            Text(image.pixelSizeText)
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
                Button("View image", systemImage: "photo.fill") {
                    model.view(image)
                }
                Button("Move to folder", systemImage: "folder") {
                    isMovePresented = true
                }
                Button("Delete image", systemImage: "trash", role: .destructive) {
                    isDeleteConfirmationPresented = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DropFramePalette.muted)
                    .frame(width: 42, height: 52)
                    .contentShape(.rect)
            }
            .accessibilityLabel("More actions for \(image.title)")
        }
        .padding(10)
        .background(DropFramePalette.paper, in: .rect(cornerRadius: 15))
        .sheet(isPresented: $isMovePresented) {
            MoveImageSheet(image: image)
                .environment(model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Delete this image?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete image", role: .destructive) {
                Task { await model.delete(image) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(image.title) from DropFrame and deletes its local file.")
        }
    }
}

struct SavedImageViewer: View {
    @Environment(AppModel.self) private var model
    let image: LibraryImage

    @State private var renderedImage: UIImage?
    @State private var localURL: URL?
    @State private var scale = 1.0
    @State private var settledScale = 1.0

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(zoomGesture)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(DropFramePalette.paper)
                    .controlSize(.large)
            }

        }
        .overlay(alignment: .top) {
            HStack(spacing: 12) {
                Button {
                    model.presentedImage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(DropFramePalette.ink)
                        .frame(width: 46, height: 46)
                        .background(DropFramePalette.paper, in: .circle)
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.72), lineWidth: 1)
                        }
                        .shadow(color: DropFramePalette.night.opacity(0.26), radius: 8, y: 4)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Close image")

                Spacer()

                if let localURL {
                    ShareLink(item: localURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(DropFramePalette.ink)
                            .frame(width: 46, height: 46)
                            .background(DropFramePalette.paper, in: .circle)
                            .overlay {
                                Circle()
                                    .stroke(.white.opacity(0.72), lineWidth: 1)
                            }
                            .shadow(
                                color: DropFramePalette.night.opacity(0.26),
                                radius: 8,
                                y: 4
                            )
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Share image")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .task {
            let resolvedURL = await model.localURL(for: image)
            localURL = resolvedURL
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageFileDecoder.fullImage(at: resolvedURL)
            }.value
            guard !Task.isCancelled else { return }
            renderedImage = decoded
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(settledScale * value.magnification, 1), 5)
            }
            .onEnded { _ in
                settledScale = scale
            }
    }
}

private struct MoveImageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var movingFolderID: UUID?
    let image: LibraryImage

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
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func destinationButton(for folder: MediaFolder) -> some View {
        let isCurrentFolder = folder.id == image.folderID
        let isMovingHere = movingFolderID == folder.id

        return Button {
            movingFolderID = folder.id
            Task {
                let didMove = await model.move(image, to: folder)
                movingFolderID = nil
                if didMove { dismiss() }
            }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: folder.symbol)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(DropFramePalette.ink)
                    .frame(width: 42, height: 42)
                    .background(Color(hex: folder.tintHex), in: .rect(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(
                        isCurrentFolder
                            ? "Current folder"
                            : "\(model.items(in: folder).count) saved items"
                    )
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(DropFramePalette.muted)
                }

                Spacer()

                if isMovingHere {
                    ProgressView().tint(DropFramePalette.cobalt)
                } else {
                    Image(
                        systemName: isCurrentFolder
                            ? "checkmark.circle.fill"
                            : "arrow.right.circle.fill"
                    )
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(
                        isCurrentFolder ? DropFramePalette.mint : DropFramePalette.cobalt
                    )
                }
            }
            .foregroundStyle(DropFramePalette.ink)
            .padding(13)
            .background(DropFramePalette.paper, in: .rect(cornerRadius: 15))
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .stroke(
                        isCurrentFolder ? DropFramePalette.mint : DropFramePalette.hairline,
                        lineWidth: isCurrentFolder ? 2 : 1
                    )
            }
        }
        .buttonStyle(.pressable)
        .disabled(isCurrentFolder || movingFolderID != nil)
        .accessibilityHint(
            isCurrentFolder
                ? "This image is already in this folder."
                : "Moves the image into this folder."
        )
    }
}

private enum ImageFileDecoder {
    static func thumbnail(at url: URL, maximumPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    static func fullImage(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            )
        else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
