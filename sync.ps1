#Requires -Version 5.1
param([string]$Command)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root "config.json"
$VersionPath = Join-Path $Root "version.json"
$StatePath = Join-Path $Root ".update-state.json"
$AllowUpdate = @("sync.ps1", "sync.bat", "version.json", "README.md", ".gitignore")

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
    if (-not $p) { $p = ".." }
    if (-not [System.IO.Path]::IsPathRooted($p)) {
        $p = [System.IO.Path]::GetFullPath((Join-Path $Root $p))
    }
    return $p
}

function Remove-NestedClone {
    $leaf = Split-Path $Root -Leaf
    $nested = Join-Path $Root $leaf
    if ($nested -eq $Root) { return }
    if ((Test-Path -LiteralPath $nested) -and (Test-Path -LiteralPath (Join-Path $nested "sync.ps1"))) {
        Write-Warn "Suppression du dossier duplique..."
        Remove-Item -LiteralPath $nested -Recurse -Force
    }
}

function Get-Curl {
    $c = Join-Path $env:SystemRoot "System32\curl.exe"
    if (-not (Test-Path -LiteralPath $c)) { throw "curl.exe introuvable (Windows)." }
    return $c
}

function Invoke-GithubUpdate {
    if ($env:SYNC_COLLAB_UPDATED -eq "1") { return $false }
    if ($Command -eq "noupdate") { return $false }

    $version = Read-JsonFile $VersionPath
    $repo = "Syckoy/sync-collab"
    $branch = "main"
    if ($version -and $version.repo) { $repo = [string]$version.repo }
    if ($version -and $version.branch) { $branch = [string]$version.branch }

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
        Write-Warn "GitHub injoignable. On continue avec la version locale."
        return $false
    }

    $remoteCommit = [string]$commitInfo.sha
    if (-not $remoteCommit) { return $false }
    if ($localCommit -and ($localCommit -ieq $remoteCommit)) {
        Write-Ok "Logiciel deja a jour."
        return $false
    }

    $shortRemote = $remoteCommit.Substring(0, [Math]::Min(7, $remoteCommit.Length))
    Write-Host ""
    Write-Warn "Une mise a jour du LOGICIEL est disponible."
    Write-Host ("Version GitHub : " + $shortRemote)
    Write-Host "Sans cette mise a jour, tu ne pourras pas utiliser ce logiciel."
    Write-Host ""
    $answer = Read-Host "Installer la mise a jour maintenant ? (O/N)"
    if ($answer -notmatch '^[oOyY]') {
        Write-ErrMsg "Mise a jour refusee. Fermeture."
        Read-Host "Entree pour fermer" | Out-Null
        exit 0
    }

    Write-Info "Telechargement..."
    $tmp = Join-Path $env:TEMP ("sync-collab-upd-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp "repo.zip"
    $extract = Join-Path $tmp "extract"
    $zipUrl = "https://github.com/{0}/archive/refs/heads/{1}.zip" -f $repo, $branch
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 120 -Headers @{ "User-Agent" = "sync-collab-updater" }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

    $ps1 = Get-ChildItem -LiteralPath $extract -Recurse -Filter "sync.ps1" -File | Select-Object -First 1
    if (-not $ps1) { throw "sync.ps1 introuvable dans GitHub. Mets les fichiers a la racine du repo, pas dans un sous-dossier." }
    $srcDir = $ps1.Directory.FullName

    foreach ($name in $AllowUpdate) {
        $src = Join-Path $srcDir $name
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $Root $name) -Force
        }
    }

    Save-JsonFile $StatePath ([pscustomobject]@{
        commit    = $remoteCommit
        checkedAt = (Get-Date).ToString("o")
    })
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    Remove-NestedClone
    Write-Ok "Mise a jour OK. Relance..."
    return $true
}

