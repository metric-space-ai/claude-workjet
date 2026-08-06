import SwiftUI
import WorkjetCore

/// Worker editor, opened by both "Worker hinzufügen" (+) and the row pencil.
/// Fields: name/role, harness buttons, model, worker-specific instructions,
/// target computer. There is intentionally no global worker system prompt.
struct WorkerEditorView: View {
    @EnvironmentObject private var model: WorkjetViewModel

    let worker: Worker?
    let onClose: () -> Void

    @State private var draft: WorkerDraft
    @State private var showProviderSetup = false
    @State private var providerToOpen: ModelProvider?
    @State private var showTechnicalDetails = false
    @State private var showManualModelEntry = false
    @State private var showDeleteConfirmation = false
    @State private var deletionMessage: String?
    @State private var persistenceMessage: String?
    @State private var deleting = false
    @State private var saving = false
    @State private var validationTarget: ValidationTarget?
    @State private var harnessInspectionTask: Task<Void, Never>?
    @FocusState private var focusedField: EditorField?

    private enum EditorField: Hashable {
        case name
        case instructions
    }

    private enum ValidationTarget: Equatable {
        case name, provider, model, instructions, computer, harness, save

        var message: String {
            switch self {
            case .name: return "Gib dem Worker einen Namen oder eine Rolle."
            case .provider: return "Wähle einen Zugang oder Anbieter-Pool."
            case .model: return "Wähle ein Modell."
            case .instructions: return "Beschreibe kurz die Aufgabe dieses Workers."
            case .computer: return "Wähle einen Ziel-Computer."
            case .harness: return "Das gewählte Harness wurde auf diesem Computer noch nicht bestätigt. Prüfe es unter Einstellungen > Computer."
            case .save: return "Der Worker konnte nicht gespeichert werden."
            }
        }
    }

    init(worker: Worker?, onClose: @escaping () -> Void) {
        self.worker = worker
        self.onClose = onClose
        _draft = State(initialValue: WorkerDraft(worker: worker))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            WJDivider()
            if showDeleteConfirmation, let worker {
                deleteConfirmation(worker)
                WJDivider()
            } else if let deletionMessage {
                operationError(deletionMessage, identifier: "worker.editor.delete.error.\(worker?.id.uuidString ?? "unknown")")
                WJDivider()
            } else if let persistenceMessage {
                operationError(persistenceMessage, identifier: "worker.editor.save.error")
                WJDivider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    nameSection
                    harnessSection
                    providerSection
                    modelSection
                    if !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !supportedReasoningEfforts.isEmpty { reasoningSection }
                        if !adapterOptions.isEmpty { adapterOptionsSection }
                    }
                    instructionsSection
                    skillsSection
                    computerSection
                    DisclosureGroup("Technische Details", isExpanded: $showTechnicalDetails) {
                        invocationSection.padding(.top, 6)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .disabled(saving || deleting)
            .accessibilityIdentifier("worker.editor.scroll")
        }
        .onAppear {
            if draft.computerID == nil { draft.computerID = model.computers.first(where: \.isLocal)?.id }
            if worker == nil {
                if draft.executable.isEmpty { draft.selectHarness(draft.harness) }
                applyAdapterOptionDefaults()
            }
        }
        .onDisappear { cancelHarnessInspection() }
        .sheet(isPresented: $showProviderSetup) {
            ProviderSetupView(
                selectedRoute: draft.providerRoute,
                initiallyOpenProvider: providerToOpen,
                onSelect: { route in
                    draft.providerRoute = route
                    clearValidation(.provider)
                    let suggestions = WorkerModelSuggestions.values(route: route, providers: model.providers)
                    if route != nil, !suggestions.contains(draft.model) {
                        selectModel(suggestions.first ?? "")
                    }
                    showProviderSetup = false
                },
                onClose: {
                    showProviderSetup = false
                    providerToOpen = nil
                }
            )
            .environmentObject(model)
        }
    }

