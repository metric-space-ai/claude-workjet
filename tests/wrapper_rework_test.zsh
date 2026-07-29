#!/bin/zsh
emulate -L zsh
setopt pipe_fail

ROOT=${0:A:h:h}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/workjet-rework.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/bin" "$TMP_ROOT/state"

cat > "$TMP_ROOT/bin/claude-minimax" <<'STUB'
#!/bin/zsh
prompt=""
while (( $# )); do
  if [[ "$1" == -p && $# -gt 1 ]]; then prompt="$2"; shift 2; else shift; fi
done
name=${0:t}
kind=task
[[ "$prompt" == *"Reply with the token: OK"* ]] && kind=probe
[[ -n "$STUB_CALL_LOG" ]] && print -r -- "$name:$kind" >> "$STUB_CALL_LOG"
if [[ "$kind" == probe ]]; then
  case "$STUB_MODE:$name" in
    retry-probe:claude-minimax)
      count=0
      [[ -f "$STUB_COUNT_FILE" ]] && count="$(<"$STUB_COUNT_FILE")"
      (( ++count ))
      print -r -- "$count" > "$STUB_COUNT_FILE"
      if (( count <= 3 )); then
        print -u2 '503 service unavailable'
        exit 1
      fi
      ;;
    timeout-probe:claude-minimax)
      sleep 30
      ;;
    timeout-probe:*)
      print -u2 '503 service unavailable'
      exit 1
      ;;
    auth-heal:claude-sol)
      if [[ ! -f "$PROXY_RESTART_MARKER" ]]; then
        print -u2 'auth_unavailable: cached oauth rejected'
        exit 1
      fi
      ;;
    auth-dead:claude-sol)
      print -u2 'auth_unavailable: oauth expired'
      exit 1
      ;;
    auth-dead:claude-opus)
      print -u2 '503 service unavailable'
      exit 1
      ;;
  esac
  print OK
  exit 0
fi
print -rn -- "$prompt" > "$STUB_PROMPT"
if [[ "$STUB_MODE" == tamper ]]; then
  print intruder > "$MAIN_REPO/tampered.txt"
elif [[ "$STUB_MODE" == timeout ]]; then
  print partial > partial.txt
  sleep 30
fi
print delivered
STUB
chmod +x "$TMP_ROOT/bin/claude-minimax"
for worker in claude-kimi claude-sol claude-opus; do
  cp "$TMP_ROOT/bin/claude-minimax" "$TMP_ROOT/bin/$worker"
done
cat > "$TMP_ROOT/bin/lsof" <<'STUB'
#!/bin/zsh
[[ "$*" == *"-t"* ]] && print -r -- "${CLIPROXY_PID:-12345}"
exit 0
STUB
cat > "$TMP_ROOT/bin/brew" <<'STUB'
#!/bin/zsh
print -r -- "$*" >> "$PROXY_RESTART_LOG"
touch "$PROXY_RESTART_MARKER"
exit 0
STUB
chmod +x "$TMP_ROOT/bin/lsof" "$TMP_ROOT/bin/brew"

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.com
print base > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -qm base

failures=0
pass() { print "ok - $1"; }
fail() { print -u2 "not ok - $1"; (( failures++ )); }
run_agent() {
  local label=$1; shift
  local dir="$TMP_ROOT/$label"
  mkdir -p "$dir/run"
  (cd "$REPO" && HOME="$TMP_ROOT/home" WORKJET_STATE_DIR="$TMP_ROOT/state" \
    PATH="$TMP_ROOT/bin:$PATH" AGENT_BIN_DIR="$TMP_ROOT/bin" OPUS_TOKEN_FILE="$TMP_ROOT/opus-token" \
    AGENT_PROBE_TIMEOUT="${CASE_PROBE_TIMEOUT:-10}" AGENT_PROBE_RETRIES="${CASE_PROBE_RETRIES:-0}" \
    AGENT_PROBE_BACKOFF="${CASE_PROBE_BACKOFF:-0}" AGENT_PROBE_CACHE_TTL="${CASE_PROBE_CACHE_TTL:-0}" \
    AGENT_TIMEOUT=2 AGENT_HEARTBEAT_INTERVAL=1 AGENT_DIFFSTAT_INTERVAL=1 \
    CLIPROXY_TOKEN_FILE="$TMP_ROOT/proxy-token" CLIPROXY_PID=12345 \
    CLIPROXY_START_EPOCH="${CASE_PROXY_START_EPOCH:-1}" CLIPROXY_RESTART_DELAY=0 \
    PROXY_RESTART_LOG="$TMP_ROOT/proxy-restarts" PROXY_RESTART_MARKER="$TMP_ROOT/proxy-restarted" \
    STUB_PROMPT="$dir/prompt" STUB_COUNT_FILE="$dir/count" STUB_CALL_LOG="$TMP_ROOT/stub-calls" \
    MAIN_REPO="$REPO" STUB_MODE="${CASE_MODE:-normal}" \
    "$ROOT/bin/claude-agent" --run-dir "$dir/run" "$@" >"$dir/out" 2>"$dir/err")
  RUN_RC=$?
  RUN_DIR="$dir/run"
  RUN_OUT="$dir/out"
  RUN_ERR="$dir/err"
  RUN_PROMPT="$dir/prompt"
}

