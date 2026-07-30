import SwiftUI
import UIKit

@main
struct DropFrameApp: App {
    @State private var model = AppModel()

    init() {
        PythonRuntimeBootstrap.configure()
        UITabBar.appearance().unselectedItemTintColor = UIColor(DropFramePalette.muted)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.light)
        }
    }
}
