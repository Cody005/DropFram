import SwiftUI

struct NewFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "play.rectangle.fill"
    @State private var tintHex = "FF5E52"
    @FocusState private var isNameFocused: Bool

    private let symbols = [
        "play.rectangle.fill",
        "film.stack.fill",
        "bookmark.fill",
        "heart.fill",
        "sparkles.tv.fill"
    ]
    private let colors = ["FF5E52", "FFD60A", "1755EC", "7BE2B8", "9A73FF"]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                TextField("Folder name", text: $name)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .focused($isNameFocused)
                    .padding(.horizontal, 16)
                    .frame(height: 58)
                    .background(DropFramePalette.paper, in: .rect(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 11) {
                    EditorialLabel(text: "Choose a mark")
                    HStack {
                        ForEach(symbols, id: \.self) { item in
                            Button {
                                symbol = item
                            } label: {
                                Image(systemName: item)
                                    .font(.system(size: 18, weight: .black))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 46)
                                    .background(
                                        symbol == item ? DropFramePalette.ink : DropFramePalette.paper,
                                        in: .rect(cornerRadius: 12)
                                    )
                                    .foregroundStyle(symbol == item ? DropFramePalette.paper : DropFramePalette.ink)
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 11) {
                    EditorialLabel(text: "Choose a color")
                    HStack {
                        ForEach(colors, id: \.self) { item in
                            Button {
                                tintHex = item
                            } label: {
                                Circle()
                                    .fill(Color(hex: item))
                                    .frame(width: 42, height: 42)
                                    .overlay {
                                        if tintHex == item {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .black))
                                        }
                                    }
                            }
                            .buttonStyle(.pressable)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                Spacer()

                Button {
                    model.createFolder(named: name, symbol: symbol, tintHex: tintHex)
                    dismiss()
                } label: {
                    Text("Create collection")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(DropFramePalette.paper)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(DropFramePalette.cobalt, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.pressable)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(18)
            .background(DropFramePalette.libraryCanvas.ignoresSafeArea())
            .navigationTitle("New collection")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { isNameFocused = true }
        }
    }
}
