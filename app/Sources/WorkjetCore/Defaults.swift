import Foundation

public enum WorkjetDefaults {
    public static let localID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let localComputer = Computer(id: localID, name: "Local", transport: .local)
    public static let unavailableCapacity = CapacityStatus.unavailable(reason: "Exakte Kapazität ist ohne kompatible Nutzungsdaten und Limit nicht verfügbar.")
    public static let skillLoaderInstructions = "Lies `~/.claude/workjet/AGENTS.md` und befolge ausschließlich die dort enthaltenen Anweisungen."
    public static let progressBoardRules = """
    ## Progress board (mandatory for every larger orchestrated task) — v2

    The board is a KANBAN, not a status page: four columns — Done / Working /
    To-Do / Backlog+Owner. It is simultaneously the human dashboard and the
    RECOVERY DOCUMENT: after any context compaction, a fresh session must be able
    to continue correctly from the board alone. Every rule below exists because
    its violation actually cost work.

    **Storage & identity (hard rules):**
    - The file lives in a git-versioned, durable location inside the project's
      private dev area — NEVER /tmp, NEVER the session scratchpad (both get
      wiped; a board was lost this way). Commit on every update.
    - Publish to ONE stable artifact URL for the project's lifetime; same file
      path on every republish. Keep the favicon stable.

    **Card discipline (what makes it compaction-proof):**
    - Every card is self-contained: the load-bearing numbers, artifact paths,
      log file, and commit hashes ON the card. Never "see above", never chat
      references — the chat will be gone.
    - Working cards name: worker, log path, and what "finished" looks like.
      Show the per-provider concurrency state (e.g. "Sol 3/3 — do not launch").
    - To-Do cards carry an explicit TRIGGER ("starts when X lands"). The trigger
      chain IS the orchestration plan; a reader must be able to derive the
      critical path from the To-Do column alone.
    - Owner decisions are cards in Backlog, marked OWNER:, never buried in prose.
      They survive until the owner decides — dropping one silently is a defect.

    **Truth discipline:**
    - Only VERIFIED facts on the board. A worker's report is a claim; the card
      says what YOU checked. Unverified statements are marked as such or stay off.
    - Corrections stay visible: a claim that proved false gets a KORREKTUR note
      on the card, not silent deletion. Failed rounds remain in Done as
      "done with negative result" — negative results are results.

    **Below the board, three permanent sections (the compaction payload):**
    1. Environment traps — every operational landmine learned (paths, auth
       quirks, kill/SSH traps, sync methods). Read before writing any brief.
    2. Error patterns — the recurring self-failure modes, numbered, with counts.
    3. Evidence map — where every artifact/ledger/report lives (host + path).

    **Update duty stays EVENT-driven** (worker lands / decision taken / finding
    made → move the cards immediately). A board that lags reality lies with
    authority. Headline = the current critical path in one sentence.
    """

