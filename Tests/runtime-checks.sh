#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/spaces-dock-runtime.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
runtime_cache="${SPACES_DOCK_MODULE_CACHE:-$PWD/.build/module-cache}"
swiftc -module-cache-path "$runtime_cache" Sources/SpacesDock/RuntimeSafety.swift Sources/SpacesDock/RuntimeProcess.swift Tests/RuntimeSafetyChecks/main.swift -o "$check_dir/runtime-checks"
clang -Wall -Wextra -I Sources/SpacesBridge Tests/SpacesBridgeChecks/main.c -o "$check_dir/bridge-checks"
result=0
"$check_dir/runtime-checks" || result=1
"$check_dir/bridge-checks" || result=1
exit "$result"
