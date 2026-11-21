@echo off
title PC Crash Reporter - Repair Windows
rem Repairs damaged Windows system files: DISM first (fixes the repair source), then SFC.
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Asking for administrator permission...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
set "LOG=%~dp0logs\repair-windows.log"
if not exist "%~dp0logs" mkdir "%~dp0logs"
echo.
echo  ============================================================
echo   Repair Windows system files
echo  ============================================================
echo   This checks Windows for damaged or missing system files and
echo   repairs them. It takes 10-30 minutes. You can keep using the
echo   PC, but don't turn it off. An internet connection helps.
echo  ============================================================
echo.
echo ===== %date% %time% Repair started ===== >> "%LOG%"
echo [Step 1 of 2] Repairing the Windows component store (DISM)...
echo              The progress can sit at one number for a long time - that is normal.
DISM /Online /Cleanup-Image /RestoreHealth
set DISMRC=%errorlevel%
echo DISM exit code: %DISMRC% >> "%LOG%"
echo.
echo [Step 2 of 2] Checking and repairing system files (SFC)...
sfc /scannow
set SFCRC=%errorlevel%
echo SFC exit code: %SFCRC% >> "%LOG%"
echo.
echo  ============================================================
if "%DISMRC%"=="0" (echo   DISM: finished OK.) else (echo   DISM: reported a problem ^(code %DISMRC%^). Check your internet connection and run this again.)
if "%SFCRC%"=="0" (echo   SFC:  finished. Read the last message above:) else (echo   SFC:  reported a problem ^(code %SFCRC%^). Read the message above.)
echo         "did not find any integrity violations"  = nothing was broken.
echo         "found corrupt files and successfully repaired them" = fixed! Restart the PC.
echo         "found corrupt files but was unable to fix some" = run this once more after a restart.
echo   A log was saved to: %LOG%
echo  ============================================================
echo ===== %date% %time% Repair finished ===== >> "%LOG%"
echo.
pause