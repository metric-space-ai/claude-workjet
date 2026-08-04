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
    @State private var editingAccountID: UUID?
    @State private var accountSecrets: [UUID: String] = [:]
    @State private var busyAccountID: UUID?
    @State private var showCustomProvider = false
    @State private var customName = ""
    @State private var customEndpoint = ""
    @State private var customAuthentication: ProviderAuthentication = .bearerToken
    @State private var customAPIKey = ""
    @State private var creatingCustomProvider = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(ModelProvider.allCases) { provider in
                providerSection(provider)
                WJDivider()
            }
            customProviderSection
        }
        .onAppear {
            if let initiallyOpenProvider { beginAdding(initiallyOpenProvider) }
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
                                Text(accountSummary(account)).font(.system(size: 10)).foregroundStyle(account.status == .connected ? WJTheme.quotaOK : WJTheme.secondaryText)
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
                        Button {
                            editingAccountID = editingAccountID == account.id ? nil : account.id
                            accountSecrets[account.id] = ""
                        } label: { Image(systemName: "pencil") }
                            .buttonStyle(WJIconButtonStyle())
                            .accessibilityLabel("\(account.name) bearbeiten")
                        Button("Trennen", role: .destructive) { disconnect(account) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .accessibilityIdentifier("provider.account.disconnect.\(account.id.uuidString.uppercased())")
                    }
                    if editingAccountID == account.id { accountEditor(account) }
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
                        WJChoiceButton(title: "Bearer", isSelected: customAuthentication == .bearerToken) { customAuthentication = .bearerToken }
                        WJChoiceButton(title: "x-api-key", isSelected: customAuthentication == .apiKeyHeader) { customAuthentication = .apiKeyHeader }
                        WJChoiceButton(title: "Ohne Auth", isSelected: customAuthentication == .none) { customAuthentication = .none }
                    }
                    if customAuthentication != .none {
                        SecureField("API-Key", text: $customAPIKey).accountField()
                    }
                    HStack {
                        Text("Workjet prüft /v1/models und übernimmt die gelieferten Modell-IDs.")
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button { onSelect?(selectedRoute == .account(account.id) ? nil : .account(account.id)) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                            Text(accountIdentityAndSummary(account))
                                .font(.system(size: 10))
                                .foregroundStyle(account.status == .connected ? WJTheme.quotaOK : WJTheme.secondaryText)
                                .lineLimit(1)
                                .accessibilityIdentifier("provider.account.label.\(account.id.uuidString.uppercased())")
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
                        Button {
                            editingAccountID = editingAccountID == account.id ? nil : account.id
                            accountSecrets[account.id] = ""
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(WJIconButtonStyle())
                        .accessibilityLabel("\(account.name) bearbeiten")
                        Button("Trennen", role: .destructive) { disconnect(account) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .accessibilityIdentifier("provider.account.disconnect.\(account.id.uuidString.uppercased())")
                    }
                    if editingAccountID == account.id { accountEditor(account) }
                }
                .padding(.leading, 33)
            }

            if accounts.count > 1 {
                Button { onSelect?(selectedRoute == .pool(provider) ? nil : .pool(provider)) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Alle \(accounts.count) Zugänge verwenden")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(accounts.map { $0.compactAccountLabel ?? $0.name }.joined(separator: " · "))
                                .font(.system(size: 9))
                                .foregroundStyle(WJTheme.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer()
                        if selectedRoute == .pool(provider) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(WJTheme.accent)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .padding(.leading, 33)
                .help("CLIProxy verwendet die verbundenen Zugänge gemeinsam.")
            }

            if openAPIProvider == provider {
                VStack(spacing: 6) {
                    if provider.usesWebLogin {
                        HStack {
                            Text("Die Mailadresse aus der Web-Anmeldung identifiziert den Zugang.")
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
    }

    private func beginAdding(_ provider: ModelProvider) {
        openAPIProvider = openAPIProvider == provider ? nil : provider
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
        let capacity: String
        if let fraction = account.capacity.fraction {
            capacity = " · \(Int((fraction * 100).rounded())) %"
        } else {
            capacity = " · Quote/Rate nicht verfügbar"
        }
        return "\(account.status.rawValue)\(capacity)"
    }

    private func accountIdentityAndSummary(_ account: Provider) -> String {
        [account.compactAccountLabel, accountSummary(account)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func disconnect(_ account: Provider) {
        if selectedRoute == .account(account.id) { onSelect?(nil) }
        model.removeProvider(id: account.id)
        editingAccountID = nil
    }

    @ViewBuilder
    private func accountEditor(_ account: Provider) -> some View {
        let modelProvider = account.modelProvider
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: accountBinding(account.id, \.name))
                .accountField()
            TextField(account.kind.isLocalGateway ? "Loopback-Endpunkt" : "HTTPS-Endpunkt", text: accountBinding(account.id, \.endpoint, invalidatesProbe: true))
                .accountField()
            HStack(spacing: 7) {
                Text("Reihenfolge")
                    .font(.system(size: 10))
                    .foregroundStyle(WJTheme.secondaryText)
                TextField("0", value: accountIntBinding(account.id, \.routingPriority), format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 42)
                    .accountField()
                Spacer()
                if busyAccountID == account.id { ProgressView().controlSize(.mini) }
                Button("Testen") { test(account) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(busyAccountID != nil)
            }

            if modelProvider?.usesWebLogin == true {
                HStack {
                    Button("Web-Anmeldung erneuern") { reauthenticate(account) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(busyAccountID != nil)
                    Text("Konkrete Account-Zuordnung noch nicht verfügbar")
                        .font(.system(size: 9))
                        .foregroundStyle(WJTheme.quotaWarning)
                }
            } else if account.authentication != .none {
                HStack(spacing: 7) {
                    SecureField("API-Key ersetzen", text: accountSecretBinding(account.id))
                        .accountField()
                    Button("Speichern & testen") { test(account, secret: accountSecrets[account.id] ?? "") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled((accountSecrets[account.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busyAccountID != nil)
                }
            }

            Text(account.statusDetail)
                .font(.system(size: 9))
                .foregroundStyle(account.status == .offline ? WJTheme.quotaCritical : WJTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Zugang löschen", role: .destructive) {
                    model.removeProvider(id: account.id)
                    editingAccountID = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(WJTheme.surface.opacity(0.7)))
    }

    private func test(_ account: Provider, secret: String = "") {
        busyAccountID = account.id
        Task {
            await model.testProvider(id: account.id, secret: secret)
            accountSecrets[account.id] = ""
            busyAccountID = nil
        }
    }

    private func reauthenticate(_ account: Provider) {
        busyAccountID = account.id
        Task {
            await model.reauthenticateProvider(id: account.id)
            busyAccountID = nil
        }
    }

    private func accountBinding(_ id: UUID, _ keyPath: WritableKeyPath<Provider, String>, invalidatesProbe: Bool = false) -> Binding<String> {
        Binding(
            get: { model.providers.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { value in
                guard var account = model.providers.first(where: { $0.id == id }) else { return }
                account[keyPath: keyPath] = value
                if invalidatesProbe {
                    account.status = .unverified
                    account.statusDetail = "Geändert; bitte erneut testen."
                    account.capacity = .unavailable(reason: "Nach einer Zugangsänderung ist eine erneute Messung erforderlich.")
                }
                model.updateProvider(account)
            }
        )
    }

    private func accountIntBinding(_ id: UUID, _ keyPath: WritableKeyPath<Provider, Int>) -> Binding<Int> {
        Binding(
            get: { model.providers.first(where: { $0.id == id })?[keyPath: keyPath] ?? 0 },
            set: { value in
                guard var account = model.providers.first(where: { $0.id == id }) else { return }
                account[keyPath: keyPath] = value
                model.updateProvider(account)
            }
        )
    }

    private func accountSecretBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { accountSecrets[id] ?? "" }, set: { accountSecrets[id] = $0 })
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
            ScrollView {
                ProviderAccountsView(selectedRoute: selectedRoute, onSelect: onSelect, initiallyOpenProvider: initiallyOpenProvider)
                    .padding(.horizontal, 14)
            }
        }
        .frame(width: 420, height: 500)
        .background(WJTheme.background)
        .preferredColorScheme(.dark)
    }
}
