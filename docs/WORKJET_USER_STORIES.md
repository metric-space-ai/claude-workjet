# Workjet release user stories and acceptance specification

Status: normative release contract. This document describes required behavior; it does **not** claim that the current build implements it.

Current implementation and test coverage are audited separately in
[`WORKJET_RELEASE_GAPS.md`](WORKJET_RELEASE_GAPS.md). The audit status is
evidence-based and never changes the normative acceptance criteria below.

## 1. Product boundary and test doctrine

Workjet is a native macOS menu-bar companion for a global Claude Code and Claude Desktop system-prompt extension. The installer adds one marked `@workjet/AGENTS.md` include to the user's global `~/.claude/CLAUDE.md`; no opt-in command is required. Claude/Fable remains the orchestrator. The app manages the visible orchestration rules, worker definitions, provider access, computers, runtime health, and telemetry. It is not a second orchestrator and must not invent workflows or silently choose workers.

Every release candidate is accepted against the stories below using the real production views and real persisted configuration. A Core test may prove data transformation, but it cannot substitute for a click test where the acceptance criterion concerns navigation, focus, labels, visibility, or editor identity. A mocked remote test may prove protocol behavior, but it cannot substitute for the named real-remote smoke test. No alternate UI hierarchy may exist solely for tests.

### 1.1 Required test levels

- **Core integration:** deterministic Swift or shell tests using production persistence, prompt composition, routing, protocol, and telemetry code with isolated temporary state.
- **UI click:** `XCUIApplication` launches the real `Workjet.app` with a temporary configuration and telemetry root. Stable accessibility identifiers use persistent UUIDs, never row indexes or visible labels alone.
- **Real remote smoke:** a disposable or explicitly designated Tailscale/SSH host executes the production bootstrap, harness, event, reconnect, and stop paths. No fake success payload is acceptable.
- **Manual security:** a human verifies macOS Keychain, OAuth, signing, permissions, install/update, and destructive confirmations where automation would weaken or bypass the security boundary.

### 1.2 Cross-story invariants

1. `Local` always exists. Every additional computer is a directly clickable peer button; there is no computer dropdown.
2. A worker is identified by its UUID. Name, model, row order, computer, or active process label never substitutes for identity.
3. Every editable prompt byte is visible somewhere in Settings. No hidden policy or technical prompt is appended at runtime.
4. General rules, model rules, worker instructions, ad-hoc learnings, and technical rules have one source each. The composed prompt may show all of them, but editing writes back only to that source.
5. Provider product, provider account, provider pool, model, harness, and computer are distinct concepts and remain distinct in persistence and UI.
6. An unavailable dependency produces an explicit visible state and recovery action. It never silently falls back, reports a fake success, or deletes the user's editable configuration.
7. Save closes an editor only after configuration and managed prompt are durably synchronized. A failed save stays open and explains the exact field or persistence failure.
8. Telemetry is evidence, not inference from an old file or process name. Stale sessions expire and cannot remain “active” indefinitely.
9. Global activation owns only its clearly marked include in `~/.claude/CLAUDE.md`. Install, update, and uninstall preserve all unrelated global content and never modify project-local `CLAUDE.md` or `AGENTS.md` files.

### 1.3 Release-wide fixtures

The UI suite must provide deterministic fixtures containing: Local plus two remote computers; four named workers; one active worker and one stale run; a missing provider account; two accounts for one provider; one provider pool; model rules for Sol, Kimi, MiniMax, and Grok; general/technical/ad-hoc text with unique sentinels; measured, rate-limited, and unavailable capacities. Secrets are synthetic and stored in a temporary credential backend used only to replace storage, never the views.

## 2. App shell, launch, and global status

### WJ-APP-001 - Launch and reopen the actual Workjet menu

- **Persona / goal:** A Claude Code user wants one reliable click target in the macOS menu bar.
- **Preconditions:** Workjet is installed in `/Applications`; no Workjet process runs; another status item with a popover is adjacent.
- **Steps:** Launch Workjet from Finder; click the Workjet turbine status item; close the popover; click the same item again; quit and relaunch.
- **Expected visible states:** Exactly one Workjet status item appears. Its icon is recognizably a turbine/engine intake at menu-bar size, not a paper plane, letter, gear, sparkle, or generic play button. Clicking it always opens the Workjet popover headed “Workjet”; it never opens the neighbor's “No Active Sessions” panel. Reopening preserves the last selected computer.
- **Persistence / prompt / runtime effect:** Launch is read-only except for normal telemetry refresh; it does not rewrite prompt or configuration merely by opening.
- **Errors / recovery:** Corrupt configuration opens a usable error state with “Konfiguration konnte nicht geladen werden” and a non-destructive recovery path. It must not crash or replace data with defaults.
- **Automation:** UI click; manual visual brand check; signed-app launch smoke.
- **Done:** Five launch/open/close cycles and an adjacent-item test pass on a clean macOS account; process inspection shows exactly one status item owner.

### WJ-APP-002 - At-a-glance Workjet activation state

- **Persona / goal:** The user wants to know whether the global Workjet prompt extension is installed and functioning in Claude without opening logs.
- **Preconditions:** Fixture states: not observed, ready, one active orchestration, degraded synchronization, fatal/unavailable.
- **Steps:** Start each fixture/state; observe the icon; open the popover.
- **Expected visible states:** Icon treatment and header status agree. The header uses concise language such as “Bereit”, “Aktiv · 1”, “Nicht bestätigt”, or “Fehler”, with a short reason on hover/details. “Active” is shown only from current, attributable runtime evidence.
- **Persistence / prompt / runtime effect:** Status changes do not mutate worker/prompt configuration.
- **Errors / recovery:** If Claude runtime telemetry is unavailable, show “Nicht bestätigt” rather than “Aus” or “Aktiv”. A synchronization failure links to the affected Settings section.
- **Automation:** Core integration + UI click + real local Claude smoke.
- **Done:** A matrix test proves icon/header consistency and no false positive after the Claude process exits.

### WJ-APP-003 - No unsolicited Keychain or OAuth dialogs on launch

- **Persona / goal:** A user wants to inspect Workjet without security prompts appearing every time.
- **Preconditions:** Accounts exist in Keychain; the keychain is locked in one run and available in another.
- **Steps:** Launch and open Workjet; switch computers; open Settings/Prompt; do not enter Providers or start a worker.
- **Expected visible states:** No Keychain password dialog and no browser OAuth window appears. Credential access is lazy and tied to an explicit “Verbinden”, “Neu anmelden”, capacity refresh, or execution action.
- **Persistence / prompt / runtime effect:** None.
- **Errors / recovery:** When explicit credential use is denied, the relevant account shows “Zugriff nicht erlaubt” with “Erneut versuchen”; unrelated UI remains usable.
- **Automation:** Manual security + UI click around non-credential flows.
- **Done:** Launch/navigation produces zero credential API reads in an instrumented test and zero system dialogs manually.

## 3. Main list and worker identity/status

### WJ-MAIN-001 - Direct computer switching without dropdowns

