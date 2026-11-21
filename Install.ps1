<#
  PC Crash Reporter - installer.
  Easiest way: double-click Install.cmd (it asks for admin rights).

  What it does:
    1. Downloads LibreHardwareMonitor (free, open-source sensor library) into .\tools
    2. Offers to install PawnIO (the small driver LibreHardwareMonitor needs to read CPU temps/power)
    3. Optionally installs Microsoft WinDbg for deeper blue-screen analysis
    4. Creates two scheduled tasks:
         - "PC Crash Reporter - Monitor": starts at boot, logs sensors in the background
         - "PC Crash Reporter - Report" : runs 1 minute after you log in, builds the report
    5. Makes sure Windows saves crash dump files
    6. Puts two shortcuts on your desktop
#>
param(
    [switch]$ToolsOnly,      # only download LibreHardwareMonitor
    [switch]$Yes             # answer yes to all optional questions
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

function Write-Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Read-YesNo([string]$Question) {
    if ($Yes) { return $true }
    $a = Read-Host "$Question [Y/n]"
    return ($a -eq '' -or $a -match '^[Yy]')
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Asking for administrator rights...'
    $args2 = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($ToolsOnly) { $args2 += '-ToolsOnly' }
    if ($Yes) { $args2 += '-Yes' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $args2
    exit
}

trap {
    Write-Host ''
    Write-Host "Something went wrong: $_" -ForegroundColor Red
    if (-not $Yes) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
$ua = @{ 'User-Agent' = 'pc-crash-reporter-installer' }

# ---------- 1. LibreHardwareMonitor ----------
function Install-Lhm {
    Write-Step 'Downloading LibreHardwareMonitor (sensor library)'
    $url = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip'
    $tag = 'v0.9.6'
    try {
        $rel = Invoke-RestMethod 'https://api.github.com/repos/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest' -Headers $ua
        $asset = $rel.assets | Where-Object { $_.name -eq 'LibreHardwareMonitor.zip' } | Select-Object -First 1
        if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -like '*.zip' -and $_.name -notmatch 'NET\.\d' } | Select-Object -First 1 }
        if ($asset) { $url = $asset.browser_download_url; $tag = $rel.tag_name }
    } catch { Write-Host "  (could not check for the newest version, using $tag)" }

    $zip = Join-Path $env:TEMP 'LibreHardwareMonitor.zip'
    Invoke-WebRequest $url -OutFile $zip -UseBasicParsing -Headers $ua
    if (Test-Path $script:Paths.Lhm) {
        # stop the monitor first so the DLLs are not locked
        Stop-MonitorProcess
        Remove-Item $script:Paths.Lhm -Recurse -Force
    }
    Expand-Archive $zip -DestinationPath $script:Paths.Lhm -Force
    Remove-Item $zip -Force
    Get-ChildItem $script:Paths.Lhm -Recurse -File | Unblock-File
    Set-Content -Path (Join-Path $script:Paths.Lhm 'VERSION.txt') -Value $tag
    Write-Host "  Installed LibreHardwareMonitor $tag" -ForegroundColor Green
}

function Stop-MonitorProcess {
    try { Stop-ScheduledTask -TaskName 'PC Crash Reporter - Monitor' -ErrorAction SilentlyContinue } catch { }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*Monitor.ps1*' -and $_.CommandLine -like "*$($script:Root)*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

Install-Lhm
if ($ToolsOnly) { exit }

# ---------- 2. PawnIO ----------
Write-Step 'Checking for PawnIO (needed to read CPU temperature and power)'
$pawn = (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\PawnIO') -or (Test-Path "$env:ProgramFiles\PawnIO")
if ($pawn) {
    Write-Host '  PawnIO is already installed.' -ForegroundColor Green
} else {
    Write-Host '  PawnIO is a small, signed, open-source driver. Without it you still get GPU,'
    Write-Host '  drive and memory readings, but no CPU temperature/power or motherboard fans/voltages.'
    if (Read-YesNo '  Download and run the PawnIO installer now?') {
        $exe = Join-Path $env:TEMP 'PawnIO_setup.exe'
        $purl = 'https://github.com/namazso/PawnIO.Setup/releases/latest/download/PawnIO_setup.exe'
        Invoke-WebRequest $purl -OutFile $exe -UseBasicParsing -Headers $ua
        Write-Host '  The PawnIO setup window will open - click through it, then come back here.'
        $p = Start-Process $exe -PassThru -Wait
        Remove-Item $exe -Force -ErrorAction SilentlyContinue
        Write-Host "  PawnIO setup finished (exit code $($p.ExitCode))."
    }
}

# ---------- 3. WinDbg (optional) ----------
Write-Step 'Optional: Microsoft WinDbg (lets the report name the exact driver behind a blue screen)'
$haveDbg = $false
try { $haveDbg = [bool](Get-AppxPackage -AllUsers -Name 'Microsoft.WinDbg' -ErrorAction SilentlyContinue) } catch { }
if (-not $haveDbg) { $haveDbg = Test-Path "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe" }
if ($haveDbg) {
    Write-Host '  WinDbg is already installed.' -ForegroundColor Green
} elseif (Get-Command winget.exe -ErrorAction SilentlyContinue) {
    if (Read-YesNo '  Install WinDbg from Microsoft via winget? (~100 MB, recommended)') {
        & winget.exe install --id Microsoft.WinDbg -e --accept-package-agreements --accept-source-agreements
    }
} else {
    Write-Host '  winget not found - skipping. (You can install "WinDbg" from the Microsoft Store later.)'
}

# ---------- 4. scheduled tasks ----------
Write-Step 'Creating scheduled tasks'
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$monitorPath = Join-Path $script:Root 'Monitor.ps1'
$reportPath  = Join-Path $script:Root 'Report.ps1'

$monAction = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$monitorPath`"" -WorkingDirectory $script:Root
$monTrigger = New-ScheduledTaskTrigger -AtStartup
$monPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$monSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName 'PC Crash Reporter - Monitor' -Action $monAction -Trigger $monTrigger -Principal $monPrincipal `
    -Settings $monSettings -Description 'Logs PC temperatures, power and load so crashes can be explained.' -Force | Out-Null
Write-Host '  Monitor task created.' -ForegroundColor Green

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$repAction = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$reportPath`"" -WorkingDirectory $script:Root
$repTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$repTrigger.Delay = 'PT1M'
$repPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$repSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'PC Crash Reporter - Report' -Action $repAction -Trigger $repTrigger -Principal $repPrincipal `
    -Settings $repSettings -Description 'Builds a plain-English report about the last session after each restart.' -Force | Out-Null
Write-Host '  Report task created.' -ForegroundColor Green

# On-demand tasks (no trigger) so the desktop shortcuts run as admin without a UAC prompt every time
$manSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
foreach ($t in @(@('PC Crash Reporter - Make Report Now', '-Force', 'Rebuilds the report about the previous session.'),
                 @('PC Crash Reporter - Check Now', '-CurrentSession', 'Health check of the current session.'))) {
    $a = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$reportPath`" $($t[1])" -WorkingDirectory $script:Root
    Register-ScheduledTask -TaskName $t[0] -Action $a -Principal $repPrincipal -Settings $manSettings -Description $t[2] -Force | Out-Null
}
Write-Host '  On-demand report tasks created.' -ForegroundColor Green

# Idle helper: runs hidden in your session and notes how long since you last used the mouse/keyboard,
# so the report can spot programs that work hard only while you are away (e.g. hidden crypto miners).
$idleAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument "`"$(Join-Path $script:Root 'lib\RunHidden.vbs')`" `"$(Join-Path $script:Root 'IdleHelper.ps1')`"" -WorkingDirectory $script:Root
$idleTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$idlePrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$idleSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'PC Crash Reporter - Idle Helper' -Action $idleAction -Trigger $idleTrigger -Principal $idlePrincipal `
    -Settings $idleSettings -Description 'Notes how long since you last used the keyboard/mouse (for the "busy while idle" check).' -Force | Out-Null
Write-Host '  Idle helper task created.' -ForegroundColor Green
# a fresh install always means monitoring is on
Remove-Item $script:Paths.Paused -Force -ErrorAction SilentlyContinue

# ---------- 5. crash dumps ----------
Write-Step 'Checking that Windows saves crash dumps'
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
$cur = (Get-ItemProperty $cc -ErrorAction SilentlyContinue).CrashDumpEnabled
if ($cur -eq 0) {
    Set-ItemProperty $cc -Name CrashDumpEnabled -Value 3   # small memory dump
    Write-Host '  Crash dumps were turned OFF - switched to "Small memory dump" so blue screens can be analysed.' -ForegroundColor Yellow
} else {
    Write-Host "  OK (setting = $cur)." -ForegroundColor Green
}

# ---------- 6. shortcuts ----------
Write-Step 'Adding desktop shortcuts'
$desk = [Environment]::GetFolderPath('Desktop')
$wsh = New-Object -ComObject WScript.Shell
$s1 = $wsh.CreateShortcut((Join-Path $desk 'PC Crash Report - Latest.lnk'))
$s1.TargetPath = Join-Path $script:Root 'reports\latest.html'
$s1.Description = 'Open the most recent PC crash report'
$s1.Save()
$s2 = $wsh.CreateShortcut((Join-Path $desk 'PC Crash Report - Check Now.lnk'))
$s2.TargetPath = Join-Path $script:Root 'Check-PC-Now.cmd'
$s2.WorkingDirectory = $script:Root
$s2.IconLocation = "$env:SystemRoot\System32\imageres.dll,76"
$s2.Description = 'Health check of the current session (temperatures, errors) right now'
$s2.Save()
Write-Host '  Done.' -ForegroundColor Green

# ---------- start ----------
Write-Step 'Starting the monitor and building your first report'
Stop-MonitorProcess
Start-ScheduledTask -TaskName 'PC Crash Reporter - Monitor'
Start-ScheduledTask -TaskName 'PC Crash Reporter - Idle Helper' -ErrorAction SilentlyContinue
& (Join-Path $script:Root 'Report.ps1') -Force

Write-Host ''
Write-Host 'All set!' -ForegroundColor Green
Write-Host 'From now on, a report opens about a minute after you log in following every restart.'
Write-Host 'Reports are kept in:' (Join-Path $script:Root 'reports')
if (-not $Yes) { Read-Host 'Press Enter to close' | Out-Null }
