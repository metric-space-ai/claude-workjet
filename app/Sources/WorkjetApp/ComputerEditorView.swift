import SwiftUI
import WorkjetCore

/// Computer setup editor, opened by the header `+` (and from Settings for
/// edits). Tailscale vs SSH as direct buttons, connection fields, minimal
/// sandbox, pinned Pi sidecar version, telemetry setup.
struct ComputerEditorView: View {
    @EnvironmentObject private var model: WorkjetViewModel

    let computer: Computer?
    let onClose: () -> Void

    @State private var draft: ComputerDraft

    init(computer: Computer?, onClose: @escaping () -> Void) {
        self.computer = computer
        self.onClose = onClose
        _draft = State(initialValue: ComputerDraft(computer: computer))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            WJDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    transportSection
                    connectionSection
                    sandboxSection
                    sidecarSection
                    telemetrySection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(computer == nil ? "Computer einrichten" : "Computer bearbeiten")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Speichern") {
                if let saved = draft.applied(to: computer) {
                    model.upsertComputer(saved)
                    onClose()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!draft.isValid)
            .accessibilityLabel("Computer speichern")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(WJIconButtonStyle())
            .accessibilityLabel("Schließen ohne Speichern")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Verbindung")
            HStack(spacing: 8) {
                WJChoiceButton(
                    title: ComputerTransport.tailscale.rawValue,
                    isSelected: draft.transport == .tailscale,
                    accessibilityLabel: "Verbindung über Tailscale"
                ) {
                    draft.transport = .tailscale
                }
                WJChoiceButton(
                    title: ComputerTransport.ssh.rawValue,
                    isSelected: draft.transport == .ssh,
                    accessibilityLabel: "Verbindung über SSH"
                ) {
                    draft.transport = .ssh
                }
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            WJSectionHeader(title: "Zugang")
            field(label: "Name", placeholder: "z. B. devbox", text: $draft.name,
                  accessibility: "Name des Computers")
            field(label: draft.transport == .tailscale ? "Tailscale-Host" : "Host",
                  placeholder: draft.transport == .tailscale ? "host.tailnet.ts.net" : "192.168.1.10",
                  text: $draft.host,
                  accessibility: "Hostname oder IP-Adresse")
            field(label: "Benutzer", placeholder: "z. B. mw", text: $draft.user,
                  accessibility: "SSH-Benutzername")
            HStack(spacing: 8) {
                Text("Port")
                    .font(.system(size: 12))
                    .foregroundStyle(WJTheme.secondaryText)
                    .frame(width: 88, alignment: .leading)
                TextField("22", value: $draft.port, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                    .accessibilityLabel("SSH-Port")
            }
        }
    }

    private var sandboxSection: some View {
        Toggle(isOn: $draft.sandboxEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Minimal-Sandbox")
                    .font(.system(size: 13))
                Text("Worker laufen eingeschränkt; nur der Arbeitsordner ist schreibbar.")
                    .font(.system(size: 11))
                    .foregroundStyle(WJTheme.secondaryText)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel("Minimal-Sandbox aktivieren")
    }

    private var sidecarSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Pi Sidecar (gepinnte Version)")
            field(label: "Version", placeholder: "z. B. 0.4.2", text: $draft.pinnedSidecarVersion,
                  accessibility: "Gepinnte Pi-Sidecar-Version")
            Text("Remote-Worker auf diesem Computer nutzen exakt diese Sidecar-Version.")
                .font(.system(size: 11))
                .foregroundStyle(WJTheme.secondaryText)
        }
    }

    private var telemetrySection: some View {
        Toggle(isOn: $draft.telemetryEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Telemetrie einrichten")
                    .font(.system(size: 13))
                Text("Pi-Sidecar-Socket-Events dieses Computers an Workjet melden.")
                    .font(.system(size: 11))
                    .foregroundStyle(WJTheme.secondaryText)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel("Telemetrie für diesen Computer einrichten")
    }

    private func field(label: String, placeholder: String, text: Binding<String>, accessibility: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(WJTheme.secondaryText)
                .frame(width: 88, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
                .accessibilityLabel(accessibility)
        }
    }
}
