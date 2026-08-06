# Release process

Workjet has no public signed binary release today. This document describes the repository automation that may create one in the future.

## Release boundary

Only a pushed `v*` tag can publish a GitHub Release. The release workflow has no manual publication path. A local `build-app.sh` ZIP or an ad-hoc GitHub Actions artifact is not a public release.

The app marketing version is currently read from `app/Info.plist`. The workflow requires the tag without its leading `v` to match that version before credentials are imported or a release is created.

## Repository configuration

Configure these GitHub Actions secrets:

```text
WORKJET_CERTIFICATE_P12_BASE64
WORKJET_CERTIFICATE_PASSWORD
WORKJET_NOTARY_KEY_BASE64
WORKJET_NOTARY_KEY_ID
WORKJET_NOTARY_ISSUER_ID
```

Configure this GitHub Actions variable:

```text
WORKJET_SIGNING_IDENTITY
```

The certificate secret is a base64-encoded Developer ID Application `.p12`. The notary key secret is a base64-encoded App Store Connect API `.p8`. Keep all values in GitHub's encrypted secret or variable storage. Do not commit them, print them, add them to artifacts, or paste them into an issue.

## Tag workflow gates

`.github/workflows/release.yml` runs only for tags matching `v*` and performs these gates in order:

1. Checkout with persisted Git credentials disabled.
2. Confirm required secrets and variables are present without printing their values.
3. Confirm the tag version matches the app version.
4. Install build dependencies.
5. Decode credentials into runner-temporary owner-only files.
6. Create and make a temporary keychain available.
7. Import the Developer ID certificate and verify the configured identity is present.
8. Run `app/build-app.sh` with release signing and App Store Connect notarization inputs.
9. Verify the Developer ID signature and arm64 architecture.
10. Validate the notarization staple.
11. Run Gatekeeper assessment.
12. Test and extract the ZIP into a temporary directory.
13. Inspect the archive shape, reject symlinks, and recheck the extracted app.
14. Generate a SHA-256 checksum file.
15. Create the GitHub Release and attach the notarized ZIP and checksum.
16. Under `always()`, restore the runner keychain list and delete temporary keychain and credential files.

A failure in any gate prevents publication.

## Maintainer checklist

Before tagging:

- confirm CI is green on the exact commit;
- confirm `CHANGELOG.md` reflects the intended version rather than only `Unreleased`;
- complete required real UI, remote, provider, Keychain, install, and accessibility acceptance evidence;
- inspect third-party notices, pinned Pi inputs, hashes, and provider assets;
- confirm no credentials or private environment data are tracked;
- confirm the GitHub Actions secrets and signing-identity variable are current;
- create a signed or otherwise policy-approved annotated tag according to maintainer policy;
- push the tag only after the commit is final.

Example tag shape:

```sh
git tag -a v0.1.0 -m 'Workjet 0.1.0'
git push origin v0.1.0
```

This example does not assert that `v0.1.0` has been released.

## Verify published assets

After the workflow succeeds, download both attached files and verify the checksum:

```sh
shasum -a 256 -c Workjet-0.1.0-macos-arm64.zip.sha256
unzip -t Workjet-0.1.0-macos-arm64.zip
```

After extraction:

```sh
codesign --verify --deep --strict --verbose=4 Workjet-0.1.0-macos-arm64/Workjet.app
xcrun stapler validate Workjet-0.1.0-macos-arm64/Workjet.app
spctl --assess --type execute --verbose=4 Workjet-0.1.0-macos-arm64/Workjet.app
```

A GitHub Release page alone is not sufficient evidence. The workflow conclusion, checksum, signature, staple, and Gatekeeper result all matter.
