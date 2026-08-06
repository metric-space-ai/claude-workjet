# Workers, skills, receipts, and telemetry

Workjet separates worker configuration, launch-time capability, observed run state, and delivered claims. Keeping those concepts distinct prevents a configured checkbox or worker report from being treated as proof.

## Workers

A worker has a stable UUID and user-visible configuration:

- name and mention tag;
- harness and exact model ID;
- reasoning and harness-specific options where supported;
- one provider account or deterministic provider pool;
- one local or remote computer;
- worker-specific instructions;
- sparse skill overrides;
- visible generated invocation facts.

Claude chooses the worker. Workjet resolves the UUID and executes the configured route. The app does not decide which worker should handle a task.

Workers remain fire-and-forget. The complete brief must contain the scope, file boundaries, acceptance commands, reporting requirements, and escape hatch before launch. Interactive mid-run steering is not part of the contract.

## Managed completion protocol

The default technical rules include Workjet Completion Receipt V1 for task-capable coding workers. A task worker is asked to finish stdout with one bounded JSON object containing:

- status;
- factual summary;
- claimed changed files;
- claimed verification commands and results;
- concerns;
- produced paths.

The dispatcher records receipt health as valid, missing, or invalid and writes bounded completion metadata. Receipt text does not determine provider fallback, failure classification, or exit status.

A receipt is non-authoritative telemetry. It may be incomplete, mistaken, or deceptive. Claude must still:

1. inspect the actual repository state and diff;
2. enforce the brief's file boundary;
3. read the changed code;
4. run the acceptance commands independently;
5. decide whether to integrate, reject, or request another change.

## Greppy

Greppy is an optional managed code-navigation skill backed by a symbol graph and local semantic index.

- It is enabled by default for compatible coding workers.
- Compatible app harnesses are Claude Code, Codex CLI, and OpenCode.
- Launch injection occurs only for a repository-backed task when the exact local or remote target passes a bounded `greppy --version` health check.
- A configured default is not evidence that the binary is installed or healthy.
- A missing or broken Greppy command leaves the base brief unchanged and does not block the worker.
- Pi Code, Cursor Agent, and Grok CLI do not receive the Greppy prompt through the current compatibility catalog.
- The web-only research worker has Greppy disabled because it does not operate on a repository checkout.
- Workjet does not create a global `grep` alias. Ordinary `grep` remains the system command.

Remote managed installation is limited by the pinned artifact's supported OS and architecture and must pass digest and version checks before availability is advertised.

## Prompt transparency

The managed prompt exposes configured and effective skill state separately:

- **Configured** shows catalog defaults and per-worker overrides.
- **Effective** shows harness compatibility.
- **Available at launch** comes from a target-specific health check or verified remote capability.

The exact Greppy task prompt is stored in visible technical rules and injected as a marked task-input block. Missing or malformed source markers fail closed and prevent injection.

The completion receipt instructions are also visible in technical rules. They are not a hidden runtime prompt.

## Local telemetry

Local wrappers and CLI runs write bounded journals containing process identity, start time, worker identity where known, heartbeat, canonical run snapshot, and terminal markers. Workjet validates the current PID and process start token before treating a journal as active or sending `SIGTERM`.

A stale heartbeat, reused PID, malformed journal, or vanished process becomes interrupted or diagnostic state rather than remaining active indefinitely. Cleanup is conservative and retains ambiguous or live-owned journals.

Telemetry deliberately avoids treating arbitrary output files as canonical live streams. Harness-specific event support is reported only where the implementation can identify and validate it.

## Remote telemetry

Remote host state is authoritative for remote runs. Workjet uses typed list, adopt, event, and stop operations with stable worker ownership and an exclusive event cursor.

- Cursor advancement occurs only after validation.
- Duplicate replayed prefixes are deduplicated.
- Sequence gaps and regressions remain visible errors.
- Terminal states are sticky.
- Transport reconnect does not fabricate a local PID or local run directory.
- Stop must target the exact run and receive host or process evidence.

## Dispatcher outcomes

The shell dispatcher distinguishes delivery from availability and task failure:

| Exit | Meaning |
|---|---|
| `0` | Required worker delivered successfully |
| `3` | Required worker unavailable and no result delivered |
| `4` | Worker task failed; no fallback attempted |
| `10` | Explicitly authorized degraded worker delivered |
| `2` | Usage error |

A weaker worker is not silently substituted. Review has no automatic fallback. Attempt artifacts remain available for the orchestrator to inspect.

## Data sensitivity

Telemetry is designed not to copy complete stdout or stderr into completion metadata, but run directories can still contain sensitive repository paths, account labels, provider output, briefs, diffs, or accidental secret material. Inspect and redact every artifact before sharing it.
