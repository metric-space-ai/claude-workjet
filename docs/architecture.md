# Architecture

Workjet is a local macOS application and CLI. Claude remains responsible for planning, worker selection, integration, and verification. Workjet supplies configuration, execution boundaries, remote transport, and observable state.

## Component map

```text
Claude Code / Claude Desktop
  |
  | globally included, user-visible worker contract
  | list / describe / run / events / stop
  v
Workjet CLI
  |
  +--> WorkjetCore service and persistence
  |      +--> configuration and managed prompt
  |      +--> provider routing and Keychain references
  |      +--> harness lifecycle and invocation adapters
  |      +--> local and remote run ledgers
  |      +--> workspace snapshots and result import
  |
  +--> local wrapper or harness process
  |
  +--> strict OpenSSH transport
           +--> versioned remote host runtime
           +--> detached host-owned worktree
           +--> harness process and bounded events

Workjet menu-bar app
  +--> edits the same configuration and prompt sources
  +--> displays worker, provider, computer, and run state
  +--> never chooses the worker for Claude
```

## App and CLI

`WorkjetApp` is an AppKit-owned menu-bar application with SwiftUI views. It edits named workers, provider routes, computers, skills, prompt sources, and settings. The app also displays local and remote run observations.

`WorkjetCLI` builds the executable product `workjet`. It is the stable bridge used by Claude:

```text
workjet workers list --json
workjet workers describe <exact-name-or-uuid> --json
workjet health --probe-workers [--worker <exact-name-or-uuid>] --json
workjet run <exact-name-or-uuid> --brief-file <path> --json
workjet events <run-id> --after <exclusive-sequence> --json
workjet stop <run-id> --json
```

The operator-only recovery command `workjet computers setup <exact-name-or-uuid> --json` redeploys Workjet's content-addressed remote host and persists the verified result. It is not part of Claude's ordinary delegation loop.

The CLI resolves current configuration and delegates to WorkjetCore. Claude does not construct raw SSH or harness commands from the managed prompt.

## WorkjetCore responsibilities

WorkjetCore contains the product rules shared by the app, CLI, and tests:

- Codable configuration and migrations.
- Atomic, owner-checked local persistence.
- Managed prompt composition and checksum-protected marker replacement.
- Provider account, pool, endpoint, and credential-reference routing.
- Harness descriptors, lifecycle inspection, and fixed invocation adapters.
- Local process identity, heartbeat, stop, and retention logic.
- Remote protocol request and response validation.
- Immutable workspace snapshot and result-bundle verification.
- Worker skill compatibility and launch-time availability checks.
- Non-authoritative completion receipt and telemetry metadata.

## Persistent state

The live app stores non-secret product state under:

```text
~/Library/Application Support/Workjet/
```

Provider credentials are stored as owner-only files under `~/.config/workjet/credentials/` (directory mode `0700`, files `0600`). The managed Claude prompt is:

```text
~/.claude/workjet/AGENTS.md
```

The installer owns exactly one marked include in:

```text
~/.claude/CLAUDE.md
```

Unrelated global content is preserved. Project-local `CLAUDE.md` and `AGENTS.md` files are not installation targets.

Local run journals and indexes are bounded state used to identify active processes and retain terminal evidence. Isolated dispatcher worktrees live under the Workjet state root and successful deliveries are protected by `refs/workjet/<run-id>` until the orchestrator integrates or abandons them.

## Prompt model

The effective managed prompt has visible sources:

1. General rules.
2. Progress-board rules.
3. Generated worker facts.
4. Canonical model rules.
5. Worker-specific instructions.
6. Ad-hoc learnings.
7. Technical rules, including the completion receipt protocol and managed skill prompt sources.

The app edits source-owned values and recomposes the prompt. Marker parsing and SHA-256 validation prevent silent replacement of malformed managed content.

## Execution model

A worker invocation is intentionally fire-and-forget:

1. Claude selects one declared worker and writes a precise brief.
2. Workjet resolves the exact worker UUID, computer, harness, provider route, and visible options.
3. Workjet starts a local process or sends a typed request to the remote host.
4. Events are read through bounded local telemetry or the remote exclusive-sequence cursor.
5. The worker may emit a structured completion receipt.
6. Claude inspects the actual result, code, diff, refs, and tests before integration.

Workjet does not silently substitute another worker. Provider pool movement is limited to the classified routing behavior represented in configuration and runtime evidence.

## Remote host

The generated remote host is versioned and content-addressed. It accepts typed operations, validates request shape and bounds, selects executable paths and arguments from host-side allowlists, and records authoritative run state. It does not accept an arbitrary client-provided shell command.

Repository-backed runs use detached worktrees created from immutable Git bundles. Pi Code retains its explicit in-memory turn request contract. See [Remote execution and security](remote-execution-security.md).

## Trust and verification

Workjet distinguishes configuration, observation, and proof:

- A configured provider or harness is not proof that it is currently available.
- A probe result is target-specific evidence, not a permanent guarantee.
- Telemetry reports observed lifecycle facts and bounded diagnostics.
- A completion receipt is an untrusted worker claim.
- The orchestrator remains responsible for inspecting changes and rerunning checks.
