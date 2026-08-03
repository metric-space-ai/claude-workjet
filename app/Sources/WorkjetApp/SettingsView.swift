import SwiftUI
import WorkjetCore

struct SettingsView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    let onClose: () -> Void
    let onAddComputer: () -> Void
    let onEditComputer: (Computer) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Einstellungen").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(WJIconButtonStyle()).accessibilityLabel("Einstellungen schließen")
            }.padding(.horizontal, 14).padding(.vertical, 10)
            WJDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SkillSettingsSection(); WJDivider().padding(.vertical, 14)
                    AccessSettingsSection(); WJDivider().padding(.vertical, 14)
                    ComputersSettingsSection(onAdd: onAddComputer, onEdit: onEditComputer); WJDivider().padding(.vertical, 14)
                    TelemetrySettingsSection(); WJDivider().padding(.vertical, 14)
                    ExecutionSettingsSection()
                }.padding(14)
            }
        }
    }
}

private struct SkillSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WJSectionHeader(title: "Systemprompt")
            Text("Allgemeine Fable-/Orchestrator-Regeln")
                .font(.system(size: 12, weight: .medium))
            Text("Nur allgemeine Regeln bearbeiten; Worker-Rollen werden direkt aus den Workern erzeugt.")
                .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            TextEditor(text: $model.skillRules).font(.system(size: 12)).scrollContentBackground(.hidden).padding(6).frame(minHeight: 96)
                .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
            Text("Automatisch aus Workern · nicht editierbar")
                .font(.system(size: 12, weight: .medium))
            ScrollView {
                Text(model.promptPreview).font(.system(size: 10, design: .monospaced)).foregroundStyle(WJTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8).textSelection(.enabled)
            }
            .frame(height: 180).background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
            Text("Wird ausschließlich über /workjet geladen. Claude Code/Fable bleibt der einzige Orchestrator.")
                .font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText)
        }
    }
}

