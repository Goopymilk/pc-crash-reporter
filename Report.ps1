<#
  PC Crash Reporter - builds a plain-English HTML report about the previous Windows session.
  Runs automatically ~1 minute after you log in following a restart (scheduled task).
  Run by hand any time:  Run-Report-Now.cmd   (or  .\Report.ps1 -Force)
#>
param(
    [switch]$Force,     # build even if a report for this boot already exists
    [switch]$NoOpen,    # do not open the report in the browser
    [switch]$CurrentSession, # health check of the session that is running now (no reboot needed)
    [ValidateSet('', 'bsod', 'powerloss')][string]$Demo = ''  # show an example crash report using live data (nothing is saved to history)
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Knowledge.ps1')
. (Join-Path $PSScriptRoot 'lib\DumpParser.ps1')

$cfg = Get-Config
if ($Demo) { $CurrentSession = [switch]$true }
$Th = $cfg.Thresholds
$now = Get-Date
$isAdmin = Test-IsAdmin
$os = Get-CimInstance Win32_OperatingSystem
$currentBoot = $os.LastBootUpTime
$bootId = $currentBoot.ToString('yyyy-MM-ddTHH:mm:ss')
$inv = [Globalization.CultureInfo]::InvariantCulture

# ------------------------------------------------------------------ run once per boot
$state = @{ LastReportedBoot = '' }
if (Test-Path $script:Paths.State) {
    try { $s = Get-Content $script:Paths.State -Raw | ConvertFrom-Json; if ($s.LastReportedBoot) { $state.LastReportedBoot = $s.LastReportedBoot } } catch { }
}
if (-not $Force -and -not $CurrentSession -and $state.LastReportedBoot -eq $bootId) {
    Write-AppLog 'Report already built for this boot - skipping.' 'report'
    exit 0
}
Write-AppLog "Building report for boot $bootId (admin=$isAdmin)" 'report'

# ------------------------------------------------------------------ previous session window
$bootEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 12 } -MaxEvents 40 -ErrorAction SilentlyContinue)
$prevBoot = $null
$curIdx = -1
for ($i = 0; $i -lt $bootEvents.Count; $i++) {
    if ([math]::Abs(($bootEvents[$i].TimeCreated - $currentBoot).TotalSeconds) -lt 180) { $curIdx = $i; break }
}
if ($curIdx -ge 0 -and $curIdx + 1 -lt $bootEvents.Count) { $prevBoot = $bootEvents[$curIdx + 1].TimeCreated }
elseif ($curIdx -lt 0) {
    $p = $bootEvents | Where-Object { $_.TimeCreated -lt $currentBoot.AddSeconds(-30) } | Select-Object -First 1
    if ($p) { $prevBoot = $p.TimeCreated }
}
$prevKnown = [bool]$prevBoot
if (-not $prevBoot) { $prevBoot = $currentBoot.AddDays(-2) }
$sessionEndRef = $currentBoot
if ($CurrentSession) { $prevBoot = $currentBoot; $prevKnown = $true; $sessionEndRef = $now }

$lastSystemEvent = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $prevBoot; EndTime = $sessionEndRef.AddSeconds(-1) } -MaxEvents 1 -ErrorAction SilentlyContinue
$lastAlive = $null
if ($lastSystemEvent) { $lastAlive = $lastSystemEvent.TimeCreated }

# ------------------------------------------------------------------ collect events
$sysEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $prevBoot; Level = 1, 2, 3 } -ErrorAction SilentlyContinue)
$sysInfo = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $prevBoot; Id = 1074, 6006, 6008, 13, 1101, 1102, 1201, 1202 } -ErrorAction SilentlyContinue)
$appEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $prevBoot; Level = 1, 2, 3 } -ErrorAction SilentlyContinue)
$werEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $prevBoot; ProviderName = 'Windows Error Reporting'; Id = 1001 } -ErrorAction SilentlyContinue)

$seenRec = @{}
$allSys = foreach ($e in ($sysEv + $sysInfo)) { if (-not $seenRec.ContainsKey("S$($e.RecordId)")) { $seenRec["S$($e.RecordId)"] = 1; $e } }
$allSys = @($allSys)

# ------------------------------------------------------------------ how did the last session end?
$afterBoot = $currentBoot.AddMinutes(-3)
$ev41   = $allSys | Where-Object { $_.Id -eq 41 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.TimeCreated -ge $afterBoot } | Select-Object -First 1
$ev6008 = $allSys | Where-Object { $_.Id -eq 6008 -and $_.TimeCreated -ge $afterBoot } | Select-Object -First 1
$evBug  = $allSys | Where-Object { $_.Id -eq 1001 -and $_.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting' -and $_.TimeCreated -ge $afterBoot } | Select-Object -First 1
$ev1074 = $allSys | Where-Object { $_.Id -eq 1074 -and $_.TimeCreated -lt $sessionEndRef -and $_.TimeCreated -ge $prevBoot } | Select-Object -First 1
$ev13   = $allSys | Where-Object { $_.Id -eq 13 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-General' -and $_.TimeCreated -lt $sessionEndRef -and $_.TimeCreated -ge $prevBoot } | Select-Object -First 1

$kind = 'unknown'
$bugCode = $null
$bugParams = @()
$d41 = @{}
if ($ev41) { $d41 = Get-EventDataMap $ev41 }

if ($evBug) {
    $m = [regex]::Match($evBug.Message, '0x([0-9a-fA-F]{1,8})\s*\(([^)]*)\)')
    if ($m.Success) {
        $bugCode = [Convert]::ToInt64($m.Groups[1].Value, 16)
        $bugParams = @($m.Groups[2].Value -split '\s*,\s*')
    }
}
if (-not $bugCode -and $d41['BugcheckCode'] -and [int64]$d41['BugcheckCode'] -ne 0) {
    $bugCode = [int64]$d41['BugcheckCode']
    $bugParams = @('BugcheckParameter1', 'BugcheckParameter2', 'BugcheckParameter3', 'BugcheckParameter4' | ForEach-Object { $d41[$_] })
}

# crash dumps written since the previous boot
$dumps = @()
$dumpAccess = $true
try {
    $files = @()
    if (Test-Path 'C:\Windows\Minidump') { $files += @(Get-ChildItem 'C:\Windows\Minidump' -Filter '*.dmp' -ErrorAction Stop | Where-Object { $_.LastWriteTime -ge $prevBoot }) }
    $full = Get-Item 'C:\Windows\MEMORY.DMP' -ErrorAction SilentlyContinue
    if ($full -and $full.LastWriteTime -ge $prevBoot -and $files.Count -eq 0) { $files += $full }
    foreach ($f in ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
        $d = Read-CrashDump $f.FullName
        $d | Add-Member -NotePropertyName Cdb -NotePropertyValue $null
        if ($cfg.UseDebuggerIfInstalled -and $dumps.Count -eq 0) {
            $d.Cdb = Invoke-CdbAnalysis $f.FullName $script:Paths.Symbols
        }
        $dumps += $d
    }
} catch { $dumpAccess = $false }

if (-not $bugCode -and $dumps.Count -gt 0 -and $dumps[0].BugCheckCode) { $bugCode = [int64]$dumps[0].BugCheckCode }

if ($bugCode) { $kind = 'bsod' }
elseif ($ev41) {
    $pb = $d41['PowerButtonTimestamp']
    $sl = $d41['SleepInProgress']
    if ($pb -and $pb -ne '0') { $kind = 'powerbutton' }
    elseif ($sl -and $sl -ne '0' -and $sl -ne 'false') { $kind = 'sleepfail' }
    else { $kind = 'powerloss' }
}
elseif ($ev6008) { $kind = 'powerloss' }
elseif ($ev1074 -or $ev13) { $kind = 'clean' }
if (-not $prevKnown -and $kind -eq 'unknown') { $kind = 'nohistory' }
if ($CurrentSession) { $kind = 'running'; $bugCode = $null }
if ($Demo) {
    $kind = $Demo
    if ($Demo -eq 'bsod') {
        $bugCode = 0x116; $bugParams = @('0xffffa58f2a4b9010', '0xfffff8074e2f8e04', '0xffffffffc000009a', '0x0000000000000004')
        $dumps = @([pscustomobject]@{ Path = 'C:\Windows\Minidump\EXAMPLE-123456-7890-01.dmp'; Time = $now; SizeMB = 1.4; BugCheckCode = 0x116; Params = @()
            DumpType = 4; StackDrivers = @('nvlddmkm.sys', 'dxgkrnl.sys', 'watchdog.sys', 'ntoskrnl.exe'); CrashAddressDriver = 'nvlddmkm.sys'
            ProbableDriver = 'nvlddmkm.sys'; Method = 'demo'; Error = $null; Cdb = $null })
    }
}

# when did it end?
$endTime = $null
if ($ev6008) {
    try {
        $raw = ('{0} {1}' -f $ev6008.Properties[1].Value, $ev6008.Properties[0].Value) -replace '[^\x20-\x7E]', ''
        $endTime = [datetime]::Parse($raw)
    } catch { }
}
if (-not $endTime -and $ev13) { $endTime = $ev13.TimeCreated }
if (-not $endTime) { $endTime = $lastAlive }
if (-not $endTime) { $endTime = $currentBoot }
if ($CurrentSession) { $endTime = $now }

$cleanInfo = $null
if ($ev1074) {
    $pv = @($ev1074.Properties | ForEach-Object { $_.Value })
    $proc = Split-Path ([string]$pv[0] -replace '\s*\(.*$', '') -Leaf
    $cleanInfo = [pscustomobject]@{ Process = $proc; Reason = [string]$pv[2]; Type = [string]$pv[4]; User = [string]$pv[6] }
}

# ------------------------------------------------------------------ findings from events
$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Sev, [string]$Title, [string]$Plain, [object[]]$Steps = @(), [int]$Count = 1,
          $First = $null, $Last = $null, [string]$Detail = '', [string]$Key = '', [string]$Area = 'Windows')
    $script:findings.Add([pscustomobject]@{ Sev = $Sev; Title = $Title; Plain = $Plain; Steps = @($Steps); Count = $Count
        First = $First; Last = $Last; Detail = $Detail; Key = $Key; Area = $Area; SeenBefore = 0 })
}

$noise = @{}
$otherWarnings = 0
$handled = @('Microsoft-Windows-Kernel-Power|41', 'EventLog|6008', 'Microsoft-Windows-WER-SystemErrorReporting|1001', 'User32|1074', 'EventLog|6006', 'Microsoft-Windows-Kernel-General|13')

function Get-ShortMessage($E, [int]$Max = 600) {
    $m = $null
    try { $m = $E.Message } catch { }
    if (-not $m) { $m = '(no message text - provider not installed)' }
    $m = ($m -replace '\r', '' -replace '\n{2,}', "`n").Trim()
    if ($m.Length -gt $Max) { $m = $m.Substring(0, $Max) + ' ...' }
    return $m
}

# System log (excluding things handled elsewhere)
$sysGroups = $allSys | Where-Object { $_.Level -in 1, 2, 3 -or $_.Id -in 1101, 1102, 1201, 1202 } | Group-Object { "$($_.ProviderName)|$($_.Id)" }
foreach ($g in $sysGroups) {
    $key = $g.Name
    if ($handled -contains $key) { continue }
    $ev = @($g.Group | Sort-Object TimeCreated)
    $parts = $key -split '\|'
    $kb = Get-EventKBEntry $parts[0] ([int]$parts[1])
    $sample = Get-ShortMessage $ev[-1]
    $detail = "Source: $($parts[0])  |  Event ID: $($parts[1])  |  Log: System`nLatest message:`n$sample"
    if ($kb) {
        $title = $kb.Title
        if ($parts[0] -eq 'Service Control Manager') {
            $svc = @($ev | ForEach-Object { try { [string]$_.Properties[0].Value } catch { } } | Where-Object { $_ } | Select-Object -Unique)
            if ($svc.Count -gt 0) { $title = "$title ($(($svc | Select-Object -First 3) -join ', '))" }
        }
        Add-Finding -Sev $kb.Sev -Title $title -Plain $kb.Plain -Steps $kb.Steps -Count $ev.Count -First $ev[0].TimeCreated -Last $ev[-1].TimeCreated -Detail $detail -Key $key -Area 'System'
    } elseif (Test-NoiseEvent $parts[0] ([int]$parts[1])) {
        $noise[$key] = $ev.Count
    } elseif ($ev[0].Level -eq 3) {
        $otherWarnings += $ev.Count
    } else {
        Add-Finding -Sev 'info' -Title "Error from $($parts[0]) (event $($parts[1]))" `
            -Plain "Windows logged an error from `"$($parts[0])`". This one is not in the tool's list of known problems. If it repeats a lot, or happens at the same time as your problems, search the web for: $($parts[0]) event $($parts[1])" `
            -Count $ev.Count -First $ev[0].TimeCreated -Last $ev[-1].TimeCreated -Detail $detail -Key $key -Area 'Other'
    }
}

