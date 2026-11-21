@echo off
rem Shows what a blue-screen report looks like, using your real sensor readings. Nothing is saved to history.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Report.ps1" -Demo bsod
