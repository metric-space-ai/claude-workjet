import Darwin
import Foundation

public struct CommandSpec: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var standardInput: Data
    public var timeout: TimeInterval
    public var stdoutLimit: Int
    public var stderrLimit: Int

    public init(executable: String, arguments: [String], standardInput: Data = Data(), timeout: TimeInterval = 30, stdoutLimit: Int = 1_048_576, stderrLimit: Int = 1_048_576) {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
        self.timeout = timeout
        self.stdoutLimit = stdoutLimit
        self.stderrLimit = stderrLimit
    }
}

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var standardOutput: Data
    public var standardError: Data
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public init(exitCode: Int32, standardOutput: Data = Data(), standardError: Data = Data(), stdoutTruncated: Bool = false, stderrTruncated: Bool = false) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

public enum CommandRunError: LocalizedError, Equatable {
    case executableMustBeAbsolute
    case launch(String)
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .executableMustBeAbsolute: return "Prozesse dürfen nur über absolute Executable-Pfade gestartet werden."
        case let .launch(detail): return "Prozess konnte nicht gestartet werden: \(detail)"
        case .timedOut: return "Remote-Befehl hat sein Zeitlimit überschritten."
        case .cancelled: return "Remote-Befehl wurde abgebrochen."
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(_ command: CommandSpec) async throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning, Sendable {
    public init() {}

    public func run(_ command: CommandSpec) async throws -> CommandResult {
        guard command.executable.hasPrefix("/") else { throw CommandRunError.executableMustBeAbsolute }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() }
        catch { throw CommandRunError.launch(error.localizedDescription) }

        let processBox = ProcessBox(process)
        return try await withTaskCancellationHandler {
            async let output = Self.drain(stdout.fileHandleForReading, limit: command.stdoutLimit)
            async let errors = Self.drain(stderr.fileHandleForReading, limit: command.stderrLimit)
            async let input: Void = Self.write(command.standardInput, to: stdin.fileHandleForWriting)
            do {
                try await Self.wait(for: processBox, timeout: command.timeout)
                try Task.checkCancellation()
                _ = try await input
                let (out, err) = try await (output, errors)
                return CommandResult(exitCode: process.terminationStatus, standardOutput: out.data, standardError: err.data, stdoutTruncated: out.truncated, stderrTruncated: err.truncated)
            } catch {
                processBox.terminate()
                _ = try? await input
                _ = try? await output
                _ = try? await errors
                throw error
            }
        } onCancel: {
            processBox.terminate()
        }
    }

    private static func write(_ data: Data, to handle: FileHandle) async throws {
        defer { try? handle.close() }
        guard !data.isEmpty else { return }
        try await Task.detached { try handle.write(contentsOf: data) }.value
    }

    private static func drain(_ handle: FileHandle, limit: Int) async throws -> (data: Data, truncated: Bool) {
        try await Task.detached {
            defer { try? handle.close() }
            var result = Data()
            var truncated = false
            while let chunk = try handle.read(upToCount: 16_384), !chunk.isEmpty {
                let remaining = max(limit - result.count, 0)
                if remaining > 0 { result.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { truncated = true }
            }
            return (result, truncated)
        }.value
    }

    private static func wait(for box: ProcessBox, timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    box.setTerminationHandler { continuation.resume(returning: true) }
                }
            }
            group.addTask {
                let duration = max(timeout, 0.01)
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                return false
            }
            guard let completed = try await group.next() else { throw CommandRunError.cancelled }
            group.cancelAll()
            if !completed { box.terminate(); throw CommandRunError.timedOut }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    init(_ process: Process) { self.process = process }

    func setTerminationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if process.isRunning {
            process.terminationHandler = { _ in handler() }
            lock.unlock()
        } else {
            lock.unlock()
            handler()
        }
    }

    func terminate() {
        lock.lock()
        let running = process.isRunning
        let pid = process.processIdentifier
        lock.unlock()
        guard running else { return }
        process.terminate()
        if pid > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if self.process.isRunning { _ = kill(pid, SIGKILL) }
            }
        }
    }
}