# Application log
$appCrash = $appEv | Where-Object { $_.ProviderName -eq 'Application Error' -and $_.Id -eq 1000 }
foreach ($g in ($appCrash | Group-Object { $p = $_.Properties; "$($p[0].Value)|$($p[3].Value)" })) {
    $ev = @($g.Group | Sort-Object TimeCreated)
    $p = $ev[-1].Properties
    $app = [string]$p[0].Value; $mod = [string]$p[3].Value; $exc = ([string]$p[6].Value).ToLower() -replace '^0x', ''
    $excText = $script:ExceptionKB[$exc]
    if (-not $excText) { $excText = "Error code 0x$exc." }
    $mi = Get-ModuleInfo $mod
    $plain = "The program $app closed unexpectedly. The error happened in $mod"
    if ($mi) { $plain += " ($($mi.What))" }
    $plain += ". $excText"
    $steps = @()
    if ($mi) { $steps += $mi.Steps }
    $steps += "Update or reinstall $app. If it is a game, use the launcher's ""Verify/Repair game files"" option."
    $steps += 'Turn off overlays (Discord, Steam, GeForce/AMD overlay, MSI Afterburner/RivaTuner) as a test.'
    $sev = 'info'; if ($ev.Count -ge 3) { $sev = 'warning' }
    Add-Finding -Sev $sev -Title "$app crashed" -Plain $plain -Steps $steps -Count $ev.Count -First $ev[0].TimeCreated -Last $ev[-1].TimeCreated `
        -Detail ("Program: $app`nFaulting module: $mod`nException code: 0x$exc`n" + (Get-ShortMessage $ev[-1] 900)) -Key "AppCrash|$app" -Area 'Programs'
}
$appHang = $appEv | Where-Object { $_.ProviderName -eq 'Application Hang' -and $_.Id -eq 1002 }
foreach ($g in ($appHang | Group-Object { [string]$_.Properties[0].Value })) {
    $ev = @($g.Group | Sort-Object TimeCreated)
    Add-Finding -Sev 'info' -Title "$($g.Name) froze (Not Responding) and was closed" `
        -Plain 'The program stopped responding and was closed (by you or by Windows). Occasional freezes are usually a program problem; frequent freezes across many programs can point to a slow/failing drive or low memory.' `
        -Steps @("Update or reinstall $($g.Name).") -Count $ev.Count -First $ev[0].TimeCreated -Last $ev[-1].TimeCreated -Detail (Get-ShortMessage $ev[-1]) -Key "AppHang|$($g.Name)" -Area 'Programs'
}
$dotnet = $appEv | Where-Object { $_.ProviderName -eq '.NET Runtime' -and $_.Id -eq 1026 }
foreach ($g in ($dotnet | Group-Object { if ($_.Message -match 'Application:\s*(\S+)') { $matches[1] } else { 'unknown' } })) {
    $ev = @($g.Group | Sort-Object TimeCreated)
    Add-Finding -Sev 'info' -Title "$($g.Name) crashed (.NET error)" -Plain 'A program written in .NET hit an error it did not handle and closed.' `
        -Steps @("Update or reinstall $($g.Name).", 'Install the latest .NET Desktop Runtime from Microsoft.') -Count $ev.Count -First $ev[0].TimeCreated -Last $ev[-1].TimeCreated `
        -Detail (Get-ShortMessage $ev[-1] 900) -Key "DotNet|$($g.Name)" -Area 'Programs'
}
foreach ($g in ($appEv | Where-Object { -not ($_.ProviderName -in 'Application Error', 'Application Hang', '.NET Runtime') } | Group-Object { "$($_.ProviderName)|$($_.Id)" })) {
    $parts = $g.Name -split '\|'
    $ev = @($g.Group | Sort-Object TimeCreated)
    if (Test-NoiseEvent $parts[0] ([int]$parts[1])) { $noise[$g.Name] = $ev.Count; continue }
    if ($ev[0].Level -eq 3) { $otherWarnings += $ev.Count; continue }
    Add-Finding -Sev 'info' -Title "Program error from $($parts[0]) (event $($parts[1]))" `
        -Plain "A program or service called `"$($parts[0])`" logged an error. These are usually only important if that program is misbehaving." `
        -Count $ev.Count -First $ev[0].TimeCreated -Last $ev[-1].TimeCreated -Detail ("Source: $($parts[0]) | Event ID: $($parts[1]) | Log: Application`n" + (Get-ShortMessage $ev[-1])) -Key $g.Name -Area 'Other'
}

# Live kernel events = GPU hangs Windows recovered from
$lke = @($werEv | Where-Object { $_.Message -match 'LiveKernelEvent' })
foreach ($g in ($lke | Group-Object { if ($_.Message -match '(?m)P1:\s*([0-9a-fA-F]+)') { $matches[1].ToLower() } else { '?' } })) {
    $ev = @($g.Group | Sort-Object TimeCreated)
    $txt = $script:LiveKernelKB[$g.Name]
    if (-not $txt) { $txt = "Windows recorded a hardware/driver hang (code $($g.Name)) and recovered without a blue screen." }
    $gpuish = $g.Name -in '141', '117', '1a8', '193', '1b8', '15f', '1a1'
    $steps = @(); if ($gpuish) { $steps = @('GpuDriver', 'GpuOc', 'GpuTemps', 'GpuPower') }
    Add-Finding -Sev 'warning' -Title $(if ($gpuish) { 'Graphics card froze and was reset' } else { "Hardware hang detected (LiveKernelEvent $($g.Name))" }) `
        -Plain "$txt Your screen may have gone black or frozen for a few seconds. If these happen often, they can lead to full crashes." `
        -Steps $steps -Count $ev.Count -First $ev[0].TimeCreated -Last $ev[-1].TimeCreated -Detail (Get-ShortMessage $ev[-1] 900) -Key "LiveKernel|$($g.Name)" -Area 'Graphics'
}

# ------------------------------------------------------------------ sensor data
$sensorFiles = @(Get-ChildItem $script:Paths.Sensors -Filter 'sensors_*.csv' -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.BaseName -match '^sensors_(\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d)') {
        $st = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd_HH-mm-ss', $inv)
        if ($st -ge $prevBoot.AddMinutes(-2) -and $st -lt $sessionEndRef) { [pscustomobject]@{ File = $_; Start = $st } }
    }
} | Sort-Object { $_.File.Name })

$series = @{}       # key -> @{ T = List[datetime]; V = List[double] }
$sensorSource = $null
foreach ($sf in $sensorFiles) {
    $fs = [IO.File]::Open($sf.File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $sr = New-Object IO.StreamReader($fs)
    $hdr = $null
    while ($null -ne ($line = $sr.ReadLine())) {
        if ($line.Length -eq 0) { continue }
        if ($line[0] -eq '#') { if ($line -match 'source=([^;]+)') { $sensorSource = $matches[1] }; continue }
        if ($line.StartsWith('"time"')) {
            $hdr = @($line.Substring(1, $line.Length - 2) -split '","')
            for ($i = 1; $i -lt $hdr.Count; $i++) {
                if (-not $series.ContainsKey($hdr[$i])) { $series[$hdr[$i]] = @{ T = New-Object System.Collections.Generic.List[datetime]; V = New-Object System.Collections.Generic.List[double] } }
            }
            continue
        }
        if (-not $hdr) { continue }
        $f = $line.Split(',')
        $t = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($f[0], 'yyyy-MM-ddTHH:mm:ss', $inv, [Globalization.DateTimeStyles]::None, [ref]$t)) { continue }
        $n = [math]::Min($f.Count, $hdr.Count)
        for ($i = 1; $i -lt $n; $i++) {
            if ($f[$i].Length -eq 0) { continue }
            $v = 0.0
            if ([double]::TryParse($f[$i], [Globalization.NumberStyles]::Float, $inv, [ref]$v)) {
                $s = $series[$hdr[$i]]; $s.T.Add($t); $s.V.Add($v)
            }
        }
    }
    $sr.Dispose()
}
# keep each series in time order (files can overlap) and drop fixed limit values that are not real readings
foreach ($key in @($series.Keys)) {
    if ($key -match '\|Temperature\|.*(Resolution|Limit)') { $series.Remove($key); continue }
    $s = $series[$key]
    $ta = $s.T.ToArray(); $va = $s.V.ToArray()
    [Array]::Sort($ta, $va)
    $s.T.Clear(); $s.T.AddRange($ta); $s.V.Clear(); $s.V.AddRange($va)
}
$hasSensors = $series.Count -gt 0

function Find-SensorKey([string]$HwPattern, [string]$Type, [string[]]$Names, [string]$Exclude = '') {
    $cands = @($series.Keys | Where-Object {
        $p = $_ -split '\|'
        $p.Count -ge 3 -and $p[0] -match $HwPattern -and $p[1] -eq $Type -and $series[$_].V.Count -gt 0 -and (-not $Exclude -or $_ -notmatch $Exclude)
    } | Sort-Object)
    foreach ($n in $Names) {
        if ($n -eq '*') { if ($cands.Count) { return $cands[0] } else { return $null } }
        $m = $cands | Where-Object { ($_ -split '\|')[2] -eq $n } | Select-Object -First 1
        if ($m) { return $m }
    }
    return $null
}

function Get-Stats([string]$Key) {
    if (-not $Key -or -not $series.ContainsKey($Key)) { return $null }
    $s = $series[$Key]; $n = $s.V.Count
    if ($n -eq 0) { return $null }
    $max = [double]::MinValue; $maxAt = $null; $sum = 0.0
    for ($i = 0; $i -lt $n; $i++) { $v = $s.V[$i]; $sum += $v; if ($v -gt $max) { $max = $v; $maxAt = $s.T[$i] } }
    if ($Key -like '*|Power|*' -and $max -le 0) { return $null }   # 0 W = sensor not readable
    $lastT = $s.T[$n - 1]
    $endMax = [double]::MinValue
    for ($i = $n - 1; $i -ge 0 -and $s.T[$i] -ge $lastT.AddSeconds(-60); $i--) { if ($s.V[$i] -gt $endMax) { $endMax = $s.V[$i] } }
    return [pscustomobject]@{ Key = $Key; Avg = $sum / $n; Max = $max; MaxAt = $maxAt; Last = $s.V[$n - 1]; LastT = $lastT; EndMax = $endMax; Count = $n }
}

$SensorKey = [ordered]@{
    CpuTemp  = Find-SensorKey '^Cpu~' 'Temperature' @('Core (Tctl/Tdie)', 'CPU Package', 'Package', 'Tctl', 'Core Max', 'CPU Core', '*')
    GpuTemp  = Find-SensorKey '^Gpu' 'Temperature' @('GPU Core', '*') 'Hot Spot|Memory Junction'
    GpuHot   = Find-SensorKey '^Gpu' 'Temperature' @('GPU Hot Spot')
    CpuPower = Find-SensorKey '^Cpu~' 'Power' @('Package', 'CPU Package', '*')
    GpuPower = Find-SensorKey '^Gpu' 'Power' @('GPU Package', 'GPU Power', 'GPU Board Power', '*')
    CpuLoad  = Find-SensorKey '^Cpu~' 'Load' @('CPU Total')
    GpuLoad  = Find-SensorKey '^Gpu' 'Load' @('GPU Core', 'D3D 3D')
    MemLoad  = Find-SensorKey '^Memory~' 'Load' @('Memory') 'Virtual'
}
$cpuTempRough = $false
if (-not $SensorKey.CpuTemp) { $SensorKey.CpuTemp = Find-SensorKey '^Motherboard~' 'Temperature' @('Thermal Zone (rough)'); $cpuTempRough = [bool]$SensorKey.CpuTemp }
$Stat = @{}
foreach ($k in $SensorKey.Keys) { $Stat[$k] = Get-Stats $SensorKey[$k] }

