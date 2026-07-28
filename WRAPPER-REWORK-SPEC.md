# Wrapper rework — spec (source: POSTMORTEM-2026-07-28.md)

Every fix lives in the wrapper; none relies on model good behaviour.

## claude-agent API changes
1. `--brief FILE` replaces prompt-by-substitution: wrapper checks existence
   and a minimum length (>= 200 bytes) and refuses to start otherwise. `-p`
   stays for ad-hoc prompts but warns when the text is under 200 bytes.
2. Preamble injection: every prompt is prefixed by the wrapper with
   "You are in an isolated worktree at <path>. Never cd to another checkout.
   Commit in green slices: a timeout must still land value. No subagents."
3. Post-run tamper check: snapshot `git -C <main-repo> status --porcelain`
   before launch; if it differs after the run, the run is marked FAILED with
   a loud TAMPER banner regardless of the worker's own result.
4. Timeout salvage: on the 5400s cap, commit the worktree as `wip: <run-id>`
   on the protected ref and write a diff report into the run dir.
5. Run journal: brief sha256 at start, PID file, heartbeat (touch every 60s),
   `git diff --stat` snapshot every 10 min, exit marker. Kill only via PID
   file — never by process-name pattern.
6. `claude-agent doctor`: probe every rung (sol, kimi, minimax, opus token
   file presence) and print a table; launcher prints a one-line warning at
   every start while a documented rung is dead.
7. `claude-agent accept RUN-ID`: merge the protected ref into the current
   branch, run `.workjet/checks.sh` if the repo has one, diff the changed
   files against the brief's FILE WHITELIST (verbatim block parsed from the
   brief), print a structured acceptance report. Non-zero on any failure.
8. Probe: 3 retries with backoff, 120s default, same invocation path as the
   task, auth distinguished from timeout in the message; last-good cache
   (skip re-probe within 10 min). On `auth_unavailable`: if the token file
   is newer than the proxy start, restart cliproxyapi once, then re-probe,
   then (only then) print the user-action instruction.

## Acceptance
A bats or shell test suite under tests/ that fakes a worker (a stub script in
place of the model CLI) and proves: short-brief refusal, preamble present in
the prompt file the stub received, tamper detection, timeout wip-commit,
journal files, doctor table, accept's whitelist violation detection. All green
in CI-less local run: `./tests/run.sh`.
Whitelist: bin/, tests/, README.md, AGENTS.md (usage sections only).
Commit message: feat(wrapper): postmortem fixes — isolation, salvage, doctor, accept