- **Persona / goal:** A user wants to switch between Local and any number of configured computers in one click.
- **Preconditions:** Local and at least three remote computers exist; each has distinct workers.
- **Steps:** Open Workjet; click each computer button in arbitrary order; return to Local.
- **Expected visible states:** All computer buttons are visible in a horizontally scrollable peer control plus a separate `+`. The selected computer is unmistakable. The worker list changes immediately and contains only workers assigned to that computer. No dropdown, hidden menu, or intermediate chooser is used.
- **Persistence / prompt / runtime effect:** Selected computer may persist as UI preference; assignments and prompt do not change.
- **Errors / recovery:** An offline computer remains selectable and shows offline state without erasing its workers.
- **Automation:** UI click.
- **Done:** Accessibility assertions prove selection and exact worker UUID set after each click.

### WJ-MAIN-002 - Every worker row shows its own operational status

- **Persona / goal:** The user wants to see whether each configured worker can actually run.
- **Preconditions:** Workers representing ready, active, unverified, degraded, unavailable/missing provider, offline computer, unsupported harness, and rate-limited states.
- **Steps:** Select the relevant computer; inspect every row; hover or invoke accessibility description.
- **Expected visible states:** Every row includes one compact status dot/label beside model/harness. Labels are worker-specific: “Bereit”, “Läuft”, “Nicht geprüft”, “Eingeschränkt”, or “Nicht verfügbar”. Detail names the cause, e.g. missing access route, offline target, unsupported live runtime, failed probe, or rate limit. A global warning never replaces row states.
- **Persistence / prompt / runtime effect:** Read-only; status is keyed by worker UUID.
- **Errors / recovery:** Unknown telemetry is “Nicht geprüft”, never “Bereit”. An expired probe changes state without losing configuration.
- **Automation:** Core integration + UI click + real local and remote smoke.
- **Done:** Tests assert a nonempty accessibility status for every row and show no state leakage between workers sharing a model or name.

### WJ-MAIN-003 - Compact quota and rate next to the model

- **Persona / goal:** The user wants quota and rate-limit awareness without opening Settings.
- **Preconditions:** Measured normal, warning, critical/rate-limited, aggregate pool, and unavailable data.
- **Steps:** Open main list; inspect `Q` and `R` on each worker; open the capacity detail.
- **Expected visible states:** Compact values appear next to model/harness, not as task progress bars. Measured percentages/limits use restrained severity colors; unknown is ` - ` with an explicit reason. Pool capacity is labelled as pool data and never fabricated from incompatible accounts.
- **Persistence / prompt / runtime effect:** Refresh updates observation cache only.
- **Errors / recovery:** Failed capacity fetch retains last-known value only with timestamp and “veraltet”; otherwise unknown. No infinite spinner.
- **Automation:** Core integration + UI click + provider smoke where supported.
- **Done:** Fixture matrix renders exact values/reasons and stale transition; no static placeholder passes as measured data.

### WJ-MAIN-004 - Active runs map to configured workers and expire safely

- **Persona / goal:** The user wants concise current activity, without ghosts or “Unbekannter Worker” when identity is available.
- **Preconditions:** One direct wrapper run, one dispatcher run, one remote run, a legacy unmapped executable, and a 48-hour stale journal.
- **Steps:** Start runs; open Workjet; stop/complete each; wait through heartbeat expiry.
- **Expected visible states:** Active area shows configured worker name, elapsed time, concise current activity, computer, and stop button. It deduplicates observer/dispatcher evidence. Legacy unmapped run is clearly marked with its executable and a remediation link; stale journal is not active.
- **Persistence / prompt / runtime effect:** Runtime ledger updates; configuration/prompt unchanged.
- **Errors / recovery:** Lost heartbeat becomes “Verbindung verloren” then terminal/stale after bounded timeout. A malformed journal is reported in Telemetry, not shown forever as running.
- **Automation:** Core integration + UI click + real local/remote smoke.
- **Done:** Start/event/stop/restart tests prove UUID attribution, deduplication, and stale eviction; storage cannot grow unbounded from ghosts.

## 4. Worker create, edit, move, and delete

### WJ-WRK-001 - Create a complete worker through progressive disclosure

- **Persona / goal:** A non-expert wants to add a named role without technical invocation jargon.
- **Preconditions:** At least one connected provider route and Local exist.
- **Steps:** Click the worker-list `+`; enter name; choose harness, provider/account or pool, model, supported reasoning and optional speed; enter “Aufgabe dieses Workers”; choose computer; save.
- **Expected visible states:** The primary form shows only these user concepts. Technical invocation details are collapsed. Save succeeds only when required fields are complete and the new row appears under the chosen computer with status.
- **Persistence / prompt / runtime effect:** New stable worker UUID persists; worker instructions and model block appear once in the managed prompt; configuration and managed prompt synchronize before editor closes.
- **Errors / recovery:** Save on an incomplete form focuses the first invalid field, outlines it, and shows plain-language guidance. Entered values remain. Persistence/prompt failure stays in editor with retry.
- **Automation:** Core integration + UI click.
- **Done:** Create, relaunch, reopen editor, and byte-check composed prompt all pass.

### WJ-WRK-002 - Pencil edits the exact worker and all of its saved fields

- **Persona / goal:** The user clicks a row pencil and expects that exact worker, not a template or another same-named worker.
- **Preconditions:** Two workers share name/model but have different UUIDs, harness options, provider routes, instructions, computers, and invocation details.
- **Steps:** Click the pencil on the first row; compare fields; close; click the second; change nothing and save; reopen both.
- **Expected visible states:** Title is “Worker bearbeiten”. Name, harness, concrete account/pool, model, reasoning, speed/options, the single worker-specific task, computer, and technical invocation match the clicked UUID. Shared model rules are not duplicated in this editor. Saving unchanged never creates a new UUID.
- **Persistence / prompt / runtime effect:** Only the targeted record may change; prompt ordering/source remains stable.
- **Errors / recovery:** If its provider was deleted, all model/rules/instructions remain visible and editable with an inline route error.
- **Automation:** Core integration + UI click.
- **Done:** UUID-keyed accessibility actions and before/after persistence assertions prove exact routing; this is not accepted by a Core-only draft test.

### WJ-WRK-003 - Edit worker instructions as the worker-specific prompt source

- **Persona / goal:** The user wants a substantial role description, including `@Other-Worker` references.
- **Preconditions:** Several workers with stable mention tags.
- **Steps:** Open worker; click text area; paste multiline Markdown; add known and unknown tags; save and reopen.
- **Expected visible states:** Text area accepts keyboard/paste/focus across its full surface. Known tags are discoverable; unknown tags warn without deleting text. The copy explains this text belongs only to this worker.
- **Persistence / prompt / runtime effect:** Exact normalized multiline content persists and appears under this worker's managed instruction markers only.
- **Errors / recovery:** Empty instructions blocks save with focused guidance. Marker-looking input is escaped so it cannot break managed boundaries.
- **Automation:** Core integration + UI click.
- **Done:** Input, save, relaunch, editor round-trip, and exact prompt section assertion pass.

