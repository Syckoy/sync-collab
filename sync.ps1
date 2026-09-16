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

function Convert-VerNum([string]$v) {
    if (-not $v) { return 0 }
    $parts = @($v.Split("."))
    $n = 0
    if ($parts.Count -gt 0) { $n += ([int]$parts[0]) * 10000 }
    if ($parts.Count -gt 1) { $n += ([int]$parts[1]) * 100 }
    if ($parts.Count -gt 2) { $n += [int]$parts[2] }
    return $n
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

    $localVer = "0"
    if ($version -and $version.version) { $localVer = [string]$version.version }
    try {
        $remoteVerObj = Invoke-RestMethod -Uri ("https://raw.githubusercontent.com/{0}/{1}/version.json" -f $repo, $branch) -Headers $headers -TimeoutSec 15
        if ($remoteVerObj -and $remoteVerObj.version) {
            $remoteVerEarly = [string]$remoteVerObj.version
            if ((Convert-VerNum $localVer) -gt (Convert-VerNum $remoteVerEarly)) {
                Write-Warn ("GitHub est en retard (local " + $localVer + " / GitHub " + $remoteVerEarly + "). Upload le dossier sync a la racine du repo.")
                return $false
            }
        }
    } catch { }

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

    $localVer = "0"
    $remoteVer = "0"
    if ($version -and $version.version) { $localVer = [string]$version.version }
    $remoteVerFile = Join-Path $srcDir "version.json"
    if (Test-Path -LiteralPath $remoteVerFile) {
        $rv = Read-JsonFile $remoteVerFile
        if ($rv -and $rv.version) { $remoteVer = [string]$rv.version }
    }
    if ((Convert-VerNum $localVer) -gt (Convert-VerNum $remoteVer)) {
        Write-Warn ("GitHub est en retard (local " + $localVer + " / GitHub " + $remoteVer + "). Upload les fichiers du dossier sync a la racine du repo.")
        try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        return $false
    }

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

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-GmodSkip {
    return @(
        "bin", "cache", "download", "downloadlists", "fallbacks", "html", "maps",
        "particles", "resource", "scenes", "backgrounds", "lua", "data"
    )
}

function Get-DsSkip {
    return @(
        "garrysmod", "bin", "platform", "sourceengine", "steam_cache", "logs",
        "package", "userdata", "appcache", "depotcache", "config", "steamapps", "sync"
    )
}

function Test-SkipPackFile([string]$name) {
    if ($name -match "sync-conflict") { return $true }
    if ($name -eq "desktop.ini" -or $name -eq "Thumbs.db") { return $true }
    if ($name -like "*.rar" -or $name -like "*.zip") { return $true }
    return $false
}

function Find-GmodDir($cfg) {
    $root = Get-SyncRoot $cfg
    $rel = "steamapps/common/GarrysModDS/garrysmod"
    if ($cfg.gmodRel) { $rel = [string]$cfg.gmodRel }
    $full = Join-Path $root ($rel -replace "/", "\")
    if (Test-Path -LiteralPath (Join-Path $full "addons")) {
        return Get-Item -LiteralPath $full
    }
    $common = Join-Path $root "steamapps\common"
    if (Test-Path -LiteralPath $common) {
        foreach ($d in Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue) {
            $g = Join-Path $d.FullName "garrysmod"
            if (Test-Path -LiteralPath (Join-Path $g "addons")) {
                return Get-Item -LiteralPath $g
            }
        }
    }
    $direct = Join-Path $root "garrysmod"
    if (Test-Path -LiteralPath (Join-Path $direct "addons")) {
        return Get-Item -LiteralPath $direct
    }
    throw "Dossier garrysmod introuvable (addons manquant)."
}

function Get-RelUnix([string]$base, [string]$full) {
    $b = $base.TrimEnd("\", "/")
    $f = $full
    if ($f.Length -lt $b.Length) { return $null }
    $prefix = $f.Substring(0, $b.Length)
    if ($prefix -ne $b -and $prefix.ToLowerInvariant() -ne $b.ToLowerInvariant()) { return $null }
    $rest = $f.Substring($b.Length).TrimStart("\", "/")
    return ($rest -replace "\\", "/")
}

function Get-RootSkip {
    return @(
        "steamapps", "sync", "bin", "appcache", "config", "depotcache", "logs",
        "package", "public", "siteserverui", "userdata", "garrysmod", "platform",
        "sourceengine", "steam_cache"
    )
}

function Get-PackTargets($cfg) {
    $gmod = Find-GmodDir $cfg
    $ds = $gmod.Directory.FullName
    $syncRoot = Get-SyncRoot $cfg
    $gmodSkip = Get-GmodSkip
    $dsSkip = Get-DsSkip
    $rootSkip = Get-RootSkip
    $targets = @()
    $seen = @{}
    foreach ($d in Get-ChildItem -LiteralPath $gmod.FullName -Directory -ErrorAction SilentlyContinue) {
        if ($gmodSkip -contains $d.Name.ToLowerInvariant()) { continue }
        $targets += [pscustomobject]@{
            Scope = "gmod"
            Name  = $d.Name
            Full  = $d.FullName
        }
        $seen[$d.FullName.ToLowerInvariant()] = $true
        Write-Info ("Inclus : garrysmod/" + $d.Name)
    }
    foreach ($d in Get-ChildItem -LiteralPath $ds -Directory -ErrorAction SilentlyContinue) {
        $key = $d.Name.ToLowerInvariant()
        if ($dsSkip -contains $key) { continue }
        if ($key -like "sync-collab*") { continue }
        $targets += [pscustomobject]@{
            Scope = "ds"
            Name  = $d.Name
            Full  = $d.FullName
        }
        $seen[$d.FullName.ToLowerInvariant()] = $true
        Write-Info ("Inclus (a cote de garrysmod) : " + $d.Name)
    }
    if ($syncRoot.ToLowerInvariant() -ne $ds.ToLowerInvariant()) {
        foreach ($d in Get-ChildItem -LiteralPath $syncRoot -Directory -ErrorAction SilentlyContinue) {
            $key = $d.Name.ToLowerInvariant()
            if ($rootSkip -contains $key) { continue }
            if ($key -like "sync-collab*" -or $key -like "steam*") { continue }
            if ($seen.ContainsKey($d.FullName.ToLowerInvariant())) { continue }
            $targets += [pscustomobject]@{
                Scope = "root"
                Name  = $d.Name
                Full  = $d.FullName
            }
            Write-Info ("Inclus (racine serveur) : " + $d.Name)
        }
    }
    if ($targets.Count -eq 0) { throw "Rien a empaqueter dans garrysmod." }
    return [pscustomobject]@{ Gmod = $gmod; Ds = $ds; Targets = $targets }
}

function New-Utf8Zip([string]$zipPath, [string]$mode) {
    if ($mode -eq "Create" -and (Test-Path -LiteralPath $zipPath)) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    $enc = New-Object System.Text.UTF8Encoding $false
    if ($mode -eq "Create") {
        $fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create)
        return New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false, $enc)
    }
    $fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    return New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read, $false, $enc)
}

function New-ServerPack($cfg) {
    $pack = Get-PackTargets $cfg
    $zipPath = Join-Path $env:TEMP ("serveur-pack-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".zip")
    Write-Info "Compression du pack (chemins + dates conserves)..."
    $zip = New-Utf8Zip $zipPath "Create"
    $files = New-Object System.Collections.Generic.List[object]
    $dirs = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($t in $pack.Targets) {
            $dirs.Add(@{ scope = $t.Scope; name = $t.Name; rel = $t.Name })
            Get-ChildItem -LiteralPath $t.Full -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $rel = Get-RelUnix $t.Full $_.FullName
                if ($rel) {
                    $dirs.Add(@{ scope = $t.Scope; name = $t.Name; rel = ($t.Name + "/" + $rel) })
                }
            }
            Get-ChildItem -LiteralPath $t.Full -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                if (Test-SkipPackFile $_.Name) { return }
                $rel = Get-RelUnix $t.Full $_.FullName
                if (-not $rel) { return }
                $entryRel = ($t.Name + "/" + $rel)
                $entryName = "content/" + $t.Scope + "/" + $entryRel
                try {
                    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $zip, $_.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Fastest
                    )
                } catch {
                    Write-Warn ("Ignore (fichier bloque) : " + $entryRel)
                    return
                }
                $files.Add(@{
                    scope    = $t.Scope
                    name     = $t.Name
                    rel      = $entryRel
                    size     = [int64]$_.Length
                    mtimeUtc = $_.LastWriteTimeUtc.ToString("o")
                })
            }
        }
        $indexObj = @{
            format = "sync-collab-v2"
            sentAt = (Get-Date).ToUniversalTime().ToString("o")
            files  = @($files.ToArray())
            dirs   = @($dirs.ToArray())
        }
        $json = $indexObj | ConvertTo-Json -Depth 6 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $entry = $zip.CreateEntry("index.json")
        $es = $entry.Open()
        try { $es.Write($bytes, 0, $bytes.Length) } finally { $es.Close() }
    } finally {
        $zip.Dispose()
    }
    $item = Get-Item -LiteralPath $zipPath
    Write-Ok ("Pack pret : {0:N1} Mo, {1} fichiers" -f ($item.Length / 1MB), $files.Count)
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

    Write-Info "Tentative catbox..."
    $raw = & $curl -sS -A "sync-collab" -F "reqtype=fileupload" -F "fileToUpload=@$zipPath" "https://catbox.moe/user/api.php"
    if ($raw -and $raw -match "^https?://\S+$") {
        $u = $raw.Trim()
        Write-Ok "Pack envoye."
        return [pscustomobject]@{ id = $u; url = $u; page = $u }
    }
    Write-Warn ("catbox : " + (Get-ShortErr $raw))

    Write-Info "Tentative bashupload..."
    $raw = & $curl -sS -A "sync-collab" -T $zipPath "https://bashupload.com/serveur-pack.zip"
    if ($raw -and $raw -match "https?://\S+") {
        $u = ([regex]::Match($raw, "https?://\S+")).Value.Trim().TrimEnd(".")
        Write-Ok "Pack envoye."
        return [pscustomobject]@{ id = $u; url = $u; page = $u }
    }
    Write-Warn ("bashupload : " + (Get-ShortErr $raw))

    Write-Info "Tentative file.io..."
    $raw = & $curl -sS -A "sync-collab" -F $fileForm "https://file.io/?expires=2d"
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

