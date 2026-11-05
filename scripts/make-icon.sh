#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/spacesdock-icon.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swift -module-cache-path "$TEMP/modules" scripts/MakeIcon.swift "$TEMP/AppIcon.iconset"
cp "$TEMP/AppIcon.iconset/AppIcon.icns" Resources/AppIcon.icns
if [[ $# -gt 0 ]]; then cp "$TEMP/AppIcon.iconset/icon_512x512@2x.png" "$1"; fi
printf 'Icône générée : Resources/AppIcon.icns\n'