# sensor-based findings
function Test-TempFinding($St, [string]$What, [double]$Warn, [double]$Crit, [string[]]$Steps) {
    if (-not $St) { return }
    $t = '{0:0} C' -f $St.Max
    $when = $St.MaxAt.ToString('HH:mm')
    if ($St.Max -ge $Crit) {
        Add-Finding -Sev 'critical' -Title "$What got dangerously hot ($t)" -Plain "$What reached $t at $when. Above $Crit C, parts slow themselves down or the PC may shut off to protect itself." -Steps $Steps -Key "Temp|$What" -Area 'Temperatures'
    } elseif ($St.Max -ge $Warn) {
        Add-Finding -Sev 'warning' -Title "$What ran hot ($t)" -Plain "$What peaked at $t at $when. That is within its limits but on the high side - better cooling helps stability and lifespan." -Steps $Steps -Key "Temp|$What" -Area 'Temperatures'
    }
}
if ($hasSensors) {
    if (-not $cpuTempRough) { Test-TempFinding $Stat.CpuTemp 'The CPU' $Th.CpuTempWarn $Th.CpuTempCrit @('Cooling', 'CpuOc') }
    Test-TempFinding $Stat.GpuTemp 'The graphics card' $Th.GpuTempWarn $Th.GpuTempCrit @('GpuTemps', 'Cooling', 'GpuOc')
    Test-TempFinding $Stat.GpuHot 'The graphics card hot spot' $Th.GpuHotspotWarn $Th.GpuHotspotCrit @('GpuTemps', 'Cooling')
    if ($Stat.MemLoad -and $Stat.MemLoad.Max -ge $Th.RamLoadWarn) {
        Add-Finding -Sev 'warning' -Title ('RAM was almost full ({0:0}% used)' -f $Stat.MemLoad.Max) `
            -Plain 'Your memory was nearly full at some point. When that happens, the PC gets slow, programs can freeze or close, and games can stutter.' `
            -Steps @('Close programs you are not using (browsers with many tabs use a lot), and check Task Manager -> Processes sorted by Memory.') -Key 'MemFull' -Area 'Memory'
    }
    # drives
    $driveHw = @($series.Keys | Where-Object { $_ -like 'Storage~*|Temperature|*' } | ForEach-Object { ($_ -split '\|')[0] } | Select-Object -Unique)
    foreach ($hw in $driveHw) {
        $name = $hw -replace '^Storage~', ''
        $tk = Find-SensorKey ([regex]::Escape($hw) + '$') 'Temperature' @('Composite Temperature', 'Temperature', '*') 'Warning|Critical'
        $st = Get-Stats $tk
        if (-not $st) { continue }
        $wk = Get-Stats (Find-SensorKey ([regex]::Escape($hw) + '$') 'Temperature' @('Warning Temperature'))
        $ck = Get-Stats (Find-SensorKey ([regex]::Escape($hw) + '$') 'Temperature' @('Critical Temperature'))
        $warn = $Th.DriveTempWarn; $crit = $Th.DriveTempCrit
        if ($wk -and $wk.Last -gt 40) { $warn = [math]::Min($warn, $wk.Last - 3) }
        if ($ck -and $ck.Last -gt 50) { $crit = [math]::Min($crit, $ck.Last - 3) }
        Test-TempFinding $st "The drive $name" $warn $crit @('Cooling', 'Put a heatsink on the M.2 drive (many motherboards include one) or improve airflow over it.')
    }
}
$psuNote = $null
$peakPower = $null
if ($Stat.CpuPower -or $Stat.GpuPower) {
    # combine CPU + GPU power per timestamp
    $sum = @{}
    foreach ($k in @($SensorKey.CpuPower, $SensorKey.GpuPower)) {
        if (-not $k) { continue }
        $s = $series[$k]
        for ($i = 0; $i -lt $s.V.Count; $i++) { $ts = $s.T[$i]; if ($sum.ContainsKey($ts)) { $sum[$ts] += $s.V[$i] } else { $sum[$ts] = $s.V[$i] } }
    }
    $peakPower = ($sum.Values | Measure-Object -Maximum).Maximum
    $series['Calc~Estimate|Power|CPU + GPU'] = @{ T = New-Object System.Collections.Generic.List[datetime]; V = New-Object System.Collections.Generic.List[double] }
    foreach ($ts in ($sum.Keys | Sort-Object)) { $series['Calc~Estimate|Power|CPU + GPU'].T.Add($ts); $series['Calc~Estimate|Power|CPU + GPU'].V.Add($sum[$ts]) }
    $est = $peakPower + 60
    if ([int]$cfg.PsuWatts -gt 0) {
        $pct = 100 * $est / [int]$cfg.PsuWatts
        if ($pct -ge $Th.PsuLoadWarnPct) {
            Add-Finding -Sev 'warning' -Title ('Power supply was heavily loaded (~{0:0}% of {1} W)' -f $pct, $cfg.PsuWatts) `
                -Plain ('Your CPU + graphics card drew up to {0:0} W (about {1:0} W for the whole PC). Short spikes can be much higher than these 5-second readings, so a PSU running this close to its limit can shut off under load.' -f $peakPower, $est) `
                -Steps @('Psu') -Key 'PsuLoad' -Area 'Power'
        }
    } else {
        $psuNote = ('Peak CPU + graphics power was {0:0} W (about {1:0} W for the whole PC). Tell the tool your power supply wattage (PsuWatts in config.json) and it will warn you if that is too close to the limit.' -f $peakPower, $est)
    }
}

# last process snapshot (what was running)
$lastProcs = $null
if ($sensorFiles.Count -gt 0) {
    $stamp = ($sensorFiles[-1].File.BaseName -replace '^sensors_', '' -replace '_part\d+$', '')
    $pf = Join-Path $script:Paths.Sensors "processes_$stamp.jsonl"
    if (Test-Path $pf) {
        $ll = Get-Content $pf -Tail 1 -ErrorAction SilentlyContinue
        if ($ll) { try { $lastProcs = $ll | ConvertFrom-Json } catch { } }
    }
}

# ------------------------------------------------------------------ drives & system info
$drives = @()
try {
    foreach ($pd in (Get-PhysicalDisk -ErrorAction Stop)) {
        $rc = $null; try { $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
        $drives += [pscustomobject]@{
            Name = $pd.FriendlyName; Type = [string]$pd.MediaType; Bus = [string]$pd.BusType; SizeGB = [math]::Round($pd.Size / 1GB)
            Health = [string]$pd.HealthStatus; Status = (@($pd.OperationalStatus) -join ', ')
            Temp = $(if ($rc) { $rc.Temperature }); TempMax = $(if ($rc) { $rc.TemperatureMax }); Wear = $(if ($rc) { $rc.Wear })
            ReadErr = $(if ($rc) { $rc.ReadErrorsUncorrected }); Hours = $(if ($rc) { $rc.PowerOnHours })
        }
    }
} catch { }
foreach ($d in $drives) {
    if ($d.Health -and $d.Health -ne 'Healthy') {
        Add-Finding -Sev 'critical' -Title "Drive '$($d.Name)' reports it is $($d.Health)" -Plain 'Windows says this drive is not healthy. It may fail soon.' -Steps @('DiskBackup', 'DiskCheck') -Key "DriveHealth|$($d.Name)" -Area 'Drives'
    }
    if ($d.Wear -and [int]$d.Wear -ge 90) {
        Add-Finding -Sev 'warning' -Title "Drive '$($d.Name)' is $($d.Wear)% worn out" -Plain 'SSDs can only be written a certain amount. This one is near the end of its rated life.' -Steps @('DiskBackup', 'Plan to replace this drive.') -Key "DriveWear|$($d.Name)" -Area 'Drives'
    }
    if ($d.ReadErr -and [int64]$d.ReadErr -gt 0) {
        Add-Finding -Sev 'warning' -Title "Drive '$($d.Name)' has had read errors it could not fix ($($d.ReadErr))" -Plain 'The drive could not read some data at some point in its life. If this number goes up, the drive is getting worse.' -Steps @('DiskBackup', 'DiskCheck') -Key "DriveReadErr|$($d.Name)" -Area 'Drives'
    }
}

$sys = [ordered]@{}
try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $sys['Windows'] = '{0} {1} (build {2}.{3})' -f $os.Caption, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR
} catch { $sys['Windows'] = $os.Caption }
try { $sys['Processor'] = ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name).Trim() } catch { }
$gpuOld = @()
try {
    foreach ($v in (Get-CimInstance Win32_VideoController)) {
        $age = ''
        if ($v.DriverDate) {
            $days = ($now - $v.DriverDate).TotalDays
            $age = ' - driver dated {0:yyyy-MM-dd}' -f $v.DriverDate
            if ($days -gt 365 -and $v.Name -match 'NVIDIA|AMD|Radeon|Intel\(R\) Arc') { $gpuOld += $v.Name }
        }
        $sys["Graphics ($($v.Name))"] = "driver $($v.DriverVersion)$age"
    }
} catch { }
try {
    $bb = Get-CimInstance Win32_BaseBoard; $bios = Get-CimInstance Win32_BIOS
    $sys['Motherboard'] = "$($bb.Manufacturer) $($bb.Product)"
    $biosDate = $bios.ReleaseDate
    $biosVer = "$($bios.SMBIOSBIOSVersion)".Trim()
    $sys['BIOS'] = $biosVer
    if ($biosDate) {
        $ageDays = ($now - $biosDate).TotalDays
        $ageTxt = if ($ageDays -ge 730) { '{0:0} years' -f [math]::Floor($ageDays / 365) } elseif ($ageDays -ge 365) { 'over a year' } else { '{0:0} months' -f [math]::Max(1, [math]::Floor($ageDays / 30.4)) }
        $sys['BIOS'] = '{0} (released {1:MMMM yyyy}, {2} ago)' -f $biosVer, $biosDate, $ageTxt
        if ($ageDays -gt 365) {
            $board = "$($bb.Manufacturer) $($bb.Product)".Trim()
            $sev = 'info'; if ($kind -in 'bsod', 'powerloss', 'sleepfail') { $sev = 'warning' }
            Add-Finding -Sev $sev -Title ('Your BIOS is {0} old (version {1}, {2:MMMM yyyy})' -f $ageTxt, $biosVer, $biosDate) `
                -Plain 'Motherboard makers regularly release BIOS updates that fix crashes, improve RAM compatibility (especially EXPO/XMP and mixed sticks) and improve CPU support. A newer version is probably available for your board.' `
                -Steps @("Check for a newer BIOS: search the web for ""$board BIOS"" and open the support page on the maker's own website. Compare the newest version there with yours ($biosVer).",
                         'Bios',
                         'Before updating, read the maker''s instructions. Use a USB stick, and never turn the PC off during the update.') -Key 'BiosOld' -Area 'System'
        }
    }
} catch { }
$ramNote = $null
try {
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $totalGB = [math]::Round((($mods | Measure-Object Capacity -Sum).Sum) / 1GB)
    $sizes = ($mods | ForEach-Object { '{0} GB' -f [math]::Round($_.Capacity / 1GB) }) -join ' + '
    $type = switch ([int]$mods[0].SMBIOSMemoryType) { 34 { 'DDR5' } 26 { 'DDR4' } 24 { 'DDR3' } default { 'RAM' } }
    $cfgSpeed = [int]$mods[0].ConfiguredClockSpeed
    $stdMax = switch ($type) { 'DDR5' { 5600 } 'DDR4' { 3200 } 'DDR3' { 1600 } default { 0 } }
    $ratedList = @($mods | ForEach-Object { Get-RamRatedSpeed $_.PartNumber } | Where-Object { $_ })
    $rated = $null; if ($ratedList.Count -eq $mods.Count) { $rated = ($ratedList | Measure-Object -Minimum).Minimum }
    $xmp = $stdMax -gt 0 -and $cfgSpeed -gt $stdMax
    $sys['Memory'] = "$totalGB GB $type ($sizes) running at $cfgSpeed MT/s"
    if ($rated) { $sys['Memory'] += " - rated for $rated MT/s" }
    $sys['Memory'] += $(if ($xmp) { ' - EXPO/XMP is ON' } else { ' - EXPO/XMP is off' })
    if ($xmp) {
        $sev = 'info'; if ($kind -in 'bsod', 'powerloss', 'sleepfail', 'powerbutton') { $sev = 'warning' }
        Add-Finding -Sev $sev -Title "Memory overclock (EXPO/XMP) is on ($cfgSpeed MT/s)" `
            -Plain "Your RAM runs at $cfgSpeed MT/s. The standard $type speed is up to $stdMax, so a memory overclock profile (EXPO on AMD, XMP on Intel) is turned on in the BIOS. This is normal for gaming PCs and is usually fine. But it is also the most common cause of random blue screens, so if you ever get crashes, turning it off is the first test." `
            -Steps @('RamXmp', 'RamTest') -Key 'RamXmpOn' -Area 'Memory'
    }
    if ($rated -and $cfgSpeed -gt $rated + 50) {
        Add-Finding -Sev 'warning' -Title "RAM runs faster than it is rated for ($cfgSpeed vs $rated MT/s)" `
            -Plain "Your RAM sticks are rated for $rated MT/s, but they are running at $cfgSpeed MT/s. That is a manual memory overclock beyond what the sticks are sold for, and it can cause crashes and file corruption." `
            -Steps @("Set the RAM back to its rated speed ($rated) in the BIOS, or load the EXPO/XMP profile instead of manual settings.", 'RamTest') -Key 'RamBeyondRated' -Area 'Memory'
    } elseif ($rated -and $cfgSpeed -lt $rated - 100) {
        $mixNote = ''
        if (@($ratedList | Select-Object -Unique).Count -gt 1) { $mixNote = ' Your sticks have different ratings, so the slower one would set the limit anyway.' }
        Add-Finding -Sev 'info' -Title "Your RAM could run faster ($cfgSpeed of $rated MT/s)" `
            -Plain "Your RAM is rated for $rated MT/s but is running at $cfgSpeed MT/s, because EXPO/XMP is off. This is the most stable setting, so there is nothing wrong. Turning EXPO/XMP on in the BIOS would make some games a few percent faster.$mixNote If your sticks don't match, leaving it off is the safer choice." `
            -Steps @() -Key 'RamBelowRated' -Area 'Memory'
    }
    $distinct = @($mods | ForEach-Object { "$($_.Capacity)|$($_.Speed)|$($_.PartNumber)".Trim() } | Select-Object -Unique)
    if ($mods.Count -gt 1 -and $distinct.Count -gt 1) {
        $sev = 'info'; if ($kind -in 'bsod', 'powerloss') { $sev = 'warning' }
        Add-Finding -Sev $sev -Title "Your RAM sticks don't match ($sizes)" `
            -Plain 'Mixing RAM sticks of different sizes or models usually works, but it is a well-known cause of random crashes - especially with EXPO/XMP turned on. Matched kits are much more reliable.' `
            -Steps @('RamTest', 'If you get random blue screens, test with only one stick installed for a few days, then the other.', 'Long term: replace with a matched kit (2 identical sticks bought together).') -Key 'RamMismatch' -Area 'Memory'
    }
} catch { }
if ($gpuOld.Count -gt 0) {
    Add-Finding -Sev 'info' -Title 'Your graphics driver is more than a year old' -Plain "The driver for $($gpuOld -join ', ') is over a year old. New drivers fix crashes and improve game performance." -Steps @('GpuDriver') -Key 'GpuDriverOld' -Area 'Graphics'
}
$pawnInstalled = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\PawnIO'
if ($hasSensors -and (-not $SensorKey.CpuTemp -or $cpuTempRough)) {
    Add-Finding -Sev 'info' -Title 'CPU temperature is not being recorded' `
        -Plain 'The monitor cannot read your CPU temperature and power yet. This needs the free PawnIO driver.' `
        -Steps @('Run Install.cmd again and say yes when it offers to install PawnIO, then restart.') -Key 'NoCpuTemp' -Area 'Setup'
}

