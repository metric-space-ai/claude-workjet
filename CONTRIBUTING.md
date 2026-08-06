# Contributing to Workjet

Thank you for improving Workjet. Contributions should preserve the product boundary: Claude remains the orchestrator, Workjet remains local software and execution plumbing, and worker claims remain subject to independent verification.

## Before opening a change

- Search existing issues and pull requests.
- For security problems, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
- Keep provider and model support configurable. Do not imply commercial affiliation, endorsement, or guaranteed account availability.
- Do not commit credentials, OAuth material, private keys, real host fingerprints, private repository data, or unredacted logs.

## Development setup

Requirements for the first build are macOS 14 or newer, Apple Silicon, Git, and Xcode command-line tools.

```sh
git clone https://github.com/metric-space-ai/claude-workjet.git
cd claude-workjet
swift test --package-path app
swift run --package-path app WorkjetApp
```

Install `librsvg` only when you need a release-shaped app bundle:

```sh
brew install librsvg
./app/build-app.sh
```

Node.js 22 is required only for the Pi sidecar reproducibility checks. See [app/README.md](app/README.md) for the complete build and test matrix.

## Make a focused change

1. Create a branch from `main`.
2. Keep the change small enough to review and verify independently.
3. Add or update tests for behavioral changes.
4. Update public documentation when a product boundary, command, persistence path, security property, or release step changes.
5. Do not edit generated release inputs unless the change intentionally updates their source, pinned versions, hashes, and license evidence together.

## Verification

Run the checks that cover your change. The full local set is:

```sh
swift test --package-path app
xcodebuild -project app/Workjet.xcodeproj -scheme Workjet \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/workjet-derived-data \
  build-for-testing CODE_SIGNING_ALLOWED=NO
zsh tests/dispatcher_test.zsh
zsh tests/wrapper_rework_test.zsh
zsh tests/worktree_gc_test.zsh
npm ci --prefix app/PiSidecar
npm run check --prefix app/PiSidecar
npm run build --prefix app/PiSidecar
npm run verify:bundle --prefix app/PiSidecar
npm run smoke --prefix app/PiSidecar
npm run verify:reproducible --prefix app/PiSidecar
./app/build-app.sh
git diff --check
```

The release-shaped build requires `librsvg`. UI changes should also run the production-view click suite documented in [app/UITests/README.md](app/UITests/README.md).

If a test cannot run in your environment, state that clearly in the pull request. Do not describe an unrun check as passing.

## Pull requests

A pull request should explain:

- the user-visible or maintainer problem;
- the chosen boundary and why it is narrow;
- tests run with exact commands and results;
- security, persistence, migration, remote, or release effects;
- screenshots for UI changes using non-secret fixture data;
- remaining limitations or follow-up work.

Worker completion receipts are useful triage input but are not acceptance evidence. Reviewers will inspect the actual diff and rerun relevant checks.

## Documentation style

Use direct, factual English. Prefer concrete commands and current behavior. Avoid invented metrics, testimonials, provider-affiliation claims, and statements that a public binary exists before the notarized tag workflow has published it.

## License

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE).
