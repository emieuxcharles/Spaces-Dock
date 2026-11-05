# Confidentialité et permissions — candidate 0.6.0

Spaces Dock ne contient aucun client réseau, compte distant, télémétrie, SDK publicitaire ou envoi automatique de diagnostics. Les profils et la sauvegarde du Dock sont enregistrés localement dans le dossier Application Support de l’utilisateur. Un fichier exporté volontairement peut contenir les noms de profils, les chemins des applications et des éléments de diagnostic : le relire avant de le partager.

L’app lit les applications, fenêtres et bureaux pour afficher les affectations et placer les fenêtres. L’autorisation Accessibilité sert à la création des bureaux via Mission Control et au placement des fenêtres ; elle peut être retirée dans Réglages Système. L’app modifie les préférences du Dock lors d’une application explicite ou d’une automatisation activée et relance le processus Dock pour charger cette configuration. Elle conserve le Dock d’Apple. Le choix du lancement à la connexion utilise ServiceManagement. Elle ne demande pas d’enregistrement d’écran et ne capture pas d’image du contenu des fenêtres.

Le manifeste embarqué déclare l’absence de collecte et de suivi. Le contrôle final du 29 octobre 2026 déclare aussi le motif `35F9.1` pour la mesure des délais locaux. Les constats de l’audit sont :

| Catégorie examinée | Constat dans le code de l’app |
|---|---|
| Préférences | `CFPreferencesCopyAppValue`, `CFPreferencesSetAppValue` et synchronisation accèdent aux domaines Dock/Spaces. Aucun appel direct `UserDefaults` ou `@AppStorage`. Le motif `CA92.1`, limité aux préférences propres à l’app, serait inexact pour ces domaines système ; il n’a pas été ajouté. |
| Dates de fichiers / espace disque | Lecture et écriture de fichiers de configuration, tests d’existence et dossiers temporaires. Pas de lecture explicite de création/modification des fichiers, `stat`, `fstat`, `statfs` ou capacité du volume dans le code applicatif examiné. |
| Démarrage système / claviers actifs | `ProcessInfo.systemUptime` borne les recherches de fenêtres et de contrôles Mission Control. Motif `35F9.1` : calculer des délais locaux. Aucune valeur de démarrage n’est conservée ni exportée. Pas d’inventaire des claviers actifs. |
| Dépendances | Cibles locales Swift/AppKit/SwiftUI/CoreFoundation et pont Objective-C ; aucun paquet tiers téléchargé déclaré dans Package.swift. |

Cet inventaire porte sur les appels applicatifs explicites, pas sur une analyse de toutes les implémentations internes des frameworks Apple. Selon la documentation Apple consultée, les déclarations des motifs obligatoires visent iOS, iPadOS, tvOS, visionOS et watchOS ; cette app est exclusivement macOS. Refaire l’inventaire à l’ajout d’un SDK, d’une collecte, d’un API concerné ou avant une nouvelle voie de distribution.

La notarisation effectuée par le développeur transmet le paquet compilé à Apple. Elle ne transmet pas les profils ou diagnostics de l’utilisateur et ne constitue pas une fonctionnalité réseau de l’app.

Sources : [contenu d’un manifeste](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files), [plateformes et règles des motifs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), [liste d’API et motifs autorisés](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
