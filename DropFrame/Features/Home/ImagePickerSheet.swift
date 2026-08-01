import SwiftUI

struct ImagePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let page: ResolvedImagePage

    @State private var selectedImageID: String?
    @State private var selectedFolderID: UUID?

    private var columns: [GridItem] {
        if page.images.count == 1 {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    private var selectedImage: RemoteImageCandidate? {
        page.images.first { $0.id == selectedImageID } ?? page.images.first
    }

    private var selectedFolder: MediaFolder? {
        model.folders.first { $0.id == selectedFolderID } ?? model.folders.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(
                            index: "01",
                            title: "Choose picture",
                            trailing: "\(page.images.count) FOUND"
                        )

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(page.images) { image in
                                ImageCandidateCard(
                                    image: image,
                                    isSelected: selectedImage?.id == image.id
                                ) {
                                    withAnimation(.smooth(duration: 0.2)) {
                                        selectedImageID = image.id
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(index: "02", title: "Save to")
                        Menu {
                            ForEach(model.folders) { folder in
                                Button {
                                    selectedFolderID = folder.id
                                } label: {
                                    Label(folder.name, systemImage: folder.symbol)
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedFolder?.symbol ?? "folder.fill")
                                    .foregroundStyle(DropFramePalette.cobalt)
                                Text(selectedFolder?.name ?? "Choose a folder")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            .foregroundStyle(DropFramePalette.ink)
                            .padding(.horizontal, 16)
                            .frame(height: 58)
                            .background(DropFramePalette.paper, in: .rect(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(DropFramePalette.hairline, lineWidth: 1)
                            }
                        }
                    }

                    Button {
                        guard let selectedImage, let selectedFolder else { return }
                        Task {
                            await model.download(
                                image: selectedImage,
                                from: page,
                                to: selectedFolder
                            )
                        }
                    } label: {
                        HStack {
                            Image(systemName: "photo.badge.arrow.down.fill")
                            Text("Download picture")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(DropFramePalette.paper)
                        .padding(.horizontal, 18)
                        .frame(height: 60)
                        .background(DropFramePalette.cobalt, in: .rect(cornerRadius: 15))
                    }
                    .buttonStyle(.pressable)
                    .disabled(selectedImage == nil || selectedFolder == nil)
                }
                .padding(18)
            }
            .background(DropFramePalette.canvas)
            .navigationTitle("Pictures found")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
    }
}

private struct ImageCandidateCard: View {
    let image: RemoteImageCandidate
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                AsyncImage(url: image.url) { phase in
                    switch phase {
                    case .empty:
                        previewPlaceholder
                            .overlay { ProgressView().tint(DropFramePalette.ink) }
                    case .success(let preview):
                        preview
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        previewPlaceholder
                    @unknown default:
                        previewPlaceholder
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .compositingGroup()
                .clipShape(.rect(cornerRadius: 12))

                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(image.label)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Text(image.fileExtension.uppercased())
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(DropFramePalette.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(
                            isSelected ? DropFramePalette.cobalt : DropFramePalette.hairline
                        )
                }
            }
            .foregroundStyle(DropFramePalette.ink)
            .padding(9)
            .background(
                isSelected ? DropFramePalette.cobalt.opacity(0.09) : DropFramePalette.paper,
                in: .rect(cornerRadius: 15)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .stroke(
                        isSelected ? DropFramePalette.cobalt : DropFramePalette.hairline,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.pressable)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var previewPlaceholder: some View {
        DropFramePalette.violet.opacity(0.3)
            .overlay {
                Image(systemName: "photo.fill")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(DropFramePalette.paper)
            }
    }
}
