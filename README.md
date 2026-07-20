# claude-workjet

Multi-agent orchestration for Claude Code with zero infrastructure. Workflows flow; a workjet has thrust.

## What this is, in plain words

You already pay for flat-rate AI subscriptions: Claude, ChatGPT Pro, MiniMax, Kimi. This repo turns them into a **team that works together in one place** — your Claude Code session.

The idea is simple:

- **Your Claude session is the manager.** It plans the work, splits it into jobs, and checks the results.
- **Three specialist workers do the jobs.** Each worker is just the normal `claude` CLI started by a small shell script that points it at a different AI provider. GPT-5.6 does the hard, exacting work. MiniMax M3 does the high-volume simple work. Kimi K3 builds frontends and reviews the others.
- **A job is one command.** The manager writes a work order (a "brief") into a prompt, starts the worker, and gets a report back on stdout. No servers, no plugins, no protocol — a worker run is an ordinary process.

That's the whole system: one manager, three workers, briefs in, reports out.

## Why this is good

- **No infrastructure.** Nothing runs in the background except one optional local proxy for GPT-5.6. There is no MCP server, no framework, nothing to babysit or debug.
- **Flat-rate, not per-token.** All workers run on subscriptions you already have. Iterating ten times costs the same as iterating once.
- **Everything is auditable.** A brief is a file. A report is a file. You can read, diff, and replay every job.
- **Workers can't see your stuff.** Each worker runs with `--bare` and its own config directory: it never sees your orchestrator prompt, your project rules, your hooks, or your Claude login.
- **Failure is loud, never silent.** If the strong model is unavailable, the dispatcher refuses to secretly substitute a weaker one. You get an explicit error that says "re-plan", not a quietly worse answer.
- **Battle-tested rules included.** The orchestrator prompt in [CLAUDE.md](CLAUDE.md) encodes what we learned running this in production: how to write briefs workers can't misinterpret, when to review, when NOT to delegate.

## The fleet

| Worker | Use it for | Model | Billing |
|---|---|---|---|
| `claude-sol` | Hard, detail-heavy, must-not-fail work | GPT-5.6, reasoning high | ChatGPT Pro subscription |
| `claude-minimax` | Clear, repetitive, high-volume work | MiniMax M3 | MiniMax coding plan |
| `claude-kimi` | Greenfield frontend/design; independent review | Kimi K3, 1M context | Kimi coding plan |
| `claude-agent` | Dispatcher with safe fallback across the three | — | — |

Any subset works. If you only have one of the subscriptions, install that wrapper and skip the rest.

---

## Setup (agent-executable)

**If you are an AI agent:** execute these steps in order. Every step ends with a CHECK command and its expected result — do not continue past a failed check. Steps marked **HUMAN** need something only your human can provide (a key or a browser login): ask for exactly that, then continue. All steps are idempotent.

### Step 0 — preconditions

```sh
command -v claude && command -v git && command -v zsh
```

