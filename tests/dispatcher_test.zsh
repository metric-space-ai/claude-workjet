#!/bin/zsh
emulate -L zsh
setopt pipe_fail

ROOT=${0:A:h:h}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/workjet-dispatcher.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/bin" "$TMP_ROOT/work"
mkdir -p "$TMP_ROOT/home/.claude/workjet"
cat > "$TMP_ROOT/home/.claude/workjet/AGENTS.md" <<'PROMPT'
<!-- WORKJET WORKER PREAMBLE BEGIN -->
You are in an isolated worktree at <WORKJET_CHECKOUT>. Never cd to another checkout. Commit in green slices: a timeout must still land value. No subagents.
<!-- WORKJET WORKER PREAMBLE END -->
<!-- WORKJET OPUS SYSTEM PROMPT BEGIN -->
You are a headless worker process. Execute exactly the brief given in the user prompt and print your report to stdout. You are NOT an orchestrator: never spawn agents, workers, or subprocesses beyond what the brief itself requires.
<!-- WORKJET OPUS SYSTEM PROMPT END -->
<!-- WORKJET HEALTH PROBE PROMPT BEGIN -->
You are in an isolated worktree at <WORKJET_CHECKOUT>. Never cd to another checkout. Do not edit files and do not spawn subagents. Reply with the token: OK
<!-- WORKJET HEALTH PROBE PROMPT END -->
<!-- WORKJET COMPLETION RECEIPT PROMPT BEGIN -->
WORKJET COMPLETION RECEIPT V1
After the human-readable report, end stdout with one completion receipt.
<!-- WORKJET COMPLETION RECEIPT PROMPT END -->
PROMPT

make_stub() {
  local name=$1
  cat > "$TMP_ROOT/bin/$name" <<'STUB'
#!/bin/zsh
name=${0:t}
kind=task
[[ " $* " == *"Reply with the token: OK"* ]] && kind=probe
print -r -- "${name}:${kind}:args=$*" >> "$STUB_LOG"

print_receipt() {
  local claimed_status="$1" summary="$2"
  print '```workjet-completion-receipt-v1'
  printf '{"schemaVersion":1,"status":"%s","summary":"%s","changedFiles":["fixture.txt"],"verification":[{"command":"zsh -n fixture","result":"passed"}],"concerns":[],"producedPaths":["fixture.txt"]}\n' "$claimed_status" "$summary"
  print '```'
}

case "$STUB_SCENARIO:$name:$kind" in
  success-words:claude-minimax:probe|valid-receipt:claude-minimax:probe|malformed-receipt:claude-minimax:probe|deceptive-receipt:claude-minimax:probe|provider-fallback:claude-minimax:probe|task-failed:claude-minimax:probe|timeout-group:claude-minimax:probe|git-success:claude-minimax:probe)
    print OK
    exit 0
    ;;
  review-tools:claude-kimi:probe)
    print OK
    exit 0
    ;;
  probe-unavailable:claude-minimax:probe)
    print -u2 '403 provider unavailable'
    exit 1
    ;;
  kimi-stdout-403-refusal:claude-kimi:probe|kimi-stdout-403-degrade:claude-kimi:probe)
    print "Failed to authenticate. API Error: 403 You've reached your usage limit for this billing cycle..."
    exit 1
    ;;
  kimi-stdout-403-refusal:claude-opus:probe)
    print -u2 'quota exhausted'
    exit 1
    ;;
  kimi-stdout-403-degrade:claude-sol:probe)
    print OK
    exit 0
    ;;
  kimi-stdout-403-degrade:claude-sol:task)
    print 'fallback after Kimi stdout 403'
    exit 0
    ;;
  git-success:claude-minimax:task)
    if [[ "$EXPECT_DIRTY" == 1 && ! -f dirty.txt ]]; then
      print -u2 'dirty snapshot missing'
      exit 7
    fi
    print 'worker result' > result.txt
    print 'git delivery'
    exit 0
    ;;
  review-tools:claude-kimi:task)
    [[ " $* " == *" --allowedTools Read,Grep,Glob "* ]] || { print -u2 'review allowed tools wrong'; exit 7; }
    [[ " $* " == *" --disallowedTools Write,Edit,Bash "* ]] || { print -u2 'review denied tools wrong'; exit 7; }
    print 'review delivery'
    exit 0
    ;;
  success-words:claude-minimax:task)
    print 'Report: fixed the 403 rate limit handling.'
    exit 0
    ;;
  valid-receipt:claude-minimax:task)
    print 'valid report remains visible'
    print_receipt completed 'implemented receipt fixture'
    exit 0
    ;;
  malformed-receipt:claude-minimax:task)
    print 'malformed report remains delivered'
    print '```workjet-completion-receipt-v1'
    print '{not-json}'
    print '```'
    exit 0
    ;;
  deceptive-receipt:claude-minimax:task)
    print 'deceptive worker claim'
    print_receipt completed '429 quota exceeded but I claim success despite the process failure'
    print -u2 'compiler exited while applying requested edit'
    exit 7
    ;;
  provider-fallback:claude-minimax:task)
    print '```workjet-completion-receipt-v1'
    print '{bad-primary-receipt}'
    print '```'
    print -u2 '429 quota exceeded'
    exit 1
    ;;
  degrade-path:claude-minimax:probe)
    print -u2 'quota exhausted'
    exit 1
    ;;
  provider-fallback:claude-kimi:probe|degrade-path:claude-kimi:probe)
    print OK
    exit 0
    ;;
  provider-fallback:claude-kimi:task)
    print 'fallback after task provider error'
    print_receipt completed 'final fallback receipt'
    exit 0
    ;;
  degrade-path:claude-kimi:task)
    print 'explicit degraded result'
    print_receipt partial 'degraded result needs verification'
    exit 0
    ;;
  opus-quota:claude-minimax:probe)
    print -u2 '429 quota exceeded'
    exit 1
    ;;
  opus-quota:claude-opus:probe)
    print OK
    exit 0
    ;;
  opus-quota:claude-opus:task)
    print 'opus quota fallback delivery'
    exit 0
    ;;
  task-failed:claude-minimax:task)
    print '429 quota exceeded in stdout must not classify provider failure'
    print -u2 'compiler exited while applying requested edit'
    exit 7
    ;;
  timeout-group:claude-minimax:task)
    print 'timeout report before hang'
    print_receipt completed 'deceptive completed claim before timeout'
    sleep 300 &
    child=$!
    print -r -- "$$ $child" > "$STUB_PID_FILE"
    wait $child
    ;;
  *)
    print -u2 "unexpected invocation: $STUB_SCENARIO $name $kind"
    exit 9
    ;;
