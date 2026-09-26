#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
binary=$(mktemp /tmp/tokenmonitor-preview.XXXXXX)
trap 'rm -f "$binary"' EXIT
find Sources/TokenMonitorApp -name '*.swift' ! -name 'TokenMonitorApp.swift' -print0 \
  | xargs -0 swiftc -D DEBUG scripts/render-previews.swift -o "$binary"
"$binary" "$project_dir/previews"
