@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$src='%~dp0'; $dst=Join-Path $env:USERPROFILE 'Desktop\sync-collab-POUR-AMI'; if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }; New-Item -ItemType Directory -Force -Path $dst | Out-Null; Copy-Item (Join-Path $src 'sync.bat') $dst; Copy-Item (Join-Path $src 'sync.ps1') $dst; Copy-Item (Join-Path $src 'config.json') $dst; Copy-Item (Join-Path $src 'LIREMOI.txt') $dst; $tools=Join-Path $src 'tools'; if (Test-Path $tools) { Copy-Item $tools (Join-Path $dst 'tools') -Recurse }; Write-Host ('Dossier pret : ' + $dst); Write-Host 'Envoie CE dossier-la a ton ami, pas tout sync-collab.'"
pause
