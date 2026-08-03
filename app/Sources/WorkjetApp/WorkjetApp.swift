import SwiftUI
import WorkjetCore

@main
struct WorkjetMenuBarApp: App {
    @StateObject private var model: WorkjetViewModel

    init() {
        let preview = ProcessInfo.processInfo.environment["WORKJET_PREVIEW"] == "1"
        _model = StateObject(wrappedValue: preview
            ? WorkjetViewModel(configuration: WorkjetDefaults.configuration())
            : WorkjetViewModel.live())
    }

    var body: some Scene {
        MenuBarExtra("Workjet") { RootView().environmentObject(model) }
            .menuBarExtraStyle(.window)
    }
}