CHECK: three paths print. If `claude` is missing, install Claude Code first (https://claude.com/claude-code); if the human hasn't logged it in, ask them to run `claude` once interactively.

### Step 1 — install the wrappers and scripts

```sh
git clone https://github.com/metric-space-ai/claude-workjet /tmp/claude-workjet
cd /tmp/claude-workjet && ./install.sh
```

CHECK: `ls ~/.local/bin/claude-sol ~/.local/bin/claude-minimax ~/.local/bin/claude-kimi ~/.local/bin/claude-agent` prints four paths. Also confirm `~/.local/bin` is on `PATH` (`echo "$PATH" | tr ':' '\n' | grep -x "$HOME/.local/bin"`); if not, append `export PATH="$HOME/.local/bin:$PATH"` to the shell profile.

### Step 2 — MiniMax worker (skip if no MiniMax subscription)

**HUMAN:** ask for the MiniMax coding-plan API key (from platform.minimax.io).

```sh
mkdir -p ~/.config/secrets
printf 'export MINIMAX_API_KEY="%s"\n' "PASTE_KEY_HERE" > ~/.config/secrets/minimax.env
chmod 600 ~/.config/secrets/minimax.env
```

CHECK:

```sh
claude-minimax -p "Reply with the token: OK" < /dev/null
```

Expected: a reply containing `OK`. An auth error means the key is wrong — ask the human again, do not retry in a loop.

### Step 3 — Kimi worker (skip if no Kimi subscription)

**HUMAN:** ask for the Kimi-Code API key (from kimi.com/code).

```sh
mkdir -p ~/.config/kimi
printf '%s\n' "PASTE_KEY_HERE" > ~/.config/kimi/api-key
chmod 600 ~/.config/kimi/api-key
```

CHECK: `claude-kimi -p "Reply with the token: OK" < /dev/null` → reply contains `OK`.

### Step 4 — Sol worker via CLIProxyAPI (skip if no ChatGPT Pro subscription)

Sol needs a small local proxy that translates the Anthropic API the `claude` CLI speaks into the Codex API GPT-5.6 speaks, authenticated with the human's ChatGPT login.

```sh
brew install cliproxyapi
```

**HUMAN:** run `cliproxyapi -codex-login` in a terminal and complete the browser login. (This cannot be done headlessly — the OAuth flow needs a browser.)

Then:

```sh
brew services start cliproxyapi
lsof -nP -iTCP:8317 -sTCP:LISTEN
```

CHECK: a listener on `127.0.0.1:8317`.

Now set a shared local secret (any random string; it never leaves the machine). Put the SAME value in both places:

1. the proxy config (`/opt/homebrew/etc/cliproxyapi.conf`, field for API keys),
2. `~/.local/bin/claude-sol` — replace both occurrences of `sol-local-CHANGE-ME`.

CHECK: `claude-sol -p "Reply with the token: OK" < /dev/null` → reply contains `OK`.

### Step 5 — install the orchestrator prompt

```sh
test -f ~/.claude/CLAUDE.md && cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.bak-workjet
cp /tmp/claude-workjet/CLAUDE.md ~/.claude/CLAUDE.md
```

If a `CLAUDE.md` already existed, MERGE instead of overwriting: keep the human's existing rules and append the workjet sections (roles, review model, progress board, brief standard, agent wiring). Show the human the diff.

CHECK: `grep -c "claude-sol" ~/.claude/CLAUDE.md` ≥ 1.

### Step 6 — end-to-end smoke

```sh
claude-agent simple -p "Reply with the token: OK" < /dev/null; echo "exit=$?"
```

Expected: output contains `OK`, `exit=0`, and stderr names the worker that answered. Setup complete — report to the human which workers are live and which were skipped.

---

## Using the fleet

### Spawn a worker (the one pattern that matters)

```sh
claude-sol -p "$(cat brief.md)" --allowedTools "Read,Write,Edit,Grep,Glob,Bash" < /dev/null
```

Headless, fire-and-forget, report on stdout. `< /dev/null` matters: a worker that asks a question would otherwise hang forever. Long jobs: run in the background, read the output file when it lands.

Every brief follows the standard in [CLAUDE.md](CLAUDE.md): a hard file whitelist, acceptance criteria as exact commands, an escape-hatch clause ("if you need more scope: STOP and justify, never widen on your own"), a structured report tail, and a no-subagents clause. All precision is front-loaded — there is no steering mid-flight.

### Dispatch with safe fallback

```sh
claude-agent <hard|normal|simple> [claude args...]
claude-agent --degrade <role> [claude args...]   # consciously accept a weaker model
```

Chains: `hard` = sol→kimi→minimax · `normal` = kimi→sol→minimax · `simple` = minimax→kimi→sol. Each worker is probed with a short timeout first (25s default) so a dead login can't hang the chain; the real job runs under a generous cap (1800s default, `AGENT_TIMEOUT`).

| Exit | Meaning |
|---|---|
| 0 | delivered by a worker at or above the required tier (stderr names it) |
| 3 | `PRIMARY_UNAVAILABLE` — only weaker workers left, nothing delivered. Re-plan: decompose, wait, or do it yourself. |
| 10 | degraded result, loudly banner-tagged — provisional, verify hard |
| 2 | usage error |

**Core rule: a fallback is a re-planning trigger, never a silent substitution.** The one failure mode this setup makes impossible is a weak model's answer masquerading as the strong model's.

### Operating rules (short)

- Concurrency ≤3 per provider. A 403/quota wall means STOP, not retry-until-broke.
- Verify every worker result yourself: run the tests, check the diff against the whitelist. A worker's "green" is a claim, not evidence.
- MiniMax touches files Write-only (new files, never Edit, never git).
- Larger orchestrations get an HTML progress board, updated on events, never on a timer.

## Field notes (paid for in real incidents)

- **`--bare` or leak.** Weaker worker models do not reliably obey "ignore the orchestrator prompt" instructions. Not loading it at all is the only isolation that held.
- **Headless children can't reach the macOS Keychain.** A `claude` child spawned from a session can't use OAuth logins — that's why every wrapper authenticates via env var or key file, and why the ChatGPT login in Step 4 is the human's step.
- **The strong model produces 150%.** The required 100% plus abstractions nobody asked for. The whitelist-plus-acceptance-criteria brief turns that into a precise 100%. Deciding what was unnecessary is the manager's job, not the worker's.
- **The escape hatch works.** Workers told "STOP and justify instead of widening scope" actually stop. Workers not told that improvise. Every brief carries the clause.

## License

Apache-2.0
