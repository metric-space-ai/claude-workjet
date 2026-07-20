---
name: workjet
description: Orchestrate the current task with the workjet fleet — Sol (GPT-5.6) for hard completion work, MiniMax M3 for bulk work, Kimi K3 for greenfield frontend and independent review, the Claude session as orchestrator. Use when the user says "workjet" or wants a task run through the multi-agent setup.
---

Run the user's task in workjet mode. First read the full operating rules from
`~/.claude/workjet/AGENTS.md` (roles, review model, brief standard, progress
board, agent wiring, quota rules). If that skill-only path does not exist, fall
back to `~/.claude/AGENTS.md` for installations made with the global prompt
option. Apply those rules as the active mode for the task at hand.

Execute in this order:

1. **Decompose.** Preserve every explicit requirement. Pick the smallest
   useful pattern — for small work (one file, quick wiring), do it yourself
   and skip the fleet entirely.
2. **Route.** Completion-critical/hard → `implementation-hard`. Clear high-volume →
   `bulk-generation` (MiniMax remains Write-only on files, never Edit, never git).
   Greenfield frontend/design → `frontend-greenfield`; existing frontend/backend
   wiring → `frontend-integration`; independent review → `review`; research →
   `research`. Invoke roles through `claude-agent`; later chain workers require
   explicit `--degrade`.
3. **Brief per the standard.** Hard file whitelist · acceptance criteria as
   exact commands · escape-hatch clause · structured report tail · no
   subagents. Spawn headless:
   `<wrapper> -p "$(cat brief.md)" --allowedTools "..." < /dev/null`
   (background for long jobs; concurrency ≤3 per provider; 403 = stop).
4. **Track.** For larger runs (multiple workers/waves/sessions) create or
   update the HTML progress board (Artifact, stable URL, event-driven
   updates). No board for single-delegation errands.
5. **Integrate and verify.** Run the tests yourself, check the diff against
   the whitelist. A worker's "green" is a claim, not evidence.
6. **Final edit** yourself: cut Sol's 150% to the best 100%.
7. **Review.** Adversarial self-review first; substantial integrations and
   final edits → Kimi. If Kimi is down: state the deferral explicitly.
