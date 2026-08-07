#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
dist_dir="$script_dir/dist"
bundle="$dist_dir/Workjet.app"
release_inputs="$script_dir/ReleaseInputs"
sidecar_source="$release_inputs/ctox-pi-sidecar.mjs"
sidecar_manifest="$release_inputs/ctox-pi-sidecar.sha256"
signing_identity="${WORKJET_SIGNING_IDENTITY:-}"
require_release_signing="${WORKJET_REQUIRE_RELEASE_SIGNING:-0}"
allow_adhoc_signing="${WORKJET_ALLOW_ADHOC_SIGNING:-0}"
notary_profile="${WORKJET_NOTARY_PROFILE:-}"
notary_key_id="${WORKJET_NOTARY_KEY_ID:-}"
notary_issuer_id="${WORKJET_NOTARY_ISSUER_ID:-}"
notary_key_path="${WORKJET_NOTARY_KEY_PATH:-}"
wrappers=(claude-sol claude-minimax claude-kimi claude-opus workjet-observe claude-agent claude-fleet)
stage=""
backup=""
published=0

fail() {
  print -u2 -r -- "Workjet release: $*"
  exit 1
}

cleanup() {
  local exit_code=$?
  if [[ -n "$backup" && -e "$backup" ]]; then
    if (( published )); then
      rm -rf -- "$backup"
    else
      rm -rf -- "$bundle"
      mv -- "$backup" "$bundle" || true
    fi
  fi
  [[ -z "$stage" || ! -d "$stage" ]] || rm -rf -- "$stage"
  return $exit_code
}
trap cleanup EXIT INT TERM HUP

[[ "$allow_adhoc_signing" == 0 || "$allow_adhoc_signing" == 1 ]] || fail \
  "WORKJET_ALLOW_ADHOC_SIGNING must be 0 or 1."
[[ "$require_release_signing" == 0 || "$require_release_signing" == 1 ]] || fail \
  "WORKJET_REQUIRE_RELEASE_SIGNING must be 0 or 1."
if [[ "$allow_adhoc_signing" == 1 ]]; then
  signing_identity=""
fi
if [[ -z "$signing_identity" && "$require_release_signing" == 1 ]]; then
  fail "Release signing was required, but WORKJET_SIGNING_IDENTITY is empty."
fi
notary_api_fields=0
[[ -z "$notary_key_id" ]] || (( notary_api_fields += 1 ))
[[ -z "$notary_issuer_id" ]] || (( notary_api_fields += 1 ))
[[ -z "$notary_key_path" ]] || (( notary_api_fields += 1 ))
(( notary_api_fields == 0 || notary_api_fields == 3 )) || fail \
  "Set WORKJET_NOTARY_KEY_ID, WORKJET_NOTARY_ISSUER_ID and WORKJET_NOTARY_KEY_PATH together."
if [[ -n "$notary_profile" && $notary_api_fields -eq 3 ]]; then
  fail "Choose either WORKJET_NOTARY_PROFILE or the three WORKJET_NOTARY_* API-key variables."
fi
if [[ ( -n "$notary_profile" || $notary_api_fields -eq 3 ) && -z "$signing_identity" ]]; then
  fail "Notarization requires WORKJET_SIGNING_IDENTITY; an ad-hoc artifact cannot be notarized."
fi

# A release never reaches outside this repository for executable payloads. The
# audited Pi runtime and its one-line SHA-256 manifest are deliberate release
# inputs; absence is a release blocker, not a reason to fall back elsewhere.
[[ -f "$sidecar_source" && ! -L "$sidecar_source" ]] || fail \
  "Pinned Pi Code input is missing: $sidecar_source. Add the audited repo input; external paths are not accepted."
[[ -f "$sidecar_manifest" && ! -L "$sidecar_manifest" ]] || fail \
  "Pinned Pi Code manifest is missing: $sidecar_manifest. Expected format: <sha256>  ctox-pi-sidecar.mjs"
read -r expected_sidecar_hash expected_sidecar_name extra < "$sidecar_manifest" || fail "Pi Code manifest is unreadable."
[[ "$expected_sidecar_hash" =~ '^[0-9a-f]{64}$' ]] || fail "Pi Code manifest has an invalid SHA-256."
[[ "$expected_sidecar_name" == "ctox-pi-sidecar.mjs" && -z "${extra:-}" ]] || fail "Pi Code manifest must name only ctox-pi-sidecar.mjs."
actual_sidecar_hash=$(shasum -a 256 "$sidecar_source" | awk '{print $1}')
[[ "$actual_sidecar_hash" == "$expected_sidecar_hash" ]] || fail \
  "Pi Code input hash mismatch: expected $expected_sidecar_hash, got $actual_sidecar_hash."

mkdir -p "$dist_dir"
stage=$(mktemp -d "$dist_dir/.workjet-build.XXXXXX")
new_bundle="$stage/Workjet.app"
contents="$new_bundle/Contents"
swift_scratch="$stage/swift-build"
mkdir -p "$contents/MacOS" "$contents/Resources"

