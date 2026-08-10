import SwiftUI
import WorkjetCore

struct ProviderAccountsView: View {
    @EnvironmentObject private var model: WorkjetViewModel

    var selectedRoute: ProviderRoute? = nil
    var onSelect: ((ProviderRoute?) -> Void)? = nil
    var initiallyOpenProvider: ModelProvider? = nil

    @State private var openAPIProvider: ModelProvider?
    @State private var apiKeys: [ModelProvider: String] = [:]
    @State private var accountNames: [ModelProvider: String] = [:]
    @State private var accountDraft: Provider?
    @State private var accountSecret = ""
    @State private var accountModelsText = ""
    @State private var accountArgumentsText = ""
    @State private var accountSaveError: String?
    @State private var busyAccountID: UUID?
    @State private var showCustomProvider = false
    @State private var customName = ""
    @State private var customEndpoint = ""
    @State private var customAuthentication: ProviderAuthentication = .bearerToken
    @State private var customAPIKey = ""
    @State private var creatingCustomProvider = false
    @State private var pendingDisconnect: Provider?
    @State private var disconnectingAccountID: UUID?
    @State private var disconnectFailure: String?

    init(
        selectedRoute: ProviderRoute? = nil,
        onSelect: ((ProviderRoute?) -> Void)? = nil,
        initiallyOpenProvider: ModelProvider? = nil
    ) {
        self.selectedRoute = selectedRoute
        self.onSelect = onSelect
        self.initiallyOpenProvider = initiallyOpenProvider
        _openAPIProvider = State(initialValue: initiallyOpenProvider)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(ModelProvider.allCases) { provider in
                providerSection(provider)
                WJDivider()
            }
            customProviderSection
        }
        .onAppear {
            if let initiallyOpenProvider {
                if openAPIProvider != initiallyOpenProvider {
                    openAPIProvider = initiallyOpenProvider
                }
                ensureDefaultAccountName(for: initiallyOpenProvider)
            }
        }
        .confirmationDialog(
            "Zugang trennen?",
            isPresented: Binding(
                get: { pendingDisconnect != nil },
                set: { isPresented in
                    if !isPresented, disconnectingAccountID == nil {
                        pendingDisconnect = nil
                        disconnectFailure = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingDisconnect
        ) { account in
            Button("\(account.name) trennen", role: .destructive) {
                disconnectConfirmed(account)
            }
            .disabled(disconnectingAccountID != nil)
            Button("Abbrechen", role: .cancel) {
                pendingDisconnect = nil
                disconnectFailure = nil
            }
            .disabled(disconnectingAccountID != nil)
        } message: { account in
            if let disconnectFailure {
                Text(disconnectFailure)
            } else if disconnectingAccountID == account.id {
                Text("Der Zugang wird dauerhaft aus der Konfiguration entfernt …")
            } else {
                Text("Worker, die nur diesen Zugang verwenden, sind danach nicht bereit. Ihre Einstellungen bleiben erhalten.")
            }
        }
    }

    private var customAccounts: [Provider] {
        model.providers
            .filter { $0.modelProvider == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var customProviderSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text("API")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 25, height: 25)
                    .background(RoundedRectangle(cornerRadius: 6).fill(WJTheme.surface))
                Text("Eigener Anbieter")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(showCustomProvider ? "Abbrechen" : "+ Zugang") {
                    showCustomProvider.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("Eigenen kompatiblen Anbieter hinzufügen")
                .accessibilityIdentifier("provider.custom.open")
            }

            ForEach(customAccounts) { account in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button { onSelect?(selectedRoute == .account(account.id) ? nil : .account(account.id)) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                                Text(accountSummary(account)).font(.system(size: 10)).foregroundStyle(accountStatusColor(account))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(account.name), \(accountIdentityAndSummary(account))")
                        .accessibilityIdentifier("provider.account.select.\(account.id.uuidString.uppercased())")
                        .accessibilityAddTraits(selectedRoute == .account(account.id) ? .isSelected : [])
                        Spacer()
                        if selectedRoute == .account(account.id) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(WJTheme.accent)
                                .accessibilityIdentifier("provider.account.selected.\(account.id.uuidString.uppercased())")
                        }
                        Button { toggleEditor(for: account) } label: { Image(systemName: "pencil") }
                            .buttonStyle(WJIconButtonStyle())
                            .disabled(busyAccountID != nil)
                            .accessibilityLabel("\(account.name) bearbeiten")
                        Button("Trennen", role: .destructive) { requestDisconnect(account) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(disconnectingAccountID != nil)
                            .accessibilityIdentifier("provider.account.disconnect.\(account.id.uuidString.uppercased())")
                    }
                    disconnectStatus(for: account)
                    if let draft = accountDraft, draft.id == account.id { accountEditor(draft) }
                }
                .padding(.leading, 33)
            }

            if showCustomProvider {
                VStack(spacing: 7) {
                    TextField("Name", text: $customName)
                        .accountField()
                        .accessibilityIdentifier("provider.custom.name")
                    TextField("Kompatibler Endpunkt, z. B. https://host.example/v1", text: $customEndpoint)
                        .accountField()
                        .accessibilityIdentifier("provider.custom.endpoint")
                    HStack(spacing: 6) {
                        WJChoiceButton(title: "Authorization-Key", isSelected: customAuthentication == .bearerToken) { customAuthentication = .bearerToken }
                        WJChoiceButton(title: "x-api-key", isSelected: customAuthentication == .apiKeyHeader) { customAuthentication = .apiKeyHeader }
                        WJChoiceButton(title: "Kein Schlüssel", isSelected: customAuthentication == .none) { customAuthentication = .none }
                    }
                    if customAuthentication != .none {
                        SecureField("API-Key", text: $customAPIKey).accountField()
                    }
                    HStack {
                        Text("Workjet lädt die verfügbaren Modelle automatisch.")
                            .font(.system(size: 9))
                            .foregroundStyle(WJTheme.secondaryText)
                        Spacer()
                        if creatingCustomProvider { ProgressView().controlSize(.mini) }
                        Button("Verbinden & Modelle laden") { connectCustomProvider() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .disabled(!customProviderInputIsComplete || creatingCustomProvider)
                    }
                }
                .padding(.leading, 33)
            }
        }
        .padding(.vertical, 8)
    }

    private var customProviderInputIsComplete: Bool {
        !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (customAuthentication == .none || !customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func connectCustomProvider() {
        creatingCustomProvider = true
        Task {
            guard let account = await model.connectCustomProvider(
                name: customName,
                endpoint: customEndpoint,
                authentication: customAuthentication,
                apiKey: customAPIKey
            ) else {
                creatingCustomProvider = false
                return
            }
            customName = ""
            customEndpoint = ""
            customAPIKey = ""
            showCustomProvider = false
            creatingCustomProvider = false
            onSelect?(.account(account.id))
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: ModelProvider) -> some View {
        let accounts = model.providerAccounts(for: provider)
        let loginState = model.providerLoginStates[provider] ?? .idle

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                ProviderLogo(provider: provider, size: 23)
                Text(provider.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if case .authenticating = loginState {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(openAPIProvider == provider ? "Abbrechen" : "+ Zugang") { beginAdding(provider) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityLabel("Weiteren \(provider.rawValue)-Zugang hinzufügen")
                }
            }

            ForEach(accounts) { account in
                let selectableRoute: ProviderRoute = .account(account.id)
                let usesGatewayLogin = provider.usesWebLogin && account.kind.isLocalGateway
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if usesGatewayLogin {
                            accountIdentity(account)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(account.name), \(accountIdentityAndSummary(account))")
                                .accessibilityIdentifier("provider.account.identity.\(account.id.uuidString.uppercased())")
                        } else {
                            Button { onSelect?(selectedRoute == selectableRoute ? nil : selectableRoute) } label: {
                                accountIdentity(account)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(account.name), \(accountIdentityAndSummary(account))")
                            .accessibilityIdentifier("provider.account.select.\(account.id.uuidString.uppercased())")
                            .accessibilityAddTraits(selectedRoute == selectableRoute ? .isSelected : [])
                        }
                        Spacer()
                        if !usesGatewayLogin, selectedRoute == selectableRoute {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(WJTheme.accent)
                                .accessibilityIdentifier("provider.account.selected.\(account.id.uuidString.uppercased())")
                        }
                        Button(usesGatewayLogin ? "Neu anmelden" : "Schlüssel") {
                            if usesGatewayLogin { reauthenticate(account) }
                            else { toggleEditor(for: account) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(busyAccountID != nil || disconnectingAccountID != nil)
                        .accessibilityLabel(usesGatewayLogin
                                            ? "Anmeldung für \(account.name) erneuern"
                                            : "Schlüssel für \(account.name) ersetzen")
                        .accessibilityIdentifier("provider.account.renew.\(account.id.uuidString.uppercased())")
                        Button("Trennen", role: .destructive) { requestDisconnect(account) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(disconnectingAccountID != nil)
                            .accessibilityIdentifier("provider.account.disconnect.\(account.id.uuidString.uppercased())")
                    }
                    disconnectStatus(for: account)
                    if let draft = accountDraft, draft.id == account.id { accountEditor(draft) }
                }
                .padding(.leading, 33)
            }

            if !accounts.isEmpty {
                let runtime = model.providerPoolPresentation(for: provider)
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(runtimeToneColor(runtime.tone))
                        .frame(width: 7, height: 7)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(runtime.state)
                            .font(.system(size: 10, weight: .semibold))
                        Text(runtime.detail)
                            .font(.system(size: 9))
                            .foregroundStyle(WJTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 33)
                .accessibilityIdentifier("provider.pool.health.\(provider.id)")
            }

            if accounts.count > 1 || (provider.usesWebLogin && onSelect != nil && !accounts.isEmpty) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.usesWebLogin
                             ? (accounts.count == 1
                                ? "\(provider.rawValue) über CLIProxy verwenden"
                                : "CLIProxy verwaltet \(accounts.count) Zugänge")
                            : "Alle \(accounts.count) Zugänge verwenden")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(accounts.map { $0.compactAccountLabel ?? $0.name }.joined(separator: " · "))
                            .font(.system(size: 9))
                            .foregroundStyle(WJTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(selectedRoute == .pool(provider) ? "Abwählen" : "Verwenden") {
                        onSelect?(selectedRoute == .pool(provider) ? nil : .pool(provider))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityLabel(provider.usesWebLogin
                                        ? "\(provider.rawValue)-Zugänge für diesen Worker verwenden"
                                        : "Alle \(provider.rawValue)-Zugänge für diesen Worker verwenden")
                    .accessibilityIdentifier("provider.pool.select.\(provider.id)")
                    .accessibilityAddTraits(selectedRoute == .pool(provider) ? .isSelected : [])
                    .help(provider.usesWebLogin
                          ? "CLIProxy wählt den Zugang und wechselt bei Bedarf."
                          : "Workjet verwendet diese Zugänge der Reihe nach.")
                }
                .padding(.leading, 33)
            }

            if openAPIProvider == provider {
                VStack(spacing: 6) {
                    if provider.usesWebLogin {
                        HStack {
                            Text(accounts.isEmpty
                                 ? "Ein Zugang kann von beliebig vielen Workern gemeinsam verwendet werden."
                                 : "Nur für einen anderen Account anmelden. Derselbe Login wird wiederverwendet, nicht doppelt angelegt.")
                                .font(.system(size: 9))
                                .foregroundStyle(WJTheme.secondaryText)
                            Spacer()
                            Button("Im Web anmelden") { authenticateNewAccount(provider) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                        }
                    } else {
                        TextField("Name des Zugangs", text: nameBinding(for: provider))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
                        HStack(spacing: 8) {
                            SecureField("API-Key", text: keyBinding(for: provider))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface))
                            Button("Verbinden") { authenticateNewAccount(provider) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .disabled((apiKeys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(.leading, 33)
            }

            if case let .failed(message) = loginState {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.quotaCritical)
                    .lineLimit(2)
                    .padding(.leading, 33)
            }
        }
        .padding(.vertical, 8)
        .id("provider.section.\(provider.id)")
    }

    private func accountIdentity(_ account: Provider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            Text(accountIdentityAndSummary(account))
                .font(.system(size: 10))
                .foregroundStyle(accountStatusColor(account))
                .lineLimit(1)
                .accessibilityIdentifier("provider.account.label.\(account.id.uuidString.uppercased())")
        }
    }

    private func beginAdding(_ provider: ModelProvider) {
        if openAPIProvider == provider {
            openAPIProvider = nil
            return
        }
        openProviderForAdding(provider)
    }

    private func openProviderForAdding(_ provider: ModelProvider) {
        openAPIProvider = provider
        ensureDefaultAccountName(for: provider)
    }

    private func ensureDefaultAccountName(for provider: ModelProvider) {
        if !provider.usesWebLogin, accountNames[provider] == nil {
            accountNames[provider] = "\(provider.rawValue) \(model.providerAccounts(for: provider).count + 1)"
        }
    }

    private func keyBinding(for provider: ModelProvider) -> Binding<String> {
        Binding(get: { apiKeys[provider] ?? "" }, set: { apiKeys[provider] = $0 })
    }

    private func nameBinding(for provider: ModelProvider) -> Binding<String> {
        Binding(get: { accountNames[provider] ?? "" }, set: { accountNames[provider] = $0 })
    }

    private func authenticateNewAccount(_ provider: ModelProvider) {
        let key = apiKeys[provider] ?? ""
        let name = accountNames[provider] ?? ""
        Task {
            guard let account = await model.connectNewAccount(provider, name: name, apiKey: key) else { return }
            apiKeys[provider] = ""
            accountNames[provider] = ""
            openAPIProvider = nil
            onSelect?(.account(account.id))
        }
    }

    private func accountSummary(_ account: Provider) -> String {
        if let fraction = account.capacity.fraction {
            let reset = capacityResetLabel(account.capacity).map { " · \($0)" } ?? ""
            return "\(model.providerPresentation(for: account).state) · \(Int((fraction * 100).rounded())) %\(reset)"
        }
        return model.providerPresentation(for: account).state
    }

    private func capacityResetLabel(_ capacity: CapacityStatus) -> String? {
        let unit: String
        switch capacity {
        case let .measured(_, _, value, _), let .userConfigured(_, _, value, _): unit = value
        case .unavailable: return nil
        }
        guard let marker = unit.range(of: " · Reset ") else { return nil }
        let raw = String(unit[marker.upperBound...])
        guard let date = ISO8601DateFormatter().date(from: raw) else { return "Reset \(raw)" }
        return "Reset " + date.formatted(.dateTime.day().month().hour().minute())
    }

    private func accountIdentityAndSummary(_ account: Provider) -> String {
        [account.compactAccountLabel, accountSummary(account)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func accountStatusColor(_ account: Provider) -> Color {
        switch model.providerPresentation(for: account).tone {
        case .connected: return WJTheme.quotaOK
        case .warning: return WJTheme.quotaWarning
        case .critical: return WJTheme.quotaCritical
        case .neutral: return WJTheme.secondaryText
        }
    }

    private func runtimeToneColor(_ tone: ProviderPresentationTone) -> Color {
        switch tone {
        case .connected: return WJTheme.quotaOK
        case .warning: return WJTheme.quotaWarning
        case .critical: return WJTheme.quotaCritical
        case .neutral: return WJTheme.secondaryText
        }
    }

    private func requestDisconnect(_ account: Provider) {
        guard disconnectingAccountID == nil else { return }
        disconnectFailure = nil
        pendingDisconnect = account
    }

    private func disconnectConfirmed(_ account: Provider) {
        guard disconnectingAccountID == nil else { return }
        disconnectingAccountID = account.id
        disconnectFailure = nil
        Task {
            let result = await model.deleteProviderDurably(id: account.id)
            disconnectingAccountID = nil
            switch result {
            case .deleted, .deletedWithWarning:
                if selectedRoute == .account(account.id) { onSelect?(nil) }
                discardEditor()
                pendingDisconnect = nil
                disconnectFailure = nil
            case let .failed(message):
                disconnectFailure = message
            }
        }
    }

    @ViewBuilder
    private func disconnectStatus(for account: Provider) -> some View {
        if disconnectingAccountID == account.id {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Zugang wird dauerhaft entfernt …")
            }
            .font(.system(size: 10))
            .foregroundStyle(WJTheme.secondaryText)
        } else if pendingDisconnect?.id == account.id, let disconnectFailure {
            Text(disconnectFailure)
                .font(.system(size: 10))
                .foregroundStyle(WJTheme.quotaCritical)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("provider.account.delete.error")
        }
    }

    @ViewBuilder
    private func accountEditor(_ draft: Provider) -> some View {
        let inFlight = busyAccountID == draft.id
        VStack(alignment: .leading, spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ProviderKind.allCases, id: \.self) { kind in
                        WJChoiceButton(title: kind.rawValue, isSelected: draft.kind == kind) {
                            mutateDraft {
                                $0.kind = kind
                                if kind.isLocalGateway && $0.authentication == .apiKeyHeader {
                                    $0.authentication = .bearerToken
                                }
                            }
                        }
                    }
                }
            }
            TextField("Name", text: draftBinding(\.name))
                .accountField()
                .accessibilityIdentifier("provider.account.draft.name")
            TextField(draft.kind.isLocalGateway ? "Loopback-Endpunkt" : "HTTPS-Endpunkt", text: draftBinding(\.endpoint))
                .accountField()
                .accessibilityIdentifier("provider.account.draft.endpoint")
            HStack(spacing: 7) {
                Text("Priorität im Pool")
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.secondaryText)
                TextField("0", value: draftIntBinding(\.routingPriority), format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 42)
                    .accountField()
                    .help("Niedrigere Zahl wird zuerst verwendet.")
                    .accessibilityLabel("Priorität im Pool. Niedrigere Zahl wird zuerst verwendet.")
                Spacer()
            }

            Text("Authentifizierung")
                .font(.system(size: 10))
                .foregroundStyle(WJTheme.secondaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(authenticationChoices(for: draft), id: \.self) { authentication in
                        WJChoiceButton(title: authentication.rawValue, isSelected: draft.authentication == authentication) {
                            mutateDraft { $0.authentication = authentication }
                        }
                    }
                }
            }
            if draft.modelProvider?.usesWebLogin == true {
                HStack {
                    Button("Web-Anmeldung erneuern") { reauthenticate(draft) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(providerDraftHasUnsavedChanges(draft))
                        .help(providerDraftHasUnsavedChanges(draft)
                              ? "Speichere die Änderungen zuerst, bevor du die Web-Anmeldung erneuerst."
                              : "Web-Anmeldung für diesen Zugang erneuern")
                    Text("Für alle passenden Worker verfügbar")
                        .font(.system(size: 9))
                        .foregroundStyle(WJTheme.quotaWarning)
                }
            } else if draft.authentication != .none {
                HStack(spacing: 7) {
                    SecureField("API-Key ersetzen (leer = bisherigen behalten)", text: $accountSecret)
                        .accountField()
                        .accessibilityIdentifier("provider.account.draft.secret")
                    Text(model.providerAccessStored.contains(draft.id) ? "Konfiguriert" : "Nicht konfiguriert")
                        .font(.system(size: 9))
                        .foregroundStyle(WJTheme.secondaryText)
                }
            }

            Text("Modelle (eine ID je Zeile)")
                .font(.system(size: 10))
                .foregroundStyle(WJTheme.secondaryText)
            TextEditor(text: localDraftTextBinding($accountModelsText))
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 55)
                .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.background))
                .accessibilityIdentifier("provider.account.draft.models")

            DisclosureGroup("Technische Details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(draft.kind.isLocalGateway
                         ? "Nur allowlist-konforme Loopback-Endpunkte sind zulässig."
                         : "HTTPS ist erforderlich; Loopback-HTTP ist nur für lokale Entwicklung zulässig.")
                        .font(.system(size: 10))
                        .foregroundStyle(WJTheme.secondaryText)
                    TextField("Login-Executable (Legacy)", text: draftOptionalStringBinding(\.loginExecutable))
                        .accountField()
                    TextEditor(text: localDraftTextBinding($accountArgumentsText))
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 45)
                        .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.background))
                    Text("Login-Argumente (Legacy), ein Argument je Zeile. Legacy-Loginbefehle werden niemals automatisch ausgeführt.")
                        .font(.system(size: 9))
                        .foregroundStyle(WJTheme.tertiaryText)
                }
                .padding(.top, 5)
            }
            .font(.system(size: 11))

            if let accountSaveError {
                Text(accountSaveError)
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.quotaCritical)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("provider.account.save.error")
            } else {
                Text(draft.statusDetail)
                    .font(.system(size: 9))
                    .foregroundStyle(draft.status == .offline ? WJTheme.quotaCritical : WJTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 7) {
                Button("Abbrechen") { discardEditor() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityIdentifier("provider.account.edit.cancel")
                Button("Zugang löschen", role: .destructive) { requestDisconnect(draft) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Spacer()
                if inFlight { ProgressView().controlSize(.mini) }
                Button("Speichern & prüfen") { saveEditorDraft() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(
                        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("provider.account.edit.save")
            }
        }
        .disabled(inFlight || disconnectingAccountID != nil)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface.opacity(0.7)))
    }

    private func toggleEditor(for account: Provider) {
        if accountDraft?.id == account.id {
            discardEditor()
        } else {
            accountDraft = account
            accountSecret = ""
            accountModelsText = account.modelIDs.joined(separator: "\n")
            accountArgumentsText = account.loginArguments.joined(separator: "\n")
            accountSaveError = nil
        }
    }

    private func discardEditor() {
        accountDraft = nil
        accountSecret = ""
        accountModelsText = ""
        accountArgumentsText = ""
        accountSaveError = nil
    }

    private func saveEditorDraft() {
        guard busyAccountID == nil, var draft = accountDraft else { return }
        draft.modelIDs = Provider.normalizedModels(
            accountModelsText.split(whereSeparator: \.isNewline).map(String.init)
        )
        draft.loginArguments = accountArgumentsText.split(whereSeparator: \.isNewline).map(String.init)
        busyAccountID = draft.id
        accountSaveError = nil
        let secret = accountSecret
        Task {
            let result = await model.saveAndTestProviderDurably(draft, secret: secret)
            busyAccountID = nil
            switch result {
            case let .saved(provider):
                accountDraft = provider
                accountSecret = ""
                accountModelsText = provider.modelIDs.joined(separator: "\n")
                accountArgumentsText = provider.loginArguments.joined(separator: "\n")
            case let .savedWithProbeFailure(provider, message):
                accountDraft = provider
                accountSecret = ""
                accountModelsText = provider.modelIDs.joined(separator: "\n")
                accountArgumentsText = provider.loginArguments.joined(separator: "\n")
                accountSaveError = "Die Änderungen und der vorgesehene Zugangsschlüssel wurden gespeichert, aber die Prüfung ist fehlgeschlagen: \(message) Prüfe Endpunkt und Authentifizierung und speichere erneut."
            case let .failed(message):
                accountSaveError = message
            }
        }
    }

    private func reauthenticate(_ account: Provider) {
        guard busyAccountID == nil else { return }
        busyAccountID = account.id
        Task {
            await model.reauthenticateProvider(id: account.id)
            busyAccountID = nil
        }
    }

    private func authenticationChoices(for provider: Provider) -> [ProviderAuthentication] {
        provider.kind.isLocalGateway ? [.bearerToken, .none] : ProviderAuthentication.allCases
    }

    private func providerDraftHasUnsavedChanges(_ draft: Provider) -> Bool {
        guard let persisted = model.providers.first(where: { $0.id == draft.id }) else { return true }
        let typedModels = Provider.normalizedModels(
            accountModelsText.split(whereSeparator: \.isNewline).map(String.init)
        )
        let typedArguments = accountArgumentsText.split(whereSeparator: \.isNewline).map(String.init)
        return draft.name != persisted.name
            || draft.kind != persisted.kind
            || draft.endpoint != persisted.endpoint
            || draft.authentication != persisted.authentication
            || draft.routingPriority != persisted.routingPriority
            || typedModels != persisted.modelIDs
            || draft.loginExecutable != persisted.loginExecutable
            || typedArguments != persisted.loginArguments
            || !accountSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func mutateDraft(_ mutation: (inout Provider) -> Void) {
        guard var draft = accountDraft else { return }
        mutation(&draft)
        draft.status = .unverified
        draft.statusDetail = "Geändert; bitte speichern und erneut prüfen."
        draft.capacity = .unavailable(reason: "Nach einer Zugangsänderung ist eine erneute Messung erforderlich.")
        accountDraft = draft
        accountSaveError = nil
    }

    private func draftBinding(_ keyPath: WritableKeyPath<Provider, String>) -> Binding<String> {
        Binding(
            get: { accountDraft?[keyPath: keyPath] ?? "" },
            set: { value in mutateDraft { $0[keyPath: keyPath] = value } }
        )
    }

    private func draftIntBinding(_ keyPath: WritableKeyPath<Provider, Int>) -> Binding<Int> {
        Binding(
            get: { accountDraft?[keyPath: keyPath] ?? 0 },
            set: { value in mutateDraft { $0[keyPath: keyPath] = value } }
        )
    }

    private func draftOptionalStringBinding(_ keyPath: WritableKeyPath<Provider, String?>) -> Binding<String> {
        Binding(
            get: { accountDraft?[keyPath: keyPath] ?? "" },
            set: { value in mutateDraft { $0[keyPath: keyPath] = value.isEmpty ? nil : value } }
        )
    }

    private func localDraftTextBinding(_ text: Binding<String>) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: { value in
                text.wrappedValue = value
                mutateDraft { _ in }
            }
        )
    }
}

private extension View {
    func accountField() -> some View {
        self
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(WJTheme.background))
    }
}

struct ProviderSetupView: View {
    let selectedRoute: ProviderRoute?
    var initiallyOpenProvider: ModelProvider? = nil
    let onSelect: (ProviderRoute?) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Anbieter und Zugang")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(WJIconButtonStyle())
                    .accessibilityLabel("Anbieter schließen")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            WJDivider()
            ScrollViewReader { proxy in
                ScrollView {
                    ProviderAccountsView(selectedRoute: selectedRoute, onSelect: onSelect, initiallyOpenProvider: initiallyOpenProvider)
                        .padding(.horizontal, 14)
                }
                .onAppear {
                    guard let initiallyOpenProvider else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("provider.section.\(initiallyOpenProvider.id)", anchor: .top)
                    }
                }
            }
        }
        .frame(width: 420, height: 500)
        .background(WJTheme.background)
        .preferredColorScheme(.dark)
    }
}
