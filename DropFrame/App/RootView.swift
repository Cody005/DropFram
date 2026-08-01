import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        tabs
            .tint(DropFramePalette.cobalt)
        .alert(
            "Couldn’t finish that",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.presentedError = nil
            }
        } message: {
            Text(model.presentedError ?? "")
        }
        .sheet(isPresented: $model.isResultPresented) {
            if let media = model.resolvedMedia {
                FormatPickerSheet(media: media)
                    .environment(model)
            }
        }
        .sheet(isPresented: $model.isImageResultPresented) {
            if let page = model.resolvedImagePage {
                ImagePickerSheet(page: page)
                    .environment(model)
            }
        }
        .fullScreenCover(item: $model.playerVideo) { video in
            PlayerScreen(video: video)
                .environment(model)
        }
        .fullScreenCover(item: $model.presentedImage) { image in
            SavedImageViewer(image: image)
                .environment(model)
        }
    }

    @ViewBuilder
    private var tabs: some View {
        @Bindable var model = model

        if #available(iOS 18, *) {
            TabView(selection: $model.selectedTab) {
                Tab("Grab", systemImage: AppTab.home.symbol, value: AppTab.home) {
                    HomeView()
                }
                Tab("Library", systemImage: AppTab.library.symbol, value: AppTab.library) {
                    LibraryView()
                }
                Tab("Downloads", systemImage: AppTab.queue.symbol, value: AppTab.queue) {
                    QueueView()
                }
                Tab("Settings", systemImage: AppTab.settings.symbol, value: AppTab.settings) {
                    SettingsView()
                }
            }
        } else {
            TabView(selection: $model.selectedTab) {
                HomeView()
                    .tag(AppTab.home)
                    .tabItem { Label("Grab", systemImage: AppTab.home.symbol) }
                LibraryView()
                    .tag(AppTab.library)
                    .tabItem { Label("Library", systemImage: AppTab.library.symbol) }
                QueueView()
                    .tag(AppTab.queue)
                    .tabItem { Label("Downloads", systemImage: AppTab.queue.symbol) }
                SettingsView()
                    .tag(AppTab.settings)
                    .tabItem { Label("Settings", systemImage: AppTab.settings.symbol) }
            }
        }
    }
}