    public static func configuration() -> WorkjetConfiguration {
        let commonArguments = ["-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"]
        let workers = [
            Worker(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!, name: "Completion Engine", harness: .claudeCode, model: "gpt-5.6-sol", instructions: "Harte, detailreiche Umsetzung exakt nach Brief. Whitelist strikt einhalten, kein Scope-Drift.", computerID: localID, invocation: WorkerInvocation(executable: "~/.local/bin/claude-sol", arguments: commonArguments, capabilities: ["Bestehende Dateien lesen und bearbeiten", "Lokale Build- und Testbefehle im Ziel-Checkout ausführen"]), capacity: unavailableCapacity),
            Worker(id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!, name: "Reviewer", harness: .claudeCode, model: "k3[1m]", instructions: "Unabhängiges Review substanzieller Integrationen; entscheidet Dispute zwischen Agents.", computerID: localID, invocation: WorkerInvocation(executable: "~/.local/bin/claude-kimi", arguments: commonArguments, capabilities: ["Repository lesen und Änderungen reviewen", "Lokale Verifikation im Ziel-Checkout ausführen"]), capacity: unavailableCapacity),
            Worker(id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!, name: "UI/UX-Experte", harness: .claudeCode, model: "k3[1m]", instructions: "Greenfield-UI und Integrationsdesign; Systemtypografie, lineare Hierarchie, keine dekorativen Elemente.", computerID: localID, invocation: WorkerInvocation(executable: "~/.local/bin/claude-kimi", arguments: commonArguments, capabilities: ["UI-Code lesen und bearbeiten", "Lokale UI-Builds und Tests im Ziel-Checkout ausführen"]), capacity: unavailableCapacity),
            Worker(id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!, name: "Bulk Worker", harness: .claudeCode, model: "MiniMax-M3", instructions: "Klar umrissene, repetitive Massenarbeit: Generierung, Klassifikation, Tests. Write-only, kein Edit, kein git.", computerID: localID, invocation: WorkerInvocation(executable: "~/.local/bin/claude-minimax", arguments: ["-p", "<WORKJET_BRIEF>"], capabilities: ["Klar benannte neue Dateien erzeugen", "Keine Host-Build-/Test-Autorität und keine Git-Operationen"]), capacity: unavailableCapacity)
        ]
        return WorkjetConfiguration(
            workers: workers,
            computers: [localComputer],
            providers: [],
            selectedComputerID: localID,
            skillRules: "Du bist Fable, der einzige Workjet-Orchestrator. Zerlege Aufgaben, wähle genau einen passenden deklarierten Worker pro Invocation, verfasse einen präzisen Brief und integriere sowie verifiziere das Ergebnis. Die App trifft keine Worker- oder Workflow-Entscheidungen.",
            skillLoaderInstructions: skillLoaderInstructions,
            modelPrompts: ModelPromptCatalog.defaults,
            progressBoardRules: progressBoardRules,
            adHocLearnings: "",
            technicalRules: """
            \(LegacyPromptMigration.currentSkillActivationSentence)

            Workjet wählt keine Worker und baut keine Workflows; Fable bleibt der Orchestrator. Starte, beobachte und stoppe Worker ausschließlich mit `workjet workers list --json`, `workjet workers describe <exakter-name-oder-uuid> --json`, `workjet run <exakter-name-oder-uuid> --brief-file <pfad> --json`, `workjet events <run-id> --after <exklusive-sequenz> --json` und `workjet stop <run-id> --json`. Die sichtbaren Executable-, Argument-, Protokoll- und Harness-Fakten führt ausschließlich die Workjet-App aus; Fable startet weder SSH noch Harness-Prozesse direkt.

            \(LegacyPromptMigration.currentFallbackSentence) CLIProxy-OAuth-Zugänge bilden einen proxyverwalteten gemeinsamen Gateway-Pool ohne Account-Pinning pro Anfrage. Ein Wechsel auf einen anderen Worker geschieht niemals automatisch.

            Remote startbar sind Claude Code, Pi Code, Codex CLI und OpenCode. Cursor Agent und Grok CLI sind ausschließlich prüf- und installierbar, nicht remote startbar. Workjet verwendet begrenztes Event-Polling mit exklusivem Sequenz-Cursor, keine t3code-Interoperabilität, keinen WebSocket-Stream und keinen behaupteten Pi-Live-Stream.

            Wenn die Orchestrierung wegen einer Workjet-Regel oder -Implementierung systematisch und reproduzierbar scheitert, halte daraus eine kurze, künftig handlungsleitende Regel mit `workjet learn --systematic "…"` fest. Keine einmaligen Fehler, flüchtigen Umgebungsprobleme oder gewöhnlichen Schwierigkeiten protokollieren.

            <!-- WORKJET WORKER PREAMBLE BEGIN -->
            You are in an isolated worktree at <WORKJET_CHECKOUT>. Never cd to another checkout. Commit in green slices: a timeout must still land value. No subagents.
            <!-- WORKJET WORKER PREAMBLE END -->

            <!-- WORKJET OPUS SYSTEM PROMPT BEGIN -->
            You are a headless worker process. Execute exactly the brief given in the user prompt and print your report to stdout. You are NOT an orchestrator: never spawn agents, workers, or subprocesses beyond what the brief itself requires.
            <!-- WORKJET OPUS SYSTEM PROMPT END -->

            <!-- WORKJET HEALTH PROBE PROMPT BEGIN -->
            You are in an isolated worktree at <WORKJET_CHECKOUT>. Never cd to another checkout. Do not edit files and do not spawn subagents. Reply with the token: OK
            <!-- WORKJET HEALTH PROBE PROMPT END -->

            <!-- WORKJET COMPLETION RECEIPT PROMPT BEGIN -->
            WORKJET COMPLETION RECEIPT V1 (required final stdout block for task runs only)
            After the human-readable report, end stdout with exactly one compact JSON receipt in this form:
            ```workjet-completion-receipt-v1
            {"schemaVersion":1,"status":"completed","summary":"bounded factual summary","changedFiles":["relative/path"],"verification":[{"command":"exact command","result":"pass/fail and concise evidence"}],"concerns":[],"producedPaths":["relative/or/absolute/path"]}
            ```
            The closing fence must be the final non-whitespace stdout content. Use status completed, partial, failed, or blocked. Keep summary under 2000 characters; at most 100 changedFiles, 50 verification entries, 50 concerns, and 100 producedPaths. Keep each field concise, include no secrets, and report claims truthfully. The receipt is non-authoritative telemetry: the orchestrator will independently inspect the diff, code, and test results.
            <!-- WORKJET COMPLETION RECEIPT PROMPT END -->

            <!-- WORKJET SKILL PROMPT SOURCE BEGIN greppy -->
            This project has `greppy`, a local code-navigation tool over a symbol graph and
            an on-device semantic index. Ordinary grep invocations are delegated byte-for-
            byte to the real system grep, but Greppy must not be installed or invoked as a
            global grep alias.

            GREPPY 1.3 COMMANDS. Use only the installed v1.3 surface:
              greppy search QUERY              search indexed symbols and code
              greppy trace SYMBOL              show the symbol's definition and relations
              greppy trace --callers SYMBOL    show incoming callers
              greppy trace --callees SYMBOL    show outgoing calls
              greppy trace --refs SYMBOL       show references and usages
              greppy trace --impact SYMBOL     show transitive change impact

            Run these from the repository being inspected. Use `greppy search` when the
            exact symbol name is unknown, then use the appropriate `greppy trace` form for
            relationship questions. Do not invent legacy commands such as `who-calls`,
            `callees`, `find-usages`, `brief`, `search-symbols`, `semantic-search`, `path`,
            or `expand`; those are not part of the managed Greppy 1.3.0 contract.

            Treat returned source paths, exact spans, signatures, and graph relations as
            navigation evidence. Read the source and verify changes with builds and tests.
            <!-- WORKJET SKILL PROMPT SOURCE END greppy -->

            <!-- WORKJET TRANSPARENT RUNTIME PROMPTS V2 -->
            """,
            transparentWorkerPromptsMigrated: true
        )
    }
}
