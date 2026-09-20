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
    # RIEN : on empaquete tout garrysmod (addons, data, lua, maps, cfg, etc.)
    return @()
}

function Get-DsSkip {
    # garrysmod = deja pris via Get-GmodSkip/targets ; sync = outil ; steamapps = hors perimetre
    return @(
        "garrysmod", "steamapps", "sync",
        ".git", ".vs", ".idea", ".svn", "node_modules"
    )
}

function Get-RootSkip {
    return @(
        "steamapps", "sync", ".git", ".vs", ".idea"
    )
}

function Test-SkipPackFile([string]$name) {
    if ($name -match "sync-conflict") { return $true }
    if ($name -eq "desktop.ini" -or $name -eq "Thumbs.db") { return $true }
    return $false
}

function Test-SkipLooseRootFile([string]$name) {
    # Tous les fichiers racine (bat, exe, dll, txt...) sauf poubelle Windows
    return (Test-SkipPackFile $name)
}

function Test-SkipPackDirName([string]$name) {
    if (-not $name) { return $true }
    $n = $name.ToLowerInvariant()
    # Uniquement meta / outil - PAS les dossiers de contenu du jeu
    $skip = @(".git", ".vs", ".idea", ".svn", "node_modules", "sync-collab-main", "sync-collab", "sync")
    if ($skip -contains $n) { return $true }
    if ($n -like "sync-collab*") { return $true }
    return $false
}

function Test-SkipPackRel([string]$rel) {
    if (-not $rel) { return $true }
    $n = ($rel -replace "\\", "/").Trim("/")
    if ($n -match "(^|/)(\.git|\.vs|\.idea|\.svn|node_modules|sync-collab)(/|$)") { return $true }
    $parts = $n -split "/"
    foreach ($p in $parts) {
        if (Test-SkipPackDirName $p) { return $true }
    }
    return $false
}

function Get-GmodParent($gmod) {
    if ($gmod.Parent -and $gmod.Parent.FullName) { return $gmod.Parent.FullName }
    return [System.IO.Path]::GetDirectoryName($gmod.FullName)
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
    foreach ($d in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
        $g = Join-Path $d.FullName "garrysmod"
        if (Test-Path -LiteralPath (Join-Path $g "addons")) {
            return Get-Item -LiteralPath $g
        }
        $addonsDirect = Join-Path $d.FullName "addons"
        if ((Test-Path -LiteralPath $addonsDirect) -and (Test-Path -LiteralPath (Join-Path $d.FullName "cfg"))) {
            return Get-Item -LiteralPath $d.FullName
        }
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

function Get-PackTargets($cfg, [switch]$Quiet) {
    $gmod = Find-GmodDir $cfg
    $ds = Get-GmodParent $gmod
    $syncRoot = Get-SyncRoot $cfg
    $gmodSkip = Get-GmodSkip
    $dsSkip = Get-DsSkip
    $rootSkip = Get-RootSkip
    $targets = @()
    $seen = @{}
    foreach ($d in Get-ChildItem -LiteralPath $gmod.FullName -Directory -ErrorAction SilentlyContinue) {
        if ($gmodSkip -contains $d.Name.ToLowerInvariant()) { continue }
        if (Test-SkipPackDirName $d.Name) { continue }
        $targets += [pscustomobject]@{
            Scope = "gmod"
            Name  = $d.Name
            Full  = $d.FullName
        }
        $seen[$d.FullName.ToLowerInvariant()] = $true
        if (-not $Quiet) { Write-Info ("Inclus : garrysmod/" + $d.Name) }
    }
    if ($ds) {
        foreach ($d in Get-ChildItem -LiteralPath $ds -Directory -ErrorAction SilentlyContinue) {
            $key = $d.Name.ToLowerInvariant()
            if ($dsSkip -contains $key) { continue }
            if (Test-SkipPackDirName $d.Name) { continue }
            if ($key -like "sync-collab*") { continue }
            $targets += [pscustomobject]@{
                Scope = "ds"
                Name  = $d.Name
                Full  = $d.FullName
            }
            $seen[$d.FullName.ToLowerInvariant()] = $true
            if (-not $Quiet) { Write-Info ("Inclus (a cote de garrysmod) : " + $d.Name) }
        }
    }
    $dsNorm = ""
    if ($ds) { $dsNorm = $ds.ToLowerInvariant() }
    if ($syncRoot.ToLowerInvariant() -ne $dsNorm) {
        foreach ($d in Get-ChildItem -LiteralPath $syncRoot -Directory -ErrorAction SilentlyContinue) {
            $key = $d.Name.ToLowerInvariant()
            if ($rootSkip -contains $key) { continue }
            if (Test-SkipPackDirName $d.Name) { continue }
            if ($key -like "sync-collab*" -or $key -like "steam*") { continue }
            if ($seen.ContainsKey($d.FullName.ToLowerInvariant())) { continue }
            $targets += [pscustomobject]@{
                Scope = "root"
                Name  = $d.Name
                Full  = $d.FullName
            }
            if (-not $Quiet) { Write-Info ("Inclus (racine serveur) : " + $d.Name) }
        }
    }
    if ($targets.Count -eq 0) { throw "Rien a empaqueter dans garrysmod." }

    # Fichiers a la racine garrysmod / a cote (start.bat, configs) - avant ils etaient ignores
    $loose = @()
    foreach ($f in Get-ChildItem -LiteralPath $gmod.FullName -File -ErrorAction SilentlyContinue) {
        if (Test-SkipLooseRootFile $f.Name) { continue }
        $loose += [pscustomobject]@{ Scope = "gmod"; Name = $f.Name; Full = $f.FullName; IsLoose = $true }
        if (-not $Quiet) { Write-Info ("Inclus (fichier garrysmod/) : " + $f.Name) }
    }
    if ($ds) {
        foreach ($f in Get-ChildItem -LiteralPath $ds -File -ErrorAction SilentlyContinue) {
            if (Test-SkipLooseRootFile $f.Name) { continue }
            $loose += [pscustomobject]@{ Scope = "ds"; Name = $f.Name; Full = $f.FullName; IsLoose = $true }
            if (-not $Quiet) { Write-Info ("Inclus (fichier a cote) : " + $f.Name) }
        }
    }

    return [pscustomobject]@{ Gmod = $gmod; Ds = $ds; Targets = $targets; LooseFiles = $loose }
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

function Get-ZipLevelForFile([string]$name) {
    # Deja compresses / binaires : STORE (beaucoup plus rapide)
    if ($name -match '(?i)\.(vpk|zip|rar|7z|gz|bz2|xz|png|jpg|jpeg|webp|gif|mp3|wav|ogg|mp4|webm|avi|dll|exe|pdb|dem|bsp|ttf|otf|woff|woff2)$') {
        return [System.IO.Compression.CompressionLevel]::NoCompression
    }
    return [System.IO.Compression.CompressionLevel]::Fastest
}

function Write-PackProgress([int]$done, [int]$total, [string]$current, [datetime]$started, [int64]$bytesDone) {
    if ($total -le 0) { return }
    $pct = [math]::Round(100.0 * $done / $total, 1)
    $elapsed = (Get-Date) - $started
    $eta = ""
    if ($done -gt 0 -and $elapsed.TotalSeconds -gt 0.5) {
        $remainSec = $elapsed.TotalSeconds * ($total - $done) / $done
        if ($remainSec -lt 60) { $eta = (" ~{0:N0}s restantes" -f $remainSec) }
        else { $eta = (" ~{0:N0} min restantes" -f ($remainSec / 60)) }
    }
    $mb = [math]::Round($bytesDone / 1MB, 1)
    $short = $current
    if ($short.Length -gt 55) { $short = "..." + $short.Substring($short.Length - 52) }
    $line = ("  [{0}/{1}] {2}% | {3} Mo |{4} | {5}" -f $done, $total, $pct, $mb, $eta, $short)
    Write-Host ("`r" + $line.PadRight(110)) -NoNewline
    try {
        Write-Progress -Activity "Compression du pack serveur" -Status $line.Trim() -PercentComplete ([math]::Min(99, [int]$pct))
    } catch { }
}

function New-ServerPack($cfg) {
    Write-Info "1/3 Scan des fichiers (patience, c est normal)..."
    $pack = Get-PackTargets $cfg -Quiet
    Write-Ok ("Dossiers inclus : " + $pack.Targets.Count)

    $toPack = New-Object System.Collections.Generic.List[object]
    $dirs = New-Object System.Collections.Generic.List[object]
    $scanStart = Get-Date

    foreach ($t in $pack.Targets) {
        $dirs.Add(@{ scope = $t.Scope; name = $t.Name; rel = $t.Name })
        Get-ChildItem -LiteralPath $t.Full -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = Get-RelUnix $t.Full $_.FullName
            if (-not $rel) { return }
            if (Test-SkipPackRel ($t.Name + "/" + $rel)) { return }
            $dirs.Add(@{ scope = $t.Scope; name = $t.Name; rel = ($t.Name + "/" + $rel) })
        }
        Get-ChildItem -LiteralPath $t.Full -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-SkipPackFile $_.Name) { return }
            $rel = Get-RelUnix $t.Full $_.FullName
            if (-not $rel) { return }
            $entryRel = ($t.Name + "/" + $rel)
            if (Test-SkipPackRel $entryRel) { return }
            $toPack.Add([pscustomobject]@{
                Scope     = $t.Scope
                Name      = $t.Name
                Rel       = $entryRel
                Full      = $_.FullName
                Size      = [int64]$_.Length
                MtimeUtc  = $_.LastWriteTimeUtc
                EntryName = ("content/" + $t.Scope + "/" + $entryRel)
            })
        }
        $n = $toPack.Count
        Write-Host ("`r  Scan... {0} fichiers trouves | dossier : {1}   " -f $n, $t.Name) -NoNewline
    }
    Write-Host ""

    foreach ($lf in @($pack.LooseFiles)) {
        $toPack.Add([pscustomobject]@{
            Scope     = $lf.Scope
            Name      = $lf.Name
            Rel       = $lf.Name
            Full      = $lf.Full
            Size      = [int64](Get-Item -LiteralPath $lf.Full).Length
            MtimeUtc  = (Get-Item -LiteralPath $lf.Full).LastWriteTimeUtc
            EntryName = ("content/" + $lf.Scope + "/" + $lf.Name)
            Loose     = $true
        })
    }

    $total = $toPack.Count
    $totalMb = [math]::Round((($toPack | Measure-Object -Property Size -Sum).Sum / 1MB), 1)
    Write-Ok ("Scan OK : {0} fichiers ({1} Mo) en {2:N0}s" -f $total, $totalMb, ((Get-Date) - $scanStart).TotalSeconds)
    if ($total -eq 0) { throw "Aucun fichier a empaqueter." }

    $zipPath = Join-Path $env:TEMP ("serveur-pack-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".zip")
    Write-Info "2/3 Compression (tu vois la progression ci-dessous)..."
    Write-Host "  Astuce : les gros fichiers (vpk/maps) sont copies sans recompresser = plus rapide." -ForegroundColor DarkGray

    $zip = New-Utf8Zip $zipPath "Create"
    $files = New-Object System.Collections.Generic.List[object]
    $done = 0
    $bytesDone = [int64]0
    $compStart = Get-Date
    $skipped = 0
    try {
        foreach ($item in $toPack) {
            $done++
            $bytesDone += $item.Size
            if (($done % 3 -eq 0) -or $done -eq 1 -or $done -eq $total -or $item.Size -gt 5MB) {
                Write-PackProgress $done $total $item.Rel $compStart $bytesDone
            }
            try {
                $level = Get-ZipLevelForFile ([System.IO.Path]::GetFileName($item.Full))
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, $item.Full, $item.EntryName, $level
                )
            } catch {
                $skipped++
                Write-Host ""
                Write-Warn ("Ignore (bloque) : " + $item.Rel)
                continue
            }
            $meta = @{
                scope    = $item.Scope
                name     = $item.Name
                rel      = $item.Rel
                size     = $item.Size
                mtimeUtc = $item.MtimeUtc.ToString("o")
            }
            if ($item.Loose) { $meta.loose = $true }
            $files.Add($meta)
        }
        Write-Host ""
        try { Write-Progress -Activity "Compression du pack serveur" -Completed } catch { }

        Write-Info "3/3 Index + finalisation..."
        $targetsMeta = @()
        $treeLines = New-Object System.Collections.Generic.List[string]
        $treeLines.Add("Arbre du serveur (cote envoi)")
        $treeLines.Add(("Date UTC : " + (Get-Date).ToUniversalTime().ToString("o")))
        $treeLines.Add("")
        foreach ($t in $pack.Targets) {
            $targetsMeta += @{ scope = $t.Scope; name = $t.Name }
            $treeLines.Add(("[" + $t.Scope + "] " + $t.Name + "/"))
        }
        foreach ($d in $dirs) {
            $treeLines.Add(("[" + $d.scope + "] " + $d.rel + "/"))
        }
        $indexObj = @{
            format   = "sync-collab-v2"
            sentAt   = (Get-Date).ToUniversalTime().ToString("o")
            files    = @($files.ToArray())
            dirs     = @($dirs.ToArray())
            targets  = @($targetsMeta)
        }
        $json = $indexObj | ConvertTo-Json -Depth 6 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $entry = $zip.CreateEntry("index.json")
        $es = $entry.Open()
        try { $es.Write($bytes, 0, $bytes.Length) } finally { $es.Close() }
        $treeBytes = [System.Text.Encoding]::UTF8.GetBytes(($treeLines -join "`r`n"))
        $treeEntry = $zip.CreateEntry("arbre-serveur.txt")
        $ts = $treeEntry.Open()
        try { $ts.Write($treeBytes, 0, $treeBytes.Length) } finally { $ts.Close() }
    } finally {
        $zip.Dispose()
    }

    $item = Get-Item -LiteralPath $zipPath
    $sec = ((Get-Date) - $compStart).TotalSeconds
    Write-Ok ("Pack pret : {0:N1} Mo, {1} fichiers, {2:N0}s" -f ($item.Length / 1MB), $files.Count, $sec)
    if ($skipped -gt 0) { Write-Warn ("Fichiers ignores (bloques) : " + $skipped) }
    return $item
}

