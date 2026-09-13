@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Preparer upload GitHub
powershell -NoProfile -ExecutionPolicy Bypass -Command "$src='%~dp0'; $dst=Join-Path $env:USERPROFILE 'Desktop\sync-collab-GITHUB'; if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }; New-Item -ItemType Directory -Force -Path $dst | Out-Null; foreach ($f in @('sync.bat','sync.ps1','config.json','version.json','README.md','.gitignore','preparer-github.bat')) { $p=Join-Path $src $f; if (Test-Path $p) { Copy-Item $p $dst } }; Write-Host ('Dossier pret : ' + $dst); Write-Host 'Uploade UNIQUEMENT ca sur GitHub.'"
echo.
pause
