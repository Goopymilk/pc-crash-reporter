@echo off
rem Rebuilds the report about the PREVIOUS session (what happened before the last restart).
schtasks /run /tn "PC Crash Reporter - Make Report Now" >nul 2>&1
if errorlevel 1 (
  echo PC Crash Reporter is not installed yet - double-click Install.cmd first.
  pause
) else (
  echo Building the report... it will open in your browser in about 10-30 seconds.
  timeout /t 4 >nul
)
