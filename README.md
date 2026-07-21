# claude-workjet

Get shit done with coding agents — Michael Welsch's Claude Code "workjet" setup.

Runs GPT-5.6, MiniMax M3, and Kimi K3 as headless workers inside Claude Code.

Each worker is a small zsh wrapper around the standard `claude` CLI: it sets its own `CLAUDE_CONFIG_DIR`, authenticates against an Anthropic-compatible endpoint via env vars, and runs `claude --bare`. A worker invocation is a single process — brief in via `-p`, report out on stdout. `claude-agent` is a role-based dispatcher with explicit degradation and failure semantics. `AGENTS.md` is the orchestrator prompt for the Claude session that coordinates the workers. The default installer loads it only through `/workjet`; the repository's `CLAUDE.md` import supports project-local or opt-in global use.

## Roles

| Agent | Role |
|---|---|
| **Claude** — your Claude Code session | **Orchestrator.** Decomposes the task, writes the briefs, routes work, integrates results, verifies everything, does the final edit, tracks the progress — for larger runs on an HTML progress board (event-driven updates, defined in AGENTS.md). Does not do the bulk production work itself. |
| **GPT-5.6 "Sol"** — `claude-sol` | **Completion engine.** Hard, detail-heavy, must-not-fail implementation work. Follows a precise brief relentlessly; tends to over-deliver, which the brief's whitelist bounds. Also owns edits to existing frontend and frontend↔backend wiring. |
| **MiniMax M3** — `claude-minimax` | **Bulk worker.** Clear, repetitive, high-volume work: generation, classification, judging, test writing. Write-only on files, never Edit, never git. |
| **Kimi K3** — `claude-kimi` | **Frontend lead and independent reviewer.** Greenfield UI/design work from scratch; reviews substantial integrations and the orchestrator's final edits; resolves disputes between agents. |
| **Claude Opus 4.8** — `claude-opus` | **Quota fallback.** Steps in automatically when a role's worker is down on quota/auth; long-lived subscription token via `claude setup-token`. Announced loudly, never silent. |
Review model: the orchestrator self-reviews adversarially by default; Kimi reviews independently and resolves disputes. The full role split, brief format, and operating rules are the content of [AGENTS.md](AGENTS.md).

## Components

| File | Purpose |
|---|---|
| `bin/claude-sol` | GPT-5.6 (reasoning high) via a local CLIProxyAPI bridge; ChatGPT Pro subscription |
| `bin/claude-minimax` | MiniMax M3; MiniMax coding plan |
| `bin/claude-kimi` | Kimi K3 (1M context); Kimi coding plan |
| `bin/claude-agent` | Role-based dispatcher: probes the required worker, degrades only with explicit authorization |
| `bin/claude-fleet` | Multi-brief runner: delegates through `claude-agent`, with a global three-slot provider semaphore |
| `AGENTS.md` | Orchestrator prompt: role split, brief format, review model, operating rules |
| `CLAUDE.md` | One line: `@AGENTS.md` — Claude Code imports the canonical prompt |
| `skills/workjet/` | Claude Code skill: `/workjet` switches the session into workjet orchestration for the current task |
| `install.sh` | Copies wrappers, installs the skill-only rules by default, and creates key-file skeletons |

Any subset works; install only the wrappers you have subscriptions for.

## Design

