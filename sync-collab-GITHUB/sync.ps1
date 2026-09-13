#Requires -Version 5.1
param(
    [string]$Command
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root "config.json"
$VersionPath = Join-Path $Root "version.json"
$StatePath = Join-Path $Root ".update-state.json"
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

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-JsonFile([string]$path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Get-Cfg {
    $cfg = Read-JsonFile $ConfigPath
    if (-not $cfg) { throw "config.json introuvable." }
    return $cfg
}

function Get-SyncRoot($cfg) {
    $p = $cfg.syncRoot
    if (-not [System.IO.Path]::IsPathRooted($p)) {
        $p = [System.IO.Path]::GetFullPath((Join-Path $Root $p))
    }
    return $p
}

function Test-UpdateSkipRel([string]$rel) {
    $n = $rel -replace "\\", "/"
    if ($n -ieq "config.json") { return $true }
    if ($n -ieq ".update-state.json") { return $true }
    if ($n -like "tools/*") { return $true }
    if ($n -like "st-home/*") { return $true }
    if ($n -like "logs/*") { return $true }
    if ($n -ieq "ami.json") { return $true }
    return $false
}

function Invoke-GithubUpdate {
    if ($env:SYNC_COLLAB_UPDATED -eq "1") { return $false }
    if ($Command -eq "noupdate") { return $false }

    $version = Read-JsonFile $VersionPath
    if (-not $version) {
        $version = [pscustomobject]@{ repo = "Syckoy/sync-collab"; branch = "main"; version = "1.1.0" }
    }
    $repo = [string]$version.repo
    if (-not $repo) { $repo = "Syckoy/sync-collab" }
    $branch = [string]$version.branch
    if (-not $branch) { $branch = "main" }

    $state = Read-JsonFile $StatePath
    $localCommit = ""
    if ($state -and $state.commit) { $localCommit = [string]$state.commit }

    Write-Info ("Verification GitHub : https://github.com/" + $repo)
    $headers = @{
        "User-Agent" = "sync-collab-updater"
        "Accept"     = "application/vnd.github+json"
    }

    try {
        $commitInfo = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/commits/{1}" -f $repo, $branch) -Headers $headers -TimeoutSec 15
    } catch {
        Write-Warn "GitHub injoignable ou repo encore vide. On continue avec la version locale."
        return $false
    }

    $remoteCommit = [string]$commitInfo.sha
    if (-not $remoteCommit) {
        Write-Warn "Pas de commit distant. On continue."
        return $false
    }

    if ($localCommit -and ($localCommit -ieq $remoteCommit)) {
        Write-Ok "Logiciel deja a jour."
        return $false
    }

    $shortRemote = $remoteCommit.Substring(0, [Math]::Min(7, $remoteCommit.Length))
    $note = ""
    if ($commitInfo.commit -and $commitInfo.commit.message) {
        $note = (($commitInfo.commit.message -split "`n")[0]).Trim()
    }

    Write-Host ""
    Write-Warn "Une mise a jour du LOGICIEL est disponible."
    Write-Host ("Version GitHub : " + $shortRemote)
    if ($note) { Write-Host ("Notes : " + $note) }
    Write-Host ""
    Write-Host "Sans cette mise a jour, tu ne pourras pas utiliser ce logiciel."
    Write-Host ""
    $answer = Read-Host "Installer la mise a jour maintenant ? (O/N)"
    if ($answer -notmatch '^[oOyY]') {
        Write-ErrMsg "Mise a jour refusee. Fermeture."
        Write-Host "Relance sync.bat quand tu voudras installer la mise a jour."
        Read-Host "Entree pour fermer" | Out-Null
        exit 0
    }

    Write-Info "Telechargement de la derniere version..."
    $tmp = Join-Path $env:TEMP ("sync-collab-upd-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp "repo.zip"
    $extract = Join-Path $tmp "extract"
    $zipUrl = "https://github.com/{0}/archive/refs/heads/{1}.zip" -f $repo, $branch
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 120 -Headers @{ "User-Agent" = "sync-collab-updater" }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $srcRoot = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    if (-not $srcRoot) { throw "Archive GitHub invalide." }
    $srcDir = $srcRoot.FullName

    $copied = 0
    Get-ChildItem -LiteralPath $srcDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($srcDir.Length).TrimStart("\", "/")
        if (Test-UpdateSkipRel $rel) { return }
        $dest = Join-Path $Root $rel
        $destParent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        $copied++
    }

    Save-JsonFile $StatePath ([pscustomobject]@{
        commit    = $remoteCommit
        checkedAt = (Get-Date).ToString("o")
    })

    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }

    if ($copied -le 0) {
        Write-Warn "Aucun fichier a copier depuis GitHub."
        return $false
    }

    Write-Ok ("Mise a jour OK (" + $copied + " fichiers). Relance...")
    return $true
}

function Ensure-Syncthing {
    if (Test-Path -LiteralPath $StExe) { return $StExe }
    Write-Info "Telechargement de Syncthing (portable)..."
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    $headers = @{ "User-Agent" = "sync-collab-updater" }
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/syncthing/syncthing/releases/latest" -Headers $headers
    $asset = $rel.assets | Where-Object { $_.name -match "^syncthing-windows-amd64-v.*\.zip$" } | Select-Object -First 1
    if (-not $asset) { throw "Impossible de trouver l'archive Syncthing Windows." }
    $zip = Join-Path $env:TEMP "syncthing-windows.zip"
    Write-Info ("Telechargement " + $asset.name)
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
    if (-not $ok) { throw "Syncthing ne repond pas. Ferme une ancienne fenetre de synchro puis relance." }
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
    Save-JsonFile $AmiPath $obj
}

function Apply-Pairing {
    param($Port, $ApiKey, $cfg, $myId, $friendId)

    $friendId = Format-DeviceId $friendId
    $myId = Format-DeviceId $myId

    St-SendJson $Port $ApiKey POST "/rest/config/devices" @{
        deviceID          = $friendId
        name              = "Ami"
        autoAcceptFolders = $true
        compression       = "metadata"
        addresses         = @("dynamic")
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
        'sync-collab/.update-state.json',
        '(?d)desktop.ini',
        '.tmp.driveupload'
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $ignoreDst -Value $ignoreText -Encoding UTF8

    St-SendJson $Port $ApiKey POST "/rest/config/folders" @{
        id                = $cfg.folderId
        label             = $cfg.folderLabel
        path              = $syncRoot
        type              = $cfg.folderType
        rescanIntervalS   = 60
        fsWatcherEnabled  = $true
        ignorePerms       = $true
        devices           = @(
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
        throw "Le lien n a pas ete enregistre. Relance sync.bat."
    }

    St-SendJson $Port $ApiKey PATCH ("/rest/config/folders/" + $cfg.folderId) @{
        type = $cfg.folderType
    }

    try {
        Invoke-RestMethod -Method POST -Uri ("http://127.0.0.1:{0}/rest/db/scan?folder={1}" -f $Port, [uri]::EscapeDataString($cfg.folderId)) -Headers @{ "X-API-Key" = $ApiKey } | Out-Null
    } catch { }
}

function Show-ProgressLoop {
    param($Port, $ApiKey, $cfg, $myId, $Mode)

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
            $needFiles = 0
            if ($db.needFiles) { $needFiles = $db.needFiles }
            $fmt = '{0:N1}'
            $tailleGo = $fmt -f ($global / 1GB)
            $syncGo = $fmt -f ($inSync / 1GB)
            $resteGo = $fmt -f ($need / 1GB)

            Clear-Host
            Write-Host "==============================================" -ForegroundColor Magenta
            if ($Mode -eq "receiveonly") {
                Write-Host "  MODE : RECUPERER le serveur" -ForegroundColor Magenta
            } else {
                Write-Host "  MODE : ENVOYER une nouvelle version" -ForegroundColor Magenta
            }
            Write-Host "=============================================="
            Write-Host ""
            Write-Host "Ton code :"
            Write-Host $myId -ForegroundColor Yellow
            Write-Host ""
            Write-Host ('Etat dossier : ' + $db.state)
            Write-Host ('Taille vue   : ' + $tailleGo + ' Go')
            Write-Host ('Avancement   : ' + $syncGo + ' Go / ' + $pct + ' pct')
            Write-Host ""
            if ($online -gt 0) {
                Write-Ok "CONNECTE a ton ami."
                if ($Mode -eq "receiveonly") {
                    if ($need -gt 0) {
                        Write-Warn ('TELECHARGEMENT : ' + $resteGo + ' Go / ' + $needFiles + ' fichiers')
                    } elseif ($db.state -eq 'scanning' -or $db.state -eq 'syncing') {
                        Write-Warn "Reception en cours, laisse ouvert."
                    } else {
                        Write-Ok "Serveur recu (rien de plus a telecharger)."
                    }
                } else {
                    if ($db.state -eq 'scanning' -or $db.state -eq 'syncing') {
                        Write-Warn "Envoi / indexation en cours, laisse ouvert."
                    } else {
                        Write-Ok "Nouvelle version en cours d envoi (laisse ouvert tant que l autre recoit)."
                    }
                }
            } else {
                Write-Warn "PAS CONNECTE."
                if ($Mode -eq "receiveonly") {
                    Write-Host "L autre doit lancer sync.bat et choisir : ENVOYER une nouvelle version."
                } else {
                    Write-Host "L autre doit lancer sync.bat et choisir : RECUPERER le serveur."
                }
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
    Write-Warn "Colle le code de ton ami, puis Entree."
    $id = Read-Host "Code ami"
    if ([string]::IsNullOrWhiteSpace($id)) { throw "Pas de code ami." }
    return $id
}

function Read-SyncChoice {
    while ($true) {
        Clear-Host
        Write-Host "==============================================" -ForegroundColor Magenta
        Write-Host "  Que veux-tu faire ?" -ForegroundColor Magenta
        Write-Host "=============================================="
        Write-Host ""
        Write-Host "  1) RECUPERER le serveur"
        Write-Host "     Tu TELECHARGES les fichiers / corrections de l autre."
        Write-Host "     Lui doit choisir 2 (envoyer une nouvelle version)."
        Write-Host ""
        Write-Host "  2) ENVOYER une nouvelle version"
        Write-Host "     TES fichiers partent chez l autre."
        Write-Host "     Lui doit choisir 1 (recuperer le serveur)."
        Write-Host ""
        Write-Host "  0) Quitter"
        Write-Host ""
        $c = Read-Host "Choix"
        if ($c -eq "1") { return "receiveonly" }
        if ($c -eq "2") { return "sendonly" }
        if ($c -eq "0") {
            Write-Host "Fermeture."
            exit 0
        }
        Write-Warn "Choix invalide."
        Start-Sleep -Seconds 1
    }
}

function Invoke-Collab {
    $mode = Read-SyncChoice
    $cfg = Get-Cfg
    $cfg | Add-Member -NotePropertyName folderType -NotePropertyValue $mode -Force

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
    Write-Host "Copie dans le presse-papiers si possible." -ForegroundColor DarkGray
    Write-Host ""
    Write-Warn "Le code de ton ami DOIT etre different du tien."

    $friend = Read-FriendId
    $friendFmt = Format-DeviceId $friend
    if ((Normalize-DeviceId $friendFmt) -eq (Normalize-DeviceId $myId)) {
        throw "C est TON code. Les deux codes doivent etre differents."
    }

    Write-Info "Enregistrement du lien avec ton ami..."
    Apply-Pairing -Port $port -ApiKey $api -cfg $cfg -myId $myId -friendId $friendFmt
    Save-Ami $friendFmt "Ami"
    Write-Ok "Lien enregistre. Les DEUX scripts doivent rester ouverts."
    Write-Host ("Dossier : " + (Get-SyncRoot $cfg))
    if ($mode -eq "receiveonly") {
        Write-Host "Toi : RECUPERER. Lui : ENVOYER."
    } else {
        Write-Host "Toi : ENVOYER. Lui : RECUPERER."
    }

    try {
        Show-ProgressLoop -Port $port -ApiKey $api -cfg $cfg -myId $myId -Mode $mode
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

    $needRelaunch = $false
    try {
        $needRelaunch = Invoke-GithubUpdate
    } catch {
        Write-Warn ("Mise a jour GitHub ignoree : " + $_.Exception.Message)
    }

    if ($needRelaunch) {
        $env:SYNC_COLLAB_UPDATED = "1"
        $bat = Join-Path $Root "sync.bat"
        Start-Process -FilePath $bat
        exit 0
    }

    Invoke-Collab
} catch {
    Write-ErrMsg $_.Exception.Message
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Read-Host "Entree pour fermer" | Out-Null
    exit 1
}
