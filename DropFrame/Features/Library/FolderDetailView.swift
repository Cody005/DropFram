import SwiftUI

struct FolderDetailView: View {
    @Environment(AppModel.self) private var model
    let folder: MediaFolder

    private var videos: [LibraryVideo] {
        model.videos(in: folder)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 15) {
                folderBanner

                if videos.isEmpty {
                    emptyState
                } else {
                    ForEach(videos) { video in
                        VideoRow(video: video)
                    }
                }
            }
            .padding(18)
        }
        .background(DropFramePalette.libraryCanvas.ignoresSafeArea())
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var folderBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                EditorialLabel(text: "Personal collection", color: DropFramePalette.ink.opacity(0.52))
                Text("\(videos.count) video\(videos.count == 1 ? "" : "s")")
                    .font(.system(size: 30, weight: .black, design: .rounded))
            }
            Spacer()
            Image(systemName: folder.symbol)
                .font(.system(size: 42, weight: .black))
        }
        .foregroundStyle(DropFramePalette.ink)
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(hex: folder.tintHex), in: .rect(cornerRadius: 18))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 42, weight: .black))
                .foregroundStyle(DropFramePalette.cobalt)
            Text("This shelf is ready")
                .font(.system(size: 21, weight: .black, design: .rounded))
            Text("Choose this folder the next time you download a video.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(DropFramePalette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(34)
        .frame(maxWidth: .infinity)
        .background(DropFramePalette.paper, in: .rect(cornerRadius: 18))
    }
}
