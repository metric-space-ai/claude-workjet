import CryptoKit
import Foundation

public enum RemotePiBootstrapError: LocalizedError, Equatable {
    case localComputer
    case invalidHost
    case invalidUser
    case invalidPort
    case missingKnownHosts
    case tailscaleUnavailable
    case invalidBundle(String)
    case commandFailed(String)
    case preflightBlocked(String)
    case invalidPreflight

    public var errorDescription: String? {
        switch self {
        case .localComputer: return "Der lokale Computer kann nicht als Remote-Ziel eingerichtet werden."
        case .invalidHost: return "Host ist leer oder enthält nicht erlaubte Zeichen."
        case .invalidUser: return "SSH-Benutzer ist leer oder enthält nicht erlaubte Zeichen."
        case .invalidPort: return "SSH-Port liegt außerhalb von 1…65535."
        case .missingKnownHosts: return "SSH benötigt eine private, reguläre known-hosts-Datei. Host-Key-Aufnahme und -Freigabe erfolgen bewusst außerhalb von Workjet."
        case .tailscaleUnavailable: return "Kein unterstütztes Tailscale-Executable wurde gefunden; Workjet fällt nicht auf gewöhnliche Netzwerk-SSH-Verbindungen zurück."
        case let .invalidBundle(detail): return "Sidecar-Bundle ist ungültig: \(detail)"
        case let .commandFailed(detail): return detail
        case let .preflightBlocked(detail): return "Remote-Preflight blockiert: \(detail)"
        case .invalidPreflight: return "Remote-Preflight lieferte keine vollständig auswertbare Antwort."
        }
    }
}

public protocol OwnedFileReading: Sendable {
    func readOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data
    func readPrivateOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data
}

public extension OwnedFileReading {
    func readPrivateOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        try readOwnedRegularFile(at: url, maximumBytes: maximumBytes)
    }
}

public struct SecureOwnedFileReader: OwnedFileReading, Sendable {
    public init() {}
    public func readOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        try SecureFile.readRegularOwnedFile(at: url, maximumBytes: maximumBytes)
    }
    public func readPrivateOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        try SecureFile.checkPrivateRegularOwnedFile(at: url)
        return try SecureFile.readRegularOwnedFile(at: url, maximumBytes: maximumBytes)
    }
}

public protocol TailscaleLocating: Sendable {
    func executablePath() -> String?
}

public struct AllowlistedTailscaleLocator: TailscaleLocating, Sendable {
    public static let allowedPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale"
    ]
    public init() {}
    public func executablePath() -> String? {
        Self.allowedPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public enum RemoteCommandBuilder {
    public static func command(
        for computer: Computer,
        tailscaleExecutable: String?,
        remoteExecutable: String,
        remoteArguments: [String],
        standardInput: Data,
        timeout: TimeInterval
    ) throws -> CommandSpec {
        try validate(computer)
        guard remoteExecutable.hasPrefix("/") || remoteExecutable == "node" else {
            throw RemotePiBootstrapError.commandFailed("Remote-Executable ist nicht erlaubt.")
        }
        switch computer.transport {
        case .local:
            throw RemotePiBootstrapError.localComputer
        case .ssh:
            let knownHosts = computer.knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard knownHosts.hasPrefix("/") else { throw RemotePiBootstrapError.missingKnownHosts }
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=10",
                    "-o", "StrictHostKeyChecking=yes",
                    "-o", "UserKnownHostsFile=\(knownHosts)",
                    "-o", "ClearAllForwardings=yes",
                    "-p", String(computer.port),
                    "-l", computer.user,
                    "--", computer.host,
                    remoteExecutable
                ] + remoteArguments,
                standardInput: standardInput,
                timeout: timeout,
                stdoutLimit: 4 * 1_024 * 1_024,
                stderrLimit: 1 * 1_024 * 1_024
            )
        case .tailscale:
            guard let tailscaleExecutable else { throw RemotePiBootstrapError.tailscaleUnavailable }
            return CommandSpec(
                executable: tailscaleExecutable,
                arguments: ["ssh", "\(computer.user)@\(computer.host)", remoteExecutable] + remoteArguments,
                standardInput: standardInput,
                timeout: timeout,
                stdoutLimit: 4 * 1_024 * 1_024,
                stderrLimit: 1 * 1_024 * 1_024
            )
        }
    }

    public static func validate(_ computer: Computer) throws {
        guard !computer.isLocal else { throw RemotePiBootstrapError.localComputer }
        let hostPattern = #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$"#
        let userPattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#
        guard computer.host.range(of: hostPattern, options: .regularExpression) != nil else { throw RemotePiBootstrapError.invalidHost }
        guard computer.user.range(of: userPattern, options: .regularExpression) != nil else { throw RemotePiBootstrapError.invalidUser }
        guard (1...65535).contains(computer.port) else { throw RemotePiBootstrapError.invalidPort }
    }
}

