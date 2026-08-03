import Foundation
import Security

public protocol CredentialStoring: Sendable {
    func read(reference: String) throws -> Data?
    func write(_ secret: Data, reference: String) throws
    func delete(reference: String) throws
}

public struct KeychainCredentialStore: CredentialStoring, Sendable {
    public let service: String
    public init(service: String = "dev.workjet.app") { self.service = service }

    public func read(reference: String) throws -> Data? {
        var query = base(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        return result as? Data
    }

    public func write(_ secret: Data, reference: String) throws {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CredentialError.emptyReference }
        let query = base(reference)
        let update = [kSecValueData as String: secret]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = secret
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
        } else if status != errSecSuccess { throw CredentialError.keychain(status) }
    }

    public func delete(reference: String) throws {
        let status = SecItemDelete(base(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }

    private func base(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }
}

public enum CredentialError: LocalizedError {
    case emptyReference
    case keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .emptyReference: return "Keychain-Referenz darf nicht leer sein."
        case let .keychain(status): return "Keychain-Fehler \(status)."
        }
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var data: Data
    public init(statusCode: Int, data: Data) { self.statusCode = statusCode; self.data = data }
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
        return HTTPResponse(statusCode: http.statusCode, data: data)
    }
}

public struct CLIProxyInspector: Sendable {
    public let client: any HTTPClient
    public let credentials: any CredentialStoring
    public init(client: any HTTPClient = URLSessionHTTPClient(), credentials: any CredentialStoring = KeychainCredentialStore()) {
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