esac
STUB
  chmod +x "$TMP_ROOT/bin/$name"
}
for worker in claude-minimax claude-kimi claude-sol claude-opus; do make_stub "$worker"; done

failures=0
LAST_RC=0
LAST_OUT=""
LAST_ERR=""
LAST_LOG=""
LAST_RUN_DIR=""
run_agent() {
  local scenario=$1; shift
  local case_dir="$TMP_ROOT/case-$scenario"
  mkdir -p "$case_dir/run"
  LAST_OUT="$case_dir/stdout"
  LAST_ERR="$case_dir/stderr"
  LAST_LOG="$case_dir/log"
  LAST_RUN_DIR="$case_dir/run"
  (cd "$TMP_ROOT/work" && \
    HOME="$TMP_ROOT/home" \
    AGENT_BIN_DIR="$TMP_ROOT/bin" \
    STUB_SCENARIO="$scenario" \
    STUB_LOG="$LAST_LOG" \
    STUB_PID_FILE="$case_dir/pids" \
    AGENT_PROBE_TIMEOUT=30 \
    AGENT_PROBE_RETRIES=0 \
    AGENT_PROBE_CACHE_TTL=0 \
    AGENT_TIMEOUT="${CASE_TASK_TIMEOUT:-10}" \
    "$ROOT/bin/claude-agent" --run-dir "$case_dir/run" "$@" >"$LAST_OUT" 2>"$LAST_ERR")
  LAST_RC=$?
}

pass() { print "ok - $1"; }
fail() {
  print -u2 "not ok - $1"
  print -u2 "  rc=$LAST_RC"
  [[ -f "$LAST_OUT" ]] && print -u2 "  stdout: $(<"$LAST_OUT")"
  [[ -f "$LAST_ERR" ]] && print -u2 "  stderr: $(<"$LAST_ERR")"
  [[ -f "$LAST_LOG" ]] && print -u2 "  log: $(<"$LAST_LOG")"
  (( failures++ ))
}
log_has() { grep -Fq -- "$1" "$LAST_LOG" 2>/dev/null; }
completion_value() {
  python3 - "$LAST_RUN_DIR/completion.json" "$1" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[part]
if value is None:
    print("null")
elif isinstance(value, bool):
    print(str(value).lower())
else:
    print(value)
PY
}

