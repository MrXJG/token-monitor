#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
cd "$project_dir"
swift build -c release --scratch-path /tmp/tokenmonitor-release-build
app_dir="${TOKENMONITOR_APP_DIR:-$HOME/Applications/TokenMonitor.app}"
mkdir -p "$app_dir/Contents/MacOS"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp /tmp/tokenmonitor-release-build/release/TokenMonitor "$app_dir/Contents/MacOS/TokenMonitor"
chmod 755 "$app_dir/Contents/MacOS/TokenMonitor"
xattr -cr "$app_dir"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
test -x "$app_dir/Contents/MacOS/TokenMonitor"
print -r -- "$app_dir"
