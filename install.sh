#!/bin/sh
# claude-workjet installer: copies the wrappers to ~/.local/bin and prepares
# the config skeleton. Idempotent; never overwrites existing keys.
set -eu

GLOBAL_PROMPT=0
case "${1-}" in
  "") ;;
  --global-prompt) GLOBAL_PROMPT=1 ;;
  *) echo "usage: ./install.sh [--global-prompt]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: ./install.sh [--global-prompt]" >&2; exit 2; }

BIN="$HOME/.local/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$BIN"
for w in claude-sol claude-minimax claude-kimi claude-agent claude-fleet; do
  cp "$HERE/bin/$w" "$BIN/$w"
  chmod +x "$BIN/$w"
  echo "installed $BIN/$w"
done

mkdir -p "$HOME/.config/secrets" "$HOME/.config/kimi" \
  "$HOME/.claude/skills/workjet" "$HOME/.claude/workjet"
cp "$HERE/skills/workjet/SKILL.md" "$HOME/.claude/skills/workjet/SKILL.md"
cp "$HERE/AGENTS.md" "$HOME/.claude/workjet/AGENTS.md"
echo "installed skill: /workjet"
echo "installed workjet rules: ~/.claude/workjet/AGENTS.md (skill-only; not auto-loaded)"

if [ "$GLOBAL_PROMPT" -eq 1 ]; then
  stamp=$(date +%Y%m%dT%H%M%S)
  if [ -f "$HOME/.claude/CLAUDE.md" ]; then
    cp "$HOME/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md.bak-workjet-$stamp"
    echo "backed up ~/.claude/CLAUDE.md to ~/.claude/CLAUDE.md.bak-workjet-$stamp"
  fi
  if [ -f "$HOME/.claude/AGENTS.md" ]; then
    cp "$HOME/.claude/AGENTS.md" "$HOME/.claude/AGENTS.md.bak-workjet-$stamp"
    echo "backed up ~/.claude/AGENTS.md to ~/.claude/AGENTS.md.bak-workjet-$stamp"
  fi
  cp "$HERE/AGENTS.md" "$HOME/.claude/AGENTS.md"
  printf '@AGENTS.md\n' > "$HOME/.claude/CLAUDE.md"
  echo "installed global prompt redirect: ~/.claude/CLAUDE.md -> ~/.claude/AGENTS.md"
  echo "merge any pre-existing rules from the .bak-workjet-$stamp files into ~/.claude/AGENTS.md, then review the diff"
fi
create_key_skeleton() {
  file=$1
  label=$2
  [ -f "$file" ] && return 0
  (umask 077 && printf 'CHANGE-ME\n' > "$file")
  chmod 600 "$file"
  echo "created $file — put your $label key in it"
}
create_key_skeleton "$HOME/.config/secrets/sol-key" "CLIProxyAPI"
create_key_skeleton "$HOME/.config/secrets/minimax-key" "MiniMax"
create_key_skeleton "$HOME/.config/kimi/api-key" "Kimi"

echo
echo "Next steps:"
echo "  1. Fill in the key files above and keep them chmod 600."
echo "  2. Sol: set the same random local key in ~/.config/secrets/sol-key and CLIProxyAPI,"
echo "     then run: brew install cliproxyapi && cliproxyapi -codex-login && brew services start cliproxyapi"
if [ "$GLOBAL_PROMPT" -eq 1 ]; then
  echo "  3. Global orchestration is installed; merge any backed-up rules as noted above."
else
  echo "  3. Default orchestration: invoke /workjet in Claude Code; no global prompt was changed."
  echo "     Optional global mode: rerun $HERE/install.sh --global-prompt and merge any backed-up rules."
fi
echo "  4. Verify: claude-minimax -p 'Reply with the token: OK' < /dev/null"
