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
if [[ "$prompt" == *"Reply with the token: OK"* ]]; then
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
    AGENT_BIN_DIR="$TMP_ROOT/bin" OPUS_TOKEN_FILE="$TMP_ROOT/opus-token" \
    AGENT_PROBE_TIMEOUT=10 AGENT_TIMEOUT=2 \
    AGENT_HEARTBEAT_INTERVAL=1 AGENT_DIFFSTAT_INTERVAL=1 \
    STUB_PROMPT="$dir/prompt" MAIN_REPO="$REPO" STUB_MODE="${CASE_MODE:-normal}" \
    "$ROOT/bin/claude-agent" --run-dir "$dir/run" "$@" >"$dir/out" 2>"$dir/err")
  RUN_RC=$?
  RUN_DIR="$dir/run"
  RUN_OUT="$dir/out"
  RUN_ERR="$dir/err"
  RUN_PROMPT="$dir/prompt"
}

print token > "$TMP_ROOT/opus-token"
chmod 600 "$TMP_ROOT/opus-token"
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

(( failures == 0 )) || exit 1
print 'wrapper rework tests: PASS'
