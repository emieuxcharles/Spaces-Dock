#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security >/dev/null
STORE_BUILD_DIR="$(swift build --show-bin-path --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)"
# SwiftPM uses XCBuild by default in Xcode 27; retain the native layout for Xcode 26.
if [[ -d "$STORE_BUILD_DIR/Modules" ]]; then
    module_args=(-I "$STORE_BUILD_DIR/Modules" -I "$STORE_BUILD_DIR/SpacesBridge.build")
    core_objects=("$STORE_BUILD_DIR"/SpacesCore.build/*.swift.o)
    bridge_object="$STORE_BUILD_DIR/SpacesBridge.build/bridge.m.o"
else
    intermediates="$(dirname "$(dirname "$STORE_BUILD_DIR")")/Intermediates.noindex"
    object_root="$intermediates/SpacesDock.build/Debug"
    architecture="$(uname -m)"
    module_args=(-I "$STORE_BUILD_DIR" -Xcc "-fmodule-map-file=$intermediates/GeneratedModuleMaps/SpacesBridge.modulemap")
    core_objects=("$object_root/SpacesCore-t.build/Objects-normal/$architecture"/*.o)
    bridge_object="$object_root/SpacesBridge-t.build/Objects-normal/$architecture/bridge.o"
fi
swiftc -parse-as-library -swift-version 5 "${module_args[@]}" \
  Sources/SpacesDock/AppStore.swift Sources/SpacesDock/SystemAdapter.swift Sources/SpacesDock/RuntimeSafety.swift Sources/SpacesDock/RuntimeProcess.swift Sources/SpacesDock/MissionControl.swift \
  Tests/AppStoreChecks.swift "${core_objects[@]}" "$bridge_object" \
  -o "$STORE_BUILD_DIR/StoreChecks"
"$STORE_BUILD_DIR/StoreChecks"
