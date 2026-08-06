# CTOX Pi sidecar release input

Generated only from the reviewable source in `app/PiSidecar` using npm's integrity-locked clean install and esbuild 0.28.1.

- Pi upstream: https://github.com/earendil-works/pi
- Pi version: 0.80.2
- Upstream tag commit: `0201806adfa825ab3d7957a4267d46e5030fd357`
- npm publish gitHead: `ec6311beb5b24fc918e5031173608447582d7262`
- Bundle SHA-256: `6ca1537e9c25941550e42d42321ddbaab867b389141fa0675654ba22af68c583`
- Bundled packages: `@earendil-works/pi-agent-core@0.80.2`, `@earendil-works/pi-ai@0.80.2`, `openai@6.26.0`, `partial-json@0.1.7`, `typebox@1.1.38`
- External Node built-ins: `node:fs`, `node:net`, `node:path`, `node:url`

Verify with `shasum -a 256 -c ctox-pi-sidecar.sha256` from this directory. The metafile and license inventory are retained as audit evidence.
