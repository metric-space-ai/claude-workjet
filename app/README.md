# Workjet app development guide

This directory contains the native macOS 14+ Apple-Silicon menu-bar app, the `workjet` CLI, shared `WorkjetCore`, tests, the reproducible Pi sidecar input, and the release packaging script.

Workjet is not a hosted service and does not orchestrate work itself. Claude remains the orchestrator. The app manages visible configuration, provider access, computers, workers, managed prompt content, and run telemetry. The CLI is the stable execution bridge Claude uses.

## Requirements

| Task | Requirements |
|---|---|
| Swift build and unit tests | macOS 14 or newer, Apple Silicon, Git, Xcode command-line tools with Swift 5.9 support |
| Xcode build and UI tests | Xcode with the `Workjet` macOS scheme |
| Release-shaped app bundle | The above plus `rsvg-convert` from Homebrew `librsvg` |
| Pi sidecar reproducibility checks | Node.js 22.19.0 or newer in the Node 22 line, plus npm |
| Remote execution | A supported remote host reached through host-key-verified SSH, optionally discovered through Tailscale |

Confirm the basic toolchain:

```sh
uname -m                    # arm64
sw_vers -productVersion     # 14 or newer
xcode-select -p
swift --version
git --version
```

## First local build

From the repository root:

```sh
swift test --package-path app
swift run --package-path app WorkjetApp
```

The debug app adds a menu-bar item. Quit it from the menu-bar context menu when finished. This command does not install the app or edit `~/.claude/CLAUDE.md`.

For a deterministic read-only preview configuration:

```sh
WORKJET_PREVIEW=1 WORKJET_OPEN_POPOVER=1 \
  swift run --package-path app WorkjetApp
```

`WORKJET_PREVIEW` is compiled into debug builds only. It does not provide release data or credentials.

## Package layout

`Package.swift` declares macOS 14 as the minimum platform and defines:

- `WorkjetCore`: persistence, prompt composition, provider routing, harness lifecycle, remote protocol, workspace snapshots, and telemetry.
- `WorkjetCLI`: the executable product named `workjet`.
- `WorkjetApp`: the SwiftUI/AppKit menu-bar executable with packaged resources.
- `WorkjetCoreTests`: the Swift package test target.

The Xcode project provides the `Workjet` scheme used for build-for-testing and the production-view click suite.

## Verification commands

Run commands from the repository root unless a section says otherwise.

### Swift package tests

```sh
swift test --package-path app
```

### Xcode build-for-testing

```sh
xcodebuild \
  -project app/Workjet.xcodeproj \
  -scheme Workjet \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/workjet-derived-data \
  build-for-testing \
  CODE_SIGNING_ALLOWED=NO
```

### Production-view UI click tests

Run from `app/`:

```sh
xcodebuild \
  -project Workjet.xcodeproj \
  -scheme Workjet \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  ONLY_ACTIVE_ARCH=YES \
  test
```

The suite launches the real `RootView` in a dedicated debug-only window with an isolated temporary home. It does not read production credentials or configuration. The optional live Tailscale case remains gated as documented in [UITests/README.md](UITests/README.md).

### Shell contracts

```sh
zsh tests/dispatcher_test.zsh
zsh tests/wrapper_rework_test.zsh
zsh tests/worktree_gc_test.zsh
```

These tests use local fixtures and stub workers. They do not require commercial provider accounts.

### Pi sidecar checks

```sh
npm ci --prefix app/PiSidecar
npm run check --prefix app/PiSidecar
npm run build --prefix app/PiSidecar
npm run verify:bundle --prefix app/PiSidecar
npm run smoke --prefix app/PiSidecar
npm run verify:reproducible --prefix app/PiSidecar
```

The checked-in release input and its SHA-256 manifest remain the packaging authority. The build does not fetch an unpinned executable payload.

## Build the app bundle

Install the icon renderer once:

```sh
brew install librsvg
```

Then build:

```sh
./app/build-app.sh
```

Outputs:

```text
app/dist/Workjet.app
app/dist/Workjet-0.1.0-macos-arm64.zip
```

