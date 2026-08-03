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

    private let modelSuggestions = ["GPT-5.6", "Kimi K3", "MiniMax M3", "Claude Opus 4.8"]

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
                    modelSection
                    instructionsSection
                    computerSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
        .onAppear {
            if draft.computerID == nil {
                draft.computerID = model.computers.first?.id
            }
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
                    onClose()
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
                        draft.harness = harness
                    }
                }
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Modell")
            TextField("z. B. gpt-5.6", text: $draft.model)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                .accessibilityLabel("Modell des Workers")
            HStack(spacing: 6) {
                ForEach(modelSuggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        draft.model = suggestion
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(draft.model == suggestion ? .white : WJTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(draft.model == suggestion ? WJTheme.accent.opacity(0.85) : WJTheme.surface)
                    )
                    .accessibilityLabel("Modell \(suggestion) wählen")
                }
            }
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Anweisungen (workerspezifisch)")
            TextEditor(text: $draft.instructions)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 110)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                .accessibilityLabel("Workerspezifische Anweisungen")
        }
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
