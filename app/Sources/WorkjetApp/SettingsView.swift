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
            WJSectionHeader(title: "Workjet Skill")
            Text("Orchestrator-Regeln (handschriftlicher Inhalt außerhalb des verwalteten Blocks)").font(.system(size: 12)).foregroundStyle(WJTheme.secondaryText)
            TextEditor(text: $model.skillRules).font(.system(size: 12)).scrollContentBackground(.hidden).padding(6).frame(minHeight: 96)
                .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
            Toggle("Worker-Deklarationen automatisch verwalten", isOn: $model.injectWorkerDeclarations).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text("Wird ausschließlich über /workjet geladen. Fable/Claude Code bleibt der einzige Orchestrator und invokiert genau einen ausgewählten Worker.").font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText)
            Text("Generierter verwalteter Block").font(.system(size: 12)).foregroundStyle(WJTheme.secondaryText)
            ScrollView { Text(model.promptPreview).font(.system(size: 10, design: .monospaced)).foregroundStyle(WJTheme.secondaryText).frame(maxWidth: .infinity, alignment: .leading).padding(8).textSelection(.enabled) }
                .frame(height: 150).background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
        }
    }
}

private struct AccessSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    @State private var editingProviderID: UUID?
    @State private var inferenceSecret = ""
    @State private var managementSecret = ""
    @State private var providerSecret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WJSectionHeader(title: "Modelle & Zugang")
                Spacer()
                Button { let provider = Provider(name: "Neuer Anbieter", kind: .apiKey, endpoint: ""); model.addProvider(provider); editingProviderID = provider.id } label: { Image(systemName: "plus") }
                    .buttonStyle(WJIconButtonStyle()).accessibilityLabel("Anbieter hinzufügen")
            }
            cliProxyEditor
            ForEach(model.providers) { provider in providerRow(provider) }
        }
    }

    private var cliProxyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(cliColor).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CLIProxyAPI · \(model.cliProxyStatus.state.rawValue)").font(.system(size: 12, weight: .semibold))
                    Text(model.cliProxyStatus.detail).font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
                }
                Spacer()
                Button { model.refreshCLIProxy() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(WJIconButtonStyle()).accessibilityLabel("CLIProxy erneut prüfen")
            }
            field("Loopback-Endpunkt", text: $model.cliProxyConfiguration.endpoint)
            field("Inferenz-Keychain-Referenz", text: optionalCLIReference(\.inferenceCredentialReference))
            HStack { SecureField("Inferenz-Geheimnis im Keychain speichern", text: $inferenceSecret).textFieldStyle(.plain); saveSecret(inferenceSecret, reference: model.cliProxyConfiguration.inferenceCredentialReference) { inferenceSecret = "" } }
                .fieldSurface()
            field("Management-Keychain-Referenz (getrennt)", text: optionalCLIReference(\.managementCredentialReference))
            HStack { SecureField("Management-Geheimnis im Keychain speichern", text: $managementSecret).textFieldStyle(.plain); saveSecret(managementSecret, reference: model.cliProxyConfiguration.managementCredentialReference) { managementSecret = "" } }
                .fieldSurface()
            Toggle("Lokale Nutzungsstatistik abfragen", isOn: $model.cliProxyConfiguration.usageStatisticsEnabled).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text(capacityDetail(model.cliProxyStatus.capacity)).font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
        }.padding(10).background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface.opacity(0.55)))
    }

    private func providerRow(_ provider: Provider) -> some View {
        let presentation = model.providerPresentation(for: provider)
        return VStack(alignment: .leading, spacing: 7) {
            Button { editingProviderID = editingProviderID == provider.id ? nil : provider.id } label: {
                HStack(spacing: 8) {
                    StatusDot(tone: presentation.tone)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                        Text("\(provider.kind.rawValue) · \(presentation.state) · \(provider.endpoint)").font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).lineLimit(1)
                    }
                    Spacer(); Text(capacityDetail(presentation.capacity)).font(.system(size: 9)).foregroundStyle(WJTheme.secondaryText).lineLimit(2); Image(systemName: "pencil").font(.system(size: 11))
                }
            }.buttonStyle(.plain).help(presentation.detail)
            if editingProviderID == provider.id { providerEditor(provider) }
        }
    }

    private func providerEditor(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) { ForEach(ProviderKind.allCases, id: \.self) { kind in WJChoiceButton(title: kind.rawValue, isSelected: provider.kind == kind) { update(provider) { $0.kind = kind } } } }
            field("Name", text: providerBinding(provider, \.name))
            field("Endpunkt", text: providerBinding(provider, \.endpoint))
            field("Keychain-Referenz", text: optionalProviderReference(provider))
            HStack {
                SecureField("API-Geheimnis im Keychain speichern", text: $providerSecret).textFieldStyle(.plain)
                saveSecret(providerSecret, reference: provider.credentialReference) { providerSecret = "" }
            }.fieldSurface()
            field("Login-Executable", text: optionalProviderString(provider, \.loginExecutable))
            field("Login-Argumente, eine Zeile je Argument", text: providerArguments(provider))
            HStack {
                Text("Login wird niemals automatisch oder headless ausgeführt.").font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
                Spacer()
                Button("Anbieter löschen", role: .destructive) { model.removeProvider(id: provider.id); editingProviderID = nil }
                    .buttonStyle(.bordered).controlSize(.mini)
            }
        }.padding(10).background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface.opacity(0.55)))
    }

    private func update(_ provider: Provider, mutation: (inout Provider) -> Void) { var copy = provider; mutation(&copy); model.updateProvider(copy) }
    private func providerBinding(_ provider: Provider, _ keyPath: WritableKeyPath<Provider, String>) -> Binding<String> { Binding(get: { provider[keyPath: keyPath] }, set: { value in update(provider) { $0[keyPath: keyPath] = value } }) }
    private func optionalProviderReference(_ provider: Provider) -> Binding<String> { Binding(get: { provider.credentialReference ?? "" }, set: { value in update(provider) { $0.credentialReference = value.isEmpty ? nil : value } }) }
    private func optionalProviderString(_ provider: Provider, _ keyPath: WritableKeyPath<Provider, String?>) -> Binding<String> { Binding(get: { provider[keyPath: keyPath] ?? "" }, set: { value in update(provider) { $0[keyPath: keyPath] = value.isEmpty ? nil : value } }) }
    private func providerArguments(_ provider: Provider) -> Binding<String> { Binding(get: { provider.loginArguments.joined(separator: "\n") }, set: { value in update(provider) { $0.loginArguments = value.split(whereSeparator: \.isNewline).map(String.init) } }) }
    private func optionalCLIReference(_ keyPath: WritableKeyPath<CLIProxyConfiguration, String?>) -> Binding<String> { Binding(get: { model.cliProxyConfiguration[keyPath: keyPath] ?? "" }, set: { value in var copy = model.cliProxyConfiguration; copy[keyPath: keyPath] = value.isEmpty ? nil : value; model.cliProxyConfiguration = copy }) }
    private func saveSecret(_ secret: String, reference: String?, clear: @escaping () -> Void) -> some View { Button("Sichern") { if let reference, !reference.isEmpty { model.storeCredential(secret, reference: reference); clear() } }.buttonStyle(.bordered).controlSize(.mini).disabled(secret.isEmpty || reference?.isEmpty != false) }
    private func field(_ placeholder: String, text: Binding<String>) -> some View { TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 11)).fieldSurface() }
    private var cliColor: Color { switch model.cliProxyStatus.state { case .unverified: WJTheme.secondaryText; case .reachable: WJTheme.quotaOK; case .usageDisabled, .managementUnavailable, .authRequired: WJTheme.quotaWarning; case .unsafeEndpoint, .offline: WJTheme.quotaCritical } }
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
    private func detail(_ computer: Computer) -> String { computer.isLocal ? "Immer vorhanden" : "\(computer.transport.rawValue) · \(computer.host) · Pi: \(computer.deploymentStatus.rawValue) · Events post-hoc" }
}

private struct TelemetrySettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WJSectionHeader(title: "Telemetrie")
            Toggle("Claude-Code-Aktivitätsdetails anzeigen", isOn: $model.telemetryClaudeCodeEvents).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text("Aus: laufende Claude-Code-Worker bleiben automatisch sichtbar; Aktivität wird als „läuft“ angezeigt und Event-Zustellung als nicht verfügbar markiert.")
                .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            Toggle("Pi-Aktivitätsdetails anzeigen", isOn: $model.telemetrySidecarEvents).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
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
