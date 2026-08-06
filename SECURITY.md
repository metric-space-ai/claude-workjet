# Security policy

## Supported versions

Workjet has not published a signed public release. Security fixes currently target the `main` branch and the current build-from-source state. When versioned public releases exist, this section will list their support status.

## Report a vulnerability privately

Do not include vulnerability details, credentials, private repository data, host information, or exploit steps in a public issue.

1. Open this repository's **Security** tab.
2. If **Report a vulnerability** is available, use GitHub private vulnerability reporting.
3. If private vulnerability reporting is not available, follow GitHub's Security Advisories guidance to establish a private report with the repository maintainers. If GitHub provides no private reporting path, open a public issue containing no vulnerability details and ask the maintainers to enable private vulnerability reporting.

Do not send secrets as proof. Use synthetic credentials and redacted examples whenever possible.

A useful report includes:

- affected commit, source build, or future release version;
- macOS version and Apple-Silicon model class;
- affected local, SSH, or Tailscale path;
- concise impact and prerequisites;
- minimal reproduction using non-secret data;
- whether provider credentials, Keychain items, repository contents, Git bundles, host keys, telemetry, or release artifacts may be exposed;
- suggested remediation, if known.

Maintainers will coordinate validation and disclosure through the private GitHub thread. No fixed response or remediation deadline is promised.

## Security boundaries

Workjet's relevant boundaries include:

- provider credentials stored in macOS Keychain;
- versioned non-secret configuration under `~/Library/Application Support/Workjet/`;
- a managed prompt under `~/.claude/workjet/AGENTS.md` and one marked global include;
- strict host-key verification for SSH and Tailscale-discovered computers;
- disabled SSH agent forwarding;
- immutable Git bundle transport with SHA-256 and Git object validation;
- remote worktrees and explicit local result refs;
- temporary release keychains and notarization keys in GitHub Actions;
- bounded run telemetry and non-authoritative completion receipts.

Worktrees, command allowlists, prompt instructions, and harness tool policy are not a full OS sandbox. Do not report their mere existence as a sandbox escape. Reports showing a violation of a documented boundary, an unsafe default, credential exposure, signature/notarization bypass, host-key bypass, path traversal, command injection, or untrusted artifact execution are in scope.

## Log and artifact handling

Before sharing diagnostics, remove or replace:

- API keys, bearer tokens, OAuth tokens, cookies, and Keychain output;
- private keys and SSH agent data;
- real hostnames, IP addresses, usernames, account labels, and host fingerprints;
- private repository names, paths, source, diffs, prompts, and Git bundle contents;
- provider request and response bodies;
- notarization credentials, certificates, and signing material.

When in doubt, describe the shape of the data instead of attaching the raw file.