function Get-ShortErr([string]$s) {
    if (-not $s) { return "(vide)" }
    if ($s -match "uploads disabled") { return "hebergeur ferme (spam)" }
    if ($s -match "(?i)file (is )?too large|payload too large|413") { return "fichier trop gros pour cet hebergeur" }
    if ($s -match "(?i)internal server error|<html|<!doctype") { return "hebergeur down (erreur 500)" }
    $t = $s.Trim()
    if ($t.Length -gt 180) { return $t.Substring(0, 180) }
    return $t
}

function Get-FileSha256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($path)
    try {
        $hash = $sha.ComputeHash($fs)
        return ([System.BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    } finally {
        $fs.Close()
        $sha.Dispose()
    }
}

function Split-FileToParts([string]$path, [int64]$chunkBytes, [string]$outDir) {
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $parts = New-Object System.Collections.Generic.List[string]
    $fs = [System.IO.File]::OpenRead($path)
    try {
        $buf = New-Object byte[] ([Math]::Min($chunkBytes, 4MB))
        $index = 0
        $remainingInChunk = $chunkBytes
        $partPath = Join-Path $outDir ("part-{0:D4}.bin" -f $index)
        $out = [System.IO.File]::Create($partPath)
        try {
            while ($true) {
                $toRead = [Math]::Min($buf.Length, [int][Math]::Min($remainingInChunk, [int64][int]::MaxValue))
                if ($toRead -le 0) { break }
                $read = $fs.Read($buf, 0, $toRead)
                if ($read -le 0) { break }
                $out.Write($buf, 0, $read)
                $remainingInChunk -= $read
                if ($remainingInChunk -le 0) {
                    $out.Close()
                    $parts.Add($partPath)
                    $index++
                    $remainingInChunk = $chunkBytes
                    $partPath = Join-Path $outDir ("part-{0:D4}.bin" -f $index)
                    $out = [System.IO.File]::Create($partPath)
                }
            }
        } finally {
            if ($out) { $out.Close() }
        }
        # Derniere part non vide
        if ((Test-Path -LiteralPath $partPath) -and ((Get-Item -LiteralPath $partPath).Length -gt 0)) {
            if (-not $parts.Contains($partPath)) { $parts.Add($partPath) }
        } elseif (Test-Path -LiteralPath $partPath) {
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        }
    } finally {
        $fs.Close()
    }
    return ,$parts.ToArray()
}

function Merge-FileParts([string[]]$partPaths, [string]$outPath) {
    $out = [System.IO.File]::Create($outPath)
    try {
        $buf = New-Object byte[] (4MB)
        foreach ($p in $partPaths) {
            $fs = [System.IO.File]::OpenRead($p)
            try {
                while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                    $out.Write($buf, 0, $read)
                }
            } finally { $fs.Close() }
        }
    } finally { $out.Close() }
}

