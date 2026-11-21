<#
  Pause or resume PC Crash Reporter's background monitoring.
    Monitor-Control.ps1 -Pause     stop recording sensors (e.g. while a game's anti-cheat complains)
    Monitor-Control.ps1 -Resume    start recording again
    Monitor-Control.ps1 -Status    show whether it is running
  Needs administrator rights for -Pause/-Resume (asks automatically).
#>
param([switch]$Pause, [switch]$Resume, [switch]$Status)
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$task = 'PC Crash Reporter - Monitor'
if (($Pause -or $Resume) -and -not (Test-IsAdmin)) {
    $a = if ($Pause) { '-Pause' } else { '-Resume' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $a"
    exit 0
}
function Show-Status {
    $t = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host 'Monitoring is not installed (run Install.cmd).' -ForegroundColor Yellow; return }
    if (Test-Path $script:Paths.Paused) {
        $p = Get-Content $script:Paths.Paused -Raw | ConvertFrom-Json
        Write-Host "Monitoring is PAUSED (since $($p.Since)). Double-click Resume-Monitoring.cmd to turn it back on." -ForegroundColor Yellow
    } else {
        Write-Host "Monitoring is ON (task state: $($t.State))." -ForegroundColor Green
    }
}
if ($Pause) {
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue | Out-Null
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'Monitor\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    @{ Since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $script:Paths.Paused -Encoding ASCII
    Write-AppLog 'Monitoring paused by user' 'control'
    Write-Host ''
    Write-Host 'Monitoring is paused. Crash reports will still be made, but without temperature and power readings.' -ForegroundColor Yellow
    Write-Host 'It stays paused after restarts until you double-click Resume-Monitoring.cmd.'
} elseif ($Resume) {
    Enable-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue | Out-Null
    Start-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Remove-Item $script:Paths.Paused -Force -ErrorAction SilentlyContinue
    Write-AppLog 'Monitoring resumed by user' 'control'
    Write-Host ''
    Write-Host 'Monitoring is back on.' -ForegroundColor Green
} else { Show-Status }
if ($Pause -or $Resume) { Write-Host ''; Read-Host 'Press Enter to close' | Out-Null }