private struct AccessSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    @State private var editingProviderID: UUID?
    @State private var providerSecret = ""
    @State private var testingProviderID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WJSectionHeader(title: "Modelle & Zugang")
                Spacer()
                Button {
                    let provider = Provider(name: "Neuer Anbieter", kind: .directAPI, endpoint: "")
                    model.addProvider(provider)
                    editingProviderID = provider.id
                } label: { Image(systemName: "plus") }
                .buttonStyle(WJIconButtonStyle()).accessibilityLabel("Anbieter hinzufügen")
            }
            Text("Direkte APIs und lokale kompatible Gateways werden als echte Anbieter gespeichert und können von Workern gewählt werden.")
                .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            ForEach(model.providers) { provider in providerRow(provider) }
        }
        .onAppear { model.refreshProviderCredentialStatus() }
    }

    private func providerRow(_ provider: Provider) -> some View {
        let presentation = model.providerPresentation(for: provider)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                editingProviderID = editingProviderID == provider.id ? nil : provider.id
                providerSecret = ""
            } label: {
                HStack(spacing: 8) {
                    StatusDot(tone: presentation.tone)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                        Text("\(provider.kind.rawValue) · \(presentation.state) · \(provider.endpoint)")
                            .font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "pencil").font(.system(size: 11))
                }
            }.buttonStyle(.plain).help(presentation.detail)
            if editingProviderID == provider.id { providerEditor(provider) }
        }
    }

    private func providerEditor(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ProviderKind.allCases, id: \.self) { kind in
                        WJChoiceButton(title: kind.rawValue, isSelected: provider.kind == kind) { update(provider) { $0.kind = kind; $0.status = .unverified; $0.statusDetail = "Noch nicht geprüft." } }
                    }
                }
            }
            field("Name", text: providerBinding(provider, \.name))
            field(provider.kind.isLocalGateway ? "Loopback-Endpunkt" : "HTTPS-Endpunkt", text: providerBinding(provider, \.endpoint))
            HStack {
                SecureField("Zugang (optional)", text: $providerSecret).textFieldStyle(.plain)
                Text(model.providerAccessStored.contains(provider.id) ? "Zugang gespeichert" : "Kein Zugang gespeichert")
                    .font(.system(size: 9)).foregroundStyle(WJTheme.secondaryText)
            }.fieldSurface()
            Text("Modelle (eine ID je Zeile)").font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            TextEditor(text: providerModels(provider)).font(.system(size: 11, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(6).frame(minHeight: 55).background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
            HStack {
                Button("Verbindung prüfen") {
                    testingProviderID = provider.id
                    let secret = providerSecret
                    Task {
                        await model.testProvider(id: provider.id, secret: secret)
                        providerSecret = ""
                        testingProviderID = nil
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.mini)
                .disabled(testingProviderID != nil || provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if testingProviderID == provider.id { ProgressView().controlSize(.mini) }
                Text(provider.statusDetail).font(.system(size: 10)).foregroundStyle(provider.status == .offline ? WJTheme.quotaCritical : WJTheme.secondaryText)
            }
            if provider.kind.isLocalGateway {
                Text("OAuth/Abonnement wird im lokalen Gateway verwaltet; Workjet prüft dessen kompatible /v1/models-Route.")
                    .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            }
            DisclosureGroup("Technische Details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.kind.isLocalGateway ? "Nur allowlist-konforme Loopback-Endpunkte sind zulässig." : "HTTPS ist erforderlich; Loopback-HTTP ist nur für lokale Entwicklung zulässig. Weiterleitungen und URL-Zugangsdaten werden abgelehnt.")
                        .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
                    field("Login-Executable (Legacy)", text: optionalProviderString(provider, \.loginExecutable))
                    field("Login-Argumente (Legacy)", text: providerArguments(provider))
                    Text("Legacy-Loginbefehle werden niemals automatisch ausgeführt.")
                        .font(.system(size: 9)).foregroundStyle(WJTheme.tertiaryText)
                }.padding(.top, 5)
            }.font(.system(size: 11))
            HStack {
                Spacer()
                Button("Anbieter löschen", role: .destructive) { model.removeProvider(id: provider.id); editingProviderID = nil }
                    .buttonStyle(.bordered).controlSize(.mini)
            }
        }.padding(10).background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface.opacity(0.55)))
    }

    private func update(_ provider: Provider, mutation: (inout Provider) -> Void) { var copy = provider; mutation(&copy); model.updateProvider(copy) }
    private func providerBinding(_ provider: Provider, _ keyPath: WritableKeyPath<Provider, String>) -> Binding<String> {
        Binding(get: { model.providers.first(where: { $0.id == provider.id })?[keyPath: keyPath] ?? provider[keyPath: keyPath] }, set: { value in updateCurrent(provider.id) { $0[keyPath: keyPath] = value } })
    }
    private func optionalProviderString(_ provider: Provider, _ keyPath: WritableKeyPath<Provider, String?>) -> Binding<String> {
        Binding(get: { model.providers.first(where: { $0.id == provider.id })?[keyPath: keyPath] ?? provider[keyPath: keyPath] ?? "" }, set: { value in updateCurrent(provider.id) { $0[keyPath: keyPath] = value.isEmpty ? nil : value } })
    }
    private func providerArguments(_ provider: Provider) -> Binding<String> {
        Binding(get: { (model.providers.first(where: { $0.id == provider.id })?.loginArguments ?? provider.loginArguments).joined(separator: "\n") }, set: { value in updateCurrent(provider.id) { $0.loginArguments = value.split(whereSeparator: \.isNewline).map(String.init) } })
    }
    private func providerModels(_ provider: Provider) -> Binding<String> {
        Binding(get: { (model.providers.first(where: { $0.id == provider.id })?.modelIDs ?? provider.modelIDs).joined(separator: "\n") }, set: { value in updateCurrent(provider.id) { $0.modelIDs = Provider.normalizedModels(value.split(whereSeparator: \.isNewline).map(String.init)) } })
    }
    private func updateCurrent(_ id: UUID, mutation: (inout Provider) -> Void) {
        guard var provider = model.providers.first(where: { $0.id == id }) else { return }
        mutation(&provider); model.updateProvider(provider)
    }
    private func field(_ placeholder: String, text: Binding<String>) -> some View { TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 11)).fieldSurface() }
}

