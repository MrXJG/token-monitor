#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
source_file="${1:-$project_dir/Sources/TokenMonitorApp/TokenMonitorApp.swift}"

python3 - "$source_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
required = [
    "NSMenu.didEndTrackingNotification",
    "requestPopoverCloseAfterMenu()",
    "closePopoverAfterMenuTracking()",
]
missing = [marker for marker in required if marker not in source]
if missing:
    raise SystemExit(f"missing popover close contract: {', '.join(missing)}")

callback_start = source.index("onProviderSwitch:")
callback_end = source.index("\n            }", callback_start)
callback = source[callback_start:callback_end]
if "popover.close()" in callback or "popover.performClose" in callback:
    raise SystemExit("popover must not close while SwiftUI Menu is tracking")

print("popover close contract passed")
PY
