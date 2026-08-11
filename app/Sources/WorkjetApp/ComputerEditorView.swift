import AppKit
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
    @State private var validationMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var pendingHostKey: RemoteHostKeyCandidate?
    @State private var isScanningHostKey = false
    @State private var persistenceOperationInFlight = false
    @State private var reusedConnectionDefaultsFrom: String?

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
            prepareDefaults()
            if draft.transport == .tailscale { model.refreshTailscaleDevices() }
        }
        .onChange(of: model.tailscaleDevices) { _, devices in
            restoreTailscaleSelection(from: devices)
        }
        .alert("Computer löschen?", isPresented: $showDeleteConfirmation) {
            Button("Abbrechen", role: .cancel) {}
            Button("Löschen", role: .destructive) { deleteComputer() }
                .disabled(persistenceOperationInFlight || isDeploying)
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    private var header: some View {
        HStack {
            Text(computer == nil ? "Computer einrichten" : "Computer bearbeiten")
                .font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            if computer != nil {
                Button("Löschen", role: .destructive) { showDeleteConfirmation = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(persistenceOperationInFlight || isDeploying)
                Button(persistenceOperationInFlight ? "Wird gespeichert …" : "Speichern") { saveAndClose() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(computer?.isLocal == true || persistenceOperationInFlight || isDeploying)
            } else if deploymentStatus == .failed || deploymentStatus == .blocked {
                Button(persistenceOperationInFlight ? "Wird gespeichert …" : "Für später speichern") { saveConnectionForLater() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(persistenceOperationInFlight || isDeploying)
            }
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(WJIconButtonStyle())
                .disabled(persistenceOperationInFlight || isDeploying)
                .accessibilityLabel("Schließen ohne Speichern")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Verbindung")
            HStack(spacing: 8) {
                WJChoiceButton(title: "Tailscale", isSelected: draft.transport == .tailscale) {
                    draft.transport = .tailscale
                    pendingHostKey = nil
                    prepareKnownHostsDefault()
                    model.refreshTailscaleDevices()
                }
                WJChoiceButton(title: "SSH", isSelected: draft.transport == .ssh) {
                    draft.transport = .ssh
                    pendingHostKey = nil
                    prepareKnownHostsDefault()
                }
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
            HStack(spacing: 8) {
                Text("SSH-Schlüssel").font(.system(size: 12)).foregroundStyle(WJTheme.secondaryText).frame(width: 90, alignment: .leading)
                Text(draft.identityFilePath.isEmpty ? "Automatisch" : URL(fileURLWithPath: draft.identityFilePath).lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(draft.identityFilePath.isEmpty ? WJTheme.secondaryText : .primary)
                    .lineLimit(1)
                Spacer()
                if !draft.identityFilePath.isEmpty {
                    Button("Zurücksetzen") { draft.identityFilePath = "" }.buttonStyle(.bordered).controlSize(.mini)
                }
                Button("Wählen …") { chooseIdentityFile() }.buttonStyle(.bordered).controlSize(.mini)
            }
            if let reusedConnectionDefaultsFrom {
                Text("Die SSH-Voreinstellungen wurden von „\(reusedConnectionDefaultsFrom)“ übernommen. Du kannst sie ändern.")
                    .font(.system(size: 9))
                    .foregroundStyle(WJTheme.secondaryText)
            }
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
                            guard device.online else { return }
                            validationMessage = nil
                            selectedDeviceID = device.id
                            draft.host = device.preferredHost
                            draft.name = device.hostname
                            pendingHostKey = nil
                            prepareKnownHostsDefault()
                            if draft.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                draft.user = NSUserName()
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.hostname).font(.system(size: 12, weight: selectedDeviceID == device.id ? .semibold : .regular))
                                    Text([device.dnsName, device.ipv4, device.os].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 9)).foregroundStyle(WJTheme.secondaryText).lineLimit(1)
                                }
                                Spacer()
                                if selectedDeviceID == device.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(WJTheme.accent)
                                }
                                Text(device.online ? "Online" : "Offline")
                                    .font(.system(size: 10)).foregroundStyle(device.online ? WJTheme.quotaOK : WJTheme.tertiaryText)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(selectedDeviceID == device.id ? WJTheme.accent.opacity(0.14) : .clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(selectedDeviceID == device.id ? WJTheme.accent.opacity(0.7) : .clear, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!device.online)
                        .opacity(device.online ? 1 : 0.55)
                        .accessibilityAddTraits(selectedDeviceID == device.id ? .isSelected : [])
                        .accessibilityLabel("\(device.hostname), \(device.online ? "online" : "offline")")
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
            if deploymentStatus != .notConfigured || isDeploying {
                HStack(spacing: 7) {
                    Text(deploymentStatus.rawValue).font(.system(size: 11, weight: .semibold))
                    if isDeploying { ProgressView().controlSize(.mini) }
                }
                if !deploymentDetail.isEmpty {
                    Text(deploymentDetail)
                        .font(.system(size: 10))
                        .foregroundStyle(deploymentStatus == .failed || deploymentStatus == .blocked ? WJTheme.quotaCritical : WJTheme.secondaryText)
                }
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.quotaCritical)
                    .accessibilityIdentifier("computer.editor.inline.error")
            }
            if draft.transport == .ssh || draft.transport == .tailscale {
                hostKeyOnboarding
            }
            if pendingHostKey == nil {
                Button(isScanningHostKey ? "Verbindung wird geprüft …" : "Identität prüfen & einrichten") { scanHostKey() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .disabled(isScanningHostKey || isDeploying || persistenceOperationInFlight || computer?.isLocal == true)
                    .accessibilityIdentifier("computer.ssh-host-key.scan")
            }
        }
    }

    @ViewBuilder private var hostKeyOnboarding: some View {
        if let pendingHostKey {
            VStack(alignment: .leading, spacing: 6) {
                Text("Verbindung bestätigen")
                    .font(.system(size: 11, weight: .semibold))
                Text("Vergleiche den Fingerabdruck mit dem Ziel-Computer. Erst danach speichert Workjet die Verbindung.")
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.secondaryText)
                Text(pendingHostKey.fingerprint)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("computer.ssh-host-key.fingerprint")
                HStack {
                    Button("Abbrechen") { self.pendingHostKey = nil }
                        .buttonStyle(.bordered)
                    Button("Bestätigen & einrichten") { confirmHostKey(pendingHostKey) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("computer.ssh-host-key.confirm")
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
        } else {
            Text("Workjet prüft zuerst die Identität des Ziel-Computers. Remote-Zugriff und Host-Key werden erst nach deiner Bestätigung eingerichtet; eine nicht erreichbare Verbindung kannst du für später speichern.")
                .font(.system(size: 10))
                .foregroundStyle(WJTheme.secondaryText)
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup("Technische Details") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Port").font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).frame(width: 90, alignment: .leading)
                    TextField("22", value: $draft.port, format: .number).textFieldStyle(.plain).fieldSurface()
                }
                if draft.transport == .ssh || draft.transport == .tailscale {
                    field(label: "Known hosts", placeholder: "/Users/…/.ssh/workjet_known_hosts", text: $draft.knownHostsPath)
                    Text("Workjet akzeptiert nur den ausdrücklich bestätigten Schlüssel dieses Computers.")
                        .font(.system(size: 9)).foregroundStyle(WJTheme.secondaryText)
                }
                Text("Pi Code \(PiSidecarRuntime.version) ist in Workjet enthalten.")
                    .font(.system(size: 9)).foregroundStyle(WJTheme.secondaryText)
                if let current = model.computer(for: draft.id), let hash = current.installedContentHash {
                    Text("Inhalt \(hash) · Version \(current.installedSidecarVersion ?? "unbekannt")")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(WJTheme.tertiaryText).textSelection(.enabled)
                }
            }.padding(.top, 6)
        }.font(.system(size: 11))
    }

    private func deploy() {
        guard !isDeploying, !persistenceOperationInFlight else { return }
        validationMessage = validationMessageForDeployment()
        guard validationMessage == nil,
              let saved = draft.applied(to: workingComputer),
              draft.isDeployable else { return }
        isDeploying = true
        deploymentStatus = .checking
        deploymentDetail = "Prüfung läuft …"
        Task {
            var deployed = await model.bootstrapRemoteComputer(saved)
            workingComputer = deployed
            draft = ComputerDraft(computer: deployed)
            deploymentStatus = deployed.deploymentStatus
            deploymentDetail = deployed.deploymentDetail
            guard deployed.deploymentStatus == .installed else {
                isDeploying = false
                return
            }

            let assignedCount = model.workers.filter { $0.computerID == deployed.id }.count
            if assignedCount > 0 {
                deploymentStatus = .checking
                deploymentDetail = assignedCount == 1 ? "Worker-Abhängigkeiten werden eingerichtet …" : "Abhängigkeiten für \(assignedCount) Worker werden eingerichtet …"
                let provisioning = await model.provisionConfiguredWorkers(on: deployed)
                if let failure = provisioning.failure {
                    deploymentStatus = .failed
                    deploymentDetail = "Worker sind nicht bereit. \(failure.userVisibleDetail)"
                    validationMessage = deploymentDetail
                    isDeploying = false
                    return
                }
                deployed.deploymentDetail = assignedCount == 1
                    ? "Remote-Computer und 1 zugewiesener Worker sind eingerichtet."
                    : "Remote-Computer und \(assignedCount) zugewiesene Worker sind eingerichtet."
                workingComputer = deployed
                draft = ComputerDraft(computer: deployed)
                deploymentStatus = .installed
                deploymentDetail = deployed.deploymentDetail
            }

            persistenceOperationInFlight = true
            let result = await model.saveComputerDurably(deployed)
            persistenceOperationInFlight = false
            isDeploying = false
            switch result {
            case .succeeded:
                onClose()
            case let .failed(message):
                validationMessage = message
            }
        }
    }

    private var selectedTailscaleDeviceIsOffline: Bool {
        guard draft.transport == .tailscale, let selectedDeviceID else { return false }
        return model.tailscaleDevices.first(where: { $0.id == selectedDeviceID })?.online == false
    }

    private func prepareDefaults() {
        if computer == nil,
           let template = preferredRemoteDefaults {
            if draft.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.user = template.user
            }
            if draft.identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.identityFilePath = template.identityFilePath
            }
            reusedConnectionDefaultsFrom = template.name
        }
        if draft.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.user = NSUserName()
        }
        if draft.sidecarBundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let bundledSidecarPath {
            draft.sidecarBundlePath = bundledSidecarPath
        }
        if draft.knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prepareKnownHostsDefault()
        }
        restoreTailscaleSelection(from: model.tailscaleDevices)
    }

    private var preferredRemoteDefaults: Computer? {
        ComputerDraft.preferredConnectionDefaults(in: model.computers, transport: draft.transport)
    }

    private func prepareKnownHostsDefault() {
        guard draft.knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft.knownHostsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Workjet/ssh/known_hosts")
            .path
    }

    private func scanHostKey() {
        guard !isScanningHostKey, !isDeploying, !persistenceOperationInFlight else { return }
        validationMessage = validationMessageForSave()
        guard validationMessage == nil, let target = draft.applied(to: workingComputer) else { return }
        isScanningHostKey = true
        deploymentStatus = .checking
        deploymentDetail = "Die Identität des Computers wird geprüft …"
        Task {
            do {
                pendingHostKey = try await model.scanRemoteHostKey(for: target)
                deploymentStatus = .blocked
                deploymentDetail = "Schritt 2: SHA256-Fingerabdruck prüfen und ausdrücklich bestätigen."
            } catch let error as RemotePiBootstrapError {
                deploymentStatus = error.isBlocked ? .blocked : .failed
                deploymentDetail = error.localizedDescription
            } catch {
                deploymentStatus = .failed
                deploymentDetail = error.localizedDescription
            }
            isScanningHostKey = false
        }
    }

    private func saveConnectionForLater() {
        guard computer == nil, !persistenceOperationInFlight, !isDeploying else { return }
        validationMessage = validationMessageForSave()
        guard validationMessage == nil, var saved = draft.applied(to: workingComputer) else { return }
        saved.deploymentStatus = deploymentStatus == .checking ? .notConfigured : deploymentStatus
        saved.deploymentDetail = deploymentDetail.isEmpty ? "Noch nicht eingerichtet." : deploymentDetail
        saved.installedContentHash = nil
        saved.installedSidecarVersion = nil
        persistenceOperationInFlight = true
        Task {
            let result = await model.saveComputerDurably(saved)
            persistenceOperationInFlight = false
            switch result {
            case .succeeded:
                onClose()
            case let .failed(message):
                validationMessage = message
            }
        }
    }

    private func confirmHostKey(_ candidate: RemoteHostKeyCandidate) {
        validationMessage = validationMessageForSave()
        guard validationMessage == nil, let target = draft.applied(to: workingComputer) else { return }
        do {
            try model.confirmRemoteHostKey(candidate, for: target)
            pendingHostKey = nil
            deploymentDetail = "Host-Key wurde bestätigt und privat gespeichert. Einrichtung wird erneut versucht."
            deploy()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private var bundledSidecarPath: String? {
        let bundled = Bundle.main.url(forResource: "ctox-pi-sidecar", withExtension: "mjs")
        #if DEBUG
        let development = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/ctox/src/core/coding_agents/pi-sidecar/dist/ctox-pi-sidecar.mjs")
        return [bundled, development]
            .compactMap { $0 }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }?
            .path
        #else
        // Release builds fail closed: only the embedded, build-time verified
        // sidecar is eligible for deployment to a remote computer.
        return bundled.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? $0.path : nil }
        #endif
    }

    private func restoreTailscaleSelection(from devices: [TailscaleDevice]) {
        guard draft.transport == .tailscale, !draft.host.isEmpty else { return }
        guard let device = devices.first(where: { $0.preferredHost == draft.host || $0.dnsName == draft.host || $0.ipv4 == draft.host }) else { return }
        selectedDeviceID = device.id
        if device.online { draft.host = device.preferredHost }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.title = "SSH-Schlüssel wählen"
        panel.prompt = "Wählen"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.identityFilePath = url.path
        validationMessage = nil
        pendingHostKey = nil
    }

    private func saveAndClose() {
        guard !persistenceOperationInFlight else { return }
        validationMessage = validationMessageForSave()
        guard validationMessage == nil, let saved = draft.applied(to: workingComputer) else { return }
        persistenceOperationInFlight = true
        Task {
            let result = await model.saveComputerDurably(saved)
            persistenceOperationInFlight = false
            switch result {
            case .succeeded:
                onClose()
            case let .failed(message):
                validationMessage = message
            }
        }
    }

    private var deleteConfirmationMessage: String {
        let count = model.workers.filter { $0.computerID == computer?.id }.count
        if count == 0 { return "Die Verbindung wird aus Workjet entfernt." }
        return "Die Verbindung wird entfernt. \(count) Worker werden auf Local verschoben."
    }

    private func deleteComputer() {
        guard !persistenceOperationInFlight, let computer, !computer.isLocal else { return }
        validationMessage = nil
        persistenceOperationInFlight = true
        Task {
            let result = await model.deleteComputerDurably(id: computer.id)
            persistenceOperationInFlight = false
            switch result {
            case .succeeded:
                onClose()
            case let .failed(message):
                validationMessage = message
            }
        }
    }

    private func validationMessageForSave() -> String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Wähle einen Computer oder gib einen Namen ein." }
        if draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Wähle einen Computer oder gib einen Host ein." }
        if draft.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Gib den SSH-Benutzer dieses Computers ein." }
        if !(1...65535).contains(draft.port) { return "Der SSH-Port muss zwischen 1 und 65535 liegen." }
        return nil
    }

    private func validationMessageForDeployment() -> String? {
        if let message = validationMessageForSave() { return message }
        if selectedTailscaleDeviceIsOffline { return "Dieser Computer ist offline. Wähle einen erreichbaren Computer." }
        if draft.sidecarBundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Die Pi-Code-Komponente fehlt in dieser Workjet-App."
        }
        if draft.knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Bestätige zuerst die Identität dieses Computers."
        }
        return nil
    }

    private func field(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(WJTheme.secondaryText).frame(width: 90, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 13)).fieldSurface()
                .onChange(of: text.wrappedValue) { validationMessage = nil }
        }
    }
}

private extension View {
    func fieldSurface() -> some View {
        padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
    }
}