print token > "$TMP_ROOT/opus-token"
print oauth > "$TMP_ROOT/proxy-token"
chmod 600 "$TMP_ROOT/opus-token" "$TMP_ROOT/proxy-token"
HOME="$TMP_ROOT/home" WORKJET_STATE_DIR="$TMP_ROOT/state" AGENT_BIN_DIR="$TMP_ROOT/bin" \
  OPUS_TOKEN_FILE="$TMP_ROOT/opus-token" AGENT_PROBE_TIMEOUT=10 \
  "$ROOT/bin/claude-agent" doctor > "$TMP_ROOT/doctor.out" 2> "$TMP_ROOT/doctor.err"
doctor_rc=$?
if [[ $doctor_rc -eq 0 ]] && grep -Fq $'WORKER\tSTATUS\tDETAIL' "$TMP_ROOT/doctor.out" && \
   [[ "$(grep -c $'^claude-.*\tOK\t' "$TMP_ROOT/doctor.out")" == 4 ]]; then
  pass 'doctor prints a health table covering every documented rung'
else
  fail 'doctor prints a health table covering every documented rung'
fi

mv "$TMP_ROOT/bin/claude-minimax" "$TMP_ROOT/bin/claude-minimax.off"
run_agent dead-warning research -p "$(printf 'health warning prompt %.0s' {1..12})"
mv "$TMP_ROOT/bin/claude-minimax.off" "$TMP_ROOT/bin/claude-minimax"
if [[ $RUN_RC -eq 0 ]] && grep -Fq 'doctor warning: documented rung(s) dead: claude-minimax' "$RUN_ERR"; then
  pass 'launcher warns on every start while a documented rung is dead'
else
  fail 'launcher warns on every start while a documented rung is dead'
fi

if grep -Fq 'PROBE_TIMEOUT=${AGENT_PROBE_TIMEOUT:-120}' "$ROOT/bin/claude-agent" && \
   grep -Fq 'PROBE_CACHE_TTL=${AGENT_PROBE_CACHE_TTL:-600}' "$ROOT/bin/claude-agent"; then
  pass 'probe defaults are 120 seconds with a ten-minute last-good cache'
else
  fail 'probe defaults are 120 seconds with a ten-minute last-good cache'
fi

rm -rf "$TMP_ROOT/state/probe-last-good"
CASE_MODE=retry-probe CASE_PROBE_RETRIES=3 run_agent retry-probe bulk-generation \
  -p "$(printf 'retry probe through the task worker path %.0s' {1..8})"
if [[ $RUN_RC -eq 0 && "$(<"$RUN_DIR/../count")" == 4 ]] && \
   [[ "$(grep -c '^claude-minimax:probe$' "$TMP_ROOT/stub-calls")" -ge 4 ]]; then
  pass 'probe retries three times with backoff through the task invocation path'
else
  fail 'probe retries three times with backoff through the task invocation path'
fi

rm -rf "$TMP_ROOT/state/probe-last-good"
: > "$TMP_ROOT/stub-calls"
CASE_PROBE_CACHE_TTL=600 run_agent cache-first bulk-generation \
  -p "$(printf 'cache this healthy worker probe %.0s' {1..10})"
cache_first_rc=$RUN_RC
CASE_PROBE_CACHE_TTL=600 run_agent cache-second bulk-generation \
  -p "$(printf 'reuse this healthy worker probe %.0s' {1..10})"
if [[ $cache_first_rc -eq 0 && $RUN_RC -eq 0 ]] && \
   [[ "$(grep -c '^claude-minimax:probe$' "$TMP_ROOT/stub-calls")" == 1 ]] && \
   grep -Fq 'probe last-good cache hit' "$RUN_ERR"; then
  pass 'last-good cache skips a re-probe within ten minutes'
else
  fail 'last-good cache skips a re-probe within ten minutes'
fi

rm -rf "$TMP_ROOT/state/probe-last-good"
: > "$TMP_ROOT/stub-calls"
CASE_MODE=timeout-probe CASE_PROBE_RETRIES=3 CASE_PROBE_TIMEOUT=1 run_agent timeout-probe \
  bulk-generation -p "$(printf 'classify probe timeout separately %.0s' {1..10})"
