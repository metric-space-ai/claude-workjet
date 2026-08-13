import Foundation
import LocalAuthentication
import Security

public protocol CredentialStoring: Sendable {
    func read(reference: String) throws -> Data?
    func write(_ secret: Data, reference: String) throws
    func delete(reference: String) throws
}

/// Non-interactive provider credential storage for Workjet's headless runtime.
/// Files are private to the current user (0700 directory, 0600 entries), just
/// like the existing CLIProxy gateway key. This avoids macOS Keychain ACL
/// prompts when locally built, ad-hoc-signed app and CLI binaries change hash.
public struct PrivateFileCredentialStore: CredentialStoring, Sendable {
    public let directory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = homeDirectory.appendingPathComponent(".config/workjet/credentials", isDirectory: true)
    }

    public func read(reference: String) throws -> Data? {
        let file = try credentialFile(reference)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try SecureFile.checkPrivateRegularOwnedFile(at: file)
        return try SecureFile.readRegularOwnedFile(at: file, maximumBytes: 64 * 1_024)
    }

    public func write(_ secret: Data, reference: String) throws {
        guard !secret.isEmpty, secret.count <= 64 * 1_024 else { throw CredentialError.invalidSecret }
        try AtomicFile.write(secret, to: try credentialFile(reference), directoryMode: 0o700, fileMode: 0o600)
    }

    public func delete(reference: String) throws {
        let file = try credentialFile(reference)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try SecureFile.checkPrivateRegularOwnedFile(at: file)
        try FileManager.default.removeItem(at: file)
    }

    private func credentialFile(_ reference: String) throws -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !reference.isEmpty,
              reference.count <= 128,
              reference.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CredentialError.emptyReference
        }
        return directory.appendingPathComponent(reference, isDirectory: false)
    }
}

public struct KeychainCredentialStore: CredentialStoring, Sendable {
    public let service: String
    public init(service: String = "dev.workjet.app") { self.service = service }

    public func read(reference: String) throws -> Data? {
        var query = base(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Credential reads are non-interactive. A stale ACL or changed app
        // signature must return an error instead of summoning a modal dialog.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        return result as? Data
    }

    public func write(_ secret: Data, reference: String) throws {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CredentialError.emptyReference }
        var query = base(reference)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let update = [kSecValueData as String: secret]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = base(reference)
            insertion[kSecValueData as String] = secret
            insertion[kSecUseAuthenticationContext as String] = context
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
        } else if status != errSecSuccess { throw CredentialError.keychain(status) }
    }

    public func delete(reference: String) throws {
        var query = base(reference)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }

    private func base(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }
}

public enum CredentialError: LocalizedError {
    case emptyReference
    case invalidSecret
    case keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .emptyReference: return "Die Zugangsdaten-Referenz ist ungültig."
        case .invalidSecret: return "Der Anbieterzugang ist leer oder zu groß."
        case .keychain: return "Der Zugang konnte nicht aus dem Schlüsselbund gelesen werden. Öffne den Anbieter und verbinde ihn erneut."
        }
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var data: Data
    /// Lower-cased field names with each original field value preserved.
    /// Quota parsers must opt into a documented provider-specific profile.
    public var headers: [String: [String]]
    public init(statusCode: Int, data: Data, headers: [String: [String]] = [:]) {
        self.statusCode = statusCode
        self.data = data
        var normalized: [String: [String]] = [:]
        for (name, values) in headers { normalized[name.lowercased(), default: []].append(contentsOf: values) }
        self.headers = normalized
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()]?.first }
}

public protocol HTTPClient: Sendable {
    func request(_ request: URLRequest) async throws -> HTTPResponse
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionHTTPClient: HTTPClient, Sendable {
    public init() {}
    public func request(_ request: URLRequest) async throws -> HTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: [String]] = [:]
        for (rawName, rawValue) in http.allHeaderFields {
            let name = String(describing: rawName).lowercased()
            if let values = rawValue as? [String] { headers[name, default: []].append(contentsOf: values) }
            else { headers[name, default: []].append(String(describing: rawValue)) }
        }
        return HTTPResponse(statusCode: http.statusCode, data: data, headers: headers)
    }
}

