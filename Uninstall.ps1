<#
  PC Crash Reporter - uninstaller. Removes the scheduled tasks and desktop shortcuts.
  Your reports and logs stay in this folder unless you choose to delete them.
#>
param([switch]$Yes)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not (Test-IsAdmin)) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Yes) { $a += '-Yes' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    exit
}

$tasks = 'PC Crash Reporter - Monitor', 'PC Crash Reporter - Report', 'PC Crash Reporter - Make Report Now', 'PC Crash Reporter - Check Now'
foreach ($t in $tasks) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $t -Confirm:$false
        Write-Host "Removed task: $t"
    }
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*Monitor.ps1*' -and $_.CommandLine -like "*$($script:Root)*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host 'Stopped the monitor.' }

$desk = [Environment]::GetFolderPath('Desktop')
foreach ($n in 'PC Crash Report - Latest.lnk', 'PC Crash Report - Check Now.lnk') {
    $p = Join-Path $desk $n
    if (Test-Path $p) { Remove-Item $p -Force; Write-Host "Removed shortcut: $n" }
}

$del = $Yes
if (-not $Yes) { $del = (Read-Host 'Also delete saved reports and sensor logs? [y/N]') -match '^[Yy]' }
if ($del) {
    foreach ($d in $script:Paths.Logs, $script:Paths.Reports, $script:Paths.Data) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    }
    Write-Host 'Reports and logs deleted.'
}

Write-Host ''
Write-Host 'PC Crash Reporter is uninstalled. You can delete this folder now.' -ForegroundColor Green
Write-Host 'Note: PawnIO and WinDbg (if you installed them) stay installed - remove them from Settings -> Apps if you want.'
if (-not $Yes) { Read-Host 'Press Enter to close' | Out-Null }
