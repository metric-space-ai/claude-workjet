#!/bin/zsh
emulate -L zsh
setopt pipe_fail

ROOT=${0:A:h:h}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/workjet-gc.XXXXXX")
if [[ -z "${WORKJET_GC_KEEP_TMP:-}" ]]; then
  trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
else
  print -u2 "worktree gc test data: $TMP_ROOT"
fi
STATE_ROOT="$TMP_ROOT/state"
REPO="$TMP_ROOT/repo"
mkdir -p "$STATE_ROOT/worktrees/repo" "$STATE_ROOT/runs" "$STATE_ROOT/run-index" "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.com
print base > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -qm base

failures=0
pass() { print "ok - $1"; }
fail() { print -u2 "not ok - $1"; (( ++failures )); }

make_run() {
  local id="$1" state="$2" marker="$3" protect="${4:-1}"
  local wt="$STATE_ROOT/worktrees/repo/$id" run="$STATE_ROOT/runs/$id" ref="refs/workjet/$id"
  git -C "$REPO" worktree add --detach --quiet "$wt" HEAD || return 1
  mkdir -p "$run"
  print -r -- "$run" > "$STATE_ROOT/run-index/$id"
  print -r -- "$wt" > "$run/worktree-path"
  print -r -- "{\"schemaVersion\":1,\"state\":\"$state\"}" > "$run/run-state.json"
  [[ -n "$marker" ]] && : > "$run/$marker"
  if (( protect )); then
    git -C "$REPO" update-ref "$ref" HEAD || return 1
    print -r -- "$ref" > "$run/protected-ref"
  fi
}

run_gc() {
  local label="$1"; shift
  WORKJET_STATE_DIR="$STATE_ROOT" "$ROOT/bin/claude-agent" runs "$@" \
    > "$TMP_ROOT/$label.out" 2> "$TMP_ROOT/$label.err"
}

make_run dry-run completed integrated
run_gc dry prune --dry-run
if [[ $? -eq 0 && -d "$STATE_ROOT/worktrees/repo/dry-run" ]] && \
   grep -Fq 'would prune integrated worktree' "$TMP_ROOT/dry.out"; then
  pass 'dry-run reports eligible worktree without removing it'
else
  fail 'dry-run reports eligible worktree without removing it'
fi

run_gc actual gc
if [[ $? -eq 0 && ! -e "$STATE_ROOT/worktrees/repo/dry-run" && \
      -d "$STATE_ROOT/runs/dry-run" && -f "$STATE_ROOT/runs/dry-run/integrated" ]] && \
   git -C "$REPO" rev-parse --verify -q 'refs/workjet/dry-run^{commit}' >/dev/null; then
  pass 'gc removes through Git while retaining journal, marker, and protected ref'
else
  fail 'gc removes through Git while retaining journal, marker, and protected ref'
fi

run_gc repeat prune
if [[ $? -eq 0 ]] && grep -Fq 'scanned=0 pruned=0 retained=0' "$TMP_ROOT/repeat.out"; then
  pass 'prune is idempotent'
else
  fail 'prune is idempotent'
fi

make_run active running integrated
run_gc active prune
if [[ $? -eq 0 && -d "$STATE_ROOT/worktrees/repo/active" ]] && \
   grep -Fq 'run is not terminal (state=running)' "$TMP_ROOT/active.out"; then
  pass 'active run is retained with its reason'
else
  fail 'active run is retained with its reason'
fi

make_run dirty completed abandoned
print dirty > "$STATE_ROOT/worktrees/repo/dirty/untracked.txt"
run_gc dirty prune
if [[ $? -eq 0 && -f "$STATE_ROOT/worktrees/repo/dirty/untracked.txt" ]] && \
   grep -Fq 'worktree is dirty' "$TMP_ROOT/dirty.out"; then
  pass 'dirty terminal worktree is retained with its reason'
else
  fail 'dirty terminal worktree is retained with its reason'
fi