run_agent success-words bulk-generation --model observed-model --effort high --speed fast -p task
if [[ $LAST_RC -eq 0 ]] && grep -Fq 'fixed the 403 rate limit handling' "$LAST_OUT" && ! log_has 'claude-kimi'; then
  pass 'rc 0 ignores provider words in stdout and does not fallback'
else
  fail 'rc 0 ignores provider words in stdout and does not fallback'
fi

if grep -Fq '"model":"observed-model"' "$LAST_RUN_DIR/run-state.json" && \
   grep -Fq '"reasoning":"high"' "$LAST_RUN_DIR/run-state.json" && \
   grep -Fq '"speed":"fast"' "$LAST_RUN_DIR/run-state.json"; then
  pass 'run snapshot records effective model reasoning and speed args'
else
  fail 'run snapshot records effective model reasoning and speed args'
fi

if [[ "$(completion_value receipt.status)" == missing && \
      "$(completion_value observations.terminal.classification)" == delivered && \
      "$(completion_value observations.actualWorker)" == claude-minimax ]]; then
  pass 'missing receipt is telemetry-only for a delivered task'
else
  fail 'missing receipt is telemetry-only for a delivered task'
fi

run_agent valid-receipt bulk-generation -p task
if [[ $LAST_RC -eq 0 ]] && grep -Fq 'valid report remains visible' "$LAST_OUT" && \
   grep -Fq '```workjet-completion-receipt-v1' "$LAST_OUT" && \
   [[ "$(completion_value receipt.status)" == valid && \
      "$(completion_value claims.summary)" == 'implemented receipt fixture' ]]; then
  pass 'valid final receipt is persisted without hiding worker stdout'
else
  fail 'valid final receipt is persisted without hiding worker stdout'
fi
if [[ "$(grep -c 'WORKJET COMPLETION RECEIPT V1' "$LAST_LOG")" == 1 ]] && \
   grep -Fq 'claude-minimax:probe:args=' "$LAST_LOG"; then
  pass 'receipt contract is injected into tasks but never health probes'
else
  fail 'receipt contract is injected into tasks but never health probes'
fi

run_agent malformed-receipt bulk-generation -p task
if [[ $LAST_RC -eq 0 && "$(completion_value receipt.status)" == invalid && \
      "$(completion_value observations.terminal.classification)" == delivered ]]; then
  pass 'malformed receipt does not change successful delivery classification'
else
  fail 'malformed receipt does not change successful delivery classification'
fi

run_agent deceptive-receipt bulk-generation -p task
if [[ $LAST_RC -eq 4 && "$(completion_value receipt.status)" == valid && \
      "$(completion_value claims.status)" == completed && \
      "$(completion_value observations.terminal.classification)" == task_failed ]]; then
  pass 'deceptive completion claim cannot override task-failure observations'
else
  fail 'deceptive completion claim cannot override task-failure observations'
fi

run_agent provider-fallback --degrade bulk-generation -p task
if [[ $LAST_RC -eq 10 ]] && grep -Fq 'fallback after task provider error' "$LAST_OUT" && log_has 'claude-kimi:task' && \
   [[ "$(completion_value claims.summary)" == 'final fallback receipt' ]]; then
  pass 'provider error in stderr permits explicit fallback and parses only the final task attempt'
else
  fail 'provider error in stderr permits explicit fallback and parses only the final task attempt'
fi

if [[ -f "$LAST_RUN_DIR/attempts/01-claude-minimax/kind" && "$(<"$LAST_RUN_DIR/attempts/01-claude-minimax/kind")" == probe && \
      -f "$LAST_RUN_DIR/attempts/02-claude-minimax/stderr" && \
      -f "$LAST_RUN_DIR/attempts/03-claude-kimi/kind" && "$(<"$LAST_RUN_DIR/attempts/03-claude-kimi/kind")" == probe && \
      -f "$LAST_RUN_DIR/attempts/04-claude-kimi/stdout" ]] && \
   grep -Fq '429 quota exceeded' "$LAST_RUN_DIR/attempts/02-claude-minimax/stderr" && \
   grep -Fq 'fallback after task provider error' "$LAST_RUN_DIR/attempts/04-claude-kimi/stdout"; then
  pass 'attempt directories preserve every probe and task in order'
