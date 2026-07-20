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

mkdir -p "$HOME/.config/secrets" "$HOME/.config/kimi"
[ -f "$HOME/.config/secrets/minimax.env" ] || {
  printf 'export MINIMAX_API_KEY="YOUR_KEY"\n' > "$HOME/.config/secrets/minimax.env"
  chmod 600 "$HOME/.config/secrets/minimax.env"
  echo "created ~/.config/secrets/minimax.env — put your MiniMax key in it"
}
[ -f "$HOME/.config/kimi/api-key" ] || {
  printf 'YOUR_KEY\n' > "$HOME/.config/kimi/api-key"
  chmod 600 "$HOME/.config/kimi/api-key"
  echo "created ~/.config/kimi/api-key — put your Kimi key in it"
}

echo
echo "Next steps:"
echo "  1. Fill in the key files above."
echo "  2. Sol: brew install cliproxyapi && cliproxyapi -codex-login && brew services start cliproxyapi"
echo "     then replace sol-local-CHANGE-ME in $BIN/claude-sol with your CLIProxyAPI key."
echo "  3. Orchestrator prompt: cp $HERE/CLAUDE.md ~/.claude/CLAUDE.md (merge if one exists)."
echo "  4. Verify: claude-minimax -p 'Reply with the token: OK' < /dev/null"
