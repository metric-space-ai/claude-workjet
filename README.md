# claude-workjet

Get shit done with coding agents — Michael Welsch's Claude Code "workjet" setup.

Runs GPT-5.6, MiniMax M3, and Kimi K3 as headless workers inside Claude Code.

Each worker is a small zsh wrapper around the standard `claude` CLI: it sets its own `CLAUDE_CONFIG_DIR`, authenticates against an Anthropic-compatible endpoint via env vars, and runs `claude --bare`. A worker invocation is a single process — brief in via `-p`, report out on stdout. `claude-agent` is a dispatcher that adds tiered fallback with explicit failure semantics. `AGENTS.md` is the orchestrator prompt for the Claude session that coordinates the workers (`CLAUDE.md` just imports it, so the same prompt also serves agents that read AGENTS.md natively).

## Roles

| Agent | Role |
|---|---|
| **Claude** — your Claude Code session | **Orchestrator.** Decomposes the task, writes the briefs, routes work, integrates results, verifies everything, does the final edit, tracks the progress — for larger runs on an HTML progress board (event-driven updates, defined in AGENTS.md). Does not do the bulk production work itself. |
| **GPT-5.6 "Sol"** — `claude-sol` | **Completion engine.** Hard, detail-heavy, must-not-fail implementation work. Follows a precise brief relentlessly; tends to over-deliver, which the brief's whitelist bounds. Also owns edits to existing frontend and frontend↔backend wiring. |
| **MiniMax M3** — `claude-minimax` | **Bulk worker.** Clear, repetitive, high-volume work: generation, classification, judging, test writing. Write-only on files, never Edit, never git. |
| **Kimi K3** — `claude-kimi` | **Frontend lead and independent reviewer.** Greenfield UI/design work from scratch; reviews substantial integrations and the orchestrator's final edits; resolves disputes between agents. |
Review model: the orchestrator self-reviews adversarially by default; Kimi reviews independently and resolves disputes. The full role split, brief format, and operating rules are the content of [AGENTS.md](AGENTS.md).

## Components

| File | Purpose |
|---|---|
| `bin/claude-sol` | GPT-5.6 (reasoning high) via a local CLIProxyAPI bridge; ChatGPT Pro subscription |
| `bin/claude-minimax` | MiniMax M3; MiniMax coding plan |
| `bin/claude-kimi` | Kimi K3 (1M context); Kimi coding plan |
| `bin/claude-agent` | Dispatcher: probes workers, falls back by capability tier, never downgrades silently |
| `AGENTS.md` | Orchestrator prompt: role split, brief format, review model, operating rules |
| `CLAUDE.md` | One line: `@AGENTS.md` — Claude Code imports the canonical prompt |
| `skills/workjet/` | Claude Code skill: `/workjet` switches the session into workjet orchestration for the current task |
| `install.sh` | Copies the wrappers to `~/.local/bin`, installs the skill, creates key-file skeletons |

Any subset works; install only the wrappers you have subscriptions for.

## Design

