# Workjet public site

Static, dependency-free files for GitHub Pages. The public path is expected to be `/claude-workjet/`.

## Local preview

From the repository root:

```sh
python3 -m http.server 4173 --directory site
```

Open `http://localhost:4173/`. Test the fallback directly at `http://localhost:4173/404.html`.

No package install, build step, framework, network request, analytics service, cookie, or web font is used at runtime.

## Content contract

The site must remain truthful to these boundaries:

- Workjet is a native macOS 14+ Apple-Silicon menu-bar app and CLI.
- The calling agent remains the sole orchestrator. Workjet is a control plane, prompt/config extension, and runtime evidence surface.
- Workers are fire-and-forget. Their completion receipts are non-authoritative claims that the orchestrator verifies against code, diffs, path policy, and tests.
- Remote shell workspaces travel as immutable Git bundles over an already host-key-verified SSH/Tailscale channel. Remote hosts need no GitHub account, origin access, repository credentials, or SSH agent forwarding.
- Result import is explicit and limited to a `refs/workjet/<run-id>` ref. It does not alter the active checkout, index, or HEAD.
- Greppy is centrally managed, default-on only for supported coding harnesses, target-verified before injection, and disabled for the online-research worker.
- Do not present a public download until a notarized GitHub Release exists. Until then, use “release candidate in verification” and link to source, docs, and releases.
- Do not add customer claims, provider affiliations, usage numbers, speed claims, model availability promises, or security certifications without repository evidence.

## Asset contract

`assets/workjet-mark.svg` is the site-owned, flat-color adaptation of the eight-blade app mark in `app/Sources/WorkjetApp/WorkjetMark.swift` and `app/Sources/WorkjetApp/Resources/Brand/workjet-app-icon.svg`.

The page reserves these exact paths for authentic product captures:

- `assets/screenshots/workjet-overview.png`
- `assets/screenshots/workjet-worker-skills.png`
- `assets/screenshots/workjet-remote-computer.png`
- `assets/screenshots/workjet-prompt-telemetry.png`

Do not replace them with fabricated UI, mock terminal output, stock imagery, or generated dashboards. Each image must be a real capture from the production Workjet app without altering product state. The current verified captures are Retina PNGs at 1164 by 1788 pixels, cropped only to remove the UI-test window chrome and screen-recording indicator. Keep future replacements at least this sharp and keep the existing HTML alt text aligned with the actual capture. Missing assets intentionally show a plain explanatory state.

## Editing rules

- Keep all runtime assets local to `site/`.
- Follow the visual contract in [`../DESIGN.md`](../DESIGN.md).
- Preserve semantic landmarks, the skip link, visible keyboard focus, and reduced-motion behavior.
- Keep navigation and CTA targets valid for the GitHub Pages base path.
- Use no framework, build tooling, web font, remote script, tracker, or network runtime dependency.
- Run `node site/check-design.mjs` and the acceptance commands in the task brief after each change.
