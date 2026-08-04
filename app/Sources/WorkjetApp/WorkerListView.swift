import SwiftUI
import WorkjetCore

struct WorkerListView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    let onEditWorker: (Worker) -> Void
    @State private var setupWorker: Worker?
    @State private var initiallyOpenProvider: ModelProvider?
    @State private var recoveringWorkerID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleWorkers) { worker in
                    WorkerRow(
                        worker: worker,
                        capacity: model.effectiveCapacity(for: worker),
                        status: model.operationalStatus(for: worker),
                        recovery: model.providerRecovery(for: worker),
                        isRecovering: recoveringWorkerID == worker.id,
                        onRecover: { recover(worker) },
                        onEdit: { onEditWorker(worker) }
                    )
                    if worker.id != model.visibleWorkers.last?.id { WJDivider().padding(.leading, 14) }
                }
                if model.visibleWorkers.isEmpty {
                    Text(emptyMessage).font(.system(size: 12)).foregroundStyle(WJTheme.secondaryText)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
        }
        .sheet(item: $setupWorker) { worker in
            ProviderSetupView(
                selectedRoute: worker.providerRoute,
                initiallyOpenProvider: initiallyOpenProvider,
                onSelect: { route in
                    var updated = worker
                    updated.providerRoute = route
                    model.upsertWorker(updated)
                    setupWorker = nil
                },
                onClose: { setupWorker = nil }
            )
            .environmentObject(model)
        }
    }

    private func recover(_ worker: Worker) {
        guard let recovery = model.providerRecovery(for: worker) else { return }
        switch recovery {
        case let .connect(provider):
            recoveringWorkerID = worker.id
            Task {
                let name = "\(provider.rawValue) \(model.providerAccounts(for: provider).count + 1)"
                if let account = await model.connectNewAccount(provider, name: name, apiKey: "") {
                    var updated = worker
                    updated.providerRoute = .account(account.id)
                    model.upsertWorker(updated)
                }
                recoveringWorkerID = nil
            }
        case let .reauthenticate(accountID, _):
            recoveringWorkerID = worker.id
            Task {
                await model.reauthenticateProvider(id: accountID)
                recoveringWorkerID = nil
            }
        case let .configure(provider):
            initiallyOpenProvider = provider
            setupWorker = worker
        }
    }

    private var emptyMessage: String {
        let computer = model.computer(for: model.selectedComputerID)?.name ?? "diesem Computer"
        return model.searchQuery.isEmpty ? "Keine Worker auf \(computer)" : "Keine passenden Worker"
    }
}

struct WorkerRow: View {
    let worker: Worker
    let capacity: CapacityStatus
    let status: WorkerOperationalStatus
    let recovery: WorkerProviderRecovery?
    let isRecovering: Bool
    let onRecover: () -> Void
    let onEdit: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(worker.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(worker.model) · \(worker.harness.rawValue)").font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).lineLimit(1)
                    WorkerStatusLabel(status: status)
                    CapacityIndicator(capacity: capacity, label: worker.name)
                }
            }
            Spacer(minLength: 8)
            if let recovery {
                Button(action: onRecover) {
                    if isRecovering {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(recoveryLabel(recovery))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(isRecovering)
                .accessibilityIdentifier("worker.recover.\(worker.id.uuidString)")
            }
            Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(WJIconButtonStyle())
                .accessibilityLabel("\(worker.name) bearbeiten").help("Worker bearbeiten")
                .accessibilityIdentifier("worker.edit.\(worker.id.uuidString)")
        }
        .padding(.horizontal, 14).frame(height: 60).accessibilityElement(children: .contain)
        .accessibilityIdentifier("worker.row.\(worker.id.uuidString)")
    }

    private func recoveryLabel(_ recovery: WorkerProviderRecovery) -> String {
        switch recovery {
        case .connect: "Anmelden"
        case .reauthenticate: "Neu anmelden"
        case let .configure(provider): provider?.usesWebLogin == false ? "API-Key" : "Anbieter wählen"
        }
    }
}

private struct WorkerStatusLabel: View {
    let status: WorkerOperationalStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(status.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(color)
        }
        .fixedSize()
        .help(status.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workerstatus: \(status.label). \(status.detail)")
    }

    private var color: Color {
        switch status.state {
        case .active: WJTheme.accent
        case .ready: WJTheme.quotaOK
        case .unverified: WJTheme.secondaryText
        case .degraded: WJTheme.quotaWarning
        case .unavailable: WJTheme.quotaCritical
        }
    }
}

struct CapacityIndicator: View {
    let capacity: CapacityStatus
    var label = ""
    private var color: Color {
        switch capacity.level {
        case .ok: WJTheme.quotaOK
        case .warning: WJTheme.quotaWarning
        case .critical: WJTheme.quotaCritical
        case .unavailable: WJTheme.secondaryText
        }
    }
    private var detail: String {
        guard let fraction = capacity.fraction else { return capacity.reason ?? "Kapazität nicht verfügbar" }
        return "\(Int((fraction * 100).rounded())) Prozent belegt" + (capacity.rateLimited == true ? ", Rate-Limit aktiv" : "")
    }
    var body: some View {
        HStack(spacing: 3) {
            compactSignal(prefix: "Q", value: quotaValue, color: color)
            compactSignal(prefix: "R", value: rateValue, color: rateColor)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Kapazität \(label): \(detail)").help(detail)
    }

    private var quotaValue: String {
        guard let fraction = capacity.fraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private var rateValue: String {
        guard let limited = capacity.rateLimited else { return "—" }
        return limited ? "Limit" : "frei"
    }

    private var rateColor: Color {
        guard let limited = capacity.rateLimited else { return WJTheme.secondaryText }
        return limited ? WJTheme.quotaCritical : WJTheme.quotaOK
    }

    private func compactSignal(prefix: String, value: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(prefix).font(.system(size: 7, weight: .bold))
            Text(value).font(.system(size: 8, design: .monospaced))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}
