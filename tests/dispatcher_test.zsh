#!/bin/zsh
emulate -L zsh
setopt pipe_fail

ROOT=${0:A:h:h}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/workjet-dispatcher.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/bin" "$TMP_ROOT/work"

make_stub() {
  local name=$1
  cat > "$TMP_ROOT/bin/$name" <<'STUB'
#!/bin/zsh
name=${0:t}
kind=task
[[ " $* " == *"Reply with the token: OK"* ]] && kind=probe
print -r -- "${name}:${kind}:args=$*" >> "$STUB_LOG"

case "$STUB_SCENARIO:$name:$kind" in
  success-words:claude-minimax:probe|provider-fallback:claude-minimax:probe|task-failed:claude-minimax:probe|timeout-group:claude-minimax:probe|git-success:claude-minimax:probe)
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
  provider-fallback:claude-minimax:task)
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
    exit 0
    ;;
  degrade-path:claude-kimi:task)
    print 'explicit degraded result'
    exit 0
    ;;
  task-failed:claude-minimax:task)
    print '429 quota exceeded in stdout must not classify provider failure'
    print -u2 'compiler exited while applying requested edit'
    exit 7
    ;;
  timeout-group:claude-minimax:task)
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
for worker in claude-minimax claude-kimi claude-sol; do make_stub "$worker"; done

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
    AGENT_PROBE_TIMEOUT=10 \
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

run_agent success-words bulk-generation -p task
if [[ $LAST_RC -eq 0 ]] && grep -Fq 'fixed the 403 rate limit handling' "$LAST_OUT" && ! log_has 'claude-kimi'; then
  pass 'rc 0 ignores provider words in stdout and does not fallback'
else
  fail 'rc 0 ignores provider words in stdout and does not fallback'
fi

run_agent provider-fallback --degrade bulk-generation -p task
if [[ $LAST_RC -eq 10 ]] && grep -Fq 'fallback after task provider error' "$LAST_OUT" && log_has 'claude-kimi:task'; then
  pass 'provider error in stderr permits explicit fallback'
else
  fail 'provider error in stderr permits explicit fallback'
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

run_agent task-failed bulk-generation -p task
if [[ $LAST_RC -eq 4 ]] && grep -Fq 'TASK_FAILED worker=claude-minimax' "$LAST_ERR" && ! log_has 'claude-kimi'; then
  pass 'unstructured nonzero exits 4 without fallback'
else
  fail 'unstructured nonzero exits 4 without fallback'
fi

run_agent degrade-path --degrade bulk-generation -p task
if [[ $LAST_RC -eq 10 ]] && grep -Fq 'explicit degraded result' "$LAST_OUT" && grep -Fq 'DEGRADED FALLBACK' "$LAST_ERR"; then
  pass '--degrade follows the role chain'
else
  fail '--degrade follows the role chain'
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
    AGENT_PROBE_TIMEOUT=10 \
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
   grep -Fq 'PATH_VIOLATION: result.txt' "$LAST_ERR"; then
  pass 'allowed-path audit records violations without failing delivery'
else
  fail 'allowed-path audit records violations without failing delivery'
fi

rm -f "$GIT_REPO/dirty.txt"
touch -t 202001010000 "$worktree"
GIT_EXPECT_DIRTY=0
run_git_agent probe-unavailable cleanup-unmarked bulk-generation -p task
if [[ $LAST_RC -eq 3 && -d "$worktree" ]] && grep -Fq 'retained unmarked worktree older than 24h' "$LAST_ERR"; then
  pass 'unmarked old worktree is warned about and retained'
else
  fail 'unmarked old worktree is warned about and retained'
fi

HOME="$TMP_ROOT/home" WORKJET_STATE_DIR="$GIT_STATE" \
  "$ROOT/bin/claude-agent" runs mark "$run_id" integrated >"$TMP_ROOT/mark.out" 2>"$TMP_ROOT/mark.err"
mark_rc=$?
run_git_agent probe-unavailable cleanup-marked bulk-generation -p task
if [[ $mark_rc -eq 0 && $LAST_RC -eq 3 && ! -e "$worktree" ]] && \
   grep -Fq 'removing integrated worktree older than 24h' "$LAST_ERR"; then
  pass 'marked old worktree is removed'
else
  fail 'marked old worktree is removed'
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
print 'dispatcher tests: PASS'
