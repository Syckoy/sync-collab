Un seul dossier : celui-ci.

Lancer : sync.bat
  1 = recuperer le serveur (l autre peut etre parti)
  2 = envoyer le serveur (ensuite tu fermes)

La recuperation compare automatiquement :
  - fichiers / dossiers en plus chez l autre -> ajoutes
  - fichiers plus recents chez l autre -> ecrases
  - fichiers plus recents chez toi -> gardes
  - fichiers enleves chez l autre -> supprimes chez toi

Le pack prend tout le custom dans garrysmod (addons, cfg, gamemodes, data, settings, etc.)
et les dossiers a cote (ex: addon-post). Pas les maps / cache / VPK.

Envoi gros packs (v2.1+) :
  - au-dela de ~40 Mo, le zip est decoupe en morceaux (~40 Mo)
  - chaque morceau est uploade separement (code MNC-XXXXXXXX)
  - a la reception, tous les morceaux sont retelecharges, fusionnes, puis appliques

Reception (v2.2+) :
  - TOUT garrysmod est pris (data, lua, maps, bat, dll, vpk, addons...)
  - seuls exclus : dossier sync (l outil), .git / .vs, steamapps
  - la version ENVOYEE par l autre ecrase toujours la tienne
  - packs gros = multi-parts auto (~40 Mo)

Pour GitHub : uploader UNIQUEMENT les fichiers de CE dossier
(sync.bat, sync.ps1, config.json, version.json, README.md, .gitignore)
a la racine du repo, sans sous-dossier.
