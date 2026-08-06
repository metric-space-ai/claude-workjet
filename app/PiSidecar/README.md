# Workjet Pi sidecar release source

This directory is the reviewable source and deterministic build recipe for the
Workjet remote Pi coding sidecar. It embeds the real
`@earendil-works/pi-agent-core@0.80.2` agent loop and the narrowly imported
`@earendil-works/pi-ai@0.80.2` OpenAI Responses adapter.

Pi Agent Core 0.80.2 imports validation, `EventStream`, and its default provider
fallback from the broad `pi-ai/compat` entrypoint. The build aliases that one
entrypoint to `src/pi-ai-compat-shim.ts`: validation and `EventStream` remain
available, while the unused default stream fails closed. Workjet always passes
the explicit loopback Responses stream into `runAgentLoop`. This removes the
otherwise bundled provider catalog without modifying or forking Pi Agent Core.
For the same reason, the public Agent Core package entry is resolved at build
time directly to that pinned package's `dist/agent-loop.js`; the TypeScript
source continues to type-check against the public package export. This avoids
bundling unrelated session, skills, and prompt-template exports.

Upstream is `https://github.com/earendil-works/pi`. Version `0.80.2` is tagged
at `0201806adfa825ab3d7957a4267d46e5030fd357`. The npm packages report publish
`gitHead` `ec6311beb5b24fc918e5031173608447582d7262`; the four intervening upstream
commits only change release changelogs and GitHub workflows.

The daemon accepts exactly one newline-delimited JSON request over a Unix
socket and then closes and removes the socket. `health` is model-free. A
`turn` starts a fresh Pi agent loop over a fresh in-memory file snapshot and
returns messages, events, and a sorted snapshot. Only `read`, `write`, `list`,
and `grep` are exposed. There is no host shell, host source filesystem, TUI,
plugin loader, package manager, updater, or model-provider fan-out.

The only model network path is Pi's OpenAI Responses adapter. The request must
identify `provider: "ctox-gateway"`, `api: "openai-responses"`, and a
credential-free HTTP loopback `baseUrl`; the sidecar supplies only a public
sentinel because the owning gateway holds real credentials. Node filesystem
access is used by this entry solely to remove the Unix socket. Any other Node
filesystem code reported in the bundle is transitive OpenAI adapter support,
not a sidecar tool surface.

Build with Node 22.19 or newer:

```sh
npm ci
npm run check
npm run build
npm run verify:bundle
npm run smoke
```

The build writes the bundle, esbuild metafile, and SHA-256 manifest under
`../ReleaseInputs`. Release verification is performed from that directory with
`shasum -a 256 -c ctox-pi-sidecar.sha256`.
