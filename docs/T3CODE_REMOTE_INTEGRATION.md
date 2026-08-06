# t3code reference notes for Workjet's own remote runtime

Stand: 4 August 2026. The primary source inspected was
[`pingdotgg/t3code` at `a261a6440ae7c1a063ff23591f43960c7d2b06e5`](https://github.com/pingdotgg/t3code/tree/a261a6440ae7c1a063ff23591f43960c7d2b06e5).

## What Workjet adapted

- **A server-owned remote runtime.** t3code's clients connect to one remote server over HTTP/WebSocket; the remote host owns projects, processes, terminals, provider sessions, and their authoritative state. Workjet retains its smaller SSH/Tailscale request protocol, but likewise treats host run state as authoritative rather than inferring it from a local SSH process. See t3code's [remote internals](https://github.com/pingdotgg/t3code/blob/a261a6440ae7c1a063ff23591f43960c7d2b06e5/docs/internals/remote.md) and [remote access guide](https://github.com/pingdotgg/t3code/blob/a261a6440ae7c1a063ff23591f43960c7d2b06e5/docs/user/remote-access.md).
- **Monotonic, exclusive event cursors.** t3code's orchestration store reads `sequence > sequenceExclusive`, orders ascending, and advances page-by-page from the last sequence. Workjet's `events` request uses the same exclusive-cursor rule, validates gaps/regressions, retains its cursor over transport reconnects, and deduplicates an identical already-delivered prefix without exposing it twice. See [`OrchestrationEventStore.ts`](https://github.com/pingdotgg/t3code/blob/a261a6440ae7c1a063ff23591f43960c7d2b06e5/apps/server/src/persistence/Layers/OrchestrationEventStore.ts).
- **Persisted resume/liveness facts.** t3code's provider session directory persists `resumeCursor` and `lastSeenAt`. Workjet keeps the cursor and an optional, host-supplied run heartbeat in its ledger. See [`ProviderSessionDirectory.ts`](https://github.com/pingdotgg/t3code/blob/a261a6440ae7c1a063ff23591f43960c7d2b06e5/apps/server/src/provider/Layers/ProviderSessionDirectory.ts).
- **Conservative stale-session cleanup.** t3code's reaper acts only after an explicit inactivity threshold and skips sessions with an active turn. Workjet requests a stop only when a non-terminal run has an explicit stale child-process heartbeat. A quiet output stream, elapsed wall time, or a successful host RPC is not treated as proof that a run is stale. See [`ProviderSessionReaper.ts`](https://github.com/pingdotgg/t3code/blob/a261a6440ae7c1a063ff23591f43960c7d2b06e5/apps/server/src/provider/Layers/ProviderSessionReaper.ts).

## Workjet-specific implementation

This is a design reference, not an integration or interoperability layer. Fable
never invokes SSH, a remote runner, or a harness directly. Its complete worker
execution boundary is the stable Workjet CLI: `workjet workers list --json`,
`workjet workers describe <exact-name-or-uuid> --json`, `workjet run
<exact-name-or-uuid> --brief-file <path> --json`, `workjet events <run-id>
--after <exclusive-sequence> --json`, and `workjet stop <run-id> --json`.

The Swift app wires `probe -> start -> list/adopt -> events -> stop` into the production service and `WorkjetViewModel`. Every start carries a stable owner derived from the persisted worker UUID. After an app restart, Workjet lists host-owned runs and adopts only a single exact owner match; ownerless, foreign, ambiguous, or conflicting runs are never guessed from names or models. Remote runs remain separate from local PID telemetry, so Workjet does not fabricate a local PID, process identity, or run directory.

Reconnect retries only transport failures. Sequence gaps, cursor regressions, run-ID mismatches, malformed heartbeats, and terminal-state regressions remain visible protocol errors. Terminal remote states are sticky. Cursor advancement and event publication happen only after a response has passed validation.

Remote adapters remain deliberately limited to the host implementations present in Workjet: Claude Code, Pi Code, Codex CLI, and OpenCode. The v2 host additionally exposes typed harness inspect/install/update/remove operations. The client sends only a harness ID and action; executable paths and argv are selected from fixed host-side allowlists, never accepted from the client and never passed through a shell string. Pi maintenance remains tied to Workjet's content-addressed deployment. Cursor Agent and Grok CLI are inspect-only until a verified protocol runtime exists.

Provider routing also stays Workjet-owned. Direct API accounts retain a
deterministic order and advance only after a classified authentication, quota,
or network failure; task failures do not advance the pool. CLIProxy OAuth
accounts are exposed as one proxy-managed gateway pool, because CLIProxy - not
Workjet - selects the concrete OAuth account and Workjet cannot pin it per
request. For remote runs, Workjet creates a run-scoped loopback relay and an
ephemeral gateway access secret. Direct API credentials are delivered only
through the encrypted request/monitor pipe. OAuth files, OAuth tokens, and
Keychain contents are never copied to or persisted on the remote host, and the
run secret is not persisted either.

## What Workjet does not claim

- Workjet is **not** a t3code client, does not implement t3code's Effect RPC/WebSocket contract, environment pairing, authentication sessions, terminal API, project model, or provider-session database.
- Workjet does **not** copy t3code code. It adapts the verified behavioral patterns above to Workjet's versioned JSON-over-SSH/Tailscale host protocol.
- Existing host-v1 installations remain decodable, but do not gain v2 ownership, adoption, heartbeat, bounded retention, or harness lifecycle capabilities. These features become available only after an explicit content-addressed host update; the app does not synthesize them from polling or output timestamps.
- A configured executable or a UI harness descriptor is not evidence of remote support. The probe capability check and adapter registry are the runtime authority.
- Workjet does not claim t3code's WebSocket streaming behavior. Its event path is bounded polling with cursor-safe reconnect.

## Verification boundary

`RemoteHostProtocolTests` and `RemoteHostV2Tests` cover probe/start/list/adopt/events/stop, stable ownership, restart adoption, heartbeat cleanup, bounded retention and recoverable cursor gaps, PID-start identity, TERM/KILL stop, typed harness maintenance, command-injection rejection, malformed responses, and unsupported harnesses. These tests prove Workjet's own client/host behavior; they do not claim interoperability with a t3code server. A real remote-machine smoke remains separate release evidence.
