#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
cd "$project_dir"

binary="/tmp/tokenmonitor-fixture-check-$$"
swiftc -parse-as-library -O \
  Sources/TokenMonitorApp/UsageModels.swift \
  Sources/TokenMonitorApp/CBCProvider.swift \
  Sources/TokenMonitorApp/ZhiyaoProvider.swift \
  Sources/TokenMonitorApp/UsageAggregator.swift \
  scripts/fixture-check.swift \
  -o "$binary"
trap 'rm -f "$binary"' EXIT
"$binary"
