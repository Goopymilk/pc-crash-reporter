<#
  PC Crash Reporter - background sensor monitor.
  Started by Windows at boot (scheduled task, runs as SYSTEM). Every few seconds it records
  temperatures, power draw, fan speeds, voltages and load to a CSV file and flushes it to disk
  immediately, so the readings from right before a crash survive the crash.

  Test it by hand:  powershell -ExecutionPolicy Bypass -File Monitor.ps1 -Once
#>
param(
    [switch]$Once,          # take one sample, print it, exit
    [int]$Samples = 0       # take N samples then exit (0 = run forever)
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$cfg = Get-Config

# ---------- single instance ----------
if (-not $Once -and $Samples -eq 0) {
    $script:mutex = New-Object System.Threading.Mutex($false, 'Global\PCCrashReporterMonitor')
    $got = $false
    try { $got = $script:mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { Write-AppLog 'Monitor already running, exiting.' 'monitor'; exit 0 }
}

# ---------- sensor sources ----------
$script:Computer = $null
$script:SensorSource = 'windows-basic'

function Initialize-Lhm {
    $lib = Get-ChildItem -LiteralPath $script:Paths.Lhm -Recurse -Filter 'LibreHardwareMonitorLib.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $lib) { Write-AppLog 'LibreHardwareMonitor not found; using basic Windows sensors only.' 'monitor'; return }
    try {
        Get-ChildItem -LiteralPath $lib.DirectoryName -Filter '*.dll' | ForEach-Object {
            try { [void][Reflection.Assembly]::LoadFrom($_.FullName) } catch { }
        }
        $c = New-Object LibreHardwareMonitor.Hardware.Computer
        foreach ($p in 'IsCpuEnabled','IsGpuEnabled','IsMemoryEnabled','IsMotherboardEnabled','IsStorageEnabled','IsPsuEnabled','IsControllerEnabled','IsBatteryEnabled') {
            try { $c.$p = $true } catch { }
        }
        $c.Open()
        $script:Computer = $c
        $script:SensorSource = 'LibreHardwareMonitor'
        Write-AppLog ('LibreHardwareMonitor loaded from {0}' -f $lib.DirectoryName) 'monitor'
    } catch {
        Write-AppLog "Failed to start LibreHardwareMonitor: $($_.Exception.Message)" 'monitor'
    }
}

function Test-KeepSensor([string]$Type, [string]$Name, [string]$HwType) {
    switch ($Type) {
        'Temperature' { return ($Name -notmatch 'Resolution|Limit') }
        'Fan'         { return $true }
        'Power'       { return ($Name -notmatch '^Core #') }
        'Voltage'     { return ($Name -notmatch '^Core #') }
        'Load'        { return ($Name -match '^(CPU Total|GPU Core|GPU Memory Controller|Memory|Virtual Memory|GPU Video Engine|D3D 3D)$') }
        'Data'        { return ($Name -match '^(Memory Used|Memory Available)$') }
        'SmallData'   { return ($Name -match '^(GPU Memory Used|GPU Memory Total)$') }
        'Clock'       { return ($Name -match '^(GPU Core|GPU Memory|Cores \(Average\)|Core \(Average\))$') }
        'Level'       { return ($HwType -eq 'Storage' -or $HwType -eq 'Battery') }
        default       { return $false }
    }
}

function Add-HardwareReadings($Hw, $Out) {
    try { $Hw.Update() } catch { }
    foreach ($sub in $Hw.SubHardware) { Add-HardwareReadings $sub $Out }
    $hwType = [string]$Hw.HardwareType
    foreach ($s in $Hw.Sensors) {
        $v = $s.Value
        if ($null -eq $v) { continue }
        $f = [double]$v
        if ([double]::IsNaN($f) -or [double]::IsInfinity($f)) { continue }
        $type = [string]$s.SensorType
        if (-not (Test-KeepSensor $type $s.Name $hwType)) { continue }
        # 0 C means "no driver access", not a real reading
        if ($type -eq 'Temperature' -and ($f -le 0 -or $f -gt 150)) { continue }
        if ($hwType -eq 'Cpu' -and $type -in 'Power', 'Clock' -and $f -le 0) { continue }
        $key = '{0}~{1}|{2}|{3}' -f $hwType, ($Hw.Name -replace '[",|~]', ' '), $type, ($s.Name -replace '[",|~]', ' ')
        $k2 = $key; $n = 2
        while ($Out.Contains($k2)) { $k2 = "$key #$n"; $n++ }
        $Out[$k2] = [math]::Round($f, 1)
    }
}

$script:NvSmi = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source

function Add-BasicReadings($Out) {
    # Used when LibreHardwareMonitor is missing, and to fill gaps it leaves.
    $hasCpuLoad = @($Out.Keys | Where-Object { $_ -like 'Cpu~*|Load|CPU Total' }).Count -gt 0
    if (-not $hasCpuLoad) {
        try {
            $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
            $Out['Cpu~CPU|Load|CPU Total'] = [double]$p.PercentProcessorTime
        } catch { }
    }
    $hasMem = @($Out.Keys | Where-Object { $_ -like 'Memory~*|Load|Memory' }).Count -gt 0
    if (-not $hasMem) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $used = ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory)
            $Out['Memory~System Memory|Load|Memory'] = [math]::Round(100 * $used / $os.TotalVisibleMemorySize, 1)
            $Out['Memory~System Memory|Data|Memory Used'] = [math]::Round($used / 1MB, 1)
        } catch { }
    }
    $hasGpu = @($Out.Keys | Where-Object { $_ -like 'Gpu*' }).Count -gt 0
    if (-not $hasGpu -and $script:NvSmi) {
        try {
            $line = & $script:NvSmi --query-gpu=name,temperature.gpu,power.draw,utilization.gpu,fan.speed,memory.used,clocks.gr --format=csv,noheader,nounits 2>$null | Select-Object -First 1
            $f = $line -split '\s*,\s*'
            if ($f.Count -ge 7) {
                $name = $f[0] -replace '[",|~]', ' '
                $map = @{ 1 = 'Temperature|GPU Core'; 2 = 'Power|GPU Package'; 3 = 'Load|GPU Core'; 4 = 'Fan|GPU Fan %'; 5 = 'SmallData|GPU Memory Used'; 6 = 'Clock|GPU Core' }
                foreach ($i in $map.Keys) {
                    $d = 0.0
                    if ([double]::TryParse($f[$i], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
                        $Out["GpuNvidia~$name|$($map[$i])"] = [math]::Round($d, 1)
                    }
                }
            }
        } catch { }
    }
    $hasCpuTemp = @($Out.Keys | Where-Object { $_ -like 'Cpu~*|Temperature|*' }).Count -gt 0
    if (-not $hasCpuTemp) {
        try {
            $z = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | Select-Object -First 1
            if ($z) {
                $c = [math]::Round($z.CurrentTemperature / 10 - 273.15, 1)
                if ($c -gt 5 -and $c -lt 130) { $Out['Motherboard~ACPI Thermal Zone|Temperature|Thermal Zone (rough)'] = $c }
            }
        } catch { }
    }
}