public enum ProviderEndpointValidation: Equatable, Sendable {
    case valid(URL)
    case invalid(String)
}

public enum ProviderEndpointValidator {
    public static func validate(_ endpoint: String, kind: ProviderKind) -> ProviderEndpointValidation {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            return .invalid("Endpunkt muss eine URL ohne Zugangsdaten, Query oder Fragment sein.")
        }
        let loopback = isLoopback(host)
        if kind.isLocalGateway {
            guard loopback, scheme == "http" || scheme == "https" else {
                return .invalid("Lokale Gateways müssen einen Loopback-Endpunkt verwenden.")
            }
        } else {
            guard scheme == "https" || (scheme == "http" && loopback) else {
                return .invalid("Direkte APIs benötigen HTTPS; HTTP ist nur auf Loopback erlaubt.")
            }
        }
        components.scheme = scheme
        components.host = host
        if components.path == "/" { components.path = "" }
        guard let url = components.url else { return .invalid("Endpunkt ist ungültig.") }
        return .valid(url)
    }

    public static func modelsURL(baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let modelPath = basePath == "v1" || basePath.hasSuffix("/v1") || basePath.hasSuffix("/v4") ? "models" : "v1/models"
        components.path = "/" + ([basePath, modelPath].filter { !$0.isEmpty }.joined(separator: "/"))
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    public static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let pieces = host.split(separator: ".")
        return pieces.count == 4 && pieces[0] == "127" && pieces.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }
}

public struct ProviderInspector: Sendable {
    public let client: any HTTPClient
    public let credentials: any CredentialStoring

    public init(client: any HTTPClient = URLSessionHTTPClient(), credentials: any CredentialStoring = PrivateFileCredentialStore()) {
        self.client = client
        self.credentials = credentials
    }

