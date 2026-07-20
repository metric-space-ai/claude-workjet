#!/bin/sh
# claude-workjet installer: copies the wrappers to ~/.local/bin and prepares
# the config skeleton. Idempotent; never overwrites existing keys.
set -eu

BIN="$HOME/.local/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$BIN"
for w in claude-sol claude-minimax claude-kimi claude-agent; do
  cp "$HERE/bin/$w" "$BIN/$w"
  chmod +x "$BIN/$w"
  echo "installed $BIN/$w"
done

mkdir -p "$HOME/.config/secrets" "$HOME/.config/kimi" "$HOME/.claude/skills/workjet"
cp "$HERE/skills/workjet/SKILL.md" "$HOME/.claude/skills/workjet/SKILL.md"
echo "installed skill: /workjet"
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
echo "  3. Orchestrator prompt: cp $HERE/AGENTS.md ~/.claude/AGENTS.md && printf '@AGENTS.md\n' > ~/.claude/CLAUDE.md (merge if one exists)."
echo "  4. Verify: claude-minimax -p 'Reply with the token: OK' < /dev/null"
