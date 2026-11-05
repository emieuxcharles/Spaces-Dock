# Spaces Dock 0.6.2 (21) — distribution directe

L’application conserve son interface, les profils MacBook seul / avec un écran externe, l’ordre des apps dans le Dock Apple, le lancement à la connexion et la création des bureaux manquants. Aucun module de publication sur le Mac App Store n’est nécessaire. Le type AppStore dans le code désigne l’état de l’application, pas une intégration au magasin Apple.

## Compatibilité vérifiée

| Système | Preuve |
|---|---|
| macOS 27.2 (26B123), Apple Silicon, écran intégré | Test réel : inventaire de 7 bureaux, autorisation Accessibilité reconnue, aller-retour d’une fenêtre propre et d’une fenêtre d’un autre processus. Application réelle du profil : 12 fenêtres placées pour 7 applications. |
| macOS 26 | Chemin de déplacement inchangé ; tests automatisés conservés. Essais matériels historiques sous 26.5.2, pas de nouvelle machine 26 disponible pour cette campagne. |
| macOS 26.0 à 26.5.1 et autres versions 27 | Même chemin de capacités, mais aucune validation matérielle exhaustive. Le correctif d’UUID vide de 0.6.1 est conservé. |
| macOS 14/15 et antérieures | Non pris en charge par ce paquet : minimum de déploiement 26.0. |
| Prochaines versions majeures | Validation nécessaire avant activation : le moteur privé n’est pas présumé compatible. |

Le défaut reproduit était le rejet explicite de macOS 27 dans la sélection du moteur et dans le chargement du déplacement asynchrone. Les capacités sont présentes sur le Mac courant. L’autorisation d’utiliser ce même moteur est étendue à 27, avec les vérifications de symboles, de sélecteur et de résultat conservées. Il n’y a pas de repli silencieux vers le déplacement ancien sur 26/27.

## Résultats du 5 novembre 2026

- Cœur : 110 contrôles, zéro échec.
- État de l’application : 16 contrôles, zéro échec. Script adapté aux sorties SwiftPM de Xcode 26 et XCBuild de Xcode 27.
- Sécurité : 23 contrôles ; pont natif : 13 contrôles, zéro échec. Le nouveau scénario macOS 27 échouait avant correction.
- Fabrication : 12 tests réussis. Compilation release et signature locale stable vérifiées.
- Profil réel : Notion 1 fenêtre, Arc 1, Cursor 6, Claude 1, ChatGPT 1, iTerm 1, Termius 1. OpenClaw est lancé (app LSUIElement) mais ne présente aucune fenêtre : signalement conservé, pas de faux succès.

Les appels lancés directement depuis le Terminal ne reproduisent pas les autorisations ni l’enregistrement des fenêtres d’une app lancée normalement. Les essais de déplacement et de profil ont été faits via LaunchServices. Les journaux et la copie avant changement se trouvent dans work/macos-27-recovery. Profils et options de connexion comparés avant/après : identiques. Les métadonnées de dernière application du profil peuvent évoluer normalement.

## Utilisation

Ouvrir outputs/Spaces Dock.app, choisir le profil correspondant aux écrans et utiliser « Appliquer ce profil ». Autoriser l’accessibilité si macOS la demande. Sur le Mac courant, l’autorisation existante est reconnue.

Le paquet installé localement garde sa signature de développement stable. L’archive destinée à GitHub est signée Developer ID Application et a été acceptée par le service de notarisation Apple le 5 novembre 2026 (soumission d24fad0c-2844-4f37-acff-5a40b4f05187, aucun avertissement). Le ticket est agrafé et Gatekeeper accepte aussi la copie extraite du ZIP. Cette validation de distribution ne remplace pas les essais fonctionnels ci-dessus. Les tests ne prouvent pas tous les scénarios de déconnexion, de connexion de session ou de branchement physique d’un écran externe. Les fonctions de bureaux reposent sur des interfaces privées de macOS : aucune garantie universelle de compatibilité future.

Les anciennes livraisons, guides, captures et prototypes sont rangés dans archives/2026-11-05. Aucun certificat ou identifiant du trousseau n’a été supprimé.
