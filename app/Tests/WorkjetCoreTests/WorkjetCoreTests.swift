import Darwin
import XCTest
@testable import WorkjetCore

private func markedTestBlock(begin: String, end: String, in source: String) -> String? {
    guard let beginRange = source.range(of: begin),
          let endRange = source.range(of: end, range: beginRange.upperBound..<source.endIndex) else { return nil }
    return String(source[beginRange.lowerBound..<endRange.upperBound])
}

final class DefaultsAndLogicTests: XCTestCase {
    func testDefaultsShipTheProvenEightWorkerOrchestrationSetup() throws {
        let config = WorkjetDefaults.configuration()
        XCTAssertEqual(config.computers, [WorkjetDefaults.localComputer])
        XCTAssertEqual(config.selectedComputerID, WorkjetDefaults.localID)
        XCTAssertEqual(config.workers.map(\.id), (11...18).map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
        })
        XCTAssertEqual(config.workers.map(\.name), [
            "Sol · Completion",
            "Kimi · Cyber & Review",
            "Kimi · UI/UX",
            "Bulk · Thoroughness",
            "Prototype A · Grok 4.5",
            "Prototype B · Luna 5.6",
            "Prototype C · GLM 5.2",
            "Web Research · Terra"
        ])
        XCTAssertEqual(config.workers.map(\.model), [
            "gpt-5.6-sol",
            "kimi-k3-256k",
            "kimi-k3-256k",
            "MiniMax-M3",
            "grok-4.5",
            "gpt-5.6-luna",
            "glm-5.2",
            "gpt-5.6-terra"
        ])
        XCTAssertTrue(config.workers.dropLast().allSatisfy { $0.harness == .claudeCode })
        XCTAssertEqual(config.workers.last?.harness, .codexCLI)
        XCTAssertTrue(config.workers.allSatisfy { $0.computerID == WorkjetDefaults.localID })
        let expectedClaudeExecutable = HarnessAdapterRegistry.defaultLocalInvocation(for: .claudeCode)?.executable
            ?? HarnessAdapterRegistry.descriptor(for: .claudeCode).defaultInvocation.executable
        XCTAssertTrue(config.workers.dropLast().allSatisfy { $0.invocation.executable == expectedClaudeExecutable })
        if HarnessAdapterRegistry.defaultLocalInvocation(for: .claudeCode) != nil {
            XCTAssertTrue(expectedClaudeExecutable.hasPrefix("/"))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: expectedClaudeExecutable))
            XCTAssertNil(HarnessAdapterRegistry.localInvocationIssue(
                harness: .claudeCode,
                invocation: config.workers[0].invocation
            ))
        }
        XCTAssertTrue(config.workers.allSatisfy { $0.capacity.fraction == nil })

        let expectedTools = [
            "Read,Write,Edit,Grep,Glob,Bash",
            "Read,Grep,Glob,Bash",
            "Read,Write,Edit,Grep,Glob,Bash",
            "Read,Write,Grep,Glob,Bash",
            "Read,Write,Edit,Grep,Glob,Bash",
            "Read,Write,Edit,Grep,Glob,Bash",
            "Read,Write,Edit,Grep,Glob,Bash"
        ]
        for (worker, tools) in zip(config.workers.dropLast(), expectedTools) {
            XCTAssertEqual(worker.invocation.arguments, ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", tools])
            XCTAssertEqual(worker.invocation.arguments.filter { $0 == "--bare" }.count, 1)
            XCTAssertEqual(worker.invocation.arguments.filter { $0 == "-p" }.count, 1)
        }
        XCTAssertEqual(config.workers.last?.invocation.arguments, ["--search", "-a", "never", "-s", "read-only", "exec", "--ignore-user-config", "--skip-git-repo-check", "--ephemeral", "<WORKJET_BRIEF>"])
        XCTAssertNil(HarnessAdapterRegistry.localInvocationIssue(harness: .codexCLI, invocation: try XCTUnwrap(config.workers.last?.invocation)))
        XCTAssertEqual(config.workers.map { $0.invocation.options["fastMode"] }, [
            "false", "false", "false", "false", "true", "true", "true", "false"
        ])
        XCTAssertTrue(config.workers.dropLast().allSatisfy { $0.skillOverrides.isEmpty })
        XCTAssertEqual(config.workers.last?.skillOverrides, ["greppy": false, "web-research": true])
        XCTAssertTrue(config.workers.last?.invocation.capabilities.contains(where: { $0.contains("Primary-source") }) == true)
        XCTAssertTrue(config.workers.last?.invocation.capabilities.contains(where: { $0.contains("no repository edits") }) == true)

        let prototypes = Array(config.workers[4...6])
        XCTAssertEqual(Set(prototypes.map(\.instructions)), [ModelPromptCatalog.prototypeDiscoveryPrompt])
        XCTAssertTrue(ModelPromptCatalog.prototypeDiscoveryPrompt.contains("same discovery brief as the other panel members"))
        for field in [
            "Approach", "Produced prototype/evidence", "Commands/results", "Difficulty (1-5)",
            "Hidden constraints", "Failure modes", "Decisive tests", "Recommended final-brief additions",
            "Unresolved questions"
        ] {
            XCTAssertTrue(ModelPromptCatalog.prototypeDiscoveryPrompt.contains(field), "Missing prototype report field: \(field)")
        }
        XCTAssertTrue(ModelPromptCatalog.prototypeDiscoveryPrompt.contains("not the final solution"))
        XCTAssertTrue(ModelPromptCatalog.prototypeDiscoveryPrompt.contains("no subagents"))
        XCTAssertTrue(ModelPromptCatalog.prototypeDiscoveryPrompt.contains("hard file whitelist and non-goals"))

        let prompts = try XCTUnwrap(config.modelPrompts)
        XCTAssertEqual(Set(prompts.keys), [
            "GPT-5.6 Sol", "Kimi K3", "MiniMax M3", "grok-4.5",
            "gpt-5.6-luna", "glm-5.2", "gpt-5.6-terra"
        ])
        XCTAssertEqual(prompts["grok-4.5"], prototypes[0].instructions)
        XCTAssertEqual(prompts["gpt-5.6-luna"], prototypes[1].instructions)
        XCTAssertEqual(prompts["glm-5.2"], prototypes[2].instructions)
        XCTAssertFalse(prompts.values.joined(separator: "\n").localizedCaseInsensitiveContains("best frontend-development LLM"))

        XCTAssertTrue(config.workers[0].instructions.contains("final production solution"))
        XCTAssertTrue(config.workers[1].instructions.contains("confirmed findings"))
        XCTAssertTrue(config.workers[1].instructions.contains("hypotheses"))
        XCTAssertTrue(config.workers[2].instructions.contains("greenfield UI/UX"))
        XCTAssertTrue(config.workers[3].instructions.contains("Count requested, completed, skipped, and failed"))
        XCTAssertTrue(config.workers[3].instructions.contains("never edit existing files and never use git"))
        XCTAssertTrue(config.workers[7].instructions.contains("current online research only"))
        XCTAssertTrue(config.workers.allSatisfy { $0.instructions.contains("no subagents") })
        XCTAssertTrue(config.workers.allSatisfy { $0.instructions.contains("WORKJET COMPLETION RECEIPT V1") })
    }

    func testPersistedCustomConfigurationIsNotReplacedAndOnlyReferencedMissingPromptsAreFilled() throws {
        var persisted = WorkjetDefaults.configuration()
        persisted.workers = Array(persisted.workers.prefix(2))
        persisted.workers[0].name = "Owner Sol"
        persisted.workers[0].instructions = "OWNER INSTRUCTIONS"
        persisted.workers[0].skillOverrides = ["greppy": false, "owner-skill": true]
        persisted.workers[1].instructions = "OWNER REVIEW INSTRUCTIONS"
        persisted.skillRules = "OWNER ROUTING CONTRACT"
        persisted.modelPrompts = ["GPT-5.6 Sol": "OWNER MODEL PROMPT"]

        let decoded = try JSONDecoder().decode(WorkjetConfiguration.self, from: JSONEncoder().encode(persisted))
        let normalized = WorkjetBootstrap.normalized(decoded)

        XCTAssertEqual(normalized.workers, persisted.workers)
        XCTAssertEqual(normalized.skillRules, "OWNER ROUTING CONTRACT")
        XCTAssertEqual(normalized.workers[0].instructions, "OWNER INSTRUCTIONS")
        XCTAssertEqual(normalized.workers[0].skillOverrides, ["greppy": false, "owner-skill": true])
        XCTAssertEqual(normalized.modelPrompts?["GPT-5.6 Sol"], "OWNER MODEL PROMPT")
        XCTAssertEqual(normalized.modelPrompts?["Kimi K3"], ModelPromptCatalog.defaults["Kimi K3"])
        XCTAssertNil(normalized.modelPrompts?["MiniMax M3"])
        XCTAssertNil(normalized.modelPrompts?["gpt-5.6-terra"])
    }

    func testKnownBrokenClaudeTerraDefaultMigratesToVerifiedCodexWebSearch() throws {
        var configuration = WorkjetDefaults.configuration()
        let index = try XCTUnwrap(configuration.workers.firstIndex(where: { $0.name == "Web Research · Terra" }))
        configuration.workers[index].harness = .claudeCode
        configuration.workers[index].instructions = "legacy generated Terra prompt"
        configuration.workers[index].invocation = WorkerInvocation(
            executable: "/opt/homebrew/bin/claude",
            arguments: ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "WebSearch,WebFetch"]
        )
        configuration.modelPrompts?["gpt-5.6-terra"] = "Terra performs online research only. Permit WebSearch and WebFetch, forbid repository, file, shell, and code work, require current primary sources with direct links, and require facts, inference, conflicts, and unknowns to be separated."

        let normalized = WorkjetBootstrap.normalized(configuration)
        let migrated = normalized.workers[index]
        XCTAssertEqual(migrated.harness, .codexCLI)
        XCTAssertEqual(migrated.invocation.arguments.first, "--search")
        XCTAssertTrue(migrated.invocation.arguments.contains("exec"))
        XCTAssertTrue(migrated.instructions.contains("native live web search"))
        XCTAssertEqual(migrated.skillOverrides[WorkerSkillCatalog.greppyID], false)
        XCTAssertEqual(migrated.skillOverrides[WorkerSkillCatalog.webResearchID], true)
        XCTAssertTrue(normalized.modelPrompts?["gpt-5.6-terra"]?.contains("dedicated read-only research worker") == true)
    }

    func testCapacityAndPureLogic() {
        XCTAssertEqual(CapacityStatus.measured(used: 25, limit: 100, unit: "requests", rateLimited: false).fraction, 0.25)
        XCTAssertNil(CapacityStatus.measured(used: 110, limit: 100, unit: "requests", rateLimited: false).fraction)
        XCTAssertEqual(CapacityStatus.unavailable(reason: "none").level, .unavailable)
        XCTAssertEqual(WorkerFilter.filtered(WorkjetDefaults.configuration().workers, query: "review", computerID: WorkjetDefaults.localID).map(\.name), ["Kimi · Cyber & Review"])
        XCTAssertEqual(DurationFormatter.string(for: 3725), "1h 2m")
    }

    func testWorkerDraftPersistsInvocation() {
        let providerID = UUID()
        var draft = WorkerDraft(); draft.name = "Reviewer"; draft.model = "k3[1m]"; draft.computerID = WorkjetDefaults.localID; draft.providerID = providerID
        XCTAssertTrue(draft.isValid)
        draft.executable = "~/.local/bin/claude-kimi"; draft.arguments = "--bare\n-p\n<WORKJET_BRIEF>\n--allowedTools\nRead,Write,Edit,Grep,Glob,Bash"; draft.capabilities = "Review\nTests"
        let worker = draft.applied(to: nil)
        XCTAssertEqual(worker?.invocation.arguments, ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"])
        XCTAssertEqual(worker?.invocation.capabilities, ["Review", "Tests"])
        XCTAssertEqual(WorkerDraft(worker: worker).providerID, providerID)
        draft.selectHarness(.piSidecar)
        XCTAssertEqual(draft.executable, "~/.local/bin/claude-kimi")
        XCTAssertTrue(draft.arguments.isEmpty)
        draft.selectHarness(.claudeCode)
        XCTAssertEqual(draft.executable, "~/.local/bin/claude-kimi")
        XCTAssertEqual(draft.arguments, "--bare\n-p\n<WORKJET_BRIEF>\n--allowedTools\nRead,Write,Edit,Grep,Glob,Bash")

        draft.arguments = "--custom-flag"
        draft.selectHarness(.piSidecar)
        XCTAssertEqual(draft.arguments, "--custom-flag")

        var defaults = WorkerDraft()
        defaults.selectHarness(.claudeCode)
        defaults.selectHarness(.piSidecar)
        XCTAssertEqual(defaults.executable, "node")
        XCTAssertTrue(defaults.arguments.isEmpty)
    }

    func testHarnessRegistryIsCompleteUniqueAndUsesVerifiedInvocationFoundations() {
        let adapters = HarnessAdapterRegistry.all
        XCTAssertEqual(Set(adapters.map(\.id)).count, adapters.count)
        XCTAssertEqual(Set(adapters.map(\.harness)), Set(Harness.allCases))
        XCTAssertEqual(HarnessAdapterRegistry.descriptor(for: .claudeCode).defaultInvocation, WorkerInvocation(executable: "claude", arguments: ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"]))
        XCTAssertEqual(HarnessAdapterRegistry.descriptor(for: .piSidecar).defaultInvocation, WorkerInvocation(executable: "node"))
        XCTAssertEqual(HarnessAdapterRegistry.descriptor(for: .codexCLI).defaultInvocation, WorkerInvocation(executable: "codex", arguments: ["exec", "--json", "<WORKJET_BRIEF>"]))
        XCTAssertEqual(HarnessAdapterRegistry.descriptor(for: .cursorAgent).defaultInvocation, WorkerInvocation(executable: "cursor-agent", arguments: ["acp"]))
        XCTAssertEqual(HarnessAdapterRegistry.descriptor(for: .openCode).defaultInvocation, WorkerInvocation(executable: "opencode", arguments: ["run", "--format", "json", "<WORKJET_BRIEF>"]))
        XCTAssertEqual(HarnessAdapterRegistry.descriptor(for: .grokCLI).defaultInvocation, WorkerInvocation(executable: "grok", arguments: ["agent", "stdio"]))
    }

    func testHarnessLegacyDecodingAndInvocationOptionsMigration() throws {
        let legacyValues: [(String, Harness)] = [
            ("Claude Code", .claudeCode), ("Pi Code", .piSidecar), ("Pi Sidecar", .piSidecar),
            ("Codex", .codexCLI), ("Cursor", .cursorAgent), ("Open Code", .openCode), ("Grok", .grokCLI)
        ]
        for (value, expected) in legacyValues {
            XCTAssertEqual(try JSONDecoder().decode(Harness.self, from: Data("\"\(value)\"".utf8)), expected)
        }
        let oldInvocation = Data(#"{"executable":"claude","arguments":["-p"],"capabilities":[]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WorkerInvocation.self, from: oldInvocation).options, [:])
    }

    func testDraftUsesAdapterDefaultsPreservesCustomInvocationAndFiltersOptions() {
        var draft = WorkerDraft()
        draft.model = "gpt-5.6-sol"
        draft.selectHarness(.codexCLI)
        XCTAssertTrue(draft.executable.hasSuffix("/codex") || draft.executable == "codex")
        XCTAssertEqual(draft.arguments, "exec\n--json\n<WORKJET_BRIEF>")
        XCTAssertEqual(HarnessAdapterRegistry.descriptor(for: .codexCLI).reasoningEfforts(for: draft.model), [.low, .medium, .high, .xhigh])
        XCTAssertEqual(
            HarnessAdapterRegistry.descriptor(for: .claudeCode).reasoningEfforts(for: draft.model),
            [.low, .medium, .high, .xhigh, .max, .ultra]
        )

        draft.executable = "/opt/custom/codex-wrapper"
        draft.arguments = "--custom"
        draft.selectHarness(.cursorAgent)
        XCTAssertEqual(draft.executable, "/opt/custom/codex-wrapper")
        XCTAssertEqual(draft.arguments, "--custom")

        draft.name = "Custom"
        draft.computerID = WorkjetDefaults.localID
        draft.harness = .claudeCode
        draft.model = "claude-opus-5"
        draft.harnessOptions = ["fastMode": "true", "invented": "yes"]
        let worker = draft.applied(to: nil)
        XCTAssertEqual(worker?.invocation.options, ["fastMode": "true"])
        XCTAssertEqual(HarnessAdapterRegistry.descriptor(for: .cursorAgent).reasoningEfforts(for: "auto"), [])
        XCTAssertEqual(HarnessAdapterRegistry.descriptor(for: .openCode).options(for: "openai/gpt-5"), [])
        XCTAssertEqual(HarnessAdapterRegistry.descriptor(for: .grokCLI).options(for: "grok-build"), [])
    }

    func testBootstrapNormalizesSkillOnlyAndDispatcherBounds() {
        var config = WorkjetDefaults.configuration()
        config.skillActivation = .global
        config.providerSlots = 9
        config.probeTimeoutSeconds = 1
        config.turnTimeoutSeconds = 99_999
        config.injectWorkerDeclarations = false
        let normalized = WorkjetBootstrap.normalized(config)
        XCTAssertEqual(normalized.skillActivation, .global)
        XCTAssertTrue(normalized.injectWorkerDeclarations)
        XCTAssertEqual(normalized.providerSlots, 3)
        XCTAssertEqual(normalized.probeTimeoutSeconds, 5)
        XCTAssertEqual(normalized.turnTimeoutSeconds, 10_800)
    }

    func testLegacyMonolithicPromptMovesModelSectionsOutOfEditableRules() {
        var config = WorkjetDefaults.configuration()
        config.modelPrompts = nil
        config.skillRules = """
        General before.

        You control these agents:

        GPT-5.6 Sol
        - Sol rule.

        MiniMax-M3
        - Mini rule.

        Kimi-K3
        - Kimi rule.

        Review model (two tiers):
        General after.
        """
        let migrated = WorkjetBootstrap.normalized(config)
        XCTAssertFalse(migrated.skillRules.contains("You control these agents:"))
        XCTAssertEqual(migrated.skillRules, "General before.\n\nReview model (two tiers):\nGeneral after.")
        XCTAssertEqual(migrated.modelPrompts?["GPT-5.6 Sol"], "- Sol rule.")
        XCTAssertEqual(migrated.modelPrompts?["MiniMax M3"], "- Mini rule.")
        XCTAssertEqual(migrated.modelPrompts?["Kimi K3"], "- Kimi rule.")
    }

    func testKnownPromptDefaultsMigrateWithoutTouchingOwnerText() {
        let ownerBefore = "OWNER RULE BEFORE"
        let ownerAfter = "OWNER RULE AFTER"
        let legacyBoard = """
        ## Progress board (mandatory for every larger orchestrated task)

        Whenever orchestration is engaged for a larger task (multiple workers, multiple waves, or work spanning sessions), create and maintain an HTML progress board, published as an Artifact with a stable URL per project. It is the shared workflow picture: the user checks it instead of asking, and it survives context compaction.

        Structure: overall progress bar · milestone/wave table with worker assignment and state (done / in progress / review open / blocked) · a dynamic "now next" list that absorbs follow-up tasks and subtasks as they appear · decisions log (short, with dates) · findings/risks strip.

        Update duty is EVENT-driven, never time-driven: milestone done, worker landed, review verdict, decision taken, new subtask discovered → update the board immediately (edit the same file, republish to the same URL). A board that lags reality is worse than no board — it lies with authority. No board for single-delegation errands: there, the smallest useful pattern is the task list alone.
        """
        let general = [ownerBefore, legacyBoard, ownerAfter].joined(separator: "\n\n")
        XCTAssertEqual(
            LegacyPromptMigration.removingKnownProgressBoardDefault(from: general),
            "\(ownerBefore)\n\n\(ownerAfter)"
        )
        XCTAssertEqual(
            LegacyPromptMigration.removingKnownProgressBoardDefault(from: "OWNER progress board wording"),
            "OWNER progress board wording"
        )

        let oldTechnical = """
        OWNER TECH BEFORE

        Der Skill `/workjet` lädt ausschließlich diesen vollständigen, in der Workjet-App sichtbaren Prompt. Der Skill selbst fügt keine Routing- oder Worker-Regeln hinzu.

        Direkte Anbieter-Pools werden deterministisch abgearbeitet und wechseln nur nach klassifizierten Auth-, Quota- oder Netzwerkfehlern zum nächsten Zugang; Task-Fehler lösen keinen Fallback aus.

        OWNER TECH AFTER
        """
        let migrated = LegacyPromptMigration.correctingKnownTechnicalDefaults(in: oldTechnical)
        XCTAssertTrue(migrated.contains("OWNER TECH BEFORE"))
        XCTAssertTrue(migrated.contains("OWNER TECH AFTER"))
        XCTAssertTrue(migrated.contains(LegacyPromptMigration.currentSkillActivationSentence))
        XCTAssertTrue(migrated.contains(LegacyPromptMigration.currentFallbackSentence))
        XCTAssertFalse(migrated.contains("Der Skill `/workjet`"))
        XCTAssertFalse(migrated.contains("Quota- oder Netzwerkfehlern"))

        var configuration = WorkjetDefaults.configuration()
        configuration.skillRules = general
        configuration.technicalRules = oldTechnical
        configuration.transparentWorkerPromptsMigrated = nil
        let normalized = WorkjetBootstrap.normalized(configuration)
        XCTAssertEqual(normalized.skillRules, "\(ownerBefore)\n\n\(ownerAfter)")
        XCTAssertTrue(normalized.technicalRules?.contains(migrated) == true)
        XCTAssertTrue(normalized.technicalRules?.contains(LegacyPromptMigration.cliExecutionContractBeginMarker) == true)
    }

    func testManagedTechnicalBlocksSynchronizeWithoutTouchingOwnerTextAndAreIdempotent() throws {
        let defaults = try XCTUnwrap(WorkjetDefaults.configuration().technicalRules)
        let receiptBegin = "<!-- WORKJET COMPLETION RECEIPT PROMPT BEGIN -->"
        let receiptEnd = "<!-- WORKJET COMPLETION RECEIPT PROMPT END -->"
        let greppyBegin = WorkerSkillCatalog.promptSourceBeginMarker(for: WorkerSkillCatalog.greppyID)
        let greppyEnd = WorkerSkillCatalog.promptSourceEndMarker(for: WorkerSkillCatalog.greppyID)
        let stale = """
        OWNER BEFORE
        \(greppyBegin)
        STALE GREPPY PROMPT THAT MUST BE REPLACED
        \(greppyEnd)
        OWNER BETWEEN ONE
        \(receiptBegin)
        stale receipt
        \(receiptEnd)
        OWNER BETWEEN TWO
        \(LegacyPromptMigration.cliExecutionContractBeginMarker)
        stale CLI contract that says events stream forever
        \(LegacyPromptMigration.cliExecutionContractEndMarker)
        <!-- WORKJET TRANSPARENT RUNTIME PROMPTS V2 -->
        OWNER AFTER
        """
        var configuration = WorkjetDefaults.configuration()
        configuration.technicalRules = stale

        let normalized = WorkjetBootstrap.normalized(configuration)
        let technical = try XCTUnwrap(normalized.technicalRules)
        for ownerText in ["OWNER BEFORE", "OWNER BETWEEN ONE", "OWNER BETWEEN TWO", "OWNER AFTER"] {
            XCTAssertTrue(technical.contains(ownerText), "Owner text changed: \(ownerText)")
        }
        XCTAssertFalse(technical.contains("STALE GREPPY PROMPT THAT MUST BE REPLACED"))
        XCTAssertFalse(technical.contains("stale receipt"))
        XCTAssertFalse(technical.contains("events stream forever"))
        XCTAssertFalse(technical.contains("WORKJET TRANSPARENT RUNTIME PROMPTS V2"))
        for (begin, end) in [
            (greppyBegin, greppyEnd),
            (receiptBegin, receiptEnd),
            (LegacyPromptMigration.cliExecutionContractBeginMarker, LegacyPromptMigration.cliExecutionContractEndMarker)
        ] {
            XCTAssertEqual(markedTestBlock(begin: begin, end: end, in: technical), markedTestBlock(begin: begin, end: end, in: defaults))
            XCTAssertEqual(technical.components(separatedBy: begin).count - 1, 1)
        }
        for begin in [
            "<!-- WORKJET WORKER PREAMBLE BEGIN -->",
            "<!-- WORKJET OPUS SYSTEM PROMPT BEGIN -->",
            "<!-- WORKJET HEALTH PROBE PROMPT BEGIN -->"
        ] {
            XCTAssertEqual(technical.components(separatedBy: begin).count - 1, 1)
        }
        XCTAssertEqual(WorkjetBootstrap.normalized(normalized), normalized)
    }

    func testFreshAndMigratedConfigurationsRenderTheSameManagedCLIContract() throws {
        let defaults = try XCTUnwrap(WorkjetDefaults.configuration().technicalRules)
        var legacy = WorkjetDefaults.configuration()
        legacy.technicalRules = "OWNER\n"
        legacy.transparentWorkerPromptsMigrated = nil
        let migrated = try XCTUnwrap(WorkjetBootstrap.normalized(legacy).technicalRules)
        let begin = LegacyPromptMigration.cliExecutionContractBeginMarker
        let end = LegacyPromptMigration.cliExecutionContractEndMarker
        XCTAssertEqual(markedTestBlock(begin: begin, end: end, in: migrated), markedTestBlock(begin: begin, end: end, in: defaults))
    }

    func testOnlyExactLegacyStandardCodingTaskIsRemoved() {
        let exact = Worker(
            name: "Standard Coding Task",
            harness: .claudeCode,
            model: "grok-4.5",
            instructions: "for standard high volume coding tasks",
            reasoningEffort: .high,
            computerID: WorkjetDefaults.localID,
            providerPool: .xAI,
            invocation: WorkerInvocation(executable: "~/.local/bin/claude-sol")
        )
        var customized: [Worker] = []
        var model = exact; model.id = UUID(); model.model = "grok-4.5-custom"; customized.append(model)
        var harness = exact; harness.id = UUID(); harness.harness = .codexCLI; customized.append(harness)
        var executable = exact; executable.id = UUID(); executable.invocation.executable = "/custom/claude-sol"; customized.append(executable)
        var arguments = exact; arguments.id = UUID(); arguments.invocation.arguments = ["--custom"]; customized.append(arguments)
        var capabilities = exact; capabilities.id = UUID(); capabilities.invocation.capabilities = ["custom"]; customized.append(capabilities)
        var options = exact; options.id = UUID(); options.invocation.options = ["fastMode": "true"]; customized.append(options)
        var instructions = exact; instructions.id = UUID(); instructions.instructions = "custom instructions"; customized.append(instructions)
        var reasoning = exact; reasoning.id = UUID(); reasoning.reasoningEffort = .xhigh; customized.append(reasoning)
        var provider = exact; provider.id = UUID(); provider.providerPool = .openAI; customized.append(provider)
        var skills = exact; skills.id = UUID(); skills.skillOverrides = [WorkerSkillCatalog.greppyID: false]; customized.append(skills)

        var configuration = WorkjetDefaults.configuration()
        let retainedDefaultIDs = Set(configuration.workers.map(\.id))
        configuration.workers += [exact] + customized
        let normalized = WorkjetBootstrap.normalized(configuration)
        let normalizedIDs = Set(normalized.workers.map(\.id))
        XCTAssertFalse(normalizedIDs.contains(exact.id))
        XCTAssertTrue(retainedDefaultIDs.isSubset(of: normalizedIDs))
        XCTAssertTrue(customized.allSatisfy { normalizedIDs.contains($0.id) })
        XCTAssertEqual(WorkjetBootstrap.normalized(normalized), normalized)
    }

    func testLegacyCLIProxyMigrationIsOneTime() {
        var config = WorkjetDefaults.configuration()
        config.cliProxy = CLIProxyConfiguration(endpoint: "http://127.0.0.1:9000", inferenceCredentialReference: "legacy-key")
        let migrated = WorkjetBootstrap.normalized(config)
        XCTAssertEqual(migrated.providers.count, 1)
        XCTAssertEqual(migrated.providers[0].kind, .cliProxyAPI)
        XCTAssertEqual(migrated.providers[0].credentialReference, "legacy-key")
        XCTAssertEqual(migrated.cliProxy, CLIProxyConfiguration())
        var deleted = migrated
        deleted.providers.removeAll()
        XCTAssertTrue(WorkjetBootstrap.normalized(deleted).providers.isEmpty)
    }
}

final class ConfigurationStoreTests: XCTestCase {
    func testVersionedRoundTripAndSecureModes() throws {
        let root = try temporaryDirectory(); let file = root.appendingPathComponent("support/Workjet/config.v1.json")
        let store = JSONConfigurationStore(fileURL: file); let expected = WorkjetDefaults.configuration(); try store.save(expected)
        XCTAssertEqual(try store.load(), expected)
        var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(file.deletingLastPathComponent().path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    func testCorruptAndUnsupportedConfigurationAreNotOverwritten() throws {
        let root = try temporaryDirectory(); let file = root.appendingPathComponent("config.v1.json"); let original = Data("{not-json".utf8); try original.write(to: file)
        let store = JSONConfigurationStore(fileURL: file); XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf: file), original)
        try Data("{\"version\":2}".utf8).write(to: file)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? LocalStateError, .unsupportedConfiguration(2)) }
    }

    func testProductionBootstrapUsesInjectedRootsOnly() throws {
        let root = try temporaryDirectory()
        let paths = WorkjetPaths(homeDirectory: root, applicationSupportDirectory: root.appendingPathComponent("support"), stateDirectory: root.appendingPathComponent("state"))
        let bootstrap = WorkjetBootstrap.live(paths: paths)
        XCTAssertEqual(bootstrap.configuration.selectedComputerID, WorkjetDefaults.localID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configurationFile.path))
        let prompt = try Data(contentsOf: paths.promptFile)
        XCTAssertNotNil(try ManagedPrompt.parse(prompt).body)
        XCTAssertTrue(bootstrap.messages.isEmpty)
    }

    func testAdHocLearningsAreGlobalAtomicAndDeduplicated() throws {
        let root = try temporaryDirectory()
        let store = AdHocLearningStore(fileURL: root.appendingPathComponent(".claude/workjet/LEARNINGS.md"))
        XCTAssertNil(try store.load())
        XCTAssertEqual(try store.appendSystematic("Repeatable failure → use explicit run ID"), "- Repeatable failure → use explicit run ID")
        XCTAssertEqual(try store.appendSystematic("Repeatable failure → use explicit run ID"), "- Repeatable failure → use explicit run ID")
        try store.replace(with: "- Edited persistent rule")
        XCTAssertEqual(try store.load(), "- Edited persistent rule")
        XCTAssertThrowsError(try store.appendSystematic(""))
    }

    func testBootstrapImportsExistingKimiLoginWithoutReopeningBrowser() throws {
        let root = try temporaryDirectory()
        let authDirectory = root.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let authFile = authDirectory.appendingPathComponent("kimi-1785829326952.json")
        try Data(#"{"type":"kimi","scope":"kimi-code","access_token":"not-copied"}"#.utf8).write(to: authFile)

        let bootstrap = WorkjetBootstrap.live(paths: WorkjetPaths(homeDirectory: root))
        let account = try XCTUnwrap(bootstrap.configuration.providers.first(where: { $0.modelProvider == .kimi }))

        XCTAssertEqual(account.accountLabel, "Kimi Code")
        XCTAssertEqual(account.externalCredentialID, authFile.lastPathComponent)
        XCTAssertEqual(account.credentialReference, CLIProxyGatewayCredentialStore.reference)
        XCTAssertFalse(String(describing: account).contains("not-copied"))
    }
}

final class ManagedPromptTests: XCTestCase {
    func testRendererIsDeterministicAndTruthful() {
        let config = WorkjetDefaults.configuration(); let body = ManagedPrompt.workerBody(configuration: config)
        XCTAssertEqual(body, ManagedPrompt.workerBody(configuration: config)); let text = String(decoding: body, as: UTF8.self)
        let workerOffset = try! XCTUnwrap(text.range(of: "## Worker")?.lowerBound)
        let learningOffset = try! XCTUnwrap(text.range(of: "## Ad-hoc Learnings")?.lowerBound)
        let technicalOffset = try! XCTUnwrap(text.range(of: "## Technische Regeln")?.lowerBound)
        XCTAssertLessThan(workerOffset, learningOffset)
        XCTAssertLessThan(learningOffset, technicalOffset)
        XCTAssertTrue(text.contains("#### Modellregeln · Kimi K3"))
        XCTAssertEqual(text.components(separatedBy: "#### Modellregeln · Kimi K3").count - 1, 1)
        XCTAssertTrue(text.contains("Use Kimi UI/UX for greenfield or explicitly assigned visual implementation."))
        XCTAssertTrue(text.contains("Workjet CLI execution contract (machine-owned):"))
        XCTAssertFalse(text.contains(WorkerSkillCatalog.promptSourceBeginMarker(for: WorkerSkillCatalog.greppyID)), "Worker-only skill prompt sources must not leak into the orchestrator prompt")
        for worker in config.workers { XCTAssertTrue(text.contains(worker.id.uuidString.lowercased())); XCTAssertTrue(text.contains(worker.invocation.executable)); XCTAssertTrue(text.contains(worker.model)) }
        var hostile = config; hostile.workers[0].instructions = ManagedPrompt.endMarker
        XCTAssertNoThrow(try ManagedPrompt.parse(ManagedPrompt.block(body: ManagedPrompt.workerBody(configuration: hostile))))

        let provider = Provider(name: "CLI Route", kind: .cliProxy, endpoint: "http://127.0.0.1:8317", credentialReference: "must-not-render")
        var routed = config; routed.providers = [provider]; routed.workers[0].providerID = provider.id
        let routedText = String(decoding: ManagedPrompt.workerBody(configuration: routed), as: UTF8.self)
        XCTAssertTrue(routedText.contains("CLI Route"))
        XCTAssertTrue(routedText.contains("CLIProxyAPI"))
        XCTAssertFalse(routedText.contains("must-not-render"))
        routed.providers = []
        let unavailable = String(decoding: ManagedPrompt.workerBody(configuration: routed), as: UTF8.self)
        XCTAssertTrue(unavailable.contains("Nicht verfügbar"))
        XCTAssertTrue(unavailable.contains(provider.id.uuidString.lowercased()))
    }

    func testMultilineInstructionsMentionsAndReasoningRenderExactlyOnce() throws {
        var config = WorkjetDefaults.configuration()
        config.workers[0].name = "Kimi-K3"
        config.workers[0].instructions = "Erste Zeile\n\n- Markdown bleibt\nArbeite mit @Kimi-UI-UX."
        config.workers[0].reasoningEffort = .xhigh
        XCTAssertEqual(config.workers[0].mentionTag, "@Kimi-K3")
        XCTAssertEqual(config.workers[2].mentionTag, "@Kimi-UI-UX")
        let text = String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self)
        XCTAssertTrue(text.contains("### @Kimi-K3 — Kimi-K3"))
        XCTAssertTrue(text.contains("Erste Zeile\n\n- Markdown bleibt\nArbeite mit @Kimi-UI-UX."))
        XCTAssertEqual(text.components(separatedBy: "Erste Zeile").count - 1, 1)
        XCTAssertTrue(text.contains("Reasoning: `xhigh`"))
        XCTAssertFalse(text.contains("Fable muss den konfigurierten Effort"))
        XCTAssertTrue(ManagedPrompt.unresolvedMentions(in: config.workers[0].instructions, workers: config.workers).isEmpty)
        XCTAssertEqual(ManagedPrompt.unresolvedMentions(in: "Frage @Missing und @Missing", workers: config.workers), ["@Missing"])
        config.workers[0].instructions = "<!-- WORKJET WORKER INSTRUCTIONS END @Kimi-K3 -->"
        XCTAssertFalse(String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self).contains("<!-- WORKJET WORKER INSTRUCTIONS END @Kimi-K3 -->\n<!-- WORKJET WORKER INSTRUCTIONS END @Kimi-K3 -->"))
    }

    func testWorkerInstructionsCanBeSeparatedFromProtectedRuntimePreview() {
        var config = WorkjetDefaults.configuration()
        config.workers[0].instructions = "UNIQUE WORKER TASK"
        let full = String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self)
        let runtime = String(decoding: ManagedPrompt.workerBody(configuration: config, includeModelPrompts: false, includeWorkerInstructions: false), as: UTF8.self)
        XCTAssertTrue(full.contains("UNIQUE WORKER TASK"))
        XCTAssertFalse(runtime.contains("UNIQUE WORKER TASK"))
        XCTAssertTrue(runtime.contains(config.workers[0].mentionTag))
    }

    func testManagedPromptUsesAdapterNameProtocolAndPersistedInvocation() {
        var config = WorkjetDefaults.configuration()
        config.workers[0].harness = .grokCLI
        config.workers[0].invocation = WorkerInvocation(
            executable: "/opt/bin/grok",
            arguments: ["agent", "stdio"],
            options: ["future": "kept-in-existing-config"]
        )
        let text = String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self)
        XCTAssertTrue(text.contains("- Harness: Grok CLI"))
        XCTAssertTrue(text.contains("- Invocation-Protokoll: `agentClientProtocol`"))
        XCTAssertTrue(text.contains("- Executable: `/opt/bin/grok`"))
        XCTAssertTrue(text.contains("- Argumente: [`agent`, `stdio`]"))
        XCTAssertTrue(text.contains("- Harness-Optionen: `future=kept-in-existing-config`"))
    }

    func testReasoningCodableDraftAndLegacyDecode() throws {
        var worker = WorkjetDefaults.configuration().workers[0]
        worker.reasoningEffort = .ultra
        let encoded = try JSONEncoder().encode(worker)
        XCTAssertEqual(try JSONDecoder().decode(Worker.self, from: encoded).reasoningEffort, .ultra)
        var draft = WorkerDraft(worker: worker)
        draft.reasoningEffort = .max
        XCTAssertEqual(draft.applied(to: worker)?.reasoningEffort, .max)
        let legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var legacy = legacyObject
        legacy.removeValue(forKey: "reasoningEffort")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(Worker.self, from: legacyData).reasoningEffort)
    }

    func testVersionOneConfigurationWithoutModelPromptsRemainsDecodable() throws {
        let encoded = try JSONEncoder().encode(WorkjetDefaults.configuration())
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "modelPrompts")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(WorkjetConfiguration.self, from: legacy).modelPrompts)
    }

    func testVersionOneConfigurationWithoutLearningAndTechnicalRulesRemainsDecodable() throws {
        let encoded = try JSONEncoder().encode(WorkjetDefaults.configuration())
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "adHocLearnings")
        object.removeValue(forKey: "technicalRules")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WorkjetConfiguration.self, from: legacy)
        XCTAssertNil(decoded.adHocLearnings)
        XCTAssertNil(decoded.technicalRules)
        let normalized = WorkjetBootstrap.normalized(decoded)
        XCTAssertEqual(normalized.adHocLearnings, "")
        XCTAssertFalse(normalized.technicalRules?.isEmpty ?? true)
    }

    func testPromptSectionOrderAndNoRendererOnlyPolicy() {
        var config = WorkjetDefaults.configuration()
        config.adHocLearnings = "LEARNING SENTINEL"
        config.technicalRules = "TECHNICAL SENTINEL"
        config.workers[0].instructions = "WORKER SENTINEL"
        let text = String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self)
        let worker = text.range(of: "WORKER SENTINEL")!.lowerBound
        let learning = text.range(of: "LEARNING SENTINEL")!.lowerBound
        let technical = text.range(of: "TECHNICAL SENTINEL")!.lowerBound
        XCTAssertLessThan(worker, learning)
        XCTAssertLessThan(learning, technical)
        XCTAssertEqual(text.components(separatedBy: "LEARNING SENTINEL").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "TECHNICAL SENTINEL").count - 1, 1)
        XCTAssertFalse(text.contains("automatisch erzeugt · nicht editierbar"))
    }

    func testAppendReplaceAndHandwrittenEdit() throws {
        let outside = Data([0x23, 0x20, 0x48, 0x61, 0x6e, 0x64, 0x0a, 0x0a, 0x58])
        let appended = try ManagedPrompt.replacingManagedBlock(in: outside, body: Data("one".utf8)); XCTAssertTrue(appended.starts(with: outside))
        let first = try ManagedPrompt.parse(appended); let replaced = try ManagedPrompt.replacingManagedBlock(in: appended, body: Data("two".utf8)); let second = try ManagedPrompt.parse(replaced)
        XCTAssertEqual(first.prefix, second.prefix); XCTAssertEqual(first.suffix, second.suffix); XCTAssertEqual(second.body, Data("two".utf8))
        let edited = try ManagedPrompt.replacingHandwrittenContent(in: replaced, rules: "new rules", body: Data("two".utf8))
        XCTAssertEqual(try ManagedPrompt.handwrittenContent(from: edited), "new rules"); XCTAssertEqual(try ManagedPrompt.parse(edited).body, Data("two".utf8))
    }

    func testConcurrentSynchronizationUsesStableLockAndPreservesManagedHash() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("AGENTS.md")
        let store = ManagedPromptStore(fileURL: file)
        var first = WorkjetDefaults.configuration(); first.workers[0].name = "Writer One"
        var second = WorkjetDefaults.configuration(); second.workers[0].name = "Writer Two"
        try store.synchronize(first, handwrittenChanged: false)

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "prompt-writers", attributes: .concurrent)
        let lock = NSLock()
        var errors: [Error] = []
        for configuration in [first, second] {
            group.enter()
            queue.async {
                defer { group.leave() }
                do { try store.synchronize(configuration, handwrittenChanged: false) }
                catch { lock.lock(); errors.append(error); lock.unlock() }
            }
        }
        group.wait()
        XCTAssertTrue(errors.isEmpty)
        let data = try Data(contentsOf: file)
        let parsed = try ManagedPrompt.parse(data)
        let body = try XCTUnwrap(parsed.body)
        XCTAssertTrue(body == ManagedPrompt.workerBody(configuration: first) || body == ManagedPrompt.workerBody(configuration: second))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockURL.path))
    }

    func testMismatchMalformedDuplicateAndSymlinkRefused() throws {
        let valid = ManagedPrompt.block(body: Data("body".utf8)); var tampered = valid
        let bodyOffset = String(decoding: valid, as: UTF8.self).firstIndex(of: "\n")!.utf16Offset(in: String(decoding: valid, as: UTF8.self)) + 1; tampered[bodyOffset] = 0x58
        XCTAssertThrowsError(try ManagedPrompt.parse(tampered)) { XCTAssertEqual($0 as? LocalStateError, .promptHashMismatch) }
        var duplicate = valid; duplicate.append(Data("\n".utf8)); duplicate.append(valid); XCTAssertThrowsError(try ManagedPrompt.parse(duplicate))
        XCTAssertThrowsError(try ManagedPrompt.parse(Data("<!-- WORKJET MANAGED WORKERS BEGIN v1 sha256=x -->".utf8)))
        let root = try temporaryDirectory(); let target = root.appendingPathComponent("target"); try valid.write(to: target); let link = root.appendingPathComponent("AGENTS.md"); XCTAssertEqual(symlink(target.path, link.path), 0)
        XCTAssertThrowsError(try ManagedPromptStore(fileURL: link).loadHandwrittenRules())
        let safeTarget = root.appendingPathComponent("safe-AGENTS.md")
        let lockStore = ManagedPromptStore(fileURL: safeTarget)
        let attackerLock = root.appendingPathComponent("attacker-lock"); try Data().write(to: attackerLock)
        XCTAssertEqual(symlink(attackerLock.path, lockStore.lockURL.path), 0)
        XCTAssertThrowsError(try lockStore.synchronize(WorkjetDefaults.configuration(), handwrittenChanged: false))
    }
}