if [[ $RUN_RC -eq 3 ]] && grep -Fq 'probe timeout_unavailable after 4 attempt(s)' "$RUN_ERR" && \
   ! grep -Fq 'USER ACTION REQUIRED' "$RUN_ERR" && \
   [[ "$(grep -c '^claude-minimax:probe$' "$TMP_ROOT/stub-calls")" == 4 ]]; then
  pass 'probe timeout is retried and reported separately from authentication'
else
  fail 'probe timeout is retried and reported separately from authentication'
fi

rm -rf "$TMP_ROOT/state/probe-last-good"
rm -f "$TMP_ROOT/proxy-restarts" "$TMP_ROOT/proxy-restarted"
: > "$TMP_ROOT/stub-calls"
CASE_MODE=auth-heal CASE_PROBE_RETRIES=3 run_agent auth-heal implementation-hard \
  -p "$(printf 'reload a fresh proxy oauth token %.0s' {1..10})"
if [[ $RUN_RC -eq 0 && "$(wc -l < "$TMP_ROOT/proxy-restarts" | tr -d ' ')" == 1 ]] && \
   [[ "$(grep -c '^claude-sol:probe$' "$TMP_ROOT/stub-calls")" == 2 ]] && \
   grep -Fq 'token is newer than proxy start' "$RUN_ERR" && \
   ! grep -Fq 'USER ACTION REQUIRED' "$RUN_ERR"; then
  pass 'fresh proxy token triggers one restart and re-probe before user action'
else
  fail 'fresh proxy token triggers one restart and re-probe before user action'
fi

rm -rf "$TMP_ROOT/state/probe-last-good"
rm -f "$TMP_ROOT/proxy-restarts" "$TMP_ROOT/proxy-restarted"
: > "$TMP_ROOT/stub-calls"
CASE_MODE=auth-dead CASE_PROBE_RETRIES=3 CASE_PROXY_START_EPOCH=4102444800 run_agent auth-dead \
  implementation-hard -p "$(printf 'exhaust authentication retries first %.0s' {1..10})"
restart_count=0
[[ -f "$TMP_ROOT/proxy-restarts" ]] && restart_count="$(wc -l < "$TMP_ROOT/proxy-restarts" | tr -d ' ')"
if [[ $RUN_RC -eq 3 && $restart_count -eq 0 ]] && \
   [[ "$(grep -c '^claude-sol:probe$' "$TMP_ROOT/stub-calls")" == 4 ]] && \
   [[ "$(grep -c 'USER ACTION REQUIRED: run: cliproxyapi -codex-login' "$RUN_ERR")" == 1 ]] && \
   grep -Fq 'probe auth_unavailable after 4 attempt(s)' "$RUN_ERR"; then
  pass 'auth user instruction appears only after retries and eligible restart handling'
else
  fail 'auth user instruction appears only after retries and eligible restart handling'
fi

print short > "$TMP_ROOT/short.md"
run_agent short --brief "$TMP_ROOT/short.md" bulk-generation
if [[ $RUN_RC -eq 2 ]] && grep -Fq 'brief is too short' "$RUN_ERR" && [[ ! -s "$RUN_PROMPT" ]]; then
  pass 'short brief is refused before worker launch'
else
  fail 'short brief is refused before worker launch'
fi

python3 - <<'PY' > "$TMP_ROOT/brief.md"
print("Implement the requested fixture exactly. " * 10)
print("FILE WHITELIST: base.txt")
PY
run_agent preamble --brief "$TMP_ROOT/brief.md" bulk-generation
worktree="$(<"$RUN_DIR/worktree-path")"
if [[ $RUN_RC -eq 0 ]] && grep -Fq "You are in an isolated worktree at $worktree." "$RUN_PROMPT" && \
   grep -Fq 'Never cd to another checkout. Commit in green slices: a timeout must still land value. No subagents.' "$RUN_PROMPT"; then
  pass 'wrapper prefixes the worker prompt with the isolation preamble'
else
  fail 'wrapper prefixes the worker prompt with the isolation preamble'
fi

CASE_MODE=tamper run_agent tamper --brief "$TMP_ROOT/brief.md" bulk-generation
if [[ $RUN_RC -eq 4 ]] && [[ -f "$RUN_DIR/tamper" ]] && grep -Fq 'TAMPER DETECTED' "$RUN_ERR"; then
  pass 'main checkout tampering overrides a successful worker result'
else
  fail 'main checkout tampering overrides a successful worker result'
fi
rm -f "$REPO/tampered.txt"

