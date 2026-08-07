#!/bin/sh
# Builds when necessary, then installs a verified Workjet release. It never
# launches the app and never invokes provider authentication.
set -eu

[ "$#" -eq 0 ] || { echo "usage: ./install.sh" >&2; exit 2; }

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_checkout=0
[ ! -x "$HERE/app/build-app.sh" ] || source_checkout=1
if [ -n "${WORKJET_SOURCE_APP:-}" ]; then
  SOURCE_APP=$WORKJET_SOURCE_APP
elif [ -d "$HERE/Workjet.app" ]; then
  SOURCE_APP="$HERE/Workjet.app"
else
  SOURCE_APP="$HERE/app/dist/Workjet.app"
fi
DEFAULT_PROMPT="$SOURCE_APP/Contents/Resources/default-workjet-agents.md"
WRAPPER_SOURCE="$SOURCE_APP/Contents/Resources/WorkjetWrappers"
HASH_MANIFEST="$SOURCE_APP/Contents/Resources/SHA256SUMS"
LOGIN_AGENT_TEMPLATE="$SOURCE_APP/Contents/Resources/dev.workjet.menubar.plist"
APPLICATIONS_DIR=${WORKJET_APPLICATIONS_DIR:-/Applications}
APP_DEST="$APPLICATIONS_DIR/Workjet.app"
LAUNCH_AGENTS_DIR=${WORKJET_LAUNCH_AGENTS_DIR:-"$HOME/Library/LaunchAgents"}
LOGIN_AGENT="$LAUNCH_AGENTS_DIR/dev.workjet.menubar.plist"
BIN="$HOME/.local/bin"
BIN_PARENT=$(dirname -- "$BIN")
CLAUDE_DIR="$HOME/.claude"
GLOBAL_CLAUDE="$CLAUDE_DIR/CLAUDE.md"
WORKJET_PROMPT_DIR="$CLAUDE_DIR/workjet"
WORKJET_PROMPT="$WORKJET_PROMPT_DIR/AGENTS.md"
LEGACY_SKILL="$CLAUDE_DIR/skills/workjet/SKILL.md"
INCLUDE_BEGIN='<!-- WORKJET GLOBAL INCLUDE BEGIN -->'
INCLUDE_END='<!-- WORKJET GLOBAL INCLUDE END -->'
WRAPPERS="claude-sol claude-minimax claude-kimi claude-opus workjet-observe claude-agent claude-fleet"
app_stage_root=
bin_stage_root=
claude_stage_root=
prompt_stage_root=
launch_stage_root=
transaction_started=0
committed=0
built_locally=0

fail() { echo "Workjet installer: $*" >&2; exit 1; }

rollback() {
  [ "$transaction_started" -eq 1 ] || return 0

  rm -rf -- "$APP_DEST"
  if [ -e "$app_stage_root/Previous.app" ]; then
    mv -- "$app_stage_root/Previous.app" "$APP_DEST" || true
  fi

  for name in $WRAPPERS workjet; do
    rm -f -- "$BIN/$name"
    if [ -e "$bin_stage_root/previous/$name" ]; then
      mv -- "$bin_stage_root/previous/$name" "$BIN/$name" || true
    fi
  done

  rm -f -- "$GLOBAL_CLAUDE"
  if [ -e "$claude_stage_root/Previous.CLAUDE.md" ]; then
    mv -- "$claude_stage_root/Previous.CLAUDE.md" "$GLOBAL_CLAUDE" || true
  fi

  rm -f -- "$WORKJET_PROMPT"
  if [ -e "$prompt_stage_root/Previous.AGENTS.md" ]; then
    mv -- "$prompt_stage_root/Previous.AGENTS.md" "$WORKJET_PROMPT" || true
  fi

  if [ -e "$prompt_stage_root/Previous.SKILL.md" ]; then
    mkdir -p -- "$(dirname -- "$LEGACY_SKILL")"
    mv -- "$prompt_stage_root/Previous.SKILL.md" "$LEGACY_SKILL" || true
  fi

  rm -f -- "$LOGIN_AGENT"
  if [ -e "$launch_stage_root/Previous.plist" ]; then
    mv -- "$launch_stage_root/Previous.plist" "$LOGIN_AGENT" || true
  fi
}

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$committed" -ne 1 ]; then rollback; fi
  [ -z "$app_stage_root" ] || rm -rf -- "$app_stage_root"
  [ -z "$bin_stage_root" ] || rm -rf -- "$bin_stage_root"
  [ -z "$claude_stage_root" ] || rm -rf -- "$claude_stage_root"
  [ -z "$prompt_stage_root" ] || rm -rf -- "$prompt_stage_root"
  [ -z "$launch_stage_root" ] || rm -rf -- "$launch_stage_root"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