function Get-PackFolders($cfg) {
    $syncRoot = Get-SyncRoot $cfg
    $rels = @($cfg.packFolders)
    if (-not $rels -or $rels.Count -eq 0) {
        $rels = @(
            "steamapps/common/GarrysModDS/garrysmod/addons",
            "steamapps/common/GarrysModDS/garrysmod/gamemodes/mangarp",
            "steamapps/common/GarrysModDS/garrysmod/cfg"
        )
    }
    $list = @()
    foreach ($rel in $rels) {
        $full = Join-Path $syncRoot ($rel -replace "/", "\")
        if (Test-Path -LiteralPath $full) {
            $list += [pscustomobject]@{ Rel = $rel; Full = $full; Name = Split-Path $full -Leaf }
        } else {
            Write-Warn ("Ignore (introuvable) : " + $rel)
        }
    }
    if ($list.Count -eq 0) { throw "Aucun dossier serveur a empaqueter. Verifie packFolders dans config.json." }
    return $list
}

function New-ServerPack($cfg) {
    $folders = Get-PackFolders $cfg
    $stage = Join-Path $env:TEMP ("sync-pack-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $stage | Out-Null
    foreach ($f in $folders) {
        $dest = Join-Path $stage $f.Name
        Write-Info ("Ajout : " + $f.Rel)
        Copy-Item -LiteralPath $f.Full -Destination $dest -Recurse -Force
    }
    $zip = Join-Path $env:TEMP ("serveur-pack-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".zip")
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Write-Info "Compression du pack..."
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -Force
    try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    $item = Get-Item -LiteralPath $zip
    Write-Ok ("Pack pret : {0:N1} Mo" -f ($item.Length / 1MB))
    return $item
}

function Get-ShortErr([string]$s) {
    if (-not $s) { return "(vide)" }
    if ($s -match "uploads disabled") { return "hebergeur ferme (spam)" }
    if ($s -match "(?i)internal server error|<html|<!doctype") { return "hebergeur down (erreur 500)" }
    $t = $s.Trim()
    if ($t.Length -gt 180) { return $t.Substring(0, 180) }
    return $t
}

function Send-PackFile([string]$zipPath) {
    $curl = Get-Curl
    Write-Info "Envoi du pack (tu pourras fermer ensuite)..."
    $fileForm = "file=@$zipPath"

    Write-Info "Tentative Gofile..."
    $raw = & $curl -sS -A "sync-collab" -X POST "https://upload.gofile.io/uploadfile" -F $fileForm
    try {
        $json = $raw | ConvertFrom-Json
        if ($json.status -eq "ok" -and $json.data) {
            $page = [string]$json.data.downloadPage
            $fid = [string]$json.data.id
            $fname = [string]$json.data.name
            if (-not $fname) { $fname = "serveur-pack.zip" }
            $server = $null
            if ($json.data.servers) {
                $sv = @($json.data.servers)
                if ($sv.Count -gt 0) { $server = [string]$sv[0] }
            }
            $link = $page
            if ($json.data.directLink) {
                $link = [string]$json.data.directLink
            } elseif ($server -and $fid) {
                $link = "https://{0}.gofile.io/download/web/{1}/{2}" -f $server, $fid, [uri]::EscapeDataString($fname)
            }
            Write-Ok "Pack envoye via Gofile."
            return [pscustomobject]@{
                id    = $fid
                url   = $link
                page  = $page
                token = [string]$json.data.guestToken
            }
        }
    } catch { }
    Write-Warn ("Gofile : " + (Get-ShortErr $raw))

    Write-Info "Tentative bashupload..."
    $raw = & $curl -sS -T $zipPath "https://bashupload.com/serveur-pack.zip"
    if ($raw -and $raw -match "https?://\S+") {
        $u = ([regex]::Match($raw, "https?://\S+")).Value.Trim().TrimEnd(".")
        Write-Ok "Pack envoye."
        return [pscustomobject]@{ id = $u; url = $u; page = $u }
    }
    Write-Warn ("bashupload : " + (Get-ShortErr $raw))

    Write-Info "Tentative file.io..."
    $raw = & $curl -sS -F $fileForm "https://file.io/?expires=2d"
    try {
        $json = $raw | ConvertFrom-Json
        if ($json.success -and $json.link) {
            $u = [string]$json.link
            Write-Ok "Pack envoye."
            return [pscustomobject]@{ id = $u; url = $u; page = $u }
        }
    } catch { }
    Write-Warn ("file.io : " + (Get-ShortErr $raw))

    throw "Echec upload : tous les hebergeurs ont refuse. Reessaie dans 2 minutes."
}

function Publish-Manifest($cfg, $up, $sizeBytes) {
    $channel = [string]$cfg.dropChannel
    if (-not $channel) { $channel = "syckoy-gmod-sync-collab" }
    $manifest = @{
        id        = $up.id
        url       = $up.url
        page      = $up.page
        token     = $up.token
        sentAt    = (Get-Date).ToString("o")
        sizeBytes = $sizeBytes
        name      = "serveur-pack.zip"
    } | ConvertTo-Json -Compress
    $uri = "https://ntfy.sh/" + $channel
    Invoke-RestMethod -Method POST -Uri $uri -Body $manifest -ContentType "text/plain; charset=utf-8" | Out-Null
}

function Get-Manifest($cfg) {
    $channel = [string]$cfg.dropChannel
    if (-not $channel) { $channel = "syckoy-gmod-sync-collab" }
    $uri = "https://ntfy.sh/" + $channel + "/json?poll=1"
    $raw = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 20
    $lines = @()
    if ($raw.Content) {
        $lines = $raw.Content -split "`n" | Where-Object { $_.Trim() -ne "" }
    }
    if ($lines.Count -eq 0) { throw "Aucune version envoyee pour le moment." }
    $last = $null
    foreach ($line in $lines) {
        try {
            $ev = $line | ConvertFrom-Json
            if ($ev.message) {
                $msg = $ev.message
                if ($msg.Trim().StartsWith("{")) {
                    $last = $msg | ConvertFrom-Json
                }
            }
        } catch { }
    }
    if (-not $last -or -not $last.url) { throw "Manifest invalide. L autre doit renvoyer une version." }
    return $last
}

function Invoke-Send {
    $cfg = Get-Cfg
    $pack = New-ServerPack $cfg
    try {
        $up = Send-PackFile $pack.FullName
        Publish-Manifest $cfg $up $pack.Length
        Write-Host ""
        Write-Ok "C est envoye. Tu peux FERMER le logiciel."
        Write-Host "L autre pourra recuperer plus tard, meme si tu n es plus la."
        Write-Host ("Lien (secours) : " + $up.page)
    } finally {
        try { Remove-Item -LiteralPath $pack.FullName -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Invoke-Receive {
    $cfg = Get-Cfg
    Write-Info "Recherche de la derniere version envoyee..."
    $man = Get-Manifest $cfg
    Write-Ok ("Trouvé : " + $man.sentAt)
    $zip = Join-Path $env:TEMP ("serveur-recv-" + [guid]::NewGuid().ToString("N") + ".zip")
    $curl = Get-Curl
    Write-Info "Telechargement du pack..."
    & $curl -L --fail -A "Mozilla/5.0" -o $zip $man.url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zip)) { throw "Telechargement echoue." }

    $extract = Join-Path $env:TEMP ("serveur-recv-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $extract | Out-Null
    Write-Info "Extraction..."
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

    $folders = Get-PackFolders $cfg
    $byName = @{}
    foreach ($f in $folders) { $byName[$f.Name] = $f }

    Get-ChildItem -LiteralPath $extract -Directory | ForEach-Object {
        $name = $_.Name
        if ($byName.ContainsKey($name)) {
            $dest = $byName[$name].Full
            Write-Info ("Mise a jour : " + $byName[$name].Rel)
            if (-not (Test-Path -LiteralPath $dest)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }
            Copy-Item -Path (Join-Path $_.FullName '*') -Destination $dest -Recurse -Force
        } else {
            Write-Warn ("Dossier ignore (pas dans config) : " + $name)
        }
    }

    try { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    Write-Host ""
    Write-Ok "Serveur recupere. Tu peux fermer."
}

function Show-Menu {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Magenta
    Write-Host "  SYNC COLLAB" -ForegroundColor Magenta
    Write-Host "=============================================="
    Write-Host ""
    Write-Host "  1) RECUPERER le serveur"
    Write-Host "     Telecharge la derniere version envoyee"
    Write-Host "     (l autre n a pas besoin d etre connecte)"
    Write-Host ""
    Write-Host "  2) ENVOYER une nouvelle version"
    Write-Host "     Upload le pack, puis tu PEUX FERMER"
    Write-Host ""
    Write-Host "  0) Quitter"
    Write-Host ""
    return (Read-Host "Choix")
}

Remove-NestedClone

try {
    $needRelaunch = $false
    try { $needRelaunch = Invoke-GithubUpdate } catch {
        Write-Warn ("Maj GitHub ignoree : " + $_.Exception.Message)
    }
    if ($needRelaunch) {
        $env:SYNC_COLLAB_UPDATED = "1"
        Start-Process -FilePath (Join-Path $Root "sync.bat")
        exit 0
    }

    $c = Show-Menu
    if ($c -eq "1") {
        Invoke-Receive
    } elseif ($c -eq "2") {
        Invoke-Send
    } elseif ($c -eq "0") {
        exit 0
    } else {
        Write-Warn "Choix invalide."
    }
} catch {
    Write-ErrMsg $_.Exception.Message
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
}

Write-Host ""
Read-Host "Entree pour fermer" | Out-Null
