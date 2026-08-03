import SwiftUI
import WorkjetCore

/// Complete inline settings view inside the same popover. Linear, cardless:
/// section headers plus thin dividers.
struct SettingsView: View {
    @EnvironmentObject private var model: WorkjetViewModel

    let onClose: () -> Void
    let onAddComputer: () -> Void
    let onEditComputer: (Computer) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Einstellungen")
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(WJIconButtonStyle())
                .accessibilityLabel("Einstellungen schließen")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            WJDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SkillSettingsSection()
                    WJDivider().padding(.vertical, 14)
                    AccessSettingsSection()
                    WJDivider().padding(.vertical, 14)
                    ComputersSettingsSection(onAdd: onAddComputer, onEdit: onEditComputer)
                    WJDivider().padding(.vertical, 14)
                    TelemetrySettingsSection()
                    WJDivider().padding(.vertical, 14)
                    ExecutionSettingsSection()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }
}

// MARK: - 1. Workjet Skill

private struct SkillSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WJSectionHeader(title: "Workjet Skill")

            Text("Orchestrator-Regeln")
                .font(.system(size: 12))
                .foregroundStyle(WJTheme.secondaryText)
            TextEditor(text: $model.skillRules)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 96)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                .accessibilityLabel("Orchestrator-Regeln bearbeiten")

            Text("Aktivierung")
                .font(.system(size: 12))
                .foregroundStyle(WJTheme.secondaryText)
            HStack(spacing: 8) {
                ForEach(SkillActivation.allCases, id: \.self) { activation in
                    WJChoiceButton(
                        title: activation.rawValue,
                        isSelected: model.skillActivation == activation,
                        accessibilityLabel: "Aktivierung \(activation.rawValue)",
                        help: activation == .skillOnly
                            ? "Der Skill lädt nur über /workjet."
                            : "Der Skill ist global in jeder Session aktiv."
                    ) {
                        model.skillActivation = activation
                    }
                }
            }

            Toggle(isOn: $model.injectWorkerDeclarations) {
                Text("Worker-Deklarationen automatisch anhängen")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Worker-Deklarationen automatisch anhängen")

            Text("Fable erhält Skill + Worker-Deklarationen und übernimmt Zerlegung, Routing und Ausführung.")
                .font(.system(size: 11))
                .foregroundStyle(WJTheme.secondaryText)

            Text("Generierter Prompt")
                .font(.system(size: 12))
                .foregroundStyle(WJTheme.secondaryText)
            ScrollView {
                Text(model.promptPreview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(WJTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
            .accessibilityLabel("Vorschau des generierten Skill-Prompts")
        }
    }
}

// MARK: - 2. Models & Access

private struct AccessSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    @State private var editingProviderID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WJSectionHeader(title: "Modelle & Zugang")
                Spacer()
                Button {
                    let provider = Provider(
                        name: "Neuer Anbieter",
                        kind: .apiKey,
                        endpoint: "",
                        status: .offline
                    )
                    model.addProvider(provider)
                    editingProviderID = provider.id
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(WJIconButtonStyle())
                .accessibilityLabel("Anbieter hinzufügen")
                .help("OAuth-/Abo- oder API-Anbieter hinzufügen")
            }

            // CLIProxy status row
            HStack(spacing: 8) {
                StatusDot(status: model.cliProxy.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CLIProxyAPI")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(model.cliProxy.endpoint) · \(model.cliProxy.account)")
                        .font(.system(size: 11))
                        .foregroundStyle(WJTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Text(model.cliProxy.status.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(WJTheme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("CLIProxyAPI, \(model.cliProxy.status.rawValue), Endpunkt \(model.cliProxy.endpoint)")

            ForEach(model.providers.indices, id: \.self) { index in
                providerRow(index: index)
            }
        }
    }

    private func providerRow(index: Int) -> some View {
        let provider = model.providers[index]
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                editingProviderID = editingProviderID == provider.id ? nil : provider.id
            } label: {
                HStack(spacing: 8) {
                    StatusDot(status: provider.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("\(provider.kind.rawValue) · \(provider.endpoint)")
                            .font(.system(size: 11))
                            .foregroundStyle(WJTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(quotaDetail(provider.quota))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(WJTheme.secondaryText)
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(WJTheme.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(provider.name) bearbeiten, \(provider.status.rawValue), Quota \(quotaDetail(provider.quota))")

            if editingProviderID == provider.id {
                providerEditor(index: index)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: editingProviderID)
    }

    private func providerEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    WJChoiceButton(
                        title: kind.rawValue,
                        isSelected: model.providers[index].kind == kind,
                        accessibilityLabel: "Anbieter-Typ \(kind.rawValue)"
                    ) {
                        model.providers[index].kind = kind
                        model.updateProvider(model.providers[index])
                    }
                }
            }
            TextField("Name", text: providerBinding(index, \.name))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                .accessibilityLabel("Name des Anbieters")
            TextField("Endpunkt", text: providerBinding(index, \.endpoint))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                .accessibilityLabel("Endpunkt des Anbieters")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface.opacity(0.6)))
    }

    private func providerBinding(_ index: Int, _ keyPath: WritableKeyPath<Provider, String>) -> Binding<String> {
        Binding(
            get: { model.providers[index][keyPath: keyPath] },
            set: { newValue in
                model.providers[index][keyPath: keyPath] = newValue
                model.updateProvider(model.providers[index])
            }
        )
    }

    private func quotaDetail(_ quota: QuotaStatus) -> String {
        let percent = Int((quota.usedPercent * 100).rounded())
        return "Quota \(percent)% · \(quota.rateLimited ? "Rate-Limit" : "Rate ok")"
    }
}

private struct StatusDot: View {
    let status: ProviderStatus

    private var color: Color {
        switch status {
        case .connected: return WJTheme.quotaOK
        case .degraded: return WJTheme.quotaWarning
        case .offline: return WJTheme.quotaCritical
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

// MARK: - 3. Computers

private struct ComputersSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    let onAdd: () -> Void
    let onEdit: (Computer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WJSectionHeader(title: "Computer")
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(WJIconButtonStyle())
                .accessibilityLabel("Computer hinzufügen")
                .help("Tailscale- oder SSH-Host hinzufügen")
            }

            ForEach(model.computers) { computer in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(computer.name)
                            .font(.system(size: 12, weight: .semibold))
                        Text(detail(for: computer))
                            .font(.system(size: 11))
                            .foregroundStyle(WJTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !computer.isLocal {
                        Button {
                            onEdit(computer)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(WJIconButtonStyle())
                        .accessibilityLabel("\(computer.name) bearbeiten")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func detail(for computer: Computer) -> String {
        if computer.isLocal {
            return "Immer verfügbar"
        }
        let sandbox = computer.sandboxEnabled ? "Sandbox an" : "Sandbox aus"
        let sidecar = computer.pinnedSidecarVersion.isEmpty
            ? "kein Sidecar"
            : "Sidecar \(computer.pinnedSidecarVersion)"
        return "\(computer.transport.rawValue) · \(computer.host) · \(sandbox) · \(sidecar)"
    }
}

// MARK: - 4. Telemetry

private struct TelemetrySettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WJSectionHeader(title: "Telemetrie")

            Toggle(isOn: $model.telemetryClaudeCodeEvents) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude-Code-Events")
                        .font(.system(size: 12))
                    Text("stream-json- und Hook-Events der Claude-Code-Worker.")
                        .font(.system(size: 11))
                        .foregroundStyle(WJTheme.secondaryText)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Claude-Code-Telemetrie aktivieren")

            Toggle(isOn: $model.telemetrySidecarEvents) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pi-Sidecar-Events")
                        .font(.system(size: 12))
                    Text("Socket-Events der Pi-Sidecar-Worker.")
                        .font(.system(size: 11))
                        .foregroundStyle(WJTheme.secondaryText)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Pi-Sidecar-Telemetrie aktivieren")

            Stepper(value: $model.telemetryRetentionDays, in: 1...90) {
                Text("Verlauf: \(model.telemetryRetentionDays) Tage")
                    .font(.system(size: 12))
            }
            .accessibilityLabel("Aufbewahrung des Telemetrie-Verlaufs in Tagen")
        }
    }
}

// MARK: - 5. Execution infrastructure defaults

private struct ExecutionSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WJSectionHeader(title: "Ausführung (Infrastruktur-Defaults)")

            Stepper(value: $model.providerSlots, in: 1...8) {
                Text("Provider-Slots: \(model.providerSlots)")
                    .font(.system(size: 12))
            }
            .accessibilityLabel("Anzahl paralleler Provider-Slots")

            Stepper(value: $model.probeTimeoutSeconds, in: 5...120, step: 5) {
                Text("Probe-Timeout: \(model.probeTimeoutSeconds) s")
                    .font(.system(size: 12))
            }
            .accessibilityLabel("Probe-Timeout in Sekunden")

            Stepper(value: $model.turnTimeoutSeconds, in: 60...3600, step: 60) {
                Text("Turn-Timeout: \(model.turnTimeoutSeconds) s")
                    .font(.system(size: 12))
            }
            .accessibilityLabel("Turn-Timeout in Sekunden")

            Toggle(isOn: $model.degradationAllowed) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explizite Degradation erlauben")
                        .font(.system(size: 12))
                    Text("Bei Quota-/Auth-Wänden darf nur mit ausdrücklicher Freigabe auf ein schwächeres Modell gewechselt werden — nie stillschweigend.")
                        .font(.system(size: 11))
                        .foregroundStyle(WJTheme.secondaryText)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Explizite Degradation erlauben")

            Text("Nur Infrastruktur-Defaults — Zerlegung, Routing und Workflow-Steuerung liegen bei Fable, nicht in dieser App.")
                .font(.system(size: 11))
                .foregroundStyle(WJTheme.tertiaryText)
        }
    }
}
