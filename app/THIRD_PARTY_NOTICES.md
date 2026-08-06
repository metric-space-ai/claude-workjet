# Workjet third-party notices

Workjet's optional remote Pi Code runtime is built from the following packages
actually present in the esbuild metafile:

| Package | Version | SPDX license |
| --- | ---: | --- |
| `@earendil-works/pi-agent-core` | 0.80.2 | MIT |
| `@earendil-works/pi-ai` | 0.80.2 | MIT |
| `openai` | 6.26.0 | Apache-2.0 |
| `partial-json` | 0.1.7 | MIT |
| `typebox` | 1.1.38 | MIT |

The Pi packages are sourced from `https://github.com/earendil-works/pi` at the
audited tag `v0.80.2` and commit
`0201806adfa825ab3d7957a4267d46e5030fd357`.

The npm-published Pi packages identify publish gitHead
`ec6311beb5b24fc918e5031173608447582d7262`. Its four commits after the audited
tag affect release changelogs and GitHub workflows, not package code.

Copyright and license rights remain with their respective authors. Relevant
attributions from the exact package metadata and license files are:

- Pi Agent Core and Pi AI: Copyright (c) 2025 Mario Zechner, MIT.
- OpenAI Node: Copyright 2026 OpenAI, Apache License 2.0.
- partial-json: Copyright (c) 2023 Promplate Dev Team, MIT.
- TypeBox: Copyright (c) 2017-2026 Haydn Paterson, MIT.

The machine-readable inventory in
`ReleaseInputs/ctox-pi-sidecar.licenses.json` records the registry URL,
integrity, repository, license, and bundled input count for every package in
the release bundle. The complete corresponding texts are committed under
`ReleaseInputs/licenses/` and copied verbatim into the signed app at
`Contents/Resources/ThirdPartyLicenses/`. Thus the distributable remains
self-contained and does not rely on a live registry or upstream repository to
deliver mandatory license terms.
