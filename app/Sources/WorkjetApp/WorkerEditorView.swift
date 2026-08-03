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
                VStack(alignment: .leading, spacing: 16) {
                    nameSection
                    harnessSection
                    providerSection
                    modelSection
                    reasoningSection
                    instructionsSection
                    computerSection
                    DisclosureGroup("Technische Details") {
                        invocationSection.padding(.top, 6)
                    }
                    .font(.system(size: 11))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
        .onAppear {
            if draft.computerID == nil { draft.computerID = model.computers.first(where: \.isLocal)?.id }
            if draft.executable.isEmpty { draft.selectHarness(draft.harness) }
        }
    }

    private var header: some View {
        HStack {
            Text(worker == nil ? "Neuer Worker" : "Worker bearbeiten")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Speichern") {
                if let saved = draft.applied(to: worker) {
                    model.upsertWorker(saved)
                    Task { await model.flushPersistence(); onClose() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!draft.isValid)
            .accessibilityLabel("Worker speichern")
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
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                .accessibilityLabel("Name oder Rolle des Workers")
        }
    }

    private var harnessSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Harness")
            HStack(spacing: 8) {
                ForEach(Harness.allCases, id: \.self) { harness in
                    WJChoiceButton(
                        title: harness.rawValue,
                        isSelected: draft.harness == harness,
                        accessibilityLabel: "Harness \(harness.rawValue)"
                    ) {
                        draft.selectHarness(harness)
                    }
                }
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Modell")
            TextField("z. B. gpt-5.6-sol", text: $draft.model)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                .accessibilityLabel("Modell des Workers")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(modelSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { draft.model = suggestion }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(draft.model == suggestion ? .white : WJTheme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(draft.model == suggestion ? WJTheme.accent.opacity(0.85) : WJTheme.surface))
                            .accessibilityLabel("Modell \(suggestion) wählen")
                    }
                }
            }
        }
    }

    private var modelSuggestions: [String] {
        WorkerModelSuggestions.values(providerID: draft.providerID, providers: model.providers)
    }

    private var reasoningSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Reasoning")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    WJChoiceButton(title: "Automatisch", isSelected: draft.reasoningEffort == nil) { draft.reasoningEffort = nil }
                    ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                        WJChoiceButton(title: effort.label, isSelected: draft.reasoningEffort == effort) { draft.reasoningEffort = effort }
                    }
                }
            }
            Text("Fable gibt den gewählten Effort beim Harness-Aufruf weiter; Workjet verändert keine eigenen Executable-Argumente.")
                .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Anbieter / Zugangsroute")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    WJChoiceButton(title: "Nicht konfiguriert", isSelected: draft.providerID == nil, accessibilityLabel: "Keine Anbieterroute") {
                        draft.providerID = nil
                    }
                    ForEach(model.providers) { provider in
                        WJChoiceButton(
                            title: provider.name,
                            isSelected: draft.providerID == provider.id,
                            accessibilityLabel: "Anbieterroute \(provider.name)",
                            help: "\(provider.kind.rawValue) · \(provider.endpoint)"
                        ) { draft.providerID = provider.id }
                    }
                    if let selected = draft.providerID, !model.providers.contains(where: { $0.id == selected }) {
                        WJChoiceButton(title: "Nicht verfügbar", isSelected: true, accessibilityLabel: "Gelöschter Anbieter ist nicht verfügbar") {}
                    }
                }
                .padding(.vertical, 1)
            }
            if let selected = draft.providerID, !model.providers.contains(where: { $0.id == selected }) {
                Text("Die gespeicherte Anbieterreferenz \(selected.uuidString.lowercased()) wurde gelöscht. Sie bleibt unverändert und wird nie automatisch ersetzt.")
                    .font(.system(size: 10)).foregroundStyle(WJTheme.quotaCritical)
            } else {
                Text("Entdeckte Modelle des gewählten Anbieters stehen oben zuerst; freie Modelleingabe bleibt möglich. Geheimnisse bleiben in der lokalen Keychain.")
                    .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            }
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Rolle und Anweisungen")
            Text("Dieser Text wird mit seinen Markdown-Zeilenumbrüchen in den verwalteten Systemprompt kopiert.")
                .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            if !otherWorkers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Worker erwähnen:").font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
                        ForEach(otherWorkers) { other in
                            Button(other.mentionTag) { appendMention(other.mentionTag) }
                                .buttonStyle(.plain).font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(WJTheme.surface))
                        }
                    }
                }
            }
            TextEditor(text: $draft.instructions)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 110)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                .accessibilityLabel("Rolle und Anweisungen")
            if !unresolvedMentions.isEmpty {
                Text("Unbekannte Worker-Erwähnung: \(unresolvedMentions.joined(separator: ", "))")
                    .font(.system(size: 10)).foregroundStyle(WJTheme.quotaWarning)
            }
        }
    }

    private var otherWorkers: [Worker] { model.workers.filter { $0.id != worker?.id } }
    private var unresolvedMentions: [String] { ManagedPrompt.unresolvedMentions(in: draft.instructions, workers: model.workers) }

    private func appendMention(_ mention: String) {
        if !draft.instructions.isEmpty && !draft.instructions.hasSuffix(" ") && !draft.instructions.hasSuffix("\n") { draft.instructions.append(" ") }
        draft.instructions.append(mention)
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
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}
