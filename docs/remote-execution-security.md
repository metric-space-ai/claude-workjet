# Remote execution and security

Workjet runs supported harnesses on computers reached through strict OpenSSH. Tailscale can provide device discovery and the encrypted network path, but Workjet still uses the same host-key-verified SSH command path.

## Trust setup

A remote computer is not trusted merely because it appears in Tailscale or answers on port 22.

1. Workjet scans the SSH host key without treating the scan as approval.
2. The user compares and explicitly confirms the fingerprint.
3. Workjet writes the confirmed entry to its private known-hosts file.
4. Every remote command uses `StrictHostKeyChecking=yes` and that explicit `UserKnownHostsFile`.
5. `BatchMode=yes`, `ClearAllForwardings=yes`, and `ForwardAgent=no` are enforced.
6. If an identity file is configured, Workjet uses `IdentitiesOnly=yes` and passes the local absolute path directly to OpenSSH.

There is no `StrictHostKeyChecking=no` fallback. A changed or unknown key blocks setup or execution until the user resolves the trust change.

## Repository transport

Repository-backed Claude Code, Codex CLI, and OpenCode runs use an immutable snapshot of the invoking Git worktree.

The snapshot includes:

- tracked files at the current `HEAD`;
- tracked edits and deletions;
- non-ignored untracked files;
- a generated snapshot commit and SHA-256 manifest.

The raw Git bundle is capped at 64 MiB. Workjet sends the manifest and bundle bytes over the verified SSH connection. The host checks the size, hash, Git bundle structure, and advertised commit before creating a detached worktree.

The remote computer does not clone or fetch the origin. It does not need:

- a GitHub account;
- GitHub or other Git-hosting credentials;
- the origin URL;
- network access to the origin;
- a forwarded SSH agent.

The source repository's local path remains in private local state and is not sent to the host.

Pi Code is different. It keeps its bounded in-memory turn request and does not receive a repository worktree through this path.

## Result transport

After a terminal repository-backed shell-harness run, the remote host can create an immutable result commit and Git bundle. The local importer validates:

- run, repository, and snapshot identities;
- manifest shape and byte bounds;
- SHA-256 digest;
- Git bundle verification and advertised result commit;
- ancestry from the original snapshot.

A successful import writes only:

```text
refs/workjet/<run-id>
```

Import does not checkout, merge, rebase, stage, modify `HEAD`, or write into the working tree. `integrated` means the verified ref was imported and the remote worktree may be cleaned. It does not mean the result was merged or pushed.

```sh
workjet result import <run-id> [--json]
workjet runs mark <run-id> integrated|abandoned [--json]
```

Unmarked terminal worktrees are retained for recovery.

## Remote runtime

The remote host runtime is generated from pinned repository inputs and deployed content-addressably. Typed operations cover probing, run lifecycle, event reads, stop, workspace import/result, and supported harness maintenance.

The client sends a harness identifier and typed fields. Host-side allowlists select executables and arguments. The protocol does not accept an arbitrary shell string from the app.

Currently represented remote start adapters are Claude Code, Pi Code, Codex CLI, and OpenCode. Cursor Agent and Grok CLI can be inspected through lifecycle support but are not represented as verified remote start adapters. A UI descriptor or installed executable alone is not runtime proof.

## Provider credentials

Provider routing remains Workjet-owned.

- Direct API credentials are read from Keychain when explicitly needed.
- Remote direct API secrets are delivered only through the run's encrypted request and monitor path.
- CLIProxy-backed OAuth uses a run-scoped loopback relay with an ephemeral access secret.
- OAuth files, OAuth tokens, Keychain contents, and run secrets are not copied to or persisted on the remote host.
- CLIProxy may manage multiple OAuth accounts as one gateway pool. Workjet does not claim per-request pinning when the gateway does not expose it.

Remote machines therefore do not need provider credential files copied from the Mac.

## Sandbox boundary

Worktrees and fixed command construction reduce accidental scope, but they are not a full OS sandbox.

For supported remote Pi Code deployments, Workjet can require Bubblewrap. When enabled and verified, the daemon receives a read-only host filesystem view and a private writable turn directory while retaining network access needed for the model gateway. If Bubblewrap was requested but cannot be confirmed, Workjet blocks the run rather than silently continuing without it.

When the OS sandbox is disabled, the app keeps that weaker boundary visible. Do not describe a non-sandboxed harness as isolated merely because its prompt or worktree is bounded.

## Telemetry and reconnect

The host owns authoritative remote run state. Events use a monotonic, exclusive sequence cursor. Workjet validates gaps, regressions, run-ID mismatches, malformed heartbeats, and terminal-state regressions before publishing events or advancing the cursor.

Reconnect retries transport failures. A quiet output stream is not proof that a run is stale. Cleanup uses explicit terminal state, ownership, heartbeat, and disposition rules.

## Operational checklist

Before using a real remote computer:

- verify the host fingerprint through an independent channel;
- use a dedicated unprivileged SSH user;
- keep the private known-hosts and identity files owner-only;
- install only the harnesses needed on that host;
- confirm Git and required runtime versions through Workjet's probe;
- enable and test Bubblewrap for Pi Code when the stronger filesystem boundary is required;
- review the result ref and diff locally before integration;
- mark a run integrated or abandoned only after that review.
