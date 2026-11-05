#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-../../outputs}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd -P)"
VERSION="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
BUILD="$(plutil -extract CFBundleVersion raw Info.plist)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || { echo 'Version invalide.' >&2; exit 1; }
NAME="Spaces-Dock-$VERSION-$BUILD-source"
DESTINATION="$OUTPUT/$NAME.zip"
[[ ! -e "$DESTINATION" ]] || { echo "Archive déjà présente : $DESTINATION" >&2; exit 1; }
TEMP="$(mktemp -d "$OUTPUT/.spaces-dock-source.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
mkdir "$TEMP/$NAME"
# This allowlist deliberately omits identity files, logs, caches and local state.
for file in Package.swift Info.plist build.sh release.sh check.sh PRODUCT.md TECHNICAL-NOTES.md; do
    cp "$file" "$TEMP/$NAME/"
done
for directory in Sources Resources scripts Tests docs; do
    ditto "$directory" "$TEMP/$NAME/$directory"
done
# Reject secrets/symlinks even if someone later puts them inside an allowed folder.
if find "$TEMP/$NAME" \( -type l -o -name '.signing-identity' -o -name '*.p12' -o -name '*.pfx' -o -name '*.key' -o -name '*.pem' -o -name '.env*' \) -print | grep -q .; then
    echo 'Archive refusée : lien symbolique ou fichier de secret dans les sources.' >&2
    exit 1
fi
find "$TEMP/$NAME" -name __pycache__ -type d -prune -exec rm -rf {} +
ditto -c -k --sequesterRsrc --keepParent "$TEMP/$NAME" "$TEMP/archive.zip"
# Link is an exclusive creation: an archive arriving concurrently is never replaced.
ln "$TEMP/archive.zip" "$DESTINATION"
printf 'Archive source sans identité locale : %s\n' "$DESTINATION"
