#Requires -Version 5.1
param(
    [string]$Command
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root "config.json"
$ToolsDir = Join-Path $Root "tools"
$DataDir = Join-Path $env:LOCALAPPDATA "serveur-local-sync"
$StHome = Join-Path $DataDir "st-home"
$LogDir = Join-Path $DataDir "logs"
$AmiPath = Join-Path $DataDir "ami.json"
$StExe = Join-Path $ToolsDir "syncthing.exe"

function Write-Info($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host $msg -ForegroundColor Green }
function Write-Warn($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-ErrMsg($msg) { Write-Host $msg -ForegroundColor Red }

function Get-Cfg {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "config.json introuvable."
    }
    return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-SyncRoot($cfg) {
    $p = $cfg.syncRoot
    if (-not [System.IO.Path]::IsPathRooted($p)) {
        $p = [System.IO.Path]::GetFullPath((Join-Path $Root $p))
    }
    return $p
}

function Ensure-Syncthing {
    if (Test-Path -LiteralPath $StExe) { return $StExe }
    Write-Info "Telechargement de Syncthing (portable)..."
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    $headers = @{ "User-Agent" = "serveur-local-sync" }
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/syncthing/syncthing/releases/latest" -Headers $headers
    $asset = $rel.assets | Where-Object { $_.name -match "^syncthing-windows-amd64-v.*\.zip$" } | Select-Object -First 1
    if (-not $asset) { throw "Impossible de trouver l'archive Syncthing Windows." }
    $zip = Join-Path $env:TEMP "syncthing-windows.zip"
    Write-Info ("Telechargement " + $asset.name + " ...")
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -Headers $headers
    $extract = Join-Path $env:TEMP "syncthing-extract"
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $found = Get-ChildItem -Path $extract -Recurse -Filter "syncthing.exe" | Select-Object -First 1
    if (-not $found) { throw "syncthing.exe introuvable dans l'archive." }
    Copy-Item $found.FullName $StExe -Force
    Write-Ok "Syncthing installe."
    return $StExe
}

function Get-ApiKey {
    $xmlPath = Join-Path $StHome "config.xml"
    if (-not (Test-Path -LiteralPath $xmlPath)) { return $null }
    [xml]$xml = Get-Content -LiteralPath $xmlPath -Encoding UTF8
    return $xml.configuration.gui.apikey
}

function Wait-Api {
    param([string]$ApiKey, [int]$Port, [int]$Seconds = 45)
    $ok = $false
    $n = 0
    while ($n -lt $Seconds) {
        try {
            $null = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/rest/system/ping" -f $Port) -Headers @{ "X-API-Key" = $ApiKey } -TimeoutSec 2
            $ok = $true
            break
        } catch {
            Start-Sleep -Seconds 1
            $n++
        }
    }
    if (-not $ok) { throw "Syncthing ne repond pas. Reessaie, ou ferme une ancienne fenetre de synchro." }
}

function St-Get {
    param($Port, $ApiKey, $Path)
    return Invoke-RestMethod -Uri ("http://127.0.0.1:{0}{1}" -f $Port, $Path) -Headers @{ "X-API-Key" = $ApiKey }
}

function St-SendJson {
    param($Port, $ApiKey, $Method, $Path, $Body)
    $json = $Body | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $uri = "http://127.0.0.1:{0}{1}" -f $Port, $Path
    Invoke-RestMethod -Method $Method -Uri $uri -Headers @{ "X-API-Key" = $ApiKey } -ContentType "application/json; charset=utf-8" -Body $bytes | Out-Null
}

function Start-Engine {
    param($cfg)
    Ensure-Syncthing | Out-Null
    New-Item -ItemType Directory -Force -Path $StHome | Out-Null
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

    $already = $null
    try { $already = Get-NetTCPConnection -LocalPort $cfg.guiPort -State Listen -ErrorAction SilentlyContinue } catch { }
    if ($already) {
        $key = Get-ApiKey
        if ($key) {
            Write-Warn "Syncthing tourne deja. On le reutilise."
            return @{ Process = $null; Reused = $true }
        }
        throw ("Le port {0} est deja pris. Ferme l'autre synchro puis relance." -f $cfg.guiPort)
    }

    $logOut = Join-Path $LogDir "syncthing.out.log"
    $logErr = Join-Path $LogDir "syncthing.err.log"
    $gui = "http://127.0.0.1:$($cfg.guiPort)"
    $stArgs = "serve --home `"$StHome`" --no-browser --no-upgrade --gui-address `"$gui`""
    $p = Start-Process -FilePath $StExe -ArgumentList $stArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $logOut -RedirectStandardError $logErr

    $tries = 0
    while ($tries -lt 40) {
        $key = Get-ApiKey
        if ($key) { break }
        if ($p.HasExited) {
            $detail = ""
            if (Test-Path -LiteralPath $logErr) {
                $detail = (Get-Content -LiteralPath $logErr -Raw -ErrorAction SilentlyContinue)
            }
            throw ("Syncthing s'est arrete trop tot. " + $detail)
        }
        Start-Sleep -Milliseconds 500
        $tries++
    }
    $key = Get-ApiKey
    if (-not $key) { throw "Pas de cle API. Relance le script." }
    Wait-Api -ApiKey $key -Port $cfg.guiPort
    return @{ Process = $p; Reused = $false }
}

function Stop-Engine {
    param($Port, $ApiKey, $Proc)
    try {
        Invoke-RestMethod -Method POST -Uri ("http://127.0.0.1:{0}/rest/system/shutdown" -f $Port) -Headers @{ "X-API-Key" = $ApiKey } | Out-Null
    } catch { }
    if ($Proc -and -not $Proc.HasExited) {
        Start-Sleep -Seconds 2
        if (-not $Proc.HasExited) {
            try { $Proc.Kill() } catch { }
        }
    }
}

function Get-MyId($Port, $ApiKey) {
    $st = St-Get $Port $ApiKey "/rest/system/status"
    return $st.myID
}

function Normalize-DeviceId([string]$raw) {
    if (-not $raw) { return "" }
    $s = $raw.Trim().ToUpper() -replace "[^A-Z0-9]", ""
    return $s
}

function Format-DeviceId([string]$raw) {
    $s = Normalize-DeviceId $raw
    if ($s.Length -lt 56) { return $raw.Trim() }
    $parts = @()
    for ($i = 0; $i -lt 56; $i += 7) {
        $parts += $s.Substring($i, [Math]::Min(7, $s.Length - $i))
    }
    return ($parts -join "-")
}

function Load-Ami {
    if (Test-Path -LiteralPath $AmiPath) {
        return Get-Content -LiteralPath $AmiPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $null
}

function Save-Ami([string]$deviceId, [string]$name) {
    $obj = @{ deviceId = $deviceId; name = $name; savedAt = (Get-Date).ToString("s") }
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath $AmiPath -Encoding UTF8
}

function Apply-Pairing {
    param($Port, $ApiKey, $cfg, $myId, $friendId)

    $friendId = Format-DeviceId $friendId
    $myId = Format-DeviceId $myId

    St-SendJson $Port $ApiKey POST "/rest/config/devices" @{
        deviceID = $friendId
        name = "Ami"
        autoAcceptFolders = $true
        compression = "metadata"
        addresses = @("dynamic")
    }

    $syncRoot = Get-SyncRoot $cfg
    if (-not (Test-Path -LiteralPath $syncRoot)) {
        New-Item -ItemType Directory -Force -Path $syncRoot | Out-Null
    }

    $ignoreDst = Join-Path $syncRoot ".stignore"
    $ignoreText = @(
        'sync-collab/tools',
        'sync-collab/st-home',
        'sync-collab/logs',
        'sync-collab/ami.json',
        '(?d)desktop.ini',
        '.tmp.driveupload'
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $ignoreDst -Value $ignoreText -Encoding UTF8

    St-SendJson $Port $ApiKey POST "/rest/config/folders" @{
        id = $cfg.folderId
        label = $cfg.folderLabel
        path = $syncRoot
        type = "sendreceive"
        rescanIntervalS = 60
        fsWatcherEnabled = $true
        ignorePerms = $true
        devices = @(
            @{ deviceID = $myId }
            @{ deviceID = $friendId }
        )
    }

    $devs = @(St-Get $Port $ApiKey "/rest/config/devices")
    $folders = @(St-Get $Port $ApiKey "/rest/config/folders")
    $hasFriend = $false
    foreach ($d in $devs) {
        if ((Normalize-DeviceId $d.deviceID) -eq (Normalize-DeviceId $friendId)) { $hasFriend = $true }
    }
    $hasFolder = $false
    foreach ($f in $folders) {
        if ($f.id -eq $cfg.folderId) { $hasFolder = $true }
    }
    if (-not $hasFriend -or -not $hasFolder) {
        throw "Le lien n'a pas ete enregistre dans Syncthing. Relance sync.bat. Si ca recommence, dis-le."
    }

    try {
        Invoke-RestMethod -Method POST -Uri ("http://127.0.0.1:{0}/rest/db/scan?folder={1}" -f $Port, [uri]::EscapeDataString($cfg.folderId)) -Headers @{ "X-API-Key" = $ApiKey } | Out-Null
    } catch { }
}

function Show-ProgressLoop {
    param($Port, $ApiKey, $cfg, $myId)

    Write-Host ""
    Write-Ok "Synchro en cours. Laisse cette fenetre ouverte."
    Write-Host "Touche Q pour arreter proprement." -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq "Q") { break }
        }

        try {
            $conn = St-Get $Port $ApiKey "/rest/system/connections"
            $db = St-Get $Port $ApiKey ("/rest/db/status?folder=" + [uri]::EscapeDataString($cfg.folderId))
            $friends = @()
            if ($conn.connections) {
                $friends = @($conn.connections.PSObject.Properties)
            }
            $online = 0
            foreach ($f in $friends) {
                if ($f.Value.connected) { $online++ }
            }

            $need = 0
            if ($db.needBytes) { $need = [int64]$db.needBytes }
            $global = 0
            if ($db.globalBytes) { $global = [int64]$db.globalBytes }
            $inSync = 0
            if ($db.inSyncBytes) { $inSync = [int64]$db.inSyncBytes }

            $pct = 0
            if ($global -gt 0) { $pct = [math]::Round(100.0 * $inSync / $global, 1) }

            Clear-Host
            Write-Host "==============================================" -ForegroundColor Magenta
            Write-Host "  SERVEUR LOCAL - synchro complete" -ForegroundColor Magenta
            Write-Host "=============================================="
            Write-Host ""
            Write-Host "Ton code :"
            Write-Host $myId -ForegroundColor Yellow
            Write-Host ""
            $needFiles = 0
            if ($db.needFiles) { $needFiles = $db.needFiles }
            $fmt = '{0:N1}'
            $tailleGo = $fmt -f ($global / 1GB)
            $syncGo = $fmt -f ($inSync / 1GB)
            $resteGo = $fmt -f ($need / 1GB)
            Write-Host ('Etat dossier : ' + $db.state)
            Write-Host ('Taille vue   : ' + $tailleGo + ' Go')
            Write-Host ('Deja recu    : ' + $syncGo + ' Go / ' + $pct + ' pct')
            Write-Host ""
            if ($online -gt 0) {
                Write-Ok "CONNECTE a ton ami."
                if ($need -gt 0) {
                    Write-Warn ('TELECHARGEMENT : ' + $resteGo + ' Go / ' + $needFiles + ' fichiers')
                } elseif ($db.state -eq 'scanning' -or $db.state -eq 'syncing') {
                    Write-Warn "Indexation / copie en cours, laisse ouvert."
                } else {
                    Write-Ok "Rien a telecharger pour le moment (deja a jour, ou ami pas encore pret)."
                }
            } else {
                Write-Warn "PAS CONNECTE. Aucun fichier ne peut arriver."
                Write-Host "Ton ami doit avoir sync.bat OUVERT en meme temps que toi."
            }
            Write-Host ""
            Write-Host "Q = quitter" -ForegroundColor DarkGray
        } catch {
            Write-Warn "Dossier de synchro pas encore pret..."
            Write-Host $_.Exception.Message -ForegroundColor DarkGray
        }

        Start-Sleep -Seconds 2
    }
}

function Read-FriendId {
    $saved = Load-Ami
    if ($saved -and $saved.deviceId) {
        Write-Ok ("Code ami deja enregistre : " + $saved.deviceId)
        $again = Read-Host "Entree pour garder, ou colle un nouveau code"
        if ([string]::IsNullOrWhiteSpace($again)) { return $saved.deviceId }
        return $again
    }
    Write-Host ""
    Write-Warn "Colle le code de ton ami (celui affiche chez lui), puis Entree."
    $id = Read-Host "Code ami"
    if ([string]::IsNullOrWhiteSpace($id)) { throw "Pas de code ami. Relance quand tu as son code." }
    return $id
}

function Invoke-Collab {
    $cfg = Get-Cfg
    Write-Info "Demarrage du moteur de synchro..."
    $eng = Start-Engine $cfg
    $api = Get-ApiKey
    $port = $cfg.guiPort
    $myId = Get-MyId $port $api

    Clear-Host
    Write-Host "==============================================" -ForegroundColor Magenta
    Write-Host "  ENVOIE CE CODE A TON AMI" -ForegroundColor Magenta
    Write-Host "=============================================="
    Write-Host ""
    Write-Host $myId -ForegroundColor Yellow
    Write-Host ""
    try { Set-Clipboard -Value $myId } catch { }
    Write-Host "(copie dans le presse-papiers si possible)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Warn "Le code de ton ami DOIT etre different du tien."
    Write-Host "S'il a le meme : il a recu ton dossier st-home. Il le supprime et il relance."

    $friend = Read-FriendId
    $friendFmt = Format-DeviceId $friend
    if ((Normalize-DeviceId $friendFmt) -eq (Normalize-DeviceId $myId)) {
        throw "C'est TON code, pas le sien. Les deux codes doivent etre differents. Ton ami doit supprimer sync-collab\st-home chez lui puis relancer sync.bat."
    }

    Write-Info "Enregistrement du lien avec ton ami..."
    Apply-Pairing -Port $port -ApiKey $api -cfg $cfg -myId $myId -friendId $friendFmt
    Save-Ami $friendFmt "Ami"
    Write-Ok "Lien enregistre. Les DEUX scripts doivent rester ouverts."
    Write-Host ("Dossier : " + (Get-SyncRoot $cfg))
    Write-Host "Sur l'ecran suivant : CONNECTE = ca tourne. PAS CONNECTE = ton ami n'a pas le script ouvert."

    try {
        Show-ProgressLoop -Port $port -ApiKey $api -cfg $cfg -myId $myId
    } finally {
        if (-not $eng.Reused) {
            Write-Info "Arret de la synchro..."
            Stop-Engine -Port $port -ApiKey $api -Proc $eng.Process
        }
    }
}

try {
    if ($Command -eq "stop") {
        $cfg = Get-Cfg
        $api = Get-ApiKey
        if ($api) { Stop-Engine -Port $cfg.guiPort -ApiKey $api -Proc $null }
        Write-Ok "Stop demande."
        return
    }
    Invoke-Collab
} catch {
    Write-ErrMsg $_.Exception.Message
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Read-Host "Entree pour fermer" | Out-Null
    exit 1
}