final class RunTelemetryTests: XCTestCase {
    private final class Probe: ProcessProbing, @unchecked Sendable {
        var identities: [Int32: ProcessIdentity] = [:]; var terminated: [Int32] = []; var killed: [Int32] = []; var ignoresTERM = false
        func identity(for pid: Int32) -> ProcessIdentity? { identities[pid] }
        func sendTERM(to pid: Int32) throws { terminated.append(pid); if !ignoresTERM { identities[pid] = nil } }
        func sendKILL(to pid: Int32) throws { killed.append(pid); identities[pid] = nil }
    }
    private final class Fixture {
        let root: URL; let index: URL; let runs: URL; let probe = Probe(); lazy var store = RunTelemetryStore(paths: WorkjetPaths(homeDirectory: root, stateDirectory: root), processProbe: probe)
        init() throws { root = try temporaryDirectory(); index = root.appendingPathComponent("run-index"); runs = root.appendingPathComponent("runs"); try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true) }
        func make(_ id: String, _ pid: Int32, _ worker: String, terminal: String? = nil) throws -> URL {
            let run = runs.appendingPathComponent(id); try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true); try Data(run.path.utf8).write(to: index.appendingPathComponent(id)); try Data("\(pid)\n".utf8).write(to: run.appendingPathComponent("pid")); try Data(worker.utf8).write(to: run.appendingPathComponent("worker")); try Data("2026-08-03T09:00:00Z\n".utf8).write(to: run.appendingPathComponent("started-at")); FileManager.default.createFile(atPath: run.appendingPathComponent("heartbeat").path, contents: Data()); if let terminal { FileManager.default.createFile(atPath: run.appendingPathComponent(terminal).path, contents: Data()) }; return run
        }
    }
    private func identity(_ pid: Int32, start: String = "1785747600.000000") -> ProcessIdentity { ProcessIdentity(pid: pid, executablePath: "/usr/bin/worker", startToken: start) }

    func testRunningCompletedDeadUnknownMalformedAndDeliveryFixtures() throws {
        let f = try Fixture(); let run = try f.make("running", 100, "claude"); try Data("safe title".utf8).write(to: run.appendingPathComponent("title")); FileManager.default.createFile(atPath: run.appendingPathComponent("stream-json").path, contents: Data()); f.probe.identities[100] = identity(100)
        _ = try f.make("completed", 101, "claude", terminal: "exit-code"); _ = try f.make("dead", 102, "claude"); _ = try f.make("unknown", 103, "mystery-wrapper"); f.probe.identities[103] = identity(103)
        let malformed = f.runs.appendingPathComponent("malformed"); try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true); try Data(malformed.path.utf8).write(to: f.index.appendingPathComponent("malformed"))
        let records = f.store.scan(workers: WorkjetDefaults.configuration().workers)
        let running = records.first { $0.sourceRunID == "running" }; XCTAssertEqual(running?.state, .running); XCTAssertEqual(running?.activeRun?.delivery, .live); XCTAssertEqual(running?.activeRun?.activity, "safe title"); XCTAssertNotNil(running?.activeRun?.lastHeartbeat)
        XCTAssertEqual(records.first { $0.sourceRunID == "completed" }?.state, .completed); XCTAssertEqual(records.first { $0.sourceRunID == "dead" }?.state, .interrupted); XCTAssertEqual(records.first { $0.sourceRunID == "malformed" }?.state, .malformed)
        let unknown = records.first { $0.sourceRunID == "unknown" }; XCTAssertEqual(unknown?.state, .running); XCTAssertEqual(unknown?.activeRun?.workerName, "mystery-wrapper · nicht konfiguriert"); XCTAssertNil(unknown?.activeRun?.workerModel)
    }

    func testPiIsPostHocAndStopChecksPIDIdentity() throws {
        let f = try Fixture(); var pi = WorkjetDefaults.configuration().workers[0]; pi.harness = .piSidecar; pi.invocation.executable = "pi-worker"
        let piRun = try f.make("pi", 104, "pi-worker"); FileManager.default.createFile(atPath: piRun.appendingPathComponent("response-events.jsonl").path, contents: Data()); f.probe.identities[104] = identity(104)
        XCTAssertEqual(f.store.scan(workers: [pi]).first?.activeRun?.delivery, .postHoc)
        _ = try f.make("stop", 105, "claude"); f.probe.identities[105] = identity(105); let active = try XCTUnwrap(f.store.scan(workers: WorkjetDefaults.configuration().workers).first { $0.sourceRunID == "stop" }?.activeRun)
        f.probe.identities[105] = ProcessIdentity(pid: 105, executablePath: "/other", startToken: "reused"); XCTAssertThrowsError(try f.store.stop(active)) { XCTAssertEqual($0 as? StopError, .pidMismatch) }; XCTAssertTrue(f.probe.terminated.isEmpty)
        f.probe.identities[105] = identity(105); try f.store.stop(active); XCTAssertEqual(f.probe.terminated, [105])
    }

    func testStopEscalatesToKILLWhenConfirmedWorkerIgnoresTERM() throws {
        let f = try Fixture()
        _ = try f.make("stubborn", 106, "/usr/bin/worker")
        f.probe.identities[106] = identity(106)
        f.probe.ignoresTERM = true
        let active = try XCTUnwrap(f.store.scan(workers: []).first?.activeRun)

        try f.store.stop(active)

        XCTAssertEqual(f.probe.terminated, [106])
        XCTAssertEqual(f.probe.killed, [106])
        XCTAssertNil(f.probe.identities[106])
    }

    func testProtocolHarnessesDoNotClaimClaudeOrPiTelemetry() throws {
        for (offset, harness) in [Harness.codexCLI, .cursorAgent, .openCode, .grokCLI].enumerated() {
            let f = try Fixture()
            var worker = WorkjetDefaults.configuration().workers[0]
            worker.harness = harness
            worker.invocation = HarnessAdapterRegistry.descriptor(for: harness).defaultInvocation
            let pid = Int32(700 + offset)
            let run = try f.make("protocol-\(offset)", pid, worker.invocation.executable)
            FileManager.default.createFile(atPath: run.appendingPathComponent("stream-json").path, contents: Data())
            FileManager.default.createFile(atPath: run.appendingPathComponent("response-events.jsonl").path, contents: Data())
            f.probe.identities[pid] = identity(pid)
            XCTAssertEqual(f.store.scan(workers: [worker]).first?.activeRun?.delivery, .unavailable)
        }
    }

    func testReusedPIDWithLaterProcessStartIsInterrupted() throws {
        let f = try Fixture()
        _ = try f.make("old-run", 691, "claude")
        f.probe.identities[691] = identity(691, start: "1785920400.000000")
        let record = try XCTUnwrap(f.store.scan(workers: WorkjetDefaults.configuration().workers).first { $0.sourceRunID == "old-run" })
        XCTAssertEqual(record.state, .interrupted)
        XCTAssertNil(record.activeRun)
        XCTAssertTrue(record.diagnostic?.contains("später gestarteten Prozess") == true)
    }

    func testCanonicalRunSnapshotRequiresFreshHeartbeat() throws {
        let f = try Fixture()
        let run = try f.make("snapshot", 692, "claude")
        f.probe.identities[692] = identity(692)
        let fresh = "{\"schemaVersion\":1,\"sequence\":1,\"state\":\"running\",\"heartbeatAt\":\"\(ISO8601DateFormatter().string(from: Date()))\"}"
        try Data(fresh.utf8).write(to: run.appendingPathComponent("run-state.json"))
        XCTAssertEqual(f.store.scan(workers: WorkjetDefaults.configuration().workers).first?.state, .running)

        let stale = "{\"schemaVersion\":1,\"sequence\":2,\"state\":\"running\",\"heartbeatAt\":\"2026-08-03T09:00:00Z\"}"
        try Data(stale.utf8).write(to: run.appendingPathComponent("run-state.json"))
        let record = try XCTUnwrap(f.store.scan(workers: WorkjetDefaults.configuration().workers).first)
        XCTAssertEqual(record.state, .interrupted)
        XCTAssertTrue(record.diagnostic?.contains("Heartbeat") == true)
    }
}