public struct RemotePiBootstrap: Sendable {
    private let runner: any CommandRunning
    private let files: any OwnedFileReading
    private let tailscaleLocator: any TailscaleLocating
    private let now: @Sendable () -> Date

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        files: any OwnedFileReading = SecureOwnedFileReader(),
        tailscaleLocator: any TailscaleLocating = AllowlistedTailscaleLocator(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.files = files
        self.tailscaleLocator = tailscaleLocator
        self.now = now
    }

    public func deploy(_ input: Computer) async -> Computer {
        var computer = input
        computer.pinnedSidecarVersion = PiSidecarRuntime.version
        computer.deploymentStatus = .checking
        computer.deploymentDetail = "Lokales Bundle und Remote-Voraussetzungen werden geprüft."
        do {
            try RemoteCommandBuilder.validate(computer)
            let bundlePath = computer.sidecarBundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundlePath.isEmpty, bundlePath.hasPrefix("/"), !bundlePath.contains("\0") else { throw RemotePiBootstrapError.invalidBundle("Pfad muss absolut sein.") }
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let bundle: Data
            do { bundle = try files.readOwnedRegularFile(at: bundleURL, maximumBytes: 32 * 1_024 * 1_024) }
            catch { throw RemotePiBootstrapError.invalidBundle(error.localizedDescription) }
            guard !bundle.isEmpty else { throw RemotePiBootstrapError.invalidBundle("Datei ist leer.") }

            var tailscaleExecutable: String?
            if computer.transport == .ssh {
                let knownHostsPath = computer.knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard knownHostsPath.hasPrefix("/"), !knownHostsPath.contains("\0") else { throw RemotePiBootstrapError.missingKnownHosts }
                do { _ = try files.readPrivateOwnedRegularFile(at: URL(fileURLWithPath: knownHostsPath), maximumBytes: 1_024 * 1_024) }
                catch { throw RemotePiBootstrapError.missingKnownHosts }
            } else if computer.transport == .tailscale {
                tailscaleExecutable = tailscaleLocator.executablePath()
                guard tailscaleExecutable != nil else { throw RemotePiBootstrapError.tailscaleUnavailable }
                computer.tailscaleExecutablePath = tailscaleExecutable
            }

            let contentHash = Self.sha256(bundle)
            let preflight = try await execute(
                computer: computer,
                tailscaleExecutable: tailscaleExecutable,
                remoteExecutable: "/bin/sh",
                remoteArguments: ["-s", "--"],
                input: Data(Self.preflightScript.utf8),
                timeout: 20
            )
            let facts = try parsePreflight(preflight.standardOutput)
            guard facts.os == "Linux" else { throw RemotePiBootstrapError.preflightBlocked("unterstützt wird Linux, gefunden wurde \(facts.os).") }
            guard ["aarch64", "arm64", "armv7l", "x86_64"].contains(facts.arch) else { throw RemotePiBootstrapError.preflightBlocked("Architektur \(facts.arch) wird nicht unterstützt.") }
            guard facts.homeWritable else { throw RemotePiBootstrapError.preflightBlocked("HOME ist nicht beschreibbar.") }
            guard facts.hasShell else { throw RemotePiBootstrapError.preflightBlocked("`sh` fehlt.") }
            guard facts.nodeMajor >= 20 else { throw RemotePiBootstrapError.preflightBlocked("Node >=20 ist erforderlich; gefunden wurde \(facts.nodeVersion). Workjet installiert keine Pakete und lädt keinen Remote-Code nach.") }
            guard facts.shaTool == "sha256sum" || facts.shaTool == "shasum" else { throw RemotePiBootstrapError.preflightBlocked("weder sha256sum noch shasum ist verfügbar.") }
            computer.lastSuccessfulPreflightAt = now()

            try await requireSuccess(computer: computer, tailscaleExecutable: tailscaleExecutable, script: Self.prepareScript, positional: [contentHash], timeout: 20)

            let runnerData = Data(Self.turnRunnerSource.utf8)
            let bundleFileHash = Self.sha256(bundle)
            let runnerHash = Self.sha256(runnerData)
            let manifestData = try Self.manifest(contentHash: contentHash, bundleHash: bundleFileHash, runnerHash: runnerHash)
            let manifestHash = Self.sha256(manifestData)

            try await upload(bundle, named: "ctox-pi-sidecar.mjs", contentHash: contentHash, expectedHash: bundleFileHash, computer: computer, tailscaleExecutable: tailscaleExecutable)
            try await upload(runnerData, named: "workjet-pi-turn.mjs", contentHash: contentHash, expectedHash: runnerHash, computer: computer, tailscaleExecutable: tailscaleExecutable)
            try await upload(manifestData, named: "manifest.json", contentHash: contentHash, expectedHash: manifestHash, computer: computer, tailscaleExecutable: tailscaleExecutable)

            try await requireSuccess(
                computer: computer,
                tailscaleExecutable: tailscaleExecutable,
                script: Self.finalizeScript,
                positional: [contentHash, bundleFileHash, runnerHash, manifestHash],
                timeout: 30
            )

            computer.deploymentStatus = .installed
            computer.deploymentDetail = "Pi-Sidecar \(PiSidecarRuntime.version) wurde inhaltadressiert installiert. Echtmodell-Inferenz bleibt ohne separaten Loopback-Relay nicht verfügbar; Faux-/Offline-Turns können geprüft werden."
            computer.installedContentHash = contentHash
            computer.installedSidecarVersion = PiSidecarRuntime.version
            computer.lastSuccessfulDeploymentAt = now()
            return computer
        } catch let error as RemotePiBootstrapError {
            computer.deploymentStatus = error.isBlocked ? .blocked : .failed
            computer.deploymentDetail = error.localizedDescription
            computer.installedContentHash = nil
            computer.installedSidecarVersion = nil
            return computer
        } catch {
            computer.deploymentStatus = .failed
            computer.deploymentDetail = error.localizedDescription
            computer.installedContentHash = nil
            computer.installedSidecarVersion = nil
            return computer
        }
    }