cd "$script_dir"
# Workjet 0.1 is explicitly Apple-Silicon-only. Do not accidentally advertise
# a universal build until both slices are built and exercised in CI.
swift build -c release --arch arm64 --product WorkjetApp --scratch-path "$swift_scratch" -Xswiftc -no-whole-module-optimization
swift build -c release --arch arm64 --product workjet --scratch-path "$swift_scratch" -Xswiftc -no-whole-module-optimization
bin_dir=$(swift build -c release --arch arm64 --show-bin-path --scratch-path "$swift_scratch")

cp "$script_dir/Info.plist" "$contents/Info.plist"
cp "$bin_dir/WorkjetApp" "$contents/MacOS/WorkjetApp"
cp "$bin_dir/workjet" "$contents/MacOS/workjet"
for executable in "$contents/MacOS/WorkjetApp" "$contents/MacOS/workjet"; do
  [[ "$(lipo -archs "$executable")" == "arm64" ]] || fail "Release executable is not arm64-only: $executable"
  # SwiftPM leaves local object and source paths in DWARF even for -c release.
  # A distributable app keeps those symbols outside the shipped executable.
  strip -S "$executable"
done

# Generate the first-install prompt with the exact WorkjetCore version that is
# shipped in this bundle. A fresh install must not expose the repository's
# contributor AGENTS.md, or require the app to be opened once, before Claude
# sees the current managed prompt. WORKJET_HOME keeps generation hermetic and
# the CLI's normal bootstrap path supplies the checksum-protected document.
prompt_home="$stage/prompt-home"
mkdir -p "$prompt_home"
WORKJET_HOME="$prompt_home" "$contents/MacOS/workjet" workers list --json >/dev/null
generated_prompt="$prompt_home/.claude/workjet/AGENTS.md"
[[ -f "$generated_prompt" && ! -L "$generated_prompt" ]] || fail "Workjet CLI did not generate the default managed prompt."
cp "$generated_prompt" "$contents/Resources/default-workjet-agents.md"
chmod 644 "$contents/Resources/default-workjet-agents.md"

resource_bundle="$bin_dir/Workjet_WorkjetApp.bundle"
[[ -d "$resource_bundle" ]] || fail "Missing SwiftPM resource bundle: $resource_bundle"
cp -R "$resource_bundle" "$contents/Resources/"
for provider_logo in kimi openai anthropic antigravity xai minimax zai; do
  packaged_logo="$contents/Resources/Workjet_WorkjetApp.bundle/$provider_logo.svg"
  [[ -f "$packaged_logo" ]] || fail "Missing packaged provider logo: $packaged_logo"
done

icon_svg="$script_dir/Sources/WorkjetApp/Resources/Brand/workjet-app-icon.svg"
iconset="$stage/WorkjetAppIcon.iconset"
[[ -f "$icon_svg" ]] || fail "Missing Workjet icon source: $icon_svg"
(( $+commands[rsvg-convert] )) || fail "rsvg-convert is required to build the app icon."
mkdir -p "$iconset"
rsvg-convert -w 1024 -h 1024 "$icon_svg" > "$iconset/icon_512x512@2x.png"
for spec in \
  '16 icon_16x16.png' '32 icon_16x16@2x.png' \
  '32 icon_32x32.png' '64 icon_32x32@2x.png' \
  '128 icon_128x128.png' '256 icon_128x128@2x.png' \
  '256 icon_256x256.png' '512 icon_256x256@2x.png' \
  '512 icon_512x512.png'; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$iconset/icon_512x512@2x.png" --out "$iconset/$name" >/dev/null
done
iconutil -c icns "$iconset" -o "$contents/Resources/WorkjetAppIcon.icns"
[[ -s "$contents/Resources/WorkjetAppIcon.icns" ]] || fail "Workjet app icon was not generated."

cp "$sidecar_source" "$contents/Resources/ctox-pi-sidecar.mjs"
cp "$script_dir/LaunchAgents/dev.workjet.menubar.plist" "$contents/Resources/dev.workjet.menubar.plist"
cp "$repo_root/LICENSE" "$contents/Resources/LICENSE.txt"
cp "$script_dir/THIRD_PARTY_NOTICES.md" "$contents/Resources/THIRD_PARTY_NOTICES.md"

# The signed app is the complete release payload. install.sh consumes these
# exact wrapper copies instead of reaching back into a source checkout.
wrapper_resources="$contents/Resources/WorkjetWrappers"
mkdir -p "$wrapper_resources"
for name in $wrappers; do
  wrapper_source="$repo_root/bin/$name"
  [[ -f "$wrapper_source" && ! -L "$wrapper_source" ]] || fail "Missing release wrapper: bin/$name"
  cp "$wrapper_source" "$wrapper_resources/$name"
  chmod 755 "$wrapper_resources/$name"
done

license_inputs="$release_inputs/licenses"
[[ -d "$license_inputs" ]] || fail "Bundled dependency license inputs are missing: $license_inputs"
license_manifest="$release_inputs/licenses.sha256"
[[ -f "$license_manifest" && ! -L "$license_manifest" ]] || fail "Dependency license manifest is missing."
(cd "$release_inputs" && shasum -a 256 -c "${license_manifest:t}" >/dev/null) || fail \
  "Dependency license input hash mismatch."
