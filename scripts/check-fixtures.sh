#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
cd "$project_dir"

binary="/tmp/tokenmonitor-fixture-check-$$"
gateway_binary="/tmp/tokenmonitor-gateway-fixture-check-$$"
refresh_binary="/tmp/tokenmonitor-refresh-fixture-check-$$"
swiftc -parse-as-library -O \
  Sources/TokenMonitorApp/UsageModels.swift \
  Sources/TokenMonitorApp/CBCProvider.swift \
  Sources/TokenMonitorApp/ZhiyaoProvider.swift \
  Sources/TokenMonitorApp/UsageAggregator.swift \
  scripts/fixture-check.swift \
  -o "$binary"
trap 'rm -f "$binary" "$gateway_binary" "$refresh_binary"' EXIT
"$binary"

swiftc -parse-as-library -O \
  Sources/TokenMonitorApp/UsageModels.swift \
  Sources/TokenMonitorApp/CBCProvider.swift \
  Sources/TokenMonitorApp/CBCGatewayProvider.swift \
  Sources/TokenMonitorApp/ZhiyaoProvider.swift \
  Sources/TokenMonitorApp/ProviderCatalog.swift \
  Sources/TokenMonitorApp/UsageAggregator.swift \
  scripts/cbc-gateway-fixture-check.swift \
  -o "$gateway_binary"
"$gateway_binary"

swiftc -parse-as-library -O \
  Sources/TokenMonitorApp/UsageModels.swift \
  Sources/TokenMonitorApp/RefreshPolicy.swift \
  Sources/TokenMonitorApp/CBCProvider.swift \
  Sources/TokenMonitorApp/CBCGatewayProvider.swift \
  Sources/TokenMonitorApp/ZhiyaoProvider.swift \
  Sources/TokenMonitorApp/ProviderCatalog.swift \
  Sources/TokenMonitorApp/UsageAggregator.swift \
  Sources/TokenMonitorApp/CredentialVault.swift \
  Sources/TokenMonitorApp/MonitorStore.swift \
  scripts/refresh-fixture-check.swift \
  -o "$refresh_binary"
"$refresh_binary"