needs_local_build=0
if [ ! -d "$SOURCE_APP" ]; then
  needs_local_build=1
elif [ ! -x "$SOURCE_APP/Contents/MacOS/WorkjetApp" ] || \
     [ ! -x "$SOURCE_APP/Contents/MacOS/workjet" ] || \
     [ ! -f "$DEFAULT_PROMPT" ] || [ -L "$DEFAULT_PROMPT" ] || \
     [ ! -f "$HASH_MANIFEST" ] || [ -L "$HASH_MANIFEST" ] || \
     [ ! -f "$LOGIN_AGENT_TEMPLATE" ] || [ -L "$LOGIN_AGENT_TEMPLATE" ] || \
     [ ! -d "$WRAPPER_SOURCE" ] || [ -L "$WRAPPER_SOURCE" ]; then
  needs_local_build=1
fi
if [ "$needs_local_build" -eq 1 ]; then
  [ -x "$HERE/app/build-app.sh" ] || fail "build script is missing: app/build-app.sh"
  echo "Workjet bundle is missing or incomplete; building a local verified artifact…" >&2
  "$HERE/app/build-app.sh" >/dev/null
  built_locally=1
fi

[ -d "$SOURCE_APP" ] || fail "build did not produce the app artifact: $SOURCE_APP"
[ -x "$SOURCE_APP/Contents/MacOS/WorkjetApp" ] || fail "app executable is missing"
[ -x "$SOURCE_APP/Contents/MacOS/workjet" ] || fail "embedded workjet CLI is missing"
[ -f "$HASH_MANIFEST" ] && [ ! -L "$HASH_MANIFEST" ] || fail "release hash manifest is missing"
[ -d "$WRAPPER_SOURCE" ] && [ ! -L "$WRAPPER_SOURCE" ] || fail "bundled wrappers are missing"
[ -f "$LOGIN_AGENT_TEMPLATE" ] && [ ! -L "$LOGIN_AGENT_TEMPLATE" ] || fail "login-agent template is missing"
/usr/libexec/PlistBuddy -c 'Print :Label' "$LOGIN_AGENT_TEMPLATE" | \
  grep -qx 'dev.workjet.menubar.launch-at-login' || fail "login-agent template has an unexpected label"

# Reject path traversal, absolute paths, malformed hashes and duplicate entries
# before asking shasum to read anything named by the signed manifest.
awk '
  length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 1 }
  $2 !~ /^Contents\// || $2 ~ /(^|\/)\.\.(\/|$)/ { exit 1 }
  seen[$2]++ { exit 1 }
' "$HASH_MANIFEST" || fail "release hash manifest is malformed"
(
  cd "$SOURCE_APP"
  shasum -a 256 -c "Contents/Resources/SHA256SUMS" >/dev/null
) || fail "release payload hash verification failed"

for name in $WRAPPERS; do
  [ -f "$WRAPPER_SOURCE/$name" ] && [ ! -L "$WRAPPER_SOURCE/$name" ] || \
    fail "bundled wrapper is missing: $name"
  grep -Eq "^[0-9a-f]{64}  Contents/Resources/WorkjetWrappers/$name$" "$HASH_MANIFEST" || \
    fail "bundled wrapper is not covered by the release manifest: $name"
done

codesign --verify --strict --verbose=4 "$SOURCE_APP/Contents/MacOS/workjet" || fail "embedded CLI signature is invalid"
codesign --verify --strict --verbose=4 "$SOURCE_APP" || fail "app signature is invalid"
signature_policy=${WORKJET_INSTALL_SIGNATURE_POLICY:-}
if [ -z "$signature_policy" ]; then
  if [ "$built_locally" -eq 1 ] || [ "$source_checkout" -eq 1 ]; then
    signature_policy=valid
  else
    signature_policy=developer-id
  fi