license_resources="$contents/Resources/ThirdPartyLicenses"
mkdir -p "$license_resources"
for license_input in "$license_inputs"/*; do
  [[ -f "$license_input" && ! -L "$license_input" ]] || fail "Invalid dependency license input: $license_input"
  cp "$license_input" "$license_resources/${license_input:t}"
done
for required_license in \
  pi-agent-core-MIT.txt pi-ai-MIT.txt openai-Apache-2.0.txt \
  partial-json-MIT.txt typebox-MIT.txt; do
  [[ -s "$license_resources/$required_license" ]] || fail "Missing dependency license text: $required_license"
done

# The manifest format intentionally has no symlink semantics. Reject links so
# every shipped pre-signing payload is represented by an ordinary file hash.
if [[ -n "$(find "$new_bundle" -type l -print -quit)" ]]; then
  fail "Release bundle contains a symlink; all payload files must be manifest-covered regular files."
fi

plutil -lint "$contents/Info.plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")" == "dev.workjet.menubar" ]] || fail "Unexpected bundle identifier."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$contents/Info.plist")" == "0.1.0" ]] || fail "Unexpected marketing version."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$contents/Info.plist")" == "1" ]] || fail "Unexpected build version."

# A source checkout or SwiftPM build directory must never be disclosed by the
# shipped payload. Generic UI placeholders such as /Users/… are not matches.
if rg -a -q '/Users/[A-Za-z0-9._-]+/' "$new_bundle"; then
  fail "Bundle contains an absolute user build path."
fi

chmod 755 "$contents/MacOS/WorkjetApp" "$contents/MacOS/workjet"

# Seal every ordinary resource with a deterministic manifest. Mach-O files are
# intentionally excluded because codesign mutates them after hashing; their
# authenticity is verified by the nested and outer code-signature checks.
# Signing the app then seals this manifest and every manifest-covered resource.
manifest="$contents/Resources/SHA256SUMS"
(
  cd "$new_bundle"
  find Contents -type f \
    ! -path 'Contents/Resources/SHA256SUMS' \
    ! -path 'Contents/MacOS/*' \
    ! -path 'Contents/_CodeSignature/*' \
    | LC_ALL=C sort | while IFS= read -r artifact_path; do
    hash=$(shasum -a 256 "$artifact_path" | awk '{print $1}')
    print -r -- "$hash  $artifact_path"
  done
) > "$manifest"
[[ -s "$manifest" ]] || fail "Release hash manifest was not generated."

if [[ -z "$signing_identity" ]]; then
  print -u2 -r -- "WARNING: WORKJET_SIGNING_IDENTITY is unset; creating a local ad-hoc build."
  codesign --force --options runtime --sign - "$contents/MacOS/workjet"
  codesign --force --options runtime --sign - "$new_bundle"
else
  codesign --force --options runtime --timestamp --sign "$signing_identity" "$contents/MacOS/workjet"
  codesign --force --options runtime --timestamp --sign "$signing_identity" "$new_bundle"
fi
codesign --verify --strict --verbose=4 "$contents/MacOS/workjet"
codesign --verify --strict --verbose=4 "$new_bundle"

if [[ -n "$notary_profile" || $notary_api_fields -eq 3 ]]; then
  archive="$stage/Workjet.zip"
  ditto -c -k --norsrc --noextattr --keepParent "$new_bundle" "$archive"
  if [[ -n "$notary_profile" ]]; then
    xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
  else
    [[ -f "$notary_key_path" && ! -L "$notary_key_path" ]] || fail "Notary API key is not a regular file."
    xcrun notarytool submit "$archive" \
      --key "$notary_key_path" --key-id "$notary_key_id" --issuer "$notary_issuer_id" --wait
  fi
  xcrun stapler staple "$new_bundle"
  xcrun stapler validate "$new_bundle"
  spctl --assess --type execute --verbose=4 "$new_bundle"
fi

# Create the archive from the fully signed/stapled staging bundle. Publishing
# both outputs happens only after every fallible packaging step succeeded.
release_root="$stage/Workjet-0.1.0-macos-arm64"
mkdir -p "$release_root"
ditto --norsrc --noextattr "$new_bundle" "$release_root/Workjet.app"
cp "$repo_root/install.sh" "$release_root/install.sh"
chmod 755 "$release_root/install.sh"
archive_stage="$stage/Workjet-0.1.0-macos-arm64.zip"
ditto -c -k --norsrc --noextattr --keepParent "$release_root" "$archive_stage"
[[ -s "$archive_stage" ]] || fail "Release archive was not generated."

if [[ -e "$bundle" ]]; then
  backup="$dist_dir/.Workjet.previous.$$"
  mv -- "$bundle" "$backup"
fi
mv -- "$new_bundle" "$bundle"
release_archive="$dist_dir/Workjet-0.1.0-macos-arm64.zip"
mv -f -- "$archive_stage" "$release_archive"
published=1
print -r -- "$bundle"
print -r -- "$release_archive"