# ------------------------------------------------------------------ fans that stopped while hot
function Get-TimeMap([string]$Key) {
    $map = @{}
    if ($Key -and $series.ContainsKey($Key)) { $s = $series[$Key]; for ($i = 0; $i -lt $s.V.Count; $i++) { $map[$s.T[$i]] = $s.V[$i] } }
    return $map
}
$fanRows = @()
if ($hasSensors) {
    $cpuMap = Get-TimeMap $SensorKey.CpuTemp
    $gpuMap = Get-TimeMap $SensorKey.GpuTemp
    foreach ($fk in @($series.Keys | Where-Object { ($_ -split '\|')[1] -eq 'Fan' } | Sort-Object)) {
        $fs = $series[$fk]; if ($fs.V.Count -lt 3) { continue }
        $fmax = ($fs.V | Measure-Object -Maximum).Maximum
        if ($fmax -lt 200) { continue }   # never spun: nothing plugged in, or a fan that stays off on purpose
        $p = $fk -split '\|'; $hwType = ($p[0] -split '~')[0]; $hwName = ($p[0] -split '~', 2)[-1]
        $isGpuFan = $hwType -like 'Gpu*'
        $fanName = if ($isGpuFan) { "graphics card fan ($($p[2]))" } else { "$($p[2]) (motherboard header)" }
        if ($isGpuFan) { $tmap = $gpuMap; $part = 'the graphics card'; $hot = 70; $warnT = $Th.GpuTempWarn }
        elseif ($p[2] -match 'CPU|Pump|AIO|OPT') { $tmap = $cpuMap; $part = 'the CPU'; $hot = 70; $warnT = $Th.CpuTempWarn }
        else { $tmap = $cpuMap; $part = 'the CPU'; $hot = 80; $warnT = $Th.CpuTempWarn }
        $st = Get-Stats $fk
        $fanRows += [pscustomobject]@{ Name = $fanName; Stat = $st }
        if ($tmap.Count -eq 0) { continue }
        $spun = $false; $hits = @()
        for ($i = 0; $i -lt $fs.V.Count; $i++) {
            $v = $fs.V[$i]
            if ($v -ge 200) { $spun = $true; continue }
            if ($spun -and $v -lt 50 -and $tmap.ContainsKey($fs.T[$i]) -and $tmap[$fs.T[$i]] -ge $hot) { $hits += [pscustomobject]@{ T = $fs.T[$i]; Temp = $tmap[$fs.T[$i]] } }
        }
        if ($hits.Count -ge 2) {
            $peakT = ($hits | Measure-Object Temp -Maximum).Maximum
            $sev = 'warning'; if ($peakT -ge $warnT) { $sev = 'critical' }
            Add-Finding -Sev $sev -Title "A fan stopped while $part was hot: $fanName" `
                -Plain ("The {0} had been spinning, then read 0 RPM while {1} was at {2:0} C (first at {3:HH:mm}, {4} readings in total). A fan that stops under load usually means it has failed, its cable came loose, or something is blocking it. That makes parts overheat, which can cause slowdowns and sudden shutdowns." -f $fanName, $part, $peakT, $hits[0].T, $hits.Count) `
                -Steps @('With the side panel off and the PC running, check that this fan actually spins. Use a flashlight - do not touch the blades.',
                         'Check that the fan cable is pushed firmly into the motherboard (or graphics card) and that no cable is touching the blades.',
                         'In the BIOS fan settings, make sure this fan is not set to stop (0%) at high temperatures.',
                         'If the fan does not spin, replace it. Case and CPU fans are cheap; graphics card fans can be bought as replacement parts or repaired under warranty.') `
                -Key "FanStopped|$($p[0])|$($p[2])" -Area 'Cooling'
        }
    }
}

# ------------------------------------------------------------------ CPU overclock check
$cpuBoost = Get-CpuMaxBoost $sys['Processor']
$clkKey = Find-SensorKey '^Cpu~' 'Clock' @('Cores (Max)', 'Cores (Average)')
if ($clkKey) {
    $clk = $series[$clkKey]
    $peakClk = ($clk.V | Measure-Object -Maximum).Maximum
    if ($cpuBoost) {
        $sys['Processor'] += (' - normal top speed {0} MHz, highest seen {1:0} MHz' -f $cpuBoost.Mhz, $peakClk)
        $limit = $cpuBoost.Mhz + 100
        $over = @($clk.V | Where-Object { $_ -gt $limit }).Count
        if ($over -ge 3) {
            $sev = 'info'; if ($kind -in 'bsod', 'powerloss', 'sleepfail', 'powerbutton') { $sev = 'warning' }
            Add-Finding -Sev $sev -Title ('Your CPU runs faster than stock ({0:0} MHz vs {1} MHz)' -f $peakClk, $cpuBoost.Mhz) `
                -Plain ("Your {0} normally tops out at {1} MHz, but it reached {2:0} MHz ({3} readings above stock). That means a CPU overclock is on - on AMD usually PBO with a boost override, on Intel a raised multiplier. Overclocks can seem stable for weeks and still cause occasional crashes. (Undervolts such as Curve Optimizer can't be detected, but they cause the same kind of crashes.)" -f $cpuBoost.Model, $cpuBoost.Mhz, $peakClk, $over) `
                -Steps @('CpuOc') -Key 'CpuOverclock' -Area 'CPU'
        }
    } else {
        $sys['Processor'] += (' - highest speed seen {0:0} MHz' -f $peakClk)
    }
}

# ------------------------------------------------------------------ recent changes (updates, drivers, programs)
$chEnd = $endTime; if ($CurrentSession) { $chEnd = $now }
$chStart = $chEnd.AddDays(-7)
$changes = New-Object System.Collections.Generic.List[object]
$storeUpdates = 0
try {
    foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19; StartTime = $chStart; EndTime = $chEnd } -ErrorAction SilentlyContinue)) {
        $title = (Get-EventDataMap $e)['updateTitle']
        if (-not $title) { continue }
        if ($title -match '^[0-9A-Z]{12}-') { $storeUpdates++; continue }   # Microsoft Store app updates - routine
        $kindTxt = 'Windows update'
        if ($title -match 'Driver|Display|Graphics|Audio|Network|Firmware|System -|Extension') { $kindTxt = 'Driver (Windows Update)' }
        $changes.Add([pscustomobject]@{ Time = $e.TimeCreated; Type = $kindTxt; Name = $title; Detail = '' })
    }
} catch { }
try {
    $pnpNames = @{}
    $drv = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Kernel-PnP/Configuration'; Id = 400; StartTime = $chStart; EndTime = $chEnd } -ErrorAction SilentlyContinue)
    foreach ($g in ($drv | ForEach-Object { $m = Get-EventDataMap $_; if ($m['DeviceUpdated'] -eq 'true' -and $m['DriverInbox'] -eq 'false') { [pscustomobject]@{ E = $_; M = $m } } } | Group-Object { "$($_.M['DriverPackageId'])|$($_.M['DriverVersion'])" })) {
        $first = $g.Group | Sort-Object { $_.E.TimeCreated } | Select-Object -First 1
        $m = $first.M
        $id = $m['DeviceInstanceId']
        $dev = $null
        try { $dev = (Get-PnpDevice -InstanceId $id -ErrorAction Stop).FriendlyName } catch { }
        if (-not $dev) { $dev = ($m['DriverPackageId'] -replace '\.inf_.*$', '') }
        $extra = ''; if ($g.Count -gt 1) { $extra = " (+$($g.Count - 1) more devices)" }
        $changes.Add([pscustomobject]@{ Time = $first.E.TimeCreated; Type = 'Driver installed/updated'; Name = "$dev$extra"
            Detail = "version $($m['DriverVersion']) by $($m['DriverProvider'])" })
    }
} catch { }
$msiNames = @{}
try {
    foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 1033, 1034; StartTime = $chStart; EndTime = $chEnd } -ErrorAction SilentlyContinue)) {
        if ($e.Message -match 'Product Name:\s*(.+?)\.\s*Product Version:\s*([^\s]+?)\.\s') {
            $n = $matches[1].Trim(); $ver = $matches[2]
            $msiNames[$n] = $true
            $changes.Add([pscustomobject]@{ Time = $e.TimeCreated; Type = $(if ($e.Id -eq 1033) { 'Program installed' } else { 'Program removed' }); Name = $n; Detail = "version $ver" })
        }
    }
} catch { }
try {
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $seenApp = @{}
    foreach ($a in (Get-ItemProperty $roots -ErrorAction SilentlyContinue)) {
        if (-not $a.DisplayName -or -not $a.InstallDate -or $a.SystemComponent -eq 1 -or $a.ParentKeyName) { continue }
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$a.InstallDate, 'yyyyMMdd', $inv, [Globalization.DateTimeStyles]::None, [ref]$d)) { continue }
        if ($d -lt $chStart.Date -or $d -gt $chEnd) { continue }
        if ($msiNames.ContainsKey($a.DisplayName) -or $seenApp.ContainsKey($a.DisplayName)) { continue }
        $seenApp[$a.DisplayName] = $true
        $changes.Add([pscustomobject]@{ Time = $d; Type = 'Program installed/updated'; Name = $a.DisplayName; Detail = $(if ($a.DisplayVersion) { "version $($a.DisplayVersion)" } else { '' }); DateOnly = $true })
    }
} catch { }
$changes = @($changes | Sort-Object Time -Descending)

# ------------------------------------------------------------------ crash details
$crash = $null
if ($kind -eq 'bsod') {
    $bi = Get-BugCheckInfo $bugCode
    $dump = $dumps | Select-Object -First 1
    $drv = $null; $drvSource = $null
    if ($dump -and $dump.Cdb -and $dump.Cdb.ImageName) { $drv = $dump.Cdb.ImageName; $drvSource = 'WinDbg analysis' }
    elseif ($dump -and $dump.ProbableDriver) { $drv = $dump.ProbableDriver; $drvSource = 'best guess from the crash dump' }
    $di = Get-DriverInfo $drv
    $crash = [pscustomobject]@{ Info = $bi; Params = $bugParams; Dump = $dump; Driver = $drv; DriverSource = $drvSource; DriverInfo = $di }
}

# ------------------------------------------------------------------ history / error index
$historyCols = 'SessionStart', 'SessionEnd', 'Outcome', 'StopCode', 'StopName', 'Driver', 'Verdict', 'Report'
$history = @()
if (Test-Path $script:Paths.History) { $history = @(Import-Csv $script:Paths.History) }
$sessionKey = $prevBoot.ToString('yyyy-MM-ddTHH:mm:ss')
$history = @($history | Where-Object { $_.SessionStart -ne $sessionKey })
$recent = @($history | Where-Object { try { [datetime]::Parse($_.SessionStart, $inv) -ge $now.AddDays(-30) } catch { $false } })
$prevBad = @($recent | Where-Object { $_.Outcome -in 'bsod', 'powerloss', 'powerbutton', 'sleepfail' })

$indexPath = Join-Path $script:Paths.Data 'error-index.csv'
$errIndex = @()
if (Test-Path $indexPath) { $errIndex = @(Import-Csv $indexPath | Where-Object { $_.SessionStart -ne $sessionKey }) }
foreach ($f in $findings) {
    if ($f.Key) { $f.SeenBefore = @($errIndex | Where-Object { $_.Key -eq $f.Key } | Select-Object -ExpandProperty SessionStart -Unique).Count }
}

# ------------------------------------------------------------------ verdict + where to start
$sevRank = @{ critical = 0; warning = 1; info = 2 }
$sorted = @($findings | Sort-Object @{ e = { $sevRank[$_.Sev] } }, @{ e = { -$_.Count } })
$nCrit = @($findings | Where-Object Sev -eq 'critical').Count
$nWarn = @($findings | Where-Object Sev -eq 'warning').Count

$endedAtCrash = $kind -in 'bsod', 'powerloss', 'sleepfail', 'powerbutton'
$tempsAtEnd = @()
$hotAtEnd = $false
if ($hasSensors -and $endedAtCrash) {
    foreach ($pair in @(@('CPU', $Stat.CpuTemp, $Th.CpuTempWarn), @('graphics card', $Stat.GpuTemp, $Th.GpuTempWarn), @('GPU hot spot', $Stat.GpuHot, $Th.GpuHotspotWarn))) {
        if ($pair[1]) {
            $tempsAtEnd += ('{0} {1:0} C' -f $pair[0], $pair[1].EndMax)
            if ($pair[1].EndMax -ge $pair[2]) { $hotAtEnd = $true }
        }
    }
}
$gap = $null
if ($hasSensors -and $endedAtCrash) {
    $lastSample = ($Stat.Values | Where-Object { $_ } | Sort-Object LastT -Descending | Select-Object -First 1).LastT
    if ($lastSample) { $gap = $endTime - $lastSample }
}

$headline = ''; $story = @(); $start = New-Object System.Collections.Generic.List[string]
$verdict = 'good'
switch ($kind) {
    'bsod' {
        $verdict = 'bad'
        $headline = 'Your PC crashed with a blue screen'
        $story += "Windows hit a serious error and had to stop (a ""blue screen of death""). The stop code was <b>$($crash.Info.Name)</b> ($($crash.Info.Code))."
        $story += $crash.Info.Plain
        if ($crash.Driver) {
            $story += "The driver most involved was <b>$(ConvertTo-Html5Text $crash.Driver)</b> - $(ConvertTo-Html5Text $crash.DriverInfo.What) ($($crash.DriverSource))."
            if ($crash.Driver -notmatch '^(ntoskrnl|hal|ntkrnlmp)') { foreach ($s in (Resolve-Steps $crash.DriverInfo.Steps)) { $start.Add($s) } }
        }
        foreach ($s in (Resolve-Steps $crash.Info.Steps)) { $start.Add($s) }
    }
    'powerloss' {
        $verdict = 'bad'
        $headline = 'Your PC turned off or restarted without warning'
        $story += 'Windows did not shut down normally and there was <b>no blue screen</b>. That means the power was cut, the PC reset itself instantly, or it froze so hard it could not even show an error.'
        if ($hasSensors -and $tempsAtEnd.Count) {
            if ($hotAtEnd) {
                $story += "Right before it happened, temperatures were <b>high</b> ($($tempsAtEnd -join ', ')). Overheating is a likely cause - PCs shut themselves off to avoid damage."
                $start.Add($script:Step.Cooling)
            } else {
                $story += "Right before it happened, temperatures were normal ($($tempsAtEnd -join ', ')), so overheating is unlikely."
            }
        }
        $story += 'The most common causes of sudden shutdowns are: a weak or failing power supply, loose power cables, an unstable overclock / EXPO memory profile, or a power cut / bad power strip.'
        $start.Add('Did the power flicker, or did someone bump the power cable or switch? If so, this one may not be a PC problem. If it keeps happening, carry on with the steps below.')
        foreach ($s in (Resolve-Steps @('Psu', 'GpuPower', 'CpuOc', 'RamXmp', 'Bios'))) { $start.Add($s) }
    }
    'powerbutton' {
        $verdict = 'warn'
        $headline = 'Your PC was switched off with the power button'
        $story += 'The power button was held down (or pressed) to force the PC off. If you did that because the PC was <b>frozen</b>, the freeze is the real problem - the clues below may explain it.'
        $start.Add('If the PC was frozen: note what you were doing (game, video, idle). Freezes with picture stuck are usually graphics driver, RAM or overclock problems.')
        foreach ($s in (Resolve-Steps @('GpuDriver', 'RamXmp', 'RamTest'))) { $start.Add($s) }
    }
    'sleepfail' {
        $verdict = 'bad'
        $headline = 'Your PC crashed while going to sleep or waking up'
        $story += 'Windows was in the middle of entering or leaving sleep when it failed. This is usually a driver that does not handle sleep properly (graphics, Wi-Fi, USB or chipset).'
        foreach ($s in (Resolve-Steps @('Chipset', 'GpuDriver', 'NetDriver', 'Bios'))) { $start.Add($s) }
        $start.Add('As a workaround, turn off Fast Startup: Control Panel -> Power Options -> "Choose what the power buttons do" -> untick "Turn on fast startup".')
    }
    'clean' {
        $headline = 'Your PC shut down normally'
        $how = 'Windows shut down / restarted the normal way.'
        if ($cleanInfo) {
            $who = $cleanInfo.Process
            if ($who -match 'TrustedInstaller|musnotification|MoUsoCoreWorker|wuauclt|UsoClient|svchost') { $how = 'Windows restarted to install <b>updates</b>.' }
            elseif ($who -match 'StartMenuExperienceHost|explorer|winlogon|shutdown|SearchHost') { $how = "You chose <b>$($cleanInfo.Type)</b> from Windows." }
            else { $how = "Restart/shutdown was started by <b>$(ConvertTo-Html5Text $who)</b> ($(ConvertTo-Html5Text $cleanInfo.Type))." }
        }
        $story += $how
    }
    'running' {
        $headline = 'Health check of the session that is running now'
        $story += 'This is a live check of everything since Windows last started (no restart involved). Use it after gaming or when the PC feels unstable.'
    }
    'nohistory' {
        $headline = 'First report - nothing to compare yet'
        $story += 'This is the first report, so there is no earlier session to look at in detail. From the next restart on, you will get a full report.'
    }
    default {
        $verdict = 'warn'
        $headline = 'Could not tell how the last session ended'
        $story += 'There were no shutdown or crash records for the last session. This can happen after a Windows update, if logs were cleared, or with Fast Startup.'
    }
}
if ($gap -and $gap.TotalSeconds -ge 0 -and $gap.TotalMinutes -lt 30) {
    $story += "The sensor monitor's last reading was <b>$(Format-Span $gap)</b> before the PC went down, so the ""Right before it ended"" readings below show what the PC was doing at that moment."
}
if ($nCrit -gt 0) { $verdict = 'bad' } elseif ($nWarn -gt 0 -and $verdict -eq 'good') { $verdict = 'warn' }
if ($kind -eq 'clean' -and $verdict -ne 'good') { $headline = 'Your PC shut down normally, but some problems were found' }

if ($endedAtCrash) {
    $prio = @{ 'Driver installed/updated' = 0; 'Driver (Windows Update)' = 0; 'Windows update' = 1 }
    $recentCh = @($changes | Where-Object { $_.Time -ge $endTime.AddDays(-3).Date -and $_.Type -ne 'Program removed' } |
        Sort-Object @{ e = { if ($prio.ContainsKey($_.Type)) { $prio[$_.Type] } else { 2 } } }, @{ e = { $_.Time }; Descending = $true } | Select-Object -First 3)
    if ($recentCh.Count) {
        $list = ($recentCh | ForEach-Object { '{0} ({1}, {2:MMM d})' -f $_.Name, $_.Type.ToLower(), $_.Time }) -join '; '
        $start.Insert([math]::Min(1, $start.Count), "Things changed in the 3 days before this happened: $list. If your crashes only started after one of these, undo it as a test. For a driver: Device Manager -> right-click the device -> Properties -> Driver -> Roll Back Driver. For a Windows update: Settings -> Windows Update -> Update history -> Uninstall updates. For a program: uninstall it. See ""What changed recently"" below.")
    }
}
foreach ($f in $sorted | Where-Object { $_.Sev -ne 'info' }) { foreach ($s in (Resolve-Steps $f.Steps)) { $start.Add($s) } }
if ($prevBad.Count -ge 1 -and $endedAtCrash) {
    $codes = @($prevBad | Where-Object { $_.StopCode } | Group-Object StopCode | Sort-Object Count -Descending)
    if ($crash -and ($codes | Where-Object { $_.Name -eq $crash.Info.Code })) {
        $start.Insert(0, "This same blue screen ($($crash.Info.Name)) has happened before in the last 30 days - that is a strong pattern, so focus on the steps for it.")
    }
}
$startList = @($start | Select-Object -Unique | Select-Object -First 7)
$crashCount30 = $prevBad.Count + [int]$endedAtCrash

# ------------------------------------------------------------------ HTML helpers
function Esc([object]$t) { ConvertTo-Html5Text $t }
function Get-SevBadge([string]$Sev) {
    switch ($Sev) {
        'critical' { '<span class="badge crit"><span aria-hidden="true">&#10006;</span> Serious</span>' }
        'warning'  { '<span class="badge warn"><span aria-hidden="true">&#9888;</span> Warning</span>' }
        default    { '<span class="badge info"><span aria-hidden="true">&#8505;</span> FYI</span>' }
    }
}
function Format-When($d) { if ($d) { ([datetime]$d).ToString('ddd MMM d, HH:mm') } else { '' } }

function New-LineChart([string]$Title, [string]$Key, [string]$Unit, [double]$Warn = [double]::NaN, [datetime]$EndAt = [datetime]::MinValue, [bool]$Zero = $true) {
    if (-not $Key -or -not $series.ContainsKey($Key)) { return '' }
    $s = $series[$Key]; $n = $s.V.Count
    if ($n -lt 2) { return '' }
    # downsample to <= 300 points, keeping the peak of each bucket
    $maxPts = 300; $bucket = [math]::Ceiling($n / $maxPts)
    $CT = New-Object System.Collections.Generic.List[datetime]; $CV = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $n; $i += $bucket) {
        $bi = $i; $bv = $s.V[$i]
        for ($j = $i; $j -lt [math]::Min($i + $bucket, $n); $j++) { if ($s.V[$j] -gt $bv) { $bv = $s.V[$j]; $bi = $j } }
        $CT.Add($s.T[$bi]); $CV.Add($bv)
    }
    $W = 640; $Hh = 190; $l = 44; $r = 14; $t = 14; $b = 28
    $t0 = $CT[0]; $t1 = $CT[$CT.Count - 1]
    if ($EndAt -gt $t1 -and ($EndAt - $t1).TotalMinutes -lt 30) { $t1 = $EndAt }
    $span = [math]::Max(1, ($t1 - $t0).TotalSeconds)
    $vmax = ($CV | Measure-Object -Maximum).Maximum; $vmin = ($CV | Measure-Object -Minimum).Minimum
    if (-not [double]::IsNaN($Warn) -and $Warn -le $vmax * 1.25) { $vmax = [math]::Max($vmax, $Warn) }
    $lo = if ($Zero) { 0 } else { [math]::Floor(([math]::Min($vmin, 30)) / 10) * 10 }
    $rawStep = ($vmax - $lo) / 4; if ($rawStep -le 0) { $rawStep = 1 }
    $mag = [math]::Pow(10, [math]::Floor([math]::Log10($rawStep)))
    $step = (@(1, 2, 2.5, 5, 10) | ForEach-Object { $_ * $mag } | Where-Object { $_ -ge $rawStep } | Select-Object -First 1)
    $hi = $lo + [math]::Ceiling(($vmax - $lo) / $step) * $step
    if ($hi -le $lo) { $hi = $lo + $step }
    $px = { param($tt) $l + ($W - $l - $r) * (($tt - $t0).TotalSeconds / $span) }
    $py = { param($vv) $t + ($Hh - $t - $b) * (1 - ($vv - $lo) / ($hi - $lo)) }
    $sb = New-Object Text.StringBuilder
    $xs = @(); $ys = @(); $labels = @(); $vals = @()
    $pts = for ($i = 0; $i -lt $CT.Count; $i++) {
        $x = [math]::Round((& $px $CT[$i]), 1); $y = [math]::Round((& $py $CV[$i]), 1)
        $xs += $x; $ys += $y; $labels += $CT[$i].ToString('HH:mm:ss'); $vals += [math]::Round($CV[$i], 1)
        '{0},{1}' -f $x.ToString($inv), $y.ToString($inv)
    }
    $data = @{ x = $xs; y = $ys; t = $labels; v = $vals; u = $Unit } | ConvertTo-Json -Compress
    [void]$sb.Append("<figure class=""chart""><figcaption>$(Esc $Title)</figcaption><div class=""plot"">")
    [void]$sb.Append("<svg viewBox=""0 0 $W $Hh"" role=""img"" aria-label=""$(Esc $Title) over the session"" data-chart='$($data -replace "'", '&#39;')'>")
    for ($g = $lo; $g -le $hi + 0.001; $g += $step) {
        $yy = [math]::Round((& $py $g), 1).ToString($inv)
        [void]$sb.Append("<line class=""grid"" x1=""$l"" x2=""$($W - $r)"" y1=""$yy"" y2=""$yy""/><text class=""ax"" x=""$($l - 6)"" y=""$yy"" dy=""4"" text-anchor=""end"">$([math]::Round($g, 1))</text>")
    }
    for ($k = 0; $k -le 4; $k++) {
        $tt = $t0.AddSeconds($span * $k / 4)
        $xx = [math]::Round((& $px $tt), 1).ToString($inv)
        $anchor = 'middle'; if ($k -eq 0) { $anchor = 'start' } elseif ($k -eq 4) { $anchor = 'end' }
        [void]$sb.Append("<text class=""ax"" x=""$xx"" y=""$($Hh - 8)"" text-anchor=""$anchor"">$($tt.ToString('HH:mm'))</text>")
    }
    if (-not [double]::IsNaN($Warn) -and $Warn -le $hi) {
        $wy = [math]::Round((& $py $Warn), 1).ToString($inv)
        [void]$sb.Append("<line class=""thr"" x1=""$l"" x2=""$($W - $r)"" y1=""$wy"" y2=""$wy""/><text class=""thrlbl"" x=""$($W - $r - 4)"" y=""$wy"" dy=""-5"" text-anchor=""end"">warning level $Warn $Unit</text>")
    }
    if ($EndAt -ne [datetime]::MinValue -and $EndAt -ge $t0 -and $EndAt -le $t1.AddSeconds(1)) {
        $ex = [math]::Round((& $px $EndAt), 1).ToString($inv)
        [void]$sb.Append("<line class=""endline"" x1=""$ex"" x2=""$ex"" y1=""$t"" y2=""$($Hh - $b)""/><text class=""endlbl"" x=""$ex"" y=""$($t + 10)"" dx=""-5"" text-anchor=""end"">PC went down</text>")
    }
    [void]$sb.Append("<line class=""base"" x1=""$l"" x2=""$($W - $r)"" y1=""$($Hh - $b)"" y2=""$($Hh - $b)""/>")
    [void]$sb.Append("<polyline class=""series"" points=""$($pts -join ' ')""/>")
    [void]$sb.Append("<line class=""xhair"" y1=""$t"" y2=""$($Hh - $b)"" visibility=""hidden""/><circle class=""dot"" r=""4.5"" visibility=""hidden""/>")
    [void]$sb.Append("<rect class=""hit"" x=""$l"" y=""0"" width=""$($W - $l - $r)"" height=""$Hh""/></svg><div class=""tip"" hidden></div></div></figure>")
    return $sb.ToString()
}

# ------------------------------------------------------------------ build HTML
$sessionDur = $null; if ($prevKnown) { $sessionDur = Format-Span ($endTime - $prevBoot) }
$verdictInfo = @{
    good = @{ cls = 'good'; icon = '&#10004;'; label = 'All good' }
    warn = @{ cls = 'warn'; icon = '&#9888;'; label = 'Worth a look' }
    bad  = @{ cls = 'crit'; icon = '&#10006;'; label = 'Problem found' }
}[$verdict]

$html = New-Object Text.StringBuilder
function A([string]$s) { [void]$script:html.Append($s) }

A @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>PC Crash Report - $($now.ToString('MMM d, yyyy HH:mm'))</title>
<style>
:root{--page:#f9f9f7;--surface:#fcfcfb;--card:#ffffff;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;--border:#e1e0d9;
--series:#2a78d6;--good:#0ca30c;--goodbg:#e7f5e7;--warn:#fab219;--warnbg:#fff4dc;--crit:#d03b3b;--critbg:#fbe9e9;--infobg:#eaf2fc;--info:#2a78d6;--code:#f1f0ec;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--page:#0d0d0d;--surface:#1a1a19;--card:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--muted:#898781;--grid:#2c2c2a;--axis:#383835;--border:#2c2c2a;
--series:#3987e5;--good:#0ca30c;--goodbg:#132613;--warn:#fab219;--warnbg:#2e2510;--crit:#d03b3b;--critbg:#311515;--infobg:#14223a;--info:#3987e5;--code:#232321;color-scheme:dark}}
:root[data-theme="dark"]{--page:#0d0d0d;--surface:#1a1a19;--card:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--muted:#898781;--grid:#2c2c2a;--axis:#383835;--border:#2c2c2a;
--series:#3987e5;--good:#0ca30c;--goodbg:#132613;--warn:#fab219;--warnbg:#2e2510;--crit:#d03b3b;--critbg:#311515;--infobg:#14223a;--info:#3987e5;--code:#232321;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--ink);font:15px/1.55 "Segoe UI",system-ui,-apple-system,sans-serif}
.wrap{max-width:980px;margin:0 auto;padding:28px 18px 60px}
h1{font-size:26px;margin:0 0 4px}h2{font-size:19px;margin:34px 0 12px}h3{font-size:16px;margin:0 0 6px}
.sub{color:var(--ink2);margin:0 0 18px}
.card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:18px 20px;margin:12px 0}
.verdict{border-left:8px solid var(--c);display:flex;gap:18px;align-items:flex-start}
.verdict.good{--c:var(--good)}.verdict.warn{--c:var(--warn)}.verdict.crit{--c:var(--crit)}
.vicon{flex:0 0 52px;height:52px;border-radius:50%;background:var(--c);color:#fff;display:grid;place-items:center;font-size:26px}
.verdict.warn .vicon{color:#0b0b0b}
.vlabel{font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;color:var(--ink2)}
.verdict h2{margin:2px 0 8px;font-size:22px}
.verdict p{margin:6px 0}
ol.start{margin:6px 0 0;padding-left:22px}ol.start li{margin:8px 0}
.badge{display:inline-flex;gap:5px;align-items:center;font-size:12px;font-weight:600;padding:2px 9px;border-radius:999px;white-space:nowrap}
.badge.crit{background:var(--crit);color:#fff}.badge.warn{background:var(--warn);color:#0b0b0b}.badge.info{background:var(--infobg);color:var(--ink)}.badge.good{background:var(--good);color:#fff}
.finding{border-left:5px solid var(--fc)}.finding.critical{--fc:var(--crit)}.finding.warning{--fc:var(--warn)}.finding.info{--fc:var(--axis)}
.fhead{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.fhead h3{margin:0}
.meta{color:var(--muted);font-size:13px}
details{margin-top:10px}summary{cursor:pointer;color:var(--ink2);font-size:14px}
pre{background:var(--code);padding:10px 12px;border-radius:8px;white-space:pre-wrap;word-break:break-word;font:12.5px/1.45 Consolas,monospace;margin:8px 0 0}
table{border-collapse:collapse;width:100%;font-size:14px}th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--border);vertical-align:top}
th{color:var(--ink2);font-weight:600;font-size:13px}td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
.tablewrap{overflow-x:auto}
.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,430px),1fr));gap:14px}
.chart{margin:0;background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:12px 12px 6px}
.chart figcaption{font-weight:600;font-size:14px;margin:0 0 4px 4px}
.plot{position:relative}.plot svg{width:100%;height:auto;display:block;overflow:visible}
.grid{stroke:var(--grid);stroke-width:1}.base{stroke:var(--axis);stroke-width:1}
.ax{fill:var(--muted);font-size:11px}
.series{fill:none;stroke:var(--series);stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
.thr{stroke:var(--muted);stroke-width:1.2;stroke-dasharray:5 4}.thrlbl{fill:var(--ink2);font-size:11px}
.endline{stroke:var(--crit);stroke-width:2}.endlbl{fill:var(--ink);font-size:11px;font-weight:600}
.xhair{stroke:var(--muted);stroke-width:1}.dot{fill:var(--series);stroke:var(--surface);stroke-width:2}
.hit{fill:transparent;cursor:crosshair}
.tip{position:absolute;pointer-events:none;background:var(--card);border:1px solid var(--border);box-shadow:0 2px 8px rgba(0,0,0,.15);border-radius:8px;padding:5px 9px;font-size:12.5px;white-space:nowrap;transform:translate(-50%,-115%)}
.tip b{font-variant-numeric:tabular-nums}
.kv{display:grid;grid-template-columns:minmax(120px,max-content) 1fr;gap:6px 18px;font-size:14px}.kv div:nth-child(odd){color:var(--ink2)}
.note{background:var(--infobg);border-radius:10px;padding:10px 14px;font-size:14px;margin:10px 0}
.ok{color:var(--good);font-weight:600}
code{background:var(--code);padding:1px 5px;border-radius:4px;font-size:13px}
footer{margin-top:40px;color:var(--muted);font-size:13px}
a{color:var(--info)}
</style></head><body><div class="wrap">
<h1>PC Crash Report</h1>
<p class="sub">Made $(Esc $now.ToString('dddd, MMMM d, yyyy \a\t HH:mm'))
"@
if ($CurrentSession) { A " &middot; covering this session: <b>$(Esc (Format-When $prevBoot))</b> to now ($sessionDur)" }
elseif ($prevKnown) { A " &middot; about your last session:<b>$(Esc (Format-When $prevBoot))</b> to <b>$(Esc (Format-When $endTime))</b> ($sessionDur)" }
A '</p>'
if ($Demo) { A '<div class="note"><b>EXAMPLE REPORT</b> - this is a demo of what a crash report looks like, using your real sensor readings. Your PC did not actually crash.</div>' }

# verdict card
A "<section class=""card verdict $($verdictInfo.cls)""><div class=""vicon"" aria-hidden=""true"">$($verdictInfo.icon)</div><div>"
A "<div class=""vlabel"">$($verdictInfo.label)</div><h2>$(Esc $headline)</h2>"
foreach ($p in $story) { A "<p>$p</p>" }
if ($crashCount30 -ge 2) { A "<p><b>This PC has gone down unexpectedly $crashCount30 times in the last 30 days.</b> See the history section at the bottom.</p>" }
A '</div></section>'

# where to start
A '<h2>Where to start</h2><section class="card">'
if ($startList.Count -eq 0) {
    A '<p class="ok">&#10004; Nothing needs fixing right now.</p><p>No crashes, hardware errors or worrying temperatures were found. You do not need to do anything.</p>'
} else {
    A '<p>Try these <b>one at a time, in this order</b>. After each change, use the PC normally and see if the problem comes back - that way you know which fix worked.</p><ol class="start">'
    foreach ($s in $startList) { A "<li>$(Esc $s)</li>" }
    A '</ol>'
}
A '</section>'

# crash details
if ($crash) {
    A '<h2>Blue screen details</h2><section class="card">'
    A "<div class=""kv""><div>Stop code</div><div><b>$(Esc $crash.Info.Name)</b> <code>$(Esc $crash.Info.Code)</code></div>"
    A "<div>Usually caused by</div><div>$(Esc $crash.Info.Area)</div>"
    if ($crash.Driver) { A "<div>Driver involved</div><div><b>$(Esc $crash.Driver)</b> - $(Esc $crash.DriverInfo.What)<br><span class=""meta"">Source: $(Esc $crash.DriverSource)</span></div>" }
    if ($crash.Dump) {
        A "<div>Crash dump file</div><div><code>$(Esc $crash.Dump.Path)</code> ($($crash.Dump.SizeMB) MB, $(Esc (Format-When $crash.Dump.Time)))</div>"
        if ($crash.Dump.StackDrivers.Count) { A "<div>Drivers on the crash stack</div><div>$(Esc (($crash.Dump.StackDrivers | Select-Object -First 8) -join ', '))</div>" }
        if ($crash.Dump.Cdb -and $crash.Dump.Cdb.FailureBucket) { A "<div>WinDbg failure bucket</div><div><code>$(Esc $crash.Dump.Cdb.FailureBucket)</code></div>" }
        if ($crash.Dump.Cdb -and $crash.Dump.Cdb.ProcessName) { A "<div>Program running at the time</div><div>$(Esc $crash.Dump.Cdb.ProcessName)</div>" }
    }
    if ($crash.Params.Count) { A "<div>Parameters</div><div><code>$(Esc ($crash.Params -join ', '))</code></div>" }
    A '</div>'
    if (-not $crash.Dump) {
        if (-not $dumpAccess -or -not $isAdmin) { A '<div class="note">The crash dump folder could not be read (needs administrator rights). The automatic report runs as administrator, so this only affects manual runs.</div>' }
        else { A '<div class="note">No crash dump file was saved for this crash. Windows needs a page file and dump saving turned on (the installer checks this).</div>' }
    } elseif (-not ($crash.Dump.Cdb)) {
        A '<div class="note">Tip: install Microsoft <b>WinDbg</b> (free, from the Microsoft Store, or re-run Install.cmd) and future reports will name the crashing driver exactly instead of a best guess.</div>'
    }
    if ($crash.Dump -and $crash.Dump.Error) { A "<p class=""meta"">$(Esc $crash.Dump.Error)</p>" }
    A '<p class="meta">Tip: you can share the dump file with a tech forum (e.g. r/techsupport or the Microsoft Community) - experienced people can read it.</p></section>'
}

# right before it ended
if ($hasSensors -and $endedAtCrash) {
    A '<h2>Right before it ended</h2><section class="card"><p>The last minute of readings before the PC went down (highest value in that minute):</p><div class="tablewrap"><table><tr><th>Reading</th><th class="num">Value</th></tr>'
    $rows = @(@('CPU temperature', $Stat.CpuTemp, 'C'), @('Graphics card temperature', $Stat.GpuTemp, 'C'), @('Graphics card hot spot', $Stat.GpuHot, 'C'), @('CPU power', $Stat.CpuPower, 'W'), @('Graphics card power', $Stat.GpuPower, 'W'), @('CPU load', $Stat.CpuLoad, '%'), @('Graphics card load', $Stat.GpuLoad, '%'), @('RAM used', $Stat.MemLoad, '%'))
    foreach ($r in $rows) { if ($r[1]) { A ('<tr><td>{0}</td><td class="num">{1:0.#} {2}</td></tr>' -f $r[0], $r[1].EndMax, $r[2]) } }
    A '</table></div>'
    if ($lastProcs) {
        $cp = @($lastProcs.cpu | ForEach-Object { '{0} ({1}%)' -f $_.n, $_.v }) -join ', '
        $mp = @($lastProcs.mem | ForEach-Object { '{0} ({1} MB)' -f $_.n, $_.v }) -join ', '
        A "<p><b>Busiest programs at that time</b> (snapshot at $(Esc ([datetime]$lastProcs.t).ToString('HH:mm:ss'))):<br>CPU: $(Esc $cp)<br>Memory: $(Esc $mp)</p>"
    }
    A '</section>'
}

# recent changes
$chLabel = if ($CurrentSession) { 'the last 7 days' } else { 'the 7 days before the session ended' }
A "<h2>What changed recently</h2><section class=""card""><p>Updates, drivers and programs installed in $chLabel. Problems that start right after a change are very often caused by it.</p>"
if ($changes.Count -eq 0) {
    A '<p class="ok">&#10004; Nothing was installed or updated in that time.</p>'
} else {
    A '<div class="tablewrap"><table><tr><th>When</th><th>What</th><th>Name</th><th>Details</th></tr>'
    foreach ($c in ($changes | Select-Object -First 40)) {
        $when = if ($c.DateOnly) { $c.Time.ToString('ddd MMM d') } else { $c.Time.ToString('ddd MMM d, HH:mm') }
        $cls = 'info'; if ($c.Type -like 'Driver*') { $cls = 'warn' }
        A "<tr><td style=""white-space:nowrap"">$(Esc $when)</td><td><span class=""badge $cls"">$(Esc $c.Type)</span></td><td>$(Esc $c.Name)</td><td class=""meta"">$(Esc $c.Detail)</td></tr>"
    }
    A '</table></div>'
    if ($changes.Count -gt 40) { A "<p class=""meta"">Showing the newest 40 of $($changes.Count) changes.</p>" }
}
if ($storeUpdates -gt 0) { A "<p class=""meta"">Plus $storeUpdates routine Microsoft Store app updates (not listed).</p>" }
A '<p class="meta">Programs that don''t use the standard Windows installer only show the date, not the time.</p></section>'

# findings
$main =@($sorted | Where-Object { $_.Area -ne 'Other' })
$other = @($sorted | Where-Object { $_.Area -eq 'Other' })
A "<h2>Problems found during the session ($($main.Count))</h2>"
if ($main.Count -eq 0) { A '<section class="card"><p class="ok">&#10004; No known problems were logged by Windows.</p></section>' }
foreach ($f in $main) {
    A "<section class=""card finding $($f.Sev)""><div class=""fhead"">$(Get-SevBadge $f.Sev)<h3>$(Esc $f.Title)</h3></div>"
    $meta = @()
    if ($f.Count -gt 1) { $meta += "$($f.Count) times" }
    if ($f.First) { if ($f.Count -gt 1) { $meta += "$(Format-When $f.First) to $(Format-When $f.Last)" } else { $meta += (Format-When $f.First) } }
    if ($f.SeenBefore -gt 0) { $meta += "also seen in $($f.SeenBefore) earlier session(s)" }
    if ($meta.Count) { A "<div class=""meta"">$(Esc ($meta -join ' | '))</div>" }
    A "<p>$(Esc $f.Plain)</p>"
    $st = Resolve-Steps $f.Steps
    if ($st.Count) { A '<b>What to do:</b><ul>'; foreach ($s in $st) { A "<li>$(Esc $s)</li>" }; A '</ul>' }
    if ($f.Detail) { A "<details><summary>Technical details</summary><pre>$(Esc $f.Detail)</pre></details>" }
    A '</section>'
}
if ($other.Count) {
    A "<details class=""card""><summary><b>Other, less common errors ($($other.Count))</b> - usually not important unless they match a problem you noticed</summary>"
    foreach ($f in $other) {
        A "<div style=""margin-top:14px""><b>$(Esc $f.Title)</b> <span class=""meta"">- $($f.Count) time(s), last $(Esc (Format-When $f.Last))</span><p style=""margin:4px 0"">$(Esc $f.Plain)</p><details><summary>Technical details</summary><pre>$(Esc $f.Detail)</pre></details></div>"
    }
    A '</details>'
}

# sensors
A '<h2>Temperatures, power and load</h2>'
if (-not $hasSensors) {
    $why = 'The background monitor was not running during that session'
    if ($sensorFiles.Count -eq 0 -and -not (Get-ScheduledTask -TaskName 'PC Crash Reporter - Monitor' -ErrorAction SilentlyContinue)) { $why += ' (it is not installed yet - run Install.cmd)' }
    A "<section class=""card""><p>$why, so there is no sensor data for it. Readings will appear in the report after your next restart.</p></section>"
} else {
    A '<section class="card"><p>Summary of the whole session. <b>Peak</b> is the highest reading; most parts are fine at their peak as long as it stays below the warning level.</p><div class="tablewrap"><table><tr><th>Reading</th><th class="num">Average</th><th class="num">Peak</th><th>Peak at</th><th>Status</th></tr>'
    $rows = @(
        @('CPU temperature' + $(if ($cpuTempRough) { ' (rough, motherboard sensor)' } else { '' }), $Stat.CpuTemp, 'C', $Th.CpuTempWarn, $Th.CpuTempCrit),
        @('Graphics card temperature', $Stat.GpuTemp, 'C', $Th.GpuTempWarn, $Th.GpuTempCrit),
        @('Graphics card hot spot', $Stat.GpuHot, 'C', $Th.GpuHotspotWarn, $Th.GpuHotspotCrit),
        @('CPU power', $Stat.CpuPower, 'W', $null, $null),
        @('Graphics card power', $Stat.GpuPower, 'W', $null, $null),
        @('CPU load', $Stat.CpuLoad, '%', $null, $null),
        @('Graphics card load', $Stat.GpuLoad, '%', $null, $null),
        @('RAM used', $Stat.MemLoad, '%', $Th.RamLoadWarn, 101)
    )
    foreach ($r in $rows) {
        $st = $r[1]; if (-not $st) { continue }
        $status = '<span class="badge good">&#10004; OK</span>'
        if ($null -ne $r[3]) {
            if ($st.Max -ge $r[4]) { $status = Get-SevBadge 'critical' } elseif ($st.Max -ge $r[3]) { $status = Get-SevBadge 'warning' }
        } else { $status = '<span class="meta">-</span>' }
        A ('<tr><td>{0}</td><td class="num">{1:0.#} {2}</td><td class="num">{3:0.#} {2}</td><td>{4}</td><td>{5}</td></tr>' -f (Esc $r[0]), $st.Avg, $r[2], $st.Max, (Esc $st.MaxAt.ToString('ddd HH:mm:ss')), $status)
    }
    foreach ($hw in @($series.Keys | Where-Object { $_ -like 'Storage~*|Temperature|*' } | ForEach-Object { ($_ -split '\|')[0] } | Select-Object -Unique)) {
        $st = Get-Stats (Find-SensorKey ([regex]::Escape($hw) + '$') 'Temperature' @('Composite Temperature', 'Temperature', '*') 'Warning|Critical')
        if ($st) {
            $status = '<span class="badge good">&#10004; OK</span>'
            if ($st.Max -ge $Th.DriveTempCrit) { $status = Get-SevBadge 'critical' } elseif ($st.Max -ge $Th.DriveTempWarn) { $status = Get-SevBadge 'warning' }
            A ('<tr><td>Drive: {0}</td><td class="num">{1:0.#} C</td><td class="num">{2:0.#} C</td><td>{3}</td><td>{4}</td></tr>' -f (Esc ($hw -replace '^Storage~', '')), $st.Avg, $st.Max, (Esc $st.MaxAt.ToString('ddd HH:mm:ss')), $status)
        }
    }
    foreach ($fr in $fanRows) {
        $bad = @($findings | Where-Object { $_.Key -like 'FanStopped|*' -and $_.Title -like "*$($fr.Name)" }).Count -gt 0
        $status = if ($bad) { Get-SevBadge 'warning' } else { '<span class="badge good">&#10004; OK</span>' }
        A ('<tr><td>Fan: {0}</td><td class="num">{1:0} RPM</td><td class="num">{2:0} RPM</td><td>{3}</td><td>{4}</td></tr>' -f (Esc $fr.Name), $fr.Stat.Avg, $fr.Stat.Max, (Esc $fr.Stat.MaxAt.ToString('ddd HH:mm:ss')), $status)
    }
    A '</table></div>'
    if ($psuNote) { A "<div class=""note"">$(Esc $psuNote)</div>" }
    A '<p class="meta">Readings are taken every few seconds, so very short spikes may not show. "C" means degrees Celsius.</p></section>'

    $endMark = [datetime]::MinValue; if ($endedAtCrash) { $endMark = $endTime }
    A '<div class="charts">'
    A (New-LineChart 'CPU temperature (C)' $SensorKey.CpuTemp 'C' $Th.CpuTempWarn $endMark $false)
    A (New-LineChart 'Graphics card temperature (C)' $SensorKey.GpuTemp 'C' $Th.GpuTempWarn $endMark $false)
    A (New-LineChart 'CPU + graphics card power (W)' 'Calc~Estimate|Power|CPU + GPU' 'W' ([double]::NaN) $endMark $true)
    A (New-LineChart 'CPU load (%)' $SensorKey.CpuLoad '%' ([double]::NaN) $endMark $true)
    A (New-LineChart 'Graphics card load (%)' $SensorKey.GpuLoad '%' ([double]::NaN) $endMark $true)
    A (New-LineChart 'RAM used (%)' $SensorKey.MemLoad '%' ([double]$Th.RamLoadWarn) $endMark $true)
    A '</div>'

    # every sensor, final values
    A '<details class="card"><summary><b>All sensors</b> - every reading the monitor recorded (average / peak / last)</summary><div class="tablewrap"><table><tr><th>Part</th><th>Sensor</th><th class="num">Average</th><th class="num">Peak</th><th class="num">Last</th></tr>'
    $units = @{ Temperature = 'C'; Power = 'W'; Load = '%'; Fan = 'RPM'; Voltage = 'V'; Clock = 'MHz'; Data = 'GB'; SmallData = 'MB'; Level = '%' }
    foreach ($key in ($series.Keys | Where-Object { $_ -notlike 'Calc~*' } | Sort-Object)) {
        $st = Get-Stats $key; if (-not $st) { continue }
        $p = $key -split '\|'; $hwn = ($p[0] -split '~', 2)[-1]; $u = $units[$p[1]]
        A ('<tr><td>{0}</td><td>{1} <span class="meta">({2})</span></td><td class="num">{3:0.##} {6}</td><td class="num">{4:0.##} {6}</td><td class="num">{5:0.##} {6}</td></tr>' -f (Esc $hwn), (Esc $p[2]), (Esc $p[1]), $st.Avg, $st.Max, $st.Last, $u)
    }
    A "</table></div><p class=""meta"">Sensor source: $(Esc $sensorSource). Motherboard voltage readings are approximate and can be wrong on some boards.</p></details>"
}

# drives
if ($drives.Count) {
    A '<h2>Drive health</h2><section class="card"><div class="tablewrap"><table><tr><th>Drive</th><th>Type</th><th class="num">Size</th><th>Windows says</th><th class="num">Temp now</th><th class="num">Wear</th></tr>'
    foreach ($d in $drives) {
        $hs = if ($d.Health -eq 'Healthy') { '<span class="badge good">&#10004; Healthy</span>' } else { "<span class=""badge crit"">&#10006; $(Esc $d.Health)</span>" }
        $tmp = if ($d.Temp) { "$($d.Temp) C" } else { '-' }
        $wr = if ($null -ne $d.Wear -and "$($d.Wear)" -ne '') { "$($d.Wear)%" } else { '-' }
        A "<tr><td>$(Esc $d.Name)</td><td>$(Esc "$($d.Type) / $($d.Bus)")</td><td class=""num"">$($d.SizeGB) GB</td><td>$hs</td><td class=""num"">$tmp</td><td class=""num"">$wr</td></tr>"
    }
    A '</table></div><p class="meta">"Wear" is how much of the SSD''s rated write life has been used (0% = new).</p></section>'
}

# history
A '<h2>Crash history (last 30 days)</h2><section class="card">'
$outLabel = @{ bsod = 'Blue screen'; powerloss = 'Sudden power-off / reset'; powerbutton = 'Forced off (power button)'; sleepfail = 'Crash during sleep/wake'; clean = 'Normal shutdown'; unknown = 'Unknown'; nohistory = 'First report' }
$rowsH = @($recent | Sort-Object SessionStart -Descending | Select-Object -First 25)
if ($rowsH.Count -eq 0) { A '<p>No earlier sessions recorded yet. This list grows with each restart.</p>' }
else {
    A '<div class="tablewrap"><table><tr><th>Session started</th><th>Ended with</th><th>Stop code</th><th>Driver</th><th>Report</th></tr>'
    foreach ($h in $rowsH) {
        $lbl = $outLabel[$h.Outcome]; if (-not $lbl) { $lbl = $h.Outcome }
        $bad = $h.Outcome -in 'bsod', 'powerloss', 'powerbutton', 'sleepfail'
        $cell = if ($bad) { "<span class=""badge crit"">&#10006; $(Esc $lbl)</span>" } else { Esc $lbl }
        $link = if ($h.Report) { "<a href=""$(Esc $h.Report)"">open</a>" } else { '' }
        A "<tr><td>$(Esc $h.SessionStart.Replace('T',' '))</td><td>$cell</td><td>$(Esc $h.StopName)</td><td>$(Esc $h.Driver)</td><td>$link</td></tr>"
    }
    A '</table></div>'
    $codes = @($prevBad | Where-Object { $_.StopName } | Group-Object StopName | Where-Object Count -ge 2)
    foreach ($c in $codes) { A "<div class=""note""><b>Pattern:</b> $(Esc $c.Name) happened $($c.Count) times. Repeating the same stop code is a strong clue - focus on that one.</div>" }
    $drvs = @($prevBad | Where-Object { $_.Driver } | Group-Object Driver | Where-Object Count -ge 2)
    foreach ($c in $drvs) { A "<div class=""note""><b>Pattern:</b> the driver $(Esc $c.Name) was involved $($c.Count) times.</div>" }
}
A '<p class="meta">All reports: <a href="index.html">reports index</a></p></section>'

# system info
A '<h2>Your PC</h2><section class="card"><div class="kv">'
foreach ($k in $sys.Keys) { A "<div>$(Esc $k)</div><div>$(Esc $sys[$k])</div>" }
A "<div>Last session</div><div>$(if ($prevKnown) { Esc "$(Format-When $prevBoot) to $(Format-When $endTime) ($sessionDur)" } else { 'unknown' })</div>"
A "<div>This session started</div><div>$(Esc (Format-When $currentBoot))</div></div></section>"

# noise + glossary
$noiseTotal = ($noise.Values | Measure-Object -Sum).Sum
if ($noiseTotal -gt 0 -or $otherWarnings -gt 0) {
    A "<details class=""card""><summary><b>Ignored as harmless</b> - $([int]$noiseTotal) routine Windows messages and $otherWarnings minor warnings</summary><p>Windows logs lots of errors and warnings that look scary but are normal (for example DistributedCOM 10016 appears on almost every PC). These were left out so you can focus on what matters.</p><div class=""tablewrap""><table><tr><th>Source | Event</th><th class=""num"">Count</th></tr>"
    foreach ($k in ($noise.Keys | Sort-Object { -$noise[$_] })) { A "<tr><td>$(Esc $k)</td><td class=""num"">$($noise[$k])</td></tr>" }
    A '</table></div></details>'
}
A '<details class="card"><summary><b>Words you might see</b> - plain-English glossary</summary><div class="kv" style="margin-top:10px">'
foreach ($k in $script:Glossary.Keys) { A "<div><b>$(Esc $k)</b></div><div>$(Esc $script:Glossary[$k])</div>" }
A '</div></details>'

A "<footer>PC Crash Reporter &middot; report covers events since $(Esc (Format-When $prevBoot)) &middot; files in $(Esc $script:Root)</footer></div>"
A @'
<script>
document.querySelectorAll('svg[data-chart]').forEach(function(svg){
  var d=JSON.parse(svg.getAttribute('data-chart'));var tip=svg.parentNode.querySelector('.tip');
  var xh=svg.querySelector('.xhair'),dot=svg.querySelector('.dot'),hit=svg.querySelector('.hit');
  function move(ev){var r=svg.getBoundingClientRect();var sx=(ev.clientX-r.left)*(svg.viewBox.baseVal.width/r.width);
    var lo=0,hi=d.x.length-1;while(hi-lo>1){var m=(lo+hi)>>1;if(d.x[m]<sx)lo=m;else hi=m;}
    var i=(Math.abs(d.x[lo]-sx)<Math.abs(d.x[hi]-sx))?lo:hi;
    xh.setAttribute('x1',d.x[i]);xh.setAttribute('x2',d.x[i]);xh.setAttribute('visibility','visible');
    dot.setAttribute('cx',d.x[i]);dot.setAttribute('cy',d.y[i]);dot.setAttribute('visibility','visible');
    tip.hidden=false;tip.innerHTML=d.t[i]+' &nbsp;<b>'+d.v[i]+' '+d.u+'</b>';
    tip.style.left=(d.x[i]*r.width/svg.viewBox.baseVal.width)+'px';tip.style.top=(d.y[i]*r.height/svg.viewBox.baseVal.height)+'px';}
  function leave(){xh.setAttribute('visibility','hidden');dot.setAttribute('visibility','hidden');tip.hidden=true;}
  hit.addEventListener('mousemove',move);hit.addEventListener('mouseleave',leave);
  hit.addEventListener('touchstart',function(e){move(e.touches[0]);},{passive:true});
});
</script></body></html>
'@

# ------------------------------------------------------------------ write files
$fileName = 'report_{0}.html' -f $now.ToString('yyyy-MM-dd_HH-mm-ss')
$outPath = Join-Path $script:Paths.Reports $fileName
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($outPath, $html.ToString(), $utf8)
[IO.File]::WriteAllText((Join-Path $script:Paths.Reports 'latest.html'), $html.ToString(), $utf8)

# history + error index
$row = [pscustomobject]@{
    SessionStart = $sessionKey; SessionEnd = $endTime.ToString('yyyy-MM-ddTHH:mm:ss'); Outcome = $kind
    StopCode = $(if ($crash) { $crash.Info.Code } else { '' }); StopName = $(if ($crash) { $crash.Info.Name } else { '' })
    Driver = $(if ($crash) { $crash.Driver } else { '' }); Verdict = $verdict; Report = $fileName
}
if ($prevKnown -and -not $CurrentSession) {
    @($history + $row) | Select-Object $historyCols | Export-Csv $script:Paths.History -NoTypeInformation -Encoding UTF8
    $newIdx = foreach ($f in $findings) { [pscustomobject]@{ SessionStart = $sessionKey; Severity = $f.Sev; Key = $f.Key; Title = $f.Title; Count = $f.Count; Last = $(if ($f.Last) { ([datetime]$f.Last).ToString('yyyy-MM-ddTHH:mm:ss') } else { '' }) } }
    @($errIndex + @($newIdx)) | Where-Object { $_ } | Export-Csv $indexPath -NoTypeInformation -Encoding UTF8
}

# reports index page
$allHist = @(); if (Test-Path $script:Paths.History) { $allHist = @(Import-Csv $script:Paths.History | Sort-Object SessionStart -Descending) }
$ix = New-Object Text.StringBuilder
[void]$ix.Append('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>PC Crash Reports</title><style>:root{--bg:#f9f9f7;--card:#fff;--ink:#0b0b0b;--muted:#898781;--b:#e1e0d9;--crit:#d03b3b;--good:#0ca30c;color-scheme:light}@media (prefers-color-scheme:dark){:root{--bg:#0d0d0d;--card:#1a1a19;--ink:#f0efec;--b:#2c2c2a;color-scheme:dark}}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 "Segoe UI",system-ui,sans-serif}.w{max-width:900px;margin:0 auto;padding:28px 18px}table{width:100%;border-collapse:collapse;background:var(--card)}td,th{padding:8px 10px;border-bottom:1px solid var(--b);text-align:left}.bad{color:var(--crit);font-weight:600}.ok{color:var(--good)}a{color:#2a78d6}</style></head><body><div class="w"><h1>PC Crash Reports</h1><p><a href="latest.html">Open the latest report</a></p><div style="overflow-x:auto"><table><tr><th>Session started</th><th>Ended</th><th>How it ended</th><th>Stop code</th><th>Report</th></tr>')
foreach ($h in $allHist) {
    $lbl = $outLabel[$h.Outcome]; if (-not $lbl) { $lbl = $h.Outcome }
    $cls = if ($h.Outcome -in 'bsod', 'powerloss', 'powerbutton', 'sleepfail') { 'bad' } else { 'ok' }
    [void]$ix.Append("<tr><td>$(Esc $h.SessionStart.Replace('T',' '))</td><td>$(Esc $h.SessionEnd.Replace('T',' '))</td><td class=""$cls"">$(Esc $lbl)</td><td>$(Esc $h.StopName)</td><td><a href=""$(Esc $h.Report)"">open</a></td></tr>")
}
[void]$ix.Append('</table></div></div></body></html>')
[IO.File]::WriteAllText((Join-Path $script:Paths.Reports 'index.html'), $ix.ToString(), $utf8)

# cleanup old reports
$cut = $now.AddDays(-[int]$cfg.KeepReportsDays)
Get-ChildItem $script:Paths.Reports -Filter 'report_*.html' | Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -ErrorAction SilentlyContinue

if (-not $CurrentSession) { $state.LastReportedBoot = $bootId }
$state | ConvertTo-Json | Set-Content $script:Paths.State -Encoding UTF8
Write-AppLog "Report written: $outPath (outcome=$kind, verdict=$verdict, findings=$($findings.Count))" 'report'

$open = -not $NoOpen -and $cfg.OpenReportAfterEveryBoot -and (-not $cfg.OpenReportOnlyIfProblems -or $verdict -ne 'good')
if ($Force -and -not $NoOpen) { $open = $true }
if ($open) { Start-Process $outPath }
Write-Output $outPath