private struct StatusDot: View {
    let tone: ProviderPresentationTone
    var body: some View {
        let color: Color
        switch tone {
        case .neutral: color = WJTheme.secondaryText
        case .connected: color = WJTheme.quotaOK
        case .warning: color = WJTheme.quotaWarning
        case .critical: color = WJTheme.quotaCritical
        }
        return Circle().fill(color).frame(width: 7, height: 7)
    }
}

private func capacityDetail(_ capacity: CapacityStatus) -> String {
    guard let fraction = capacity.fraction else { return "Kapazität nicht verfügbar: \(capacity.reason ?? "unbekannter Grund")" }
    let source = { if case .measured = capacity { return "remote gemessen" }; return "lokal konfiguriertes Limit" }()
    return "Kapazität \(Int((fraction * 100).rounded()))% (\(source))" + (capacity.rateLimited == true ? " · Rate-Limit" : "")
}

private struct ComputersSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    let onAdd: () -> Void; let onEdit: (Computer) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { WJSectionHeader(title: "Computer"); Spacer(); Button(action: onAdd) { Image(systemName: "plus") }.buttonStyle(WJIconButtonStyle()) }
            ForEach(model.computers) { computer in
                HStack { VStack(alignment: .leading, spacing: 2) { Text(computer.name).font(.system(size: 12, weight: .semibold)); Text(detail(computer)).font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).lineLimit(1) }; Spacer(); if !computer.isLocal { Button { onEdit(computer) } label: { Image(systemName: "pencil") }.buttonStyle(WJIconButtonStyle()) } }
            }
        }
    }
    private func detail(_ computer: Computer) -> String { computer.isLocal ? "Immer vorhanden" : "\(computer.transport.rawValue) · \(computer.host) · Pi Code: \(computer.deploymentStatus.rawValue) · Details post-hoc" }
}

private struct TelemetrySettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WJSectionHeader(title: "Telemetrie")
            Toggle("Claude-Code-Aktivitätsdetails anzeigen", isOn: $model.telemetryClaudeCodeEvents).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text("Aus: laufende Claude-Code-Worker bleiben automatisch sichtbar; Aktivität wird als „läuft“ angezeigt und Event-Zustellung als nicht verfügbar markiert.")
                .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            Toggle("Pi-Code-Aktivitätsdetails anzeigen", isOn: $model.telemetrySidecarEvents).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text("Aus: laufende Pi-Worker bleiben automatisch sichtbar; Aktivität wird als „läuft“ angezeigt und post-hoc Event-Zustellung als nicht verfügbar markiert. Für Remote-Pi muss zusätzlich die Telemetrie am Computer aktiviert sein.")
                .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            Text("Diese Schalter ändern nur Aktivitätsdetails und Zustellungsanzeige. Dispatcher-Journale werden weder gelöscht noch gekürzt.")
                .font(.system(size: 10)).foregroundStyle(WJTheme.tertiaryText)
        }
    }
}

private struct ExecutionSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WJSectionHeader(title: "Ausführung (Infrastruktur-Defaults)")
            Stepper(value: $model.providerSlots, in: 1...3) { Text("Provider-Slots: \(model.providerSlots)").font(.system(size: 12)) }
            Stepper(value: $model.probeTimeoutSeconds, in: 5...600, step: 5) { Text("Probe-Timeout: \(model.probeTimeoutSeconds) s").font(.system(size: 12)) }
            Stepper(value: $model.turnTimeoutSeconds, in: 60...10800, step: 60) { Text("Turn-Timeout: \(model.turnTimeoutSeconds) s").font(.system(size: 12)) }
            Toggle("Explizite Degradation erlauben", isOn: $model.degradationAllowed).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text("Fable steuert Zerlegung, Worker-Auswahl und Workflow. Die App fällt nie stillschweigend zurück.").font(.system(size: 11)).foregroundStyle(WJTheme.tertiaryText)
        }
    }
}

private extension View {
    func fieldSurface() -> some View { self.padding(.horizontal, 9).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface)) }
}