- **One process per job.** Briefs and reports are files; every run can be inspected and replayed. MiniMax and Kimi talk directly to their Anthropic-compatible endpoints — key file, nothing else. Sol is the exception: ChatGPT Pro has no Anthropic-compatible API, so it needs one piece of infrastructure — [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), a local service that bridges the Anthropic API to the Codex API and holds the ChatGPT OAuth login (setup step 4). This setup was tested with [CLIProxyAPI 7.2.85](https://github.com/router-for-me/CLIProxyAPI/releases/tag/v7.2.85).
- **Isolation via `--bare`.** Workers load no global or project `CLAUDE.md`, no hooks, no plugins, and use no interactive login. `CLAUDE_CONFIG_DIR` alone does not prevent prompt auto-discovery (`~/.claude` is resolved through the system user database); `--bare` does. Task context goes into the brief.
- **Subscription billing.** All workers run on flat-rate plans through their Anthropic-compatible APIs.
- **Explicit failure.** Quota and auth walls surface as distinct dispatcher exit codes. A weaker model is never substituted for a stronger one without an explicit `--degrade` flag and a marked result.

## Setup

Ordered steps; each ends with a check. Steps marked **HUMAN** require input an automated agent cannot obtain itself (API keys, a browser OAuth flow) — everything else is scriptable. All steps are idempotent.

### 0. Preconditions

```sh
command -v claude && command -v git && command -v zsh && command -v python3
```

Check: four paths. `claude` must be installed and logged in once (interactive `claude`). `python3` provides the process-session fallback on platforms without `setsid`.

### 1. Install

```sh
git clone https://github.com/metric-space-ai/claude-workjet /tmp/claude-workjet
cd /tmp/claude-workjet && ./install.sh
```

Check: `ls ~/.local/bin/claude-{sol,minimax,kimi,agent,fleet}` prints five paths, and `~/.local/bin` is on `PATH`.

### 2. MiniMax (skip without subscription)

**HUMAN:** MiniMax coding-plan API key (platform.minimax.io).

```sh
mkdir -p ~/.config/secrets
printf '%s\n' "KEY" > ~/.config/secrets/minimax-key
chmod 600 ~/.config/secrets/minimax-key
```

Check: `claude-minimax -p "Reply with the token: OK" < /dev/null` returns `OK`. On an auth error, the key is wrong — do not retry in a loop. Existing `~/.config/secrets/minimax.env` installations remain readable without sourcing, but should migrate to `minimax-key`.

### 3. Kimi (skip without subscription)

**HUMAN:** Kimi-Code API key (kimi.com/code).

```sh
mkdir -p ~/.config/kimi
printf '%s\n' "KEY" > ~/.config/kimi/api-key
chmod 600 ~/.config/kimi/api-key
```

Check: `claude-kimi -p "Reply with the token: OK" < /dev/null` returns `OK`.

### 4. Sol (skip without ChatGPT Pro)

[router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) bridges the Anthropic API to the Codex API using the ChatGPT login. The upstream owner was verified with `gh repo view` on 2026-07-20. Install a known-good Homebrew release, record the installed version, and pin it after verification so an unattended upgrade cannot silently change the local authentication boundary. Tested with [CLIProxyAPI 7.2.85](https://github.com/router-for-me/CLIProxyAPI/releases/tag/v7.2.85) from Homebrew.

```sh
brew install cliproxyapi
brew info cliproxyapi                 # record the installed version
brew pin cliproxyapi                  # after the smoke test is green
```

Before starting the service, edit `/opt/homebrew/etc/cliproxyapi.conf`. The following security settings are mandatory:

```yaml
host: "127.0.0.1"
port: 8317
remote-management:
  allow-remote: false
  disable-control-panel: true
plugins:
  enabled: false
```

The upstream default `host: ""` binds on all interfaces. Explicit loopback binding prevents exposing the subscription-backed proxy to the LAN; remote management, the control panel, and plugins are disabled to minimize the local attack surface.

**HUMAN:** `cliproxyapi -codex-login` (browser OAuth; not possible headlessly).

```sh
brew services start cliproxyapi
lsof -nP -iTCP:8317 -sTCP:LISTEN
```

Check: the listener is specifically on `127.0.0.1:8317`, not `*:8317` or `[::]:8317`.

Choose a random local secret and set the same value in the CLIProxyAPI config (`/opt/homebrew/etc/cliproxyapi.conf`) and as the single line in `~/.config/secrets/sol-key`; then run `chmod 600 ~/.config/secrets/sol-key`. It is only used on loopback.

Check: `claude-sol -p "Reply with the token: OK" < /dev/null` returns `OK`.

### 5. Orchestrator mode

The default install is **skill-only**. `install.sh` copies the rules to `~/.claude/workjet/AGENTS.md` (not auto-loaded) and installs `/workjet`. It does not modify the global `~/.claude/CLAUDE.md`.

```sh
test -f ~/.claude/workjet/AGENTS.md
test -f ~/.claude/skills/workjet/SKILL.md
```

Check: start Claude Code and invoke `/workjet <task>`; the skill reads the workjet rules for that task only.

To make workjet the global prompt for every Claude Code session, opt in explicitly:

```sh
cd /tmp/claude-workjet
./install.sh --global-prompt
```

Global mode backs up existing `~/.claude/CLAUDE.md` and `~/.claude/AGENTS.md` with timestamped `.bak-workjet-*` names, installs the canonical prompt as `~/.claude/AGENTS.md`, and writes the one-line `@AGENTS.md` redirect. Merge any pre-existing rules from the backups into the new `AGENTS.md`, review the diff, and keep `CLAUDE.md` as the one-line import.

### 6. Smoke test

```sh
claude-agent bulk-generation -p "Reply with the token: OK" < /dev/null; echo "exit=$?"
```

Check: output contains `OK`, exit 0, stderr names the answering worker.

## Usage

### Triggering workjet

In any Claude Code session: `/workjet <task>` (or just say "workjet"). The skill reads `~/.claude/workjet/AGENTS.md` and activates the orchestration mode for that task — decompose, route to the fleet, brief per standard, track on the board, verify, final edit. Installed by `install.sh` to `~/.claude/skills/workjet/` without changing the global prompt.

### Spawning a worker

```sh
claude-sol -p "$(cat brief.md)" --allowedTools "Read,Write,Edit,Grep,Glob,Bash" < /dev/null
```

`< /dev/null` prevents a worker that asks a question from blocking forever. For long jobs, run in the background and read the output file.

Brief format (defined in `AGENTS.md`): hard file whitelist, acceptance criteria as exact commands, an escape-hatch clause (stop and justify instead of widening scope), a structured report tail, no subagents. Workers cannot be steered mid-run; all precision goes into the brief.

### Dispatcher

```sh
claude-agent <role> [claude args...]
claude-agent --degrade <role> [claude args...]
claude-agent --no-isolate <role> [claude args...]
claude-agent --include-dirty <role> [claude args...]
claude-agent --allowed-paths 'src/**,tests/**' <role> [claude args...]
claude-agent runs mark <run-id> integrated|abandoned
```

The first worker in each chain is **required**: it is the only worker that fully satisfies the role. Every later worker is provisional and is invoked only with `--degrade`.

| Role | Chain |
|---|---|
| `implementation-hard` | Sol → Kimi |
| `frontend-greenfield` | Kimi → Sol |
| `frontend-integration` | Sol → Kimi |
| `bulk-generation` | MiniMax → Kimi → Sol |
| `review` | Kimi only; no automatic fallback — on outage, exit 3 and defer review |
| `research` | Kimi → Sol → MiniMax |

Legacy aliases remain temporarily available and print a deprecation notice: `hard` → `implementation-hard`, `normal` → `research`, `simple` → `bulk-generation`.

Unless the caller supplies `--allowedTools` or `--tools`, the dispatcher injects role policy into task calls: `review` is limited to `Read,Grep,Glob` and explicitly denies `Write,Edit,Bash`; `bulk-generation` explicitly denies `Edit`; implementation, frontend, and research roles receive the full `Read,Write,Edit,Grep,Glob,Bash` set. Explicit caller tool flags take precedence.

`--allowed-paths 'glob1,glob2'` audits the actual post-run diff. Out-of-policy paths are written to `path-violations.txt` in the run directory and reported on stderr. This is a non-blocking flag: the dispatcher preserves the result and exit code so the orchestrator can inspect and decide.

Workers are probed with a short timeout (default 25 s, `AGENT_PROBE_TIMEOUT`) before the job runs under a generous cap (default 1800 s, `AGENT_TIMEOUT`). In a Git repository, each delivery runs in a detached worktree under `~/.local/state/workjet/worktrees/<repo-id>/<run-id>`; the repository checkout is never populated with dispatcher state. The main checkout must be clean. To transfer staged, unstaged, and untracked changes intentionally, pass `--include-dirty`; the dispatcher archives a binary patch in the run directory and applies it to the worker worktree. Use `--no-isolate` only when in-place execution is intentional.

After a successful isolated delivery, all worktree changes are committed and protected by `refs/workjet/<run-id>`. The worktree remains for inspection and integration. Automatic stale cleanup removes it only after the run is explicitly marked `integrated` or `abandoned`; unmarked worktrees are warned about and retained:

```sh
claude-agent runs mark <run-id> integrated
claude-agent runs mark <run-id> abandoned
```

Every invocation records its brief and final result under `~/.local/state/workjet/runs/<timestamp>-<role>/`: `brief.txt`, `stdout`, `stderr`, `rc`, `worker`, `run-id`, and `worktree-path`, plus `git-head-before`, `git-head-after`, `diffstat`, `protected-ref`, and `protected-sha` when applicable. Every probe and task invocation also has an immutable `attempts/NN-<worker>/` directory containing its `kind`, `rc`, `stdout`, and `stderr`, so degradation chains never overwrite evidence. The path is printed on stderr at exit. Use `--run-dir DIR` to select an explicit location.

| Exit | Meaning |
|---|---|
| 0 | Delivered by the role's required worker; stderr names it |
| 3 | `PRIMARY_UNAVAILABLE`: required worker unavailable and no result delivered — re-plan; for `review`, defer the independent review |
| 4 | `TASK_FAILED`: worker returned a non-provider task error; no fallback attempted |
| 10 | Degraded result (only with `--degrade`), banner-marked — verify and disclose before use |
| 2 | Usage error |

### Fleet runner

```sh
claude-fleet <role> brief1.md [brief2.md ...]
```

Each brief is a separate `claude-agent` run with its own run directory and isolated worktree. `claude-fleet` uses a shared flock semaphore under `~/.local/state/workjet/sem/<provider>.lock/` and enforces at most three concurrent calls per provider across fleet processes. Set `WORKJET_PROVIDER_SLOTS=1..3` to lower the cap; values above three are rejected. A provider failure (`claude-agent` exit 3, including 403/quota/auth failures) stops queued briefs for that provider, while task failures (exit 4) do not stop the queue. The final table reports status, run directory, and worktree for every brief.

### Operating rules

- Use `claude-fleet` for parallel briefs; it technically enforces concurrency ≤ 3 per provider and stops queued work on a 403/quota wall.
- Verify worker results independently (run the tests, check the diff against the whitelist).
- MiniMax writes new files only — no Edit, no git.

## Testing

Run the pure-zsh dispatcher suite without real provider calls:

```sh
./tests/dispatcher_test.zsh
```

The suite injects stub workers through `AGENT_BIN_DIR` and covers error classification, degradation, immutable attempt artifacts, process-group timeout cleanup, dirty-checkout handling, protected refs, safe stale-worktree cleanup, path auditing, review tool policy, and fleet semaphore serialization. The current setup was tested with Claude Code **2.1.215** (`claude --version`) and zsh 5.9 on macOS.

## Known limits

- Worktrees and Claude Code tool policy are not a full OS sandbox. Workers do not have enforced filesystem namespaces or network isolation.
- Provider failure classification currently uses exit status plus regex matching on CLI stderr. Structured CLI error output is the roadmap; until then, new provider wording may require classifier updates.

## Notes

- Prompt-override instructions are not reliably honored by weaker models; `--bare` is the isolation mechanism, not a system-prompt instruction.
- Headless `claude` children spawned from a session cannot access macOS Keychain/OAuth logins. All wrapper auth is therefore env-var or key-file based; the ChatGPT OAuth in step 4 is the only interactive step.
- GPT-5.6 tends to over-deliver (extra abstractions, files, scope). The whitelist and acceptance criteria in the brief bound this; deciding what is unnecessary stays with the orchestrator.

## License

MIT
