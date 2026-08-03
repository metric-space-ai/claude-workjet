# Workjet menu bar app

Native macOS 14+ menu bar UI for the existing Workjet skill and worker fleet.
It manages `~/.claude/workjet/AGENTS.md`; Claude Code continues to enter through
`/workjet`, and Fable remains the only orchestrator.

```sh
swift test
./build-app.sh
open dist/Workjet.app
```

Set `WORKJET_PREVIEW=1` when launching the executable for a read-only visual
preview backed by default sample data. The live app stores its versioned config
under `~/Library/Application Support/Workjet/` and credentials in Keychain.
