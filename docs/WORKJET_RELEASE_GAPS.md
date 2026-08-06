# Workjet release readiness

Status: Unreleased

This document summarizes remaining release evidence for the current source tree. It does not claim that a public binary exists, that private development-machine results apply to every checkout, or that a configured provider or harness is commercially available.

The normative acceptance stories remain in [WORKJET_USER_STORIES.md](WORKJET_USER_STORIES.md).

## Current product state

Implemented source paths include:

- native macOS 14+ Apple-Silicon menu-bar app and CLI;
- versioned local configuration, Keychain credential references, and managed prompt synchronization;
- configurable provider accounts and pools;
- local and host-key-verified SSH or Tailscale remote computers;
- typed harness lifecycle and execution paths;
- immutable Git bundle workspace and result transport;
- bounded local and remote telemetry;
- structured, non-authoritative completion receipts;
- default-on Greppy configuration for compatible coding workers with launch-time availability checks;
- ad-hoc local packaging and a tag-only signed/notarized release workflow.

These source paths are not equivalent to a public signed release or complete real-world acceptance evidence.

## Gates before the first public release

### Build and automated verification

- Run the complete Swift package suite from a clean checkout.
- Run Xcode build-for-testing and the complete production-view UI click suite.
- Run dispatcher, wrapper, and worktree retention shell contracts.
- Run Pi sidecar type, build, bundle, smoke, and reproducibility checks.
- Build and inspect the release-shaped app twice from clean environments.
- Confirm repository hygiene and documentation checks are green.

### Real UI and accessibility

- Complete the full click journey for workers, providers, computers, settings navigation, persistence, stop, and recovery.
- Capture current screenshots using non-secret fixture data.
- Verify keyboard navigation, VoiceOver labels, focus on validation, contrast, and dense layouts.

### Remote execution

- Complete a named, authorized SSH or Tailscale smoke on a disposable or designated host.
- Verify independent host fingerprint approval and changed-key failure.
- Verify setup, content-addressed deployment, harness lifecycle, repository snapshot, result import, reconnect, stop, cleanup, and retention.
- Verify the Pi Code Bubblewrap canary when sandboxing is enabled.
- Confirm the remote host requires no GitHub account, origin credentials, origin access, or SSH agent forwarding.

### Providers and credentials

- Complete real or provider-approved sandbox tests for every enabled account path.
- Verify model discovery, account identity handling, deterministic direct-account pool order, classified failover, and truthful unavailable capacity.
- Verify CLIProxy gateway behavior is described as gateway-managed rather than per-request account pinning.
- Complete locked and available-Keychain tests and confirm no credential or OAuth prompt appears on passive launch or navigation.
- Confirm logs and diagnostics contain no credentials.

### Prompt, skills, and telemetry

- Map every managed prompt byte to a visible editable or generated source.
- Verify completion receipts remain untrusted claims and do not affect fallback or exit classification.
- Verify Greppy injection only after repository and target health checks, and verify the web-only research worker remains disabled for Greppy.
- Complete local and remote no-ghost, bounded-retention, cursor-gap, reconnect, and exact-stop evidence.

### Distribution and security

- Configure Developer ID and App Store Connect notarization secrets in GitHub Actions.
- Push a final version tag only after the app version and changelog match it.
- Require the tag workflow to pass signing, notarization, stapling, Gatekeeper, archive inspection, and SHA-256 checksum generation.
- Verify the attached archive on a clean supported Mac.
- Complete source and dependency license review.
- Complete the private vulnerability reporting setup described in [../SECURITY.md](../SECURITY.md).

## Release truth

Until all required gates are complete and the tag workflow publishes assets, the correct public status is:

- build-from-source available;
- no public signed binary release;
- release automation present but not evidence of a release;
- provider and worker support configurable and environment-dependent;
- remote security properties bounded by the documented host, credential, and sandbox assumptions.
