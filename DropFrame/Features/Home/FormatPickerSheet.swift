import SwiftUI

struct FormatPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let media: ResolvedMedia

    @State private var selectedFormatID: String?
    @State private var selectedFolderID: UUID?

    private var selectedFormat: MediaFormat? {
        media.formats.first { $0.id == selectedFormatID } ?? media.formats.first
    }

    private var selectedFolder: MediaFolder? {
        model.folders.first { $0.id == selectedFolderID } ?? model.folders.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    MediaPreview(media: media)

                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(index: "01", title: "Choose quality", trailing: "\(media.formats.count) FOUND")
                        ForEach(media.formats) { format in
                            FormatRow(
                                format: format,
                                isSelected: selectedFormat?.id == format.id
                            ) {
                                withAnimation(.smooth(duration: 0.22)) {
                                    selectedFormatID = format.id
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
                        guard let selectedFormat else { return }
                        guard let selectedFolder else { return }
                        Task { await model.download(format: selectedFormat, to: selectedFolder) }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Download \(selectedFormat?.resolutionText ?? "")")
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
                    .disabled(selectedFormat == nil || selectedFolder == nil)
                }
                .padding(18)
            }
            .background(DropFramePalette.canvas)
            .navigationTitle("Ready to save")
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

private struct MediaPreview: View {
    let media: ResolvedMedia

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncThumbnail(url: media.thumbnailURL)
                .frame(height: 220)

            LinearGradient(
                colors: [.clear, DropFramePalette.night.opacity(0.88)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 7) {
                EditorialLabel(text: media.sourceURL.host ?? "Web", color: .white.opacity(0.7))
                Text(media.title)
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(17)
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 18))
    }
}

private struct FormatRow: View {
    let format: MediaFormat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(format.resolutionText)
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .frame(width: 68, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(format.label)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(format.detailText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DropFramePalette.muted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(isSelected ? DropFramePalette.cobalt : DropFramePalette.hairline)
            }
            .foregroundStyle(DropFramePalette.ink)
            .padding(15)
            .background(
                isSelected ? DropFramePalette.cobalt.opacity(0.10) : DropFramePalette.paper,
                in: .rect(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? DropFramePalette.cobalt : DropFramePalette.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}
