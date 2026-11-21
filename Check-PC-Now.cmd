@echo off
rem Health check of the CURRENT session: temperatures, power, errors since Windows started. No restart needed.
schtasks /run /tn "PC Crash Reporter - Check Now" >nul 2>&1
if errorlevel 1 (
  echo PC Crash Reporter is not installed yet - double-click Install.cmd first.
  pause
) else (
  echo Checking your PC... the report will open in your browser in about 10-30 seconds.
  timeout /t 4 >nul
)
