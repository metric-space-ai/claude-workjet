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
    @State private var remoteSetupIssue: RemoteSetupIssue?
    @State private var manualTailscaleHost = false
    @State private var selectedDeviceID: String?
    @State private var validationMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var pendingHostKey: RemoteHostKeyCandidate?
    @State private var isScanningHostKey = false
    @State private var persistenceOperationInFlight = false
    @State private var reusedConnectionDefaultsFrom: String?
    @State private var technicalDetailsExpanded = false

    init(computer: Computer?, onClose: @escaping () -> Void) {
        self.computer = computer
        self.onClose = onClose
        _draft = State(initialValue: ComputerDraft(computer: computer))
        _workingComputer = State(initialValue: computer)
        _deploymentStatus = State(initialValue: computer?.deploymentStatus ?? .notConfigured)
        _deploymentDetail = State(initialValue: computer?.deploymentDetail ?? "Noch nicht geprüft.")
        _remoteSetupIssue = State(initialValue: computer?.remoteSetupIssue)
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
                    draft.tailscaleSSHEnabled = true
                    draft.port = 22
                    draft.identityFilePath = ""
                    pendingHostKey = nil
                    remoteSetupIssue = nil
                    model.refreshTailscaleDevices()
                }
                WJChoiceButton(title: "SSH", isSelected: draft.transport == .ssh) {
                    draft.transport = .ssh
                    draft.tailscaleSSHEnabled = false
                    pendingHostKey = nil
                    remoteSetupIssue = nil
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
            if usesManagedTailscaleSSH {
                field(
                    label: "Linux-Konto",
                    placeholder: "z. B. deck",
                    text: $draft.user,
                    accessibilityIdentifier: "computer.tailscale.user"
                )
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(WJTheme.accent)
                    Text("Tailscale übernimmt Schlüssel und Geräteidentität. Linux benötigt trotzdem ein vorhandenes Zielkonto; Workjet übernimmt es nicht von einem anderen Computer.")
                        .font(.system(size: 10))
                        .foregroundStyle(WJTheme.secondaryText)
                        .accessibilityIdentifier("computer.tailscale.account.help")
                }
            } else {
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
            }
            if let reusedConnectionDefaultsFrom, !usesManagedTailscaleSSH {
                Text("Die SSH-Voreinstellungen wurden von „\(reusedConnectionDefaultsFrom)“ übernommen. Du kannst sie ändern.")
                    .font(.system(size: 9))
                    .foregroundStyle(WJTheme.secondaryText)
            }
            if draft.transport == .tailscale && !usesManagedTailscaleSSH {
                HStack {
                    Text("Bestehende Verbindung: OpenSSH über den Tailscale-Netzpfad.")
                        .font(.system(size: 9))
                        .foregroundStyle(WJTheme.secondaryText)
                    Spacer()
                    Button("Auf Tailscale SSH umstellen") { convertToManagedTailscaleSSH() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
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
                            remoteSetupIssue = nil
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
                        .accessibilityIdentifier("computer.deployment.status")
                    if isDeploying { ProgressView().controlSize(.mini) }
                }
                if !deploymentDetail.isEmpty {
                    if tailscaleRecovery != nil {
                        tailscaleRecoveryPanel
                    } else {
                        Text(deploymentDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(deploymentStatus == .failed || deploymentStatus == .blocked ? WJTheme.quotaCritical : WJTheme.secondaryText)
                            .accessibilityIdentifier("computer.deployment.detail")
                    }
                }
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.quotaCritical)
                    .accessibilityIdentifier("computer.editor.inline.error")
            }
            if !usesManagedTailscaleSSH && (draft.transport == .ssh || draft.transport == .tailscale) {
                hostKeyOnboarding
            }
            if pendingHostKey == nil {
                Button(primarySetupButtonTitle) {
                    if usesManagedTailscaleSSH { deploy() }
                    else { scanHostKey() }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .disabled(isScanningHostKey || isDeploying || persistenceOperationInFlight || computer?.isLocal == true)
                    .accessibilityIdentifier(usesManagedTailscaleSSH ? "computer.tailscale.setup" : "computer.ssh-host-key.scan")
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
        DisclosureGroup("Technische Details", isExpanded: $technicalDetailsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Port").font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).frame(width: 90, alignment: .leading)
                    if usesManagedTailscaleSSH {
                        Text("22 · von Tailscale SSH vorgegeben")
                            .font(.system(size: 11))
                            .foregroundStyle(WJTheme.secondaryText)
                    } else {
                        TextField("22", value: $draft.port, format: .number).textFieldStyle(.plain).fieldSurface()
                    }
                }
                if !usesManagedTailscaleSSH && (draft.transport == .ssh || draft.transport == .tailscale) {
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
        remoteSetupIssue = nil
        Task {
            var deployed = await model.bootstrapRemoteComputer(saved)
            workingComputer = deployed
            draft = ComputerDraft(computer: deployed)
            deploymentStatus = deployed.deploymentStatus
            deploymentDetail = deployed.deploymentDetail
            remoteSetupIssue = deployed.remoteSetupIssue
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
                    remoteSetupIssue = nil
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
                remoteSetupIssue = nil
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
           !usesManagedTailscaleSSH,
           let template = preferredRemoteDefaults {
            if draft.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.user = template.user
            }
            if draft.identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.identityFilePath = template.identityFilePath
            }
            reusedConnectionDefaultsFrom = template.name
        }
        if !usesManagedTailscaleSSH,
           draft.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        guard !usesManagedTailscaleSSH else { return }
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
                remoteSetupIssue = error.remoteSetupIssue
            } catch {
                deploymentStatus = .failed
                deploymentDetail = error.localizedDescription
                remoteSetupIssue = nil
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
        saved.remoteSetupIssue = remoteSetupIssue
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
        // UI tests may inject a disposable fixture outside protected user
        // folders. Production and normal debug runs only use the embedded
        // release input and never probe ~/Documents for developer artifacts.
        let environment = ProcessInfo.processInfo.environment
        let uiTestFixture = environment["WORKJET_UI_TEST_WINDOW"] == "1"
            ? environment["WORKJET_UI_TEST_SIDECAR_PATH"].map(URL.init(fileURLWithPath:))
            : nil
        return [bundled, uiTestFixture]
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

    private func convertToManagedTailscaleSSH() {
        draft.tailscaleSSHEnabled = true
        draft.port = 22
        draft.identityFilePath = ""
        draft.knownHostsPath = ""
        pendingHostKey = nil
        validationMessage = nil
        deploymentStatus = .notConfigured
        deploymentDetail = "Tailscale übernimmt die Verbindung; richte den Computer erneut ein."
        remoteSetupIssue = nil
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
        if draft.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return usesManagedTailscaleSSH
                ? "Gib das Linux-Konto auf diesem Zielcomputer ein. Tailscale authentifiziert die Verbindung, ersetzt aber kein lokales Linux-Konto."
                : "Gib den SSH-Benutzer dieses Computers ein."
        }
        if !(1...65535).contains(draft.port) { return "Der SSH-Port muss zwischen 1 und 65535 liegen." }
        return nil
    }

    private func validationMessageForDeployment() -> String? {
        if let message = validationMessageForSave() { return message }
        if selectedTailscaleDeviceIsOffline { return "Dieser Computer ist offline. Wähle einen erreichbaren Computer." }
        if draft.sidecarBundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Die Pi-Code-Komponente fehlt in dieser Workjet-App."
        }
        if !usesManagedTailscaleSSH,
           draft.knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Bestätige zuerst die Identität dieses Computers."
        }
        return nil
    }

    private var usesManagedTailscaleSSH: Bool {
        draft.transport == .tailscale && draft.tailscaleSSHEnabled
    }

    private var primarySetupButtonTitle: String {
        if isDeploying { return "Einrichtung läuft …" }
        if usesManagedTailscaleSSH {
            return deploymentStatus == .blocked || deploymentStatus == .failed
                ? "Erneut prüfen & einrichten"
                : "Über Tailscale einrichten"
        }
        return isScanningHostKey ? "Verbindung wird geprüft …" : "Identität prüfen & einrichten"
    }

    private struct TailscaleRecovery {
        enum Action {
            case openTailscale
            case showLinuxAccount
            case openDownload
        }

        let title: String
        let explanation: String
        let steps: [String]
        let command: String?
        let action: Action?
    }

    private var tailscaleRecovery: TailscaleRecovery? {
        guard usesManagedTailscaleSSH, let remoteSetupIssue else { return nil }
        let target = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? draft.host
            : draft.name
        switch remoteSetupIssue {
        case .tailscaleSSHNotEnabled:
            return TailscaleRecovery(
                title: "Tailscale SSH fehlt auf \(target)",
                explanation: "Workjet sieht den Computer im Tailnet, darf dort aber noch keine Befehle ausführen.",
                steps: [
                    "Öffne direkt auf \(target) ein Terminal.",
                    "Aktiviere dort Tailscale SSH mit dem unten stehenden Befehl. Dafür sind Adminrechte auf dem Zielcomputer erforderlich.",
                    "Klicke danach auf „Erneut prüfen & einrichten“. Workjet installiert Pi Code, Harness und ausgewählte Skills anschließend selbst."
                ],
                command: "sudo tailscale set --ssh",
                action: nil
            )
        case .tailscaleAccessDenied:
            return TailscaleRecovery(
                title: "\(draft.user)@\(target) wurde abgelehnt",
                explanation: "Tailscale SSH hat genau diese Anmeldung abgelehnt. Netzwerk und Computer sind erreichbar; Workjet hat den Benutzer nicht erfolgreich angemeldet.",
                steps: [
                    "Ändere oben „Linux-Konto“, falls auf \(target) ein anderer Benutzer verwendet wird.",
                    "Falls „\(draft.user)“ korrekt ist: Prüfe, dass das Konto existiert und die Tailscale-SSH-Policy genau diesen Zugriff erlaubt.",
                    "Klicke danach auf „Erneut prüfen & einrichten“."
                ],
                command: "id \(draft.user)",
                action: nil
            )
        case .tailscaleNotInstalled:
            return TailscaleRecovery(
                title: "Tailscale fehlt auf diesem Mac",
                explanation: "Workjet benötigt die lokale Tailscale-App, um Geräte zu finden und die Verbindung aufzubauen.",
                steps: [
                    "Installiere Tailscale auf diesem Mac.",
                    "Melde diesen Mac im gleichen Tailnet wie den Zielcomputer an.",
                    "Öffne Workjet erneut und aktualisiere die Geräteliste."
                ],
                command: nil,
                action: .openDownload
            )
        case .tailscaleAppUnavailable:
            return TailscaleRecovery(
                title: "Tailscale ist auf diesem Mac nicht bereit",
                explanation: "Die App ist installiert, antwortet Workjet aber momentan nicht.",
                steps: [
                    "Öffne Tailscale und prüfe, dass „Verbunden“ angezeigt wird.",
                    "Kehre zu Workjet zurück und klicke auf „Erneut prüfen & einrichten“."
                ],
                command: nil,
                action: .openTailscale
            )
        case .tailscaleClientUnsupported:
            return TailscaleRecovery(
                title: "Diese Tailscale-Version unterstützt den benötigten Zugriff nicht",
                explanation: "Workjet braucht eine Tailscale-Installation, die den Befehl `tailscale ssh` bereitstellt.",
                steps: [
                    "Installiere die aktuelle Standalone-Version von Tailscale.",
                    "Verbinde sie mit deinem Tailnet und versuche die Einrichtung erneut."
                ],
                command: nil,
                action: .openDownload
            )
        case .tailscalePortInvalid:
            return TailscaleRecovery(
                title: "Tailscale SSH verwendet Port 22",
                explanation: "Für einen anderen Port muss der Verbindungstyp „SSH“ verwendet werden.",
                steps: ["Öffne die technischen Details oder wechsle oben zu „SSH“."],
                command: nil,
                action: .showLinuxAccount
            )
        }
    }

    @ViewBuilder private var tailscaleRecoveryPanel: some View {
        if let recovery = tailscaleRecovery {
            VStack(alignment: .leading, spacing: 9) {
                Text(recovery.title)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityIdentifier("computer.tailscale.recovery.title")
                Text(recovery.explanation)
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("computer.deployment.detail")
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(recovery.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 7) {
                            Text("\(index + 1).")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(WJTheme.secondaryText)
                                .frame(width: 16, alignment: .trailing)
                            Text(step)
                                .font(.system(size: 10))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let command = recovery.command {
                    Text(command)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(WJTheme.background))
                        .accessibilityIdentifier("computer.tailscale.recovery-command")
                }
                HStack(spacing: 8) {
                    if let command = recovery.command {
                        Button("Befehl kopieren") { copyToPasteboard(command) }
                            .accessibilityIdentifier("computer.tailscale.copy-activation-command")
                    }
                    if let action = recovery.action {
                        recoveryButton(for: action)
                    }
                    Link("Tailscale-Anleitung", destination: URL(string: "https://tailscale.com/docs/features/tailscale-ssh")!)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(WJTheme.divider, lineWidth: 1))
        }
    }

    @ViewBuilder private func recoveryButton(for action: TailscaleRecovery.Action) -> some View {
        switch action {
        case .openTailscale:
            Button("Tailscale öffnen") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
            }
        case .showLinuxAccount:
            Button("Linux-Konto anzeigen") { technicalDetailsExpanded = true }
        case .openDownload:
            Link("Tailscale laden", destination: URL(string: "https://tailscale.com/download/mac")!)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @ViewBuilder
    private func field(
        label: String,
        placeholder: String,
        text: Binding<String>,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(WJTheme.secondaryText).frame(width: 90, alignment: .leading)
            if let accessibilityIdentifier {
                TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 13)).fieldSurface()
                    .onChange(of: text.wrappedValue) { validationMessage = nil }
                    .accessibilityIdentifier(accessibilityIdentifier)
            } else {
                TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 13)).fieldSurface()
                    .onChange(of: text.wrappedValue) { validationMessage = nil }
            }
        }
    }
}

private extension View {
    func fieldSurface() -> some View {
        padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WJTheme.surface))
    }
}