function Test-DirectPackUrl([string]$url) {
    if (-not $url) { return $false }
    if ($url -match "(?i)gofile\.io") { return $false }
    return $true
}

function Test-ZipFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $fs = [System.IO.File]::OpenRead($path)
    try {
        if ($fs.Length -lt 4) { return $false }
        $b0 = $fs.ReadByte()
        $b1 = $fs.ReadByte()
        return ($b0 -eq 0x50 -and $b1 -eq 0x4B)
    } finally { $fs.Close() }
}

function Get-Manifest($cfg) {
    $channel = [string]$cfg.dropChannel
    if (-not $channel) { $channel = "syckoy-gmod-sync-collab" }
    $curl = Get-Curl
    $uri = "https://ntfy.sh/" + $channel + "/json?poll=1"
    $raw = & $curl -sS -A "sync-collab" $uri
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw "Aucune version envoyee pour le moment." }
    $lines = $raw -split "`n" | Where-Object { $_.Trim() -ne "" }
    $last = $null
    $sawGofile = $false
    foreach ($line in $lines) {
        try {
            $ev = $line | ConvertFrom-Json
            if ($ev.message) {
                $msg = [string]$ev.message
                if ($msg.Trim().StartsWith("{")) {
                    $man = $msg | ConvertFrom-Json
                    if ($man.url) {
                        if (Test-DirectPackUrl ([string]$man.url)) {
                            $last = $man
                        } else {
                            $sawGofile = $true
                        }
                    }
                }
            }
        } catch { }
    }
    if ($last) { return $last }
    if ($sawGofile) {
        throw "L envoi de ton ami est encore sur Gofile (page web, pas un vrai fichier). Demande-lui de relancer sync.bat, accepter la maj, puis ENVOYER (2)."
    }
    throw "Manifest invalide. L autre doit renvoyer une version."
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

