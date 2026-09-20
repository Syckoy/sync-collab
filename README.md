# Sync collab

## But
Snicula travaille sur le serveur. Quand il a fini : ENVOYER.
Toi tu RECUPERES son travail. Simple.

## Modes
| Choix | Quand | Vitesse |
|-------|-------|---------|
| **1 RECUPERER** | L autre a deja envoye (messager) | Moyen (upload/download) |
| **2 ENVOYER** | L autre n est pas la / pour plus tard | Moyen |
| **3 DIRECT** | Les DEUX sont devant le PC | Rapide (TCP local / IP) |

## Regles de confiance (v2.4)
1. RECUPERER / DIRECT = fusion uniquement (ajoute / remplace). **Jamais de suppression** de tes dossiers.
2. Avant chaque fusion : **backup automatique** dans `sync/backups/pre-recv-...`
3. ENVOYER (messager) : zip controle, lien re-telecharge, **puis seulement** manifeste publie.
4. DIRECT : meme pack + hash SHA256, multi-ports (27890..), discovery LAN, log dans `debug.log`.
5. Au demarrage : auto-debug (curl, gmod, ports, IPs) ecrit dans `debug.log`.

## Usage DIRECT (rapide)
1. Les DEUX ont la meme version (`sync.bat` a jour — accepter la maj GitHub)
2. Celui qui envoie : `3` -> `H` (heberger) — session annoncee auto + IP affichee
3. Celui qui recoit : `3` -> `C` (connecter) — Entree pour essayer toutes les sessions trouvees
4. Transfert TCP + hash + fusion + backup auto

Si pas sur le meme WiFi : VPN (ZeroTier/Hamachi) ou port TCP ouvert. Sinon utilise 1/2 messager.

## Si ca merde
- Rien n a du etre publie si l upload echoue (pas de faux lien)
- Si la fusion te plait pas : restaure depuis `sync/backups/`
- Envoie / lis `sync/debug.log` pour voir ce qui a echoue
