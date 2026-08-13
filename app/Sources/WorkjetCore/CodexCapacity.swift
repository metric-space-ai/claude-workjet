import Foundation

public struct CodexCapacitySnapshot: Equatable, Sendable {
    public var accountEmail: String
    public var plan: String?
    public var capacity: CapacityStatus

    public init(accountEmail: String, plan: String?, capacity: CapacityStatus) {
        self.accountEmail = accountEmail
        self.plan = plan
        self.capacity = capacity
    }

    public func capacity(matchingAccountLabel label: String?) -> CapacityStatus? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty,
              accountEmail.caseInsensitiveCompare(label) == .orderedSame else { return nil }
        return capacity
    }
}

/// Reads ChatGPT/Codex subscription windows from Codex's documented local
/// app-server protocol. It never opens or parses Codex credential files.
public struct CodexAppServerCapacityReader: Sendable {
    private let runner: any CommandRunning
    private let executableCandidates: [String]

    public init(runner: any CommandRunning = ProcessCommandRunner(), executableCandidates: [String] = CodexAppServerCapacityReader.defaultExecutableCandidates) {
        self.runner = runner
        self.executableCandidates = executableCandidates
    }

    public static var defaultExecutableCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex"
        ]
    }

    public func read() async -> CodexCapacitySnapshot? {
        guard let executable = executableCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        // App-server processes one request at a time. The short pauses keep stdin
        // open until each response has been emitted; closing it immediately can
        // legitimately terminate the server after `initialize`.
        let script = #"""
        set -eu
        {
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"workjet","version":"0.1.0"},"capabilities":{}}}'
          sleep 0.15
          printf '%s\n' '{"jsonrpc":"2.0","method":"initialized","params":{}}'
          sleep 0.10
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"account/read","params":{}}'
          sleep 0.25
          printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"account/rateLimits/read","params":{}}'
          # `account/rateLimits/read` may refresh its cache before replying.
          # Closing stdin after only 500 ms races that response in the real
          # Codex app-server and leaves Workjet with an account but no quota.
          sleep 3
        } | "$1" app-server --stdio
        """#
        guard let result = try? await runner.run(CommandSpec(
            executable: "/bin/sh",
            arguments: ["-c", script, "workjet-codex-capacity", executable],
            currentDirectory: NSTemporaryDirectory(),
            timeout: 8,
            stdoutLimit: 1_048_576,
            stderrLimit: 65_536
        )), result.exitCode == 0, !result.stdoutTruncated else { return nil }
        return Self.parse(result.standardOutput)
    }

    public static func parse(_ output: Data, observedAt: Date = Date()) -> CodexCapacitySnapshot? {
        var email: String?
        var plan: String?
        var rateLimits: [String: Any]?
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \Character.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue,
                  let result = object["result"] as? [String: Any] else { continue }
            if id == 2, let account = result["account"] as? [String: Any] {
                email = (account["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                plan = account["planType"] as? String
            } else if id == 3 {
                rateLimits = result
            }
        }
        guard let email, !email.isEmpty, let rateLimits else { return nil }
        let rawLimits = rateLimits["rateLimitsByLimitId"] as? [String: Any]
        let limits: [[String: Any]]
        if let rawLimits {
            limits = rawLimits.keys.sorted().compactMap { rawLimits[$0] as? [String: Any] }
        } else if let single = rateLimits["rateLimits"] as? [String: Any] {
            limits = [single]
        } else {
            return nil
        }
        var signals: [CapacitySignal] = []
        for limit in limits {
            let limitName = nonempty(limit["limitName"] as? String)
            let limitID = nonempty(limit["limitId"] as? String) ?? "Codex"
            let scope = limitName ?? limitID
            let limited = limit["rateLimitReachedType"] is String
            for key in ["primary", "secondary"] {
                guard let window = limit[key] as? [String: Any],
                      let used = number(window["usedPercent"]), (0...100).contains(used),
                      let minutes = number(window["windowDurationMins"]), minutes > 0 else { continue }
                let resetAt = number(window["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
                signals.append(CapacitySignal(
                    kind: .quota,
                    label: windowLabel(minutes: minutes, fallback: key.capitalized),
                    used: used,
                    limit: 100,
                    resetAt: resetAt,
                    observedAt: observedAt,
                    source: "Codex app-server",
                    scope: scope,
                    limited: limited || used >= 100
                ))
            }
        }
        guard !signals.isEmpty else { return nil }
        return CodexCapacitySnapshot(accountEmail: email, plan: plan, capacity: .observed(signals: signals, reason: nil))
    }

    private static func windowLabel(minutes: Double, fallback: String) -> String {
        if abs(minutes - 300) < 1 { return "5 Stunden" }
        if abs(minutes - 10_080) < 1 { return "Woche" }
        if minutes.truncatingRemainder(dividingBy: 1_440) == 0 { return "\(Int(minutes / 1_440)) Tage" }
        if minutes.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(minutes / 60)) Stunden" }
        return fallback
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
