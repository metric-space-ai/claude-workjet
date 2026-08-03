import SwiftUI
import WorkjetCore

@main
struct WorkjetMenuBarApp: App {
    @StateObject private var model = WorkjetViewModel.preview()

    var body: some Scene {
        MenuBarExtra("Workjet") {
            RootView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