- **One process per job.** Briefs and reports are files; every run can be inspected and replayed. MiniMax and Kimi talk directly to their Anthropic-compatible endpoints — key file, nothing else. Sol is the exception: ChatGPT Pro has no Anthropic-compatible API, so it needs one piece of infrastructure — [CLIProxyAPI](https://github.com/luispater/CLIProxyAPI), a local service that bridges the Anthropic API to the Codex API and holds the ChatGPT OAuth login (setup step 4).
- **Isolation via `--bare`.** Workers load no global or project `CLAUDE.md`, no hooks, no plugins, and use no interactive login. `CLAUDE_CONFIG_DIR` alone does not prevent prompt auto-discovery (`~/.claude` is resolved through the system user database); `--bare` does. Task context goes into the brief.
- **Subscription billing.** All workers run on flat-rate plans through their Anthropic-compatible APIs.
- **Explicit failure.** Quota and auth walls surface as distinct dispatcher exit codes. A weaker model is never substituted for a stronger one without an explicit `--degrade` flag and a marked result.

## Setup

Ordered steps; each ends with a check. Steps marked **HUMAN** require input an automated agent cannot obtain itself (API keys, a browser OAuth flow) — everything else is scriptable. All steps are idempotent.

### 0. Preconditions

```sh
command -v claude && command -v git && command -v zsh
```

Check: three paths. `claude` must be installed and logged in once (interactive `claude`).

### 1. Install

```sh
git clone https://github.com/metric-space-ai/claude-workjet /tmp/claude-workjet
cd /tmp/claude-workjet && ./install.sh
```

Check: `ls ~/.local/bin/claude-{sol,minimax,kimi,agent}` prints four paths, and `~/.local/bin` is on `PATH`.

### 2. MiniMax (skip without subscription)

**HUMAN:** MiniMax coding-plan API key (platform.minimax.io).

```sh
mkdir -p ~/.config/secrets
printf 'export MINIMAX_API_KEY="%s"\n' "KEY" > ~/.config/secrets/minimax.env
chmod 600 ~/.config/secrets/minimax.env
```

Check: `claude-minimax -p "Reply with the token: OK" < /dev/null` returns `OK`. On an auth error, the key is wrong — do not retry in a loop.

### 3. Kimi (skip without subscription)

**HUMAN:** Kimi-Code API key (kimi.com/code).

```sh
mkdir -p ~/.config/kimi
printf '%s\n' "KEY" > ~/.config/kimi/api-key
chmod 600 ~/.config/kimi/api-key
```

Check: `claude-kimi -p "Reply with the token: OK" < /dev/null` returns `OK`.

### 4. Sol (skip without ChatGPT Pro)

CLIProxyAPI bridges the Anthropic API to the Codex API using the ChatGPT login.

```sh
brew install cliproxyapi
```

**HUMAN:** `cliproxyapi -codex-login` (browser OAuth; not possible headlessly).

```sh
brew services start cliproxyapi
lsof -nP -iTCP:8317 -sTCP:LISTEN
```

Check: listener on `127.0.0.1:8317`.

Choose a random local secret and set the same value in the CLIProxyAPI config (`/opt/homebrew/etc/cliproxyapi.conf`) and in `~/.local/bin/claude-sol` (both occurrences of `sol-local-CHANGE-ME`). It is only used on loopback.

Check: `claude-sol -p "Reply with the token: OK" < /dev/null` returns `OK`.

### 5. Orchestrator prompt

```sh
test -f ~/.claude/CLAUDE.md && cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.bak-workjet
cp /tmp/claude-workjet/AGENTS.md ~/.claude/AGENTS.md
printf '@AGENTS.md\n' > ~/.claude/CLAUDE.md
```

If a `CLAUDE.md` already exists, keep its rules: merge them into `~/.claude/AGENTS.md` (the canonical file) instead of overwriting, and show the diff. `CLAUDE.md` stays the one-line import.

Check: `grep -c claude-sol ~/.claude/AGENTS.md` ≥ 1 and `cat ~/.claude/CLAUDE.md` prints `@AGENTS.md`.

### 6. Smoke test

```sh
claude-agent simple -p "Reply with the token: OK" < /dev/null; echo "exit=$?"
```

Check: output contains `OK`, exit 0, stderr names the answering worker.

## Usage

### Triggering workjet

In any Claude Code session: `/workjet <task>` (or just say "workjet"). The skill activates the orchestration mode — decompose, route to the fleet, brief per standard, track on the board, verify, final edit. Installed by `install.sh` to `~/.claude/skills/workjet/`.

### Spawning a worker

```sh
claude-sol -p "$(cat brief.md)" --allowedTools "Read,Write,Edit,Grep,Glob,Bash" < /dev/null
```

`< /dev/null` prevents a worker that asks a question from blocking forever. For long jobs, run in the background and read the output file.

Brief format (defined in `AGENTS.md`): hard file whitelist, acceptance criteria as exact commands, an escape-hatch clause (stop and justify instead of widening scope), a structured report tail, no subagents. Workers cannot be steered mid-run; all precision goes into the brief.

### Dispatcher

```sh
claude-agent <hard|normal|simple> [claude args...]
claude-agent --degrade <role> [claude args...]
```

Chains: `hard` sol→kimi→minimax, `normal` kimi→sol→minimax, `simple` minimax→kimi→sol. Workers are probed with a short timeout (default 25 s, `AGENT_PROBE_TIMEOUT`) before the job runs under a generous cap (default 1800 s, `AGENT_TIMEOUT`). In a Git repository, each delivery runs in a detached `.workjet/wt-*` worktree by default. Successful worktrees are retained for orchestrator inspection and integration; failed or timed-out worktrees are discarded before fallback. Use `--no-isolate` only when in-place execution is intentional.

| Exit | Meaning |
|---|---|
| 0 | Delivered by a worker at or above the required tier; stderr names it |
| 3 | `PRIMARY_UNAVAILABLE`: only lower-tier workers reachable, nothing delivered — re-plan |
| 10 | Degraded result (only with `--degrade`), banner-marked — verify before use |
| 2 | Usage error |

### Operating rules

- Concurrency ≤ 3 per provider; a 403/quota wall means stop, not retry.
- Verify worker results independently (run the tests, check the diff against the whitelist).
- MiniMax writes new files only — no Edit, no git.

## Notes

- Prompt-override instructions are not reliably honored by weaker models; `--bare` is the isolation mechanism, not a system-prompt instruction.
- Headless `claude` children spawned from a session cannot access macOS Keychain/OAuth logins. All wrapper auth is therefore env-var or key-file based; the ChatGPT OAuth in step 4 is the only interactive step.
- GPT-5.6 tends to over-deliver (extra abstractions, files, scope). The whitelist and acceptance criteria in the brief bound this; deciding what is unnecessary stays with the orchestrator.

## License

MIT
