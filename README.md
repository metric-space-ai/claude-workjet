# claude-workjet

Multi-agent orchestration for Claude Code with zero infrastructure: your Claude session orchestrates three headless worker LLMs — each a flat-rate subscription driven through the stock `claude` CLI by a ~30-line shell wrapper. No MCP servers, no framework, no per-token API bills. Workflows flow; a workjet has thrust.

This is the setup we run in production daily. Every rule in here was earned, not designed: the isolation flag exists because prompt leakage actually happened, the no-silent-downgrade rule exists because a quota wall actually swallowed a hard task, the brief standard exists because a worker actually rewrote files it had no business touching.

## The fleet

| Worker | Role | Model | Billing |
|---|---|---|---|
| `claude-sol` | **Completion engine.** Difficult, detail-heavy, must-not-fail work. Follows a precise brief relentlessly. | GPT-5.6 (reasoning high) via [CLIProxyAPI](https://github.com/luispater/CLIProxyAPI) | ChatGPT Pro subscription |
| `claude-minimax` | **Bulk worker.** Clear, repetitive, high-volume work: generation, classification, judging. | MiniMax M3 | MiniMax coding plan |
| `claude-kimi` | **Frontend lead & independent reviewer.** Greenfield UI/design, reviews, dispute resolution. | Kimi K3 (1M context) | Kimi coding plan |
| *(your session)* | **Orchestrator.** Decomposes, briefs, integrates, verifies, does the final edit. | Claude | your Claude subscription |

The division of labor, review tiers, brief standard, and progress-board duty live in [CLAUDE.md](CLAUDE.md) — the orchestrator prompt. Install it as your global `~/.claude/CLAUDE.md` and your Claude session runs the fleet by itself.

## Why this beats a framework

- **A worker run is a process.** Brief in via `-p`, report out on stdout, exit code tells you what happened. Everything is a file you can audit, diff, and replay. No protocol layer to debug at 2am.
- **Total isolation.** Each wrapper sets its own `CLAUDE_CONFIG_DIR` and runs `claude --bare`. Workers never see your orchestrator prompt, your project's CLAUDE.md, your hooks, or your login. (`--bare` is the only robust fix: Claude resolves `~/.claude` through the system user database, so neither `CLAUDE_CONFIG_DIR` nor `HOME` suppresses prompt auto-discovery.)
- **Flat-rate economics.** Three subscriptions, unlimited iteration mentality. The dispatcher treats quota walls as first-class events instead of surprise bills.
- **Failure is loud.** `claude-agent` never silently swaps a weaker model in for a hard task. It refuses (exit 3) and tells the orchestrator to re-plan, or — only with an explicit `--degrade` — delivers a banner-tagged provisional result (exit 10).

## Install

Prerequisites: [Claude Code CLI](https://claude.com/claude-code) installed and logged in; zsh; the subscriptions you want to use (any subset works — the wrappers are independent).

```sh
git clone https://github.com/metric-space-ai/claude-workjet
cd claude-workjet
cp bin/* ~/.local/bin/        # or run ./install.sh
chmod +x ~/.local/bin/claude-sol ~/.local/bin/claude-minimax ~/.local/bin/claude-kimi ~/.local/bin/claude-agent
cp CLAUDE.md ~/.claude/CLAUDE.md   # the orchestrator prompt (merge if you already have one)
```

### Keys and endpoints

**MiniMax** — put your coding-plan key in `~/.config/secrets/minimax.env`:

```sh
mkdir -p ~/.config/secrets
echo 'export MINIMAX_API_KEY="YOUR_KEY"' > ~/.config/secrets/minimax.env
chmod 600 ~/.config/secrets/minimax.env
```

**Kimi** — put your Kimi-Code key in `~/.config/kimi/api-key` (the raw key, one line, `chmod 600`).

**Sol (GPT-5.6 via ChatGPT Pro)** — needs CLIProxyAPI as a local Anthropic↔Codex bridge:

```sh
brew install cliproxyapi
cliproxyapi -codex-login        # opens the ChatGPT OAuth browser flow
brew services start cliproxyapi # listens on 127.0.0.1:8317
```

Set an API key of your choice in the CLIProxyAPI config and put the same value into `bin/claude-sol` (the `sol-local-CHANGE-ME` placeholder). It only ever travels over loopback.

### Verify

```sh
claude-minimax -p "Reply with the token: OK" < /dev/null
claude-kimi    -p "Reply with the token: OK" < /dev/null
claude-sol     -p "Reply with the token: OK" < /dev/null
```

## Usage

### Spawn a worker (the one pattern that matters)

```sh
claude-sol -p "$(cat brief.md)" --allowedTools "Read,Write,Edit,Grep,Glob,Bash" < /dev/null
```

Headless, fire-and-forget, report on stdout. `< /dev/null` matters: without it a worker that asks a question hangs forever. Long tasks: run it in the background and read the output file when it lands.

Briefs follow a hard standard (see CLAUDE.md): file whitelist, acceptance criteria as exact commands, an escape-hatch clause ("if you need more scope: STOP and justify, never widen on your own"), a structured report tail, and a no-subagents clause. Front-load all precision — there is no mid-flight steering.

### Dispatch with fallback

```sh
claude-agent <hard|normal|simple> [claude args...]
claude-agent --degrade <role> [claude args...]   # consciously accept a weaker model
```

Chains: `hard` = sol→kimi→minimax · `normal` = kimi→sol→minimax · `simple` = minimax→kimi→sol. Every worker is probed with a short timeout first (default 25s) so a dead login can't hang the chain; the real task runs under a generous cap (default 1800s, tune with `AGENT_TIMEOUT`).

| Exit | Meaning |
|---|---|
| 0 | delivered by a worker at or above the required tier (stderr names which) |
| 3 | `PRIMARY_UNAVAILABLE` — only weaker workers left. No output delivered. Re-plan: decompose, wait, or do it yourself. |
| 10 | degraded result delivered with a loud banner — treat as provisional, verify hard |
| 2 | usage error |

**The core rule: a fallback is a re-planning trigger, never a silent substitution.** A weaker model's answer masquerading as the strong model's answer is the worst failure mode this setup has — so it's the one thing the dispatcher makes impossible.

### Operating rules (short version)

- Concurrency ≤3 per provider. A 403/quota wall means STOP, not retry-until-broke.
- Independently verify every worker result: run the tests yourself, check the diff against the whitelist. A worker's "green" is a claim, not evidence.
- MiniMax touches files Write-only (new files, never Edit, never git).
- Larger orchestrations get an HTML progress board, updated on events, never on a timer.

## Field notes

- **`--bare` or leak.** Workers on weaker models do not reliably honor "ignore previous instructions"-style prompt overrides. Not loading the orchestrator prompt at all is the only isolation that held.
- **Headless children can't reach the macOS Keychain.** A `claude` child spawned from a session cannot use OAuth logins — subscription-authenticated fallbacks must run from a real terminal. Wrappers work headless because their auth is env-var/file based.
- **Sol produces 150%.** The required 100% plus abstractions nobody asked for. The whitelist plus acceptance-criteria brief is what turns that into a precise 100%. Don't ask Sol what is unnecessary — that's the orchestrator's final edit.
- **The escape hatch works.** Workers told "STOP and justify instead of widening scope" actually stop. Workers not told that improvise. Every brief carries the clause.

## License

Apache-2.0
