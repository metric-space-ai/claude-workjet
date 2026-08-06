import Darwin
import Foundation

public struct CommandSpec: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var standardInput: Data
    public var currentDirectory: String?
    public var environment: [String: String]?
    public var timeout: TimeInterval
    public var stdoutLimit: Int
    public var stderrLimit: Int

    public init(executable: String, arguments: [String], standardInput: Data = Data(), currentDirectory: String? = nil, environment: [String: String]? = nil, timeout: TimeInterval = 30, stdoutLimit: Int = 1_048_576, stderrLimit: Int = 1_048_576) {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
        self.currentDirectory = currentDirectory
        self.environment = environment
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
    case standardInputClosed
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .executableMustBeAbsolute: return "Die ausführbare Datei braucht einen vollständigen Pfad."
        case .launch: return "Der Worker konnte nicht gestartet werden."
        case .standardInputClosed: return "Die Ausführung wurde unerwartet beendet."
        case .timedOut: return "Der Worker hat das Zeitlimit überschritten."
        case .cancelled: return "Die Ausführung wurde abgebrochen."
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
        if let currentDirectory = command.currentDirectory {
            guard currentDirectory.hasPrefix("/"), !currentDirectory.contains("\0") else { throw CommandRunError.launch("Ungültiges Arbeitsverzeichnis") }
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }
        if let environment = command.environment { process.environment = environment }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let inputBox = InputBox(stdin.fileHandleForWriting)
        guard fcntl(inputBox.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            inputBox.close()
            throw CommandRunError.launch(String(cString: strerror(errno)))
        }

        do { try process.run() }
        catch { inputBox.close(); throw CommandRunError.launch(error.localizedDescription) }

        let processBox = ProcessBox(process)
        return try await withTaskCancellationHandler {
            async let output = Self.drain(stdout.fileHandleForReading, limit: command.stdoutLimit)
            async let errors = Self.drain(stderr.fileHandleForReading, limit: command.stderrLimit)
            async let input: Void = Self.write(command.standardInput, through: inputBox)
            do {
                try await Self.wait(for: processBox, timeout: command.timeout)
                try Task.checkCancellation()
                inputBox.close()
                _ = try await input
                let (out, err) = try await (output, errors)
                return CommandResult(exitCode: process.terminationStatus, standardOutput: out.data, standardError: err.data, stdoutTruncated: out.truncated, stderrTruncated: err.truncated)
            } catch {
                processBox.terminate()
                inputBox.close()
                _ = try? await input
                _ = try? await output
                _ = try? await errors
                throw error
            }
        } onCancel: {
            processBox.terminate()
            inputBox.close()
        }
    }

    private static func write(_ data: Data, through box: InputBox) async throws {
        defer { box.close() }
        guard !data.isEmpty else { return }
        try await Task.detached {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(box.fileDescriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else if written < 0 && (errno == EPIPE || errno == EBADF) {
                        throw CommandRunError.standardInputClosed
                    } else if written < 0 {
                        throw CommandRunError.launch("Standardeingabe konnte nicht geschrieben werden: \(String(cString: strerror(errno)))")
                    }
                }
            }
        }.value
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

private final class InputBox: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(_ handle: FileHandle) { self.handle = handle }
    var fileDescriptor: Int32 { handle.fileDescriptor }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        try? handle.close()
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    init(_ process: Process) { self.process = process }

    func setTerminationHandler(_ handler: @escaping @Sendable () -> Void) {
        // A very short-lived child can exit between an `isRunning` check and
        // assigning Foundation's termination handler. Install the callback
        // first, then sample state, and make both paths share an exactly-once
        // gate so the waiter cannot miss or double-deliver termination.
        let callback = OnceCallback(handler)
        process.terminationHandler = { _ in callback.call() }
        if !process.isRunning { callback.call() }
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

private final class OnceCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?

    init(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func call() {
        lock.lock()
        let pending = callback
        callback = nil
        lock.unlock()
        pending?()
    }
}
