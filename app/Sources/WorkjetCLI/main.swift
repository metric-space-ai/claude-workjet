import Darwin
import Foundation
import WorkjetCore

@main
enum WorkjetCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "__local-supervise", arguments.count == 2 {
            do {
                let runDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
                let stateDirectory = runDirectory.deletingLastPathComponent().deletingLastPathComponent()
                let livePaths = paths()
                let supervisorPaths = WorkjetPaths(homeDirectory: livePaths.homeDirectory, applicationSupportDirectory: livePaths.applicationSupportDirectory, stateDirectory: stateDirectory)
                try LocalRunService(paths: supervisorPaths).supervise(runDirectory: runDirectory)
                exit(WorkjetCLIExitCode.success.rawValue)
            } catch {
                exit(WorkjetCLIExitCode.state.rawValue)
            }
        }
        if arguments.first == "learn" {
            do {
                try runLearn(arguments)
                exit(WorkjetCLIExitCode.success.rawValue)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(WorkjetCLIExitCode.usage.rawValue)
            }
        }
        if arguments == ["activation", "uninstall"] {
            do {
                try WorkjetActivationStore(paths: paths()).uninstallGlobalInclude()
                print("Globale Workjet-Aktivierung entfernt. Konfiguration, Zugänge und der verwaltete Prompt bleiben erhalten.")
                exit(WorkjetCLIExitCode.success.rawValue)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(WorkjetCLIExitCode.state.rawValue)
            }
        }

        let jsonRequested = arguments.contains("--json")
        do {
            let command = try WorkjetCLIParser.parse(arguments)
            let response = try await WorkjetCLIEngine(backing: try LiveWorkjetCLIBacking(paths: paths())).execute(command)
            if jsonRequested {
                try writeJSON(response)
            } else {
                writeHuman(response)
            }
            exit(WorkjetCLIExitCode.success.rawValue)
        } catch let error as WorkjetCLIError {
            if jsonRequested {
                try? writeJSON(WorkjetCLIErrorResponse(error: error.code, message: error.message))
            } else {
                FileHandle.standardError.write(Data((error.message + "\n").utf8))
            }
            exit(error.exitCode.rawValue)
        } catch {
            let wrapped = WorkjetCLIError(code: "internal_error", message: error.localizedDescription, exitCode: .state)
            if jsonRequested {
                try? writeJSON(WorkjetCLIErrorResponse(error: wrapped.code, message: wrapped.message))
            } else {
                FileHandle.standardError.write(Data((wrapped.message + "\n").utf8))
            }
            exit(wrapped.exitCode.rawValue)
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }

    private static func writeHuman(_ response: WorkjetCLIResponse) {
        if let workers = response.workers {
            for worker in workers { print("\(worker.id.uuidString)\t\(worker.name)\t\(worker.model)\t\(worker.computerName)") }
        } else if let worker = response.worker {
            print("\(worker.name) · \(worker.model) · \(worker.harness) · \(worker.computerName)")
        } else if let runID = response.runID {
            print([runID, response.state, response.lifecycle, response.resultRef, response.resultOID].compactMap { $0 }.joined(separator: " · "))
            response.events?.forEach { print("\($0.sequence)\t\($0.kind)\t\($0.text ?? "")") }
        }
    }

    private static func runLearn(_ arguments: [String]) throws {
        if arguments.dropFirst().first == "--list" {
            let value = try AdHocLearningStore(fileURL: paths().learningsFile).load() ?? ""
            print(value, terminator: value.hasSuffix("\n") || value.isEmpty ? "" : "\n")
            return
        }
        guard arguments.dropFirst().first == "--systematic" else { throw LearnUsageError() }
        let inline = arguments.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let piped: String
        if inline.isEmpty, isatty(STDIN_FILENO) == 0 {
            piped = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } else {
            piped = inline
        }
        let paths = paths()
        let learningStore = AdHocLearningStore(fileURL: paths.learningsFile)
        let updated = try learningStore.appendSystematic(piped)
        let configurationStore = JSONConfigurationStore(fileURL: paths.configurationFile)
        var configuration = WorkjetBootstrap.normalized(try configurationStore.load() ?? WorkjetDefaults.configuration())
        configuration.adHocLearnings = updated
        if let general = try ManagedPromptStore(fileURL: paths.promptFile).loadHandwrittenRules(), !general.isEmpty {
            configuration.skillRules = general
        }
        try configurationStore.save(configuration)
        try ManagedPromptStore(fileURL: paths.promptFile).synchronize(configuration, handwrittenChanged: false)
        print("Learning gespeichert und in den Workjet-Prompt übernommen.")
    }

    /// `WORKJET_HOME` makes CLI automation hermetic without changing the app's
    /// normal path contract or trusting a shell command string.
    private static func paths() -> WorkjetPaths {
        guard let override = ProcessInfo.processInfo.environment["WORKJET_HOME"], !override.isEmpty else { return .live }
        return WorkjetPaths(homeDirectory: URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL)
    }
}

private struct LearnUsageError: LocalizedError {
    var errorDescription: String? {
        "Verwendung: workjet learn --systematic \"Fehlermuster → neue Orchestrierungsregel\" | workjet learn --list"
    }
}
