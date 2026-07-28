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
    AGENT_BIN_DIR="$TMP_ROOT/bin" AGENT_PROBE_TIMEOUT=2 AGENT_TIMEOUT=2 \
    STUB_PROMPT="$dir/prompt" MAIN_REPO="$REPO" STUB_MODE="${CASE_MODE:-normal}" \
    "$ROOT/bin/claude-agent" --run-dir "$dir/run" "$@" >"$dir/out" 2>"$dir/err")
  RUN_RC=$?
  RUN_DIR="$dir/run"
  RUN_OUT="$dir/out"
  RUN_ERR="$dir/err"
  RUN_PROMPT="$dir/prompt"
}

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

(( failures == 0 )) || exit 1
print 'wrapper rework tests: PASS'
