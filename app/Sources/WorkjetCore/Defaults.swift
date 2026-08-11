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
    - The canonical board is one self-contained HTML artifact. It is not a
      prose status summary and it must remain directly usable after compaction.
    - The file lives in a git-versioned, durable location inside the project's
      private dev area — NEVER /tmp, NEVER the session scratchpad (both get
      wiped; a board was lost this way). Commit on every update.
    - Publish to ONE stable artifact URL for the project's lifetime; same file
      path on every republish. Keep the favicon stable.

    **Card discipline (what makes it compaction-proof):**
    - Every card is self-contained: the load-bearing numbers, artifact paths,
      log file, and commit hashes ON the card. Never "see above", never chat
      references — the chat will be gone.
    - Working contains ONLY work proven to be running now. For your own work,
      name the concrete action currently being executed and the fresh evidence
      that it is active. For delegated work, name the exact Workjet worker,
      Workjet run ID, last verified non-terminal state, and check timestamp.
      Show the per-provider concurrency state (e.g. "Sol 3/3 — do not launch").
    - Never keep queued, waiting, blocked, terminal, completed, stopped, failed,
      abandoned, or unverified cards in Working. Move them immediately to To-Do,
      Backlog+Owner, or Done as appropriate. A background poll is not work by
      itself; its underlying run must still be non-terminal.
    - Reconcile every Working card against fresh Workjet events/health or direct
      process evidence whenever the board is updated. A card without current
      evidence is a stale corpse and must leave Working in that same update.
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
                harness: .codexCLI,
                model: "gpt-5.6-terra",
                instructions: "Perform current online research only with Codex's native live web search. Prioritize primary sources, quote factual evidence carefully, and provide direct links. Never inspect or modify a local repository or run shell/code tasks; use no subagents. Obey the brief's source boundaries and non-goals. Report question, sources consulted, confirmed findings, conflicting or uncertain evidence, links, and unresolved questions. \(completionReceipt)",
                computerID: localID,
                skillOverrides: [
                    WorkerSkillCatalog.greppyID: false,
                    WorkerSkillCatalog.webResearchID: true
                ],
                invocation: WorkerInvocation(
                    executable: HarnessAdapterRegistry.defaultLocalInvocation(for: .codexCLI)?.executable
                        ?? HarnessAdapterRegistry.descriptor(for: .codexCLI).defaultInvocation.executable,
                    arguments: ["--search", "-a", "never", "-s", "read-only", "exec", "--ignore-user-config", "--skip-git-repo-check", "--ephemeral", "<WORKJET_BRIEF>"],
                    capabilities: [
                        "Current online research using verified native live web search",
                        "Primary-source research with direct links",
                        "Read-only runtime; no repository edits or shell/code tasks"
                    ],
                    options: ["fastMode": "false"]
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

            Route greenfield UI/UX and explicitly assigned visual implementation to Kimi UI/UX. Route cybersecurity and independent adversarial review to Kimi Cyber & Review. Existing frontend adaptation and frontend-to-backend wiring default to Sol. Give Bulk only disjoint, counted, fixed-schema repetitive slices, then independently sample its output. \(LegacyPromptMigration.currentWebResearchRoutingSentence)

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
            - Before declaring Workjet or its workers unavailable, run the explicit end-to-end probe `workjet health --probe-workers --json`. It starts every configured worker with a bounded no-tools token prompt and reports actual model response, latency, provider route, and failure class.
            - A health claim is valid only from a command executed in the current turn after the latest Workjet update or provider authorization. Resolve Workjet with `command -v workjet`, require an absolute executable path, run that exact path, and require the JSON `checkedAt` value from this invocation. Never reuse an earlier turn's output, a cached UI label, or a remembered error.
            - Treat only that Workjet health output as the authority for Workjet worker availability. Do not inspect or diagnose the native `Claude Code-credentials` keychain entry, do not ask the user to run `claude /login`, and do not launch `claude --bare` directly unless the selected Workjet provider route explicitly says it uses native Anthropic authentication. Workjet gateway and direct-provider workers receive their configured endpoint and credential through Workjet.
            - Read health failures literally. `computerName` identifies the resolved configured target even when launch fails; `error` and `message` identify the failed layer. Never infer a missing computer, expired login, or provider outage from another field.
            - Never infer a harness-permission defect from Claude text such as “requested permissions” or prescribe raw `--allowedTools` arguments. Report an invocation defect only when Workjet itself returns `harness_contract_invalid`; otherwise use the exact Workjet health error and open the affected worker in Workjet for repair.
            - Repository workers run only in Workjet-owned isolated worktrees created from an immutable snapshot of the invoking checkout. Initialized top-level Git submodules are materialized offline at their pinned commits inside that worktree and are read-only for result capture. Never infer a different workspace identity from a path printed by a worker, and never edit the caller checkout on a worker's behalf.
            - For a classified missing/expired provider login, give the user Workjet's exact recovery action instead of a provider-native login guess. Open Workjet and select Einstellungen → Anbieter → the affected access → “Neu anmelden”; after authorization, rerun the current-turn health probe and quote its new `checkedAt` value.
            - When reporting health, quote `checkedAt` and each affected worker's exact `status`, `error`, and `message`. Do not replace mixed results with a blanket summary such as “all workers failed”. If a required worker is not ready, do not claim that its group or run has started.
            - Start a worker only with `workjet run <uuid-oder-exakter-name> --brief-file <pfad> --json`.
            - Web Research is an additive per-worker skill, not a separate harness role: when enabled, the worker keeps its normal tools and receives Workjet's verified live-search and page-fetch path. Terra is merely the default research-only worker with this skill enabled. Do not infer native `WebSearch`/`WebFetch` tools from Claude Code; use the configured worker through Workjet and treat `WEB_RESEARCH_UNAVAILABLE` as a real runtime failure.
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
            Work only in the checkout supplied by Workjet and never cd to another checkout. Repository-backed local and remote runs use Workjet-owned isolated worktrees created from immutable snapshots; initialized top-level Git submodules are available offline at their pinned commits and must remain unchanged. Never edit the invoking checkout directly. Commit in green slices so a timeout can still land value. No subagents.
            <!-- WORKJET WORKER PREAMBLE END -->

            <!-- WORKJET OPUS SYSTEM PROMPT BEGIN -->
            For this Workjet invocation, act as a headless task worker. Execute exactly the brief given in the user prompt and print your report to stdout. You are NOT an orchestrator: never spawn agents, workers, or subprocesses beyond what the brief itself requires.
            <!-- WORKJET OPUS SYSTEM PROMPT END -->

            <!-- WORKJET HEALTH PROBE PROMPT BEGIN -->
            Do not inspect, edit, or navigate repository files and do not spawn subagents. Reply with the token: OK
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
            \(WorkerSkillCatalog.prescribedGreppyPrompt)
            <!-- WORKJET SKILL PROMPT SOURCE END greppy -->

            <!-- WORKJET SKILL PROMPT SOURCE BEGIN web-research -->
            \(WebResearchPrompt.text)
            <!-- WORKJET SKILL PROMPT SOURCE END web-research -->
            """,
            transparentWorkerPromptsMigrated: true
        )
    }
}