### WJ-WRK-004 - Edit shared model rules once in Settings, with one canonical source

- **Persona / goal:** The user wants the role guidance for GPT-5.6 Sol, Kimi K3, MiniMax M3, Grok, or any custom canonical model directly next to a worker.
- **Preconditions:** Two workers share the same canonical model; one uses a model alias.
- **Steps:** Open Settings/Prompt; edit the colored model-owned block; save; open both workers and return to Settings/Prompt.
- **Expected visible states:** Settings clearly labels the block as model-owned and shows the full current text. Each worker editor has exactly one worker-specific task field and no second model-rule description. There is no separate “Modellregeln” modal or orphan editor.
- **Persistence / prompt / runtime effect:** One `modelPrompts[canonicalName]` value updates; the composed prompt includes the model block once, even if multiple workers use it.
- **Errors / recovery:** Changing model warns if unsaved edits would switch canonical source; user can save/discard/cancel. Missing rules show an editable empty model block, not stale defaults from another model.
- **Automation:** Core integration + UI click.
- **Done:** Cross-editor round-trip, alias canonicalization, and exactly-once prompt tests pass.

### WJ-WRK-005 - Model-specific controls come from model/harness capabilities

- **Persona / goal:** The user wants valid reasoning and speed choices, not a generic list that the runtime ignores.
- **Preconditions:** Fixtures for GPT-5.6 Sol/Terra/Luna, Claude Sonnet/Opus/Fable 5, Kimi, MiniMax M3, GLM 5.2, Grok, Gemini, plus unknown custom model.
- **Steps:** Change provider/model/harness combinations.
- **Expected visible states:** Only supported reasoning levels and speed/variant controls appear. Labels are user-facing. Unsupported values are not selectable; custom model allows manual ID and explicitly states unverified capabilities.
- **Persistence / prompt / runtime effect:** Selected values map to the exact harness invocation and are rendered in generated worker facts.
- **Errors / recovery:** A discovered model capability change resets only invalid options with a visible explanation; never silently sends ignored flags.
- **Automation:** Core integration + UI click + harness smoke.
- **Done:** Capability matrix asserts both UI choices and actual command/protocol payload.

### WJ-WRK-006 - Move a worker between computers

- **Persona / goal:** The user wants to move an existing worker from Local to a remote computer or back.
- **Preconditions:** Local and a configured remote; worker is not currently running.
- **Steps:** Edit worker; click target computer; save; switch main computer buttons.
- **Expected visible states:** Computer choices are direct buttons. Worker disappears from source and appears on target with the same UUID and all settings. Its new readiness status reflects target capability.
- **Persistence / prompt / runtime effect:** Only `computerID` and derived generated target/runtime facts change; instructions/model rules remain byte-identical.
- **Errors / recovery:** Moving an active worker is blocked with “Worker zuerst stoppen” or explicitly queues the move; it never strands the run. Incompatible harness/target is explained before save.
- **Automation:** Core integration + UI click + remote compatibility test.
- **Done:** Move both directions, relaunch, prompt check, and UUID preservation pass.

### WJ-WRK-007 - Delete a worker safely

- **Persona / goal:** The user wants obsolete workers removed without damaging shared model rules.
- **Preconditions:** Worker shares model with another worker and has historical runs.
- **Steps:** Open editor; choose Delete; inspect confirmation; cancel once; confirm once.
- **Expected visible states:** Confirmation names worker and explains active-run/history effects. Deleted row disappears; shared model rule remains while referenced. Historical runs remain auditable but marked deleted worker.
- **Persistence / prompt / runtime effect:** Worker block/instructions and generated facts disappear on successful synchronized save. Shared model prompt is not automatically deleted.
- **Errors / recovery:** Active worker must be stopped first or deletion explicitly includes safe stop. Sync failure leaves worker present.
- **Automation:** Core integration + UI click.
- **Done:** Cancel/no-op and confirm/relaunch/prompt assertions pass.

## 5. Prompt transparency and navigation

### WJ-PRM-001 - Read the entire effective system prompt in source-aware blocks

- **Persona / goal:** The user wants to audit everything Fable receives.
- **Preconditions:** Unique sentinel text in every prompt source.
- **Steps:** Open Settings → Prompt; scroll from top to bottom; expand technical rules.
- **Expected visible states:** In effective order: editable General Rules; colored model-owned blocks; worker-owned blocks; persistent Ad-hoc Learnings; collapsed Technical Rules. Generated facts are visible in the relevant worker/technical area. Each block names its source and edit behavior. No giant undifferentiated editor exists.
- **Persistence / prompt / runtime effect:** Merely reading is non-mutating.
- **Errors / recovery:** Malformed managed markers display a blocking integrity error with backup/recovery; app does not silently regenerate over them.
- **Automation:** Core integration + UI click.
- **Done:** Every byte of the emitted prompt maps to a visible source block or visible composition delimiter; a test fails on any hidden appended text.

### WJ-PRM-002 - Edit general rules without absorbing generated content

- **Persona / goal:** The user wants to change only universal Fable/orchestrator rules.
- **Preconditions:** Existing general and generated content.
- **Steps:** Edit general rules; save/close; reopen; compare managed prompt.
- **Expected visible states:** Only the general block is editable in this editor. Worker/model content is visually separate.
- **Persistence / prompt / runtime effect:** Handwritten prefix changes; managed worker/model/learning/technical sources remain intact and are recomposed.
- **Errors / recovery:** Managed marker text pasted into general rules is rejected or escaped with explanation.
- **Automation:** Core integration + UI click.
- **Done:** Byte diff proves no generated content was copied into or deleted from general rules.

### WJ-PRM-003 - Edit model and worker blocks from the prompt page via their owners

- **Persona / goal:** While reading the composed prompt, the user wants a convenient edit action without losing source ownership.
- **Preconditions:** Model and worker blocks visible.
- **Steps:** Click Edit on a model block; change text; return. Click Edit on a worker block; change task; return.
- **Expected visible states:** Model action opens the corresponding model-owned editor in context; worker action opens the exact worker UUID editor. Returning scrolls back to the block and shows saved text. Source colors/labels remain.
- **Persistence / prompt / runtime effect:** Writes only `modelPrompts[canonical]` or `worker.instructions`, then recomposes.
- **Errors / recovery:** Deleted/missing owner shows an actionable stale-reference error, not a blank editor.
- **Automation:** UI click + Core integration.
- **Done:** Deep-link identity, round-trip, and source-only diffs pass.

### WJ-PRM-004 - Settings tabs scroll the one-page Settings view

- **Persona / goal:** The user wants fast navigation without separate cryptic settings pages.
- **Preconditions:** Settings content exceeds viewport.
- **Steps:** From top click Prompt, Anbieter, Computer, Telemetrie, Ausführung; manually scroll; repeat reverse order.
- **Expected visible states:** Sticky top tabs remain visible; clicking scrolls the real one-page view so the named section header lands below the tab bar and selected state follows. Tabs never replace content with a blank page.
- **Persistence / prompt / runtime effect:** None.
- **Errors / recovery:** Dynamic content height changes do not break anchors.
- **Automation:** UI click only (Core test insufficient).
- **Done:** Screenshot/frame assertions pass for every tab from multiple scroll positions.