else
  fail 'attempt directories preserve every probe and task in order'
fi

run_agent kimi-stdout-403-refusal frontend-greenfield -p task
if [[ $LAST_RC -eq 3 ]] && grep -Fq 'PRIMARY_UNAVAILABLE' "$LAST_ERR" && \
   ! grep -Fq 'TASK_FAILED' "$LAST_ERR" && ! log_has 'claude-sol'; then
  pass 'nonzero Kimi probe classifies provider signatures from bounded stdout'
else
  fail 'nonzero Kimi probe classifies provider signatures from bounded stdout'
fi

run_agent kimi-stdout-403-degrade --degrade frontend-greenfield -p task
if [[ $LAST_RC -eq 10 ]] && grep -Fq 'fallback after Kimi stdout 403' "$LAST_OUT" && \
   log_has 'claude-sol:probe' && log_has 'claude-sol:task'; then
  pass '--degrade continues after Kimi probe provider failure on stdout'
else
  fail '--degrade continues after Kimi probe provider failure on stdout'
fi

run_agent task-failed bulk-generation -p task
if [[ $LAST_RC -eq 4 ]] && grep -Fq 'TASK_FAILED worker=claude-minimax' "$LAST_ERR" && ! log_has 'claude-kimi'; then
  pass 'unstructured nonzero exits 4 without fallback'
else
  fail 'unstructured nonzero exits 4 without fallback'
fi

run_agent degrade-path --degrade bulk-generation -p task
if [[ $LAST_RC -eq 10 ]] && grep -Fq 'explicit degraded result' "$LAST_OUT" && grep -Fq 'DEGRADED FALLBACK' "$LAST_ERR" && \
   [[ "$(completion_value receipt.status)" == valid && \
      "$(completion_value claims.status)" == partial && \
      "$(completion_value observations.terminal.classification)" == degraded ]]; then
  pass '--degrade follows the role chain and records receipt health'
else
  fail '--degrade follows the role chain and records receipt health'
fi

run_agent review-tools review -p task
if [[ $LAST_RC -eq 0 ]] && grep -Fq -- '--allowedTools Read,Grep,Glob' "$LAST_LOG" && \
   grep -Fq -- '--disallowedTools Write,Edit,Bash' "$LAST_LOG"; then
  pass 'review role receives read-only tool policy'
else
  fail 'review role receives read-only tool policy'
fi

CASE_TASK_TIMEOUT=1 run_agent timeout-group bulk-generation -p task
pid_file="$TMP_ROOT/case-timeout-group/pids"
parent_pid="" child_pid=""
[[ -f "$pid_file" ]] && read -r parent_pid child_pid < "$pid_file"
for _ in {1..20}; do
  { [[ -z "$parent_pid" ]] || ! kill -0 "$parent_pid" 2>/dev/null; } && \
    { [[ -z "$child_pid" ]] || ! kill -0 "$child_pid" 2>/dev/null; } && break
  sleep 0.1
done
if [[ $LAST_RC -eq 3 && -n "$parent_pid" && -n "$child_pid" ]] && \
   ! kill -0 "$parent_pid" 2>/dev/null && ! kill -0 "$child_pid" 2>/dev/null; then
  pass 'timeout kills the worker process group'
else
  fail 'timeout kills the worker process group'
  print -u2 "  parent_pid=${parent_pid:-missing} child_pid=${child_pid:-missing}"
fi
if [[ "$(completion_value receipt.status)" == valid && \
      "$(completion_value claims.status)" == completed && \
      "$(completion_value observations.terminal.classification)" == primary_unavailable && \
      "$(completion_value observations.flags.timeout)" == true ]]; then
  pass 'timeout observations override a deceptive completed receipt claim'
else
  fail 'timeout observations override a deceptive completed receipt claim'
fi

GIT_REPO="$TMP_ROOT/git-repo"
GIT_STATE="$TMP_ROOT/git-state"
mkdir -p "$GIT_REPO" "$GIT_STATE"
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" config user.name test
git -C "$GIT_REPO" config user.email test@example.com
print base > "$GIT_REPO/base.txt"
git -C "$GIT_REPO" add base.txt
git -C "$GIT_REPO" commit -qm base