CASE_MODE=timeout run_agent timeout --brief "$TMP_ROOT/brief.md" bulk-generation
run_id="$(<"$RUN_DIR/run-id")"
protected_ref="$(<"$RUN_DIR/protected-ref")"
protected_subject="$(git -C "$REPO" show -s --format=%s "$protected_ref" 2>/dev/null)"
if [[ $RUN_RC -eq 3 && "$protected_ref" == "refs/workjet/$run_id" && "$protected_subject" == "wip: $run_id" ]] && \
   [[ -s "$RUN_DIR/timeout.diff" ]] && git -C "$REPO" show "$protected_ref:partial.txt" | grep -Fq partial; then
  pass 'timeout commits partial work on the protected ref and writes a diff report'
else
  fail 'timeout commits partial work on the protected ref and writes a diff report'
fi

if [[ -s "$RUN_DIR/brief.sha256" && -s "$RUN_DIR/pid" && -f "$RUN_DIR/heartbeat" && -s "$RUN_DIR/exit" ]] && \
   [[ -f "$RUN_DIR/exit-code" && "$(<"$RUN_DIR/exit-code")" == 3 ]] && \
   find "$RUN_DIR/journal" -name 'diffstat-[0-9][0-9][0-9][0-9]' -type f | grep -q .; then
  pass 'run journal records hash, pid, heartbeat, diffstat snapshots, and exit marker'
else
  fail 'run journal records hash, pid, heartbeat, diffstat snapshots, and exit marker'
fi

ACCEPT_REPO="$TMP_ROOT/accept-repo"
ACCEPT_STATE="$TMP_ROOT/accept-state"
ACCEPT_RUN="$ACCEPT_STATE/runs/accept-violation"
mkdir -p "$ACCEPT_REPO/.workjet" "$ACCEPT_RUN" "$ACCEPT_STATE/run-index"
git -C "$ACCEPT_REPO" init -q
git -C "$ACCEPT_REPO" config user.name test
git -C "$ACCEPT_REPO" config user.email test@example.com
cat > "$ACCEPT_REPO/.workjet/checks.sh" <<'CHECKS'
#!/bin/sh
printf checked > "$CHECK_MARKER"
CHECKS
chmod +x "$ACCEPT_REPO/.workjet/checks.sh"
print base > "$ACCEPT_REPO/base.txt"
git -C "$ACCEPT_REPO" add .workjet/checks.sh base.txt
git -C "$ACCEPT_REPO" commit -qm base
accept_branch="$(git -C "$ACCEPT_REPO" branch --show-current)"
git -C "$ACCEPT_REPO" checkout -qb accept-result
print allowed > "$ACCEPT_REPO/allowed.txt"
print forbidden > "$ACCEPT_REPO/forbidden.txt"
git -C "$ACCEPT_REPO" add allowed.txt forbidden.txt
git -C "$ACCEPT_REPO" commit -qm result
accept_sha="$(git -C "$ACCEPT_REPO" rev-parse HEAD)"
git -C "$ACCEPT_REPO" update-ref refs/workjet/accept-violation "$accept_sha"
git -C "$ACCEPT_REPO" checkout -q "$accept_branch"
python3 - <<'PY' > "$ACCEPT_RUN/brief.txt"
print("Validate the protected result before integrating it. " * 8)
print("## FILE WHITELIST")
print("- ONLY allowed.txt. FORBIDDEN: forbidden.txt")
print("## HARD RULES")
print("Reject every path outside the verbatim whitelist block.")
PY
print refs/workjet/accept-violation > "$ACCEPT_RUN/protected-ref"
print "$ACCEPT_RUN" > "$ACCEPT_STATE/run-index/accept-violation"
(cd "$ACCEPT_REPO" && HOME="$TMP_ROOT/home" WORKJET_STATE_DIR="$ACCEPT_STATE" \
  CHECK_MARKER="$TMP_ROOT/check-marker" "$ROOT/bin/claude-agent" accept accept-violation \
  > "$TMP_ROOT/accept.out" 2> "$TMP_ROOT/accept.err")
accept_rc=$?
if [[ $accept_rc -ne 0 && "$(git -C "$ACCEPT_REPO" rev-parse HEAD)" == "$accept_sha" ]] && \
   [[ -f "$TMP_ROOT/check-marker" ]] && grep -Fq 'MERGE: PASS' "$TMP_ROOT/accept.out" && \
   grep -Fq 'CHECKS: PASS' "$TMP_ROOT/accept.out" && grep -Fq 'WHITELIST: FAIL' "$TMP_ROOT/accept.out" && \
   grep -Fxq 'forbidden.txt' "$ACCEPT_RUN/accept-whitelist-violations.txt"; then
  pass 'accept merges the protected ref, runs checks, and rejects whitelist violations'
else
  fail 'accept merges the protected ref, runs checks, and rejects whitelist violations'
fi

(( failures == 0 )) || exit 1
print 'wrapper rework tests: PASS'
