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
    @State private var showTechnicalDetails = false
    @State private var showManualModelEntry = false
    @State private var editedModelPrompts: [String: String] = [:]
    @State private var validationTarget: ValidationTarget?
    @FocusState private var focusedField: EditorField?

    private enum EditorField: Hashable {
        case name
        case instructions
    }

    private enum ValidationTarget: Equatable {
        case name, provider, model, instructions, computer, save

        var message: String {
            switch self {
            case .name: return "Gib dem Worker einen Namen oder eine Rolle."
            case .provider: return "Wähle einen Zugang oder Anbieter-Pool."
            case .model: return "Wähle ein Modell."
            case .instructions: return "Beschreibe kurz die Aufgabe dieses Workers."
            case .computer: return "Wähle einen Ziel-Computer."
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
                    if !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        modelPromptSection
                    }
                    computerSection
                    DisclosureGroup("Technische Details", isExpanded: $showTechnicalDetails) {
                        invocationSection.padding(.top, 6)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .accessibilityIdentifier("worker.editor.scroll")
        }
        .onAppear {
            if draft.computerID == nil { draft.computerID = model.computers.first(where: \.isLocal)?.id }
            if draft.executable.isEmpty { draft.selectHarness(draft.harness) }
            applyAdapterOptionDefaults()
        }
        .sheet(isPresented: $showProviderSetup) {
            ProviderSetupView(
                selectedRoute: draft.providerRoute,
                onSelect: { route in
                    draft.providerRoute = route
                    clearValidation(.provider)
                    let suggestions = WorkerModelSuggestions.values(route: route, providers: model.providers)
                    if route != nil, !suggestions.contains(draft.model) {
                        selectModel(suggestions.first ?? "")
                    }
                    showProviderSetup = false
                },
                onClose: { showProviderSetup = false }
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
            Button("Speichern") { save() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel("Worker speichern")
            .accessibilityIdentifier("worker.editor.save")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(WJIconButtonStyle())
            .accessibilityLabel("Schließen ohne Speichern")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                    ForEach(HarnessAdapterRegistry.all) { adapter in
                        WJChoiceButton(
                            title: adapter.displayName,
                            isSelected: draft.harness == adapter.harness,
                            accessibilityLabel: "Harness \(adapter.displayName)"
                        ) {
                            draft.selectHarness(adapter.harness)
                            applyAdapterOptionDefaults()
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
                        .accessibilityIdentifier("worker.editor.provider.\(provider.id)")
                    }
                    Button { showProviderSetup = true } label: { Image(systemName: "plus") }
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
                Text("Keine Anbieterroute. Modell und Prompttext bleiben sichtbar; wähle zum Ausführen einen Zugang oder Pool.")
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

    private var modelPromptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                WJSectionHeader(title: "Modellregeln · \(modelPromptName)")
                Spacer()
                Text("GEMEINSAM")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WJTheme.accent)
            }
            TextEditor(text: modelPromptBinding)
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 150)
                .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.accent.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(WJTheme.accent.opacity(0.65), lineWidth: 1))
                .accessibilityLabel("Modellregeln für \(modelPromptName)")
                .accessibilityIdentifier("worker.editor.model-prompt.\(modelPromptName)")
            Text("Dieser Block erscheint im Systemprompt und gilt für alle Worker mit diesem Modell.")
                .font(.system(size: 10))
                .foregroundStyle(WJTheme.secondaryText)
        }
    }

    private var modelPromptName: String {
        ModelPromptCatalog.canonicalName(for: draft.model)
    }

    private var modelPromptBinding: Binding<String> {
        let name = modelPromptName
        return Binding(
            get: { editedModelPrompts[name] ?? model.modelPrompt(for: name) },
            set: { editedModelPrompts[name] = $0 }
        )
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
            WJSectionHeader(title: "Stabile Invocation")
            if isRemotePi {
                Text(remotePiRunnerTruth)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(WJTheme.secondaryText)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
                Text("Executable und Argumente werden für Remote-Pi generiert und sind deshalb hier nicht editierbar. Agent-Dateiwerkzeuge arbeiten nur auf dem projizierten In-Memory-Snapshot; kein beliebiges physisches Projektverzeichnis wird als schreibbar behauptet.")
                    .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            } else {
                TextField("Absolute Datei oder ~/… Wrapper", text: $draft.executable)
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

    private var isRemotePi: Bool {
        draft.harness == .piSidecar && selectedComputer?.isLocal == false
    }

    private var remotePiRunnerTruth: String {
        let sandboxArgument = selectedComputer?.sandboxEnabled == true ? " --sandbox" : ""
        let sandboxTruth = selectedComputer?.sandboxEnabled == true
            ? "Bubblewrap-OS-Sandbox aktiviert"
            : "OS-Sandbox deaktiviert"
        return "node ~/.local/lib/workjet/current/workjet-pi-turn.mjs\(sandboxArgument)\n\(sandboxTruth) · eine finale NDJSON-Antwort · Pi-Events post-hoc"
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
                            clearValidation(.computer)
                        }
                        .accessibilityIdentifier("worker.editor.computer.\(computer.id.uuidString)")
                    }
                }
                .padding(.vertical, 1)
            }
            validationText(.computer)
        }
    }

    private func save() {
        validationTarget = nil
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
            draft.selectHarness(draft.harness)
        }
        guard let saved = draft.applied(to: worker) else {
            validationTarget = .save
            return
        }
        for (modelName, prompt) in editedModelPrompts {
            model.setModelPrompt(prompt, for: modelName)
        }
        model.upsertWorker(saved)
        Task {
            if await model.flushPersistence() { onClose() }
        }
    }

    @ViewBuilder
    private func validationText(_ target: ValidationTarget) -> some View {
        if validationTarget == target {
            Text(target.message)
                .font(.system(size: 10))
                .foregroundStyle(WJTheme.quotaCritical)
        }
    }

    private func clearValidation(_ target: ValidationTarget) {
        if validationTarget == target { validationTarget = nil }
    }
}