### WJ-PRM-005 - Persistent Ad-hoc Learnings from UI and CLI

- **Persona / goal:** Fable wants to retain systematic orchestration lessons across projects; user wants to inspect/edit them.
- **Preconditions:** Shared Workjet state; CLI available.
- **Steps:** Read the in-app explanation; run `workjet learn --systematic "…"`; reopen Settings; edit the entry; list via CLI; restart app/project.
- **Expected visible states:** Section explains what qualifies: systematic, predictable orchestration failures - not daily/random struggles - and how Fable can add/edit them. Entries are readable/editable and persistent globally.
- **Persistence / prompt / runtime effect:** Learning store and Ad-hoc Learnings prompt section update atomically; no duplicate insertion.
- **Errors / recovery:** Concurrent app/CLI edits are lock-safe; conflicts are surfaced, never last-write-lost silently. Non-systematic CLI input is rejected or requires explicit systematic confirmation.
- **Automation:** Core/CLI integration + UI click.
- **Done:** Cross-process concurrency, project switch, relaunch, edit/list, and exact prompt tests pass.

### WJ-PRM-006 - Technical rules are visible, editable, and collapsed by default

- **Persona / goal:** An advanced user wants no hidden runtime policy while keeping normal Settings uncluttered.
- **Preconditions:** Technical rules and generated invocation facts exist.
- **Steps:** Open Prompt; confirm collapsed state; expand; edit technical policy; save; inspect emitted prompt.
- **Expected visible states:** Clear distinction between editable technical policy and generated runtime facts. Both are visible; generated facts link to their owning worker/computer rather than pretending to be editable text.
- **Persistence / prompt / runtime effect:** Technical policy update is persisted and composed at the end.
- **Errors / recovery:** Generated facts cannot be directly overwritten; Edit routes to owner. No invisible constant string is appended elsewhere.
- **Automation:** Core integration + UI click.
- **Done:** Source-coverage test accounts for 100% of emitted bytes and technical section defaults collapsed.

### WJ-PRM-007 - Configuration changes become effective immediately and observably

- **Persona / goal:** The user expects a saved worker/prompt change to affect the next delegation in a fresh Claude session.
- **Preconditions:** Claude Code installed; global Workjet include installed.
- **Steps:** Change a sentinel in app; save; inspect sync status; start a fresh Claude CLI/Desktop session and inspect the loaded Workjet configuration; repeat with app closed and reopened.
- **Expected visible states:** While saving, the app shows that changes are being applied. After success it reports only that the managed prompt is current on disk and globally installed. It does not claim to know whether an already-running Claude process reloaded that prompt. A failed write shows an explicit error instead.
- **Persistence / prompt / runtime effect:** Durable config and `~/.claude/workjet/AGENTS.md` are synchronized before success. Every already-running Claude process retains its captured prompt; only a fully restarted CLI/Desktop session gets the new one.
- **Errors / recovery:** Permission, malformed prompt, disk-full, or lock errors remain visible with retry and path; editor stays open and data remains.
- **Automation:** Core integration + UI click + real fresh-session Claude CLI and Desktop smoke.
- **Done:** Save-to-next-turn latency is bounded and proven; injected sync failure never reports success.

### WJ-PRM-008 - Global activation install, update, migration, and uninstall

- **Persona / goal:** The user installs Workjet once and expects every new Claude Code CLI and Desktop session to receive it automatically without losing personal Claude instructions.
- **Preconditions:** Exercise four homes: no global prompt, an existing unrelated global prompt, a former `/workjet`-only installation, and a current Workjet installation.
- **Steps:** Install; inspect `~/.claude/CLAUDE.md`; install again; update; start fresh CLI/Desktop sessions; uninstall the global integration.
- **Expected visible states:** Workjet reports “Bereit” only when the managed prompt is current and exactly one marked `@workjet/AGENTS.md` include exists. A malformed or duplicate marked block produces an actionable error and is never guessed at or silently rewritten.
- **Persistence / prompt / runtime effect:** Install/update atomically writes the app-managed `~/.claude/workjet/AGENTS.md` and replaces only Workjet's marked global block. Repeated installation is byte-idempotent. Migration removes dependence on the former skill. Uninstall removes only the marked include; unrelated global content and project-local `CLAUDE.md`/`AGENTS.md` files remain byte-identical.
- **Errors / recovery:** A failure during either write restores the previous global prompt and managed prompt. Symlinks, wrong ownership, malformed markers, and unwritable paths fail closed with recovery guidance.
- **Automation:** Core transaction tests + installer integration in an isolated home + real fresh-session Claude CLI and Desktop smoke.
- **Done:** All four homes pass install/update/uninstall, rollback injection, idempotency, project-nonmutation, and fresh-session prompt sentinel checks.

## 6. Computers and remote setup

### WJ-CMP-001 - Add a Tailscale computer by clicking a discovered device

- **Persona / goal:** The user wants to select an existing Tailscale machine and set it up without copying a hostname.
- **Preconditions:** Tailscale is connected; online and offline Linux devices are returned.
- **Steps:** Click top computer `+`; choose Tailscale; click an online device row; enter the target OS user if absent; click “Über Tailscale einrichten”. Workjet uses Tailscale SSH and deploys the remote runtime without asking for a local SSH key or fingerprint confirmation.
- **Expected visible states:** Selected row gains checkmark/highlight; the reachable Tailscale address populates internally; offline rows are visibly disabled; the UI states that Tailscale owns authentication and device identity. Successful setup becomes a top peer button.
- **Persistence / prompt / runtime effect:** Computer UUID/transport/host/user, managed-Tailscale-SSH mode, and verified deployment facts persist; private-key contents and provider secrets are never stored in configuration or copied to remote.
- **Errors / recovery:** Tailscale absent/disconnected shows plain-language install/connect/retry. A target that has not opted in shows the exact one-time `sudo tailscale set --ssh` action; a policy or OS-user denial is named separately. There is no silent key-based fallback.
- **Automation:** Core integration + UI click + real Tailscale smoke.
- **Done:** Actual row click - not manual host workaround - leads to successful probe/deployment and persisted button.

### WJ-CMP-002 - Add a strict SSH computer

- **Persona / goal:** The user wants a non-Tailscale host with explicit trust.
- **Preconditions:** Reachable SSH host and separately approved known-hosts entry.
- **Steps:** Add computer; choose SSH; enter name, host, user; select the SSH key if required; expand technical only for non-default port/known-hosts; scan and explicitly confirm the host fingerprint; set up.
- **Expected visible states:** Primary UI stays concise. Strict host-key validation is stated. Success/failure is visible.
- **Persistence / prompt / runtime effect:** Connection metadata and only the local key-file path persist; private-key contents and passwords are never stored by Workjet.
- **Errors / recovery:** Unknown/mismatched host key blocks setup with exact external remediation; no `StrictHostKeyChecking=no` fallback.
- **Automation:** Core integration + UI click + real SSH smoke + manual security.
- **Done:** Good key succeeds; unknown and changed keys fail safely.