    private var header: some View {
        HStack {
            Text(worker == nil ? "Neuer Worker" : "Worker bearbeiten")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("worker.editor.title")
            Spacer()
            if let worker {
                Button("Löschen", role: .destructive) { requestDeletion(of: worker) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(deleting || saving)
                    .accessibilityLabel("Worker \(worker.name) löschen")
                    .accessibilityIdentifier("worker.editor.delete.\(worker.id.uuidString)")
            }
            Button(saving ? "Wird gespeichert …" : "Speichern") { save() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(saving || deleting)
            .accessibilityLabel("Worker speichern")
            .accessibilityIdentifier("worker.editor.save")
            Button {
                cancelHarnessInspection()
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(WJIconButtonStyle())
            .disabled(saving || deleting)
            .accessibilityLabel("Schließen ohne Speichern")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func deleteConfirmation(_ worker: Worker) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("„\(worker.name)“ wirklich löschen?")
                .font(.system(size: 12, weight: .semibold))
            Text("Der Worker wird aus Workjet und dem synchronisierten Systemprompt entfernt. Modellregeln und bisherige Läufe bleiben erhalten.")
                .font(.system(size: 10))
                .foregroundStyle(WJTheme.secondaryText)
            HStack(spacing: 8) {
                Button("Abbrechen") {
                    showDeleteConfirmation = false
                    deletionMessage = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("worker.editor.delete.cancel.\(worker.id.uuidString)")
                Button("Worker löschen", role: .destructive) { confirmDeletion(of: worker) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(deleting || saving)
                    .accessibilityIdentifier("worker.editor.delete.confirm.\(worker.id.uuidString)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WJTheme.quotaCritical.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("worker.editor.delete.confirmation.\(worker.id.uuidString)")
    }

    private func operationError(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(WJTheme.quotaCritical)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }

    private func requestDeletion(of worker: Worker) {
        guard !deleting, !saving else { return }
        deletionMessage = nil
        persistenceMessage = nil
        if let reason = model.workerDeletionBlockReason(id: worker.id) {
            showDeleteConfirmation = false
            deletionMessage = reason
        } else {
            showDeleteConfirmation = true
        }
    }

    private func confirmDeletion(of worker: Worker) {
        guard !deleting, !saving else { return }
        deleting = true
        Task {
            let result = await model.deleteWorker(id: worker.id)
            deleting = false
            switch result {
            case .deleted:
                onClose()
            case let .blocked(message), let .failed(message):
                showDeleteConfirmation = false
                deletionMessage = message
            }
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Name / Rolle")
            TextField("z. B. Completion Engine", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focusedField, equals: .name)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(validationTarget == .name ? WJTheme.quotaCritical : .clear, lineWidth: 1)
                )
                .accessibilityLabel("Name oder Rolle des Workers")
                .accessibilityIdentifier("worker.editor.name")
                .onChange(of: draft.name) { clearValidation(.name) }
            validationText(.name)
        }
    }

    private var harnessSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Harness")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availableHarnessAdapters) { adapter in
                        WJChoiceButton(
                            title: adapter.displayName,
                            isSelected: draft.harness == adapter.harness,
                            accessibilityLabel: "Harness \(adapter.displayName)"
                        ) {
                            draft.selectHarness(adapter.harness)
                            applyAdapterOptionDefaults()
                            inspectSelectedHarness()
                        }
                        .accessibilityIdentifier("worker.editor.harness.\(adapter.id)")
                    }
                }
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                WJSectionHeader(title: "Modell")
                Spacer()
                Button { showManualModelEntry.toggle() } label: { Image(systemName: "pencil") }
                    .buttonStyle(WJIconButtonStyle())
                    .accessibilityLabel("Modell-ID manuell bearbeiten")
                    .help("Modell-ID manuell bearbeiten")
            }
            if !displayedModelSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(displayedModelSuggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                selectModel(suggestion)
                                clearValidation(.model)
                            }
                                .buttonStyle(.plain)
                                .font(.system(size: 10))
                                .foregroundStyle(draft.model == suggestion ? .white : WJTheme.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(draft.model == suggestion ? WJTheme.accent.opacity(0.85) : WJTheme.surface))
                                .accessibilityLabel("Modell \(suggestion) wählen")
                                .accessibilityIdentifier("worker.editor.model.\(suggestion)")
                        }
                    }
                }
            }
            if showManualModelEntry || displayedModelSuggestions.isEmpty {
                TextField("Modell-ID", text: $draft.model)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
                    .accessibilityIdentifier("worker.editor.model-id")
                    .onChange(of: draft.model) {
                        clearValidation(.model)
                        normalizeAdapterSelections()
                    }
            }
            validationText(.model)
        }
    }

    private var modelSuggestions: [String] {
        WorkerModelSuggestions.values(route: draft.providerRoute, providers: model.providers)
    }

    private var displayedModelSuggestions: [String] {
        Provider.normalizedModels(
            (draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [draft.model])
                + modelSuggestions
        )
    }

    private var reasoningSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Reasoning")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    WJChoiceButton(title: "Automatisch", isSelected: draft.reasoningEffort == nil) { draft.reasoningEffort = nil }
                        .accessibilityIdentifier("worker.editor.reasoning.automatic")
                    ForEach(supportedReasoningEfforts, id: \.self) { effort in
                        WJChoiceButton(title: effort.label, isSelected: draft.reasoningEffort == effort) { draft.reasoningEffort = effort }
                            .accessibilityIdentifier("worker.editor.reasoning.\(effort.rawValue)")
                    }
                }
            }
        }
    }

    private var selectedAdapter: HarnessAdapterDescriptor {
        HarnessAdapterRegistry.descriptor(for: draft.harness)
    }

    private var availableHarnessAdapters: [HarnessAdapterDescriptor] {
        guard let selectedComputer else { return HarnessAdapterRegistry.local }
        if selectedComputer.isLocal { return HarnessAdapterRegistry.local }
        let registry = RemoteHarnessAdapterRegistry()
        return HarnessAdapterRegistry.all.filter { registry.supports($0.harness) }
    }

    private var supportedReasoningEfforts: [ReasoningEffort] {
        selectedAdapter.reasoningEfforts(for: draft.model)
    }

    private var adapterOptions: [HarnessOptionDescriptor] {
        selectedAdapter.options(for: draft.model)
    }

    private var adapterOptionsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(adapterOptions) { option in
                VStack(alignment: .leading, spacing: 5) {
                    WJSectionHeader(title: option.label)
                    HStack(spacing: 6) {
                        ForEach(option.choices) { choice in
                            WJChoiceButton(
                                title: choice.label,
                                isSelected: draft.harnessOptions[option.id] == choice.id
                            ) {
                                draft.harnessOptions[option.id] = choice.id
                            }
                        }
                    }
                }
            }
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Anbieter")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(ModelProvider.allCases) { provider in
                        Button {
                            providerToOpen = provider
                            showProviderSetup = true
                        } label: {
                            ProviderLogo(provider: provider, size: 22)
                                .frame(width: 34, height: 30)
                                .background(RoundedRectangle(cornerRadius: 7).fill(selectedModelProvider == provider ? WJTheme.accent.opacity(0.28) : WJTheme.surface))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selectedModelProvider == provider ? WJTheme.accent : WJTheme.divider))
                        }
                        .buttonStyle(.plain)
                        .help(provider.rawValue)
                        .accessibilityLabel("Anbieter \(provider.rawValue)")
                        .accessibilityValue(
                            ProcessInfo.processInfo.environment["WORKJET_UI_TEST_WINDOW"] == "1"
                                ? (ProviderLogo.hasBrandArtwork(for: provider) ? "Originalmarke" : "Ersatzmarke")
                                : ""
                        )
                        .accessibilityIdentifier("worker.editor.provider.\(provider.id)")
                    }
                    Button {
                        providerToOpen = nil
                        showProviderSetup = true
                    } label: { Image(systemName: "plus") }
                        .buttonStyle(WJIconButtonStyle())
                        .accessibilityLabel("Anbieter einrichten")
                        .accessibilityIdentifier("worker.editor.provider.setup")
                }
                .padding(.vertical, 1)
            }
            if let routeLabel {
                Text(routeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.secondaryText)
            } else {
                Text("Noch kein Zugang gewählt. Wähle einen Anbieter, um den Worker zu verwenden.")
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.quotaWarning)
            }
            validationText(.provider)
        }
    }

    private var selectedModelProvider: ModelProvider? {
        switch draft.providerRoute {
        case let .pool(provider): return provider
        case let .account(id): return model.providers.first(where: { $0.id == id })?.modelProvider
        case nil: return nil
        }
    }

    private var routeLabel: String? {
        switch draft.providerRoute {
        case let .account(id):
            return model.providers.first(where: { $0.id == id }).map { "Zugang: \($0.name)" }
        case let .pool(provider):
            let accounts = model.providerAccounts(for: provider)
            return "Pool: " + accounts.map(\.name).joined(separator: " → ")
        case nil:
            return nil
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Aufgabe dieses Workers")
            TextField(
                "Was soll dieser Worker übernehmen?",
                text: $draft.instructions,
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focusedField, equals: .instructions)
                .lineLimit(5...12)
                .padding(9)
                .frame(minHeight: 96, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(validationTarget == .instructions ? WJTheme.quotaCritical : (focusedField == .instructions ? WJTheme.accent : .clear), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { focusedField = .instructions }
                .onChange(of: draft.instructions) { clearValidation(.instructions) }
                .accessibilityLabel("Aufgabe dieses Workers")
                .accessibilityIdentifier("worker.editor.instructions")
            validationText(.instructions)
            Text("Nur für \(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "diesen Worker" : draft.name); wird als Worker-Aufgabe in den Systemprompt übernommen.")
                .font(.system(size: 10))
                .foregroundStyle(WJTheme.secondaryText)
            if !unresolvedMentions.isEmpty {
                Text("Unbekannte Worker-Erwähnung: \(unresolvedMentions.joined(separator: ", "))")
                    .font(.system(size: 10)).foregroundStyle(WJTheme.quotaWarning)
            }
        }
    }

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            WJSectionHeader(title: "Skills")
            ForEach(WorkerSkillCatalog.all) { skill in
                let compatible = skill.isCompatible(with: draft.harness)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { draft.configuredEnabled(for: skill) },
                        set: { draft.setConfiguredEnabled($0, for: skill) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(skill.description)
                                .font(.system(size: 10))
                                .foregroundStyle(WJTheme.secondaryText)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!compatible)
                    .accessibilityLabel("Skill \(skill.displayName)")
                    .accessibilityValue(compatible
                        ? (draft.configuredEnabled(for: skill) ? "Aktiviert" : "Deaktiviert")
                        : "Nicht unterstützt für \(draft.harness.rawValue)")
                    .accessibilityIdentifier("worker.editor.skill.\(skill.id)")

                    if !compatible {
                        Text(skill.incompatibilityDescription(for: draft.harness))
                            .font(.system(size: 10))
                            .foregroundStyle(WJTheme.quotaWarning)
                            .accessibilityIdentifier("worker.editor.skill.\(skill.id).unsupported")
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("worker.editor.skill.\(skill.id).row")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("worker.editor.skills")
    }

    private var otherWorkers: [Worker] { model.workers.filter { $0.id != worker?.id } }
    private var unresolvedMentions: [String] { ManagedPrompt.unresolvedMentions(in: draft.instructions, workers: model.workers) }

    private func appendMention(_ mention: String) {
        if !draft.instructions.isEmpty && !draft.instructions.hasSuffix(" ") && !draft.instructions.hasSuffix("\n") { draft.instructions.append(" ") }
        draft.instructions.append(mention)
    }

    private func selectModel(_ model: String) {
        draft.model = model
        if let effort = draft.reasoningEffort, !supportedReasoningEfforts.contains(effort) {
            draft.reasoningEffort = nil
        }
        normalizeAdapterSelections()
        applyAdapterOptionDefaults()
    }

    private func normalizeAdapterSelections() {
        let allowed = Set(adapterOptions.map(\.id))
        draft.harnessOptions = draft.harnessOptions.filter { allowed.contains($0.key) }
    }

    private func applyAdapterOptionDefaults() {
        normalizeAdapterSelections()
        for option in adapterOptions where draft.harnessOptions[option.id] == nil {
            draft.harnessOptions[option.id] = option.defaultValue
        }
    }

    private var invocationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            WJSectionHeader(title: "Startbefehl")
            if isRemotePi {
                Text(remotePiRuntimeSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(WJTheme.secondaryText)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
                Text("Pi Code erhält nur die Dateien des aktuellen Auftrags. Aktivitätsdetails erscheinen nach Abschluss.")
                    .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            } else {
                TextField("Vollständiger Pfad oder ~/…-Wrapper", text: $draft.executable)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .padding(8).background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
                Text("Argumente (eine Zeile je Argument; <WORKJET_BRIEF> markiert den Brief)")
                    .font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText)
                TextEditor(text: $draft.arguments).font(.system(size: 11, design: .monospaced)).scrollContentBackground(.hidden)
                    .padding(6).frame(minHeight: 70).background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
            }
            Text("Fähigkeiten (eine Zeile je Aussage)").font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText)
            TextEditor(text: $draft.capabilities).font(.system(size: 11)).scrollContentBackground(.hidden)
                .padding(6).frame(minHeight: 70).background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
        }
    }

    private var selectedComputer: Computer? {
        guard let id = draft.computerID else { return nil }
        return model.computer(for: id)
    }

    private func inspectSelectedHarness() {
        cancelHarnessInspection()
        guard let selectedComputer else { return }
        let harness = draft.harness
        harnessInspectionTask = Task {
            await model.inspectHarness(harness, on: selectedComputer)
        }
    }

    private func cancelHarnessInspection() {
        harnessInspectionTask?.cancel()
        harnessInspectionTask = nil
    }

    private var selectedHarnessStatus: HarnessComputerStatus {
        guard let id = draft.computerID else { return .unknown }
        return model.harnessStatus(draft.harness, on: id)
    }

    private var isRemotePi: Bool {
        draft.harness == .piSidecar && selectedComputer?.isLocal == false
    }

    private var remotePiRuntimeSummary: String {
        selectedComputer?.sandboxEnabled == true
            ? "Von Workjet verwaltet · Minimal-Sandbox aktiv"
            : "Von Workjet verwaltet · Minimal-Sandbox aus"
    }

    private var computerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Ziel-Computer")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.computers) { computer in
                        WJChoiceButton(
                            title: computer.name,
                            isSelected: draft.computerID == computer.id,
                            accessibilityLabel: "Ziel-Computer \(computer.name)"
                        ) {
                            draft.computerID = computer.id
                            if computer.isLocal, !HarnessAdapterRegistry.supportsLocalExecution(draft.harness),
                               let fallback = HarnessAdapterRegistry.local.first {
                                draft.selectHarness(fallback.harness)
                                applyAdapterOptionDefaults()
                            } else if !computer.isLocal, !RemoteHarnessAdapterRegistry().supports(draft.harness),
                                      let fallback = HarnessAdapterRegistry.all.first(where: { RemoteHarnessAdapterRegistry().supports($0.harness) }) {
                                draft.selectHarness(fallback.harness)
                                applyAdapterOptionDefaults()
                            }
                            clearValidation(.computer)
                            inspectSelectedHarness()
                        }
                        .accessibilityIdentifier("worker.editor.computer.\(computer.id.uuidString)")
                    }
                }
                .padding(.vertical, 1)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(selectedHarnessStatus.state == .installed ? WJTheme.quotaOK : (selectedHarnessStatus.state == .broken ? WJTheme.quotaCritical : WJTheme.quotaWarning))
                    .frame(width: 7, height: 7)
                Text("\(draft.harness.rawValue): \(selectedHarnessStatus.detail)")
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.secondaryText)
                Spacer()
                ForEach(selectedHarnessStatus.actions, id: \.self) { action in
                    Button(action.label) {
                        guard let selectedComputer else { return }
                        Task { await model.performHarnessAction(action, harness: draft.harness, on: selectedComputer) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(selectedHarnessStatus.state == .checking)
                }
            }
            validationText(.harness)
            if let issue = invocationIssueForSelectedComputer {
                Text(issue)
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.quotaCritical)
            }
            validationText(.computer)
        }
    }

    private func save() {
        guard !saving, !deleting else { return }
        validationTarget = nil
        deletionMessage = nil
        persistenceMessage = nil
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationTarget = .name
            focusedField = .name
            return
        }
        if draft.providerRoute == nil {
            validationTarget = .provider
            return
        }
        if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationTarget = .model
            return
        }
        if draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationTarget = .instructions
            focusedField = .instructions
            return
        }
        if draft.computerID == nil {
            validationTarget = .computer
            return
        }
        if draft.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.executable = WorkerDraft.defaultExecutable(for: draft.harness)
        }
        if invocationIssueForSelectedComputer != nil {
            validationTarget = .harness
            return
        }
        if selectedComputer?.isLocal == false {
            // Remote Save owns dependency provisioning. Missing harnesses and
            // enabled managed skills are installed and verified before the
            // durable worker mutation is allowed to run.
            startDurableSave()
            return
        }
        switch selectedHarnessStatus.state {
        case .installed:
            startDurableSave()
        case .unknown, .checking:
            guard let selectedComputer else {
                validationTarget = .computer
                return
            }
            saving = true
            let harness = draft.harness
            Task {
                let status = await model.inspectHarness(harness, on: selectedComputer)
                guard status.state == .installed else {
                    saving = false
                    validationTarget = .harness
                    return
                }
                await persistDraft()
            }
        case .missing, .broken:
            validationTarget = .harness
        }
    }

    private func startDurableSave() {
        saving = true
        Task { await persistDraft() }
    }

    private func persistDraft() async {
        guard let saved = draft.applied(to: worker) else {
            saving = false
            validationTarget = .save
            return
        }
        let result = await model.saveWorkerDurably(saved)
        saving = false
        switch result {
        case .succeeded:
            onClose()
        case let .failed(message):
            persistenceMessage = message
        }
    }

    @ViewBuilder
    private func validationText(_ target: ValidationTarget) -> some View {
        if validationTarget == target {
            Text(target == .harness ? harnessValidationMessage : target.message)
                .font(.system(size: 10))
                .foregroundStyle(WJTheme.quotaCritical)
        }
    }

    private var harnessValidationMessage: String {
        switch selectedHarnessStatus.state {
        case .missing, .broken:
            return "\(draft.harness.rawValue) ist auf diesem Computer nicht einsatzbereit: \(selectedHarnessStatus.detail)"
        case .unknown, .checking:
            return "\(draft.harness.rawValue) konnte auf diesem Computer nicht bestätigt werden: \(selectedHarnessStatus.detail)"
        case .installed:
            return invocationIssueForSelectedComputer ?? ValidationTarget.harness.message
        }
    }

    private func clearValidation(_ target: ValidationTarget) {
        if validationTarget == target { validationTarget = nil }
    }

    private var invocationIssueForSelectedComputer: String? {
        guard let selectedComputer else { return nil }
        if selectedComputer.isLocal {
            return HarnessAdapterRegistry.localInvocationIssue(
                harness: draft.harness,
                invocation: WorkerInvocation(
                    executable: draft.executable.trimmingCharacters(in: .whitespacesAndNewlines),
                    arguments: draft.arguments.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                    options: draft.harnessOptions
                )
            )
        }
        return RemoteHarnessAdapterRegistry().supports(draft.harness)
            ? nil
            : "Dieses Harness ist auf Remote-Computern noch nicht ausführbar."
    }
}
