# Shared helpers for PC Crash Reporter. Dot-source this file.
# Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).

$script:AppName = 'PC Crash Reporter'
$script:Root    = Split-Path -Parent $PSScriptRoot

$script:Paths = [ordered]@{
    Root       = $script:Root
    Config     = Join-Path $script:Root 'config.json'
    Logs       = Join-Path $script:Root 'logs'
    Sensors    = Join-Path $script:Root 'logs\sensors'
    AppLog     = Join-Path $script:Root 'logs\app.log'
    Reports    = Join-Path $script:Root 'reports'
    Data       = Join-Path $script:Root 'data'
    History    = Join-Path $script:Root 'data\history.csv'
    State      = Join-Path $script:Root 'data\state.json'
    Paused     = Join-Path $script:Root 'data\paused.json'
    Tools      = Join-Path $script:Root 'tools'
    Lhm        = Join-Path $script:Root 'tools\LibreHardwareMonitor'
    Symbols    = Join-Path $script:Root 'tools\symbols'
}

function Initialize-Folder([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

foreach ($k in 'Logs','Sensors','Reports','Data','Tools') { Initialize-Folder $script:Paths[$k] }

function Write-AppLog([string]$Message, [string]$Source = 'app') {
    try {
        $p = $script:Paths.AppLog
        if ((Test-Path $p) -and (Get-Item $p).Length -gt 2MB) {
            Move-Item $p "$p.old" -Force
        }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Source, $Message
        [IO.File]::AppendAllText($p, $line + [Environment]::NewLine)
    } catch { }
}

function Get-DefaultConfig {
    [ordered]@{
        SampleIntervalSeconds   = 5
        ProcessSnapshotSeconds  = 30
        KeepSensorLogDays       = 10
        KeepReportsDays         = 120
        OpenReportAfterEveryBoot = $true
        OpenReportOnlyIfProblems = $false
        PsuWatts                = 0
        UseDebuggerIfInstalled  = $true
        UseHardwareSensors      = $true
        Thresholds = [ordered]@{
            CpuTempWarn     = 90
            CpuTempCrit     = 97
            GpuTempWarn     = 83
            GpuTempCrit     = 90
            GpuHotspotWarn  = 100
            GpuHotspotCrit  = 108
            DriveTempWarn   = 65
            DriveTempCrit   = 75
            VrmTempWarn     = 100
            VrmTempCrit     = 110
            RamLoadWarn     = 90
            PsuLoadWarnPct  = 80
        }
    }
}

function Get-Config {
    $cfg = Get-DefaultConfig
    if (Test-Path $script:Paths.Config) {
        try {
            $user = Get-Content $script:Paths.Config -Raw | ConvertFrom-Json
            foreach ($p in $user.PSObject.Properties) {
                if ($p.Name -eq 'Thresholds' -and $p.Value) {
                    foreach ($t in $p.Value.PSObject.Properties) { $cfg.Thresholds[$t.Name] = $t.Value }
                } elseif ($p.Name -notlike '_*') {
                    $cfg[$p.Name] = $p.Value
                }
            }
        } catch {
            Write-AppLog "config.json could not be read, using defaults: $_"
        }
    }
    return $cfg
}

function ConvertTo-Html5Text([object]$Text) {
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function Format-Span([TimeSpan]$Span) {
    if ($Span.TotalSeconds -lt 0) { $Span = $Span.Negate() }
    if ($Span.TotalMinutes -lt 1) { $n = [int]$Span.TotalSeconds; return ('{0} second{1}' -f $n, $(if ($n -eq 1) { '' } else { 's' })) }
    if ($Span.TotalHours -lt 1)   { $n = [int][math]::Floor($Span.TotalMinutes); return ('{0} minute{1}' -f $n, $(if ($n -eq 1) { '' } else { 's' })) }
    if ($Span.TotalDays -lt 1)    { return ('{0} h {1} min' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes) }
    return ('{0} days {1} h' -f [int][math]::Floor($Span.TotalDays), $Span.Hours)
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-EventDataMap($Event) {
    # Returns a hashtable of named EventData values (unnamed ones get index keys).
    $map = @{}
    try {
        $xml = [xml]$Event.ToXml()
        $i = 0
        foreach ($d in $xml.Event.EventData.Data) {
            $name = $d.Name
            if (-not $name) { $name = [string]$i }
            $val = $d.'#text'
            if ($null -eq $val -and $d -is [string]) { $val = $d }
            $map[$name] = $val
            $i++
        }
    } catch { }
    return $map
}

# Background apps that hook into games or talk to hardware at a low level (process-name regex, friendly name, type)
$script:SideApps = @(
    @('^Discord$', 'Discord (in-game overlay)', 'overlay'), @('^RTSS$|RTSSHooksLoader', 'RivaTuner Statistics Server (on-screen display)', 'overlay'),
    @('^MSIAfterburner$', 'MSI Afterburner', 'tuning'), @('^Overwolf', 'Overwolf', 'overlay'), @('^NVIDIA Overlay$|^nvcontainer$', 'NVIDIA overlay / app', 'overlay'),
    @('^GameBar$|^GameBarFTServer$', 'Xbox Game Bar', 'overlay'), @('^gameoverlayui', 'Steam overlay', 'overlay'), @('^EpicOverlay|^EOSOverlayRenderer', 'Epic Games overlay', 'overlay'),
    @('^RadeonSoftware$|^AMDRSServ$', 'AMD Radeon Software (overlay / tuning)', 'tuning'), @('^iCUE$|^Corsair\.Service', 'Corsair iCUE', 'rgb'),
    @('^ArmouryCrate|^AsusCertService|^LightingService$', 'ASUS Armoury Crate', 'rgb'), @('^SignalRgb', 'SignalRGB', 'rgb'), @('^OpenRGB$', 'OpenRGB', 'rgb'),
    @('^NZXT CAM$|^CAM$', 'NZXT CAM', 'rgb'), @('^wallpaper(32|64)$', 'Wallpaper Engine', 'overlay'), @('^HWiNFO(32|64)?$', 'HWiNFO', 'monitoring'),
    @('^lghub|^LGHUB', 'Logitech G HUB', 'rgb'), @('^Razer Synapse|^RazerCentral', 'Razer Synapse', 'rgb'), @('^MSI\.CentralServer|^MSI Center|^MSI_Central', 'MSI Center', 'rgb'),
    @('^GCC$|GigabyteControlCenter|^RGBFusion|^GBT', 'Gigabyte Control Center / RGB Fusion', 'rgb'), @('^AIDA64$', 'AIDA64', 'monitoring'),
    @('^EVGAPrecision|^PrecisionX', 'EVGA Precision', 'tuning'), @('^ThunderMaster', 'Thermaltake software', 'rgb'), @('^Lian.?Li|^L-Connect', 'Lian Li L-Connect', 'rgb'),
    @('^Medal$', 'Medal.tv (clip recording)', 'overlay'), @('^obs64$', 'OBS (recording)', 'overlay'), @('^Ryzen ?Master|^AMDRyzenMaster', 'AMD Ryzen Master', 'tuning'),
    @('^XTU|^XtuService', 'Intel Extreme Tuning Utility', 'tuning'), @('^FanControl$', 'Fan Control', 'monitoring'), @('^SteelSeriesGG|^SteelSeriesEngine', 'SteelSeries GG', 'rgb')
)
function Get-SideAppMatches([string[]]$ProcessNames) {
    $out = @()
    foreach ($a in $script:SideApps) {
        if (@($ProcessNames | Where-Object { $_ -match $a[0] }).Count) { $out += [pscustomobject]@{ Name = $a[1]; Type = $a[2] } }
    }
    return $out
}