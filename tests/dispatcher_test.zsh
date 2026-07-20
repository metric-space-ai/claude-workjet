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
print -r -- "$name:$kind" >> "$STUB_LOG"

case "$STUB_SCENARIO:$name:$kind" in
  success-words:claude-minimax:probe|provider-fallback:claude-minimax:probe|task-failed:claude-minimax:probe|timeout-group:claude-minimax:probe)
    print OK
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
run_agent() {
  local scenario=$1; shift
  local case_dir="$TMP_ROOT/case-$scenario"
  mkdir -p "$case_dir/run"
  LAST_OUT="$case_dir/stdout"
  LAST_ERR="$case_dir/stderr"
  LAST_LOG="$case_dir/log"
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

(( failures == 0 )) || exit 1
print 'dispatcher tests: PASS'