function Get-Readings {
    $out = [ordered]@{}
    if ($script:Computer) {
        foreach ($hw in $script:Computer.Hardware) { Add-HardwareReadings $hw $out }
    }
    Add-BasicReadings $out
    return $out
}

# ---------- process snapshot (what was running) ----------
$script:LastProc = @{}
$script:LastProcTime = $null
$script:Cores = [Environment]::ProcessorCount

function Get-ProcessSnapshot {
    $now = Get-Date
    $procs = Get-Process -ErrorAction SilentlyContinue
    $cur = @{}
    $cpuList = @()
    foreach ($p in $procs) {
        $t = $null
        try { $t = $p.TotalProcessorTime.TotalSeconds } catch { }
        if ($null -eq $t) { continue }
        $cur[$p.Id] = $t
        if ($script:LastProcTime -and $script:LastProc.ContainsKey($p.Id)) {
            $dt = ($now - $script:LastProcTime).TotalSeconds
            if ($dt -gt 0) {
                $pct = 100 * ($t - $script:LastProc[$p.Id]) / ($dt * $script:Cores)
                if ($pct -gt 0.5) { $cpuList += [pscustomobject]@{ n = $p.ProcessName; v = [math]::Round($pct, 1) } }
            }
        }
    }
    $first = ($null -eq $script:LastProcTime)
    $script:LastProc = $cur
    $script:LastProcTime = $now
    if ($first) { return $null }
    $mem = $procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
        ForEach-Object { [pscustomobject]@{ n = $_.ProcessName; v = [math]::Round($_.WorkingSet64 / 1MB) } }
    return [pscustomobject]@{
        t   = $now.ToString('o')
        cpu = @($cpuList | Sort-Object v -Descending | Select-Object -First 5)
        mem = @($mem)
    }
}