### WJ-CMP-003 - Minimal sandbox is enforced, not decorative

- **Persona / goal:** The user wants Pi Code on a remote host to see only the projected turn snapshot.
- **Preconditions:** Linux host with and without approved `bwrap` cases.
- **Steps:** Enable sandbox; set up; run a canary turn attempting permitted turn-file write and forbidden host-file write; repeat with `bwrap` unavailable.
- **Expected visible states:** App reports verified sandbox readiness. Permitted operation succeeds; forbidden host access fails. Missing `bwrap` blocks execution rather than degrading unsandboxed.
- **Persistence / prompt / runtime effect:** Verified executable/version/hash persist and appear as visible generated technical facts.
- **Errors / recovery:** Host lacking prerequisite gives actionable status; toggling sandbox off requires explicit acknowledgement and changes visible prompt fact.
- **Automation:** Real remote smoke + manual security.
- **Done:** Security canary proves filesystem boundary and fail-closed behavior.

### WJ-CMP-004 - Edit, switch, and delete a computer

- **Persona / goal:** The user wants lifecycle control over every remote button.
- **Preconditions:** Remote computer with assigned workers.
- **Steps:** Open computer edit action; change allowed connection data; save; select button; reopen; delete; cancel once then confirm.
- **Expected visible states:** Edit targets exact computer UUID. Delete confirmation states worker migration. On confirm remote button disappears and assigned workers move to Local with unchanged UUIDs.
- **Persistence / prompt / runtime effect:** Connection and target facts recompose; deleting never deletes workers/model rules.
- **Errors / recovery:** Local cannot be deleted. Active runs block deletion or require explicit safe stop. Save/deletion failure leaves original state.
- **Automation:** Core integration + UI click.
- **Done:** Edit/relaunch/select/delete/migration/prompt assertions pass.

### WJ-CMP-005 - Remote setup is minimal, versioned, and auditable

- **Persona / goal:** The user wants fast deployment of the pinned Pi core/host without a source fork or package sprawl.
- **Preconditions:** Clean supported Linux host; audited bundled artifacts.
- **Steps:** Set up remote; inspect deployment report; rerun unchanged; update bundle version and rerun.
- **Expected visible states:** App reports protocol/version/content hash and idempotent result. Only bundle, generated runner, and manifest are transferred; Workjet does not install OS/npm packages silently.
- **Persistence / prompt / runtime effect:** Installed version/hash and timestamps persist.
- **Errors / recovery:** Partial transfer never becomes current; rollback/current pointer remains valid. Unsupported Node/Linux reports blocked.
- **Automation:** Core integration + real remote smoke + release artifact audit.
- **Done:** File manifest matches allowlist, idempotence and atomic upgrade/rollback tests pass.

## 7. Providers, accounts, pools, models, and capacity

### WJ-PRV-001 - Add OAuth provider in one homogeneous flow

- **Persona / goal:** The user wants Kimi, OpenAI, Anthropic, Antigravity/Google, or xAI access via CLIProxy with one click to web authentication.
- **Preconditions:** Loopback-only CLIProxy service available with management authentication.
- **Steps:** Settings → Anbieter; click real provider logo; name account; click “Im Browser verbinden”; complete OAuth; return.
- **Expected visible states:** Authentic provider logo/name, browser opens only on click, progress and callback status are clear, connected account appears with identity/label and discovered models. Flow shape is the same for all OAuth-capable providers.
- **Persistence / prompt / runtime effect:** Persist nonsecret CLIProxy auth identity/routing prefix and Keychain credential reference; never browser tokens in config/prompt.
- **Errors / recovery:** Cancel, callback timeout, wrong account, service down, and auth expiry each show specific retry/re-auth. No account is marked connected without post-login identity verification.
- **Automation:** Core integration + UI click with test server + manual real OAuth/security.
- **Done:** One real supported provider completes E2E; remaining provider adapters pass contract tests; no fake connected state.

### WJ-PRV-002 - Add API-key provider in the same provider language

- **Persona / goal:** The user wants MiniMax M3, z.ai GLM 5.2, or compatible API services without confronting proxy internals.
- **Preconditions:** Valid/invalid test credentials and endpoint.
- **Steps:** Click provider logo or `+`; select API access; name account; enter key; connect; select discovered model.
- **Expected visible states:** Same account card and model picker as OAuth. Technical endpoint is advanced/optional. Real logos are used, not letter tiles.
- **Persistence / prompt / runtime effect:** Secret goes to Keychain; config stores only reference/account metadata/models.
- **Errors / recovery:** Invalid key/endpoint/TLS/network are distinct; key remains masked; denial does not create connected account.
- **Automation:** Core integration + UI click + provider sandbox/manual security.
- **Done:** MiniMax and z.ai compatible contract smokes prove authentication and model listing.

### WJ-PRV-003 - Edit, re-authenticate, disable, and delete an account

- **Persona / goal:** The user wants complete provider-account lifecycle control.
- **Preconditions:** Account referenced by workers and another unreferenced account.
- **Steps:** Open account; rename; refresh models; re-auth; disable/enable; attempt delete.
- **Expected visible states:** Exact account identity is edited. Delete explains affected workers/pools and requires confirmation. Disabled/deleted route makes affected workers unavailable but preserves their model/instructions.
- **Persistence / prompt / runtime effect:** References remain stable on rename/re-auth; deletion removes credential only after config/prompt synchronization or transactionally rolls back.
- **Errors / recovery:** Keychain denial and provider outage retain account metadata and offer retry. No launch-time popups.
- **Automation:** Core integration + UI click + manual Keychain/OAuth.
- **Done:** Lifecycle matrix and referential-integrity tests pass.

### WJ-PRV-004 - Stack multiple subscriptions for the same provider

- **Persona / goal:** A power user wants several OpenAI/xAI/etc. subscriptions as separately visible accounts.
- **Preconditions:** Two real or contract-test accounts of same provider.
- **Steps:** Add account A; add account B through the same provider logo; name/priority both; assign different workers directly.
- **Expected visible states:** Both account cards remain distinct, show connection/capacity state, and can be selected explicitly. Adding B never overwrites A.
- **Persistence / prompt / runtime effect:** Unique account UUID plus external proxy auth identity/prefix persist. Concrete-account invocation is pinned to that identity.
- **Errors / recovery:** Duplicate external identity is detected and offered as “existing account”, not silently duplicated. One expired account does not disconnect the other.
- **Automation:** Core integration + CLIProxy contract + UI click + manual OAuth.
- **Done:** Requests attributed by proxy evidence prove A and B are actually distinct, not two labels over one token.

### WJ-PRV-005 - Select a deterministic provider pool with real failover

