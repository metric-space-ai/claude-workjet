import SwiftUI
import WorkjetCore

struct SettingsView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    let onClose: () -> Void
    let onAddComputer: () -> Void
    let onEditComputer: (Computer) -> Void
    @State private var selectedSection: SettingsSection = .prompt

    private enum SettingsSection: String, CaseIterable {
        case prompt = "Prompt"
        case providers = "Anbieter"
        case computers = "Computer"
        case telemetry = "Telemetrie"
        case execution = "Ausführung"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Einstellungen").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(WJIconButtonStyle()).accessibilityLabel("Einstellungen schließen")
            }.padding(.horizontal, 14).padding(.vertical, 10)
            WJDivider()
            ScrollViewReader { proxy in
                settingsNavigation { section in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(section, anchor: .top)
                    }
                    selectedSection = section
                }
                WJDivider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SkillSettingsSection()
                            .id(SettingsSection.prompt)
                        WJDivider().padding(.vertical, 14)
                        AccessSettingsSection()
                            .id(SettingsSection.providers)
                        WJDivider().padding(.vertical, 14)
                        ComputersSettingsSection(onAdd: onAddComputer, onEdit: onEditComputer)
                            .id(SettingsSection.computers)
                        WJDivider().padding(.vertical, 14)
                        TelemetrySettingsSection()
                            .id(SettingsSection.telemetry)
                        WJDivider().padding(.vertical, 14)
                        ExecutionSettingsSection()
                            .id(SettingsSection.execution)
                    }
                    .padding(14)
                }
                .accessibilityIdentifier("settings.sections")
            }
        }
    }

    private func settingsNavigation(onSelect: @escaping (SettingsSection) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(SettingsSection.allCases, id: \.self) { section in
                Button(section.rawValue) {
                    onSelect(section)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: selectedSection == section ? .semibold : .regular))
                .foregroundStyle(selectedSection == section ? .white : WJTheme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(selectedSection == section ? WJTheme.accent.opacity(0.82) : .clear))
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                .accessibilityIdentifier("settings.jump.\(section.rawValue.lowercased())")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

private struct SkillSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    @State private var technicalRulesExpanded = false
    @State private var editingModel: String?
    @State private var editingWorkerID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WJSectionHeader(title: "Systemprompt")
                .accessibilityIdentifier("settings.section.prompt")
            HStack {
                Text("Allgemeine Regeln").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("EDITIERBAR").font(.system(size: 9, weight: .semibold)).foregroundStyle(WJTheme.secondaryText)
            }
            TextEditor(text: $model.skillRules).font(.system(size: 12)).scrollContentBackground(.hidden).padding(6).frame(height: 180)
                .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Progress Board").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("BEARBEITBAR")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(WJTheme.secondaryText)
                }
                TextEditor(text: $model.progressBoardRules)
                    .font(.system(size: 11))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 190)
                    .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
                    .accessibilityIdentifier("settings.prompt.progress-board-text")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.prompt.progress-board")

            Text("Worker")
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 4)
            ForEach(model.workers) { worker in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("WORKER · \(worker.name.uppercased())")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(modelColor(worker.model))
                            Text("\(worker.mentionTag) · \(worker.model)")
                                .font(.system(size: 9))
                                .foregroundStyle(WJTheme.secondaryText)
                        }
                        Spacer()
                        Button(editingWorkerID == worker.id ? "Fertig" : "Bearbeiten") {
                            editingWorkerID = editingWorkerID == worker.id ? nil : worker.id
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(editingWorkerID == worker.id ? WJTheme.accent : WJTheme.secondaryText)
                        .accessibilityLabel("Aufgabe von (worker.name) bearbeiten")
                        .accessibilityIdentifier("settings.prompt.edit-worker.\(worker.id.uuidString)")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            promptFact(worker.model)
                            promptFact(worker.harness.rawValue)
                            promptFact(model.computer(for: worker.computerID)?.name ?? "Unbekannter Computer")
                            promptFact(worker.reasoningEffort?.rawValue ?? "Reasoning automatisch")
                        }
                    }
                    if isFirstWorkerForModel(worker) {
                        let canonicalModel = ModelPromptCatalog.canonicalName(for: worker.model)
                        HStack {
                            Text("MODELL · \(canonicalModel.uppercased())")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(modelColor(worker.model))
                            Spacer()
                            Button(editingModel == canonicalModel ? "Fertig" : "Bearbeiten") {
                                editingModel = editingModel == canonicalModel ? nil : canonicalModel
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(editingModel == canonicalModel ? modelColor(worker.model) : WJTheme.secondaryText)
                            .accessibilityLabel("Modellregeln für \(canonicalModel) bearbeiten")
                            .accessibilityIdentifier("settings.prompt.edit-model.\(promptIdentifier(canonicalModel))")
                        }
                        if editingModel == canonicalModel {
                            TextField(
                                "Regeln für alle Worker mit diesem Modell",
                                text: modelPromptBinding(worker.model),
                                axis: .vertical
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .lineLimit(4...14)
                            .padding(8)
                            .frame(minHeight: 88, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(WJTheme.surface))
                            .accessibilityIdentifier("settings.prompt.model-text.\(promptIdentifier(canonicalModel))")
                        } else {
                            promptSourceText(model.modelPrompt(for: worker.model), empty: "Noch keine Regeln für dieses Modell")
                        }
                    }
                    Text("WORKER-AUFGABE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(modelColor(worker.model))
                    if editingWorkerID == worker.id {
                        TextField(
                            "Aufgabe dieses Workers",
                            text: workerInstructionsBinding(worker.id),
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .lineLimit(3...10)
                        .padding(8)
                        .frame(minHeight: 72, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(WJTheme.surface))
                        .accessibilityIdentifier("settings.prompt.worker-text.\(worker.id.uuidString)")
                    } else {
                        promptSourceText(worker.instructions, empty: "Noch keine Aufgabe für diesen Worker")
                    }
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 7).fill(modelColor(worker.model).opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(modelColor(worker.model).opacity(0.25), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Ad-hoc Learnings").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("DAUERHAFT")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(WJTheme.secondaryText)
                }
                Text("Für wiederkehrende Orchestrierungsprobleme. Workjet übernimmt diese Regeln dauerhaft in alle Projekte.")
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Auch per CLI: workjet learn --systematic \"Fehlermuster → neue Regel\"")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(WJTheme.accent)
                    .textSelection(.enabled)
                TextField(
                    "Noch keine projektübergreifenden Learnings",
                    text: $model.adHocLearnings,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(4...14)
                .padding(8)
                .frame(minHeight: 96, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
            }
            .padding(.top, 4)

            DisclosureGroup(isExpanded: $technicalRulesExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Technische Regeln")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Enthält auch die sichtbaren Laufzeitverträge für Worker-Receipts und optionale Skills. Workjet übernimmt den Text zwischen den markierten Zeilen unverändert; fehlt ein benötigter Block, wird er nicht verborgen ersetzt.")
                        .font(.system(size: 10))
                        .foregroundStyle(WJTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Technische Regeln", text: $model.technicalRules, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .lineLimit(6...20)
                        .padding(8)
                        .frame(minHeight: 130, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
                        .accessibilityIdentifier("settings.prompt.technical-rules")

                    WJDivider().padding(.vertical, 3)
                    HStack {
                        Text("Generierte Worker-Fakten")
                            .font(.system(size: 10, weight: .semibold))
                        Spacer()
                        Text("AUS WORKER & COMPUTER")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(WJTheme.secondaryText)
                    }
                    Text("Diese Zeilen werden unverändert in den Systemprompt übernommen. Ändere sie über den jeweiligen Worker oder Computer.")
                        .font(.system(size: 10))
                        .foregroundStyle(WJTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        Text(model.generatedWorkerPreview)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(WJTheme.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 240)
                    .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
                    .accessibilityIdentifier("settings.prompt.generated-worker-facts")
                }
                .padding(.top, 7)
            } label: {
                HStack {
                    Text("Erweiterte Regeln")
                    Spacer()
                    Text("REGELN EDITIERBAR")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(WJTheme.secondaryText)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.top, 2)
        }
    }

    private func modelPromptBinding(_ modelName: String) -> Binding<String> {
        Binding(
            get: { model.modelPrompt(for: modelName) },
            set: { model.setModelPrompt($0, for: modelName) }
        )
    }

    private func workerInstructionsBinding(_ workerID: UUID) -> Binding<String> {
        Binding(
            get: { model.workers.first(where: { $0.id == workerID })?.instructions ?? "" },
            set: { model.setWorkerInstructions($0, for: workerID) }
        )
    }

    private func isFirstWorkerForModel(_ worker: Worker) -> Bool {
        let canonical = ModelPromptCatalog.canonicalName(for: worker.model)
        return model.workers.first { ModelPromptCatalog.canonicalName(for: $0.model) == canonical }?.id == worker.id
    }

    private func promptFact(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(WJTheme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(WJTheme.surface))
    }

    private func promptSourceText(_ value: String, empty fallback: String) -> some View {
        Text(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value)
            .font(.system(size: 11))
            .foregroundStyle(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? WJTheme.secondaryText : Color.primary)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(WJTheme.surface.opacity(0.72)))
            .textSelection(.enabled)
    }

    private func promptIdentifier(_ value: String) -> String {
        value.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    private func modelColor(_ modelName: String) -> Color {
        let normalized = modelName.lowercased()
        if normalized.contains("kimi") { return Color(red: 0.55, green: 0.48, blue: 1.0) }
        if normalized.contains("minimax") { return Color(red: 1.0, green: 0.38, blue: 0.36) }
        return WJTheme.accent
    }
}

private struct AccessSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                WJSectionHeader(title: "Anbieter")
                    .accessibilityIdentifier("settings.section.providers")
                Spacer()
                if model.workerHealthProbeInFlight {
                    ProgressView().controlSize(.mini)
                }
                Button(model.workerHealthProbeInFlight ? "Worker werden geprüft …" : "Alle Worker prüfen") {
                    Task { await model.probeAllWorkersNow() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(model.workerHealthProbeInFlight)
                .accessibilityIdentifier("settings.providers.probe-all")
            }
            Text(model.workerHealthFreshnessText)
                .font(.system(size: 10))
                .foregroundStyle(WJTheme.secondaryText)
            if let error = model.workerHealthProbeError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.quotaCritical)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProviderAccountsView()
        }
    }
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

private struct ComputersSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    let onAdd: () -> Void; let onEdit: (Computer) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { WJSectionHeader(title: "Computer").accessibilityIdentifier("settings.section.computers"); Spacer(); Button(action: onAdd) { Image(systemName: "plus") }.buttonStyle(WJIconButtonStyle()) }
            ForEach(model.computers) { computer in
                VStack(alignment: .leading, spacing: 7) {
                    HStack { VStack(alignment: .leading, spacing: 2) { Text(computer.name).font(.system(size: 12, weight: .semibold)); Text(detail(computer)).font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).lineLimit(1) }; Spacer(); if !computer.isLocal { Button { onEdit(computer) } label: { Image(systemName: "pencil") }.buttonStyle(WJIconButtonStyle()) } }
                    ForEach(visibleHarnesses(for: computer), id: \.self) { harness in
                        harnessRow(harness, computer: computer)
                    }
                    if computer.isLocal {
                        let piCodeBoundary = "Pi Code wird über den Workjet-Host auf eingerichteten Remote-Computern verwaltet; eine lokale One-Shot-Schnittstelle ist noch nicht implementiert."
                        Text(piCodeBoundary)
                            .font(.system(size: 9))
                            .foregroundStyle(WJTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.harness.local.pi-note")
                            .accessibilityLabel(piCodeBoundary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface.opacity(0.45)))
                .task(id: computer.id) { await model.inspectHarnesses(on: computer) }
            }
        }
    }

    private func harnessRow(_ harness: Harness, computer: Computer) -> some View {
        let status = model.harnessStatus(harness, on: computer.id)
        return HStack(spacing: 7) {
            Circle().fill(statusColor(status.state)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(harness.rawValue).font(.system(size: 11, weight: .medium))
                Text(status.detail).font(.system(size: 9)).foregroundStyle(WJTheme.secondaryText).lineLimit(1)
            }
            Spacer()
            ForEach(status.actions, id: \.self) { action in
                Button(action.label) {
                    Task { await model.performHarnessAction(action, harness: harness, on: computer) }
                }
                .buttonStyle(.bordered).controlSize(.mini)
                .disabled(status.state == .checking)
            }
            .accessibilityIdentifier("settings.harness.\(computer.id.uuidString).\(harness.rawValue)")
        }
    }

    private func statusColor(_ state: HarnessComputerState) -> Color {
        switch state {
        case .unknown, .checking: return WJTheme.secondaryText
        case .missing: return WJTheme.quotaWarning
        case .installed: return WJTheme.quotaOK
        case .broken: return WJTheme.quotaCritical
        }
    }
    private func visibleHarnesses(for computer: Computer) -> [Harness] {
        if computer.isLocal {
            return HarnessAdapterRegistry.local.map(\.harness)
        }
        return Harness.allCases
    }
    private func detail(_ computer: Computer) -> String {
        computer.isLocal ? "Dieser Mac" : "\(computer.transport.rawValue) · \(computer.host) · \(computer.deploymentStatus.rawValue)"
    }
}