    public func inspect(_ provider: Provider) async -> ProviderProbeResult {
        let validation = ProviderEndpointValidator.validate(provider.endpoint, kind: provider.kind)
        guard case let .valid(baseURL) = validation else {
            if case let .invalid(detail) = validation { return ProviderProbeResult(status: .offline, detail: detail) }
            return ProviderProbeResult(status: .offline, detail: "Endpunkt ist ungültig.")
        }
        let modelsURL: URL
        if provider.modelProvider == .zAI, baseURL.host?.lowercased() == "api.z.ai" {
            modelsURL = URL(string: "https://api.z.ai/api/paas/v4/models")!
        } else {
            modelsURL = ProviderEndpointValidator.modelsURL(baseURL: baseURL)
        }
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var accessToken: String?
        if provider.authentication != .none {
            guard let reference = provider.credentialReference,
                  !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ProviderProbeResult(status: .offline, detail: "Für diesen Zugang fehlt der Schlüssel.")
            }
            let secret: Data?
            do {
                secret = try credentials.read(reference: reference)
            } catch {
                return ProviderProbeResult(status: .offline, detail: "Der gespeicherte Zugang ist nicht verfügbar. Verbinde den Anbieter erneut.")
            }
            guard let secret,
                  let token = String(data: secret, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                return ProviderProbeResult(status: .offline, detail: "Für diesen Zugang fehlt der Schlüssel.")
            }
            accessToken = token
            switch provider.authentication {
            case .none: break
            case .bearerToken:
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            case .apiKeyHeader:
                request.setValue(token, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        }
        let response: HTTPResponse
        do { response = try await client.request(request) }
        catch { return ProviderProbeResult(status: .offline, detail: "Endpunkt ist nicht erreichbar.") }
        guard response.data.count <= 1_048_576 else { return ProviderProbeResult(status: .degraded, detail: "Die Modellliste konnte nicht geladen werden.") }
        if response.statusCode == 401 || response.statusCode == 403 {
            return ProviderProbeResult(status: .offline, detail: "Der Anbieter hat den Zugang abgelehnt.")
        }
        guard (200..<300).contains(response.statusCode) else {
            return ProviderProbeResult(status: .offline, detail: "Der Anbieter hat die Modellabfrage abgelehnt.")
        }
        guard let models = Self.parseModels(response.data, provider: provider.modelProvider) else {
            return ProviderProbeResult(status: .degraded, detail: "Der Anbieter hat keine lesbare Modellliste geliefert.")
        }
        let route = provider.kind.isLocalGateway ? " · Zugang über lokalen Gateway" : ""
        var detail = "Verbindung geprüft · \(models.count) Modelle gefunden\(route)."
        var capacity = Self.parseDocumentedRateHeaders(response.headers, provider: provider.modelProvider)
            ?? .unavailable(reason: "Für diesen Zugang sind keine Kapazitätsdaten verfügbar.")
        if provider.kind == .directAPI, provider.modelProvider == .miniMax, let accessToken,
           let usageURL = Self.miniMaxUsageURL(baseURL: baseURL, apiKey: accessToken) {
            var quotaRequest = URLRequest(url: usageURL)
            quotaRequest.httpMethod = "GET"
            quotaRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            quotaRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            do {
                let quotaResponse = try await client.request(quotaRequest)
                if (200..<300).contains(quotaResponse.statusCode),
                   quotaResponse.data.count <= 1_048_576,
                   let measured = accessToken.hasPrefix("sk-api-")
                        ? Self.parseMiniMaxBalance(quotaResponse.data)
                        : Self.parseMiniMaxCapacity(quotaResponse.data) {
                    capacity = measured.capacity
                    detail += " Kontingent: \(measured.summary)."
                } else {
                    capacity = .unavailable(reason: "Kontingent konnte nicht gelesen werden.")
                }
            } catch {
                capacity = .unavailable(reason: "Kontingent ist derzeit nicht erreichbar.")
            }
        } else if provider.kind == .directAPI, provider.modelProvider == .zAI, let accessToken,
                  let usageURL = Self.zAIUsageURL(baseURL: baseURL) {
            var quotaRequest = URLRequest(url: usageURL)
            quotaRequest.httpMethod = "GET"
            quotaRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            quotaRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            do {
                let quotaResponse = try await client.request(quotaRequest)
                if (200..<300).contains(quotaResponse.statusCode),
                   quotaResponse.data.count <= 1_048_576,
                   let measured = Self.parseZAIUsage(quotaResponse.data) {
                    capacity = measured.capacity
                    detail += " Kontingent: \(measured.summary)."
                } else {
                    capacity = .unavailable(reason: "Coding-Plan-Kontingent konnte nicht gelesen werden.")
                }
            } catch {
                capacity = .unavailable(reason: "Coding-Plan-Kontingent ist derzeit nicht erreichbar.")
            }
        }
        return ProviderProbeResult(status: .connected, detail: detail, modelIDs: models, capacity: capacity)
    }

    public struct MiniMaxCapacityMeasurement: Equatable, Sendable {
        public var capacity: CapacityStatus
        public var summary: String
        public var resetAt: Date?
    }

    /// Parses only provider-documented response headers. "OpenAI compatible"
    /// alone is deliberately insufficient evidence for these semantics.
    public static func parseDocumentedRateHeaders(_ headers: [String: [String]], provider: ModelProvider?) -> CapacityStatus? {
        var normalized: [String: [String]] = [:]
        for (name, values) in headers { normalized[name.lowercased(), default: []].append(contentsOf: values) }
        let source = provider == .openAI ? "OpenAI-Antwortheader" : "Anthropic-Antwortheader"
        let observedAt = Date()
        var signals: [CapacitySignal] = []
        for (suffix, label) in [("requests", "Anfragen"), ("tokens", "Tokens")] {
            let limitName: String
            let remainingName: String
            let resetName: String
            switch provider {
            case .openAI:
                limitName = "x-ratelimit-limit-\(suffix)"
                remainingName = "x-ratelimit-remaining-\(suffix)"
                resetName = "x-ratelimit-reset-\(suffix)"
            case .anthropic:
                limitName = "anthropic-ratelimit-\(suffix)-limit"
                remainingName = "anthropic-ratelimit-\(suffix)-remaining"
                resetName = "anthropic-ratelimit-\(suffix)-reset"
            default:
                return nil
            }
            guard let limit = headerNumber(normalized, limitName), limit > 0,
                  let remaining = headerNumber(normalized, remainingName), remaining >= 0, remaining <= limit else { continue }
            let compact = "\(compactNumber(remaining))/\(compactNumber(limit))"
            signals.append(CapacitySignal(
                kind: .rate,
                label: label,
                used: limit - remaining,
                limit: limit,
                compactValue: compact,
                resetAt: headerReset(normalized[resetName]?.first, observedAt: observedAt),
                observedAt: observedAt,
                source: source,
                scope: "Account/Projekt",
                limited: remaining == 0
            ))
        }
        guard !signals.isEmpty else { return nil }
        return .observed(signals: signals, reason: nil)
    }

    private static func headerNumber(_ headers: [String: [String]], _ name: String) -> Double? {
        guard let value = headers[name]?.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return Double(value)
    }

    private static func headerReset(_ raw: String?, observedAt: Date) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        if let seconds = Double(raw) { return observedAt.addingTimeInterval(seconds) }
        let pattern = #"(?i)([0-9]*\.?[0-9]+)(ms|s|m|h)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = expression.matches(in: raw, range: range)
        guard !matches.isEmpty else { return nil }
        var seconds = 0.0
        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: raw),
                  let unitRange = Range(match.range(at: 2), in: raw),
                  let value = Double(raw[valueRange]) else { return nil }
            switch raw[unitRange].lowercased() {
            case "ms": seconds += value / 1_000
            case "s": seconds += value
            case "m": seconds += value * 60
            case "h": seconds += value * 3_600
            default: return nil
            }
        }
        return observedAt.addingTimeInterval(seconds)
    }

    private static func compactNumber(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000).replacingOccurrences(of: ".0k", with: "k") }
        return String(Int(value.rounded()))
    }

    public static func miniMaxUsageURL(baseURL: URL, apiKey: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), host == "api.minimax.io" || host == "api.minimaxi.com" || host == "www.minimax.io" || host == "www.minimaxi.com" else { return nil }
        if host.hasPrefix("www.") { components.host = "api." + host.dropFirst(4) }
        components.path = apiKey.hasPrefix("sk-api-") ? "/account/query_balance" : "/v1/token_plan/remains"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func zAIUsageURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), ["api.z.ai", "open.bigmodel.cn", "dev.bigmodel.cn"].contains(host) else { return nil }
        components.path = "/api/monitor/usage/quota/limit"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Parses only explicitly identified text/coding-plan windows. In
    /// particular, `usage_count` is consumption despite the endpoint name;
    /// media-only quotas and unlabeled numeric pairs are intentionally ignored.
    public static func parseMiniMaxCapacity(_ data: Data) -> MiniMaxCapacityMeasurement? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let base = root["base_resp"] as? [String: Any],
           let code = number(base["status_code"]), code != 0 { return nil }
        guard let entries = root["model_remains"] as? [[String: Any]] else { return nil }

        struct Window {
            var used: Double
            var limit: Double
            var label: String
            var resetAt: Date?
            var compactValue: String?
            var limited: Bool
            var fraction: Double { used / limit }
        }
        var windows: [Window] = []
        for entry in entries {
            guard let rawName = entry["model_name"] as? String else { continue }
            let name = rawName.lowercased()
            guard name == "general" || name.contains("minimax-m") || name.contains("coding") else { continue }

            func resetDate(_ key: String) -> Date? {
                guard let value = number(entry[key]), value > 0 else { return nil }
                return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
            }
            func status(_ key: String) -> Int? { number(entry[key]).map(Int.init) }
            func appendCounts(usedKey: String, limitKey: String, label: String, resetKey: String, statusKey: String) -> Bool {
                guard let used = number(entry[usedKey]), let limit = number(entry[limitKey]),
                      used >= 0, limit > 0, used <= limit else { return false }
                let state = status(statusKey)
                windows.append(Window(used: state == 2 ? limit : used, limit: limit, label: "\(rawName) · \(label)", resetAt: resetDate(resetKey), compactValue: state == 3 ? "∞" : nil, limited: state == 2))
                return true
            }
            func appendRemainingPercent(key: String, label: String, resetKey: String, statusKey: String, boost: Double = 1) {
                guard let remaining = number(entry[key]), remaining >= 0 else { return }
                let displayed = remaining * boost
                let state = status(statusKey)
                let bounded = min(displayed, 100)
                windows.append(Window(used: state == 2 ? 100 : max(0, 100 - bounded), limit: 100, label: "\(rawName) · \(label)", resetAt: resetDate(resetKey), compactValue: state == 3 ? "∞" : (displayed > 100 ? "\(Int(displayed.rounded()))% übrig" : nil), limited: state == 2))
            }
            if !appendCounts(usedKey: "current_interval_usage_count", limitKey: "current_interval_total_count", label: "5 Stunden", resetKey: "end_time", statusKey: "current_interval_status") {
                appendRemainingPercent(key: "current_interval_remaining_percent", label: "5 Stunden", resetKey: "end_time", statusKey: "current_interval_status")
            }
            let boost = max(1, (number(entry["weekly_boost_permille"]) ?? 1_000) / 1_000)
            if !appendCounts(usedKey: "current_weekly_usage_count", limitKey: "current_weekly_total_count", label: "Woche", resetKey: "weekly_end_time", statusKey: "current_weekly_status") {
                appendRemainingPercent(key: "current_weekly_remaining_percent", label: "Woche", resetKey: "weekly_end_time", statusKey: "current_weekly_status", boost: boost)
            }
        }
        guard let worst = windows.max(by: { $0.fraction < $1.fraction }) else { return nil }
        let formatter = ISO8601DateFormatter()
        let summaries = windows
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            .map { window in
                let reset = window.resetAt.map { " · Reset \(formatter.string(from: $0))" } ?? ""
                return "\(window.label) \(Int((window.fraction * 100).rounded())) % genutzt\(reset)"
            }
            .joined(separator: "; ")
        let observedAt = Date()
        var signals = windows.map {
            CapacitySignal(kind: .quota, label: $0.label, used: $0.used, limit: $0.limit, compactValue: $0.compactValue, resetAt: $0.resetAt, observedAt: observedAt, source: "MiniMax Token Plan", scope: "Account", limited: $0.limited)
        }
        signals += [
            CapacitySignal(kind: .rate, label: "M3 Anfragen", compactValue: "200/m", observedAt: observedAt, source: "MiniMax-Dokumentation", scope: "M3", evidence: .published),
            CapacitySignal(kind: .rate, label: "M3 Tokens", compactValue: "10M/m", observedAt: observedAt, source: "MiniMax-Dokumentation", scope: "M3", evidence: .published)
        ]
        return MiniMaxCapacityMeasurement(
            capacity: .observed(signals: signals, reason: nil),
            summary: summaries,
            resetAt: worst.resetAt
        )
    }

    public static func parseMiniMaxBalance(_ data: Data) -> MiniMaxCapacityMeasurement? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balance = number(root["available_balance"] ?? (root["data"] as? [String: Any])?["available_balance"]), balance >= 0 else { return nil }
        let currency = (root["currency"] as? String) ?? ((root["data"] as? [String: Any])?["currency"] as? String) ?? "USD"
        let value = currency.uppercased() == "USD" ? String(format: "$%.2f", balance) : "\(balance) \(currency)"
        let signal = CapacitySignal(kind: .quota, label: "PAYG-Guthaben", compactValue: value, source: "MiniMax Kontostand", scope: "Account")
        return MiniMaxCapacityMeasurement(capacity: .observed(signals: [signal], reason: nil), summary: "Verfügbar \(value)", resetAt: nil)
    }

    public struct ZAIUsageMeasurement: Equatable, Sendable {
        public var capacity: CapacityStatus
        public var summary: String
    }

    public static func parseZAIUsage(_ data: Data, observedAt: Date = Date()) -> ZAIUsageMeasurement? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (root["data"] as? [String: Any]) ?? root
        guard let entries = payload["limits"] as? [[String: Any]] else { return nil }
        let tier = nonempty(payload["level"])?.capitalized
        var signals: [CapacitySignal] = []
        for entry in entries {
            guard let type = nonempty(entry["type"])?.uppercased(), let percentage = number(entry["percentage"]), (0...100).contains(percentage) else { continue }
            let windowNumber = number(entry["number"]).map(Int.init)
            let unit = number(entry["unit"]).map(Int.init)
            let label: String
            if type == "TOKENS_LIMIT", windowNumber == 5, unit == 3 { label = "5 Stunden" }
            else if type == "TOKENS_LIMIT", windowNumber == 1, unit == 6 { label = "Woche" }
            else if type == "TIME_LIMIT", windowNumber == 1, unit == 5 { label = "Web/MCP · Monat" }
            else { continue }
            let reset = timestamp(entry["nextResetTime"] ?? entry["next_reset_time"])
            signals.append(CapacitySignal(kind: .quota, label: label, used: percentage, limit: 100, resetAt: reset, observedAt: observedAt, source: "Z.ai Coding Plan", scope: type == "TIME_LIMIT" ? "Web/MCP" : "Modelle", limited: percentage >= 100))
        }
        guard !signals.isEmpty else { return nil }
        if let tier {
            signals.append(CapacitySignal(kind: .rate, label: "Dynamische Parallelität", compactValue: "\(tier) · dyn.", observedAt: observedAt, source: "Z.ai Coding Plan", scope: "Account"))
        }
        let summary = signals.filter { $0.kind == .quota }.map { "\($0.label) \(Int(($0.fraction ?? 0) * 100)) % genutzt" }.joined(separator: "; ")
        return ZAIUsageMeasurement(capacity: .observed(signals: signals, reason: nil), summary: summary)
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func timestamp(_ value: Any?) -> Date? {
        if let text = value as? String {
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            if let number = Double(text) { return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number) }
        }
        guard let number = number(value), number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    public static func parseModels(_ data: Data, provider: ModelProvider? = nil) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return nil }
        let filtered = entries.filter { entry in
            guard let provider else { return true }
            guard let owner = (entry["owned_by"] as? String)?.lowercased() else {
                return provider.usesWebLogin == false
            }
            return provider.modelOwnerAliases.contains(owner)
        }
        return Provider.normalizedModels(filtered.compactMap { $0["id"] as? String })
    }
}