    private func upload(_ data: Data, named name: String, contentHash: String, expectedHash: String, computer: Computer, tailscaleExecutable: String?) async throws {
        guard ["ctox-pi-sidecar.mjs", "workjet-pi-turn.mjs", "manifest.json"].contains(name) else {
            throw RemotePiBootstrapError.commandFailed("Nicht erlaubter Deployment-Dateiname.")
        }
        let input = Data(Self.uploadProgram(data: data).utf8)
        _ = try await execute(
            computer: computer,
            tailscaleExecutable: tailscaleExecutable,
            remoteExecutable: "node",
            remoteArguments: ["--input-type=module", "-", contentHash, name, expectedHash],
            input: input,
            timeout: 60
        )
    }

    private func requireSuccess(computer: Computer, tailscaleExecutable: String?, script: String, positional: [String], timeout: TimeInterval) async throws {
        _ = try await execute(
            computer: computer,
            tailscaleExecutable: tailscaleExecutable,
            remoteExecutable: "/bin/sh",
            remoteArguments: ["-s", "--"] + positional,
            input: Data(script.utf8),
            timeout: timeout
        )
    }

    private func execute(computer: Computer, tailscaleExecutable: String?, remoteExecutable: String, remoteArguments: [String], input: Data, timeout: TimeInterval) async throws -> CommandResult {
        let command = try RemoteCommandBuilder.command(for: computer, tailscaleExecutable: tailscaleExecutable, remoteExecutable: remoteExecutable, remoteArguments: remoteArguments, standardInput: input, timeout: timeout)
        let result = try await runner.run(command)
        guard result.exitCode == 0 else {
            let stderr = String(decoding: result.standardError.prefix(2_048), as: UTF8.self)
            if computer.transport == .ssh && (stderr.localizedCaseInsensitiveContains("host key verification failed") || stderr.localizedCaseInsensitiveContains("known hosts")) {
                throw RemotePiBootstrapError.commandFailed("Strikte Host-Key-Prüfung ist fehlgeschlagen. Bitte den Host-Key außerhalb von Workjet prüfen und in der privaten known-hosts-Datei freigeben; Workjet verwendet weder `StrictHostKeyChecking=no` noch `accept-new`.")
            }
            throw RemotePiBootstrapError.commandFailed("Remote-Befehl ist mit Status \(result.exitCode) fehlgeschlagen: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard !result.stdoutTruncated, !result.stderrTruncated else { throw RemotePiBootstrapError.commandFailed("Remote-Ausgabe überschritt das Sicherheitslimit.") }
        return result
    }

    private func parsePreflight(_ data: Data) throws -> PreflightFacts {
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        var values: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard let os = values["WORKJET_OS"], let arch = values["WORKJET_ARCH"], let node = values["WORKJET_NODE"] else {
            throw RemotePiBootstrapError.invalidPreflight
        }
        let major = Int(node.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").first ?? "") ?? 0
        return PreflightFacts(os: os, arch: arch, homeWritable: values["WORKJET_HOME_WRITABLE"] == "1", hasShell: values["WORKJET_SH"] == "1", nodeVersion: node, nodeMajor: major, shaTool: values["WORKJET_SHA"] ?? "")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func manifest(contentHash: String, bundleHash: String, runnerHash: String) throws -> Data {
        let value = DeploymentManifest(
            schema: 1,
            version: PiSidecarRuntime.version,
            contentHash: contentHash,
            files: [
                "ctox-pi-sidecar.mjs": bundleHash,
                "workjet-pi-turn.mjs": runnerHash
            ],
            inference: "remote-real-model-unavailable-without-loopback-relay",
            events: "post-hoc-final-response"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func uploadProgram(data: Data) -> String {
        let encoded = data.base64EncodedString()
        return #"""
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
const [contentHash, name, expectedHash] = process.argv.slice(2);
if (!/^[0-9a-f]{64}$/.test(contentHash) || !/^[0-9a-f]{64}$/.test(expectedHash) || !["ctox-pi-sidecar.mjs", "workjet-pi-turn.mjs", "manifest.json"].includes(name)) process.exit(64);
process.umask(0o077);
const home = os.homedir();
const directories = [path.join(home, ".local"), path.join(home, ".local", "lib"), path.join(home, ".local", "lib", "workjet"), path.join(home, ".local", "lib", "workjet", "releases")];
const release = path.join(directories[3], contentHash);
for (const directory of [...directories, release]) {
  const info = fs.lstatSync(directory);
  if (!info.isDirectory() || info.isSymbolicLink()) process.exit(73);
}
const payload = Buffer.from("\#(encoded)", "base64");
if (crypto.createHash("sha256").update(payload).digest("hex") !== expectedHash) process.exit(65);
const temporary = path.join(release, `.${name}.tmp-${process.pid}`);
fs.writeFileSync(temporary, payload, {mode: 0o600, flag: "wx"});
fs.renameSync(temporary, path.join(release, name));
"""#
    }

    public static let preflightScript = #"""
set -eu
umask 077
printf 'WORKJET_OS=%s\n' "$(uname -s)"
printf 'WORKJET_ARCH=%s\n' "$(uname -m)"
if [ -n "${HOME:-}" ] && [ -d "$HOME" ] && [ -w "$HOME" ]; then printf 'WORKJET_HOME_WRITABLE=1\n'; else printf 'WORKJET_HOME_WRITABLE=0\n'; fi
if command -v sh >/dev/null 2>&1; then printf 'WORKJET_SH=1\n'; else printf 'WORKJET_SH=0\n'; fi
if command -v node >/dev/null 2>&1; then printf 'WORKJET_NODE=%s\n' "$(node --version)"; else printf 'WORKJET_NODE=missing\n'; fi
if command -v sha256sum >/dev/null 2>&1; then printf 'WORKJET_SHA=sha256sum\n'; elif command -v shasum >/dev/null 2>&1; then printf 'WORKJET_SHA=shasum\n'; else printf 'WORKJET_SHA=missing\n'; fi
"""#

    public static let prepareScript = #"""
set -eu
umask 077
hash="$1"
case "$hash" in *[!0-9a-f]*|'') exit 64;; esac
[ "${#hash}" -eq 64 ] || exit 64
local_root="$HOME/.local"
lib="$local_root/lib"
root="$lib/workjet"
releases="$root/releases"
release="$releases/$hash"
for directory in "$local_root" "$lib" "$root" "$releases" "$release"; do
  if [ -L "$directory" ] || { [ -e "$directory" ] && [ ! -d "$directory" ]; }; then exit 73; fi
done
mkdir -p "$release"
chmod 700 "$local_root" "$lib" "$root" "$releases" "$release"
"""#

    public static let finalizeScript = #"""
set -eu
umask 077
hash="$1"; bundle_hash="$2"; runner_hash="$3"; manifest_hash="$4"
for value in "$hash" "$bundle_hash" "$runner_hash" "$manifest_hash"; do case "$value" in *[!0-9a-f]*|'') exit 64;; esac; [ "${#value}" -eq 64 ] || exit 64; done
root="$HOME/.local/lib/workjet"
releases="$root/releases"
release="$releases/$hash"
for directory in "$HOME/.local" "$HOME/.local/lib" "$root" "$releases" "$release"; do [ -d "$directory" ] && [ ! -L "$directory" ] || exit 73; done
if command -v sha256sum >/dev/null 2>&1; then
  check() { [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ]; }
elif command -v shasum >/dev/null 2>&1; then
  check() { [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]; }
else
  exit 69
fi
check "$release/ctox-pi-sidecar.mjs" "$bundle_hash"
check "$release/workjet-pi-turn.mjs" "$runner_hash"
check "$release/manifest.json" "$manifest_hash"
chmod 600 "$release/ctox-pi-sidecar.mjs" "$release/workjet-pi-turn.mjs" "$release/manifest.json"
if { [ -e "$root/current" ] || [ -L "$root/current" ]; } && [ ! -L "$root/current" ]; then exit 73; fi
node - "$root" "$hash" <<'WORKJET_NODE'
const fs = require("node:fs");
const path = require("node:path");
const [root, hash] = process.argv.slice(2);
if (!/^[0-9a-f]{64}$/.test(hash)) process.exit(64);
const current = path.join(root, "current");
const temporary = path.join(root, `.current-${hash}-${process.pid}`);
try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== "ENOENT") throw error; }
fs.symlinkSync(path.join("releases", hash), temporary);
fs.renameSync(temporary, current);
WORKJET_NODE
"""#

    public static let turnRunnerSource = #"""
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import {spawn} from "node:child_process";
const REQUEST_LIMIT = 1024 * 1024;
const RESPONSE_LIMIT = 4 * 1024 * 1024;
const TIMEOUT_MS = 120000;
const release = path.dirname(new URL(import.meta.url).pathname);
const daemonFile = path.join(release, "ctox-pi-sidecar.mjs");
const privateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "workjet-pi-"));
fs.chmodSync(privateDirectory, 0o700);
const socketPath = path.join(privateDirectory, "turn.sock");
let daemon;
let socket;
const cleanup = async () => {
  if (socket) socket.destroy();
  if (daemon && daemon.exitCode === null) {
    daemon.kill("SIGTERM");
    await Promise.race([new Promise(resolve => daemon.once("exit", resolve)), new Promise(resolve => setTimeout(resolve, 1000))]);
    if (daemon.exitCode === null) {
      daemon.kill("SIGKILL");
      await new Promise(resolve => daemon.once("exit", resolve));
    }
  }
  try { fs.rmSync(privateDirectory, {recursive: true, force: true}); } catch {}
};
const fail = async message => { await cleanup(); process.stderr.write(`workjet-pi-turn: ${message}\n`); process.exit(1); };
const hardTimer = setTimeout(() => { void fail("execution timeout"); }, TIMEOUT_MS);
let request = Buffer.alloc(0);
for await (const chunk of process.stdin) {
  request = Buffer.concat([request, chunk]);
  if (request.length > REQUEST_LIMIT) await fail("request limit exceeded");
}
const lines = request.toString("utf8").split(/\r?\n/).filter(Boolean);
if (lines.length !== 1) await fail("exactly one NDJSON request is required");
try { JSON.parse(lines[0]); } catch { await fail("request is not JSON"); }
const cleanEnvironment = {HOME: process.env.HOME ?? "", PATH: process.env.PATH ?? "/usr/bin:/bin", TMPDIR: privateDirectory};
daemon = spawn(process.execPath, [daemonFile, "--socket", socketPath], {cwd: release, env: cleanEnvironment, stdio: ["ignore", "ignore", "ignore"]});
const deadline = Date.now() + 5000;
while (!fs.existsSync(socketPath)) {
  if (daemon.exitCode !== null) await fail("sidecar exited before socket became ready");
  if (Date.now() >= deadline) await fail("sidecar socket timeout");
  await new Promise(resolve => setTimeout(resolve, 25));
}
socket = net.createConnection(socketPath);
await new Promise((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
socket.write(lines[0] + "\n");
let response = Buffer.alloc(0);
const timer = setTimeout(() => socket.destroy(new Error("turn timeout")), TIMEOUT_MS);
try {
  for await (const chunk of socket) {
    response = Buffer.concat([response, chunk]);
    if (response.length > RESPONSE_LIMIT) throw new Error("response limit exceeded");
    const newline = response.indexOf(10);
    if (newline >= 0) { response = response.subarray(0, newline); break; }
  }
  JSON.parse(response.toString("utf8"));
  process.stdout.write(response);
  process.stdout.write("\n");
} catch (error) {
  clearTimeout(timer);
  await fail(error.message);
}
clearTimeout(timer);
clearTimeout(hardTimer);
await cleanup();
"""#
}

private struct DeploymentManifest: Codable {
    var schema: Int
    var version: String
    var contentHash: String
    var files: [String: String]
    var inference: String
    var events: String
}

private struct PreflightFacts {
    var os: String
    var arch: String
    var homeWritable: Bool
    var hasShell: Bool
    var nodeVersion: String
    var nodeMajor: Int
    var shaTool: String
}

private extension RemotePiBootstrapError {
    var isBlocked: Bool {
        switch self {
        case .preflightBlocked, .tailscaleUnavailable, .missingKnownHosts: return true
        default: return false
        }
    }
}
