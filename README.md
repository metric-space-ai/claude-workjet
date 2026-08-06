# Workjet

Workjet is an open-source native macOS menu-bar app and CLI for managing specialized coding-agent workers across local and remote computers while Claude remains the orchestrator.

[Project site](https://metric-space-ai.github.io/claude-workjet/) · [Documentation](docs/architecture.md) · [Security](SECURITY.md)

<p align="center">
  <img src="docs/images/workjet-main.png" alt="Workjet menu showing configured workers and their current readiness" width="496">
</p>

<p align="center"><em>Actual Workjet source build with an anonymized, non-secret configuration.</em></p>

## Product boundary

Workjet provides configuration, execution plumbing, and observable run state. It does not replace the agent that plans and integrates the work.

- **Claude remains the orchestrator.** Claude chooses a configured worker, writes the brief, and verifies the result.
- **Workjet is not a hosted service.** The app, CLI, configuration, credentials, and run state stay on computers you control.
- **Workjet is not a second orchestrator.** It does not invent workflows or silently choose a different worker.
- **Workers are fire-and-forget.** A worker receives a bounded brief and returns output when it finishes. It cannot be steered mid-run.
- **Receipts are claims, not proof.** Structured completion receipts and telemetry help with triage. Claude still inspects the code and diff and reruns the relevant tests.
- **Provider support is configurable.** Provider names and logos identify compatible configuration paths, not commercial affiliation, endorsement, account availability, or guaranteed model access.

## Core workflow

1. Configure the provider accounts and compatible endpoints you use.
2. Keep work local or add a remote computer over Tailscale or SSH with an explicitly confirmed host key.
3. Define named workers with a harness, model, provider route, instructions, skills, and target computer.
4. Start a fresh Claude Code or Claude Desktop session. The installer-managed global include exposes the current Workjet worker contract.
5. Claude invokes the stable `workjet` CLI to list, describe, start, observe, and stop a worker.
6. Workjet records bounded telemetry and, where supported, a structured completion receipt. Claude independently verifies the delivered result.

## Security model

- Provider secrets are stored in macOS Keychain. Non-secret configuration is stored under `~/Library/Application Support/Workjet/`.
- Remote commands use strict, host-key-verified OpenSSH for both SSH and Tailscale-discovered computers. SSH agent forwarding is disabled.
- Remote repositories are transferred as immutable Git bundles over the verified connection. The remote computer does not need a GitHub account, origin credentials, origin network access, or a forwarded SSH agent.
- Remote result import creates only `refs/workjet/<run-id>` in the source repository. It does not merge, rebase, stage, checkout, or modify the working tree.
- Worktrees and harness tool policies are useful boundaries, but they are not a complete operating-system sandbox. Pi Code can additionally require Bubblewrap on a supported Linux remote and fails closed when that requested sandbox is unavailable.

See [Remote execution and security](docs/remote-execution-security.md) and [Security policy](SECURITY.md) for the full boundary.

## Architecture

```text
Claude Code / Claude Desktop
          |
          | chooses a worker and calls the stable CLI
          v
     workjet CLI  <---->  WorkjetCore  <---->  local persistence / Keychain
          |                    |
          |                    +----> menu-bar UI and telemetry
          |
          +----> local harness process
          |
          +----> strict SSH over LAN or Tailscale
                         |
                         +----> versioned remote host runtime
                         +----> detached Git-bundle worktree
```

The menu-bar app edits configuration and the visible managed prompt. The CLI is the execution boundary used by Claude. WorkjetCore owns persistence, provider routing, harness lifecycle, workspace snapshots, remote protocol validation, and telemetry. See [Architecture](docs/architecture.md).

## Build from source

Requirements: macOS 14 or newer, Apple Silicon, Git, and Xcode command-line tools.

```sh
git clone https://github.com/metric-space-ai/claude-workjet.git
cd claude-workjet
xcode-select -p
swift test --package-path app
swift run --package-path app WorkjetApp
```

The app appears in the menu bar. This path uses a debug build and does not install or change your global Claude prompt.

To create the local release-shaped app bundle:

```sh
brew install librsvg
./app/build-app.sh
open app/dist/Workjet.app
```

Without release credentials, `build-app.sh` creates an ad-hoc-signed Apple-Silicon build for local use. For test, Xcode, packaging, installer, Pi sidecar, and release verification commands, see [app/README.md](app/README.md).

## Release status

There is no public signed binary release yet. Building from source is supported.

A `v*` tag can create a GitHub Release only after the repository workflow completes Developer ID signing, notarization, stapling, Gatekeeper assessment, archive inspection, and SHA-256 checksum generation. Until that workflow succeeds for a tag, do not treat locally built ZIP files as public releases. See [Release process](docs/releasing.md).

## Documentation

- [Developer build and verification guide](app/README.md)
- [Architecture](docs/architecture.md)
- [Remote execution and security](docs/remote-execution-security.md)
- [Workers, skills, receipts, and telemetry](docs/workers-skills-telemetry.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Changelog](CHANGELOG.md)
- [Release acceptance stories](docs/WORKJET_USER_STORIES.md)
- [Current release gaps](docs/WORKJET_RELEASE_GAPS.md)
- [t3code design reference notes](docs/T3CODE_REMOTE_INTEGRATION.md)

## License

Workjet is available under the [MIT License](LICENSE).