GIT_EXPECT_DIRTY=0
run_git_agent() {
  local scenario=$1 label=$2; shift 2
  local case_dir="$TMP_ROOT/git-$label"
  mkdir -p "$case_dir/run"
  LAST_OUT="$case_dir/stdout"
  LAST_ERR="$case_dir/stderr"
  LAST_LOG="$case_dir/log"
  LAST_RUN_DIR="$case_dir/run"
  (cd "$GIT_REPO" && \
    HOME="$TMP_ROOT/home" \
    WORKJET_STATE_DIR="$GIT_STATE" \
    AGENT_BIN_DIR="$TMP_ROOT/bin" \
    STUB_SCENARIO="$scenario" \
    STUB_LOG="$LAST_LOG" \
    STUB_PID_FILE="$case_dir/pids" \
    EXPECT_DIRTY="$GIT_EXPECT_DIRTY" \
    AGENT_PROBE_TIMEOUT=30 \
    AGENT_PROBE_RETRIES=0 \
    AGENT_PROBE_CACHE_TTL=0 \
    AGENT_TIMEOUT=10 \
    "$ROOT/bin/claude-agent" --run-dir "$case_dir/run" "$@" >"$LAST_OUT" 2>"$LAST_ERR")
  LAST_RC=$?
}

print dirty > "$GIT_REPO/dirty.txt"
run_git_agent git-success dirty-stop bulk-generation -p task
if [[ $LAST_RC -eq 4 ]] && grep -Fq 'main checkout is dirty' "$LAST_ERR" && [[ ! -s "$LAST_LOG" ]]; then
  pass 'dirty main checkout stops before worker start'
else
  fail 'dirty main checkout stops before worker start'
fi

run_git_agent probe-unavailable dirty-probe --include-dirty --allowed-paths 'worker-output.txt' bulk-generation -p task
if [[ $LAST_RC -eq 3 && ! -e "$LAST_RUN_DIR/path-violations.txt" ]] && \
   [[ "$(completion_value observations.pathViolation.state)" == clean ]]; then
  pass 'provider failure before task launch never classifies dirty input as worker output'
else
  fail 'provider failure before task launch never classifies dirty input as worker output'
fi

GIT_EXPECT_DIRTY=1
run_git_agent git-success dirty-include --include-dirty --allowed-paths 'dirty.txt' bulk-generation -p task
protected_run_dir="$LAST_RUN_DIR"
run_id="$(<"$protected_run_dir/run-id")"
worktree="$(<"$protected_run_dir/worktree-path")"
if [[ $LAST_RC -eq 0 && -s "$protected_run_dir/dirty.patch" && -f "$worktree/dirty.txt" ]] && \
   git -C "$GIT_REPO" show "refs/workjet/$run_id:dirty.txt" | grep -Fq dirty; then
  pass '--include-dirty reaches worker and successful result has protected ref'
else
  fail '--include-dirty reaches worker and successful result has protected ref'
fi

if [[ "$worktree" == "$GIT_STATE/worktrees/"* && ! -e "$GIT_REPO/.workjet" ]] && \
   [[ "$(git -C "$GIT_REPO" status --short)" == '?? dirty.txt' ]]; then
  pass 'isolated worktree stays outside repository checkout'
else
  fail 'isolated worktree stays outside repository checkout'
fi

if [[ -f "$protected_run_dir/path-violations.txt" ]] && \
   grep -Fxq 'result.txt' "$protected_run_dir/path-violations.txt" && \
   ! grep -Fxq 'dirty.txt' "$protected_run_dir/path-violations.txt" && \
   grep -Fq 'PATH_VIOLATION: result.txt' "$LAST_ERR"; then
  pass 'allowed-path audit records only worker changes, not the dirty input snapshot'
else
  fail 'allowed-path audit records only worker changes, not the dirty input snapshot'
fi
if [[ "$(completion_value observations.pathViolation.state)" == violated && \
      "$(completion_value observations.protectedResult.ref)" == "refs/workjet/$run_id" ]] && \
   grep -Fq 'result.txt' "$protected_run_dir/completion.json" && \
   ! grep -Fq 'worker result' "$protected_run_dir/completion.json"; then
  pass 'completion separates bounded Git observations from full worker streams'
