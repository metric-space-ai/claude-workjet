# t3code remote integration notes

Stand: 4 August 2026. The primary source inspected was
[`pingdotgg/t3code` at `a261a6440ae7c1a063ff23591f43960c7d2b06e5`](https://github.com/pingdotgg/t3code/tree/a261a6440ae7c1a063ff23591f43960c7d2b06e5).

## What Workjet adapted

- **A server-owned remote runtime.** t3code's clients connect to one remote server over HTTP/WebSocket; the remote host owns projects, processes, terminals, provider sessions, and their authoritative state. Workjet retains its smaller SSH/Tailscale request protocol, but likewise treats host run state as authoritative rather than inferring it from a local SSH process. See t3code's [remote internals](https://github.com/pingdotgg/t3code/blob/a261a6440ae7c1a063ff23591f43960c7d2b06e5/docs/internals/remote.md) and [remote access guide](https://github.com/pingdotgg/t3code/blob/a261a6440ae7c1a063ff23591f43960c7d2b06e5/docs/user/remote-access.md).
- **Monotonic, exclusive event cursors.** t3code's orchestration store reads `sequence > sequenceExclusive`, orders ascending, and advances page-by-page from the last sequence. Workjet's `events` request uses the same exclusive-cursor rule, validates gaps/regressions, retains its cursor over transport reconnects, and deduplicates an identical already-delivered prefix without exposing it twice. See [`OrchestrationEventStore.ts`](https://github.com/pingdotgg/t3code/blob/a261a6440ae7c1a063ff23591f43960c7d2b06e5/apps/server/src/persistence/Layers/OrchestrationEventStore.ts).
- **Persisted resume/liveness facts.** t3code's provider session directory persists `resumeCursor` and `lastSeenAt`. Workjet keeps the cursor and an optional, host-supplied run heartbeat in its ledger. See [`ProviderSessionDirectory.ts`](https://github.com/pingdotgg/t3code/blob/a261a6440ae7c1a063ff23591f43960c7d2b06e5/apps/server/src/provider/Layers/ProviderSessionDirectory.ts).
- **Conservative stale-session cleanup.** t3code's reaper acts only after an explicit inactivity threshold and skips sessions with an active turn. Workjet requests a stop only when a non-terminal run has an explicit stale child-process heartbeat. A quiet output stream, elapsed wall time, or a successful host RPC is not treated as proof that a run is stale. See [`ProviderSessionReaper.ts`](https://github.com/pingdotgg/t3code/blob/a261a6440ae7c1a063ff23591f43960c7d2b06e5/apps/server/src/provider/Layers/ProviderSessionReaper.ts).

## Workjet-specific implementation

The Swift app now wires the already existing `probe -> start -> events -> stop` service operations into `WorkjetViewModel`. A probe must advertise `start`, `events-after-exclusive-cursor`, `stop`, and the selected harness before Workjet starts a run. Remote runs are represented separately from local PID telemetry, so Workjet does not fabricate a local PID, process identity, or run directory.

Reconnect retries only transport failures. Sequence gaps, cursor regressions, run-ID mismatches, malformed heartbeats, and terminal-state regressions remain visible protocol errors. Terminal remote states are sticky. Cursor advancement and event publication happen only after a response has passed validation.

Remote adapters remain deliberately limited to the host implementations present in Workjet: Claude Code, Pi Code, Codex CLI, and OpenCode. Cursor Agent and Grok CLI remain visibly blocked by `RemoteHarnessAdapterError.unsupportedHarness`; their configuration descriptors do not imply a working remote runtime.

## What Workjet does not claim

- Workjet is **not** a t3code client, does not implement t3code's Effect RPC/WebSocket contract, environment pairing, authentication sessions, terminal API, project model, or provider-session database.
- Workjet does **not** copy t3code code. It adapts the verified behavioral patterns above to Workjet's versioned JSON-over-SSH/Tailscale host protocol.
- The currently deployed Workjet host v1 does not emit a child-process `heartbeatAt`. The Swift protocol now accepts and tests that optional fact, but the app does not synthesize it from polling or output timestamps. Consequently, heartbeat-based ghost reaping activates only for a host response that truthfully supplies it; existing hosts continue to rely on terminal events/state and explicit stop.
- A configured executable or a UI harness descriptor is not evidence of remote support. The probe capability check and adapter registry are the runtime authority.
- Workjet does not claim t3code's WebSocket streaming behavior. Its event path is bounded polling with cursor-safe reconnect.

## Verification boundary

`RemoteHostProtocolTests` uses both a scripted transport and an injected `WorkjetService` to cover probe/start/events/stop, stale explicit heartbeat cleanup, reconnect without duplicate replay, sequence gaps, malformed/rejected responses, and unsupported harnesses. These tests prove Workjet's client and ViewModel behavior; they do not claim interoperability with a t3code server.
