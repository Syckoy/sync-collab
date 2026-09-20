# Sync collab

## But
Snicula travaille sur le serveur. Quand il a fini : ENVOYER.
Toi tu RECUPERES son travail. Simple.

## Regles de confiance (v2.3)
1. RECUPERER = fusion uniquement (ajoute / remplace). **Jamais de suppression** de tes dossiers.
2. Avant chaque recuperation : **backup automatique** dans `sync/backups/pre-recv-...`
3. ENVOYER : le zip est controle, le lien est re-telecharge pour verif, **puis seulement** le manifeste est publie.
4. Gros packs : decoupe en morceaux + barre de progression.

## Usage
1. Les DEUX ont la meme version (`sync.ps1` + `version.json`)
2. Lui : `sync.bat` -> 2 (envoyer)
3. Toi : `sync.bat` -> 1 (recuperer)

## Si ca merde
- Rien n a du etre publie si l upload echoue (pas de faux lien)
- Si la fusion te plait pas : restaure depuis `sync/backups/`