public struct CLIProxyInspector: Sendable {
    public let client: any HTTPClient
    public let credentials: any CredentialStoring
    public init(client: any HTTPClient = URLSessionHTTPClient(), credentials: any CredentialStoring = PrivateFileCredentialStore()) {
        self.client = client
        self.credentials = credentials
    }

    public func inspect(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
        guard let baseURL = URL(string: configuration.endpoint), isSafeLoopback(baseURL) else {
            return CLIProxyStatus(endpoint: configuration.endpoint, state: .unsafeEndpoint, detail: "Nur Loopback-Endpunkte (localhost, 127.0.0.0/8 oder ::1) sind erlaubt.", capacity: .unavailable(reason: "Kapazität ist für einen unsicheren Endpunkt nicht abrufbar."))
        }
        let inferenceURL = baseURL.appendingPathComponent("v1/models")
        var reachability = URLRequest(url: inferenceURL)
        reachability.httpMethod = "GET"
        if let reference = configuration.inferenceCredentialReference,
           let secret = try? credentials.read(reference: reference),
           let token = String(data: secret, encoding: .utf8) {
            reachability.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let response: HTTPResponse
        do { response = try await client.request(reachability) }
        catch {
            return CLIProxyStatus(endpoint: configuration.endpoint, state: .offline, detail: "Loopback-Endpunkt ist nicht erreichbar.", capacity: .unavailable(reason: "CLIProxy ist offline."))
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            return CLIProxyStatus(endpoint: configuration.endpoint, state: .authRequired, detail: "Der Inferenz-Endpunkt verlangt eine eigene Inferenz-Berechtigung.", capacity: .unavailable(reason: "Inferenz-Authentifizierung erforderlich."))
        }
        guard (200..<300).contains(response.statusCode) else {
            return CLIProxyStatus(endpoint: configuration.endpoint, state: .offline, detail: "Die konkrete Inferenzroute /v1/models antwortet mit HTTP \(response.statusCode).", capacity: .unavailable(reason: "CLIProxy-Inferenzroute ist nicht verfügbar."))
        }
        guard configuration.usageStatisticsEnabled else {
            return CLIProxyStatus(endpoint: configuration.endpoint, state: .usageDisabled, detail: "CLIProxy ist erreichbar; lokale Nutzungsstatistik ist deaktiviert.", capacity: .unavailable(reason: "Lokale CLIProxy-Nutzungsstatistik ist deaktiviert."))
        }
        guard let managementReference = configuration.managementCredentialReference, !managementReference.isEmpty,
              managementReference != configuration.inferenceCredentialReference else {
            return CLIProxyStatus(endpoint: configuration.endpoint, state: .managementUnavailable, detail: "CLIProxy ist erreichbar; eine vom Inferenzzugang getrennte Management-Keychain-Referenz fehlt.", capacity: .unavailable(reason: "Kein separater CLIProxy-Management-Schlüssel konfiguriert."))
        }
        guard let secret = try? credentials.read(reference: managementReference),
              let managementToken = String(data: secret, encoding: .utf8), !managementToken.isEmpty else {
            return CLIProxyStatus(endpoint: configuration.endpoint, state: .managementUnavailable, detail: "Die Management-Keychain-Referenz enthält kein verfügbares Geheimnis.", capacity: .unavailable(reason: "CLIProxy-Management-Zugang ist nicht verfügbar."))
        }
        let usageURL = baseURL.appendingPathComponent("v0/management/usage")
        var usageRequest = URLRequest(url: usageURL)
        usageRequest.httpMethod = "GET"
        usageRequest.setValue("Bearer \(managementToken)", forHTTPHeaderField: "Authorization")
        usageRequest.setValue(managementToken, forHTTPHeaderField: "X-Management-Key")
        do {
            let usage = try await client.request(usageRequest)
            guard (200..<300).contains(usage.statusCode) else {
                return CLIProxyStatus(endpoint: configuration.endpoint, state: .managementUnavailable, detail: "Management-Endpunkt antwortet mit HTTP \(usage.statusCode).", capacity: .unavailable(reason: "CLIProxy-Management-Endpunkt ist nicht verfügbar."))
            }
            guard let capacity = parseCapacity(usage.data) else {
                return CLIProxyStatus(endpoint: configuration.endpoint, state: .reachable, detail: "CLIProxy und Management sind erreichbar.", capacity: .unavailable(reason: "Nutzungsantwort enthält kein kompatibles, identitäts- und zeitfenstergebundenes Paar aus Verbrauch und Limit."))
            }
            return CLIProxyStatus(endpoint: configuration.endpoint, state: .reachable, detail: "CLIProxy und Management-Nutzungsstatistik sind erreichbar.", capacity: capacity)
        } catch {
            return CLIProxyStatus(endpoint: configuration.endpoint, state: .managementUnavailable, detail: "CLIProxy ist erreichbar, der Management-Endpunkt jedoch nicht.", capacity: .unavailable(reason: "CLIProxy-Management-Endpunkt ist nicht erreichbar."))
        }
    }

    public func isSafeLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let pieces = host.split(separator: ".")
        return pieces.count == 4 && pieces[0] == "127" && pieces.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }

    private func parseCapacity(_ data: Data) -> CapacityStatus? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return capacity(in: json)
    }

    private func capacity(in value: Any) -> CapacityStatus? {
        if let dictionary = value as? [String: Any] {
            let used = number(dictionary["used"])
            let limit = number(dictionary["limit"])
            let window = nonemptyString(dictionary["window"]) ?? nonemptyString(dictionary["period"])
            let identity = nonemptyString(dictionary["identity"]) ?? nonemptyString(dictionary["account_id"]) ?? nonemptyString(dictionary["model"])
            if let used, let limit, let window, let identity, limit > 0, used >= 0, used <= limit {
                let unit = dictionary["unit"] as? String ?? "Einheiten"
                let limited = dictionary["rate_limited"] as? Bool ?? dictionary["rateLimited"] as? Bool ?? false
                return .measured(used: used, limit: limit, unit: "\(unit) · \(window) · \(identity)", rateLimited: limited)
            }
            for nested in dictionary.values { if let found = capacity(in: nested) { return found } }
        } else if let array = value as? [Any] {
            for nested in array { if let found = capacity(in: nested) { return found } }
        }
        return nil
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func nonemptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
