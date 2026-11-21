@echo off
title PC Crash Reporter - Pause monitoring
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Monitor-Control.ps1" -Pause
