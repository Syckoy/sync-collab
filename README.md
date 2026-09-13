# sync-collab

Outil de synchro pour un serveur Garry's Mod local, a deux (toi + un ami), **sans envoyer le serveur sur GitHub**.

Ce depot contient **uniquement les scripts**. Le contenu du serveur (~30 Go) passe en direct entre les deux PC.

Repo : https://github.com/Syckoy/sync-collab

## Comment ca marche

1. Au lancement, `sync.bat` verifie GitHub et met a jour les scripts tout seul.
2. Ensuite les deux PC se connectent (codes a echanger **une seule fois**).
3. Tant que les deux fenetres sont ouvertes, les fichiers du serveur se recopient (seulement ce qui a change).

Le depot GitHub doit etre **public**, sinon la maj automatique ne pourra pas telecharger.

## Installation

1. Place ce dossier dans ton serveur, exemple :
   `...\server local\sync-collab\`
2. Double-clic sur `sync.bat`
3. Envoie **ton code** a l'autre
4. Colle **son code** (il doit etre different)
5. Laissez les deux fenetres ouvertes

Si `config.json` pointe mal vers le serveur, change `syncRoot` (par defaut `..` = le dossier parent).

## Usage

Au lancement :

1. Si une **mise a jour du logiciel** est sur GitHub, on te demande de l installer.
   - **O** = installation, puis relance
   - **N** = le logiciel se ferme (obligatoire)
2. Ensuite tu choisis :
   - **1 RECUPERER** = tu telecharges le serveur / les corrections
   - **2 ENVOYER** = tu envoies une nouvelle version
   - **0** = quitter

Les deux doivent etre ouverts **en meme temps**, avec le choix inverse :
celui qui a corrige choisit ENVOYER, l autre choisit RECUPERER.

## Mise a jour des scripts

Pousse tes corrections de **scripts** sur `main`. Au prochain lancement, chaque PC recupere tout seul la nouvelle version. Pas besoin de renvoyer des fichiers.

Les corrections **du serveur GMod** (addons, configs, etc.) ne passent pas par GitHub : elles passent par la synchro tant que les deux scripts sont ouverts.