fi
case "$signature_policy" in
  developer-id)
    codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 | grep -q '^Authority=Developer ID Application:' || \
      fail "app is not signed with a Developer ID Application identity"
    spctl --assess --type execute --verbose=4 "$SOURCE_APP" || \
      fail "Developer ID app was not accepted by Gatekeeper"
    ;;
  valid) : ;;
  *) fail "WORKJET_INSTALL_SIGNATURE_POLICY must be developer-id or valid" ;;
esac

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")
build_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")
[ "$bundle_id" = "dev.workjet.menubar" ] || fail "unexpected bundle identifier: $bundle_id"
[ "$bundle_version" = "0.1.0" ] && [ "$build_version" = "1" ] || fail "unexpected app version: $bundle_version ($build_version)"

if pgrep -f "$APP_DEST/Contents/MacOS/WorkjetApp" >/dev/null 2>&1; then
  fail "Workjet is running. Quit Workjet before installing the update."
fi

[ -f "$DEFAULT_PROMPT" ] && [ ! -L "$DEFAULT_PROMPT" ] || fail "bundle default Workjet prompt is missing"

mkdir -p -- "$APPLICATIONS_DIR" "$BIN" "$CLAUDE_DIR" "$WORKJET_PROMPT_DIR" "$LAUNCH_AGENTS_DIR"
app_stage_root=$(mktemp -d "$APPLICATIONS_DIR/.workjet-install.XXXXXX")
bin_stage_root=$(mktemp -d "$BIN_PARENT/.workjet-install.XXXXXX")
claude_stage_root=$(mktemp -d "$CLAUDE_DIR/.workjet-install.XXXXXX")
prompt_stage_root=$(mktemp -d "$WORKJET_PROMPT_DIR/.workjet-install.XXXXXX")
launch_stage_root=$(mktemp -d "$LAUNCH_AGENTS_DIR/.workjet-install.XXXXXX")
mkdir -p -- "$bin_stage_root/new" "$bin_stage_root/previous"

ditto "$SOURCE_APP" "$app_stage_root/Workjet.app"
codesign --verify --strict --verbose=4 "$app_stage_root/Workjet.app"
for name in $WRAPPERS; do
  cp -- "$WRAPPER_SOURCE/$name" "$bin_stage_root/new/$name"
  chmod 755 "$bin_stage_root/new/$name"
done
cp -- "$SOURCE_APP/Contents/MacOS/workjet" "$bin_stage_root/new/workjet"
chmod 755 "$bin_stage_root/new/workjet"

# Preserve every unrelated byte in the global Claude prompt. Only Workjet's
# explicitly marked block may be replaced. A malformed or duplicate block is
# rejected instead of guessing at the owner's intent.
if [ -e "$GLOBAL_CLAUDE" ]; then
  [ -f "$GLOBAL_CLAUDE" ] && [ ! -L "$GLOBAL_CLAUDE" ] || fail "global CLAUDE.md is not a regular file"
  [ "$(stat -f %u "$GLOBAL_CLAUDE")" = "$(id -u)" ] || fail "global CLAUDE.md belongs to another user"
  begin_count=$(grep -Fxc "$INCLUDE_BEGIN" "$GLOBAL_CLAUDE" || true)
  end_count=$(grep -Fxc "$INCLUDE_END" "$GLOBAL_CLAUDE" || true)
  [ "$begin_count" = "$end_count" ] && [ "$begin_count" -le 1 ] || fail "global CLAUDE.md contains a malformed Workjet block"
  if [ "$begin_count" -eq 1 ]; then
    begin_line=$(grep -Fn "$INCLUDE_BEGIN" "$GLOBAL_CLAUDE" | cut -d: -f1)
    end_line=$(grep -Fn "$INCLUDE_END" "$GLOBAL_CLAUDE" | cut -d: -f1)
    [ "$begin_line" -lt "$end_line" ] || fail "global CLAUDE.md contains a malformed Workjet block"
    sed "/^$INCLUDE_BEGIN\$/,/^$INCLUDE_END\$/d" "$GLOBAL_CLAUDE" > "$claude_stage_root/New.CLAUDE.md"
  else
    cp -- "$GLOBAL_CLAUDE" "$claude_stage_root/New.CLAUDE.md"
  fi