function Get-ScopeBase($cfg, $gmod, [string]$scope) {
    if ($scope -eq "ds") { return $gmod.Directory.FullName }
    if ($scope -eq "root") { return Get-SyncRoot $cfg }
    return $gmod.FullName
}

function Expand-Utf8Zip([string]$zipPath, [string]$dest) {
    if (-not (Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Path $dest | Out-Null
    }
    $zip = New-Utf8Zip $zipPath "Read"
    try {
        foreach ($e in $zip.Entries) {
            $name = [string]$e.FullName
            if (-not $name -or $name.EndsWith("/") -or $name.EndsWith("\")) { continue }
            $target = Join-Path $dest ($name -replace "/", "\")
            $dir = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally {
        $zip.Dispose()
    }
}

function Read-PackIndex([string]$extract) {
    $p = Join-Path $extract "index.json"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Invoke-MirrorPack($cfg, $gmod, $index, [string]$extract) {
    $added = 0
    $updated = 0
    $kept = 0
    $removed = 0
    $content = Join-Path $extract "content"
    $remoteFiles = @{}
    $packedRoots = @{}

    foreach ($d in @($index.dirs)) {
        $base = Get-ScopeBase $cfg $gmod ([string]$d.scope)
        $rel = [string]$d.rel
        if (-not $rel) { continue }
        $dest = Join-Path $base ($rel -replace "/", "\")
        if (-not (Test-Path -LiteralPath $dest)) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
        }
    }

    foreach ($f in @($index.files)) {
        $key = ([string]$f.scope) + "|" + ([string]$f.rel)
        $remoteFiles[$key] = $f
        $rootKey = ([string]$f.scope) + "|" + ([string]$f.name)
        $packedRoots[$rootKey] = $true
        $base = Get-ScopeBase $cfg $gmod ([string]$f.scope)
        $dest = Join-Path $base (($f.rel -replace "/", "\"))
        $src = Join-Path $content ((([string]$f.scope) + "\" + ($f.rel -replace "/", "\")))
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Warn ("Fichier absent du zip : " + $f.rel)
            continue
        }
        $remoteM = [datetime]::Parse([string]$f.mtimeUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if (-not (Test-Path -LiteralPath $dest)) {
            $dir = Split-Path $dest -Parent
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            [System.IO.File]::Copy($src, $dest, $true)
            [System.IO.File]::SetLastWriteTimeUtc($dest, $remoteM)
            $added++
            continue
        }
        $localM = (Get-Item -LiteralPath $dest).LastWriteTimeUtc
        if ($remoteM -ge $localM) {
            [System.IO.File]::Copy($src, $dest, $true)
            [System.IO.File]::SetLastWriteTimeUtc($dest, $remoteM)
            $updated++
        } else {
            $kept++
        }
    }

    foreach ($rootKey in $packedRoots.Keys) {
        $parts = $rootKey.Split("|", 2)
        $scope = $parts[0]
        $name = $parts[1]
        $base = Join-Path (Get-ScopeBase $cfg $gmod $scope) $name
        if (-not (Test-Path -LiteralPath $base)) { continue }
        Get-ChildItem -LiteralPath $base -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-SkipPackFile $_.Name) { return }
            $rel = Get-RelUnix $base $_.FullName
            if (-not $rel) { return }
            $key = $scope + "|" + $name + "/" + $rel
            if (-not $remoteFiles.ContainsKey($key)) {
                Remove-Item -LiteralPath $_.FullName -Force
                $removed++
            }
        }
        Get-ChildItem -LiteralPath $base -Directory -Recurse -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                $has = Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                if (-not $has) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
    }

    Write-Host ""
    Write-Ok ("Ajoutes : " + $added)
    Write-Ok ("Mis a jour (plus recents chez l autre) : " + $updated)
    if ($kept -gt 0) { Write-Warn ("Gardes chez toi (plus recents) : " + $kept) }
    Write-Ok ("Supprimes (enleves chez l autre) : " + $removed)
}

function Invoke-LegacyReceive($gmod, [string]$extract) {
    Write-Warn "Ancien pack (sans index). Copie brute addons/cfg/gamemodes."
    $map = @{
        "addons"  = (Join-Path $gmod.FullName "addons")
        "cfg"     = (Join-Path $gmod.FullName "cfg")
        "mangarp" = (Join-Path $gmod.FullName "gamemodes\mangarp")
    }
    Get-ChildItem -LiteralPath $extract -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        if ($map.ContainsKey($name)) {
            $dest = $map[$name]
            if (-not (Test-Path -LiteralPath $dest)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }
            Write-Info ("Mise a jour : " + $name)
            Copy-Item -Path (Join-Path $_.FullName '*') -Destination $dest -Recurse -Force
        } else {
            $dest = Join-Path $gmod.FullName $name
            Write-Info ("Dossier extra : " + $name)
            if (-not (Test-Path -LiteralPath $dest)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }
            Copy-Item -Path (Join-Path $_.FullName '*') -Destination $dest -Recurse -Force
        }
    }
}

function Invoke-Receive {
    $cfg = Get-Cfg
    Write-Info "Recherche de la derniere version envoyee..."
    $man = Get-Manifest $cfg
    Write-Ok ("Trouve : " + $man.sentAt)
    $zip = Join-Path $env:TEMP ("serveur-recv-" + [guid]::NewGuid().ToString("N") + ".zip")
    $curl = Get-Curl
    Write-Info "Telechargement du pack..."
    & $curl -L --fail -A "Mozilla/5.0" -o $zip $man.url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zip)) { throw "Telechargement echoue." }
    if (-not (Test-ZipFile $zip)) {
        throw "Le fichier telecharge n est pas un zip. Demande a ton ami de renvoyer avec la nouvelle version (bouton 2)."
    }

    $extract = Join-Path $env:TEMP ("serveur-recv-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $extract | Out-Null
    Write-Info "Extraction..."
    Expand-Utf8Zip $zip $extract

    $gmod = Find-GmodDir $cfg
    $index = Read-PackIndex $extract
    if ($index -and $index.format -eq "sync-collab-v2") {
        Write-Info "Comparaison ancienne version / pack recu..."
        Invoke-MirrorPack $cfg $gmod $index $extract
    } else {
        Invoke-LegacyReceive $gmod $extract
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
