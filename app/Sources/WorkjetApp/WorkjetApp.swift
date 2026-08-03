import SwiftUI
import WorkjetCore

@main
struct WorkjetMenuBarApp: App {
    @StateObject private var model: WorkjetViewModel
    init() { _model = StateObject(wrappedValue: WorkjetViewModel.live()) }
    var body: some Scene {
        MenuBarExtra("Workjet") { RootView().environmentObject(model) }.menuBarExtraStyle(.window)
    }
}