# ---------- housekeeping ----------
function Remove-OldLogs {
    $cut = (Get-Date).AddDays(-[int]$cfg.KeepSensorLogDays)
    Get-ChildItem -LiteralPath $script:Paths.Sensors -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------- file writing ----------
$script:Writer = $null
$script:Stream = $null
$script:Header = $null
$script:ProcStream = $null
$script:ProcWriter = $null
$script:SessionStamp = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
$script:Part = 0

function Open-SensorFile([string[]]$Keys) {
    if ($script:Writer) { try { $script:Writer.Dispose() } catch { } }
    $script:Part++
    $suffix = ''
    if ($script:Part -gt 1) { $suffix = "_part$($script:Part)" }
    $path = Join-Path $script:Paths.Sensors ("sensors_{0}{1}.csv" -f $script:SessionStamp, $suffix)
    $script:Stream = New-Object IO.FileStream($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $script:Writer = New-Object IO.StreamWriter($script:Stream, (New-Object Text.UTF8Encoding($false)))
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
    $script:Writer.WriteLine("# source=$($script:SensorSource);boot=$boot;interval=$($cfg.SampleIntervalSeconds)")
    $script:Writer.WriteLine('"time",' + (($Keys | ForEach-Object { '"' + $_ + '"' }) -join ','))
    $script:Header = $Keys
}

function Write-Line([System.IO.StreamWriter]$W, [System.IO.FileStream]$S, [string]$Line) {
    $W.WriteLine($Line)
    $W.Flush()
    $S.Flush($true)   # force to physical disk so it survives a crash
}

function Write-ProcessSnapshot($Snap) {
    if (-not $Snap) { return }
    if (-not $script:ProcWriter) {
        $path = Join-Path $script:Paths.Sensors ("processes_{0}.jsonl" -f $script:SessionStamp)
        $script:ProcStream = New-Object IO.FileStream($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $script:ProcWriter = New-Object IO.StreamWriter($script:ProcStream, (New-Object Text.UTF8Encoding($false)))
    }
    Write-Line $script:ProcWriter $script:ProcStream ($Snap | ConvertTo-Json -Compress -Depth 4)
}

# ---------- main ----------
Initialize-Lhm

if ($Once) {
    $r = Get-Readings
    Write-Output "Sensor source: $($script:SensorSource)"
    $r.GetEnumerator() | ForEach-Object { '{0,-90} {1}' -f $_.Key, $_.Value }
    exit 0
}

Remove-OldLogs
Write-AppLog "Monitor started (source=$($script:SensorSource), interval=$($cfg.SampleIntervalSeconds)s)" 'monitor'
$interval = [math]::Max(1, [int]$cfg.SampleIntervalSeconds)
$nextProc = Get-Date
$count = 0
$inv = [Globalization.CultureInfo]::InvariantCulture

while ($true) {
    $start = Get-Date
    try {
        $r = Get-Readings
        $keys = @($r.Keys)
        if ($keys.Count -gt 0) {
            $newKeys = @($keys | Where-Object { $script:Header -notcontains $_ })
            if (-not $script:Header -or $newKeys.Count -gt 0) {
                $all = @(); if ($script:Header) { $all += $script:Header }; $all += $newKeys
                Open-SensorFile $all
            }
            $vals = foreach ($k in $script:Header) {
                if ($r.Contains($k)) { ([double]$r[$k]).ToString($inv) } else { '' }
            }
            Write-Line $script:Writer $script:Stream ($start.ToString('yyyy-MM-ddTHH:mm:ss') + ',' + ($vals -join ','))
        }
        if ($start -ge $nextProc) {
            Write-ProcessSnapshot (Get-ProcessSnapshot)
            $nextProc = $start.AddSeconds([int]$cfg.ProcessSnapshotSeconds)
        }
    } catch {
        Write-AppLog "Sample failed: $($_.Exception.Message)" 'monitor'
        Start-Sleep -Seconds 5
    }
    $count++
    if ($Samples -gt 0 -and $count -ge $Samples) { break }
    $elapsed = ((Get-Date) - $start).TotalMilliseconds
    $wait = [int]($interval * 1000 - $elapsed)
    if ($wait -gt 50) { Start-Sleep -Milliseconds $wait }
}

if ($script:Writer) { $script:Writer.Dispose() }
if ($script:ProcWriter) { $script:ProcWriter.Dispose() }
