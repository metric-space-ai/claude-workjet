import Foundation

public struct TailscaleDevice: Identifiable, Equatable, Sendable {
    public var id: String
    public var hostname: String
    public var dnsName: String?
    public var ipv4: String?
    public var online: Bool
    public var os: String?

    public init(id: String, hostname: String, dnsName: String? = nil, ipv4: String? = nil, online: Bool, os: String? = nil) {
        self.id = id
        self.hostname = hostname
        self.dnsName = dnsName
        self.ipv4 = ipv4
        self.online = online
        self.os = os
    }

    /// The Tailscale IP is the reliable transport address even when MagicDNS
    /// is disabled or temporarily unavailable on the Mac. DNS remains visible
    /// in the picker, but must not make an otherwise online peer unreachable.
    public var preferredHost: String { ipv4 ?? dnsName ?? hostname }
}

public enum TailscaleDeviceError: LocalizedError, Equatable {
    case unavailable
    case notConnected(String)
    case commandFailed(String)
    case outputTooLarge
    case malformedStatus

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Tailscale wurde auf diesem Mac nicht gefunden."
        case .notConnected: return "Tailscale ist nicht verbunden. Öffne Tailscale und versuche es erneut."
        case .commandFailed: return "Die Tailscale-Geräteliste konnte nicht geladen werden. Öffne Tailscale und versuche es erneut."
        case .outputTooLarge, .malformedStatus: return "Die Tailscale-Geräteliste konnte nicht geladen werden. Versuche es erneut."
        }
    }
}

public enum TailscaleDeviceParser {
    public static func parse(_ data: Data) throws -> [TailscaleDevice] {
        guard data.count <= 1_048_576 else { throw TailscaleDeviceError.outputTooLarge }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw TailscaleDeviceError.malformedStatus }
        guard let root = value as? [String: Any] else { throw TailscaleDeviceError.malformedStatus }
        if let state = root["BackendState"] as? String, state.caseInsensitiveCompare("Running") != .orderedSame {
            throw TailscaleDeviceError.notConnected(state)
        }
        let selfID = stableID(root["Self"] as? [String: Any])
        guard let peers = root["Peer"] as? [String: Any] else { return [] }
        var devices: [TailscaleDevice] = []
        for (key, raw) in peers {
            guard let peer = raw as? [String: Any] else { continue }
            let id = stableID(peer) ?? key
            guard id != selfID else { continue }
            let hostname = string(peer["HostName"]) ?? trimmedDNS(peer["DNSName"]) ?? id
            let dnsName = trimmedDNS(peer["DNSName"])
            let ipv4 = (peer["TailscaleIPs"] as? [Any])?.compactMap(string).first { address in
                address.range(of: #"^\d{1,3}(?:\.\d{1,3}){3}$"#, options: .regularExpression) != nil
            }
            devices.append(TailscaleDevice(
                id: id,
                hostname: hostname,
                dnsName: dnsName,
                ipv4: ipv4,
                online: peer["Online"] as? Bool ?? false,
                os: string(peer["OS"])
            ))
        }
        return devices.sorted {
            if $0.online != $1.online { return $0.online && !$1.online }
            let hostOrder = $0.hostname.localizedCaseInsensitiveCompare($1.hostname)
            return hostOrder == .orderedSame ? $0.id < $1.id : hostOrder == .orderedAscending
        }
    }

    private static func stableID(_ value: [String: Any]?) -> String? {
        guard let value else { return nil }
        for key in ["ID", "StableID", "NodeKey", "PublicKey"] {
            if let result = string(value[key]) { return result }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmedDNS(_ value: Any?) -> String? {
        string(value)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

public struct TailscaleDeviceDiscovery: Sendable {
    private let runner: any CommandRunning
    private let locator: any TailscaleLocating

    public init(runner: any CommandRunning = ProcessCommandRunner(), locator: any TailscaleLocating = AllowlistedTailscaleLocator()) {
        self.runner = runner
        self.locator = locator
    }

    public func discover() async throws -> [TailscaleDevice] {
        guard let executable = locator.executablePath(), AllowlistedTailscaleLocator.allowedPaths.contains(executable) else {
            throw TailscaleDeviceError.unavailable
        }
        do {
            return try await discover(executable: executable)
        } catch TailscaleDeviceError.malformedStatus {
            // A local Tailscale process can occasionally exit successfully
            // while stdout capture is empty or partial. Retry exactly once;
            // every semantic or transport failure still fails immediately.
            return try await discover(executable: executable)
        }
    }

    private func discover(executable: String) async throws -> [TailscaleDevice] {
        let result: CommandResult
        do {
            result = try await runner.run(CommandSpec(executable: executable, arguments: ["status", "--json"], timeout: 3, stdoutLimit: 1_048_576, stderrLimit: 16_384))
        } catch {
            throw TailscaleDeviceError.commandFailed(error.localizedDescription)
        }
        guard !result.stdoutTruncated else { throw TailscaleDeviceError.outputTooLarge }
        guard result.exitCode == 0 else {
            let detail = String(decoding: result.standardError.prefix(1_024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TailscaleDeviceError.commandFailed(detail.isEmpty ? "Exit \(result.exitCode)" : detail)
        }
        return try TailscaleDeviceParser.parse(result.standardOutput)
    }
}