- **Persona / goal:** The user wants stacked accounts used as a pool.
- **Preconditions:** Three accounts same provider with explicit priority; one healthy, one quota-exhausted, one auth-failed.
- **Steps:** Choose provider pool on worker; run multiple requests; inspect route/status; restore accounts.
- **Expected visible states:** UI shows “Pool: A → B → C”, not “not configured”. Runtime starts with deterministic eligible account and fails over only on classified provider availability/quota failures; it loudly reports account change. Task errors do not trigger account fallback.
- **Persistence / prompt / runtime effect:** Worker stores pool provider; composed prompt shows ordered account names/identities without secrets; runtime ledger records selected account.
- **Errors / recovery:** All unavailable yields explicit pool failure with per-account reasons; no silent model/provider substitution.
- **Automation:** Core integration + CLIProxy/runtime integration + UI click + real provider smoke.
- **Done:** Attribution logs prove order and failure semantics E2E.

### WJ-PRV-006 - Discover and choose only real available models

- **Persona / goal:** The user wants to authenticate first, then choose the models that account actually exposes.
- **Preconditions:** Provider response includes several models and capability metadata.
- **Steps:** Connect account; refresh; create/edit worker; choose account; inspect/select model.
- **Expected visible states:** Discovered models lead the picker and include current supported families; stale hard-coded chips do not masquerade as availability. Manual model ID remains possible and labelled unverified.
- **Persistence / prompt / runtime effect:** Exact provider model ID and discovery timestamp persist; canonical prompt mapping is explicit.
- **Errors / recovery:** Discovery failure shows cached list as stale or manual entry; it never cross-contaminates models from another provider/account.
- **Automation:** Core integration + UI click + provider contract.
- **Done:** Per-account model isolation and refresh/update tests pass.

### WJ-PRV-007 - Capacity and rate refresh for account and pool

- **Persona / goal:** The user wants trustworthy quota/rate information in rows and Settings.
- **Preconditions:** Providers with measured usage, rate-limit response, unsupported metrics, and multiple pool accounts.
- **Steps:** Open Settings/Anbieter; refresh; observe main rows; trigger a rate limit; wait for reset.
- **Expected visible states:** Account details show source, value, reset/timestamp when the provider actually exposes them. Main row reflects selected account/pool. A connected account with no measurable quota remains simply “Verbunden”; missing telemetry is neither green warning copy nor a fake capacity restriction.
- **Persistence / prompt / runtime effect:** Observation cache only; no prompt mutation.
- **Errors / recovery:** Backoff prevents polling storms. Last-known data is marked stale. Pool aggregates only compatible measured units or shows account-wise status.
- **Automation:** Core integration + UI click + real provider smoke.
- **Done:** Refresh, stale, reset, backoff, and pool-compatibility tests pass.

## 8. Harnesses and execution

### WJ-HAR-001 - Harness selection is honest and capability-driven

- **Persona / goal:** The user wants Claude Code, Pi Code, Codex CLI, OpenCode, Cursor Agent, or Grok CLI only when Workjet can actually invoke it.
- **Preconditions:** Adapter registry contains supported and unavailable adapters.
- **Steps:** Open worker; inspect harness buttons; select each; inspect fields/status; save/run where supported.
- **Expected visible states:** Product names are exact (“Pi Code”, not “Pi Sidecar”). Supported adapters expose appropriate model/options. Unimplemented adapters are disabled/“Nicht verfügbar” with reason; they cannot be saved as ready merely because a button exists.
- **Persistence / prompt / runtime effect:** Selected adapter ID and visible options map to generated prompt facts and runtime payload.
- **Errors / recovery:** Missing executable/version/protocol is detected by probe. No shell-template fake claims support.
- **Automation:** Core integration + UI click + harness smokes.
- **Done:** Registry/UI/runtime support matrix has no contradictory state.

### WJ-HAR-002 - Claude Code local and remote execution

- **Persona / goal:** Fable delegates to a configured Claude Code worker and receives attributable live status/result.
- **Preconditions:** Valid account/model; local and remote target variants.
- **Steps:** Invoke through the Workjet CLI contract from a globally configured Claude turn; observe app; receive events/result; stop one run.
- **Expected visible states:** Correct worker becomes active; concise activity/elapsed target shown; stop reaches that run; terminal result clears active state.
- **Persistence / prompt / runtime effect:** Run ledger records worker/computer/account/harness; prompt config unchanged.
- **Errors / recovery:** Auth/quota/task/transport failures are distinct; fallback follows declared dispatcher rules only.
- **Automation:** Core integration + real local/remote smoke + UI click.
- **Done:** Start/events/stop/result E2E passes and output identity matches worker UUID.

### WJ-HAR-003 - Pi Code fresh-daemon bounded turn

- **Persona / goal:** Fable delegates one bounded snapshot turn to the custom Pi harness.
- **Preconditions:** Pinned `@earendil-works/pi-agent-core@0.80.2` bundle and verified target sandbox.
- **Steps:** Send `CtoxTurnRequest.files`; observe start/events; receive `CtoxTurnResponse`; terminate/drop; test second turn.
- **Expected visible states:** Pi Code status names target; each turn uses a fresh daemon; no host process authority is shared; response/event limitations are honest.
- **Persistence / prompt / runtime effect:** Result becomes review/integration input; runtime facts show pinned version/hash/sandbox.
- **Errors / recovery:** Daemon crash/timeout/invalid response kills child, closes run, and reports error. No faux inference is labelled real.
- **Automation:** Core integration + real local/remote smoke + sandbox security.
- **Done:** Process lifecycle, single-turn bound, snapshot isolation, and cleanup are proven.

### WJ-HAR-004 - Codex CLI and OpenCode protocol execution

- **Persona / goal:** The user wants additional genuine harnesses beyond Claude and Pi.
- **Preconditions:** Supported executables/config on target.
- **Steps:** Configure one worker per harness; invoke via Workjet CLI; observe events/result/stop.
- **Expected visible states:** Harness-specific supported controls only; active row names correct worker/harness. Telemetry comes from structured adapter events or explicitly bounded observation, not fabricated generic strings.
- **Persistence / prompt / runtime effect:** Exact adapter options and command/protocol facts persist visibly.
- **Errors / recovery:** Missing/unsupported version blocks readiness with install/remediation.
- **Automation:** Core integration + real local/remote smoke + UI click.
- **Done:** Independent start/event/stop/result smoke for each harness.

### WJ-HAR-005 - Cursor Agent and Grok CLI require real adapters before enablement

- **Persona / goal:** The user wants these harnesses if and only if genuine invocation and telemetry exist.
- **Preconditions:** Adapter unavailable state; later supported build fixture.
- **Steps:** Attempt selection in unavailable build; in supported build run protocol smoke.
- **Expected visible states:** Unavailable build explains “Adapter noch nicht unterstützt” and cannot save it as functional. Supported build exposes controls only after executable/protocol probe.
- **Persistence / prompt / runtime effect:** No placeholder invocation is generated.
- **Errors / recovery:** Protocol mismatch returns unsupported/degraded state, not generic success.
- **Automation:** Core integration + UI click; real smoke mandatory before release flag.
- **Done:** Feature flag/support status is evidence-backed; a button alone never satisfies story.

### WJ-HAR-006 - CLI is the stable bridge from Fable to workers