else
  fail 'completion separates bounded Git observations from full worker streams'
fi

rm -f "$GIT_REPO/dirty.txt"
touch -t 202001010000 "$worktree"
GIT_EXPECT_DIRTY=0
run_git_agent probe-unavailable cleanup-unmarked bulk-generation -p task
if [[ $LAST_RC -eq 3 && ! -e "$worktree" && -f "$protected_run_dir/pruned" ]] && \
   git -C "$GIT_REPO" rev-parse --verify -q "refs/workjet/$run_id^{commit}" >/dev/null && \
   grep -Fq 'removing unmarked worktree older than 24h' "$LAST_ERR" && \
   grep -Fq "marked run $run_id pruned" "$LAST_ERR"; then
  pass 'recoverable unmarked old worktree is pruned while journal and ref remain'
else
  fail 'recoverable unmarked old worktree is pruned while journal and ref remain'
fi

HOME="$TMP_ROOT/home" WORKJET_STATE_DIR="$GIT_STATE" \
  "$ROOT/bin/claude-agent" runs mark "$run_id" integrated >"$TMP_ROOT/mark.out" 2>"$TMP_ROOT/mark.err"
mark_rc=$?
if [[ $mark_rc -eq 0 && -f "$protected_run_dir/integrated" && ! -f "$protected_run_dir/pruned" ]] && \
   git -C "$GIT_REPO" rev-parse --verify -q "refs/workjet/$run_id^{commit}" >/dev/null; then
  pass 'pruned result remains integratable through its protected ref'
else
  fail 'pruned result remains integratable through its protected ref'
fi

SHOW_STATE="$TMP_ROOT/show-state"
SHOW_RUN="$SHOW_STATE/runs/show-safe"
mkdir -p "$SHOW_RUN"
(cd "$TMP_ROOT/work" && HOME="$TMP_ROOT/home" WORKJET_STATE_DIR="$SHOW_STATE" \
  AGENT_BIN_DIR="$TMP_ROOT/bin" STUB_SCENARIO=valid-receipt STUB_LOG="$TMP_ROOT/show-log" \
  AGENT_PROBE_RETRIES=0 AGENT_PROBE_CACHE_TTL=0 AGENT_TIMEOUT=10 \
  "$ROOT/bin/claude-agent" --run-dir "$SHOW_RUN" bulk-generation -p task \
  > "$TMP_ROOT/show-run.out" 2> "$TMP_ROOT/show-run.err")
show_run_rc=$?
show_id="$(<"$SHOW_RUN/run-id")"
HOME="$TMP_ROOT/home" WORKJET_STATE_DIR="$SHOW_STATE" \
  "$ROOT/bin/claude-agent" runs show "$show_id" > "$TMP_ROOT/show.out" 2> "$TMP_ROOT/show.err"
show_rc=$?
if [[ $show_run_rc -eq 0 && $show_rc -eq 0 ]] && \
   grep -Fq 'receipt: valid' "$TMP_ROOT/show.out" && \
   grep -Fq 'summary=implemented receipt fixture' "$TMP_ROOT/show.out" && \
   grep -Fq 'classification=delivered' "$TMP_ROOT/show.out"; then
  pass 'runs show emits a concise completion sighting packet'
else
  LAST_RC=$show_rc; LAST_OUT="$TMP_ROOT/show.out"; LAST_ERR="$TMP_ROOT/show.err"
  fail 'runs show emits a concise completion sighting packet'
fi

mkdir -p "$SHOW_STATE/run-index"
print -r -- "$protected_run_dir" > "$SHOW_STATE/run-index/escaped-run"
HOME="$TMP_ROOT/home" WORKJET_STATE_DIR="$SHOW_STATE" \
  "$ROOT/bin/claude-agent" runs show escaped-run > "$TMP_ROOT/show-unsafe.out" 2> "$TMP_ROOT/show-unsafe.err"
unsafe_show_rc=$?
HOME="$TMP_ROOT/home" WORKJET_STATE_DIR="$SHOW_STATE" \
  "$ROOT/bin/claude-agent" runs show '../escaped' > /dev/null 2> "$TMP_ROOT/show-invalid.err"