function Test-UploadUrl([string]$raw) {
    if (-not $raw) { return $null }
    $t = $raw.Trim()
    if ($t -match '(?i)<!doctype|<html|<svg|xmlns=') { return $null }

    $line = ($t -split "`r?`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1)
    if (-not $line) { return $null }
    $line = $line.Trim()

    if ($line -notmatch '^https?://') {
        $m = [regex]::Match($t, 'https?://[^\s\"''<>]+')
        if (-not $m.Success) { return $null }
        $line = $m.Value
    }

    $u = $line.TrimEnd(".", ",", ")", "]", "`"", "'")
    if ($u -notmatch '(?i)^https?://(litterbox\.catbox\.moe|files\.catbox\.moe|catbox\.moe|0x0\.st|file\.io|bashupload\.com|pixeldrain\.com)(/|$)') {
        return $null
    }
    if ($u -match '(?i)w3\.org|\.svg(\?|$)') { return $null }
    return $u
}

function Invoke-HostUpload([string]$name, [scriptblock]$attempt, [string]$okLabel = "") {
    for ($n = 1; $n -le 2; $n++) {
        if ($n -gt 1) {
            Write-Info ("Nouvelle tentative " + $name + " dans 3s...")
            Start-Sleep -Seconds 3
        } else {
            Write-Info ("Tentative " + $name + "...")
        }
        try {
            $raw = & $attempt
            $u = Test-UploadUrl ([string]$raw)
            if ($u) {
                if ($okLabel) { Write-Ok $okLabel } else { Write-Ok ("Pack envoye via " + $name + ".") }
                return [pscustomobject]@{ id = $u; url = $u; page = $u; host = $name }
            }
            try {
                $json = ([string]$raw) | ConvertFrom-Json
                if ($json.success -and $json.link) {
                    $u2 = Test-UploadUrl ([string]$json.link)
                    if ($u2) {
                        if ($okLabel) { Write-Ok $okLabel } else { Write-Ok ("Pack envoye via " + $name + ".") }
                        return [pscustomobject]@{ id = $u2; url = $u2; page = $u2; host = $name }
                    }
                }
            } catch { }
            Write-Warn ($name + " : " + (Get-ShortErr ([string]$raw)))
        } catch {
            Write-Warn ($name + " : " + (Get-ShortErr ([string]$_.Exception.Message)))
        }
    }
    return $null
}

function Send-OneFile([string]$filePath, [string]$okLabel = "") {
    $curl = Get-Curl
    $sizeMb = [math]::Round((Get-Item -LiteralPath $filePath).Length / 1MB, 1)

    $up = Invoke-HostUpload -name "litterbox" -okLabel $okLabel -attempt {
        & $curl -sS --connect-timeout 20 --max-time 900 -A "sync-collab" `
            -F "reqtype=fileupload" -F "time=72h" -F "fileToUpload=@$filePath" `
            "https://litterbox.catbox.moe/resources/internals/api.php"
    }
    if ($up) { return $up }

    $up = Invoke-HostUpload -name "0x0.st" -okLabel $okLabel -attempt {
        & $curl -sS --connect-timeout 20 --max-time 900 -A "sync-collab" `
            -F "file=@$filePath" "https://0x0.st"
    }
    if ($up) { return $up }

    if ($sizeMb -le 190) {
        $up = Invoke-HostUpload -name "catbox" -okLabel $okLabel -attempt {
            & $curl -sS --connect-timeout 20 --max-time 900 -A "sync-collab" `
                -F "reqtype=fileupload" -F "fileToUpload=@$filePath" `
                "https://catbox.moe/user/api.php"
        }
        if ($up) { return $up }
    }

    $up = Invoke-HostUpload -name "bashupload" -okLabel $okLabel -attempt {
        & $curl -sS --connect-timeout 20 --max-time 900 -A "sync-collab" `
            -T $filePath "https://bashupload.com/serveur-part.bin"
    }
    if ($up) { return $up }

    $up = Invoke-HostUpload -name "file.io" -okLabel $okLabel -attempt {
        & $curl -sS --connect-timeout 20 --max-time 900 -A "sync-collab" `
            -F "file=@$filePath" "https://file.io/?expires=2d"
    }
    if ($up) { return $up }

    $up = Invoke-HostUpload -name "pixeldrain" -okLabel $okLabel -attempt {
        $raw = & $curl -sS --connect-timeout 20 --max-time 900 -A "sync-collab" `
            -T $filePath "https://pixeldrain.com/api/file/"
        try {
            $j = ([string]$raw) | ConvertFrom-Json
            if ($j.id) { return ("https://pixeldrain.com/api/file/" + $j.id + "?download") }
        } catch { }
        return $raw
    }
    if ($up) { return $up }

    return $null
}

# Packs > ce seuil : decoupage automatique (anti-ban / limites hebergeurs)
$script:ChunkThresholdBytes = 40MB
$script:ChunkPartBytes = 40MB

function Send-PackFile([string]$zipPath) {
    $size = (Get-Item -LiteralPath $zipPath).Length
    $sizeMb = [math]::Round($size / 1MB, 1)
    Write-Info "Envoi du pack (tu pourras fermer ensuite)..."
    Write-Info ("Taille pack : " + $sizeMb + " Mo")

    # Petit pack : un seul fichier
    if ($size -le $script:ChunkThresholdBytes) {
        $up = Send-OneFile $zipPath
        if ($up) {
            return [pscustomobject]@{
                format    = "single"
                id        = $up.url
                url       = $up.url
                page      = $up.url
                host      = $up.host
                code      = $null
                indexUrl  = $null
                partCount = 1
                sha256    = (Get-FileSha256 $zipPath)
            }
        }
        Write-Warn "Upload mono echoue - bascule en multi-parts..."
    } else {
        Write-Info ("Pack volumineux -> envoi en plusieurs morceaux (~" + [math]::Round($script:ChunkPartBytes/1MB) + " Mo).")
    }

    return Send-PackFileChunked $zipPath
}

function Send-PackFileChunked([string]$zipPath) {
    $code = "MNC-" + ([guid]::NewGuid().ToString("N").Substring(0, 8).ToUpperInvariant())
    $work = Join-Path $env:TEMP ("sync-parts-" + $code)
    $partsMeta = New-Object System.Collections.Generic.List[object]
    try {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $work -Force | Out-Null

        Write-Info ("Code envoi : " + $code)
        Write-Info "Decoupage du zip..."
        $partFiles = Split-FileToParts $zipPath $script:ChunkPartBytes $work
        $total = $partFiles.Count
        Write-Info ("Morceaux : " + $total)

        $fullSha = Get-FileSha256 $zipPath
        $i = 0
        foreach ($pf in $partFiles) {
            $i++
            $label = ("Partie " + $i + "/" + $total + " (" + $code + ") envoyee.")
            Write-Info ("--- Upload partie " + $i + "/" + $total + " ---")
            $up = Send-OneFile $pf $label
            if (-not $up) {
                throw ("Echec upload partie " + $i + "/" + $total + ". Reessaie plus tard.")
            }
            $partsMeta.Add([pscustomobject]@{
                i      = ($i - 1)
                url    = $up.url
                host   = $up.host
                size   = (Get-Item -LiteralPath $pf).Length
                sha256 = (Get-FileSha256 $pf)
            })
            if ($i -lt $total) { Start-Sleep -Seconds 2 }
        }

        # Petit index JSON (1 seul lien dans ntfy) = toutes les URLs des parts
        $indexObj = [pscustomobject]@{
            format    = "sync-collab-parts-v1"
            code      = $code
            name      = "serveur-pack.zip"
            sizeBytes = (Get-Item -LiteralPath $zipPath).Length
            partCount = $total
            partSize  = [int64]$script:ChunkPartBytes
            sha256    = $fullSha
            parts     = $partsMeta
        }
        $indexPath = Join-Path $work ("index-" + $code + ".json")
        [System.IO.File]::WriteAllText(
            $indexPath,
            ($indexObj | ConvertTo-Json -Depth 6 -Compress),
            (New-Object System.Text.UTF8Encoding $false)
        )
        Write-Info "Upload de l index (plan des morceaux)..."
        $idxUp = Send-OneFile $indexPath ("Index " + $code + " envoye.")
        if (-not $idxUp) { throw "Echec upload de l index multi-parts." }

        Write-Ok ("Pack multi-parts pret : " + $total + " morceaux, code " + $code)
        return [pscustomobject]@{
            format    = "sync-collab-parts-v1"
            id        = $code
            url       = $idxUp.url
            page      = $idxUp.url
            host      = $idxUp.host
            code      = $code
            indexUrl  = $idxUp.url
            partCount = $total
            sha256    = $fullSha
            token     = $null
        }
    } finally {
        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Publish-Manifest($cfg, $up, $sizeBytes) {
    $channel = [string]$cfg.dropChannel
    if (-not $channel) { $channel = "syckoy-gmod-sync-collab" }
    $manifest = @{
        format    = $(if ($up.format) { $up.format } else { "single" })
        id        = $up.id
        url       = $up.url
        page      = $up.page
        token     = $up.token
        code      = $up.code
        indexUrl  = $up.indexUrl
        partCount = $up.partCount
        sha256    = $up.sha256
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
    if ($url -match "(?i)w3\.org|\.svg") { return $false }
    if ($url -notmatch '(?i)^https?://(litterbox\.catbox\.moe|files\.catbox\.moe|catbox\.moe|0x0\.st|file\.io|bashupload\.com|pixeldrain\.com)/') {
        return $false
    }
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

function Assert-PackZipReady([string]$zipPath) {
    if (-not (Test-ZipFile $zipPath)) {
        throw "Pack local invalide (pas un zip). Envoi annule."
    }
    $zip = $null
    try {
        $zip = New-Utf8Zip $zipPath "Read"
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        if ($names.Count -lt 2) { throw "Pack quasi vide. Envoi annule." }
        if ($names -notcontains "index.json") { throw "Pack sans index.json. Envoi annule." }
        $idxEntry = $zip.GetEntry("index.json")
        $sr = New-Object System.IO.StreamReader($idxEntry.Open())
        try { $raw = $sr.ReadToEnd() } finally { $sr.Close() }
        $idx = $raw | ConvertFrom-Json
        if (-not $idx.files -or @($idx.files).Count -lt 1) {
            throw "index.json sans fichiers. Envoi annule."
        }
        Write-Ok ("Controle pack OK : {0} fichiers indexes, {1} entrees zip." -f @($idx.files).Count, $names.Count)
        return $idx
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Test-UrlFetchable([string]$url) {
    if (-not (Test-DirectPackUrl $url)) { return $false }
    $curl = Get-Curl
    $tmp = Join-Path $env:TEMP ("sync-probe-" + [guid]::NewGuid().ToString("N") + ".bin")
    try {
        & $curl -sS -L --fail --connect-timeout 20 --max-time 120 -A "sync-collab" -r 0-2047 -o $tmp -- $url 2>$null
        if ($LASTEXITCODE -ne 0) {
            # certains hosts refusent Range : retente sans
            & $curl -sS -L --fail --connect-timeout 20 --max-time 120 -A "sync-collab" -o $tmp -- $url 2>$null
        }
        if ($LASTEXITCODE -ne 0) { return $false }
        return ((Test-Path -LiteralPath $tmp) -and ((Get-Item -LiteralPath $tmp).Length -gt 0))
    } catch {
        return $false
    } finally {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Backup-LocalBeforeReceive($cfg, $gmod) {
    $backupRoot = Join-Path $Root "backups"
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $dest = Join-Path $backupRoot ("pre-recv-" + $stamp)
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Write-Info "SECURITE : sauvegarde locale avant fusion..."
    Write-Info ("Dossier : " + $dest)

    $folders = @("addons", "cfg", "gamemodes", "data", "settings", "_paused_addons")
    $robo = Join-Path $env:SystemRoot "System32\robocopy.exe"
    foreach ($name in $folders) {
        $src = Join-Path $gmod.FullName $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        Write-Host ("  Backup " + $name + "...") -ForegroundColor DarkGray
        $target = Join-Path $dest $name
        if (Test-Path -LiteralPath $robo) {
            & $robo $src $target /E /R:1 /W:1 /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
            # robocopy codes 0-7 = success-ish
            if ($LASTEXITCODE -ge 8) {
                Write-Warn ("Backup partiel : " + $name)
            }
        } else {
            Copy-Item -LiteralPath $src -Destination $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $ds = Get-GmodParent $gmod
    foreach ($extra in @("start.bat", "steam_appid.txt")) {
        $p = Join-Path $ds $extra
        if (Test-Path -LiteralPath $p) {
            Copy-Item -LiteralPath $p -Destination (Join-Path $dest $extra) -Force -ErrorAction SilentlyContinue
        }
    }

    # Garde les 5 derniere backups max
    $olds = @(Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "pre-recv-*" } |
        Sort-Object Name -Descending)
    if ($olds.Count -gt 5) {
        $olds | Select-Object -Skip 5 | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    Write-Ok ("Backup OK (si probleme, restaure depuis : " + $dest + ")")
    return $dest
}

function Write-ReceiveLog([string]$msg) {
    try {
        $log = Join-Path $Root "receive-log.txt"
        $line = ("{0}  {1}" -f (Get-Date).ToString("o"), $msg)
        Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    } catch { }
}

function Get-NtfyChannel($cfg) {
    $channel = [string]$cfg.dropChannel
    if (-not $channel) { $channel = "syckoy-gmod-sync-collab" }
    return $channel
}

function Publish-DirectPresence($cfg, [string[]]$ips, [int]$port, [int64]$sizeBytes) {
    $channel = Get-NtfyChannel $cfg
    $payload = @{
        format    = "direct-presence"
        magic     = "DIRECTCOLLAB"
        name      = $env:COMPUTERNAME
        ips       = @($ips)
        port      = $port
        ports     = @($script:DirectPorts)
        sizeBytes = $sizeBytes
        sentAt    = (Get-Date).ToString("o")
        version   = [string](Read-JsonFile $VersionPath).version
    } | ConvertTo-Json -Compress
    $body = "DIRECTCOLLAB|" + $payload
    $uri = "https://ntfy.sh/" + $channel
    try {
        Invoke-RestMethod -Method POST -Uri $uri -Body $body -ContentType "text/plain; charset=utf-8" -TimeoutSec 15 | Out-Null
        Write-DebugLog "presence published channel=$channel port=$port ips=$($ips -join ',')"
        return $true
    } catch {
        Write-DebugLog "presence publish fail: $($_.Exception.Message)"
        return $false
    }
}

function Get-DirectPresenceList($cfg) {
    $channel = Get-NtfyChannel $cfg
    $curl = Get-Curl
    $uri = "https://ntfy.sh/" + $channel + "/json?poll=1"
    $found = New-Object System.Collections.Generic.List[object]
    try {
        $raw = & $curl -sS -A "sync-collab" --max-time 20 $uri 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
        $cutoff = (Get-Date).AddMinutes(-20)
        foreach ($line in ($raw -split "`n" | Where-Object { $_.Trim() -ne "" })) {
            try {
                $ev = $line | ConvertFrom-Json
                $msg = [string]$ev.message
                if (-not $msg) { continue }
                $json = $null
                if ($msg.StartsWith("DIRECTCOLLAB|")) {
                    $json = $msg.Substring("DIRECTCOLLAB|".Length)
                } elseif ($msg.Trim().StartsWith("{") -and $msg -match '"direct-presence"') {
                    $json = $msg
                } else { continue }
                $p = $json | ConvertFrom-Json
                if ([string]$p.format -ne "direct-presence") { continue }
                $when = $null
                try { $when = [datetime]::Parse([string]$p.sentAt) } catch { }
                if ($when -and $when -lt $cutoff) { continue }
                $ipList = @()
                if ($p.ips) { $ipList = @($p.ips | ForEach-Object { [string]$_ }) }
                $found.Add([pscustomobject]@{
                    Name = [string]$p.name
                    Ips  = $ipList
                    Port = [int]$p.port
                    Size = [int64]$p.sizeBytes
                    At   = [string]$p.sentAt
                }) | Out-Null
            } catch { }
        }
    } catch {
        Write-DebugLog "presence poll fail: $($_.Exception.Message)"
    }
    # plus recent en premier
    return @($found | Sort-Object At -Descending)
}

function Get-Manifest($cfg) {
    $channel = Get-NtfyChannel $cfg
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
                if ($msg.StartsWith("DIRECTCOLLAB|")) { continue }
                if ($msg.Trim().StartsWith("{")) {
                    $man = $msg | ConvertFrom-Json
                    if ([string]$man.format -eq "direct-presence") { continue }
                    $u = $null
                    if ($man.indexUrl) { $u = [string]$man.indexUrl }
                    elseif ($man.url) { $u = [string]$man.url }
                    if ($u) {
                        if (Test-DirectPackUrl $u) {
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
    throw "Aucun lien d upload valide. L envoi de ton ami a echoue (faux lien). Demande-lui de mettre a jour sync.ps1 puis de renvoyer (bouton 2)."
}

function Invoke-Send {
    $cfg = Get-Cfg
    Write-Host ""
    Write-Host "=== ENVOI DU SERVEUR (mode confiance) ===" -ForegroundColor Magenta
    Write-Host "A) Compression + controles"
    Write-Host "B) Upload + verification du lien"
    Write-Host "C) Publication du manifeste (seulement si B OK)"
    Write-Host ""
    $pack = New-ServerPack $cfg
    try {
        Write-Info "Controle du zip avant envoi..."
        $idx = Assert-PackZipReady $pack.FullName
        $fileCount = @($idx.files).Count

        Write-Host ""
        Write-Info "Etape B : envoi en ligne..."
        $up = Send-PackFile $pack.FullName

        Write-Info "Verification que le lien est telechargeable..."
        $checkUrl = $up.url
        if ($up.indexUrl) { $checkUrl = $up.indexUrl }
        if (-not (Test-UrlFetchable $checkUrl)) {
            throw "Upload refuse : le lien ne se telecharge pas. RIEN n a ete publie. Reessaie."
        }
        Write-Ok "Lien verifie (telechargeable)."

        if ($up.format -eq "sync-collab-parts-v1") {
            Write-Info "Controle index multi-parts..."
            $probe = Join-Path $env:TEMP ("sync-idx-check-" + [guid]::NewGuid().ToString("N") + ".json")
            try {
                Get-RemoteFile $checkUrl $probe
                $remoteIdx = Get-Content -LiteralPath $probe -Raw -Encoding UTF8 | ConvertFrom-Json
                $pc = @($remoteIdx.parts).Count
                if ($pc -lt 1) { throw "Index distant vide." }
                if ($up.partCount -and ([int]$up.partCount -ne $pc)) {
                    throw ("Nombre de parts incoherent (local {0} / distant {1})." -f $up.partCount, $pc)
                }
                $p0 = [string](@($remoteIdx.parts | Sort-Object { [int]$_.i })[0].url)
                if (-not (Test-UrlFetchable $p0)) {
                    throw "La partie 0 ne se telecharge pas. Publication annulee."
                }
                Write-Ok ("Index distant OK ({0} morceaux)." -f $pc)
            } finally {
                try { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } catch { }
            }
        }

        if ($up.sha256) {
            $localSha = Get-FileSha256 $pack.FullName
            if ($up.sha256 -ne $localSha -and $up.format -eq "single") {
                throw "Hash local/remote incoherent. Envoi annule."
            }
        }

        Write-Info "Publication du manifeste..."
        Publish-Manifest $cfg $up $pack.Length
        Write-Host ""
        Write-Ok "ENVOI TERMINE ET VERIFIE."
        Write-Host ("Fichiers dans le pack : " + $fileCount)
        Write-Host "L autre peut recuperer (bouton 1) - fusion, sans suppression chez lui."
        if ($up.code) {
            Write-Host ("Code multi-parts : " + $up.code + " (" + $up.partCount + " morceaux)")
        }
        Write-Host ("Lien (secours) : " + $up.page)
        Write-ReceiveLog ("SEND ok files=" + $fileCount + " size=" + $pack.Length + " url=" + $up.page)
    } finally {
        try { Remove-Item -LiteralPath $pack.FullName -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-ScopeBase($cfg, $gmod, [string]$scope) {
    if ($scope -eq "ds") { return Get-GmodParent $gmod }
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

function Get-RemoteTopMap($index) {
    $map = @{}
    foreach ($t in @($index.targets)) {
        if ($t -and $t.scope -and $t.name) {
            $map[([string]$t.scope + "|" + [string]$t.name)] = $true
        }
    }
    foreach ($d in @($index.dirs)) {
        if ($d -and $d.scope -and $d.name) {
            $map[([string]$d.scope + "|" + [string]$d.name)] = $true
        }
    }
    foreach ($f in @($index.files)) {
        if ($f -and $f.scope -and $f.name) {
            $map[([string]$f.scope + "|" + [string]$f.name)] = $true
        }
    }
    return $map
}

function Get-RemoteDirMap($index) {
    $map = @{}
    foreach ($d in @($index.dirs)) {
        $rel = [string]$d.rel
        if (-not $rel) { continue }
        if (Test-SkipPackRel $rel) { continue }
        $map[([string]$d.scope + "|" + $rel)] = $true
    }
    return $map
}

function Save-TreeDoc($index, [string]$path) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Arbre du serveur recu")
    if ($index.sentAt) { $lines.Add("Envoye : " + [string]$index.sentAt) }
    $lines.Add("Mode fusion : on AJOUTE / REMPLACE les fichiers du pack.")
    $lines.Add("Rien n est supprime chez toi hors du pack.")
    $lines.Add("")
    foreach ($d in (@($index.dirs) | Sort-Object { [string]$_.scope + "/" + [string]$_.rel })) {
        $lines.Add("[" + $d.scope + "] " + $d.rel + "/")
    }
    [System.IO.File]::WriteAllLines($path, $lines.ToArray(), (New-Object System.Text.UTF8Encoding $false))
}

function Invoke-MirrorPack($cfg, $gmod, $index, [string]$extract) {
    $added = 0
    $updated = 0
    $denied = 0
    $content = Join-Path $extract "content"

    Write-Info "Mode FUSION : on met a jour ce qui est dans le pack."
    Write-Info "On ne supprime RIEN d autre chez toi (A/D/E/F restent)."

    foreach ($d in @($index.dirs)) {
        $base = Get-ScopeBase $cfg $gmod ([string]$d.scope)
        $rel = [string]$d.rel
        if (-not $rel) { continue }
        if (Test-SkipPackRel $rel) { continue }
        $dest = Join-Path $base ($rel -replace "/", "\")
        if (-not (Test-Path -LiteralPath $dest)) {
            try { New-Item -ItemType Directory -Path $dest -Force | Out-Null } catch { }
        }
    }

    foreach ($f in @($index.files)) {
        if (Test-SkipPackRel ([string]$f.rel) -or Test-SkipPackDirName ([string]$f.name)) { continue }
        $base = Get-ScopeBase $cfg $gmod ([string]$f.scope)
        $dest = Join-Path $base (($f.rel -replace "/", "\"))
        $src = Join-Path $content ((([string]$f.scope) + "\" + ($f.rel -replace "/", "\")))
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Warn ("Fichier absent du zip : " + $f.rel)
            continue
        }
        $remoteM = $null
        try {
            $remoteM = [datetime]::Parse([string]$f.mtimeUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        } catch { }

        try {
            $existed = Test-Path -LiteralPath $dest
            if (-not $existed) {
                $dir = Split-Path $dest -Parent
                if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
            }
            [System.IO.File]::Copy($src, $dest, $true)
            if ($remoteM) {
                try { [System.IO.File]::SetLastWriteTimeUtc($dest, $remoteM) } catch { }
            }
            if ($existed) { $updated++ } else { $added++ }
        } catch {
            $denied++
            Write-Warn ("Ignore (acces refuse) : " + $f.rel)
        }
    }

    # PAS de suppression : le pack = overlay, pas un miroir destructeur.

    Write-Host ""
    Write-Ok ("Ajoutes : " + $added)
    Write-Ok ("Remplaces (depuis l autre) : " + $updated)
    Write-Ok "Aucun dossier/fichier local supprime."
    if ($denied -gt 0) { Write-Warn ("Ignores (acces refuse) : " + $denied) }
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

function Get-RemoteFile([string]$url, [string]$outPath) {
    $curl = Get-Curl
    & $curl -L --fail --connect-timeout 20 --max-time 900 -A "Mozilla/5.0" -o $outPath -- $url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outPath)) {
        throw ("Telechargement echoue (curl " + $LASTEXITCODE + ") : " + $url)
    }
}

function Receive-PackToZip($man, [string]$zipOut) {
    $format = [string]$man.format
    $indexUrl = $null
    if ($man.indexUrl) { $indexUrl = [string]$man.indexUrl }
    elseif ($format -eq "sync-collab-parts-v1" -and $man.url) { $indexUrl = [string]$man.url }

    # Ancien format : 1 seul zip
    if (-not $indexUrl -or $format -eq "single" -or (-not $format -and -not $man.partCount)) {
        $url = [string]$man.url
        if (-not (Test-DirectPackUrl $url)) {
            throw "Lien invalide. Ton ami doit renvoyer avec sync a jour (bouton 2)."
        }
        Write-Info ("URL : " + $url)
        Write-Info "Telechargement du pack..."
        Get-RemoteFile $url $zipOut
        return
    }

    # Multi-parts : telecharger l index puis chaque morceau
    if (-not (Test-DirectPackUrl $indexUrl)) {
        throw "Index multi-parts invalide. Ton ami doit renvoyer (bouton 2)."
    }
    $code = [string]$man.code
    if (-not $code) { $code = "parts" }
    Write-Ok ("Pack multi-parts detecte" + $(if ($code) { " : " + $code } else { "" }))
    Write-Info ("Index : " + $indexUrl)

    $work = Join-Path $env:TEMP ("sync-recv-" + $code + "-" + [guid]::NewGuid().ToString("N").Substring(0, 6))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $indexPath = Join-Path $work "index.json"
        Get-RemoteFile $indexUrl $indexPath
        $index = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $index.parts -or $index.parts.Count -lt 1) {
            throw "Index multi-parts vide ou corrompu."
        }
        $ordered = @($index.parts | Sort-Object { [int]$_.i })
        Write-Info ("Morceaux a telecharger : " + $ordered.Count)
        $partPaths = New-Object System.Collections.Generic.List[string]
        $n = 0
        foreach ($p in $ordered) {
            $n++
            $purl = [string]$p.url
            if (-not (Test-DirectPackUrl $purl)) {
                throw ("URL partie " + $n + " invalide : " + $purl)
            }
            $pp = Join-Path $work ("part-{0:D4}.bin" -f ([int]$p.i))
            Write-Info ("Telechargement partie " + $n + "/" + $ordered.Count + "...")
            Get-RemoteFile $purl $pp
            if ($p.sha256) {
                $got = Get-FileSha256 $pp
                if ($got -ne [string]$p.sha256) {
                    throw ("Hash partie " + $n + " incorrect (fichier corrompu).")
                }
            }
            $partPaths.Add($pp)
        }
        Write-Info "Fusion des morceaux..."
        Merge-FileParts ($partPaths.ToArray()) $zipOut
        if ($index.sha256) {
            $gotFull = Get-FileSha256 $zipOut
            if ($gotFull -ne [string]$index.sha256) {
                throw "Hash du zip reconstitue incorrect. Demande a ton ami de renvoyer."
            }
            Write-Ok "Integrite OK (sha256)."
        }
    } finally {
        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Invoke-Receive {
    $cfg = Get-Cfg
    Write-Host ""
    Write-Host "=== RECUPERATION (mode confiance) ===" -ForegroundColor Magenta
    Write-Host "1) Telecharger + verifier"
    Write-Host "2) Backup local automatique"
    Write-Host "3) Fusion (AJOUT/REMPLACE uniquement - ZERO suppression)"
    Write-Host ""

    Write-Info "Recherche de la derniere version envoyee..."
    $man = Get-Manifest $cfg
    Write-Ok ("Trouve : " + $man.sentAt)
    if ($man.sizeBytes) {
        Write-Info ("Taille annoncee : {0:N1} Mo" -f ($man.sizeBytes / 1MB))
    }

    $zip = Join-Path $env:TEMP ("serveur-recv-" + [guid]::NewGuid().ToString("N") + ".zip")
    Receive-PackToZip $man $zip

    if (-not (Test-ZipFile $zip)) {
        throw "Fichier telecharge invalide. RIEN n a ete modifie chez toi."
    }
    if ($man.sha256 -and $man.format -eq "single") {
        $got = Get-FileSha256 $zip
        if ($got -ne [string]$man.sha256) {
            throw "Hash du telechargement incorrect. RIEN n a ete modifie chez toi."
        }
        Write-Ok "Hash telechargement OK."
    }

    $extract = Join-Path $env:TEMP ("serveur-recv-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $extract | Out-Null
    Write-Info "Extraction..."
    Expand-Utf8Zip $zip $extract

    $index = Read-PackIndex $extract
    if (-not $index -or $index.format -ne "sync-collab-v2") {
        throw "Pack sans index v2. RIEN n a ete modifie. Demande a l autre de renvoyer avec sync a jour."
    }
    $nFiles = @($index.files).Count
    if ($nFiles -lt 1) {
        throw "Pack vide. RIEN n a ete modifie chez toi."
    }
    Write-Ok ("Pack valide : " + $nFiles + " fichiers a fusionner.")

    $gmod = Find-GmodDir $cfg
    $backupPath = Backup-LocalBeforeReceive $cfg $gmod

    Write-Info "Fusion en cours (aucune suppression)..."
    Invoke-MirrorPack $cfg $gmod $index $extract
    $treeOut = Join-Path $Root ".dernier-arbre.txt"
    try { Save-TreeDoc $index $treeOut } catch { }

    Write-ReceiveLog ("RECV ok files=" + $nFiles + " backup=" + $backupPath)
    try { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    Write-Host ""
    Write-Ok "RECUPERATION TERMINEE (fusion)."
    Write-Host ("Backup de securite : " + $backupPath)
    Write-Host "Tes autres dossiers non presents dans le pack sont INTACTS."
}

# --- Debug + connexion directe (option 3) ---

$script:DirectPorts = @(27890, 27891, 27892, 27901, 27902)
$script:DiscoverPort = 27999

function Write-DebugLog([string]$msg) {
    try {
        $log = Join-Path $Root "debug.log"
        $line = "{0} | {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $msg
        Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    } catch { }
}

function Invoke-SelfDebug {
    Write-DebugLog "==== SELF-DEBUG START v$((Read-JsonFile $VersionPath).version) ===="
    $issues = New-Object System.Collections.Generic.List[string]
    $oks = New-Object System.Collections.Generic.List[string]

    try {
        $curl = Get-Curl
        $oks.Add("curl OK: $curl")
        Write-DebugLog $oks[$oks.Count - 1]
    } catch {
        $issues.Add("curl manquant")
        Write-DebugLog "ERR curl: $($_.Exception.Message)"
    }

    try {
        $cfg = Get-Cfg
        $oks.Add("config.json OK channel=$($cfg.dropChannel)")
        Write-DebugLog $oks[$oks.Count - 1]
        $gmod = Find-GmodDir $cfg
        $oks.Add("garrysmod OK: $($gmod.FullName)")
        Write-DebugLog $oks[$oks.Count - 1]
    } catch {
        $issues.Add("config/gmod: $($_.Exception.Message)")
        Write-DebugLog "ERR gmod: $($_.Exception.Message)"
    }

    # Ports libres ?
    foreach ($p in $script:DirectPorts) {
        $l = $null
        try {
            $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $p)
            $l.Start()
            $oks.Add("port $p libre")
            Write-DebugLog "port $p libre"
            $l.Stop()
        } catch {
            $issues.Add("port $p occupe/bloque")
            Write-DebugLog "WARN port $p : $($_.Exception.Message)"
            try { if ($l) { $l.Stop() } } catch { }
        }
    }

    # IPs locales
    try {
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -ne "WellKnown" } |
            Select-Object -ExpandProperty IPAddress -Unique)
        if (-not $ips -or $ips.Count -eq 0) {
            $ips = @([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
                Where-Object { $_.AddressFamily -eq "InterNetwork" -and $_.ToString() -notlike "127.*" } |
                ForEach-Object { $_.ToString() })
        }
        Write-DebugLog ("IPs locales: " + ($ips -join ", "))
        $oks.Add("IPs: " + ($ips -join ", "))
    } catch {
        Write-DebugLog "WARN IPs: $($_.Exception.Message)"
    }

    Write-DebugLog ("SELF-DEBUG done oks=$($oks.Count) issues=$($issues.Count)")
    if ($issues.Count -gt 0) {
        Write-Warn ("Auto-debug: " + ($issues -join " | "))
        Write-Host ("Details: " + (Join-Path $Root "debug.log")) -ForegroundColor DarkGray
    } else {
        Write-Ok "Auto-debug OK (voir debug.log)."
    }
}

function Get-NetworkEndpoints {
    $list = New-Object System.Collections.Generic.List[object]
    try {
        $rows = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -notlike "127.*" -and
                $_.IPAddress -notlike "169.254.*"
            })
        foreach ($r in $rows) {
            $alias = [string]$r.InterfaceAlias
            $ip = [string]$r.IPAddress
            $kind = "lan"
            if ($alias -match '(?i)radmin|hamachi|zerotier|tailscale|wireguard|vpn|tun|tap|openvpn|softether') {
                $kind = "vpn"
            } elseif ($ip -match '^26\.') {
                # Radmin VPN classique = 26.x.x.x
                $kind = "vpn"
            } elseif ($ip -match '^100\.') {
                $kind = "vpn" # CGNAT / Tailscale-ish
            }
            $list.Add([pscustomobject]@{
                Ip    = $ip
                Alias = $alias
                Kind  = $kind
            }) | Out-Null
        }
    } catch { }
    if ($list.Count -eq 0) {
        try {
            $fallback = @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
                Where-Object { $_.AddressFamily -eq "InterNetwork" } |
                ForEach-Object { $_.ToString() } |
                Where-Object { $_ -notlike "127.*" -and $_ -notlike "169.254.*" })
            foreach ($ip in $fallback) {
                $kind = if ($ip -match '^26\.') { "vpn" } else { "lan" }
                $list.Add([pscustomobject]@{ Ip = $ip; Alias = "?"; Kind = $kind }) | Out-Null
            }
        } catch { }
    }
    # VPN d abord
    return @($list | Sort-Object @{ Expression = { if ($_.Kind -eq "vpn") { 0 } else { 1 } } }, Ip)
}

function Get-LanIPv4List {
    return @((Get-NetworkEndpoints).Ip | Select-Object -Unique)
}

function Get-VpnIPv4List {
    return @((Get-NetworkEndpoints | Where-Object { $_.Kind -eq "vpn" }).Ip | Select-Object -Unique)
}

function Ensure-DirectFirewall {
    $name = "SyncCollab-Direct-All"
    $portArg = "27890-27892,27901-27902"
    $ok = $false
    try {
        $existing = netsh advfirewall firewall show rule name="$name" 2>$null
        if ($existing -match $name) {
            Write-DebugLog "firewall rule already exists: $name"
            return $true
        }
    } catch { }

    $addArgs = @(
        "advfirewall", "firewall", "add", "rule",
        "name=$name", "dir=in", "action=allow", "protocol=TCP",
        "localport=$portArg", "profile=any", "enable=yes",
        "edge=yes"
    )
    try {
        $r = Start-Process -FilePath "netsh" -ArgumentList $addArgs -Wait -PassThru -WindowStyle Hidden
        Write-DebugLog ("firewall add exit=$($r.ExitCode)")
        if ($r.ExitCode -eq 0) { return $true }
    } catch {
        Write-DebugLog ("firewall add fail: $($_.Exception.Message)")
    }

    Write-Warn "Pare-feu : besoin d admin (Radmin est souvent en reseau Public = bloque)."
    Write-Host "Une fenetre UAC va s ouvrir : accepte pour ouvrir les ports Sync." -ForegroundColor Yellow
    try {
        $r2 = Start-Process -FilePath "netsh" -ArgumentList $addArgs -Verb RunAs -Wait -PassThru
        Write-DebugLog ("firewall UAC exit=$($r2.ExitCode)")
        $ok = ($r2.ExitCode -eq 0)
    } catch {
        Write-DebugLog ("firewall UAC fail: $($_.Exception.Message)")
        $ok = $false
    }
    if (-not $ok) {
        Write-Warn "Pare-feu NON ouvert. Chez l hebergeur : autorise TCP 27890-27892 et 27901-27902 (profil Public inclus)."
    } else {
        Write-Ok "Pare-feu OK (tous profils, y compris Public/Radmin)."
    }
    return $ok
}

function Try-AddFirewallRule([int]$port) {
    return (Ensure-DirectFirewall)
}

function Test-IsLikelyWrongVpnIp([string]$ip) {
    $mineVpn = @(Get-VpnIPv4List)
    if ($mineVpn.Count -eq 0) { return $false }
    # Si ON a Radmin (26.x) et qu on tape du 192.168 -> presque surement faux
    if (($mineVpn | Where-Object { $_ -match '^26\.' }) -and ($ip -match '^192\.168\.')) {
        return $true
    }
    return $false
}

function Invoke-DirectDiagnose([string[]]$ips, [int[]]$ports) {
    Write-Host ""
    Write-Host "=== DIAGNOSTIC DIRECT ===" -ForegroundColor Yellow
    $eps = Get-NetworkEndpoints
    Write-Host "Tes interfaces :"
    foreach ($e in $eps) {
        $col = if ($e.Kind -eq "vpn") { "Green" } else { "Gray" }
        Write-Host ("  [{0}] {1}  ({2})" -f $e.Kind.ToUpper(), $e.Ip, $e.Alias) -ForegroundColor $col
        Write-DebugLog ("iface kind=$($e.Kind) ip=$($e.Ip) alias=$($e.Alias)")
    }

    foreach ($ip in $ips) {
        if (Test-IsLikelyWrongVpnIp $ip) {
            Write-Host ""
            Write-Warn "IP $ip = Wi-Fi/LAN chez LUI, PAS joignable via Radmin."
            Write-Host "Dans Radmin VPN, prends son IP 26.x.x.x (affichee dans Radmin), pas 192.168.x.x" -ForegroundColor Yellow
            Write-DebugLog "DIAG wrong-ip-type target=$ip (have local radmin)"
        }

        Write-Host ""
        Write-Info ("Ping $ip ...")
        $pingOk = $false
        try {
            $pingOk = Test-Connection -ComputerName $ip -Count 2 -Quiet -ErrorAction SilentlyContinue
        } catch { }
        if ($pingOk) {
            Write-Ok "Ping OK (le VPN voit la machine)"
            Write-DebugLog "DIAG ping OK $ip"
        } else {
            Write-Warn "Ping KO - Radmin pas connecte a lui, mauvaise IP, ou ping bloque."
            Write-DebugLog "DIAG ping FAIL $ip"
        }

        $probePort = $ports[0]
        Write-Info ("Test TCP ${ip}:$probePort ...")
        $tcpOk = $false
        try {
            $tnc = Test-NetConnection -ComputerName $ip -Port $probePort -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            $tcpOk = [bool]$tnc.TcpTestSucceeded
            Write-DebugLog ("DIAG tnc $ip`:$probePort tcp=$tcpOk ping=$($tnc.PingSucceeded)")
        } catch {
            Write-DebugLog "DIAG tnc err: $($_.Exception.Message)"
        }
        if ($tcpOk) {
            Write-Ok "Port ouvert ! Relance Connect juste apres."
        } else {
            Write-Warn "Port ferme / filtre. Causes frequentes :"
            Write-Host "  1) Chez LUI : sync option 3 -> H (Heberger) doit rester ouvert" -ForegroundColor Yellow
            Write-Host "  2) Chez LUI : accepter UAC pare-feu (profil Public / Radmin)" -ForegroundColor Yellow
            Write-Host "  3) Mauvaise IP : utiliser l IP Radmin 26.x, pas le Wi-Fi 192.168" -ForegroundColor Yellow
            Write-Host "  4) Les DEUX doivent etre en ligne dans le meme reseau Radmin" -ForegroundColor Yellow
        }
    }
    Write-Host ("Details: " + (Join-Path $Root "debug.log")) -ForegroundColor DarkGray
}

function Apply-PackZipFile([string]$zipPath) {
    if (-not (Test-ZipFile $zipPath)) { throw "Zip invalide. RIEN modifie." }
    $extract = Join-Path $env:TEMP ("serveur-direct-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $extract | Out-Null
    try {
        Expand-Utf8Zip $zipPath $extract
        $index = Read-PackIndex $extract
        if (-not $index -or $index.format -ne "sync-collab-v2") {
            throw "Pack sans index v2. RIEN modifie."
        }
        $nFiles = @($index.files).Count
        if ($nFiles -lt 1) { throw "Pack vide. RIEN modifie." }
        Write-Ok ("Pack valide : $nFiles fichiers")
        $cfg = Get-Cfg
        $gmod = Find-GmodDir $cfg
        $backupPath = Backup-LocalBeforeReceive $cfg $gmod
        Invoke-MirrorPack $cfg $gmod $index $extract
        try { Save-TreeDoc $index (Join-Path $Root ".dernier-arbre.txt") } catch { }
        Write-ReceiveLog ("DIRECT-RECV ok files=$nFiles backup=$backupPath")
        Write-DebugLog "DIRECT apply OK files=$nFiles"
        Write-Ok "Fusion terminee (aucune suppression)."
        Write-Host ("Backup : " + $backupPath)
    } finally {
        try { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Send-TcpPack([System.Net.Sockets.TcpClient]$client, [string]$zipPath, $meta) {
    $stream = $client.GetStream()
    $metaLine = "SYNCCOLLAB2|" + ($meta | ConvertTo-Json -Compress) + "`n"
    $metaBytes = [System.Text.Encoding]::UTF8.GetBytes($metaLine)
    $stream.Write($metaBytes, 0, $metaBytes.Length)
    $stream.Flush()

    $fs = [System.IO.File]::OpenRead($zipPath)
    try {
        $buf = New-Object byte[] (1024 * 256)
        $sent = [int64]0
        $total = $fs.Length
        $start = Get-Date
        while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $stream.Write($buf, 0, $read)
            $sent += $read
            $pct = [math]::Round(100.0 * $sent / $total, 1)
            $mb = [math]::Round($sent / 1MB, 1)
            $elapsed = ((Get-Date) - $start).TotalSeconds
            $speed = if ($elapsed -gt 0.2) { [math]::Round(($sent / 1MB) / $elapsed, 1) } else { 0 }
            Write-Host ("`r  Envoi direct [{0}%] {1} Mo / {2:N1} Mo | {3} Mo/s   " -f $pct, $mb, ($total/1MB), $speed) -NoNewline
        }
        $stream.Flush()
        Write-Host ""
    } finally { $fs.Close() }
}

function Receive-TcpPack([System.Net.Sockets.TcpClient]$client, [string]$outZip) {
    $stream = $client.GetStream()
    $stream.ReadTimeout = 120000
    # Lire header jusqu au \n
    $ms = New-Object System.IO.MemoryStream
    while ($true) {
        $b = $stream.ReadByte()
        if ($b -lt 0) { throw "Connexion coupee (header)." }
        if ($b -eq 10) { break } # \n
        if ($b -ne 13) { $ms.WriteByte([byte]$b) }
        if ($ms.Length -gt 200000) { throw "Header trop long." }
    }
    $header = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    if ($header -notlike "SYNCCOLLAB2|*") { throw "Protocole inconnu: $header" }
    $json = $header.Substring("SYNCCOLLAB2|".Length)
    $meta = $json | ConvertFrom-Json
    $total = [int64]$meta.sizeBytes
    if ($total -le 0) { throw "Taille invalide." }
    Write-Info ("Reception : {0:N1} Mo (sha {1}...)" -f ($total/1MB), ([string]$meta.sha256).Substring(0, [Math]::Min(8, ([string]$meta.sha256).Length)))

    $fs = [System.IO.File]::Create($outZip)
    try {
        $buf = New-Object byte[] (1024 * 256)
        $got = [int64]0
        $start = Get-Date
        while ($got -lt $total) {
            $want = [int][Math]::Min($buf.Length, $total - $got)
            $read = $stream.Read($buf, 0, $want)
            if ($read -le 0) { throw "Connexion coupee au milieu du transfert." }
            $fs.Write($buf, 0, $read)
            $got += $read
            $pct = [math]::Round(100.0 * $got / $total, 1)
            $mb = [math]::Round($got / 1MB, 1)
            $elapsed = ((Get-Date) - $start).TotalSeconds
            $speed = if ($elapsed -gt 0.2) { [math]::Round(($got / 1MB) / $elapsed, 1) } else { 0 }
            Write-Host ("`r  Recu [{0}%] {1} Mo | {2} Mo/s   " -f $pct, $mb, $speed) -NoNewline
        }
        Write-Host ""
    } finally { $fs.Close() }

    if ($meta.sha256) {
        $h = Get-FileSha256 $outZip
        if ($h -ne [string]$meta.sha256) { throw "Hash direct incorrect. Abandon (rien fusionne)." }
        Write-Ok "Hash OK."
    }
    return $meta
}

function Start-DirectHost {
    $cfg = Get-Cfg
    Write-Host ""
    Write-Host "=== DIRECT : HEBERGER (envoyer maintenant) ===" -ForegroundColor Magenta
    Write-DebugLog "DIRECT HOST start"

    Write-Info "Compression du pack (comme un envoi normal)..."
    $pack = New-ServerPack $cfg
    $idx = Assert-PackZipReady $pack.FullName
    $sha = Get-FileSha256 $pack.FullName
    $meta = @{
        magic     = "SYNCCOLLAB2"
        version   = [string](Read-JsonFile $VersionPath).version
        sizeBytes = [int64]$pack.Length
        sha256    = $sha
        fileCount = @($idx.files).Count
        name      = $env:COMPUTERNAME
        sentAt    = (Get-Date).ToString("o")
    }

    Write-Info "Ouverture pare-feu (obligatoire pour Radmin = reseau Public)..."
    [void](Ensure-DirectFirewall)

    $listener = $null
    $boundPort = 0
    foreach ($p in $script:DirectPorts) {
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $p)
            $listener.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
            $listener.Start()
            $boundPort = $p
            Write-DebugLog "LISTEN OK port=$p"
            break
        } catch {
            Write-DebugLog "LISTEN fail port=$p : $($_.Exception.Message)"
            try { if ($listener) { $listener.Stop() } } catch { }
            $listener = $null
        }
    }
    if (-not $listener) {
        throw "Aucun port libre parmi: $($script:DirectPorts -join ', '). Ferme un logiciel ou autorise le pare-feu."
    }

    $eps = Get-NetworkEndpoints
    $ips = @($eps.Ip | Select-Object -Unique)
    $vpnIps = @($eps | Where-Object { $_.Kind -eq "vpn" } | ForEach-Object { $_.Ip })
    Write-Ok ("En ecoute sur le port $boundPort (toutes interfaces)")
    Write-Host ""
    Write-Host "Dis a l autre : sync option 3 -> C (Connecter)" -ForegroundColor Cyan
    if ($vpnIps.Count -gt 0) {
        Write-Host ""
        Write-Host ">>> IP RADMIN / VPN A LUI DONNER (copie ca) <<<" -ForegroundColor Green
        foreach ($ip in $vpnIps) {
            Write-Host ("      $ip") -ForegroundColor Green
        }
        Write-Host "PAS son Wi-Fi 192.168 - UNIQUEMENT l IP ci-dessus (souvent 26.x)" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Toutes tes IPs (secours) :" -ForegroundColor DarkGray
    foreach ($e in $eps) {
        Write-Host ("   [{0}] {1}  {2}" -f $e.Kind, $e.Ip, $e.Alias) -ForegroundColor DarkGray
    }
    if ($ips.Count -eq 0) { Write-Warn "IP locale introuvable." }

    # Auto-test : le port repond en local (on consomme tout de suite la fausse connexion)
    try {
        $self = New-Object System.Net.Sockets.TcpClient
        $iar = $self.BeginConnect("127.0.0.1", $boundPort, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(1000, $false)) {
            $self.EndConnect($iar)
            $self.Close()
            Start-Sleep -Milliseconds 150
            if ($listener.Pending()) {
                $bogus = $listener.AcceptTcpClient()
                $bogus.Close()
            }
            Write-Ok "Auto-test local port $boundPort : OK"
            Write-DebugLog "HOST selftest loopback OK"
        } else {
            Write-Warn "Auto-test local timeout (bizarre)."
            Write-DebugLog "HOST selftest loopback timeout"
            try { $self.Close() } catch { }
        }
    } catch {
        Write-DebugLog "HOST selftest fail: $($_.Exception.Message)"
        try { if ($listener.Pending()) { $listener.AcceptTcpClient().Close() } } catch { }
    }

    Write-Info "Signalement session (ntfy) pour que l autre te trouve auto..."
    if (Publish-DirectPresence $cfg $ips $boundPort ([int64]$pack.Length)) {
        Write-Ok "Session annoncee. L autre peut juste faire 3 -> C."
    } else {
        Write-Warn "Signalement ntfy rate - il devra taper ton IP Radmin manuellement."
    }
    Write-Host ""
    Write-Host "Laisse cette fenetre OUVERTE. Attente de connexion..." -ForegroundColor Magenta
    Write-DebugLog ("HOST waiting ips=$($ips -join ',') vpn=$($vpnIps -join ',') port=$boundPort size=$($pack.Length)")

    # Discovery UDP en parallele (job leger)
    $discover = $null
    try {
        $discover = Start-Job -ScriptBlock {
            param($port, $tcpPort, $name)
            $udp = New-Object System.Net.Sockets.UdpClient
            try {
                $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
                $udp.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $port))
                $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                while ($true) {
                    $bytes = $udp.Receive([ref]$remote)
                    $msg = [System.Text.Encoding]::UTF8.GetString($bytes)
                    if ($msg -like "SYNCOLLAB-DISC*") {
                        $reply = [System.Text.Encoding]::UTF8.GetBytes("SYNCOLLAB-HERE|$tcpPort|$name")
                        $udp.Send($reply, $reply.Length, $remote) | Out-Null
                    }
                }
            } finally { $udp.Close() }
        } -ArgumentList $script:DiscoverPort, $boundPort, $env:COMPUTERNAME
    } catch {
        Write-DebugLog "discover job fail: $($_.Exception.Message)"
    }

    try {
        $client = $listener.AcceptTcpClient()
        $ep = $client.Client.RemoteEndPoint.ToString()
        Write-Ok ("Connecte : $ep")
        Write-DebugLog "HOST accepted $ep"
        Write-Info "Transfert direct..."
        Send-TcpPack $client $pack.FullName $meta
        $client.Close()
        Write-Ok "ENVOI DIRECT TERMINE."
        Write-ReceiveLog "DIRECT-SEND ok to=$ep size=$($pack.Length)"
        Write-DebugLog "HOST send done"
    } finally {
        try { $listener.Stop() } catch { }
        if ($discover) {
            try { Stop-Job $discover -Force; Remove-Job $discover -Force } catch { }
        }
        try { Remove-Item -LiteralPath $pack.FullName -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Find-DirectHosts {
    $found = @{}
    # 1) Presence ntfy (meme canal) - marche meme sans broadcast UDP
    try {
        Write-Info "Recherche session annoncee (ntfy)..."
        $cfg = Get-Cfg
        foreach ($p in (Get-DirectPresenceList $cfg)) {
            foreach ($ip in @($p.Ips)) {
                if (-not $ip) { continue }
                $key = "$ip`:$($p.Port)"
                $found[$key] = [pscustomobject]@{ Ip = $ip; Port = [int]$p.Port; Name = $p.Name; Via = "ntfy" }
            }
        }
        Write-DebugLog ("presence hits=" + $found.Count)
    } catch {
        Write-DebugLog "presence search fail: $($_.Exception.Message)"
    }

    # 2) Broadcast LAN UDP
    Write-Info "Recherche LAN (2s)..."
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 800
        $data = [System.Text.Encoding]::UTF8.GetBytes("SYNCOLLAB-DISC?")
        $udp.Send($data, $data.Length, [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast, $script:DiscoverPort)) | Out-Null
        foreach ($ip in (Get-LanIPv4List)) {
            try {
                $parts = $ip.Split(".")
                if ($parts.Count -eq 4) {
                    $bcast = "$($parts[0]).$($parts[1]).$($parts[2]).255"
                    $udp.Send($data, $data.Length, [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($bcast), $script:DiscoverPort)) | Out-Null
                }
            } catch { }
        }
        $deadline = (Get-Date).AddSeconds(2.5)
        while ((Get-Date) -lt $deadline) {
            try {
                $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $bytes = $udp.Receive([ref]$remote)
                $msg = [System.Text.Encoding]::UTF8.GetString($bytes)
                if ($msg -like "SYNCOLLAB-HERE|*") {
                    $bits = $msg.Split("|")
                    $key = $remote.Address.ToString() + ":" + $bits[1]
                    $found[$key] = [pscustomobject]@{ Ip = $remote.Address.ToString(); Port = [int]$bits[1]; Name = $bits[2]; Via = "lan" }
                }
            } catch { break }
        }
        $udp.Close()
    } catch {
        Write-DebugLog "discover client fail: $($_.Exception.Message)"
    }
    return @($found.Values)
}

function Start-DirectClient {
    Write-Host ""
    Write-Host "=== DIRECT : SE CONNECTER (recuperer maintenant) ===" -ForegroundColor Magenta
    Write-DebugLog "DIRECT CLIENT start"

    $hosts = Find-DirectHosts
    $ip = $null
    $portHint = $null
    $tryIps = New-Object System.Collections.Generic.List[string]
    if ($hosts.Count -gt 0) {
        Write-Ok ("Session(s) trouvee(s) :")
        $i = 1
        foreach ($h in $hosts) {
            Write-Host ("  $i) $($h.Name) @ $($h.Ip):$($h.Port) [$($h.Via)]")
            $i++
        }
        $c = Read-Host "Numero (ou Entree = essayer TOUTES auto / ou tape une IP)"
        if ($c -match '^\d+$') {
            $n = [int]$c
            if ($n -ge 1 -and $n -le $hosts.Count) {
                $ip = $hosts[$n - 1].Ip
                $portHint = $hosts[$n - 1].Port
            }
        } elseif (-not $c) {
            foreach ($h in $hosts) {
                if (-not $tryIps.Contains($h.Ip)) { $tryIps.Add($h.Ip) | Out-Null }
                if (-not $portHint) { $portHint = $h.Port }
            }
        } else {
            $ip = $c.Trim()
        }
    }
    if (-not $ip -and $tryIps.Count -eq 0) {
        Write-Host "Sous Radmin : tape son IP 26.x (dans Radmin), PAS 192.168.x" -ForegroundColor Yellow
        $ip = Read-Host "IP de l autre (ex 26.182.232.196)"
    }
    if ($ip) { $tryIps.Clear(); $tryIps.Add($ip) | Out-Null }
    if ($tryIps.Count -eq 0) { throw "IP manquante." }

    foreach ($cand in @($tryIps)) {
        if (Test-IsLikelyWrongVpnIp $cand) {
            Write-Warn "ATTENTION: $cand ressemble a du Wi-Fi local. Via Radmin il faut l IP 26.x de ton ami."
            $fix = Read-Host "Continuer quand meme avec $cand ? (O/N)"
            if ($fix -notmatch '^[oOyY]') {
                $alt = Read-Host "Colle son IP Radmin 26.x"
                if ($alt) { $tryIps.Clear(); $tryIps.Add($alt.Trim()) | Out-Null }
            }
        }
    }

    $ports = @()
    if ($portHint) { $ports += $portHint }
    $ports += $script:DirectPorts
    $ports = @($ports | Select-Object -Unique)

    $client = $null
    $usedPort = 0
    $usedIp = $null
    :connectOuter foreach ($candIp in $tryIps) {
        foreach ($p in $ports) {
            try {
                Write-Info ("Connexion $($candIp):$p ...")
                $client = New-Object System.Net.Sockets.TcpClient
                $iar = $client.BeginConnect($candIp, $p, $null, $null)
                # VPN = latence plus haute
                $ok = $iar.AsyncWaitHandle.WaitOne(8000, $false)
                if (-not $ok) {
                    Write-DebugLog "CLIENT timeout $candIp`:$p"
                    $client.Close(); $client = $null; continue
                }
                $client.EndConnect($iar)
                $usedPort = $p
                $usedIp = $candIp
                Write-Ok ("Connecte sur $($candIp):$p")
                Write-DebugLog "CLIENT connected $candIp`:$p"
                break connectOuter
            } catch {
                Write-DebugLog "CLIENT fail $candIp`:$p : $($_.Exception.Message)"
                try { if ($client) { $client.Close() } } catch { }
                $client = $null
            }
        }
    }
    if (-not $client) {
        Invoke-DirectDiagnose (@($tryIps)) (@($ports))
        throw "Impossible de joindre ($($tryIps -join ', ')). Chez LUI: 3->H ouvert + UAC pare-feu. Chez TOI: IP Radmin 26.x."
    }

    $zip = Join-Path $env:TEMP ("serveur-direct-recv-" + [guid]::NewGuid().ToString("N") + ".zip")
    try {
        $meta = Receive-TcpPack $client $zip
        $client.Close()
        Write-Info "Application du pack (fusion + backup)..."
        Apply-PackZipFile $zip
        Write-Ok "RECUPERATION DIRECTE TERMINEE."
        Write-DebugLog "CLIENT done from=$usedIp`:$usedPort files=$($meta.fileCount)"
    } finally {
        try { if ($client) { $client.Close() } } catch { }
        try { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Invoke-DirectMenu {
    Write-Host ""
    Write-Host "=== CONNEXION DIRECTE (rapide, les deux presents) ===" -ForegroundColor Magenta
    Write-Host "  H) Heberger  = TOI envoies ton serveur maintenant"
    Write-Host "  C) Connecter = TOI recuperes depuis l autre maintenant"
    Write-Host "  0) Retour"
    Write-Host ""
    $c = Read-Host "Choix"
    if ($c -match '^[hH]') { Start-DirectHost }
    elseif ($c -match '^[cC]') { Start-DirectClient }
    elseif ($c -eq "0") { return }
    else { Write-Warn "Choix invalide." }
}

function Show-Menu {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Magenta
    Write-Host "  SYNC COLLAB" -ForegroundColor Magenta
    Write-Host "=============================================="
    Write-Host ""
    Write-Host "  1) RECUPERER (messager - l autre peut etre parti)"
    Write-Host "     Fusion + backup auto"
    Write-Host ""
    Write-Host "  2) ENVOYER (messager - pour plus tard)"
    Write-Host "     Pack verifie + lien reteste"
    Write-Host ""
    Write-Host "  3) DIRECT (les DEUX sont la - rapide)"
    Write-Host "     Connexion TCP locale / IP, multi-ports"
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
        Write-DebugLog "GithubUpdate warn: $($_.Exception.Message)"
    }
    if ($needRelaunch) {
        $env:SYNC_COLLAB_UPDATED = "1"
        Start-Process -FilePath (Join-Path $Root "sync.bat")
        exit 0
    }

    try { Invoke-SelfDebug } catch { Write-DebugLog "SelfDebug err: $($_.Exception.Message)" }

    $c = Show-Menu
    if ($c -eq "1") {
        Invoke-Receive
    } elseif ($c -eq "2") {
        Invoke-Send
    } elseif ($c -eq "3") {
        Invoke-DirectMenu
    } elseif ($c -eq "0") {
        exit 0
    } else {
        Write-Warn "Choix invalide."
    }
} catch {
    Write-ErrMsg $_.Exception.Message
    Write-DebugLog ("FATAL: " + $_.Exception.Message + " | " + $_.ScriptStackTrace)
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ("Debug: " + (Join-Path $Root "debug.log")) -ForegroundColor Yellow
}

Write-Host ""
Read-Host "Entree pour fermer" | Out-Null
