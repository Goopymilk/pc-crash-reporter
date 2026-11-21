@echo off
title PC Crash Reporter - Resume monitoring
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Monitor-Control.ps1" -Resume
