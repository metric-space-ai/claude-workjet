import SwiftUI
import WorkjetCore

/// Root of the popover. Switches inline between main, settings and the two
/// editors with small restrained transitions only.
struct RootView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    @State private var screen: Screen = .main
    @State private var computerEditorReturn: Screen = .main

    enum Screen: Equatable {
        case main
        case settings
        case workerEditor(Worker?)
        case computerEditor(Computer?)
    }

    var body: some View {
        ZStack {
            WJTheme.background.ignoresSafeArea()
            Group {
                switch screen {
                case .main:
                    MainView(
                        onOpenSettings: { screen = .settings },
                        onAddWorker: { screen = .workerEditor(nil) },
                        onEditWorker: { screen = .workerEditor($0) },
                        onAddComputer: { openComputerEditor(nil, from: .main) }
                    )
                case .settings:
                    SettingsView(
                        onClose: { screen = .main },
                        onAddComputer: { openComputerEditor(nil, from: .settings) },
                        onEditComputer: { openComputerEditor($0, from: .settings) }
                    )
                case .workerEditor(let worker):
                    WorkerEditorView(worker: worker, onClose: { screen = .main })
                case .computerEditor(let computer):
                    ComputerEditorView(computer: computer, onClose: { screen = computerEditorReturn })
                }
            }
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.18), value: screen)
        .frame(width: WJTheme.popoverWidth, height: WJTheme.popoverHeight)
        .preferredColorScheme(.dark)
    }

    private func openComputerEditor(_ computer: Computer?, from returnTo: Screen) {
        computerEditorReturn = returnTo
        screen = .computerEditor(computer)
    }
}