- **Persona / goal:** Claude/Fable receives the globally included Workjet configuration and can invoke a declared worker without the app orchestrating for it.
- **Preconditions:** App-generated configuration; `workjet` CLI installed.
- **Steps:** From Claude Code call list/describe/run/events/stop for a worker mention/UUID; repeat after app configuration change.
- **Expected visible states:** App reflects CLI run; CLI emits stable machine-readable output and human diagnostics. Fable chooses worker; app does not choose for it.
- **Persistence / prompt / runtime effect:** Managed prompt contains exact invocation contract. CLI resolves current config atomically.
- **Errors / recovery:** Unknown/ambiguous mention, unsupported adapter, stale config, and connection loss return distinct nonzero codes.
- **Automation:** CLI/Core integration + real local/remote smoke.
- **Done:** A fresh Claude CLI and Desktop session can perform E2E delegation using only the globally included, user-visible Workjet instructions.

## 9. Telemetry, reconnection, stop, and errors

### WJ-TEL-001 - Local telemetry follows real lifecycle events

- **Persona / goal:** The user wants to trust the Active area.
- **Preconditions:** Direct wrapper, dispatcher, and CLI-run fixtures.
- **Steps:** Start, stream, idle, complete, fail, and kill each process.
- **Expected visible states:** Active starts promptly, shows current bounded summary, then terminates. Process disappearance cannot leave hours-long activity. Duplicate journals collapse to one run.
- **Persistence / prompt / runtime effect:** Bounded ledger with terminal state and retention policy.
- **Errors / recovery:** Malformed/stale files appear as diagnostics, never active sessions.
- **Automation:** Core integration + UI click + real process smoke.
- **Done:** Lifecycle timing bounds and no-ghost assertions pass.

### WJ-TEL-002 - Remote events reconnect without gaps or duplication

- **Persona / goal:** The user wants reliable telemetry over flaky Tailscale/SSH.
- **Preconditions:** Running remote harness with cursor/event replay protocol.
- **Steps:** Disconnect network; produce events; reconnect; restart app; continue; complete.
- **Expected visible states:** Run becomes “Verbindung unterbrochen”, then resumes. Replayed events are ordered once. Unrecoverable cursor gap is called out explicitly.
- **Persistence / prompt / runtime effect:** Last cursor persists per run; configuration unchanged.
- **Errors / recovery:** Backoff is bounded; user can retry/stop. A host restart produces terminal/lost state, not eternal running.
- **Automation:** Core integration + real remote smoke + UI click.
- **Done:** Network fault injection proves exclusive replay, gap detection, and eventual terminal state.

### WJ-TEL-003 - Stop targets exactly one run and confirms outcome

- **Persona / goal:** The user wants the red stop control to stop the intended active worker safely.
- **Preconditions:** Two concurrent runs, local and remote.
- **Steps:** Click stop on one; confirm if necessary; inspect both.
- **Expected visible states:** Target changes to stopping then interrupted; other continues. Failure to stop remains visible with retry/force guidance appropriate to harness.
- **Persistence / prompt / runtime effect:** Terminal interruption event persisted.
- **Errors / recovery:** Lost connection queues/attempts protocol stop and explains uncertainty; never marks stopped without acknowledgement or process evidence.
- **Automation:** Core integration + UI click + real local/remote smoke.
- **Done:** Run-ID isolation and acknowledgement semantics pass.

### WJ-TEL-004 - Full error awareness stays concise and actionable

- **Persona / goal:** The user wants subtle status at a glance and complete diagnostics when needed.
- **Preconditions:** Inject prompt sync, provider, quota, computer, harness, telemetry, and persistence errors.
- **Steps:** Trigger each; observe header/row; open related details; retry/dismiss.
- **Expected visible states:** Header summarizes count/severity; row/account/computer owns its error; Settings has timestamped diagnostics and recovery. No technical essay crowds the main list.
- **Persistence / prompt / runtime effect:** Errors do not mutate config; dismissing UI does not erase unresolved health fact.
- **Errors / recovery:** Recovery action re-probes and clears only on evidence.
- **Automation:** Core integration + UI click.
- **Done:** Error-to-owner/action matrix is complete and no failure is represented only in logs.

## 10. Worktree lifecycle and storage

### WJ-RUN-001 - Isolated run worktrees are recoverable and bounded

- **Persona / goal:** The orchestrator wants isolated changes without another 101 GB of ghost worktrees.
- **Preconditions:** Clean/dirty repos, successful/failed/abandoned/integrated runs, ignored files, active process handles.
- **Steps:** Dispatch isolated runs; inspect refs/journals; mark integrated/abandoned; run dry-run prune and automatic prune after policy age.
- **Expected visible states:** CLI reports run directory/worktree/ref and cleanup decision/reason. App Execution/Telemetry may summarize storage and stale retained items.
- **Persistence / prompt / runtime effect:** Successful changes protected by `refs/workjet/<run-id>` before cleanup; journal remains auditable.
- **Errors / recovery:** Unmarked, dirty, active, unregistered, path-outside-root, or missing-protected-ref worktrees are retained. No broad `rm -rf`/forced removal.
- **Automation:** Shell/Core integration + manual disk audit.
- **Done:** Safety matrix, disk-growth regression, recovery from protected ref, and 24-hour auto-policy tests pass.

### WJ-RUN-002 - Dispatcher fallback and quota semantics remain explicit

- **Persona / goal:** Fable wants predictable routing when a required worker is unavailable.
- **Preconditions:** Probe fixtures for primary available, auth/quota unavailable, task failure, and explicit degradation.
- **Steps:** Run each role with/without `--degrade`; inspect exit/status artifacts.
- **Expected visible states:** Required success exit 0; primary unavailable without authorization exit 3/no delivery; task failure exit 4/no fallback; explicit degraded delivery exit 10 with loud banner. Review has no fallback.
- **Persistence / prompt / runtime effect:** Immutable attempt artifacts and answering worker retained.
- **Errors / recovery:** Auth expiry gives exact user action; never silently swaps model/account.
- **Automation:** Shell integration.
- **Done:** Dispatcher and fleet suites pass in release environment.

## 11. Release, install, and update

### WJ-REL-001 - Clean reproducible release build

- **Persona / goal:** A maintainer wants a release, not an ad-hoc development bundle.
- **Preconditions:** Clean checkout and pinned toolchain/dependencies.
- **Steps:** Run full test/build/package pipeline twice; compare manifests; inspect bundle.
- **Expected visible states:** Proper app icon/status asset included; provider logos included; no development absolute paths, temporary assets, preview data, or runtime SVG conversion dependency.
- **Persistence / prompt / runtime effect:** None until install.
- **Errors / recovery:** Missing signing/dependency fails build clearly.
- **Automation:** CI + artifact audit.
- **Done:** All Core/UI/shell/remote-contract tests green, `git diff --check` green, reproducible manifest documented.

### WJ-REL-002 - Signed, notarized, quiet installation

