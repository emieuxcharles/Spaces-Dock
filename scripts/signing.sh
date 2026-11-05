#!/bin/bash
# Shared, fail-closed signature checks. No custom designated requirement is used.
fail() { printf 'Erreur : %s\n' "$*" >&2; exit 1; }
require_developer_id() {
    local identity="$1" identities
    [[ "$identity" =~ ^[[:xdigit:]]{40}$ ]] || fail 'SPACES_DOCK_DEVELOPER_ID doit contenir l’empreinte SHA-1 du certificat Developer ID Application.'
    identities="$(security find-identity -v -p codesigning)" || fail 'Impossible de lire les identités du trousseau.'
    printf '%s\n' "$identities" | awk -v id="$identity" '
        toupper($2) == toupper(id) && /"Developer ID Application:/ { found=1 }
        END { exit !found }
    ' || fail 'Certificat Developer ID Application avec clé privée introuvable ; une identité Apple Development ne permet pas cette livraison.'
}
verify_bundle() {
    local app="$1" mode="$2" details requirement
    codesign --verify --deep --strict "$app"
    details="$(codesign -dv --verbose=4 "$app" 2>&1)"
    requirement="$(codesign -d -r- "$app" 2>&1)"
    printf '%s\n' "$details" | grep -q '^Identifier=fr.local.spacesdock$' || fail 'Identifiant de signature inattendu.'
    printf '%s\n' "$details" | grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' || fail 'La signature ne porte pas une équipe Apple valide.'
    printf '%s\n' "$details" | grep -Eq 'flags=.*runtime' || fail 'Hardened runtime absent.'
    printf '%s\n' "$requirement" | grep -q 'anchor apple generic' || fail 'Exigence de signature Apple stable absente.'
    if [[ "$mode" == developer-id ]]; then
        printf '%s\n' "$details" | grep -q '^Authority=Developer ID Application:' || fail 'La signature finale n’est pas Developer ID Application.'
        printf '%s\n' "$details" | grep -q '^Timestamp=' || fail 'Horodatage sécurisé de signature absent.'
    fi
}