The script:

1. Verifies the pinned Pi sidecar and third-party license inputs.
2. Builds `WorkjetApp` and `workjet` as arm64 release executables.
3. Packages SwiftPM resources, provider logos, the app icon, wrappers, notices, the pinned Pi runtime, and the generated default managed prompt.
4. Rejects symlinks and absolute user build paths in the bundle.
5. Creates a SHA-256 resource manifest.
6. Signs the embedded CLI and app.
7. If notarization credentials are supplied, submits the app, waits, staples it, validates the staple, and runs Gatekeeper assessment.
8. Publishes the app and release-shaped ZIP only after all preceding checks pass.

With no signing variables, the script creates an ad-hoc-signed local artifact. It is not a public release.

## Developer ID and notarization inputs

A distributable build requires:

```text
WORKJET_REQUIRE_RELEASE_SIGNING=1
WORKJET_SIGNING_IDENTITY="Developer ID Application: ..."
```

Choose one notarization method:

```text
WORKJET_NOTARY_PROFILE
```

or all three App Store Connect API-key inputs:

```text
WORKJET_NOTARY_KEY_ID
WORKJET_NOTARY_ISSUER_ID
WORKJET_NOTARY_KEY_PATH
```

Do not place certificates, private keys, provider credentials, or notarization secrets in the repository. The tag workflow imports release credentials into a temporary keychain and deletes temporary credential files under `always()` cleanup. See [Release process](../docs/releasing.md).

## Verify a built bundle

For a local artifact:

```sh
codesign --verify --deep --strict --verbose=4 app/dist/Workjet.app
lipo -archs app/dist/Workjet.app/Contents/MacOS/WorkjetApp
unzip -t app/dist/Workjet-0.1.0-macos-arm64.zip
```

For a notarized release candidate, also require:

```sh
xcrun stapler validate app/dist/Workjet.app
spctl --assess --type execute --verbose=4 app/dist/Workjet.app
```

A successful local `codesign` check does not prove Developer ID identity, notarization, stapling, or Gatekeeper acceptance.

## Install from source

From a clean source checkout:

```sh
brew install librsvg
./install.sh
```

If `app/dist/Workjet.app` is absent or incomplete, the installer builds it locally. It then verifies the bundle signatures and SHA-256 manifest before a rollback-safe transaction installs:

- `/Applications/Workjet.app`
- `workjet` and the bundled wrappers under `~/.local/bin/`
- the managed prompt at `~/.claude/workjet/AGENTS.md`
- one marked `@workjet/AGENTS.md` include in `~/.claude/CLAUDE.md`

The installer preserves unrelated global Claude content and does not modify project-local prompt files. A source checkout accepts its own valid ad-hoc build. An unpacked public release archive requires a Developer ID Application signature and Gatekeeper acceptance by default.

To remove only the global Workjet activation while retaining the app and configuration:

```sh
workjet activation uninstall
```

## Local state

The live app stores versioned non-secret state under:

```text
~/Library/Application Support/Workjet/
```

Provider credentials are stored in macOS Keychain. The managed Claude prompt is stored separately at `~/.claude/workjet/AGENTS.md`. Run journals and indexes use Workjet state paths managed by `WorkjetCore` and the wrapper tools.

Never attach these directories to an issue without inspecting and redacting account labels, repository paths, hostnames, usernames, provider output, and any accidental secret material.

## Remote repository transport

Repository-backed remote runs create an immutable Git bundle from the current worktree, including tracked edits, deletions, and non-ignored untracked files. The bundle is capped at 64 MiB and sent through strict host-key-verified SSH, including when Tailscale supplies discovery and the encrypted network path.

The remote computer does not need a GitHub account, origin credentials, forwarded SSH agents, or access to the Git origin. Result import verifies the returned Git bundle and writes only `refs/workjet/<run-id>` locally. See [Remote execution and security](../docs/remote-execution-security.md).

## Release status

No public signed binary release exists today. The source build is usable. Only a successful `v*` tag workflow may publish the notarized archive and checksum to a GitHub Release.