- **Persona / goal:** A user wants to install and launch without Gatekeeper confusion or unsolicited prompts.
- **Preconditions:** Fresh supported macOS account.
- **Steps:** Install signed artifact to Applications; launch; inspect signature/notarization; open/quit/relaunch.
- **Expected visible states:** Correct Workjet turbine icon and menu status item; no terminal required; no Keychain dialog until explicit credential use.
- **Persistence / prompt / runtime effect:** Creates versioned Application Support state with secure permissions and installs only Workjet's marked global Claude include while preserving unrelated content.
- **Errors / recovery:** Unsupported OS or migration failure explains and preserves prior data.
- **Automation:** CI signing verification + manual clean-machine smoke.
- **Done:** `codesign`/`spctl`/notarization and clean-user acceptance pass.

### WJ-REL-003 - Update and configuration migration preserve user intent

- **Persona / goal:** Existing users want new versions without losing workers, prompts, accounts, computers, learnings, or histories.
- **Preconditions:** Fixtures from every released schema and legacy “Pi Sidecar” naming/single-provider format.
- **Steps:** Install old fixture; update; launch; inspect/mutate/relaunch; optionally roll back app binary.
- **Expected visible states:** Migration summary only when action is needed. Harness displays “Pi Code”; stable UUIDs/routes survive. No OAuth is triggered on update.
- **Persistence / prompt / runtime effect:** Atomic, backed-up, versioned migration; managed prompt recompose is deterministic.
- **Errors / recovery:** Migration failure leaves original files and offers restore/export; never overwrites with sample defaults.
- **Automation:** Core migration + UI smoke + manual update.
- **Done:** Golden fixtures and rollback/readability policy pass.

### WJ-REL-004 - Accessibility and dense-layout release check

- **Persona / goal:** Keyboard, VoiceOver, and low-vision users need the same compact but understandable app.
- **Preconditions:** Default and increased text size/contrast settings.
- **Steps:** Navigate all controls by keyboard and VoiceOver; inspect popover at supported scale; run main workflows.
- **Expected visible states:** Meaningful labels include stable target identity; focus is visible; horizontal chip rows remain operable; no clipped essential controls; status never relies on color alone. Information hierarchy stays dense without blank spacer rows or technical prose on primary screens.
- **Persistence / prompt / runtime effect:** Same as mouse flow.
- **Errors / recovery:** Validation moves focus and is announced.
- **Automation:** UI accessibility audit + manual VoiceOver.
- **Done:** All release stories' primary actions are keyboard/VoiceOver reachable and screenshots meet density baseline.

## 12. Complaint-to-acceptance traceability

This matrix ensures every recurring complaint from the design/implementation conversation is represented by a release acceptance, rather than being lost as informal feedback.

| Complaint / requirement | Governing stories |
|---|---|
| Minimal, dense HuggQuick-like list; no visual noise or wasted rows | WJ-MAIN-002, WJ-MAIN-003, WJ-REL-004 |
| Workers are named roles with model beneath; only running/not-running is task progress | WJ-MAIN-002, WJ-MAIN-004 |
| Local plus arbitrary direct computer buttons; no dropdown | WJ-MAIN-001 |
| Top `+` adds computer; worker-list `+` adds worker | WJ-CMP-001, WJ-WRK-001 |
| Edit pencil must open exact worker and show all data | WJ-WRK-002 |
| Status on every worker; global warning is insufficient | WJ-MAIN-002 |
| Quota/rate beside model and complete in Settings | WJ-MAIN-003, WJ-PRV-007 |
| Worker text must be enterable, saved, and appear correctly in prompt | WJ-WRK-003, WJ-PRM-003 |
| Missing fields must explain why Save cannot proceed | WJ-WRK-001 |
| Model rules are canonical source, visible/editable in worker and prompt; no extra modal | WJ-WRK-004, WJ-PRM-003 |
| Kimi/Sol/MiniMax/Grok rule text must round-trip exactly | WJ-WRK-004 |
| Entire system prompt readable; general/model/worker blocks source-aware | WJ-PRM-001, WJ-PRM-002, WJ-PRM-003 |
| No hidden prompts; technical prompts visible/editable and collapsed at end | WJ-PRM-006 |
| One-page Settings with working navigation tabs | WJ-PRM-004 |
| Persistent Ad-hoc Learnings with guidance for Fable CLI | WJ-PRM-005 |
| Changes in app immediately affect the next fresh Claude turn, with status/errors | WJ-PRM-007 |
| App icon clearly Workjet/turbine and status at a glance | WJ-APP-001, WJ-APP-002 |
| App must open correct popover, not neighbor's “No Active Sessions” | WJ-APP-001 |
| No launch-time Keychain password popups | WJ-APP-003 |
| Authentic provider logos, not initials | WJ-PRV-001, WJ-PRV-002 |
| Homogeneous add-provider flow; one click to OAuth; API accounts too | WJ-PRV-001, WJ-PRV-002 |
| Kimi/OpenAI/Anthropic/Antigravity/xAI plus MiniMax/z.ai | WJ-PRV-001, WJ-PRV-002, WJ-PRV-006 |
| Multiple subscriptions of same provider and stacked pools | WJ-PRV-004, WJ-PRV-005 |
| Provider edit/delete/re-auth and actual account pinning | WJ-PRV-003, WJ-PRV-004 |
| Discover model after auth, then choose reasoning/speed | WJ-PRV-006, WJ-WRK-005 |
| Harness names are Claude Code and Pi Code; more real harnesses via t3code-like capability | WJ-HAR-001 through WJ-HAR-005 |
| Workjet remains a global prompt/config extension; Fable chooses and invokes workers | WJ-HAR-006 |
| Minimal Pi sandbox over Tailscale/SSH, pinned upstream core | WJ-CMP-003, WJ-CMP-005, WJ-HAR-003 |
| Select a Tailscale device directly; edit/delete/switch computers | WJ-CMP-001, WJ-CMP-004 |
| Move worker between computers | WJ-WRK-006 |
| Real local/remote telemetry, reconnect, stop; no ghosts | WJ-MAIN-004, WJ-TEL-001 through WJ-TEL-003 |
| Complete but subtle error awareness | WJ-TEL-004 |
| 101 GB ghost worktrees, safe lifecycle and retention | WJ-RUN-001 |
| No fake fallback or implementation claims | WJ-HAR-001, WJ-PRV-005, WJ-RUN-002 |
| Repo must be maintained for a real release | WJ-REL-001 through WJ-REL-004 |

## 13. Mandatory release evidence

A release is not “done” until its artifact bundle contains or links to:

1. Core/shell test reports and coverage of all deterministic contracts.
2. Real-app UI-click report with screenshots for every `UI click` story and UUID-keyed accessibility identifiers.
3. Remote smoke report naming OS, transport, host role (secrets redacted), protocol/harness versions, sandbox canary, event reconnect, and stop results.
4. Provider/account evidence for OAuth and API flows, multiple-account identity attribution, pool fallback, model discovery, and capacity. Credentials/tokens must never appear.
5. Prompt transparency artifact mapping every emitted byte to its visible editable/generated source.
6. Signed/notarized artifact verification, clean-user install/update results, and migration fixture report.
7. An open-defects list. Any unmet Done criterion remains explicitly open; it cannot be relabelled “implemented” because a type, button, mock, or unit test exists.