invalid_show_rc=$?
if [[ $unsafe_show_rc -eq 2 && $invalid_show_rc -eq 2 ]] && \
   grep -Fq 'outside the trusted runs root' "$TMP_ROOT/show-unsafe.err" && \
   grep -Fq 'invalid run id' "$TMP_ROOT/show-invalid.err"; then
  pass 'runs show fails closed on untrusted paths and invalid run ids'
else
  LAST_RC=$unsafe_show_rc; LAST_OUT="$TMP_ROOT/show-unsafe.out"; LAST_ERR="$TMP_ROOT/show-unsafe.err"
  fail 'runs show fails closed on untrusted paths and invalid run ids'
fi

FLEET_ROOT="$TMP_ROOT/fleet"
mkdir -p "$FLEET_ROOT/state"
print one > "$FLEET_ROOT/one.md"
print two > "$FLEET_ROOT/two.md"
cat > "$FLEET_ROOT/fake-agent" <<'FLEET_STUB'
#!/bin/zsh
run_dir=""
while [[ "$1" == --* ]]; do
  case "$1" in
    --run-dir) run_dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$run_dir"
print call >> "$WORKJET_STATE_DIR/calls"
call_no="$(wc -l < "$WORKJET_STATE_DIR/calls" | tr -d ' ')"
if ! mkdir "$WORKJET_STATE_DIR/active" 2>/dev/null; then
  print overlap > "$WORKJET_STATE_DIR/overlap"
  exit 9
fi
sleep 0.15
rmdir "$WORKJET_STATE_DIR/active"
: > "$run_dir/worktree-path"
if [[ "$FLEET_MODE" == receipt-aggregate ]]; then
  if [[ "$call_no" == 1 ]]; then
    python3 - "$run_dir/completion.json" <<'PY'
