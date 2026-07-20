#!/bin/zsh
emulate -L zsh
setopt pipe_fail

ROOT=${0:A:h:h}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/workjet-dispatcher.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
mkdir -p "$TMP_ROOT/home/.local/bin" "$TMP_ROOT/work"

make_stub() {
  local name=$1
  cat > "$TMP_ROOT/home/.local/bin/$name" <<'STUB'
#!/bin/zsh
name=${0:t}
kind=task
[[ " $* " == *"Reply with the token: OK"* ]] && kind=probe
print -r -- "$name:$kind" >> "$STUB_LOG"
[[ "$kind" == probe ]] && { print OK; exit 0; }
case "$STUB_SCENARIO:$name" in
  success-words:claude-minimax)
    print 'Report: fixed the 403 rate limit handling.'
    exit 0
    ;;
  provider-fallback:claude-minimax)
    print -u2 '429 quota exceeded'
    exit 1
    ;;
  provider-fallback:claude-kimi)
    print 'fallback result'
    exit 0
    ;;
  task-failed:claude-minimax)
    print -u2 'compiler exited while applying requested edit'
    exit 7
    ;;
  *)
    print "unexpected invocation: $STUB_SCENARIO $name" >&2
    exit 9
    ;;
esac
STUB
  chmod +x "$TMP_ROOT/home/.local/bin/$name"
}
for worker in claude-minimax claude-kimi claude-sol; do make_stub "$worker"; done

failures=0
run_case() {
  local label=$1 scenario=$2 expected_rc=$3 expected_out=$4 expected_err=$5
  local case_dir="$TMP_ROOT/$scenario"
  local out="$case_dir/stdout" err="$case_dir/stderr" log="$case_dir/log"
  mkdir -p "$case_dir"
  local agent_options=()
  [[ "$scenario" == provider-fallback ]] && agent_options=(--degrade)
  (cd "$TMP_ROOT/work" && HOME="$TMP_ROOT/home" STUB_SCENARIO="$scenario" STUB_LOG="$log" \
    AGENT_PROBE_TIMEOUT=3 AGENT_TIMEOUT=3 "$ROOT/bin/claude-agent" "${agent_options[@]}" simple -p task >"$out" 2>"$err")
  local rc=$?
  if [[ $rc -ne $expected_rc ]] || { [[ -n "$expected_out" ]] && ! grep -Fq -- "$expected_out" "$out"; } || { [[ -n "$expected_err" ]] && ! grep -Fq -- "$expected_err" "$err"; }; then
    print -u2 "not ok - $label"
    print -u2 "  rc=$rc expected=$expected_rc"
    print -u2 "  stdout: $(<"$out")"
    print -u2 "  stderr: $(<"$err")"
    (( failures++ ))
  else
    print "ok - $label"
  fi
}

run_case 'rc 0 ignores provider words in stdout' success-words 0 'fixed the 403 rate limit handling' 'answered by: claude-minimax'
run_case 'provider error in stderr permits explicit fallback' provider-fallback 10 'fallback result' 'DEGRADED FALLBACK'
run_case 'unstructured nonzero is TASK_FAILED' task-failed 4 '' 'TASK_FAILED worker=claude-minimax'

if grep -q 'claude-kimi' "$TMP_ROOT/task-failed/log" 2>/dev/null; then
  print -u2 'not ok - TASK_FAILED did not stop fallback chain'
  (( failures++ ))
else
  print 'ok - TASK_FAILED stops fallback chain'
fi

(( failures == 0 )) || exit 1
print 'dispatcher tests: PASS'
