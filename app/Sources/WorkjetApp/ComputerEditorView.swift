import SwiftUI
import WorkjetCore

struct ComputerEditorView: View {
    @EnvironmentObject private var model: WorkjetViewModel

    let computer: Computer?
    let onClose: () -> Void

    @State private var draft: ComputerDraft
    @State private var workingComputer: Computer?
    @State private var isDeploying = false
    @State private var deploymentStatus: DeploymentStatus
    @State private var deploymentDetail: String
    @State private var manualTailscaleHost = false
    @State private var selectedDeviceID: String?

    init(computer: Computer?, onClose: @escaping () -> Void) {
        self.computer = computer
        self.onClose = onClose
        _draft = State(initialValue: ComputerDraft(computer: computer))
        _workingComputer = State(initialValue: computer)
        _deploymentStatus = State(initialValue: computer?.deploymentStatus ?? .notConfigured)
        _deploymentDetail = State(initialValue: computer?.deploymentDetail ?? "Noch nicht geprüft.")
        _manualTailscaleHost = State(initialValue: computer?.transport == .tailscale && !(computer?.host.isEmpty ?? true))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            WJDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    transportSection
                    connectionSection
                    Toggle("Minimal-Sandbox", isOn: $draft.sandboxEnabled).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    Toggle("Aktivitätsdetails für diesen Computer", isOn: $draft.telemetryEnabled).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    setupSection
                    technicalDetails
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
            }
        }
        .onAppear {
            if draft.transport == .tailscale { model.refreshTailscaleDevices() }
        }
    }

    private var header: some View {
        HStack {
            Text(computer == nil ? "Computer einrichten" : "Computer bearbeiten")
                .font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Speichern") {
                if let saved = draft.applied(to: workingComputer) {
                    model.upsertComputer(saved)
                    Task { await model.flushPersistence(); onClose() }
                }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(!draft.isValid || computer?.isLocal == true)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(WJIconButtonStyle()).accessibilityLabel("Schließen ohne Speichern")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Verbindung")
            HStack(spacing: 8) {
                WJChoiceButton(title: "Tailscale", isSelected: draft.transport == .tailscale) {
                    draft.transport = .tailscale
                    model.refreshTailscaleDevices()
                }
                WJChoiceButton(title: "SSH", isSelected: draft.transport == .ssh) { draft.transport = .ssh }
            }
        }
    }

    @ViewBuilder private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            WJSectionHeader(title: draft.transport == .tailscale ? "Tailscale-Gerät" : "SSH-Ziel")
            if draft.transport == .tailscale {
                tailscalePicker
            } else {
                field(label: "Name", placeholder: "z. B. devbox", text: $draft.name)
                field(label: "Host", placeholder: "devbox.example.test", text: $draft.host)
            }
            field(label: "SSH-Benutzer", placeholder: "z. B. workjet", text: $draft.user)
        }
    }

    private var tailscalePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(model.tailscaleLoading ? "Geräte werden geladen …" : "Gerät auswählen")
                    .font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText)
                Spacer()
                Button("Aktualisieren") { model.refreshTailscaleDevices() }
                    .buttonStyle(.bordered).controlSize(.mini).disabled(model.tailscaleLoading)
            }
            if let error = model.tailscaleError {
                Text(error).font(.system(size: 10)).foregroundStyle(WJTheme.quotaCritical)
            }
            if !manualTailscaleHost {
                VStack(spacing: 0) {
                    ForEach(model.tailscaleDevices) { device in
                        Button {
                            selectedDeviceID = device.id
                            draft.host = device.preferredHost
                            draft.name = device.hostname
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.hostname).font(.system(size: 12, weight: selectedDeviceID == device.id ? .semibold : .regular))
                                    Text([device.dnsName, device.ipv4, device.os].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 9)).foregroundStyle(WJTheme.secondaryText).lineLimit(1)
                                }
                                Spacer()
                                Text(device.online ? "Online" : "Offline")
                                    .font(.system(size: 10)).foregroundStyle(device.online ? WJTheme.quotaOK : WJTheme.tertiaryText)
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                        if device.id != model.tailscaleDevices.last?.id { WJDivider() }
                    }
                }
                if model.tailscaleDevices.isEmpty && !model.tailscaleLoading && model.tailscaleError == nil {
                    Text("Keine entfernten Tailscale-Geräte gefunden.").font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText)
                }
            } else {
                field(label: "Name", placeholder: "z. B. devbox", text: $draft.name)
                field(label: "Host", placeholder: "host.tailnet.ts.net", text: $draft.host)
            }
            Button(manualTailscaleHost ? "Zur Geräteliste" : "Host manuell eingeben") {
                manualTailscaleHost.toggle()
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(WJTheme.accent)
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            WJSectionHeader(title: "Setup")
            HStack(spacing: 7) {
                Text(deploymentStatus.rawValue).font(.system(size: 11, weight: .semibold))
                if isDeploying { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Prüfen & einrichten") { deploy() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!draft.isDeployable || isDeploying || computer?.isLocal == true)
            }
            Text(draft.isDeployable ? deploymentDetail : missingDeploymentRequirements)
                .font(.system(size: 10)).foregroundStyle(draft.isDeployable ? WJTheme.secondaryText : WJTheme.quotaWarning)
        }
    }

    private var missingDeploymentRequirements: String {
        var missing: [String] = []
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("Name oder Geräteauswahl") }
        if draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("Host oder Tailscale-Gerät") }
        if draft.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("SSH-Benutzer") }
        if draft.sidecarBundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("auditiertes Bundle unter Technische Details") }
        if draft.transport == .ssh && draft.knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("private known-hosts-Datei unter Technische Details") }
        if !(1...65535).contains(draft.port) { missing.append("gültiger Port") }
        return "Für „Prüfen & einrichten“ fehlt: \(missing.joined(separator: ", "))."
    }

    private var technicalDetails: some View {
        DisclosureGroup("Technische Details") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Port").font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).frame(width: 90, alignment: .leading)
                    TextField("22", value: $draft.port, format: .number).textFieldStyle(.plain).fieldSurface()
                }
                if draft.transport == .ssh {
                    field(label: "Known hosts", placeholder: "/Users/…/.ssh/workjet_known_hosts", text: $draft.knownHostsPath)
                    Text("Strikte Host-Key-Prüfung bleibt aktiv; Aufnahme und Freigabe erfolgen außerhalb von Workjet.")
                        .font(.system(size: 9)).foregroundStyle(WJTheme.secondaryText)
                }
                field(label: "Bundle", placeholder: "/absoluter/Pfad/ctox-pi-sidecar.mjs", text: $draft.sidecarBundlePath)
                Text("Pi-Code-Runtime \(PiSidecarRuntime.version). Workjet überträgt nur das auditierte Bundle, den Turn-Runner und das Manifest und installiert keine Pakete.")
                    .font(.system(size: 9)).foregroundStyle(WJTheme.secondaryText)
                if let current = model.computer(for: draft.id), let hash = current.installedContentHash {
                    Text("Inhalt \(hash) · Version \(current.installedSidecarVersion ?? "unbekannt")")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(WJTheme.tertiaryText).textSelection(.enabled)
                }
            }.padding(.top, 6)
        }.font(.system(size: 11))
    }

    private func deploy() {
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

    private func field(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(WJTheme.secondaryText).frame(width: 90, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 13)).fieldSurface()
        }
    }
}

private extension View {
    func fieldSurface() -> some View {
        padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
    }
}