import json
import sys
json.dump({
    "schemaVersion": 1,
    "receipt": {"status": "valid", "detail": "validated"},
    "claims": {"schemaVersion": 1, "status": "completed", "summary": "fleet summary " + "x" * 240,
               "changedFiles": [], "verification": [], "concerns": [], "producedPaths": []},
    "observations": {"runId": "fleet", "terminal": {"exitCode": 0, "classification": "delivered"}}
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
  else
    print '{malformed' > "$run_dir/completion.json"
  fi
fi
if [[ "$FLEET_MODE" == task-first && "$call_no" == 1 ]]; then
  exit 4
fi
if [[ "$FLEET_MODE" == provider-first && "$call_no" == 1 ]]; then
  exit 3
fi
print delivered
FLEET_STUB
chmod +x "$FLEET_ROOT/fake-agent"
WORKJET_STATE_DIR="$FLEET_ROOT/state" WORKJET_PROVIDER_SLOTS=1 \
  CLAUDE_AGENT_BIN="$FLEET_ROOT/fake-agent" \
  "$ROOT/bin/claude-fleet" bulk-generation "$FLEET_ROOT/one.md" "$FLEET_ROOT/two.md" \
  > "$FLEET_ROOT/stdout" 2> "$FLEET_ROOT/stderr"
fleet_rc=$?
fleet_calls="$(wc -l < "$FLEET_ROOT/state/calls" | tr -d ' ')"
if [[ $fleet_rc -eq 0 && "$fleet_calls" == 2 && ! -e "$FLEET_ROOT/state/overlap" ]] && \
   [[ "$(grep -c '^success' "$FLEET_ROOT/stdout")" == 2 ]]; then
  pass 'fleet one-slot semaphore serializes two briefs'
else
  LAST_RC=$fleet_rc
  LAST_OUT="$FLEET_ROOT/stdout"
  LAST_ERR="$FLEET_ROOT/stderr"
  fail 'fleet one-slot semaphore serializes two briefs'
fi

mkdir -p "$FLEET_ROOT/receipt-state"
WORKJET_STATE_DIR="$FLEET_ROOT/receipt-state" WORKJET_PROVIDER_SLOTS=1 FLEET_MODE=receipt-aggregate \
  CLAUDE_AGENT_BIN="$FLEET_ROOT/fake-agent" \
  "$ROOT/bin/claude-fleet" bulk-generation "$FLEET_ROOT/one.md" "$FLEET_ROOT/two.md" \
  > "$FLEET_ROOT/receipt-stdout" 2> "$FLEET_ROOT/receipt-stderr"
receipt_fleet_rc=$?
receipt_summary="$(awk -F '\t' '$1 == "success" && $2 == "valid" {print $3}' "$FLEET_ROOT/receipt-stdout")"
if [[ $receipt_fleet_rc -eq 0 && ${#receipt_summary} -eq 160 ]] && \
   grep -q $'^success\tvalid\tfleet summary ' "$FLEET_ROOT/receipt-stdout" && \
   grep -q $'^success\tinvalid\t<none>' "$FLEET_ROOT/receipt-stdout"; then
  pass 'fleet aggregates receipt health with a bounded summary'
else
  LAST_RC=$receipt_fleet_rc; LAST_OUT="$FLEET_ROOT/receipt-stdout"; LAST_ERR="$FLEET_ROOT/receipt-stderr"
  fail 'fleet aggregates receipt health with a bounded summary'
fi

mkdir -p "$FLEET_ROOT/task-state"
WORKJET_STATE_DIR="$FLEET_ROOT/task-state" WORKJET_PROVIDER_SLOTS=1 FLEET_MODE=task-first \
  CLAUDE_AGENT_BIN="$FLEET_ROOT/fake-agent" \
  "$ROOT/bin/claude-fleet" bulk-generation "$FLEET_ROOT/one.md" "$FLEET_ROOT/two.md" \
  > "$FLEET_ROOT/task-stdout" 2> "$FLEET_ROOT/task-stderr"
task_fleet_rc=$?
task_calls="$(wc -l < "$FLEET_ROOT/task-state/calls" | tr -d ' ')"
if [[ $task_fleet_rc -eq 4 && "$task_calls" == 2 ]] && \
   grep -q '^task-failed' "$FLEET_ROOT/task-stdout" && grep -q '^success' "$FLEET_ROOT/task-stdout"; then
  pass 'fleet task failure does not stop queued briefs'
else
  LAST_RC=$task_fleet_rc
  LAST_OUT="$FLEET_ROOT/task-stdout"
  LAST_ERR="$FLEET_ROOT/task-stderr"
  fail 'fleet task failure does not stop queued briefs'
fi

mkdir -p "$FLEET_ROOT/provider-state"
WORKJET_STATE_DIR="$FLEET_ROOT/provider-state" WORKJET_PROVIDER_SLOTS=1 FLEET_MODE=provider-first \
  CLAUDE_AGENT_BIN="$FLEET_ROOT/fake-agent" \
  "$ROOT/bin/claude-fleet" bulk-generation "$FLEET_ROOT/one.md" "$FLEET_ROOT/two.md" \
  > "$FLEET_ROOT/provider-stdout" 2> "$FLEET_ROOT/provider-stderr"
provider_fleet_rc=$?
provider_calls="$(wc -l < "$FLEET_ROOT/provider-state/calls" | tr -d ' ')"
if [[ $provider_fleet_rc -eq 3 && "$provider_calls" == 1 ]] && \
   grep -q '^provider-failed' "$FLEET_ROOT/provider-stdout" && grep -q '^skipped-provider' "$FLEET_ROOT/provider-stdout"; then
  pass 'fleet provider failure stops queued briefs'
else
  LAST_RC=$provider_fleet_rc
  LAST_OUT="$FLEET_ROOT/provider-stdout"
  LAST_ERR="$FLEET_ROOT/provider-stderr"
  fail 'fleet provider failure stops queued briefs'
fi

(( failures == 0 )) || exit 1
run_agent opus-quota bulk-generation -p task
if [[ $LAST_RC -eq 0 ]] && grep -Fq 'QUOTA FALLBACK' "$LAST_ERR" && grep -Fq 'opus quota fallback delivery' "$LAST_OUT"; then
  pass 'quota-walled required worker falls back to claude-opus automatically'
else
  fail 'quota-walled required worker falls back to claude-opus automatically'
fi

if grep -Fq 'WORKJET HEALTH PROBE PROMPT BEGIN' "$ROOT/bin/claude-agent" && \
   ! grep -Fq 'Reply with the token: OK' "$ROOT/bin/claude-agent" && \
   ! grep -Fq 'Commit in green slices: a timeout must still land value. No subagents.' "$ROOT/bin/claude-agent"; then
  pass 'dispatcher health probe prompt is loaded from visible Workjet rules'
else
  fail 'dispatcher health probe prompt is loaded from visible Workjet rules'
fi

print 'dispatcher tests: PASS'
