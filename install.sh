#!/bin/sh
# claude-workjet installer: copies the wrappers to ~/.local/bin and prepares
# the config skeleton. Idempotent; never overwrites existing keys.
set -eu

[ "$#" -eq 0 ] || { echo "usage: ./install.sh" >&2; exit 2; }

BIN="$HOME/.local/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$BIN"
for w in claude-sol claude-minimax claude-kimi workjet-observe claude-agent claude-fleet; do
  cp "$HERE/bin/$w" "$BIN/$w"
  chmod +x "$BIN/$w"
  echo "installed $BIN/$w"
done

mkdir -p "$HOME/.config/secrets" "$HOME/.config/kimi" \
  "$HOME/.claude/skills/workjet" "$HOME/.claude/workjet"
cp "$HERE/skills/workjet/SKILL.md" "$HOME/.claude/skills/workjet/SKILL.md"
echo "installed skill: /workjet"
if [ ! -e "$HOME/.claude/workjet/AGENTS.md" ]; then
  (umask 077 && printf '%s\n' 'Du bist Fable, der einzige Workjet-Orchestrator. Worker-Rollen und Modellanweisungen werden von der Workjet-App aus der Worker-Konfiguration ergänzt.' > "$HOME/.claude/workjet/AGENTS.md")
  echo "created workjet rules: ~/.claude/workjet/AGENTS.md (the app adds managed worker blocks)"
else
  echo "preserved workjet rules: ~/.claude/workjet/AGENTS.md (managed by the app)"
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
echo "  3. Invoke /workjet in Claude Code; Workjet never changes the global prompt."
echo "  4. Verify: claude-minimax -p 'Reply with the token: OK' < /dev/null"
