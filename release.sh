#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source scripts/signing.sh
IDENTITY="${SPACES_DOCK_DEVELOPER_ID:-}"
PROFILE="${SPACES_DOCK_NOTARY_PROFILE:-}"
[[ -n "$IDENTITY" ]] || fail 'SPACES_DOCK_DEVELOPER_ID requis (empreinte Developer ID Application).'
[[ -n "$PROFILE" ]] || fail 'SPACES_DOCK_NOTARY_PROFILE requis (profil notarytool du trousseau).'
require_developer_id "$IDENTITY"
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
VERSION="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
BUILD="$(plutil -extract CFBundleVersion raw Info.plist)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || fail 'Version de paquet invalide.'
ARCH="$(uname -m)"
[[ "$ARCH" == arm64 ]] || fail 'Seule la candidate Apple Silicon est actuellement préparée ; ne pas annoncer une validation Intel.'
NAME="Spaces-Dock-$VERSION-$BUILD-$ARCH"
OUTPUT="${1:-../../outputs}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd -P)"
DESTINATION="$OUTPUT/$NAME"
[[ ! -e "$DESTINATION" ]] || fail "Livraison déjà présente : $DESTINATION (aucun remplacement automatique)."
LOCK="$OUTPUT/.spaces-dock-release.lock"
mkdir "$LOCK" 2>/dev/null || fail "Une livraison utilise déjà ce dossier (verrou : $LOCK)."
STAGING=''
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$STAGING" ]]; then
        if [[ "$status" -eq 0 ]]; then rm -rf "$STAGING"
        else printf 'Livraison interrompue ; aucun nouveau livrable publié. Diagnostic conservé : %s\n' "$STAGING" >&2
        fi
    fi
    rmdir "$LOCK" || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
STAGING="$(mktemp -d "$OUTPUT/.spaces-dock-release.XXXXXX")"
SPACES_DOCK_SIGNING_IDENTITY="$IDENTITY" SPACES_DOCK_BUILD_MODE=developer-id ./build.sh "$STAGING/build"
APP="$STAGING/build/Spaces Dock.app"
verify_bundle "$APP" developer-id
mkdir "$STAGING/deliverable"
REPORT="$STAGING/deliverable"
# This upload archive never becomes the distributable: stapling changes the app.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/upload.zip"
xcrun notarytool submit "$STAGING/upload.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$REPORT/notarization.json"
STATUS="$(plutil -extract status raw "$REPORT/notarization.json")"
SUBMISSION="$(plutil -extract id raw "$REPORT/notarization.json")"
[[ "$SUBMISSION" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || fail 'Identifiant de notarisation invalide.'
xcrun notarytool log "$SUBMISSION" "$REPORT/notarization-log.json" --keychain-profile "$PROFILE"
[[ "$STATUS" == Accepted ]] || fail "Notarisation refusée : $STATUS (consulter le journal conservé)."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
verify_bundle "$APP" developer-id
spctl --assess --type execute --verbose=4 "$APP" > "$REPORT/gatekeeper.txt" 2>&1
codesign -dv --verbose=4 "$APP" > "$REPORT/signature.txt" 2>&1
codesign -d -r- "$APP" >> "$REPORT/signature.txt" 2>&1
ARCHIVE="$REPORT/$NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
# Check the bytes recipients receive, including the stapled ticket.
mkdir "$STAGING/extracted"
ditto -x -k "$ARCHIVE" "$STAGING/extracted"
EXTRACTED="$STAGING/extracted/Spaces Dock.app"
verify_bundle "$EXTRACTED" developer-id
xcrun stapler validate "$EXTRACTED"
spctl --assess --type execute --verbose=4 "$EXTRACTED" >> "$REPORT/gatekeeper.txt" 2>&1
(cd "$REPORT" && shasum -a 256 "$NAME.zip" > SHA256SUMS)
[[ ! -e "$DESTINATION" ]] || fail 'La destination a été créée pendant la livraison ; aucun remplacement.'
mv "$REPORT" "$DESTINATION"
printf 'Archive signée, notarialisée, agrafée et vérifiée : %s/%s.zip\n' "$DESTINATION" "$NAME"
printf 'Avant publication, terminer la validation matérielle et session propre de docs/RELEASE.md.\n'
