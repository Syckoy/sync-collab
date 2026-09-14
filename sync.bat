@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Sync collab
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync.ps1" %*
if errorlevel 1 pause
