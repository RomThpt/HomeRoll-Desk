# HomeRoll Desktop Local

Client natif macOS pour Immich, fork conservant les correctifs locaux.

## Validation

- Générer le projet : `xcodegen generate`.
- Compiler : `xcodebuild -project HomeRollDesktop.xcodeproj -scheme HomeRollDesktop -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- build`.
- Tests synthétiques : `xcodebuild -project HomeRollDesktop.xcodeproj -scheme HomeRollDesktop -derivedDataPath build CODE_SIGN_IDENTITY=- test`.
- Vérifier les plists avec `plutil -lint` et le diff avec `git diff --check`.
- Ne jamais exécuter les anciens SelfTest avec un compte réel : ils modifient le serveur.

## Invariants

- Les imports utilisent un client privé immuable et un contexte révocable, jamais le client global après une suspension.
- Changement de compte, droits ou arrêt de synchronisation : révoquer les imports et annuler leurs requêtes.
- Ne jamais supprimer les originaux Photos. Une ressource manquante ou non vérifiée reste à reprendre.
- Les reçus sont isolés par serveur/compte, version du média et ressources ; ne pas réutiliser les anciens marqueurs UUID seuls.
- Jetons dans le Trousseau uniquement ; aucun secret dans les fichiers, tests ou journaux.
- Aucun updater distant dans ce fork. Les mises à jour passent par revue du code, tests et compilation locale.
- Signature de développement personnelle et URL privée seulement dans les paramètres locaux ignorés.
- Les tests réseau utilisent URLProtocol et des identités factices, jamais Nexus.

## Limites

Le transfert conserve les ressources média originales, vidéos Live et rendus modifiés. Il ne reconstitue pas une photothèque Apple complète (albums, recettes d’ajustement propriétaires). Un reçu confirme le contenu exposé par Immich, pas une restauration indépendante ni une deuxième sauvegarde.
