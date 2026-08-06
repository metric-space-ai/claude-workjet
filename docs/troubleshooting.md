# Troubleshooting

## The first Swift build fails

Confirm the supported platform and toolchain:

```sh
uname -m
sw_vers -productVersion
xcode-select -p
swift --version
```

Workjet currently requires macOS 14 or newer on Apple Silicon. If command-line tools are missing, install or select them with Xcode before retrying:

```sh
xcode-select --install
```

Then clear only a disposable scratch path and rerun:

```sh
rm -rf /tmp/workjet-swift-build
swift test --package-path app --scratch-path /tmp/workjet-swift-build
```

Do not delete Workjet application state to fix a compiler error.

## `build-app.sh` cannot find `rsvg-convert`

The release-shaped bundle generates the `.icns` file from the checked-in SVG source:

```sh
brew install librsvg
command -v rsvg-convert
./app/build-app.sh
```

A normal `swift test` or `swift run` does not require `librsvg`.

## The app launches but no window appears

Workjet is a menu-bar app. Look for the Workjet turbine icon in the macOS menu bar and click it. For an explicit debug preview:

```sh
WORKJET_PREVIEW=1 WORKJET_OPEN_POPOVER=1 \
  swift run --package-path app WorkjetApp
```

If another Workjet process is running, quit it from the menu-bar context menu before launching a different build.

## Claude does not see updated workers

Existing Claude Code and Claude Desktop sessions retain the prompt captured at session start.

1. In Workjet, confirm the configuration and managed prompt synchronized successfully.
2. Check that the managed file exists:

   ```sh
   test -f ~/.claude/workjet/AGENTS.md
   ```

3. Check for exactly one marked include:

   ```sh
   grep -n '@workjet/AGENTS.md' ~/.claude/CLAUDE.md
   ```

4. Fully start a new Claude session.

Do not add a second manual include. The installer and activation repair path own one marked block and preserve unrelated global content.

To remove only the global activation:

```sh
workjet activation uninstall
```

## A provider is configured but the worker is unavailable

Configuration is not runtime proof. Check:

- the worker points to the intended account or provider pool;
- the account is connected and exposes the selected model;
- the endpoint and authentication mode match the provider;
- Keychain access was explicitly allowed for the operation;
- a remote target can receive the selected route;
- CLIProxy-backed OAuth is treated as a gateway-managed pool, not a guaranteed pinned account.

Do not paste API keys, tokens, cookies, or provider response bodies into an issue. Use the bug template's redaction checklist.

## A remote computer fails host-key verification

Workjet intentionally fails closed.

- Compare the displayed fingerprint through an independent trusted channel.
- If the host was rebuilt or its SSH key changed, verify that change before replacing the confirmed entry.
- Confirm the configured private known-hosts path still exists and is owner-only.
- Confirm the SSH username, port, host, and optional identity-file path are correct.

Never bypass the error with `StrictHostKeyChecking=no`.

## A remote repository snapshot exceeds the limit

Repository-backed remote Git bundles are capped at 64 MiB. Remove or ignore large generated files that should not be part of the task, then retry. Workjet includes non-ignored untracked files, so a large untracked artifact can exceed the cap even when it is not committed.

Useful checks:

```sh
git status --short
git ls-files --others --exclude-standard
```

Do not add secrets to `.gitignore` as a substitute for removing them from the worktree or secret storage.

## The remote machine asks for GitHub credentials

That is not part of Workjet's repository transport. Workjet sends a Git bundle over verified SSH and does not clone or fetch the origin remotely. A remote harness, custom script, or repository hook may be attempting its own network Git operation. Inspect that behavior before providing credentials.

Remote machines do not need a GitHub account, origin credentials, or a forwarded SSH agent for the Workjet snapshot and result path.

## Remote events show a gap or interrupted connection

Workjet validates an exclusive sequence cursor. It does not silently skip missing events.

- Retry after the transport is available.
- Check the computer and run diagnostics in the app.
- Do not mark the run successful based only on a worker receipt.
- If the run reached a terminal state, inspect and import the result bundle explicitly.
- If the host cannot supply a continuous event range, treat the gap as missing evidence.

## Greppy is enabled but not used

Greppy injection requires all of the following:

- a compatible coding harness;
- a repository-backed task;
- the skill enabled by catalog default or worker override;
- a healthy `greppy --version` result on the exact target;
- an intact managed prompt source block.

If any condition is missing, Workjet leaves the base brief unchanged. This is expected and does not block the worker. The web-only research worker and incompatible harnesses do not receive Greppy.

## Gatekeeper rejects a ZIP or app

There is no public signed binary release yet. A source build is ad-hoc signed unless you supplied a Developer ID identity. Ad-hoc signing can pass local `codesign` verification but is not a notarized public release.

For a future tagged release, verify:

```sh
codesign --verify --deep --strict --verbose=4 Workjet.app
xcrun stapler validate Workjet.app
spctl --assess --type execute --verbose=4 Workjet.app
shasum -a 256 -c Workjet-<version>-macos-arm64.zip.sha256
```

Download only the archive and checksum attached by the repository's tag workflow.

## Before filing a bug

Record:

- Workjet commit or future release version;
- macOS version and Apple-Silicon model class;
- build or install command;
- exact reproduction steps;
- expected and observed behavior;
- the smallest sanitized diagnostic excerpt.

Remove API keys, tokens, cookies, private keys, host fingerprints, real hostnames, usernames, account labels, private repository names and paths, source code, diffs, prompts, and provider request or response bodies.