print '*.cache' > "$REPO/.gitignore"
git -C "$REPO" add .gitignore
git -C "$REPO" commit -qm 'ignore cache files'
make_run ignored completed abandoned
print irreplaceable > "$STATE_ROOT/worktrees/repo/ignored/result.cache"
run_gc ignored prune
if [[ $? -eq 0 && -f "$STATE_ROOT/worktrees/repo/ignored/result.cache" ]] && \
   grep -Fq 'worktree is dirty' "$TMP_ROOT/ignored.out"; then
  pass 'ignored files make a worktree dirty for safe pruning'
else
  fail 'ignored files make a worktree dirty for safe pruning'
fi

make_run unprotected completed integrated 0
run_gc unprotected prune
if [[ $? -eq 0 && -d "$STATE_ROOT/worktrees/repo/unprotected" ]] && \
   grep -Fq 'missing or mismatched protected ref metadata' "$TMP_ROOT/unprotected.out"; then
  pass 'unprotected terminal worktree is retained with its reason'
else
  fail 'unprotected terminal worktree is retained with its reason'
fi

make_run missing-ref completed integrated
git -C "$REPO" update-ref -d refs/workjet/missing-ref
run_gc missing-ref prune
if [[ $? -eq 0 && -d "$STATE_ROOT/worktrees/repo/missing-ref" ]] && \
   grep -Fq 'protected ref is missing or not a commit' "$TMP_ROOT/missing-ref.out"; then
  pass 'missing protected ref keeps its terminal worktree'
else
  fail 'missing protected ref keeps its terminal worktree'
fi

make_run alive completed integrated
print -r -- "$$" > "$STATE_ROOT/runs/alive/pid"
run_gc alive prune
if [[ $? -eq 0 && -d "$STATE_ROOT/worktrees/repo/alive" ]] && \
   grep -Fq 'is still alive' "$TMP_ROOT/alive.out"; then
  pass 'terminal run with a live process is retained with its reason'
else
  fail 'terminal run with a live process is retained with its reason'
fi

make_run mismatch completed integrated
print -r -- "$TMP_ROOT/outside" > "$STATE_ROOT/runs/mismatch/worktree-path"
run_gc mismatch prune
if [[ $? -eq 0 && -d "$STATE_ROOT/worktrees/repo/mismatch" ]] && \
   grep -Fq 'worktree path metadata is outside or does not match' "$TMP_ROOT/mismatch.out"; then
  pass 'mismatched path metadata cannot escape the worktree state root'
else
  fail 'mismatched path metadata cannot escape the worktree state root'
fi

make_run fresh-unmarked completed ''
touch -t "$(date -v-2d '+%Y%m%d%H%M.%S')" "$STATE_ROOT/worktrees/repo/fresh-unmarked"
WORKJET_STATE_DIR="$STATE_ROOT" "$ROOT/bin/claude-agent" runs prune --dry-run \
  > "$TMP_ROOT/unmarked-manual.out" 2> "$TMP_ROOT/unmarked-manual.err"
if [[ -d "$STATE_ROOT/worktrees/repo/fresh-unmarked" ]] && \
   grep -Fq 'run is unmarked' "$TMP_ROOT/unmarked-manual.out"; then
  pass 'explicit prune retains unmarked worktrees without the automatic age policy'
else
  fail 'explicit prune retains unmarked worktrees without the automatic age policy'
fi

WORKJET_STATE_DIR="$STATE_ROOT" "$ROOT/bin/claude-agent" runs prune --auto \
  > "$TMP_ROOT/unmarked-auto.out" 2> "$TMP_ROOT/unmarked-auto.err"
if [[ ! -e "$STATE_ROOT/worktrees/repo/fresh-unmarked" && \
      -f "$STATE_ROOT/runs/fresh-unmarked/pruned" ]] && \
   git -C "$REPO" rev-parse --verify -q 'refs/workjet/fresh-unmarked^{commit}' >/dev/null; then
  pass 'automatic age policy prunes only recoverable unmarked terminal worktrees'
else
  fail 'automatic age policy prunes only recoverable unmarked terminal worktrees'
fi

if rg -n 'rm -rf -- \"\$stale\"|worktree remove --force' "$ROOT/bin/claude-agent" >/dev/null; then
  fail 'dispatcher still contains a destructive worktree removal fallback'
else
  pass 'dispatcher has no destructive worktree removal fallback'
fi

(( failures == 0 )) || exit 1
print 'worktree gc tests: PASS'