else
  : > "$claude_stage_root/New.CLAUDE.md"
fi
if [ -s "$claude_stage_root/New.CLAUDE.md" ]; then
  last_byte=$(tail -c 1 "$claude_stage_root/New.CLAUDE.md" | od -An -tuC | tr -d ' ')
  if [ "$last_byte" = 10 ]; then printf '\n' >> "$claude_stage_root/New.CLAUDE.md"; else printf '\n\n' >> "$claude_stage_root/New.CLAUDE.md"; fi
fi
printf '%s\n@workjet/AGENTS.md\n%s\n' "$INCLUDE_BEGIN" "$INCLUDE_END" >> "$claude_stage_root/New.CLAUDE.md"
chmod 600 "$claude_stage_root/New.CLAUDE.md"

if [ -e "$WORKJET_PROMPT" ]; then
  [ -f "$WORKJET_PROMPT" ] && [ ! -L "$WORKJET_PROMPT" ] || fail "managed Workjet prompt is not a regular file"
  cp -- "$WORKJET_PROMPT" "$prompt_stage_root/New.AGENTS.md"
else
  cp -- "$DEFAULT_PROMPT" "$prompt_stage_root/New.AGENTS.md"
fi
chmod 600 "$prompt_stage_root/New.AGENTS.md"

cp -- "$LOGIN_AGENT_TEMPLATE" "$launch_stage_root/New.plist"
plutil -remove ProgramArguments.0 "$launch_stage_root/New.plist"
plutil -insert ProgramArguments.0 -string "$APP_DEST/Contents/MacOS/WorkjetApp" "$launch_stage_root/New.plist"
plutil -lint "$launch_stage_root/New.plist" >/dev/null
chmod 600 "$launch_stage_root/New.plist"

# Only after every source has been staged and verified do we move existing
# files aside. All moves stay on their destination filesystem, so rollback is
# available until the whole transaction is committed.
transaction_started=1
if [ -e "$APP_DEST" ]; then mv -- "$APP_DEST" "$app_stage_root/Previous.app"; fi
for name in $WRAPPERS workjet; do
  if [ -e "$BIN/$name" ]; then mv -- "$BIN/$name" "$bin_stage_root/previous/$name"; fi
done
if [ -e "$GLOBAL_CLAUDE" ]; then mv -- "$GLOBAL_CLAUDE" "$claude_stage_root/Previous.CLAUDE.md"; fi
if [ -e "$WORKJET_PROMPT" ]; then mv -- "$WORKJET_PROMPT" "$prompt_stage_root/Previous.AGENTS.md"; fi
if [ -e "$LEGACY_SKILL" ]; then mv -- "$LEGACY_SKILL" "$prompt_stage_root/Previous.SKILL.md"; fi
if [ -e "$LOGIN_AGENT" ]; then mv -- "$LOGIN_AGENT" "$launch_stage_root/Previous.plist"; fi

mv -- "$app_stage_root/Workjet.app" "$APP_DEST"
for name in $WRAPPERS workjet; do mv -- "$bin_stage_root/new/$name" "$BIN/$name"; done
mv -- "$claude_stage_root/New.CLAUDE.md" "$GLOBAL_CLAUDE"
mv -- "$prompt_stage_root/New.AGENTS.md" "$WORKJET_PROMPT"
mv -- "$launch_stage_root/New.plist" "$LOGIN_AGENT"
codesign --verify --strict --verbose=4 "$APP_DEST"

committed=1
transaction_started=0
rm -rf -- "$app_stage_root/Previous.app" "$bin_stage_root/previous" "$claude_stage_root/Previous.CLAUDE.md" "$prompt_stage_root/Previous.AGENTS.md" "$prompt_stage_root/Previous.SKILL.md" "$launch_stage_root/Previous.plist"
echo "installed $APP_DEST"
echo "installed Workjet CLI and wrappers in $BIN"
echo "installed global Workjet include in $GLOBAL_CLAUDE"
echo "installed managed Workjet prompt in $WORKJET_PROMPT"
echo "installed Workjet login agent in $LOGIN_AGENT"
