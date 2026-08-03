import Foundation

public enum WorkjetDefaults {
    public static let localID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let localComputer = Computer(id: localID, name: "Local", transport: .local)
    public static let unavailableCapacity = CapacityStatus.unavailable(reason: "Exakte Kapazität ist ohne kompatible Nutzungsdaten und Limit nicht verfügbar.")

    public static func configuration() -> WorkjetConfiguration {
        let commonArguments = ["-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"]
        let workers = [
            Worker(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!, name: "Completion Engine", harness: .claudeCode, model: "gpt-5.6-sol", instructions: "Harte, detailreiche Umsetzung exakt nach Brief. Whitelist strikt einhalten, kein Scope-Drift.", computerID: localID, invocation: WorkerInvocation(executable: "~/.local/bin/claude-sol", arguments: commonArguments, capabilities: ["Bestehende Dateien lesen und bearbeiten", "Lokale Build- und Testbefehle im Ziel-Checkout ausführen"]), capacity: unavailableCapacity),
            Worker(id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!, name: "Reviewer", harness: .claudeCode, model: "k3[1m]", instructions: "Unabhängiges Review substanzieller Integrationen; entscheidet Dispute zwischen Agents.", computerID: localID, invocation: WorkerInvocation(executable: "~/.local/bin/claude-kimi", arguments: commonArguments, capabilities: ["Repository lesen und Änderungen reviewen", "Lokale Verifikation im Ziel-Checkout ausführen"]), capacity: unavailableCapacity),
            Worker(id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!, name: "UI/UX-Experte", harness: .claudeCode, model: "k3[1m]", instructions: "Greenfield-UI und Integrationsdesign; Systemtypografie, lineare Hierarchie, keine dekorativen Elemente.", computerID: localID, invocation: WorkerInvocation(executable: "~/.local/bin/claude-kimi", arguments: commonArguments, capabilities: ["UI-Code lesen und bearbeiten", "Lokale UI-Builds und Tests im Ziel-Checkout ausführen"]), capacity: unavailableCapacity),
            Worker(id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!, name: "Bulk Worker", harness: .claudeCode, model: "MiniMax-M3", instructions: "Klar umrissene, repetitive Massenarbeit: Generierung, Klassifikation, Tests. Write-only, kein Edit, kein git.", computerID: localID, invocation: WorkerInvocation(executable: "~/.local/bin/claude-minimax", arguments: ["-p", "<WORKJET_BRIEF>"], capabilities: ["Klar benannte neue Dateien erzeugen", "Keine Host-Build-/Test-Autorität und keine Git-Operationen"]), capacity: unavailableCapacity)
        ]
        return WorkjetConfiguration(workers: workers, computers: [localComputer], providers: [], selectedComputerID: localID, skillRules: "Du bist Fable, der einzige Workjet-Orchestrator. Zerlege Aufgaben, wähle genau einen passenden deklarierten Worker pro Invocation, verfasse einen präzisen Brief und integriere sowie verifiziere das Ergebnis. Die App trifft keine Worker- oder Workflow-Entscheidungen.")
    }
}
