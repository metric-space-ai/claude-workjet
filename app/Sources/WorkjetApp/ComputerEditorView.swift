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
    @State private var workingComputer: Computer?
    @State private var isDeploying = false
    @State private var deploymentStatus: DeploymentStatus
    @State private var deploymentDetail: String

    init(computer: Computer?, onClose: @escaping () -> Void) {
        self.computer = computer
        self.onClose = onClose
        _draft = State(initialValue: ComputerDraft(computer: computer))
        _workingComputer = State(initialValue: computer)
        _deploymentStatus = State(initialValue: computer?.deploymentStatus ?? .notConfigured)
        _deploymentDetail = State(initialValue: computer?.deploymentDetail ?? "Noch nicht geprüft.")
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
            Button("Prüfen & einrichten") {
                guard let saved = draft.applied(to: workingComputer), draft.isDeployable else { return }
                isDeploying = true
                deploymentStatus = .checking
                deploymentDetail = "Prüfung läuft …"
                Task {
                    let deployed = await model.bootstrapRemoteComputer(saved)
                    workingComputer = deployed
                    draft = ComputerDraft(computer: deployed)
                    deploymentStatus = deployed.deploymentStatus
                    deploymentDetail = deployed.deploymentDetail
                    isDeploying = false
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!draft.isDeployable || isDeploying || computer?.isLocal == true)
            .accessibilityLabel("Remote-Computer prüfen und Pi-Sidecar einrichten")
            Button("Speichern") {
                if let saved = draft.applied(to: workingComputer) {
                    model.upsertComputer(saved)
                    Task { await model.flushPersistence(); onClose() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!draft.isValid || computer?.isLocal == true)
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
            if draft.transport == .ssh {
                field(label: "Known hosts", placeholder: "/Users/…/.ssh/workjet_known_hosts", text: $draft.knownHostsPath,
                      accessibility: "Private known-hosts-Datei")
                Text("Host-Key-Aufnahme und -Freigabe erfolgen außerhalb von Workjet. Strikte Prüfung bleibt immer aktiv.")
                    .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
            }
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
        VStack(alignment: .leading, spacing: 7) {
            WJSectionHeader(title: "Pi Sidecar (gepinnte Version \(PiSidecarRuntime.version))")
            field(label: "Bundle", placeholder: "/absoluter/Pfad/ctox-pi-sidecar.mjs", text: $draft.sidecarBundlePath,
                  accessibility: "Lokaler Pfad zum auditierten Pi-Sidecar-Bundle")
            HStack(spacing: 7) {
                Circle().fill(deploymentColor).frame(width: 7, height: 7)
                Text(deploymentStatus.rawValue).font(.system(size: 11, weight: .semibold))
                if isDeploying { ProgressView().controlSize(.mini) }
            }
            Text(deploymentDetail).font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText).lineLimit(4)
            if let current = model.computer(for: draft.id), let hash = current.installedContentHash {
                Text("Installierter Inhalt: \(hash) · Version \(current.installedSidecarVersion ?? "unbekannt")")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(WJTheme.tertiaryText).textSelection(.enabled)
            }
            Text("Es werden nur Bundle, generierter Turn-Runner und Manifest übertragen. Node >=20 wird vorausgesetzt; Workjet installiert keine Pakete. Echtmodell-Inferenz bleibt ohne separaten Loopback-Relay nicht verfügbar.")
                .font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
        }
    }

    private var deploymentColor: Color {
        switch deploymentStatus {
        case .installed: return WJTheme.quotaOK
        case .checking: return WJTheme.quotaWarning
        case .blocked, .failed: return WJTheme.quotaCritical
        case .notConfigured: return WJTheme.tertiaryText
        }
    }

    private var telemetrySection: some View {
        Toggle(isOn: $draft.telemetryEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Telemetrie einrichten")
                    .font(.system(size: 13))
                Text("Pi-Ereignisse aus der finalen Antwort post-hoc erfassen; keine Live-Events.")
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
