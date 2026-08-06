# Changelog

All notable changes to Workjet will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Version entries will be added only when a real repository tag and release exist.

## Unreleased

### Added

- Native macOS 14+ Apple-Silicon menu-bar app and `workjet` CLI.
- Configurable workers, provider accounts and pools, local and remote computers, harness lifecycle, managed prompt sources, and bounded run telemetry.
- Immutable Git bundle transport for repository-backed remote runs and explicit result-ref import.
- Managed completion receipts and optional Greppy skill behavior for compatible workers.
- Reproducible Pi sidecar checks and release-shaped local packaging.
- GitHub CI, Pages deployment for `site/**`, issue forms, and a tag-gated notarized release workflow.

### Security

- Strict SSH host-key verification and disabled agent forwarding.
- Keychain-backed provider credentials and private local state permissions.
- Developer ID, notarization, stapling, Gatekeeper, checksum, and archive-inspection gates before tag publication.

### Release status

- No public signed binary release exists yet.
- Build-from-source is the supported distribution path until a `v*` tag workflow publishes a verified release.