final class CLIProxyTests: XCTestCase {
    private final class Client: HTTPClient, @unchecked Sendable { var responses: [HTTPResponse] = []; var requests: [URLRequest] = []; func request(_ request: URLRequest) async throws -> HTTPResponse { requests.append(request); if responses.isEmpty { throw URLError(.cannotConnectToHost) }; return responses.removeFirst() } }
    private final class Credentials: CredentialStoring, @unchecked Sendable { var values: [String: Data] = [:]; func read(reference: String) throws -> Data? { values[reference] }; func write(_ secret: Data, reference: String) throws { values[reference] = secret }; func delete(reference: String) throws { values[reference] = nil } }

    func testAccountDiscoveryUsesProviderAuthIdentityWithoutReadingTokensIntoConfiguration() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authDirectory = home.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let first = authDirectory.appendingPathComponent("codex-michael@example.com-pro.json")
        let second = authDirectory.appendingPathComponent("codex-team@example.org-pro.json")
        let ignored = authDirectory.appendingPathComponent("xai-other@example.net.json")
        let kimi = authDirectory.appendingPathComponent("kimi-1785829326952.json")
        try Data(#"{"email":"michael@example.com","access_token":"must-not-escape"}"#.utf8).write(to: first)
        try Data(#"{"email":"team@example.org","refresh_token":"must-not-escape"}"#.utf8).write(to: second)
        try Data(#"{"email":"other@example.net"}"#.utf8).write(to: ignored)
        try Data(#"{"type":"kimi","scope":"kimi-code","access_token":"must-not-escape"}"#.utf8).write(to: kimi)

        let accounts = CLIProxyAccountAuthenticator.availableAccounts(for: .openAI, homeDirectory: home)

        XCTAssertEqual(accounts.map(\.label), ["michael@example.com", "team@example.org"])
        XCTAssertEqual(Set(accounts.flatMap(\.sourceRecordIDs)), Set([first.lastPathComponent, second.lastPathComponent]))
        XCTAssertEqual(Set(accounts.map(\.externalID)).count, 2)
        XCTAssertFalse(String(describing: accounts).contains("must-not-escape"))
        XCTAssertEqual(CLIProxyAccountAuthenticator.availableAccounts(for: .xAI, homeDirectory: home).map(\.label), ["other@example.net"])
        XCTAssertEqual(CLIProxyAccountAuthenticator.availableAccounts(for: .kimi, homeDirectory: home), [
            CLIProxyAuthenticatedAccount(label: "Kimi Code", externalID: kimi.lastPathComponent, sourceRecordID: kimi.lastPathComponent)
        ])

        let provider = Provider(name: "OpenAI 1", kind: .cliProxyAPI, endpoint: "http://127.0.0.1:8317", accountLabel: accounts[0].label)
        XCTAssertEqual(provider.compactAccountLabel, "mi…@example.com")
    }

    func testUnsafeUsageDisabledAndDistinctStates() async {
        let unsafeClient = Client(); let unsafe = await CLIProxyInspector(client: unsafeClient, credentials: Credentials()).inspect(CLIProxyConfiguration(endpoint: "http://192.168.1.5:8317")); XCTAssertEqual(unsafe.state, .unsafeEndpoint); XCTAssertTrue(unsafeClient.requests.isEmpty)
        let disabledClient = Client(); disabledClient.responses = [HTTPResponse(statusCode: 200, data: Data())]; let disabled = await CLIProxyInspector(client: disabledClient, credentials: Credentials()).inspect(CLIProxyConfiguration()); XCTAssertEqual(disabled.state, .usageDisabled); XCTAssertEqual(disabledClient.requests.count, 1)
        let authClient = Client(); authClient.responses = [HTTPResponse(statusCode: 401, data: Data())]; let auth = await CLIProxyInspector(client: authClient, credentials: Credentials()).inspect(CLIProxyConfiguration()); XCTAssertEqual(auth.state, .authRequired)
        let missingRouteClient = Client(); missingRouteClient.responses = [HTTPResponse(statusCode: 404, data: Data())]; let missingRoute = await CLIProxyInspector(client: missingRouteClient, credentials: Credentials()).inspect(CLIProxyConfiguration()); XCTAssertEqual(missingRoute.state, .offline); XCTAssertTrue(missingRoute.detail.contains("/v1/models"))
        let managementClient = Client(); managementClient.responses = [HTTPResponse(statusCode: 200, data: Data())]; var config = CLIProxyConfiguration(); config.usageStatisticsEnabled = true; let management = await CLIProxyInspector(client: managementClient, credentials: Credentials()).inspect(config); XCTAssertEqual(management.state, .managementUnavailable)
    }

    func testProviderBackwardsCodableAndEndpointPolicies() throws {
        let id = UUID()
        let legacy = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Legacy\",\"kind\":\"Direkter API-Key\",\"endpoint\":\"https://api.example.test\",\"status\":\"Nicht geprüft\",\"capacity\":{\"unavailable\":{\"reason\":\"n/a\"}},\"loginArguments\":[]}".utf8)
        let provider = try JSONDecoder().decode(Provider.self, from: legacy)
        XCTAssertEqual(provider.kind, .directAPI)
        XCTAssertEqual(provider.modelIDs, [])
        XCTAssertEqual(provider.credentialReference, Provider.credentialReference(for: id))
        XCTAssertEqual(ProviderEndpointValidator.validate("https://api.example.test", kind: .directAPI), .valid(URL(string: "https://api.example.test")!))
        if case .valid = ProviderEndpointValidator.validate("http://127.0.0.1:9000", kind: .directAPI) {} else { XCTFail("Loopback development endpoint should be allowed") }
        if case .invalid = ProviderEndpointValidator.validate("http://api.example.test", kind: .directAPI) {} else { XCTFail("Remote direct HTTP must be rejected") }
        if case .valid = ProviderEndpointValidator.validate("http://localhost:8317", kind: .cliProxyAPI) {} else { XCTFail("Loopback gateway should be allowed") }
        if case .invalid = ProviderEndpointValidator.validate("https://gateway.example.test", kind: .cliProxyRust) {} else { XCTFail("Remote gateway must be rejected") }
        if case .invalid = ProviderEndpointValidator.validate("https://user:secret@api.example.test", kind: .directAPI) {} else { XCTFail("URL credentials must be rejected") }
        XCTAssertEqual(ProviderEndpointValidator.modelsURL(baseURL: URL(string: "https://api.example.test/v1")!).path, "/v1/models")
        let legacyOAuth = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Legacy OAuth\",\"kind\":\"OAuth/Abo\",\"endpoint\":\"http://127.0.0.1:8317\"}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(Provider.self, from: legacyOAuth).kind, .cliProxyAPI)
    }

    func testProviderProbeSendsBearerOnlyWhenExplicitlyCalledAndDiscoversModels() async {
        let client = Client()
        client.responses = [HTTPResponse(statusCode: 200, data: Data(#"{"data":[{"id":"gpt-5.6-sol"},{"id":"claude-sonnet-5"},{"id":"gpt-5.6-sol"}]}"#.utf8))]
        let credentials = Credentials()
        let provider = Provider(name: "Direct", kind: .directAPI, endpoint: "https://api.example.test")
        credentials.values[provider.credentialReference!] = Data("top-secret".utf8)
        XCTAssertTrue(client.requests.isEmpty)
        let result = await ProviderInspector(client: client, credentials: credentials).inspect(provider)
        XCTAssertEqual(result.status, .connected)
        XCTAssertEqual(result.modelIDs, ["gpt-5.6-sol", "claude-sonnet-5"])
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].url?.path, "/v1/models")
        XCTAssertEqual(client.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer top-secret")
        XCTAssertFalse(result.detail.contains("top-secret"))
        XCTAssertEqual(WorkerModelSuggestions.values(providerID: provider.id, providers: [Provider(id: provider.id, name: provider.name, kind: provider.kind, endpoint: provider.endpoint, modelIDs: result.modelIDs)]).prefix(2), result.modelIDs.prefix(2))
    }

    func testProviderProbeSupportsAPIKeyHeaderAuthentication() async {
        let client = Client()
        client.responses = [HTTPResponse(statusCode: 200, data: Data(#"{"data":[{"id":"claude-sonnet-5"}]}"#.utf8))]
        let credentials = Credentials()
        let provider = Provider(name: "Anthropic", kind: .directAPI, endpoint: "https://api.anthropic.com", authentication: .apiKeyHeader)
        credentials.values[provider.credentialReference!] = Data("api-secret".utf8)

        let result = await ProviderInspector(client: client, credentials: credentials).inspect(provider)

        XCTAssertEqual(result.status, .connected)
        XCTAssertEqual(client.requests[0].value(forHTTPHeaderField: "x-api-key"), "api-secret")
        XCTAssertEqual(client.requests[0].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(client.requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testGatewayProbeDoesNotSubstituteKindsAndParsesCompatibleModels() async {
        for kind in [ProviderKind.cliProxyAPI, .cliProxyRust] {
            let client = Client()
            client.responses = [HTTPResponse(statusCode: 200, data: Data(#"{"data":[{"id":"gateway-model"}]}"#.utf8))]
            let result = await ProviderInspector(client: client, credentials: Credentials()).inspect(Provider(
                name: kind.rawValue,
                kind: kind,
                endpoint: "http://127.0.0.1:8317",
                authentication: .none
            ))
            XCTAssertEqual(result.status, .connected)
            XCTAssertEqual(result.modelIDs, ["gateway-model"])
            XCTAssertTrue(result.detail.contains("lokalen Gateway"))
        }
    }

    func testManagementUsesDistinctCredentialAndParsesCapacity() async {
        let client = Client(); client.responses = [HTTPResponse(statusCode: 200, data: Data()), HTTPResponse(statusCode: 200, data: Data("{\"usage\":{\"used\":25,\"limit\":100,\"window\":\"monthly\",\"identity\":\"account-a\"}}".utf8))]
        let credentials = Credentials(); credentials.values["management"] = Data("mgmt-secret".utf8); credentials.values["inference"] = Data("inference-secret".utf8)
        let status = await CLIProxyInspector(client: client, credentials: credentials).inspect(CLIProxyConfiguration(inferenceCredentialReference: "inference", managementCredentialReference: "management", usageStatisticsEnabled: true))
        XCTAssertEqual(status.state, .reachable); XCTAssertEqual(status.capacity.fraction, 0.25); XCTAssertEqual(client.requests.count, 2); XCTAssertEqual(client.requests[0].url?.path, "/v1/models"); XCTAssertEqual(client.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer inference-secret"); XCTAssertEqual(client.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer mgmt-secret")

        let aggregateClient = Client(); aggregateClient.responses = [HTTPResponse(statusCode: 200, data: Data()), HTTPResponse(statusCode: 200, data: Data("{\"total_tokens\":9000,\"used\":25,\"limit\":100}".utf8))]
        let aggregate = await CLIProxyInspector(client: aggregateClient, credentials: credentials).inspect(CLIProxyConfiguration(inferenceCredentialReference: "inference", managementCredentialReference: "management", usageStatisticsEnabled: true))
        XCTAssertNil(aggregate.capacity.fraction)
        XCTAssertTrue(aggregate.capacity.reason?.contains("identitäts") == true)
    }
}

final class TailscaleDeviceTests: XCTestCase {
    private actor Runner: CommandRunning {
        var result: CommandResult
        var commands: [CommandSpec] = []
        init(_ result: CommandResult) { self.result = result }
        func run(_ command: CommandSpec) async throws -> CommandResult { commands.append(command); return result }
        func recorded() -> [CommandSpec] { commands }
    }
    private struct Locator: TailscaleLocating { var path: String?; func executablePath() -> String? { path } }

    private var statusJSON: Data {
        Data(#"{"BackendState":"Running","Self":{"ID":"self-id","HostName":"mac"},"Peer":{"node-off":{"ID":"off-id","HostName":"zeta","DNSName":"zeta.tailnet.ts.net.","TailscaleIPs":["fd7a::2","100.64.0.2"],"Online":false,"OS":"linux"},"node-on":{"ID":"on-id","HostName":"alpha","DNSName":"alpha.tailnet.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":true,"OS":"linux"},"duplicate-self":{"ID":"self-id","HostName":"mac"}}}"#.utf8)
    }

    func testParserExcludesSelfTrimsDNSSelectsIPv4AndOrdersOnlineFirst() throws {
        let devices = try TailscaleDeviceParser.parse(statusJSON)
        XCTAssertEqual(devices.map(\.id), ["on-id", "off-id"])
        XCTAssertEqual(devices[0].dnsName, "alpha.tailnet.ts.net")
        XCTAssertEqual(devices[0].preferredHost, "100.64.0.1")
        XCTAssertEqual(devices[1].ipv4, "100.64.0.2")
        XCTAssertEqual(devices[1].preferredHost, "100.64.0.2")
        XCTAssertTrue(devices[0].online)
        XCTAssertFalse(devices[1].online)
    }

    func testDiscoveryUsesAllowlistedExecutableAndReportsErrors() async throws {
        let runner = Runner(CommandResult(exitCode: 0, standardOutput: statusJSON))
        let devices = try await TailscaleDeviceDiscovery(runner: runner, locator: Locator(path: "/usr/bin/tailscale")).discover()
        XCTAssertEqual(devices.count, 2)
        let commands = await runner.recorded()
        XCTAssertEqual(commands.first?.executable, "/usr/bin/tailscale")
        XCTAssertEqual(commands.first?.arguments, ["status", "--json"])
        XCTAssertEqual(commands.first?.stdoutLimit, 1_048_576)

        do {
            _ = try await TailscaleDeviceDiscovery(runner: runner, locator: Locator(path: "/tmp/tailscale")).discover()
            XCTFail("Expected unavailable executable")
        } catch { XCTAssertEqual(error as? TailscaleDeviceError, .unavailable) }
        XCTAssertThrowsError(try TailscaleDeviceParser.parse(Data(#"{"BackendState":"Stopped","Peer":{}}"#.utf8))) {
            XCTAssertEqual($0 as? TailscaleDeviceError, .notConnected("Stopped"))
        }
    }
}

final class RemotePiBootstrapTests: XCTestCase {
    private actor Runner: CommandRunning {
        var results: [CommandResult]
        var recorded: [CommandSpec] = []
        init(_ results: [CommandResult]) { self.results = results }
        func run(_ command: CommandSpec) async throws -> CommandResult {
            recorded.append(command)
            return results.isEmpty ? CommandResult(exitCode: 0) : results.removeFirst()
        }
        func commands() -> [CommandSpec] { recorded }
    }

    private final class Files: OwnedFileReading, @unchecked Sendable {
        var values: [String: Data] = [:]
        var failure: Error?
        func readOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
            if let failure { throw failure }
            return values[url.path] ?? Data("bundle".utf8)
        }
    }

    private struct Locator: TailscaleLocating {
        var path: String?
        func executablePath() -> String? { path }
    }

    private var successfulPreflight: CommandResult {
        CommandResult(exitCode: 0, standardOutput: Data("WORKJET_OS=Linux\nWORKJET_ARCH=aarch64\nWORKJET_HOME_WRITABLE=1\nWORKJET_SH=1\nWORKJET_NODE=v20.18.0\nWORKJET_NODE_PATH=/usr/bin/node\nWORKJET_SHA=sha256sum\nWORKJET_BWRAP=/usr/bin/bwrap\n".utf8))
    }

    private func sshComputer(bundle: String = "/audit/ctox-pi-sidecar.mjs") -> Computer {
        Computer(name: "pi", transport: .ssh, host: "pi.example.test", user: "workjet", port: 2222, sidecarBundlePath: bundle, knownHostsPath: "/private/workjet-known-hosts")
    }

    func testExactSSHArgumentsUseStrictPrivateKnownHostsAndNoUnsafeOption() throws {
        let computer = sshComputer()
        let command = try RemoteCommandBuilder.command(for: computer, tailscaleExecutable: nil, remoteExecutable: "/bin/sh", remoteArguments: ["-s", "--", String(repeating: "a", count: 64)], standardInput: Data("fixed".utf8), timeout: 20)
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertEqual(command.arguments, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\"/private/workjet-known-hosts\"", "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-p", "2222", "-l", "workjet", "--", "pi.example.test", "/bin/sh", "-s", "--", String(repeating: "a", count: 64)])
        XCTAssertFalse(command.arguments.contains { $0.contains("StrictHostKeyChecking=no") || $0.contains("accept-new") })
        XCTAssertFalse(command.arguments.contains("-c"))
    }

    func testSSHQuotesKnownHostsPathForOpenSSHConfigParser() throws {
        var computer = sshComputer()
        computer.knownHostsPath = "/Users/test/Library/Application Support/Workjet/ssh/known_hosts"

        let command = try RemoteCommandBuilder.command(
            for: computer,
            tailscaleExecutable: nil,
            remoteExecutable: "/usr/bin/true",
            remoteArguments: [],
            standardInput: Data(),
            timeout: 20
        )

        XCTAssertTrue(command.arguments.contains(
            "UserKnownHostsFile=\"/Users/test/Library/Application Support/Workjet/ssh/known_hosts\""
        ))
    }

    func testExplicitSSHIdentityIsUsedWithoutFallingBackToOtherKeys() throws {
        var computer = sshComputer()
        computer.identityFilePath = "/Users/test/.ssh/id_ed25519_workjet"

        let command = try RemoteCommandBuilder.command(
            for: computer,
            tailscaleExecutable: nil,
            remoteExecutable: "/usr/bin/true",
            remoteArguments: [],
            standardInput: Data(),
            timeout: 20
        )

        let identityIndex = try XCTUnwrap(command.arguments.firstIndex(of: "IdentitiesOnly=yes"))
        XCTAssertEqual(command.arguments[identityIndex - 1], "-o")
        XCTAssertEqual(command.arguments[identityIndex + 1], "-i")
        XCTAssertEqual(command.arguments[identityIndex + 2], "/Users/test/.ssh/id_ed25519_workjet")
    }

    func testRelativeSSHIdentityPathIsRejected() throws {
        var computer = sshComputer()
        computer.identityFilePath = ".ssh/id_ed25519"

        XCTAssertThrowsError(
            try RemoteCommandBuilder.command(
                for: computer,
                tailscaleExecutable: nil,
                remoteExecutable: "/usr/bin/true",
                remoteArguments: [],
                standardInput: Data(),
                timeout: 20
            )
        )
    }

    func testTailscaleMissingConfirmedHostKeyBlocksBeforeAnyNetworkCommand() async {
        let runner = Runner([])
        let files = Files()
        var computer = sshComputer(); computer.transport = .tailscale; computer.knownHostsPath = ""
        let result = await RemotePiBootstrap(runner: runner, files: files, tailscaleLocator: Locator(path: nil)).deploy(computer)
        XCTAssertEqual(result.deploymentStatus, .blocked)
        XCTAssertEqual(result.deploymentDetail, "Bestätige zuerst die Identität dieses Computers.")
        let commands = await runner.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testInvalidBundleSymlinkAndInjectedWrongOwnerAreRejected() async throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("bundle-real.mjs")
        try Data("audited".utf8).write(to: target)
        let link = root.appendingPathComponent("bundle-link.mjs")
        XCTAssertEqual(symlink(target.path, link.path), 0)
        let runner = Runner([])
        let linked = await RemotePiBootstrap(runner: runner, files: SecureOwnedFileReader(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer(bundle: link.path))
        XCTAssertEqual(linked.deploymentStatus, .failed)
        XCTAssertNil(linked.installedContentHash)

        let wrongOwnerFiles = Files(); wrongOwnerFiles.failure = LocalStateError.wrongOwner("/audit/ctox-pi-sidecar.mjs")
        let wrongOwner = await RemotePiBootstrap(runner: runner, files: wrongOwnerFiles, tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        XCTAssertEqual(wrongOwner.deploymentStatus, .failed)
        XCTAssertTrue(wrongOwner.deploymentDetail.contains("beschädigt"))

        let relative = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer(bundle: "relative-sidecar.mjs"))
        XCTAssertEqual(relative.deploymentStatus, .failed)
        XCTAssertTrue(relative.deploymentDetail.contains("beschädigt"))
    }

    func testNodePreflightFailureIsBlockedWithoutInstallingAnything() async {
        let unavailable = CommandResult(exitCode: 0, standardOutput: Data("WORKJET_OS=Linux\nWORKJET_ARCH=aarch64\nWORKJET_HOME_WRITABLE=1\nWORKJET_SH=1\nWORKJET_NODE=missing\nWORKJET_NODE_PATH=missing\nWORKJET_SHA=sha256sum\nWORKJET_BWRAP=/usr/bin/bwrap\n".utf8))
        let runner = Runner([unavailable])
        let result = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        XCTAssertEqual(result.deploymentStatus, .blocked)
        XCTAssertTrue(result.deploymentDetail.contains("JavaScript-Laufzeit"))
        XCTAssertFalse(result.deploymentDetail.contains("Node"))
        XCTAssertNil(result.lastSuccessfulPreflightAt)
        XCTAssertNil(result.installedContentHash)
        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 1)
    }

    func testSandboxEnabledPreflightBlocksWithoutBubblewrapAndDoesNotInstall() async {
        let noBubblewrap = CommandResult(exitCode: 0, standardOutput: Data("WORKJET_OS=Linux\nWORKJET_ARCH=aarch64\nWORKJET_HOME_WRITABLE=1\nWORKJET_SH=1\nWORKJET_NODE=v20.18.0\nWORKJET_NODE_PATH=/usr/bin/node\nWORKJET_SHA=sha256sum\nWORKJET_BWRAP=missing\n".utf8))
        let runner = Runner([noBubblewrap])
        let result = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        XCTAssertEqual(result.deploymentStatus, .blocked)
        XCTAssertTrue(result.deploymentDetail.contains("Minimal-Sandbox ist auf diesem Computer nicht verfügbar"))
        XCTAssertFalse(result.deploymentDetail.contains("bwrap"))
        XCTAssertTrue(result.deploymentDetail.contains("deaktiviere die Minimal-Sandbox"))
        XCTAssertNil(result.bubblewrapExecutablePath)
        XCTAssertNil(result.installedContentHash)
        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(String(decoding: commands[0].standardInput, as: UTF8.self).contains("WORKJET_BWRAP"))
    }

    func testGeneratedSandboxInvocationAndRunnerUseExactBubblewrapBoundary() async {
        let runner = Runner([successfulPreflight])
        let installed = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        XCTAssertEqual(installed.deploymentStatus, .installed)
        XCTAssertEqual(installed.bubblewrapExecutablePath, "/usr/bin/bwrap")

        var config = WorkjetDefaults.configuration()
        var worker = config.workers[0]
        worker.harness = .piSidecar
        worker.computerID = installed.id
        config.workers = [worker]
        config.computers.append(installed)
        let prompt = String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self)
        XCTAssertTrue(prompt.contains("workjet-pi-turn.mjs' '--sandbox'"))
        XCTAssertTrue(prompt.contains("aktiviert `--sandbox` ausdrücklich"))
        XCTAssertTrue(prompt.contains("projizierten In-Memory-Snapshot"))
        XCTAssertTrue(prompt.contains("read-only Host-Dateisystem"))

        let source = RemotePiBootstrap.turnRunnerSource
        for token in ["--die-with-parent", "--new-session", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--ro-bind", "--bind", "--proc", "--dev"] {
            XCTAssertTrue(source.contains("\"\(token)\""), "missing \(token)")
        }
        XCTAssertTrue(source.contains("daemon = spawn(sandboxExecutable, sandboxArguments"))
        XCTAssertFalse(source.contains("--unshare-net"))
        XCTAssertTrue(source.contains("no verified bubblewrap executable is recorded"))
    }

    func testSandboxDisabledInvocationIsExplicitlyUnsandboxed() async {
        var computer = sshComputer()
        computer.sandboxEnabled = false
        let runner = Runner([CommandResult(exitCode: 0, standardOutput: Data("WORKJET_OS=Linux\nWORKJET_ARCH=aarch64\nWORKJET_HOME_WRITABLE=1\nWORKJET_SH=1\nWORKJET_NODE=v20.18.0\nWORKJET_NODE_PATH=/usr/bin/node\nWORKJET_SHA=sha256sum\nWORKJET_BWRAP=missing\n".utf8))])
        let installed = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(computer)
        XCTAssertEqual(installed.deploymentStatus, .installed)
        XCTAssertNil(installed.bubblewrapExecutablePath)
        var config = WorkjetDefaults.configuration()
        var worker = config.workers[0]; worker.harness = .piSidecar; worker.computerID = installed.id
        config.workers = [worker]; config.computers.append(installed)
        let prompt = String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self)
        XCTAssertFalse(prompt.contains("workjet-pi-turn.mjs' '--sandbox'"))
        XCTAssertTrue(prompt.contains("OS-Sandbox ist deaktiviert"))
        XCTAssertTrue(prompt.contains("keine zusätzliche Betriebssystem-Dateisystemgrenze"))
    }

    func testSuccessfulContentAddressedDeploymentAndStatusRoundTrip() async throws {
        let runner = Runner([successfulPreflight])
        let files = Files(); files.values["/audit/ctox-pi-sidecar.mjs"] = Data("audited sidecar".utf8); files.values["/private/workjet-known-hosts"] = Data("host key".utf8)
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let installed = await RemotePiBootstrap(runner: runner, files: files, tailscaleLocator: Locator(path: nil), now: { date }).deploy(sshComputer())
        XCTAssertEqual(installed.deploymentStatus, .installed)
        XCTAssertEqual(installed.installedSidecarVersion, "0.80.2")
        XCTAssertEqual(installed.bubblewrapExecutablePath, "/usr/bin/bwrap")
        XCTAssertEqual(installed.installedContentHash?.count, 64)
        XCTAssertEqual(installed.lastSuccessfulPreflightAt, date)
        XCTAssertEqual(installed.lastSuccessfulDeploymentAt, date)

        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 6)
        XCTAssertTrue(commands.allSatisfy { $0.executable == "/usr/bin/ssh" })
        XCTAssertTrue(String(decoding: commands[1].standardInput, as: UTF8.self).contains("releases/$hash"))
        XCTAssertTrue(String(decoding: commands[5].standardInput, as: UTF8.self).contains("fs.renameSync(temporary, current)"))
        XCTAssertEqual(commands.filter { $0.arguments.contains("/usr/bin/node") }.count, 4)

        let root = try temporaryDirectory(); let store = JSONConfigurationStore(fileURL: root.appendingPathComponent("config.v1.json"))
        var config = WorkjetDefaults.configuration(); config.computers.append(installed); try store.save(config)
        XCTAssertEqual(try store.load()?.computers.last?.installedContentHash, installed.installedContentHash)
        XCTAssertEqual(try store.load()?.computers.last?.deploymentStatus, .installed)
    }

    func testRemoteFailureNeverMarksInstalledAndExplainsHostKeyApproval() async {
        let failure = CommandResult(exitCode: 255, standardError: Data("Host key verification failed".utf8))
        let runner = Runner([successfulPreflight, failure])
        let result = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        XCTAssertEqual(result.deploymentStatus, .failed)
        XCTAssertNil(result.installedContentHash)
        XCTAssertNil(result.installedSidecarVersion)
        XCTAssertTrue(result.deploymentDetail.contains("Identität dieses Computers"))
        XCTAssertFalse(result.deploymentDetail.localizedCaseInsensitiveContains("host key"))
        let commands = await runner.commands()
        XCTAssertFalse(commands.flatMap(\.arguments).contains { $0.contains("accept-new") || $0.contains("StrictHostKeyChecking=no") })
    }

    func testCredentialsNeverAppearInCommandsManifestPromptOrDeploymentPayload() async {
        let secret = "SUPER-SECRET-CREDENTIAL-VALUE"
        let runner = Runner([successfulPreflight])
        let files = Files(); files.values["/audit/ctox-pi-sidecar.mjs"] = Data("audited sidecar".utf8)
        let installed = await RemotePiBootstrap(runner: runner, files: files, tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        let commands = await runner.commands()
        let transcript = commands.map { $0.executable + $0.arguments.joined(separator: " ") + String(decoding: $0.standardInput, as: UTF8.self) }.joined(separator: "\n")
        XCTAssertFalse(transcript.contains(secret))

        let provider = Provider(name: "Direct", kind: .apiKey, endpoint: "https://user:\(secret)@api.example.test/v1?api_key=\(secret)", credentialReference: secret)
        var config = WorkjetDefaults.configuration(); config.providers = [provider]; config.workers[0].providerID = provider.id; config.workers[0].harness = .piSidecar; config.workers[0].computerID = installed.id; config.computers.append(installed)
        let prompt = String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self)
        XCTAssertFalse(prompt.contains(secret))
        XCTAssertTrue(prompt.contains("projizierten In-Memory-Snapshot"))
        XCTAssertTrue(prompt.contains("Loopback-Relay mit flüchtigem Gateway-Schlüssel"))
        XCTAssertTrue(prompt.contains("exklusivem Cursor"))
        XCTAssertTrue(prompt.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(prompt.contains("--sandbox"))
        XCTAssertTrue(RemotePiBootstrap.turnRunnerSource.contains("env: cleanEnvironment"))
        XCTAssertTrue(RemotePiBootstrap.turnRunnerSource.contains("spawn(sandboxExecutable"))
        XCTAssertFalse(RemotePiBootstrap.turnRunnerSource.contains("process.env.API"))
    }
}

final class ProcessCommandRunnerTests: XCTestCase {
    func testShortLivedProcessCannotOutrunTerminationObservation() async throws {
        for _ in 0..<20 {
            let started = Date()
            let result = try await ProcessCommandRunner().run(
                CommandSpec(executable: "/usr/bin/true", arguments: [], timeout: 0.5)
            )
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        }
    }

    func testEarlyChildExitDuringLargeStdinReturnsControlledFailureWithoutSIGPIPEOrHang() async {
        let payload = Data(repeating: 0x41, count: 16 * 1_024 * 1_024)
        let command = CommandSpec(executable: "/bin/sh", arguments: ["-c", "exit 0"], standardInput: payload, timeout: 2)
        let started = Date()
        do {
            _ = try await ProcessCommandRunner().run(command)
            XCTFail("Expected closed stdin to be reported")
        } catch {
            XCTAssertEqual(error as? CommandRunError, .standardInputClosed)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

@MainActor final class ViewModelTests: XCTestCase {
    private final class Service: WorkjetService, @unchecked Sendable {
        var saves: [(WorkjetConfiguration, Bool)] = []
        var saveError: Error?
        var failNextSave = false
        var runRecords: [RunRecord] = []
        var proxyStatus: CLIProxyStatus?
        var providerProbe = ProviderProbeResult(status: .unverified, detail: "test")
        var credentials: [String: Data] = [:]
        func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {
            if failNextSave {
                failNextSave = false
                throw LocalStateError.io("Einmaliger Testfehler")
            }
            if let saveError { throw saveError }
            saves.append((configuration, handwrittenRulesChanged))
        }
        func runs(workers: [Worker]) -> [RunRecord] { runRecords }
        func stop(_ run: ActiveRun) throws {}
        func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
            proxyStatus ?? CLIProxyStatus(endpoint: configuration.endpoint, state: .offline, detail: "test", capacity: .unavailable(reason: "test"))
        }
        func inspectProvider(_ provider: Provider) async -> ProviderProbeResult { providerProbe }
        func storeCredential(_ secret: Data, reference: String) throws { credentials[reference] = secret }
        func deleteCredential(reference: String) throws { credentials[reference] = nil }
        func hasCredential(reference: String) -> Bool { credentials[reference] != nil }
    }
    func testSelectionIsExclusiveAndDebouncedChangesCoalesceOnExplicitFlush() async {
        let service = Service(); let model = WorkjetViewModel(configuration: PreviewData.configuration(), service: service, persistenceDelay: 60); model.searchQuery = "Completion"; model.toggleComputerSelection(PreviewData.devbox.id); XCTAssertEqual(model.selectedComputerID, PreviewData.devbox.id); XCTAssertEqual(model.searchQuery, "Completion"); model.toggleComputerSelection(PreviewData.devbox.id); XCTAssertEqual(model.selectedComputerID, PreviewData.devbox.id)
        model.providerSlots = 2; model.telemetryRetentionDays = 30; model.cliProxyConfiguration.usageStatisticsEnabled = true; model.skillRules = "n"; model.skillRules = "new rules"; model.addProvider(Provider(name: "API", kind: .apiKey, endpoint: "https://example.test"))
        XCTAssertTrue(service.saves.isEmpty)
        await model.flushPersistence()
        XCTAssertEqual(service.saves.count, 1)
        XCTAssertEqual(service.saves.first?.1, true)
        XCTAssertEqual(service.saves.first?.0.skillRules, "new rules")
        XCTAssertEqual(service.saves.first?.0.providers.count, 2)
        guard case .synchronized = model.promptSyncStatus else { return XCTFail("Expected synchronized prompt") }
        XCTAssertFalse(model.claudeRestartRequired)
        XCTAssertEqual(model.runtimeStatus, .attention)
        XCTAssertEqual(model.runtimeSubtitle, "Computer nicht vollständig eingerichtet")
        XCTAssertNotEqual(model.runtimeSubtitle, "Claude neu starten, um Änderungen zu laden")
    }

    func testPromptSyncFailureIsPersistentHealthStateAndFlushReportsFailure() async {
        let service = Service()
        service.saveError = LocalStateError.io("Prompt nicht schreibbar")
        let model = WorkjetViewModel(configuration: PreviewData.configuration(), service: service, persistenceDelay: 60)
        model.skillRules = "changed"
        XCTAssertEqual(model.promptSyncStatus, .pending)
        let saved = await model.flushPersistence()
        XCTAssertFalse(saved)
        guard case let .failed(message) = model.promptSyncStatus else { return XCTFail("Expected failed prompt sync") }
        XCTAssertEqual(message, "Eine Workjet-Datei konnte nicht gelesen oder gespeichert werden.")
        XCTAssertEqual(model.runtimeStatus, .attention)
        XCTAssertEqual(model.runtimeSubtitle, "Änderungen konnten nicht übernommen werden")
        XCTAssertFalse(model.claudeRestartRequired)
    }

    func testPriorPersistenceFailureDoesNotTrapNoOpCloseBehindAnEmptyFlush() async {
        let service = Service()
        service.saveError = LocalStateError.io("Prompt nicht schreibbar")
        let model = WorkjetViewModel(configuration: PreviewData.configuration(), service: service, persistenceDelay: 60)
        model.skillRules = "changed"

        let failedSave = await model.flushPersistence()
        XCTAssertFalse(failedSave)
        service.saveError = nil

        let emptyFlush = await model.flushPersistence()
        XCTAssertTrue(emptyFlush, "Ein leerer Flush darf einen Schließen-Button nicht wegen eines früheren Fehlers blockieren.")
        guard case .failed = model.promptSyncStatus else {
            return XCTFail("Der frühere Fehler muss weiterhin sichtbar bleiben, bis er behoben oder verworfen wird.")
        }
    }

    func testConfigurationOnlySaveDoesNotClaimClaudeRestartIsRequired() async {
        let service = Service()
        let model = WorkjetViewModel(configuration: PreviewData.configuration(), service: service, persistenceDelay: 60)

        model.telemetryClaudeCodeEvents.toggle()
        let saved = await model.flushPersistence()

        XCTAssertTrue(saved)
        XCTAssertFalse(model.claudeRestartRequired)
    }

    func testBackgroundProviderObservationUpdatesUIWithoutSchedulingPersistence() async {
        let service = Service()
        service.providerProbe = ProviderProbeResult(
            status: .connected,
            detail: "Live beobachtet",
            modelIDs: ["observed-model"],
            capacity: .unavailable(reason: "Nicht gemessen")
        )
        var configuration = PreviewData.configuration()
        configuration.providers = [
            Provider(
                name: "Beobachteter Anbieter",
                kind: .directAPI,
                endpoint: "https://example.test",
                authentication: .none,
                status: .unverified,
                statusDetail: "Noch nicht geprüft"
            )
        ]
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)
        let promptStatusBefore = model.promptSyncStatus

        await model.refreshProvidersNow()

        XCTAssertEqual(model.providers.first?.status, .connected)
        XCTAssertEqual(model.providers.first?.statusDetail, "Live beobachtet")
        XCTAssertEqual(model.providers.first?.modelIDs, ["observed-model"])
        XCTAssertEqual(model.promptSyncStatus, promptStatusBefore)
        XCTAssertTrue(service.saves.isEmpty)
        let flushed = await model.flushPersistence()
        XCTAssertTrue(flushed)
        XCTAssertTrue(service.saves.isEmpty)
        XCTAssertTrue(model.statusMessages.isEmpty)
    }

    func testAdHocLearningParticipatesInPromptSyncStateAndExplicitFlush() async {
        let service = Service()
        let model = WorkjetViewModel(configuration: PreviewData.configuration(), service: service, persistenceDelay: 60)

        model.adHocLearnings = "Persistent orchestration learning"
        XCTAssertEqual(model.promptSyncStatus, .pending)
        let saved = await model.flushPersistence()
        XCTAssertTrue(saved)

        guard case .synchronized = model.promptSyncStatus else {
            return XCTFail("Ad-hoc learning must finish as a synchronized prompt change")
        }
        XCTAssertFalse(model.claudeRestartRequired)
    }

    func testRemovingRemoteComputerMovesItsWorkersToLocal() async {
        var configuration = PreviewData.configuration()
        let remote = PreviewData.devbox
        configuration.selectedComputerID = remote.id
        configuration.workers[0].computerID = remote.id
        let model = WorkjetViewModel(configuration: configuration, persistenceDelay: 60)
        model.removeComputer(id: remote.id)
        XCTAssertFalse(model.computers.contains(where: { $0.id == remote.id }))
        XCTAssertEqual(model.selectedComputerID, WorkjetDefaults.localID)
        XCTAssertEqual(model.workers[0].computerID, WorkjetDefaults.localID)
    }

    func testDurableWorkerSaveRollsBackExactConfigurationAndCanBeRetried() async throws {
        let service = Service()
        let model = WorkjetViewModel(configuration: WorkjetDefaults.configuration(), service: service, persistenceDelay: 60)
        let snapshot = model.configuration
        var edited = try XCTUnwrap(snapshot.workers.first)
        edited.name = "Transactional Worker"
        edited.instructions = "Persist only after the complete configuration is durable."
        service.failNextSave = true

        let failed = await model.saveWorkerDurably(edited)

        guard case let .failed(message) = failed else { return XCTFail("Expected worker save failure") }
        XCTAssertTrue(message.contains("vorherige Konfiguration wurde wiederhergestellt"))
        XCTAssertEqual(model.configuration, snapshot)
        XCTAssertEqual(service.saves.last?.0, snapshot, "Der wiederhergestellte Snapshot muss selbst erneut gespeichert werden.")

        let retried = await model.saveWorkerDurably(edited)

        XCTAssertEqual(retried, .succeeded)
        XCTAssertEqual(model.workers.first(where: { $0.id == edited.id }), edited)
        XCTAssertEqual(service.saves.last?.0, model.configuration)
    }

    func testDurableComputerSaveRollsBackExactConfigurationAndCanBeRetried() async throws {
        let service = Service()
        let model = WorkjetViewModel(configuration: PreviewData.configuration(), service: service, persistenceDelay: 60)
        let snapshot = model.configuration
        var edited = try XCTUnwrap(snapshot.computers.first(where: { !$0.isLocal }))
        edited.name = "Transactional Devbox"
        edited.host = "transactional-devbox.tailnet.test"
        service.failNextSave = true

        let failed = await model.saveComputerDurably(edited)

        guard case let .failed(message) = failed else { return XCTFail("Expected computer save failure") }
        XCTAssertTrue(message.contains("vorherige Konfiguration wurde wiederhergestellt"))
        XCTAssertEqual(model.configuration, snapshot)
        XCTAssertEqual(service.saves.last?.0, snapshot, "Der wiederhergestellte Snapshot muss selbst erneut gespeichert werden.")

        let retried = await model.saveComputerDurably(edited)

        XCTAssertEqual(retried, .succeeded)
        XCTAssertEqual(model.computers.first(where: { $0.id == edited.id }), edited)
        XCTAssertEqual(service.saves.last?.0, model.configuration)
    }

    func testDurableComputerDeleteRollsBackWorkersComputersAndSelectionAndCanBeRetried() async {
        var configuration = PreviewData.configuration()
        let remote = PreviewData.devbox
        configuration.selectedComputerID = remote.id
        configuration.workers[0].computerID = remote.id
        let service = Service()
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)
        let snapshot = model.configuration
        service.failNextSave = true

        let failed = await model.deleteComputerDurably(id: remote.id)

        guard case let .failed(message) = failed else { return XCTFail("Expected computer deletion failure") }
        XCTAssertTrue(message.contains("vorherige Konfiguration wurde wiederhergestellt"))
        XCTAssertEqual(model.workers, snapshot.workers)
        XCTAssertEqual(model.computers, snapshot.computers)
        XCTAssertEqual(model.selectedComputerID, snapshot.selectedComputerID)
        XCTAssertEqual(model.configuration, snapshot)
        XCTAssertEqual(service.saves.last?.0, snapshot, "Der wiederhergestellte Snapshot muss selbst erneut gespeichert werden.")

        let retried = await model.deleteComputerDurably(id: remote.id)

        XCTAssertEqual(retried, .succeeded)
        XCTAssertFalse(model.computers.contains(where: { $0.id == remote.id }))
        XCTAssertEqual(model.selectedComputerID, WorkjetDefaults.localID)
        XCTAssertTrue(model.workers.allSatisfy { $0.computerID != remote.id })
        XCTAssertEqual(service.saves.last?.0, model.configuration)
    }

    func testDeletingWorkerDurablyRemovesOnlyThatWorkerAndKeepsSharedModelRulesAndRunHistory() async {
        var configuration = WorkjetDefaults.configuration()
        let deleted = configuration.workers[0]
        configuration.workers[1].model = deleted.model
        let canonicalModel = ModelPromptCatalog.canonicalName(for: deleted.model)
        configuration.modelPrompts?[canonicalModel] = "Shared rule that must survive."
        let historical = RunRecord(sourceRunID: "historical-run", state: .completed)
        let service = Service()
        service.runRecords = [historical]
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)

        let result = await model.deleteWorker(id: deleted.id)

        XCTAssertEqual(result, .deleted)
        XCTAssertFalse(model.workers.contains(where: { $0.id == deleted.id }))
        XCTAssertEqual(model.modelPrompts[canonicalModel], "Shared rule that must survive.")
        XCTAssertEqual(service.runRecords, [historical], "Worker-Löschung darf historische Läufe nicht verändern.")
        let saved = try! XCTUnwrap(service.saves.last?.0)
        XCTAssertFalse(saved.workers.contains(where: { $0.id == deleted.id }))
        XCTAssertEqual(saved.modelPrompts?[canonicalModel], "Shared rule that must survive.")
        let prompt = String(decoding: ManagedPrompt.workerBody(configuration: saved), as: UTF8.self)
        XCTAssertFalse(prompt.contains(deleted.id.uuidString.lowercased()))
        XCTAssertFalse(prompt.contains("WORKJET WORKER INSTRUCTIONS BEGIN \(deleted.mentionTag)"))
        XCTAssertTrue(prompt.contains(configuration.workers[1].id.uuidString.lowercased()))
        XCTAssertEqual(prompt.components(separatedBy: "Shared rule that must survive.").count - 1, 1)
    }

    func testDeletingWorkerRollsBackVisibleAndDurableConfigurationWhenPersistenceFails() async {
        let configuration = WorkjetDefaults.configuration()
        let deleted = configuration.workers[0]
        let service = Service()
        service.failNextSave = true
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)

        let result = await model.deleteWorker(id: deleted.id)

        guard case let .failed(message) = result else { return XCTFail("Expected deletion failure") }
        XCTAssertTrue(message.contains("nicht gelöscht"))
        XCTAssertEqual(model.workers, configuration.workers)
        XCTAssertEqual(model.modelPrompts, configuration.modelPrompts ?? [:])
        XCTAssertTrue(model.statusMessages.contains(message))
        XCTAssertEqual(service.saves.last?.0.workers, configuration.workers,
                       "Nach einem fehlgeschlagenen Lösch-Flush muss die Wiederherstellung selbst durable gespeichert werden.")
    }

    func testDeletingActiveWorkerIsBlockedWithoutStoppingOrMutatingIt() async throws {
        let configuration = WorkjetDefaults.configuration()
        let worker = configuration.workers[0]
        let service = Service()
        service.runRecords = [RunRecord(sourceRunID: "active", state: .running, activeRun: activeRun(worker: worker, activity: "läuft", delivery: .live, pid: 411))]
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)
        model.refreshRuns()
        for _ in 0..<50 where model.activeRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = await model.deleteWorker(id: worker.id)

        guard case let .blocked(message) = result else { return XCTFail("Expected active worker deletion to be blocked") }
        XCTAssertTrue(message.contains("Stoppe den Worker zuerst"))
        XCTAssertTrue(model.workers.contains(where: { $0.id == worker.id }))
        XCTAssertEqual(service.runRecords.first?.state, .running, "Löschen darf einen aktiven Run nicht automatisch stoppen.")
        XCTAssertTrue(service.saves.isEmpty)
    }

    func testRuntimeSubtitleCountsExecutionsRatherThanClaimingDistinctWorkers() async throws {
        var configuration = WorkjetDefaults.configuration()
        let provider = Provider(
            name: "Verbunden",
            kind: .directAPI,
            endpoint: "https://example.test",
            authentication: .none,
            status: .connected,
            statusDetail: "Verbunden"
        )
        configuration.providers = [provider]
        for index in configuration.workers.indices {
            configuration.workers[index].providerRoute = .account(provider.id)
        }
        let worker = configuration.workers[0]
        let service = Service()
        service.runRecords = [
            RunRecord(sourceRunID: "first", state: .running, activeRun: activeRun(worker: worker, activity: "läuft", delivery: .live, pid: 501)),
            RunRecord(sourceRunID: "second", state: .running, activeRun: activeRun(worker: worker, activity: "läuft", delivery: .live, pid: 502))
        ]
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)
        model.telemetryRetentionDays += 1
        let synchronized = await model.flushPersistence()
        XCTAssertTrue(synchronized)

        model.refreshRuns()
        for _ in 0..<50 where model.activeRuns.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.activeRuns.count, 2)
        XCTAssertEqual(model.runtimeSubtitle, "2 Ausführungen aktiv")
    }

    func testTelemetryDefaultsAndMaskingKeepAutomaticActiveRuns() {
        let defaults = WorkjetDefaults.configuration()
        let model = WorkjetViewModel(configuration: defaults, service: Service(), persistenceDelay: 60)
        XCTAssertTrue(model.telemetryClaudeCodeEvents)
        XCTAssertTrue(model.telemetrySidecarEvents)
        XCTAssertFalse(Computer(name: "remote", transport: .ssh).telemetryEnabled)

        let localClaude = defaults.workers[0]
        let remoteComputer = Computer(name: "pi", transport: .ssh, telemetryEnabled: false)
        var remotePi = defaults.workers[1]
        remotePi.harness = .piSidecar
        remotePi.computerID = remoteComputer.id
        let claudeRun = activeRun(worker: localClaude, activity: "Claude liest Dateien", delivery: .live, pid: 300)
        let piRun = activeRun(worker: remotePi, activity: "Pi bearbeitet Snapshot", delivery: .postHoc, pid: 301)

        let claudeMasked = WorkjetViewModel.applyingTelemetryPolicy(to: [claudeRun], workers: [localClaude], computers: defaults.computers, claudeEventsEnabled: false, sidecarEventsEnabled: true)
        XCTAssertEqual(claudeMasked.count, 1)
        XCTAssertEqual(claudeMasked[0].activity, "läuft")
        XCTAssertEqual(claudeMasked[0].delivery, .unavailable)

        let remoteMasked = WorkjetViewModel.applyingTelemetryPolicy(to: [piRun], workers: [remotePi], computers: [remoteComputer], claudeEventsEnabled: true, sidecarEventsEnabled: true)
        XCTAssertEqual(remoteMasked.count, 1)
        XCTAssertEqual(remoteMasked[0].activity, "läuft")
        XCTAssertEqual(remoteMasked[0].delivery, .unavailable)

        var enabledComputer = remoteComputer; enabledComputer.telemetryEnabled = true
        let remoteVisible = WorkjetViewModel.applyingTelemetryPolicy(to: [piRun], workers: [remotePi], computers: [enabledComputer], claudeEventsEnabled: true, sidecarEventsEnabled: true)
        XCTAssertEqual(remoteVisible[0].activity, "Pi bearbeitet Snapshot")
        XCTAssertEqual(remoteVisible[0].delivery, .postHoc)

        let piGloballyMasked = WorkjetViewModel.applyingTelemetryPolicy(to: [piRun], workers: [remotePi], computers: [enabledComputer], claudeEventsEnabled: true, sidecarEventsEnabled: false)
        XCTAssertEqual(piGloballyMasked[0].activity, "läuft")
        XCTAssertEqual(piGloballyMasked[0].delivery, .unavailable)
    }

    func testRunRefreshAppliesConfiguredTelemetryRetention() async throws {
        let root = try temporaryDirectory()
        let paths = WorkjetPaths(homeDirectory: root, stateDirectory: root.appendingPathComponent("state"))
        try FileManager.default.createDirectory(at: paths.runsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.runIndexDirectory, withIntermediateDirectories: true)
        let run = paths.runsDirectory.appendingPathComponent("expired")
        let index = paths.runIndexDirectory.appendingPathComponent("expired")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try Data((run.path + "\n").utf8).write(to: index)
        try Data("999999\n".utf8).write(to: run.appendingPathComponent("pid"))
        try Data("0\n".utf8).write(to: run.appendingPathComponent("exit-code"))
        let oldDate = Date(timeIntervalSince1970: 1_000)
        for path in [run.appendingPathComponent("pid"), run.appendingPathComponent("exit-code"), run, index] {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path.path)
        }
        var configuration = WorkjetDefaults.configuration()
        configuration.telemetryRetentionDays = 30
        let maintenance = RunTelemetryStore(
            paths: paths,
            now: { Date(timeIntervalSince1970: 10_000_000) }
        )
        let model = WorkjetViewModel(
            configuration: configuration,
            service: Service(),
            persistenceDelay: 60,
            telemetryMaintenance: maintenance
        )

        model.refreshRuns()
        for _ in 0..<50 where FileManager.default.fileExists(atPath: run.path) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: run.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
    }

    func testProviderConnectionTestStoresSecretModelsAndStatus() async {
        var config = WorkjetDefaults.configuration()
        let provider = Provider(name: "CLI", kind: .cliProxyAPI, endpoint: "http://127.0.0.1:8317")
        config.providers = [provider]
        config.workers[0].providerID = provider.id
        let service = Service()
        service.providerProbe = ProviderProbeResult(status: .connected, detail: "verbunden", modelIDs: ["gateway-model"])
        let model = WorkjetViewModel(configuration: config, service: service, persistenceDelay: 60)
        await model.testProvider(id: provider.id, secret: "secret")
        let updated = try! XCTUnwrap(model.providers.first)
        XCTAssertEqual(updated.status, .connected)
        XCTAssertEqual(updated.statusDetail, "verbunden")
        XCTAssertEqual(updated.modelIDs, ["gateway-model"])
        XCTAssertEqual(service.credentials[Provider.credentialReference(for: provider.id)], Data("secret".utf8))
        XCTAssertTrue(model.providerAccessStored.contains(provider.id))
        XCTAssertEqual(model.providerPresentation(for: updated).tone, .neutral)
        XCTAssertEqual(WorkerModelSuggestions.values(providerID: provider.id, providers: model.providers).first, "gateway-model")
        let deletion = await model.deleteProviderDurably(id: provider.id)
        XCTAssertEqual(deletion, .deleted)
        XCTAssertTrue(model.providers.isEmpty)
        XCTAssertNil(service.credentials[Provider.credentialReference(for: provider.id)])
    }

    func testProviderWithoutAuthenticationDoesNotStoreSecretAndSharedLegacySecretIsPreserved() async {
        var config = WorkjetDefaults.configuration()
        let noAuth = Provider(name: "Public", kind: .directAPI, endpoint: "https://example.test", authentication: .none)
        let shared = Provider(name: "Legacy", kind: .cliProxyAPI, endpoint: "http://127.0.0.1:8317", credentialReference: "shared-key")
        config.providers = [noAuth, shared]
        let service = Service()
        service.credentials["shared-key"] = Data("keep".utf8)
        let model = WorkjetViewModel(configuration: config, service: service, persistenceDelay: 60)

        await model.testProvider(id: noAuth.id, secret: "must-not-store")
        XCTAssertNil(service.credentials[Provider.credentialReference(for: noAuth.id)])
        model.cliProxyConfiguration.inferenceCredentialReference = "shared-key"
        let deletion = await model.deleteProviderDurably(id: shared.id)
        XCTAssertEqual(deletion, .deleted)
        XCTAssertEqual(service.credentials["shared-key"], Data("keep".utf8))
    }

    func testUnprobedProviderDefaultsToNeutralInsteadOfOffline() {
        let provider = Provider(name: "New", kind: .apiKey, endpoint: "https://example.test")
        XCTAssertEqual(provider.status, .unverified)
        let model = WorkjetViewModel(configuration: WorkjetDefaults.configuration(), service: Service(), persistenceDelay: 60)
        let presentation = model.providerPresentation(for: provider)
        XCTAssertEqual(presentation.state, "Zugang fehlt")
        XCTAssertEqual(presentation.tone, .neutral)
        XCTAssertNil(presentation.capacity.fraction)
    }

    private func activeRun(worker: Worker, activity: String, delivery: HarnessDelivery, pid: Int32) -> ActiveRun {
        ActiveRun(
            sourceRunID: "run-\(pid)",
            workerID: worker.id,
            workerName: worker.name,
            workerModel: worker.model,
            activity: activity,
            startedAt: Date(timeIntervalSince1970: 1_000),
            observedAt: Date(timeIntervalSince1970: 1_100),
            lastHeartbeat: Date(timeIntervalSince1970: 1_090),
            delivery: delivery,
            pid: pid,
            processIdentity: ProcessIdentity(pid: pid, executablePath: "/usr/bin/worker", startToken: "start-\(pid)"),
            runDirectory: URL(fileURLWithPath: "/tmp/run-\(pid)"),
            indexFile: nil
        )
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkjetTests-\(UUID().uuidString)", isDirectory: true); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
}
