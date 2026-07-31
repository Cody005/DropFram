import SwiftUI
import UIKit

@main
struct DropFrameApp: App {
    @State private var model = AppModel()
    @State private var appLock = AppLockController()

    init() {
        PythonRuntimeBootstrap.configure()
        UITabBar.appearance().unselectedItemTintColor = UIColor(DropFramePalette.muted)
    }

    var body: some Scene {
        WindowGroup {
            SecuredRootView()
                .environment(model)
                .environment(appLock)
                .preferredColorScheme(.light)
        }
    }
}
