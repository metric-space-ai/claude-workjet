#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
bundle="$script_dir/dist/Workjet.app"
contents="$bundle/Contents"

cd "$script_dir"
swift build -c release --product WorkjetApp

if [[ -e "$bundle" ]]; then
  rm -rf -- "$bundle"
fi
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$script_dir/Info.plist" "$contents/Info.plist"
cp "$script_dir/.build/release/WorkjetApp" "$contents/MacOS/WorkjetApp"
chmod 755 "$contents/MacOS/WorkjetApp"
codesign --force --sign - "$bundle"

print -r -- "$bundle"
