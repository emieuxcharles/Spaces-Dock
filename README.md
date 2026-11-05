# Spaces Dock

Utilitaire macOS en français pour organiser les applications par écran et bureau virtuel, tout en conservant le Dock Apple.

## Télécharger

Les versions installables sont disponibles dans [Releases](https://github.com/emieuxcharles/Spaces-Dock/releases). Télécharger le ZIP de l’application dans les fichiers joints à la Release ; les archives « Source code » contiennent uniquement les sources.

Version actuelle : **0.6.2 (21)**, MacBook Apple Silicon, **macOS 26 ou 27**. Le déplacement est testé sur macOS 27.2 ; le moteur macOS 26 est conservé avec ses tests de non-régression et les validations historiques sous 26.5.2. Les autres versions et les futures mises à jour majeures ne sont pas garanties compatibles. Voir [les vérifications et limites](docs/RELEASE.md).

1. Quitter l’ancienne version de Spaces Dock.
2. Décompresser le ZIP et déplacer **Spaces Dock.app** dans Applications.
3. Ouvrir l’app et autoriser **Accessibilité** dans les réglages macOS si nécessaire.
4. Choisir le profil correspondant aux écrans, ajouter les apps et leurs bureaux, puis **Appliquer ce profil**.

Les profils existants sont conservés lors du remplacement de l’app. Le passage d’une ancienne signature de développement à Developer ID peut nécessiter une nouvelle autorisation Accessibilité.

## Fonctions

- Deux profils : MacBook seul, ou MacBook avec un écran externe en mode étendu.
- Affectation des apps à un écran et un bureau ; création des bureaux manquants.
- Ordre des apps par bureau et organisation du Dock Apple en groupes.
- Ouverture des apps du profil à la connexion, adaptation automatique au changement d’écrans.
- Sauvegarde du Dock, restauration, import/export des profils et diagnostic local.

L’écran intégré doit être actif. La recopie vidéo, le capot fermé et plusieurs écrans externes ne sont pas pris en charge. Une app de barre des menus peut être lancée sans avoir de fenêtre à déplacer. Les fenêtres en plein écran sont ignorées et signalées.

## Développement et vérifications

Depuis ce dossier, avec les outils Xcode compatibles :

```sh
./check.sh
bash Tests/runtime-checks.sh
bash Tests/store-checks.sh
python3 Tests/Packaging/check.py
```

Compilation locale avec une identité stable du trousseau :

```sh
SPACES_DOCK_SIGNING_IDENTITY=EMPREINTE_DU_CERTIFICAT ./build.sh /chemin/vers/la-sortie
```

`release.sh` prépare séparément une archive Developer ID notarifiée. Il exige les références d’une identité et d’un profil notarytool du trousseau, sans exporter la clé privée. La création de l’archive ne publie pas sur GitHub : une Release GitHub doit ensuite être créée et l’archive ajoutée à ses fichiers joints. Un simple `git push` publie les sources, pas une nouvelle app téléchargeable.

## Confidentialité et compatibilité

Les profils restent sur le Mac. Aucun compte distant ni envoi automatique de données n’est intégré. Voir [la confidentialité](docs/PRIVACY.md).

La gestion des bureaux utilise des interfaces privées de macOS. La compatibilité doit être vérifiée après une mise à jour du système. Cette application est distribuée directement, hors du Mac App Store.
