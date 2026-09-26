#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Resources/Info.plist")
architecture=$(uname -m)
output_dir="${TOKENMONITOR_DIST_DIR:-$project_dir/dist}"
staging_dir=$(mktemp -d /tmp/tokenmonitor-package.XXXXXX)
trap 'rm -rf "$staging_dir"' EXIT

mkdir -p "$output_dir"
TOKENMONITOR_APP_DIR="$staging_dir/TokenMonitor.app" zsh "$script_dir/build-app.sh"
ln -s /Applications "$staging_dir/Applications"

image="$output_dir/TokenMonitor-$version-macos-$architecture.dmg"
hdiutil create -quiet -volname "TokenMonitor $version" -srcfolder "$staging_dir" -format UDZO -ov "$image"
hdiutil verify -quiet "$image"
print -r -- "$image"
shasum -a 256 "$image"
