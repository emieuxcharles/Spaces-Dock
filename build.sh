#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source scripts/signing.sh
# Stable certificate and bundle identifier preserve the default Apple designated
# requirement. Never fall back to ad-hoc signing or weaken the requirement.
SIGNING_IDENTITY="${SPACES_DOCK_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && -f .signing-identity ]]; then
    SIGNING_IDENTITY="$(cat .signing-identity)"
fi
[[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != '-' ]] || fail 'Signature stable requise : SPACES_DOCK_SIGNING_IDENTITY ou .signing-identity.'
MODE="${SPACES_DOCK_BUILD_MODE:-local}"
case "$MODE" in
    local) TIMESTAMP='--timestamp=none' ;;
    developer-id) require_developer_id "$SIGNING_IDENTITY"; TIMESTAMP='--timestamp' ;;
    *) fail 'Mode de signature inconnu.' ;;
esac
OUTPUT="${1:-../../outputs}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd -P)"
DESTINATION="$OUTPUT/Spaces Dock.app"
[[ ! -L "$DESTINATION" ]] || fail 'Le paquet de destination est un lien symbolique ; choisir un autre dossier.'
[[ ! -e "$DESTINATION" || -d "$DESTINATION" ]] || fail 'La destination existante n’est pas un paquet.'
LOCK="$OUTPUT/.spaces-dock-build.lock"
mkdir "$LOCK" 2>/dev/null || fail "Une création utilise déjà ce dossier (verrou : $LOCK)."
STAGING=''
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$STAGING" && -d "$STAGING/previous.app" && ! -e "$DESTINATION" ]]; then
        if ! mv "$STAGING/previous.app" "$DESTINATION"; then
            printf 'Restauration nécessaire : le paquet précédent est conservé dans %s/previous.app\n' "$STAGING" >&2
            rmdir "$LOCK" || true
            exit 1
        fi
    fi
    [[ -z "$STAGING" ]] || rm -rf "$STAGING"
    rmdir "$LOCK" || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
STAGING="$(mktemp -d "$OUTPUT/.spaces-dock-build.XXXXXX")"
APP="$STAGING/Spaces Dock.app"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
BINARY_DIRECTORY="$(swift build -c release --show-bin-path)"
[[ -x "$BINARY_DIRECTORY/SpacesDock" ]] || fail 'Exécutable compilé introuvable.'
plutil -lint Info.plist Resources/PrivacyInfo.xcprivacy
[[ -s Resources/AppIcon.icns ]] || fail 'Icône manquante ; exécuter scripts/make-icon.sh.'
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY_DIRECTORY/SpacesDock" "$APP/Contents/MacOS/SpacesDock"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$TIMESTAMP" --identifier fr.local.spacesdock "$APP"
verify_bundle "$APP" "$MODE"
# Both renames stay on the output filesystem. Any handled error restores the old
# app; a power loss/SIGKILL may require restoring staging/previous.app manually.
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$STAGING/previous.app"; fi
mv "$APP" "$DESTINATION"
printf 'App vérifiée (%s) : %s\n' "$MODE" "$DESTINATION"
if [[ "$MODE" == local ]]; then
    printf 'Candidate locale ; cette signature ne constitue pas une livraison publique notarialisée.\n'
fi
