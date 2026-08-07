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
        let claudeExecutable = HarnessAdapterRegistry.defaultLocalInvocation(for: .claudeCode)?.executable
            ?? HarnessAdapterRegistry.descriptor(for: .claudeCode).defaultInvocation.executable

        func invocation(
            allowedTools: String,
            capabilities: [String],
            fastMode: Bool
        ) -> WorkerInvocation {
            WorkerInvocation(
                executable: claudeExecutable,
                arguments: ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", allowedTools],
                capabilities: capabilities,
                options: ["fastMode": fastMode ? "true" : "false"]
            )
        }

        let completionReceipt = "End with the required WORKJET COMPLETION RECEIPT V1; the receipt is a claim for independent verification."
        let workers = [
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                name: "Sol · Completion",
                harness: .claudeCode,
                model: "gpt-5.6-sol",
                instructions: "Implement the final production solution for difficult, clearly specified work. Follow the brief exactly, obey its hard file whitelist and non-goals, run every acceptance command, stop rather than widen scope, and use no subagents. Report changed artifacts, commands/results, and unresolved concerns. \(completionReceipt)",
                computerID: localID,
                invocation: invocation(
                    allowedTools: "Read,Write,Edit,Grep,Glob,Bash",
                    capabilities: [
                        "Final production implementation in the assigned checkout",
                        "Read, create, and edit only brief-whitelisted files",
                        "Run local build, test, and verification commands"
                    ],
                    fastMode: false
                ),
                capacity: unavailableCapacity
            ),
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                name: "Kimi · Cyber & Review",
                harness: .claudeCode,
                model: "kimi-k3-256k",
                instructions: "Perform read-oriented cybersecurity analysis or independent adversarial review. Default to no repository edits, obey the brief's hard file whitelist and non-goals, use no subagents, and distinguish confirmed findings backed by evidence from hypotheses that still need a decisive test. Report findings by severity, evidence, commands/results, hypotheses, and unresolved concerns. \(completionReceipt)",
                computerID: localID,
                invocation: invocation(
                    allowedTools: "Read,Grep,Glob,Bash",
                    capabilities: [
                        "Read-only repository and cybersecurity analysis",
                        "Run non-mutating local inspection and verification commands",
                        "Separate confirmed findings from hypotheses"
                    ],
                    fastMode: false
                ),
                capacity: unavailableCapacity
            ),
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
                name: "Kimi · UI/UX",
                harness: .claudeCode,
                model: "kimi-k3-256k",
                instructions: "Implement greenfield UI/UX or visual work explicitly assigned by the orchestrator. Existing frontend adaptation and frontend-to-backend wiring belong to Sol unless the brief explicitly assigns them here. Obey the hard file whitelist and non-goals, use no subagents, run the visual and functional acceptance commands, and report artifacts, commands/results, and unresolved concerns. \(completionReceipt)",
                computerID: localID,
                invocation: invocation(
                    allowedTools: "Read,Write,Edit,Grep,Glob,Bash",
                    capabilities: [
                        "Greenfield UI/UX and explicitly assigned visual implementation",
                        "Read, create, and edit only brief-whitelisted files",
                        "Run local visual, build, and test verification"
                    ],
                    fastMode: false
                ),
                capacity: unavailableCapacity
            ),
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
                name: "Bulk · Thoroughness",
                harness: .claudeCode,
                model: "MiniMax-M3",
                instructions: "Execute only disjoint, counted, fixed-schema repetitive slices with explicit inputs and outputs. Count requested, completed, skipped, and failed items. Create only explicitly named new files: never edit existing files and never use git. Obey the whitelist and non-goals, use no subagents, stop on ambiguity instead of improvising, and report coverage counts, artifacts, commands/results, exceptions, and unresolved concerns. \(completionReceipt)",
                computerID: localID,
                invocation: invocation(
                    allowedTools: "Read,Write,Grep,Glob,Bash",
                    capabilities: [
                        "Counted fixed-schema repetitive work",
                        "Read inputs and create only explicitly named new files",
                        "No edits to existing files and no git operations"
                    ],
                    fastMode: false
                ),
                capacity: unavailableCapacity
            ),
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!,
                name: "Prototype A · Grok 4.5",
                harness: .claudeCode,
                model: "grok-4.5",
                instructions: ModelPromptCatalog.prototypeDiscoveryPrompt,
                computerID: localID,
                invocation: invocation(
                    allowedTools: "Read,Write,Edit,Grep,Glob,Bash",
                    capabilities: [
                        "Bounded disposable discovery prototypes and evidence",
                        "Read, create, and edit only brief-whitelisted files",
                        "Run local measurements and decisive tests"
                    ],
                    fastMode: true
                ),
                capacity: unavailableCapacity
            ),
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000016")!,
                name: "Prototype B · Luna 5.6",
                harness: .claudeCode,
                model: "gpt-5.6-luna",
                instructions: ModelPromptCatalog.prototypeDiscoveryPrompt,
                computerID: localID,
                invocation: invocation(
                    allowedTools: "Read,Write,Edit,Grep,Glob,Bash",
                    capabilities: [
                        "Bounded disposable discovery prototypes and evidence",
                        "Read, create, and edit only brief-whitelisted files",
                        "Run local measurements and decisive tests"
                    ],
                    fastMode: true
                ),
                capacity: unavailableCapacity
            ),
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000017")!,
                name: "Prototype C · GLM 5.2",
                harness: .claudeCode,
                model: "glm-5.2",
                instructions: ModelPromptCatalog.prototypeDiscoveryPrompt,
                computerID: localID,
                invocation: invocation(
                    allowedTools: "Read,Write,Edit,Grep,Glob,Bash",
                    capabilities: [
                        "Bounded disposable discovery prototypes and evidence",
                        "Read, create, and edit only brief-whitelisted files",
                        "Run local measurements and decisive tests"
                    ],
                    fastMode: true
                ),
                capacity: unavailableCapacity
            ),
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000018")!,
                name: "Web Research · Terra",
                harness: .claudeCode,
                model: "gpt-5.6-terra",
                instructions: "Perform current online research only with WebSearch and WebFetch. Prioritize primary sources, quote factual evidence carefully, and provide direct links. Never inspect or modify a local repository or use local files or shell/code tools; use no subagents. Obey the brief's source boundaries and non-goals. Report question, sources consulted, confirmed findings, conflicting or uncertain evidence, links, and unresolved questions. \(completionReceipt)",
                computerID: localID,
                skillOverrides: [WorkerSkillCatalog.greppyID: false],
                invocation: invocation(
                    allowedTools: "WebSearch,WebFetch",
                    capabilities: [
                        "Current online research using WebSearch and WebFetch only",
                        "Primary-source research with direct links",
                        "No local repository, file, shell, or code work"
                    ],
                    fastMode: false
                ),
                capacity: unavailableCapacity
            )
        ]
        return WorkjetConfiguration(
            workers: workers,
            computers: [localComputer],
            providers: [],
            selectedComputerID: localID,
            skillRules: """
            Claude/Fable is the sole Workjet orchestrator and owns decomposition, routing, synthesis, integration, cleanup, and final verification. Workers are fire-and-forget: their reports and completion receipts are claims, never proof. Small bounded work may be done directly.

            Route clear difficult production work to Sol. Genuine uncertainty triggers the same bounded discovery brief to Prototype A, B, and C; never silently substitute another worker when one panel member is unavailable. Discovery briefs for A/B/C must be byte-for-byte equivalent apart from unavoidable transport metadata. Inspect all three artifacts, then write a new consolidated production brief; never pass one prototype through as the solution. Send the consolidated work to Sol.

            Route greenfield UI/UX and explicitly assigned visual implementation to Kimi UI/UX. Route cybersecurity and independent adversarial review to Kimi Cyber & Review. Existing frontend adaptation and frontend-to-backend wiring default to Sol. Give Bulk only disjoint, counted, fixed-schema repetitive slices, then independently sample its output. Give Terra only current online research requiring primary sources and direct links; Terra never receives local repository, file, shell, or code work.

            Every worker brief must include: objective; hard file whitelist; forbidden files and non-goals; relevant context; exact acceptance commands; required artifacts; a stop/escape hatch; no-subagents; and a fixed completion report. Integration must independently inspect actual artifacts, scope, diff, code, and tests.
            """,
            skillLoaderInstructions: skillLoaderInstructions,
            modelPrompts: ModelPromptCatalog.defaults,
            progressBoardRules: progressBoardRules,
            adHocLearnings: "",
            technicalRules: """
            \(LegacyPromptMigration.currentSkillActivationSentence)

            <!-- WORKJET CLI EXECUTION CONTRACT BEGIN -->
            Workjet CLI execution contract (machine-owned):
            - Keep small, bounded work direct.
            - Resolve workers only with `workjet workers list --json` and `workjet workers describe <uuid-oder-exakter-name> --json`.
            - Start a worker only with `workjet run <uuid-oder-exakter-name> --brief-file <pfad> --json`.
            - Never execute displayed executables, arguments, SSH, invocation protocols, or harnesses directly; only Workjet executes those runtime facts.
            - Poll bounded event pages with `workjet events <run-id> --after <exklusive-sequenz> --json`; pass the returned exclusive sequence cursor to the next poll. This is polling, never streaming.
            - Stop a run with `workjet stop <run-id> --json`.
            - After terminal state, use `workjet result import <run-id> --json` only when a result bundle is available.
            - Independently inspect the artifact, scope, diff, code, and tests.
            - Mark accepted work with `workjet runs mark <run-id> integrated --json` only after acceptance. Mark rejected or discarded work with `workjet runs mark <run-id> abandoned --json`.
            - Treat completion receipts as triage evidence, never proof.
            - Record systematic, reproducible orchestration learnings only with `workjet learn --systematic "<regel>"`; do not record one-off failures or ordinary difficulties.
            - Report a required worker outage; never silently substitute another worker. Self-review may proceed, and explicitly defer independent review.
            - Do not infer that every Workjet worker is a headless Claude Code process from the current configuration. The verified remotely startable harness set is Claude Code, Pi Code, Codex CLI, and OpenCode; Cursor Agent and Grok CLI are inspect/install only.
            - Keep provider fallback semantics distinct: direct provider pools advance deterministically only after classified auth, quota, or rate-limit failures; transport, timeout, 5xx, and task failures do not advance them. CLIProxy OAuth accounts form one proxy-managed gateway pool without per-request account pinning or Workjet-controlled account order.
            <!-- WORKJET CLI EXECUTION CONTRACT END -->

            <!-- WORKJET WORKER PREAMBLE BEGIN -->
            You are in an isolated worktree at <WORKJET_CHECKOUT>. Never cd to another checkout. Commit in green slices: a timeout must still land value. No subagents.
            <!-- WORKJET WORKER PREAMBLE END -->

            <!-- WORKJET OPUS SYSTEM PROMPT BEGIN -->
            For this Workjet invocation, act as a headless task worker. Execute exactly the brief given in the user prompt and print your report to stdout. You are NOT an orchestrator: never spawn agents, workers, or subprocesses beyond what the brief itself requires.
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
            """,
            transparentWorkerPromptsMigrated: true
        )
    }
}