private struct TelemetrySettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WJSectionHeader(title: "Telemetrie")
                .accessibilityIdentifier("settings.section.telemetry")
            Toggle("Claude-Code-Aktivitätsdetails anzeigen", isOn: $model.telemetryClaudeCodeEvents).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text("Zeigt bei laufenden Claude-Code-Workern zusätzliche Aktivitätsdetails.")
                .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            Toggle("Pi-Code-Aktivitätsdetails anzeigen", isOn: $model.telemetrySidecarEvents).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text("Zeigt bei laufenden Pi-Code-Workern zusätzliche Aktivitätsdetails.")
                .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
        }
    }
}

private struct ExecutionSettingsSection: View {
    @EnvironmentObject private var model: WorkjetViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WJSectionHeader(title: "Ausführung")
                .accessibilityIdentifier("settings.section.execution")
            Stepper(value: $model.providerSlots, in: 1...3) { Text("Gleichzeitige Aufträge: \(model.providerSlots)").font(.system(size: 12)) }
            Stepper(value: $model.probeTimeoutSeconds, in: 5...600, step: 5) { Text("Verbindungsprüfung: \(model.probeTimeoutSeconds) s").font(.system(size: 12)) }
            Stepper(value: $model.turnTimeoutSeconds, in: 60...10800, step: 60) { Text("Maximale Laufzeit: \(model.turnTimeoutSeconds) s").font(.system(size: 12)) }
            Toggle("Bei Ausfall Ersatzmodell verwenden", isOn: $model.degradationAllowed).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text("Ein Ersatzmodell wird nur verwendet, wenn du diese Option aktivierst.").font(.system(size: 11)).foregroundStyle(WJTheme.tertiaryText)
        }
    }
}

private extension View {
    func fieldSurface() -> some View { self.padding(.horizontal, 9).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface)) }
}
