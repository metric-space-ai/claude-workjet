import SwiftUI
import WorkjetCore

/// Root of the popover. Switches inline between main, settings and the two
/// editors with small restrained transitions only.
struct RootView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    var viewportHeight: CGFloat = WJTheme.popoverHeight
    @State private var screen: Screen = .main
    @State private var computerEditorReturn: Screen = .main
    @State private var repairProvider: ModelProvider?
    @State private var repairWorker: Worker?

    enum Screen: Equatable {
        case main
        case settings
        case workerEditor(Worker?)
        case computerEditor(Computer?)
    }

    var body: some View {
        ZStack(alignment: .top) {
            WJTheme.background.ignoresSafeArea()
            Group {
                switch screen {
                case .main:
                    MainView(
                        onOpenSettings: { screen = .settings },
                        onOpenHealthRecovery: openRuntimeRecovery,
                        onAddWorker: { screen = .workerEditor(nil) },
                        onEditWorker: { screen = .workerEditor($0) },
                        onAddComputer: { openComputerEditor(nil, from: .main) },
                        onEditComputer: { openComputerEditor($0, from: .main) }
                    )
                case .settings:
                    SettingsView(
                        onClose: {
                            Task {
                                if await model.flushPersistence() { screen = .main }
                            }
                        },
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
            if let message = model.statusMessages.last {
                let visibleMessage = displayMessage(for: message)
                HStack(spacing: 8) {
                    Button { openRecovery(for: message) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(visibleMessage)
                                .font(.system(size: 10))
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(visibleMessage). Öffnet die passende Stelle zur Behebung.")
                    .accessibilityIdentifier("status-banner.open-recovery")
                    Button { model.dismissMessage(message) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Statusmeldung schließen")
                        .accessibilityIdentifier("status-banner.dismiss")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color(nsColor: .systemOrange).opacity(0.96))
                .padding(8)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: screen)
        .frame(width: WJTheme.popoverWidth, height: viewportHeight)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: .workjetOpenComputerRecovery)) { notification in
            guard let computerID = notification.object as? UUID,
                  let computer = model.computer(for: computerID) else { return }
            openComputerEditor(computer, from: .main)
        }
        .onReceive(NotificationCenter.default.publisher(for: .workjetOpenSettings)) { _ in
            screen = .settings
        }
        .sheet(item: $repairProvider, onDismiss: { repairWorker = nil }) { provider in
            ProviderSetupView(
                selectedRoute: repairWorker?.providerRoute,
                initiallyOpenProvider: provider,
                onSelect: { route in
                    if var worker = repairWorker {
                        worker.providerRoute = route
                        model.upsertWorker(worker)
                    }
                    repairProvider = nil
                },
                onClose: { repairProvider = nil }
            )
            .environmentObject(model)
        }
        .onDisappear {
            Task { await model.flushPersistence() }
        }
    }

    private func openComputerEditor(_ computer: Computer?, from returnTo: Screen) {
        computerEditorReturn = returnTo
        screen = .computerEditor(computer)
    }

    private func openRecovery(for message: String) {
        model.dismissMessage(message)
        if let computer = failedComputer(for: message) {
            openComputerEditor(computer, from: .main)
            return
        }
        guard let provider = failedProvider(for: message) else {
            screen = .settings
            return
        }
        screen = .main
        repairWorker = model.workers.first { worker in
            ModelProvider.inferred(from: worker.model) == provider
        }
        repairProvider = provider
    }

    private func openRuntimeRecovery() {
        guard let worker = model.workers.first(where: { model.recoveryAction(for: $0) != nil }),
              let recovery = model.recoveryAction(for: worker) else {
            screen = .settings
            return
        }
        switch recovery {
        case let .computer(computerID):
            if let computer = model.computer(for: computerID) {
                openComputerEditor(computer, from: .main)
            } else {
                screen = .settings
            }
        case let .provider(providerRecovery):
            let provider: ModelProvider?
            switch providerRecovery {
            case let .connect(value): provider = value
            case let .reauthenticate(_, value): provider = value
            case let .configure(value): provider = value ?? ModelProvider.inferred(from: worker.model)
            }
            guard let provider else { screen = .settings; return }
            repairWorker = worker
            repairProvider = provider
        }
    }

    private func displayMessage(for message: String) -> String {
        if failedComputer(for: message) != nil { return "Computer einrichten" }
        if let provider = failedProvider(for: message) { return "\(provider.rawValue) verbinden" }
        if message.localizedCaseInsensitiveContains("speicher") || message.localizedCaseInsensitiveContains("prompt") {
            return "Änderungen konnten nicht übernommen werden"
        }
        if message.localizedCaseInsensitiveContains("tailscale") { return "Tailscale-Verbindung prüfen" }
        if message.localizedCaseInsensitiveContains("schlüsselbund") || message.localizedCaseInsensitiveContains("zugang") {
            return "Anbieterzugang prüfen"
        }
        if message.localizedCaseInsensitiveContains("konfiguration") {
            return "Konfiguration prüfen"
        }
        return "Einstellungen prüfen"
    }

    private func failedComputer(for message: String) -> Computer? {
        model.computers.first { computer in
            guard !computer.isLocal else { return false }
            return computer.deploymentDetail == message || model.remoteHostErrors[computer.id] == message
        }
    }

    private func failedProvider(for message: String) -> ModelProvider? {
        if let namedProvider = ModelProvider.allCases.first(where: {
            message.localizedCaseInsensitiveContains($0.rawValue)
        }) {
            return namedProvider
        }
        return ModelProvider.allCases.first { provider in
            guard case let .failed(detail) = model.providerLoginStates[provider] else { return false }
            return detail == message
        }
    }
}
