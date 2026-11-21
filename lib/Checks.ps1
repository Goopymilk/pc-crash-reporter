# Detection checks and shared sensor helpers for PC Crash Reporter. ASCII only.
# Functions read script-level variables set by Report.ps1 (or by tests\Run-Tests.ps1):
#   $series, $SensorKey, $findings, $Th, $kind, $endTime, $cfg

# ------------------------------------------------------------------ shared helpers
function Add-Finding {
    param([string]$Sev, [string]$Title, [string]$Plain, [object[]]$Steps = @(), [int]$Count = 1,
          $First = $null, $Last = $null, [string]$Detail = '', [string]$Key = '', [string]$Area = 'Windows')
    $script:findings.Add([pscustomobject]@{ Sev = $Sev; Title = $Title; Plain = $Plain; Steps = @($Steps); Count = $Count
        First = $First; Last = $Last; Detail = $Detail; Key = $Key; Area = $Area; SeenBefore = 0 })
}

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

function Get-TimeMap([string]$Key) {
    $map = @{}
    if ($Key -and $series.ContainsKey($Key)) { $s = $series[$Key]; for ($i = 0; $i -lt $s.V.Count; $i++) { $map[$s.T[$i]] = $s.V[$i] } }
    return $map
}

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

# ------------------------------------------------------------------ 1. VRM (CPU power circuit) temperature
function Invoke-VrmTempCheck {
    $keys = @($series.Keys | Where-Object { $p = $_ -split '\|'; $p[1] -eq 'Temperature' -and $p[0] -match '^(Motherboard|SuperIO|EmbeddedController)~' -and $p[2] -match 'VRM|MOS|VR\b|VCORE|Power Stage' })
    foreach ($k in $keys) {
        $st = Get-Stats $k
        if (-not $st) { continue }
        $name = ($k -split '\|')[2]
        Test-TempFinding $st "The motherboard power circuits ($name)" $Th.VrmTempWarn $Th.VrmTempCrit @(
            'The VRMs feed power to your CPU. They get hot when the CPU works hard, especially with no airflow over them (common with AIO water coolers, which leave no fan blowing near the CPU socket).',
            'Improve airflow around the CPU socket: make sure a case fan blows across the top-left area of the motherboard.',
            'CpuOc',
            'If you have a high-end CPU on a budget motherboard, the board may simply be too weak for it at full power. Setting a power limit (PPT on AMD, PL1/PL2 on Intel) in the BIOS helps.')
    }
}
# ------------------------------------------------------------------ 2. weak / failing power supply
function Get-CombinedPower {
    # CPU + GPU power added up per timestamp -> @{ T; V } sorted by time, or $null
    $sum = @{}
    foreach ($k in @($SensorKey.CpuPower, $SensorKey.GpuPower)) {
        if (-not $k -or -not $series.ContainsKey($k)) { continue }
        $s = $series[$k]
        for ($i = 0; $i -lt $s.V.Count; $i++) { $ts = $s.T[$i]; if ($sum.ContainsKey($ts)) { $sum[$ts] += $s.V[$i] } else { $sum[$ts] = $s.V[$i] } }
    }
    if ($sum.Count -eq 0) { return $null }
    $r = @{ T = New-Object System.Collections.Generic.List[datetime]; V = New-Object System.Collections.Generic.List[double] }
    foreach ($ts in ($sum.Keys | Sort-Object)) { $r.T.Add($ts); $r.V.Add($sum[$ts]) }
    return $r
}

function Get-Median([double[]]$Values) {
    if (-not $Values -or $Values.Count -eq 0) { return 0 }
    $s = @($Values | Sort-Object)
    $mid = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2 -eq 1) { return [double]$s[$mid] }
    return ([double]$s[$mid - 1] + [double]$s[$mid]) / 2
}

$script:PowerAtEnd = $null   # set by Invoke-PsuCheck, used by later checks
function Invoke-PsuCheck {
    $script:PowerAtEnd = $null
    $pw = Get-CombinedPower
    if ($pw -and $pw.V.Count -ge 6) {
        $lastT = $pw.T[$pw.T.Count - 1]
        $endPeak = 0.0
        for ($i = $pw.V.Count - 1; $i -ge 0 -and $pw.T[$i] -ge $lastT.AddSeconds(-60); $i--) { if ($pw.V[$i] -gt $endPeak) { $endPeak = $pw.V[$i] } }
        $sessMax = ($pw.V | Measure-Object -Maximum).Maximum
        $median = Get-Median $pw.V.ToArray()
        $script:PowerAtEnd = [pscustomobject]@{ EndPeak = $endPeak; SessionMax = $sessMax; Median = $median; LastT = $lastT }
        if ($kind -eq 'powerloss' -and $endPeak -ge 0.85 * $sessMax -and $endPeak -ge [math]::Max(150, 1.5 * $median)) {
            Add-Finding -Sev 'critical' -Title ('The PC shut off while drawing a lot of power ({0:0} W for CPU + graphics card)' -f $endPeak) `
                -Plain ("In its last minute, the CPU and graphics card together drew up to {0:0} W - close to the highest of the whole session ({1:0} W), and far above its usual {2:0} W. A power supply that switches off exactly when the load is highest is the classic sign of a PSU that is too weak, worn out, or tripping its protection. The real spikes are even higher than these 5-second readings show." -f $endPeak, $sessMax, $median) `
                -Steps @('Psu', 'GpuPower', 'As a test, limit the graphics card''s power (e.g. 80% power limit in MSI Afterburner, or a frame-rate cap in the game). If the shutdowns stop, the power supply is the problem.') `
                -Key 'PsuSpikeAtShutoff' -Area 'Power'
        }
    }
    # Voltage rails (motherboard readings are approximate - hints only)
    $rails = @(@('12V', 12.0, '^\+?12V'), @('5V', 5.0, '^\+?5V$'), @('3.3V', 3.3, '^\+?3\.3V$'))
    foreach ($r in $rails) {
        $k = @($series.Keys | Where-Object { $p = $_ -split '\|'; $p[1] -eq 'Voltage' -and $p[0] -match '^(Motherboard|SuperIO|Psu)~' -and $p[2] -match $r[2] }) | Select-Object -First 1
        if (-not $k) { continue }
        $s = $series[$k]; $nom = [double]$r[1]
        $plausible = @($s.V | Where-Object { $_ -gt $nom * 0.75 -and $_ -lt $nom * 1.25 })
        if ($plausible.Count -lt [math]::Max(3, $s.V.Count * 0.8)) { continue }   # sensor reads nonsense on this board
        $low = @($plausible | Where-Object { $_ -lt $nom * 0.95 })
        if ($low.Count -eq 0) { continue }
        $min = ($plausible | Measure-Object -Minimum).Maximum
        $min = ($plausible | Measure-Object -Minimum).Minimum
        $sev = 'warning'
        $lastT = $s.T[$s.T.Count - 1]
        $endLow = $false
        for ($i = $s.V.Count - 1; $i -ge 0 -and $s.T[$i] -ge $lastT.AddSeconds(-60); $i--) { if ($s.V[$i] -lt $nom * 0.95 -and $s.V[$i] -gt $nom * 0.75) { $endLow = $true } }
        if ($endLow -and $kind -eq 'powerloss') { $sev = 'critical' }
        Add-Finding -Sev $sev -Title ('The {0} power rail dipped to {1:0.00} V (rough reading)' -f $r[0], $min) `
            -Plain ("The {0} supply from your power supply should stay between {1:0.00} and {2:0.00} V. The motherboard measured it as low as {3:0.00} V ({4} readings below the limit{5}). Motherboard voltage sensors are not very accurate, so treat this as a hint, not proof - but a rail that sags under load is a typical sign of a tired or overloaded power supply." -f $r[0], ($nom * 0.95), ($nom * 1.05), $min, $low.Count, $(if ($endLow) { ', including right before the PC went down' } else { '' })) `
            -Steps @('Psu', 'For a real answer, a PC shop can test the power supply, or you can borrow a known-good one and see if the problem goes away.') `
            -Key "RailDip|$($r[0])" -Area 'Power'
    }
}
# ------------------------------------------------------------------ 3. GPU power cable (daisy-chain) at shutoff
function Invoke-GpuCableCheck {
    if ($kind -ne 'powerloss') { return }
    $st = Get-Stats $SensorKey.GpuPower
    if (-not $st) { return }
    if ($st.EndMax -ge 150 -or ($st.EndMax -ge 100 -and $st.EndMax -ge 0.75 * $st.Max)) {
        Add-Finding -Sev 'warning' -Title ('The graphics card was drawing {0:0} W when the PC shut off' -f $st.EndMax) `
            -Plain ('Right before the shutoff, your graphics card was working hard ({0:0} W). Graphics cards make very short power spikes that can trip a power supply. A common cause is one power cable with two plugs on it (a "daisy-chain" or "pigtail") feeding the whole card, which overloads that single cable.' -f $st.EndMax) `
            -Steps @('If your graphics card has two or three power sockets, use a separate cable from the power supply for each socket - not one cable with two plugs on the end.',
                     'For 12VHPWR / 12V-2x6 (the small 16-pin plug on newer cards): check the plug is pushed all the way in, the cable is not bent sharply near the plug, and there are no melted or brown marks.',
                     'Psu') -Key 'GpuCableAtShutoff' -Area 'Power'
    }
}
# ------------------------------------------------------------------ 5. temperatures vs this PC's own history (paste / cooler)
function Get-TempProfile {
    # Average temperature at high load and at idle, for CPU and GPU, pairing readings by timestamp.
    $r = [ordered]@{}
    foreach ($part in @(@('Cpu', $SensorKey.CpuTemp, $SensorKey.CpuLoad, 60), @('Gpu', $SensorKey.GpuTemp, $SensorKey.GpuLoad, 80))) {
        $tk = $part[1]; $lk = $part[2]
        $r["$($part[0])LoadTemp"] = ''; $r["$($part[0])LoadN"] = 0; $r["$($part[0])IdleTemp"] = ''; $r["$($part[0])IdleN"] = 0
        if (-not $tk -or -not $lk -or -not $series.ContainsKey($tk) -or -not $series.ContainsKey($lk)) { continue }
        $load = Get-TimeMap $lk
        $ts = $series[$tk]; $hi = @(); $lo = @()
        for ($i = 0; $i -lt $ts.V.Count; $i++) {
            if (-not $load.ContainsKey($ts.T[$i])) { continue }
            $l = $load[$ts.T[$i]]
            if ($l -ge $part[3]) { $hi += $ts.V[$i] } elseif ($l -le 10) { $lo += $ts.V[$i] }
        }
        if ($hi.Count) { $r["$($part[0])LoadTemp"] = [math]::Round(($hi | Measure-Object -Average).Average, 1); $r["$($part[0])LoadN"] = $hi.Count }
        if ($lo.Count) { $r["$($part[0])IdleTemp"] = [math]::Round(($lo | Measure-Object -Average).Average, 1); $r["$($part[0])IdleN"] = $lo.Count }
    }
    return [pscustomobject]$r
}

function Invoke-TempHistoryCheck($Profile, [object[]]$Baseline, [datetime]$Now) {
    if (-not $Profile) { return }
    $old = @($Baseline | Where-Object { try { $d = [datetime]::Parse($_.SessionStart, [Globalization.CultureInfo]::InvariantCulture); $d -le $Now.AddDays(-14) -and $d -ge $Now.AddDays(-150) } catch { $false } })
    $checks = @(
        @('Cpu', 'Load', 'The CPU', 'under load', 10), @('Cpu', 'Idle', 'The CPU', 'at idle', 12),
        @('Gpu', 'Load', 'The graphics card', 'under load', 10), @('Gpu', 'Idle', 'The graphics card', 'at idle', 12))
    $flagged = @{}
    foreach ($c in $checks) {
        $part = $c[0]; $mode = $c[1]
        if ($flagged[$part]) { continue }
        $nowT = $Profile."$part$($mode)Temp"; $nowN = [int]$Profile."$part$($mode)N"
        if ($nowT -eq '' -or $null -eq $nowT -or $nowN -lt 12) { continue }
        $prev = @($old | Where-Object { [int]$_."$part$($mode)N" -ge 12 -and $_."$part$($mode)Temp" -ne '' } | ForEach-Object { [double]$_."$part$($mode)Temp" })
        if ($prev.Count -lt 2) { continue }
        $base = Get-Median $prev
        $diff = [double]$nowT - $base
        if ($diff -ge $c[4]) {
            $flagged[$part] = $true
            $sev = 'warning'; if ($diff -ge 15) { $sev = 'critical' }
            $steps = @('Cooling', 'Think about the room: a warmer room (summer, heater) raises all temperatures by a few degrees. If the room is about the same as before, the PC itself has changed.')
            if ($part -eq 'Cpu') {
                $steps += 'Check the CPU cooler is tight: with the PC off, gently try to wiggle it - it should not move. For an AIO water cooler, check the pump is running (you can usually feel a light vibration or hear a hum).'
                $steps += 'Replace the thermal paste between the CPU and cooler if it is a few years old (search for a video guide for your cooler - it takes about 20 minutes).'
            } else {
                $steps += 'Clean the dust out of the graphics card''s heatsink and fans with compressed air (hold the fans still while you blow).'
                $steps += 'Graphics cards that are 3+ years old can benefit from new thermal paste/pads - a PC shop can do this if you''re not comfortable.'
            }
            Add-Finding -Sev $sev -Title ('{0} runs {1:0} C hotter {2} than it used to ({3:0} vs {4:0} C)' -f $c[2], $diff, $c[3], [double]$nowT, $base) `
                -Plain ('Compared with this PC''s own readings from 2+ weeks ago ({0} earlier sessions), {1} now runs {2:0} C hotter {3} at the same kind of workload. When a PC gets steadily hotter over time, the usual causes are dust build-up, dried-out thermal paste, a cooler that has come loose, or a failing fan or pump.' -f $prev.Count, $c[2].ToLower(), $diff, $c[3]) `
                -Steps $steps -Key "TempDrift|$part" -Area 'Cooling'
        }
    }
}
# ------------------------------------------------------------------ 7. RAM slot placement
function Get-RamSlotInfo($Module) {
    # Returns channel letter and position within the channel (1 = closest to CPU) from names like
    # DIMMA1 / DIMM_A2 / "P0 CHANNEL A" / ChannelA-DIMM0 / Controller0-ChannelA-DIMM1
    $loc = "$($Module.DeviceLocator)"; $bank = "$($Module.BankLabel)"
    $ch = $null; $pos = $null
    if ($loc -match 'DIMM[_\s-]?([A-H])\s*([0-9])') { $ch = $matches[1]; $pos = [int]$matches[2] }
    elseif ($loc -match 'Channel\s*([A-H]).*DIMM\s*([0-9])') { $ch = $matches[1]; $pos = [int]$matches[2] + 1 }   # DIMM0 = first slot
    if (-not $ch -and $bank -match 'CHANNEL\s*([A-H])') { $ch = $matches[1] }
    if (-not $pos -and $loc -match '([0-9])\s*$' -and $ch) { $pos = [int]$matches[1] }
    # Intel DDR5 naming: each memory controller is its own channel (ChannelA/B are sub-channels)
    if ($ch -and $loc -match 'Controller\s*([0-9])') { $ch = "MC$($matches[1])-$ch" }
    return [pscustomobject]@{ Channel = $ch; Pos = $pos; Label = $loc }
}

function Invoke-RamSlotCheck([object[]]$Modules, [int]$SlotCount) {
    $mods = @($Modules | Where-Object { $_ })
    if ($mods.Count -lt 1) { return }
    $info = @($mods | ForEach-Object { Get-RamSlotInfo $_ })
    $labels = ($info | ForEach-Object { $_.Label }) -join ' + '
    if ($mods.Count -eq 3) {
        Add-Finding -Sev 'info' -Title "You have 3 RAM sticks installed ($labels)" `
            -Plain 'Memory works best in pairs (2 or 4 sticks). With 3, part of the memory runs slower and EXPO/XMP is more likely to be unstable.' `
            -Steps @('Use 2 or 4 sticks - ideally identical ones bought as a kit.') -Key 'RamOddCount' -Area 'Memory'
        return
    }
    if ($mods.Count -ne 2 -or @($info | Where-Object { -not $_.Channel }).Count) { return }
    if ($info[0].Channel -eq $info[1].Channel) {
        Add-Finding -Sev 'warning' -Title "Both RAM sticks are on the same channel ($labels)" `
            -Plain 'Your two RAM sticks share one memory channel, so the PC runs in "single channel" mode. That makes memory about half as fast, which hurts games a lot, and it is not the layout the motherboard is designed for.' `
            -Steps @('Move one stick to the other channel. Your motherboard manual (or the small print on the board next to the slots) shows which slots to use for 2 sticks - usually A2 and B2, the 2nd and 4th slots from the CPU.') -Key 'RamSameChannel' -Area 'Memory'
        return
    }
    if ($SlotCount -ge 4 -and @($info | Where-Object { $_.Pos -ne 1 }).Count -eq 0) {
        Add-Finding -Sev 'info' -Title "Your 2 RAM sticks are in the first slots of each channel ($labels)" `
            -Plain 'Your board has 4 RAM slots. Almost all 4-slot motherboards want 2 sticks in the 2nd and 4th slots from the CPU (called A2 and B2). The first slots (A1/B1) still work, but the signal is weaker there, which can cause instability - especially with EXPO/XMP - or stop the memory reaching its full speed.' `
            -Steps @('Check your motherboard manual for the recommended slots for 2 sticks (search "<your board> manual" - it is in the memory section). If it says A2 and B2, power off, unplug, and move both sticks one slot over.',
                     'After moving them, the first start can take a minute or two while the board re-trains the memory - that is normal.') -Key 'RamWrongSlots' -Area 'Memory'
    }
}
# ------------------------------------------------------------------ 8. CPU voltages (overclock / unsafe settings)
function Test-IsIntelRaptorLake([string]$CpuName) {
    # 13th/14th gen Core i5-13600 and up, i7, i9 (the models affected by the 2024 voltage/degradation issue)
    if ($CpuName -match 'i[79]-1[34]\d{3}') { return $true }
    if ($CpuName -match 'i5-1[34](\d{3})' -and [int]$matches[1] -ge 600) { return $true }
    return $false
}
function Test-IsAmdAm5([string]$CpuName) { return ($CpuName -match 'Ryzen\s+\d\s+[789]\d{3}') }

function Get-VoltageKeys([string]$NamePattern, [string]$Exclude = '^$') {
    return @($series.Keys | Where-Object { $p = $_ -split '\|'; $p[1] -eq 'Voltage' -and $p[0] -match '^(Cpu|Motherboard|SuperIO)~' -and $p[2] -match $NamePattern -and $p[2] -notmatch $Exclude })
}

function Invoke-CpuVoltageCheck([string]$CpuName) {
    $raptor = Test-IsIntelRaptorLake $CpuName
    $am5 = Test-IsAmdAm5 $CpuName
    # SVI2 sensors are the old AM4 interface and read garbage on AM5 CPUs
    $vcoreKeys = Get-VoltageKeys '^(Vcore|CPU Core|Core \(SVI\d TFN\)|CPU VCORE|Core)$' $(if ($am5) { 'SVI2' } else { '^$' })
    foreach ($k in $vcoreKeys) {
        $v = @($series[$k].V | Where-Object { $_ -gt 0.5 -and $_ -lt 2.0 })
        if ($v.Count -lt 3) { continue }
        $limit = if ($raptor) { 1.50 } else { 1.55 }
        $high = @($v | Where-Object { $_ -gt $limit })
        if ($high.Count -lt 3) { continue }
        $max = ($v | Measure-Object -Maximum).Maximum
        if ($raptor) {
            Add-Finding -Sev 'warning' -Title ('CPU voltage reached {0:0.00} V - too high for a 13th/14th gen Intel CPU' -f $max) `
                -Plain ('Your CPU core voltage went above {0:0.00} V ({1} readings). Intel confirmed that 13th and 14th gen Core i5/i7/i9 CPUs slowly get damaged by voltages this high, which first shows up as random crashes in games (often "out of video memory" errors or shader compile crashes) and gets worse over time.' -f $limit, $high.Count) `
                -Steps @('Update your BIOS to a version with Intel microcode 0x12B or newer (released from late 2024). This is the official fix and limits the voltage.', 'In the BIOS, use the "Intel Default Settings" / "Intel Baseline" profile instead of the motherboard''s unlimited power settings.', 'If crashes continue even after the update, contact Intel support - many affected CPUs are replaced under an extended warranty.') `
                -Key 'VcoreHighRaptor' -Area 'CPU'
        } else {
            Add-Finding -Sev 'warning' -Title ('CPU core voltage reached {0:0.00} V (rough reading)' -f $max) `
                -Plain ('Your CPU core voltage went above {0:0.00} V ({1} readings). That is higher than CPUs normally use and usually means a manual overclock or an "auto" overclocking setting in the BIOS. High voltage makes the CPU hotter and can damage it over time. Motherboard voltage readings are approximate, so treat this as a hint.' -f $limit, $high.Count) `
                -Steps @('CpuOc') -Key 'VcoreHigh' -Area 'CPU'
        }
    }
    if ($am5) {
        foreach ($k in (Get-VoltageKeys '^(SoC|VSOC|CPU SoC|SoC Voltage|VDDCR_SOC|CPU VSOC)' 'SVI2')) {
            $v = @($series[$k].V | Where-Object { $_ -gt 0.5 -and $_ -lt 2.0 })
            if ($v.Count -lt 3) { continue }
            $max = ($v | Measure-Object -Maximum).Maximum
            if (@($v | Where-Object { $_ -gt 1.30 }).Count -ge 3) {
                Add-Finding -Sev 'critical' -Title ('CPU SoC voltage is {0:0.00} V - unsafe for Ryzen 7000/8000/9000' -f $max) `
                    -Plain 'The SoC voltage (which powers the memory controller) is above 1.30 V. In 2023, AMD Ryzen 7000-series CPUs were burning out at SoC voltages like this, usually caused by EXPO memory profiles on older BIOS versions. AMD now limits it to 1.30 V in newer BIOS versions.' `
                    -Steps @('Update your BIOS now - current versions cap SoC voltage at a safe level.', 'Until then, turn EXPO off, or set SoC voltage manually to 1.25 V or lower in the BIOS.') `
                    -Key 'SocHigh' -Area 'CPU'
            }
        }
    }
}
# ------------------------------------------------------------------ 9. SMART attributes (SATA drives)
function ConvertFrom-SmartData([byte[]]$Bytes) {
    # ATA SMART data block: 2-byte version, then 30 x 12-byte attributes (id, flags x2, current, worst, raw x6, reserved)
    $a = @{}
    if (-not $Bytes -or $Bytes.Count -lt 362) { return $a }
    for ($i = 0; $i -lt 30; $i++) {
        $o = 2 + $i * 12
        $id = [int]$Bytes[$o]
        if ($id -eq 0) { continue }
        [uint64]$raw = 0
        for ($b = 5; $b -ge 0; $b--) { $raw = $raw * 256 + $Bytes[$o + 5 + $b] }
        $a[$id] = $raw
    }
    return $a
}

function Get-SmartDrives {
    # Returns @( @{ Name; Attributes } ) for drives that expose ATA SMART through Windows (needs admin)
    $out = @()
    try {
        $disks = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop)
        foreach ($d in @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictData -ErrorAction Stop)) {
            $disk = $disks | Where-Object { $d.InstanceName -like "$($_.PNPDeviceID)*" } | Select-Object -First 1
            $name = if ($disk) { $disk.Model } else { $d.InstanceName }
            $out += [pscustomobject]@{ Name = $name; Attributes = (ConvertFrom-SmartData ([byte[]]$d.VendorSpecific)) }
        }
    } catch { }
    return $out
}

function Invoke-SmartCheck([object[]]$Drives, [hashtable]$Previous = @{}) {
    foreach ($d in $Drives) {
        $a = $d.Attributes; $n = $d.Name
        $realloc = [uint64]0; foreach ($id in 5, 196) { if ($a.ContainsKey($id) -and $a[$id] -gt $realloc) { $realloc = $a[$id] } }
        $pending = if ($a.ContainsKey(197)) { $a[197] } else { 0 }
        $uncorr = if ($a.ContainsKey(198)) { $a[198] } else { 0 }
        $reported = if ($a.ContainsKey(187)) { $a[187] } else { 0 }
        $crc = if ($a.ContainsKey(199)) { $a[199] } else { 0 }
        if ($pending -gt 0 -or $uncorr -gt 0) {
            Add-Finding -Sev 'critical' -Title "Drive '$n' has unreadable sectors ($pending pending, $uncorr uncorrectable)" `
                -Plain 'The drive reports parts of its surface it can no longer read reliably. This is one of the strongest signs that a drive is failing, and it can cause freezes, blue screens and lost files.' `
                -Steps @('DiskBackup', 'Plan to replace this drive soon.', 'DiskCheck') -Key "SmartPending|$n" -Area 'Drives'
        }
        if ($realloc -gt 0) {
            $sev = if ($realloc -ge 50) { 'critical' } else { 'warning' }
            Add-Finding -Sev $sev -Title "Drive '$n' has replaced $realloc bad sectors" `
                -Plain 'The drive found damaged spots and swapped them for spare ones ("reallocated sectors"). A handful can stay stable for years, but a number that keeps going up means the drive is wearing out.' `
                -Steps @('DiskBackup', 'Check this number again in a few weeks (it is shown in every report). If it grows, replace the drive.') -Key "SmartRealloc|$n" -Area 'Drives'
        }
        if ($reported -gt 0 -and $pending -eq 0 -and $uncorr -eq 0) {
            Add-Finding -Sev 'warning' -Title "Drive '$n' has reported $reported read errors it could not fix" `
                -Plain 'At some point the drive failed to read data and could not recover it.' -Steps @('DiskBackup', 'DiskCheck') -Key "SmartReported|$n" -Area 'Drives'
        }
        if ($crc -gt 0) {
            $before = if ($Previous.ContainsKey($n)) { [uint64]$Previous[$n] } else { $null }
            if ($null -ne $before -and $crc -gt $before) {
                Add-Finding -Sev 'warning' -Title "Cable errors on drive '$n' went up ($before -> $crc)" `
                    -Plain 'The drive is seeing data errors on the cable between it and the motherboard ("CRC errors"), and the count has gone up since the last report. That points to a bad or loose SATA cable, not a bad drive. It can cause freezes and slow file copies.' `
                    -Steps @('Replace the SATA data cable (they are cheap) and plug it into a different SATA port on the motherboard. Make sure both ends click in.') -Key "SmartCrc|$n" -Area 'Drives'
            } elseif ($null -eq $before) {
                Add-Finding -Sev 'info' -Title "Drive '$n' has had $crc cable errors in its lifetime" `
                    -Plain 'This counter never goes down, so old errors (for example from a previous cable) stay in it. It only matters if it keeps going up - the next reports will tell you if it does.' `
                    -Steps @() -Key "SmartCrcOld|$n" -Area 'Drives'
            }
        }
    }
}
# ------------------------------------------------------------------ 10. SSD firmware
function Get-SsdTool([string]$Model) {
    switch -Regex ($Model) {
        'Samsung'                 { return 'Samsung Magician' }
        'KINGSTON|^SA400|^SNV|^SKC|^SFYR' { return 'Kingston SSD Manager' }
        '^WD|^WDC|SanDisk|^WDS'   { return 'WD Dashboard (Western Digital)' }
        '^CT\d|Crucial|Micron'    { return 'Crucial Storage Executive' }
        'Seagate|^ST\d|FireCuda'  { return 'SeaTools (Seagate)' }
        'Solidigm|INTEL SSD'      { return 'Solidigm Storage Tool' }
        'SK ?hynix|HFS|Platinum'  { return 'SK hynix Drive Manager' }
        'Corsair|^Force|^MP\d'    { return 'Corsair SSD Toolbox / iCUE' }
        'T-FORCE|TEAM'            { return 'the T-FORCE SSD Toolbox (TeamGroup)' }
        'ADATA|XPG|^SX\d'         { return 'ADATA SSD ToolBox' }
        'Lexar'                   { return 'Lexar DiskMaster' }
        default                   { return 'the drive maker''s SSD tool (on their website)' }
    }
}

function Invoke-FirmwareCheck([object[]]$Drives, [hashtable]$Previous = @{}, [bool]$DriveTrouble = $false) {
    foreach ($d in $Drives) {
        if (-not $d.Firmware) { continue }
        $before = $Previous[$d.Name]
        if ($before -and $before -ne $d.Firmware) {
            Add-Finding -Sev 'info' -Title "Drive '$($d.Name)' firmware changed ($before -> $($d.Firmware))" `
                -Plain 'The drive''s own built-in software was updated. Firmware updates usually fix bugs - but if problems started right after it, mention it when asking for help.' `
                -Steps @() -Key "FwChanged|$($d.Name)" -Area 'Drives'
        }
        if ($DriveTrouble -and $d.Media -ne 'HDD') {
            Add-Finding -Sev 'warning' -Title "Check for an SSD firmware update ($($d.Name), firmware $($d.Firmware))" `
                -Plain ('Drive-related errors showed up in this report. SSDs have their own built-in software (firmware), and buggy firmware is a common cause of drives freezing, disappearing or causing blue screens. Your {0} is running firmware {1}.' -f $d.Name, $d.Firmware) `
                -Steps @("Install $(Get-SsdTool $d.Name), check for a firmware update and apply it. Back up first, just in case.") -Key "FwUpdate|$($d.Name)" -Area 'Drives'
        }
    }
}
# ------------------------------------------------------------------ 11. PCI Express errors (WHEA) with the device named
$script:PciVendors = @{
    '1022' = @('AMD', 'cpu'); '8086' = @('Intel', 'cpu'); '10DE' = @('NVIDIA', 'gpu'); '1002' = @('AMD Radeon', 'gpu'); '8086GPU' = @('Intel Arc', 'gpu')
    '144D' = @('Samsung', 'ssd'); '2646' = @('Kingston', 'ssd'); '15B7' = @('Western Digital / SanDisk', 'ssd'); '1987' = @('Phison-based', 'ssd')
    '1C5C' = @('SK hynix', 'ssd'); '126F' = @('Silicon Motion-based', 'ssd'); '1E0F' = @('Kioxia', 'ssd'); 'C0A9' = @('Crucial / Micron', 'ssd'); '1344' = @('Crucial / Micron', 'ssd')
    '1E4B' = @('MAXIO-based', 'ssd'); '1CC1' = @('ADATA', 'ssd'); '1D97' = @('Lexar/SPCC', 'ssd'); '1BB1' = @('Seagate', 'ssd'); '1B4B' = @('Marvell', 'ssd'); '10EC' = @('Realtek', 'net')
    '14E4' = @('Broadcom', 'net'); '168C' = @('Qualcomm Atheros', 'net'); '17CB' = @('Qualcomm', 'net'); '14C3' = @('MediaTek', 'net'); '1B21' = @('ASMedia', 'chipset')
}

function Get-WheaPciDevice([string]$Message) {
    $ven = $null; $dev = $null; $comp = ''
    if ($Message -match 'Vendor ID:Device ID:\s*0x([0-9A-Fa-f]{1,4}):0x([0-9A-Fa-f]{1,4})') { $ven = $matches[1].ToUpper().PadLeft(4, '0'); $dev = $matches[2].ToUpper().PadLeft(4, '0') }
    if ($Message -match 'Component:\s*([^\r\n]+)') { $comp = $matches[1].Trim() }
    return [pscustomobject]@{ Vendor = $ven; Device = $dev; Component = $comp }
}

function Invoke-WheaPcieCheck([object[]]$Events) {
    $pci = @($Events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' -and "$($_.Message)" -match 'PCI Express|PCIe' })
    if (-not $pci.Count) { return }
    $groups = $pci | ForEach-Object { $d = Get-WheaPciDevice $_.Message; [pscustomobject]@{ E = $_; D = $d; Key = "$($d.Vendor):$($d.Device)" } } | Group-Object Key
    foreach ($g in $groups) {
        $d = $g.Group[0].D; $evs = @($g.Group | ForEach-Object { $_.E })
        $fatal = @($evs | Where-Object { $_.Id -ne 17 -or ($_.Level -le 2 -and "$($_.Message)" -match 'fatal') }).Count -gt 0
        $info = if ($d.Vendor -and $PciVendors.ContainsKey($d.Vendor)) { $PciVendors[$d.Vendor] } else { @('an unknown', 'unknown') }
        $isRootPort = $d.Component -match 'Root Port' -or $info[1] -eq 'cpu'
        switch ($info[1]) {
            'gpu' { $what = "your $($info[0]) graphics card"; $steps = @('Power off, unplug, and reseat the graphics card: take it out and push it firmly back in until the slot clicks. Re-plug its power cables.', 'If you use a riser cable (vertical GPU mount), it is a very common cause - try the card directly in the motherboard slot.', 'In the BIOS, set the graphics card slot speed ("PCIe Link Speed") from Auto to Gen 4 (or Gen 3). This often stops these errors with little or no performance loss.', 'GpuDriver') }
            'ssd' { $what = "your $($info[0]) NVMe SSD"; $steps = @('DiskBackup', 'Reseat the SSD: power off, unplug, unscrew it, take it out and put it back in firmly.', 'Update the SSD firmware with the maker''s tool.', 'In the BIOS, set that M.2 slot''s speed from Auto to one generation lower (e.g. Gen 4 instead of Gen 5).') }
            'net' { $what = "your $($info[0]) network / Wi-Fi card"; $steps = @('NetDriver', 'If it is a separate card, reseat it. If the errors continue, disable its power saving: Device Manager > Network adapters > the adapter > Power Management > untick "Allow the computer to turn off this device".') }
            'chipset' { $what = "a $($info[0]) controller on your motherboard (usually extra USB or SATA ports)"; $steps = @('Chipset', 'Bios', 'Unplug devices from the extra USB/SATA ports one by one to see if one of them causes it.') }
            default { $what = 'a slot or link on your motherboard (the CPU''s connection to a card or SSD)'; $steps = @('Reseat your graphics card and M.2 SSDs (power off and unplug first).', 'In the BIOS, set PCIe Link Speed for the graphics slot and M.2 slots from Auto to one generation lower.', 'Bios', 'Chipset') }
        }
        $sev = if ($fatal) { 'critical' } else { 'warning' }
        $idText = if ($d.Vendor) { " (vendor ID $($d.Vendor), device ID $($d.Device))" } else { '' }
        $where = if ($isRootPort -and $info[1] -eq 'cpu') { ' The error was reported by the CPU/motherboard side of the slot, so the problem is with whatever is plugged into that slot, or the slot itself.' } else { '' }
        Add-Finding -Sev $sev -Title ("PCI Express {0}: {1}" -f $(if ($fatal) { 'hardware error' } else { 'communication errors' }), $what) `
            -Plain ("Windows logged {0} {1} on the high-speed connection (PCI Express) to {2}{3}.{4} These happen when the signal between a card/SSD and the motherboard is not clean - often a card not fully seated, a riser cable, dust in the slot, or a link running at a speed it can't hold. A few corrected errors are harmless, but many of them, or an uncorrected one, can freeze or crash the PC." -f $evs.Count, $(if ($fatal) { 'error(s), including uncorrected ones' } else { 'corrected error(s)' }), $what, $idText, $where) `
            -Steps $steps -Count $evs.Count -First (($evs | Sort-Object TimeCreated)[0].TimeCreated) -Last (($evs | Sort-Object TimeCreated)[-1].TimeCreated) -Key "WheaPcie|$($g.Name)" -Area 'Hardware'
    }
}
# ------------------------------------------------------------------ 12. graphics card disappearing / power dropping out under load
function Invoke-GpuDropoutCheck {
    $gpuKeys = @($SensorKey.GpuTemp, $SensorKey.GpuLoad, $SensorKey.GpuPower) | Where-Object { $_ -and $series.ContainsKey($_) }
    $refKey = $SensorKey.CpuLoad
    if (-not $gpuKeys.Count -or -not $refKey -or -not $series.ContainsKey($refKey)) { return }
    $ref = $series[$refKey]; $refLast = $ref.T[$ref.T.Count - 1]
    $gpuLast = ($gpuKeys | ForEach-Object { $series[$_].T[$series[$_].T.Count - 1] } | Measure-Object -Maximum).Maximum
    $gap = ($refLast - $gpuLast).TotalSeconds
    $steps = @('Make sure the graphics card power cables are pushed fully in at both ends (card and power supply), and use separate cables for each socket on the card.',
               'Power off, unplug, and reseat the graphics card. If you use a riser cable, try without it.',
               'In the BIOS, set the graphics card slot (PCIe Link Speed) from Auto to Gen 4 or Gen 3.',
               'GpuDriver', 'Psu')
    if ($gap -ge 20) {
        Add-Finding -Sev 'critical' -Title ('The graphics card stopped responding {0} before the end' -f (Format-Span ([TimeSpan]::FromSeconds($gap)))) `
            -Plain ('The tool kept reading the CPU sensors until {0:HH:mm:ss}, but the graphics card''s sensors went silent at {1:HH:mm:ss}. That means the card stopped answering - it "fell off" the system. This usually happens when the card loses power for a moment (cable or power supply), is not seated firmly, or its driver crashed hard.' -f $refLast, $gpuLast) `
            -Steps $steps -Key 'GpuVanished' -Area 'Graphics'
        return
    }
    # Power or clock collapsing to ~0 while the card was busy
    $pk = $SensorKey.GpuPower
    if ($pk -and $series.ContainsKey($pk)) {
        $s = $series[$pk]
        $loadMap = if ($SensorKey.GpuLoad) { Get-TimeMap $SensorKey.GpuLoad } else { @{} }
        $drops = 0; $firstDrop = $null
        for ($i = 1; $i -lt $s.V.Count; $i++) {
            if ($s.V[$i - 1] -ge 80 -and $s.V[$i] -le 3 -and ($s.T[$i] - $s.T[$i - 1]).TotalSeconds -le 30) {
                $busy = (-not $loadMap.ContainsKey($s.T[$i])) -or $loadMap[$s.T[$i]] -ge 50 -or $loadMap[$s.T[$i]] -eq 0
                if ($busy) { $drops++; if (-not $firstDrop) { $firstDrop = $s.T[$i] } }
            }
        }
        if ($drops -gt 0) {
            Add-Finding -Sev 'warning' -Title ('The graphics card''s power suddenly dropped to zero while it was busy ({0} time{1})' -f $drops, $(if ($drops -ne 1) { 's' } else { '' })) `
                -Plain ('At {0:HH:mm:ss} the graphics card went from drawing a lot of power straight to nothing in one reading. A working card ramps down; an instant drop to zero means it briefly lost power or reset. This is often what you see as a black screen or a game freezing for a few seconds.' -f $firstDrop) `
                -Steps $steps -Count $drops -First $firstDrop -Key 'GpuPowerDrop' -Area 'Graphics'
        }
    }
}
# ------------------------------------------------------------------ 13. USB errors right before the crash
function Invoke-UsbCheck([object[]]$Events, $End) {
    if (-not $End) { return }
    $usb = @($Events | Where-Object { $_.TimeCreated -ge $End.AddMinutes(-10) -and $_.TimeCreated -le $End.AddSeconds(30) -and $_.Level -le 3 -and
        ($_.ProviderName -match 'USB' -or ("$($_.Message)" -match '\bUSB\\|\bUSB\b' -and $_.ProviderName -match 'Kernel-PnP|DeviceSetupManager|UserPnp|disk|partmgr')) })
    if (-not $usb.Count) { return }
    $devs = @($usb | ForEach-Object { if ("$($_.Message)" -match '(USB\\VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4})') { $matches[1].ToUpper() } } | Select-Object -Unique)
    $devText = if ($devs.Count) { ' Device(s) involved: ' + ($devs -join ', ') + ' (search the VID/PID online to see what device it is).' } else { '' }
    $sev = if ($kind -in 'bsod', 'powerloss', 'powerbutton') { 'warning' } else { 'info' }
    Add-Finding -Sev $sev -Title ('{0} USB error{1} in the 10 minutes before the end' -f $usb.Count, $(if ($usb.Count -ne 1) { 's' } else { '' })) `
        -Plain ("Shortly before the PC went down, Windows logged problems with USB devices (a device disconnecting, resetting or failing to start).$devText A faulty USB device, a bad cable or hub, or a device drawing too much power can freeze or crash a PC - and a power surge through a USB port can even make it shut off.") `
        -Steps @('Unplug every USB device you don''t need (hubs, RGB controllers, webcams, card readers, phone chargers) and see if the crashes stop. Then add them back one at a time.',
                 'Plug important devices straight into the ports on the back of the PC instead of front ports or hubs.', 'Usb', 'Chipset') `
        -Count $usb.Count -First (($usb | Sort-Object TimeCreated)[0].TimeCreated) -Key 'UsbBeforeCrash' -Area 'Devices'
}
# ------------------------------------------------------------------ 14. CMOS battery (clock / BIOS settings memory)
function Invoke-CmosBatteryCheck([object[]]$TimeEvents) {
    $vk = @($series.Keys | Where-Object { $p = $_ -split '\|'; $p[1] -eq 'Voltage' -and $p[2] -match 'VBAT|CMOS|Battery|3VSB_BAT|VBat' }) | Select-Object -First 1
    $low = $null
    if ($vk) {
        $v = @($series[$vk].V | Where-Object { $_ -gt 1.5 -and $_ -lt 3.6 })
        if ($v.Count -ge 3) { $med = Get-Median $v; if ($med -lt 2.8) { $low = $med } }
    }
    $jumps = @()
    foreach ($e in $TimeEvents) {
        if ($e.ProviderName -ne 'Microsoft-Windows-Kernel-General' -or $e.Id -ne 1) { continue }
        $m = Get-EventDataMap $e
        try {
            $new = [datetime]::Parse($m['NewTime'], [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
            $old = [datetime]::Parse($m['OldTime'], [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
            $diff = [math]::Abs(($new - $old).TotalHours)
            # Reason 2 = time read from the motherboard clock at startup. "Old" is the last time Windows knew (usually the
            #   shutdown time), so a jump FORWARD is just how long the PC was off. A jump BACKWARD means the clock reset.
            # Reason 1 = something (normally the internet time service) corrected the clock afterwards - big fixes are suspicious.
            $reason = "$($m['Reason'])"
            $bad = if ($reason -eq '2' -or -not $reason) { ($old - $new).TotalHours -ge 2 } elseif ($reason -eq '1') { $diff -ge 2 } else { $false }
            if ($bad) { $jumps += [pscustomobject]@{ Time = $e.TimeCreated; Old = $old; New = $new; Hours = $diff; Reason = $reason } }
        } catch { }
    }
    if ($null -eq $low -and -not $jumps.Count) { return }
    $parts = @()
    if ($null -ne $low) { $parts += ('The motherboard measures the battery at {0:0.00} V. A healthy CR2032 battery is about 3.0 V; below about 2.8 V it is running out.' -f $low) }
    if ($jumps.Count) {
        $j = $jumps | Sort-Object Hours -Descending | Select-Object -First 1
        $wrong = if ($j.Reason -eq '1') { $j.Old } else { $j.New }
        $parts += ('{0} time(s) the PC''s clock was badly wrong and had to be corrected - by up to {1} (the motherboard clock said {2:yyyy-MM-dd HH:mm} UTC). That happens when the clock on the motherboard loses track while the PC is unplugged.' -f $jumps.Count, (Format-Span ([TimeSpan]::FromHours($j.Hours))), $wrong)
    }
    $sev = if ($null -ne $low -and $low -lt 2.6) { 'warning' } else { 'info' }
    Add-Finding -Sev $sev -Title 'The motherboard battery (CMOS battery) may be getting weak' `
        -Plain ('The motherboard has a coin battery that keeps the clock running and remembers your BIOS settings while the PC is unplugged. ' + ($parts -join ' ') + ' A dead battery doesn''t usually cause crashes while running, but it can reset BIOS settings (memory speed, boot order, fan curves) and cause a wrong clock, which breaks websites, game logins and updates.') `
        -Steps @('Replace the coin battery on the motherboard - it is a CR2032, costs very little and is sold almost everywhere. Power off and unplug first, press the small clip to pop the old one out.',
                 'After replacing it, go into the BIOS once to set the date/time and re-apply any settings you changed (like EXPO/XMP).') -Key 'CmosBattery' -Area 'Motherboard'
}
# ------------------------------------------------------------------ 15. Intel 13th/14th gen microcode
function Get-MicrocodeRevision {
    try {
        $b = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name 'Update Revision' -ErrorAction Stop).'Update Revision'
        if ($b -and $b.Count -ge 8) { return [int64][BitConverter]::ToUInt32([byte[]]$b, 4) }   # Intel: revision in the high DWORD
        if ($b -and $b.Count -ge 4) { return [int64][BitConverter]::ToUInt32([byte[]]$b, 0) }   # AMD: 4 bytes
    } catch { }
    return $null
}

function Invoke-MicrocodeCheck([string]$CpuName, $Revision) {
    if (-not (Test-IsIntelRaptorLake $CpuName) -or $null -eq $Revision) { return }
    try { $Revision = [int64]$Revision } catch { return }
    if ($Revision -le 0) { return }
    if ($Revision -ge 0x12B) { return }
    Add-Finding -Sev 'critical' -Title ('Your Intel CPU needs a BIOS update (microcode 0x{0:X} is older than 0x12B)' -f $Revision) `
        -Plain ('Your {0} is a 13th/14th gen Intel CPU. In 2024 Intel found that these CPUs ask for too much voltage, which slowly damages them and causes random crashes - especially in games (errors like "out of video memory", shader compile crashes, or Unreal Engine crashes). The fix is new CPU "microcode", delivered through a BIOS update. Your PC is running microcode 0x{1:X}; the fixed version is 0x12B or newer. The damage is permanent, so update as soon as you can.' -f $CpuName.Trim(), $Revision) `
        -Steps @('Update your BIOS to the newest version from your motherboard maker''s website (look for "microcode 0x12B" or newer, or "Intel Default Settings", in the release notes).', 'Bios',
                 'If crashes continue after the update, the CPU may already be damaged. Intel extended the warranty on these CPUs - contact Intel support or the shop you bought it from for a replacement.') `
        -Key 'IntelMicrocode' -Area 'CPU'
}
# ------------------------------------------------------------------ 16. wall power (outlet / power strip / UPS)
function Invoke-WallPowerCheck([bool]$HadSensorData) {
    if ($kind -ne 'powerloss') { return }
    $inside = @($findings | Where-Object { $_.Sev -in 'warning', 'critical' -and $_.Area -in 'Power', 'Cooling', 'Graphics', 'Hardware', 'CPU', 'Motherboard' })
    $steps = @('Think back: did anything else in the room flicker or switch off at the same moment (lights, monitor, router, speakers)? If so, the problem is the building''s power, not the PC.',
               'Plug the PC straight into a wall socket, not a power strip, extension cord or cheap surge protector - worn-out power strips are a very common cause of sudden shutoffs.',
               'Don''t share the socket with heaters, kettles, hair dryers, vacuums or air conditioners - they cause voltage dips when they switch on.',
               'If you have a UPS (battery backup), test the PC without it: a UPS with an old battery can drop the power by itself. If you don''t have one, a UPS stops power cuts and dips from turning the PC off.',
               'Check the power cable is pushed firmly into the back of the PC, and the switch on the power supply is fully on.')
    if (-not $inside.Count -and $HadSensorData) {
        Add-Finding -Sev 'critical' -Title 'Nothing inside the PC explains this shutoff - check the wall power first' `
            -Plain 'The PC lost power suddenly, but right up to that moment everything looked normal: temperatures were fine, power use was not unusual, and there were no hardware errors. When a PC dies with no warning signs at all, the cause is often outside the PC: the wall socket, a power strip, a UPS, a loose cable, or a short power dip in the building.' `
            -Steps ($steps + @('If the wall power checks out and it happens again, the power supply itself is the next suspect.', 'Psu')) -Key 'WallPower' -Area 'Power'
    } else {
        Add-Finding -Sev 'info' -Title 'Also rule out the wall power' `
            -Plain 'Sudden shutoffs can also come from outside the PC (wall socket, power strip, UPS, power dips), so it is worth ruling these out too.' `
            -Steps $steps -Key 'WallPowerAlso' -Area 'Power'
    }
}
# ------------------------------------------------------------------ 19. overlays, RGB and tuning apps running at the crash
function Invoke-SideAppsCheck([string[]]$Apps, [object[]]$GpuTop, [int]$AppCrashCount = 0) {
    $crashy = $kind -in 'bsod', 'powerloss', 'powerbutton', 'sleepfail' -or $AppCrashCount -gt 0
    if (-not $crashy) { return }
    $known = @{}; foreach ($a in $SideApps) { $known[$a[1]] = $a[2] }
    $apps = @($Apps | Where-Object { $_ } | Select-Object -Unique)
    $gpuText = ''
    $g = @($GpuTop | Where-Object { $_ -and $_.n }) | Select-Object -First 1
    if ($g) { $gpuText = (' The program using the graphics card the most at the end was {0} ({1:0}%).' -f $g.n, [double]$g.v) }
    if (-not $apps.Count) { return }
    $tuning = @($apps | Where-Object { $known[$_] -in 'tuning', 'rgb', 'monitoring' })
    $overlay = @($apps | Where-Object { $known[$_] -eq 'overlay' })
    $sev = if ($kind -eq 'bsod' -and $tuning.Count) { 'warning' } else { 'info' }
    $plain = 'These programs were running right before the end:'
    if ($overlay.Count) { $plain += ' overlays/recorders (' + ($overlay -join ', ') + ') draw on top of games by hooking into them, and are a well-known cause of game crashes and black screens.' }
    if ($tuning.Count) { $plain += ' Tuning, RGB and monitoring apps (' + ($tuning -join ', ') + ') talk directly to your hardware through their own low-level drivers. Several of them at once can fight over the same sensors and chips, which can freeze the PC or cause blue screens.' }
    $steps = @()
    if ($overlay.Count) { $steps += 'Turn the overlays off as a test: Discord (User Settings > Game Overlay), Steam (Settings > In Game), NVIDIA app (Settings > Overlay), Xbox Game Bar (Windows Settings > Gaming). If crashes stop, turn them back on one at a time.' }
    if ($tuning.Count) { $steps += 'Keep only one program that controls RGB/fans/hardware and uninstall the rest (not just close them - their background services keep running). Many people only need the one from their motherboard maker, or none at all.'; $steps += 'If MSI Afterburner, Ryzen Master or Radeon tuning has an overclock or undervolt applied, reset it to defaults.' }
    Add-Finding -Sev $sev -Title ('{0} overlay/tuning app{1} running: {2}' -f $apps.Count, $(if ($apps.Count -ne 1) { 's were' } else { ' was' }), ($apps -join ', ')) `
        -Plain ($plain + $gpuText + ' They are not necessarily the cause - but they are quick to rule out.') -Steps $steps -Key 'SideApps' -Area 'Software'
}
# ------------------------------------------------------------------ 21. running out of memory (commit charge)
function Invoke-CommitCheck {
    $k = @($series.Keys | Where-Object { $p = $_ -split '\|'; $p[1] -eq 'Load' -and ($p[0] -match 'Virtual Memory' -or $p[2] -match 'Commit') }) | Select-Object -First 1
    if (-not $k) { return }
    $s = $series[$k]
    $high = @($s.V | Where-Object { $_ -ge 90 })
    if (-not $high.Count) { return }
    $max = ($s.V | Measure-Object -Maximum).Maximum
    $lastT = $s.T[$s.T.Count - 1]; $endMax = 0
    for ($i = $s.V.Count - 1; $i -ge 0 -and $s.T[$i] -ge $lastT.AddSeconds(-120); $i--) { if ($s.V[$i] -gt $endMax) { $endMax = $s.V[$i] } }
    $atEnd = $endMax -ge 90
    $sev = if ($atEnd -and $kind -in 'bsod', 'powerbutton', 'unknown') { 'critical' } elseif ($atEnd -or $max -ge 97) { 'warning' } else { 'info' }
    Add-Finding -Sev $sev -Title ('Windows ran nearly out of memory (up to {0:0}% of RAM + page file used{1})' -f $max, $(if ($atEnd) { ', including at the end' } else { '' })) `
        -Plain ('Windows can only promise programs as much memory as your RAM plus the page file (extra space on the drive). This "committed" memory reached {0:0}% of that limit. When it hits 100%, programs crash with "out of memory" errors, games close without warning, and the PC can freeze or blue-screen. It usually means too many heavy programs at once (browser tabs, games, Discord), a program with a memory leak, a page file that is too small or switched off, or simply not enough RAM.' -f $max) `
        -Steps @('Check the page file is on and managed by Windows: press Win+R, type sysdm.cpl, Advanced > Performance Settings > Advanced > Virtual memory > Change, tick "Automatically manage paging file size for all drives".',
                 'Make sure the C: drive has free space (at least 15-20 GB) so the page file can grow.',
                 'Close browser tabs and background programs before gaming. The "Right before it ended" section shows which programs used the most memory.',
                 'If this happens often, more RAM (16 GB minimum for gaming today, 32 GB is comfortable) is the lasting fix.') `
        -Key 'CommitHigh' -Area 'Memory'
}
# ------------------------------------------------------------------ 22. page file switched off or too small
function Get-PageFileInfo {
    $r = [pscustomobject]@{ Auto = $null; Files = @(); RamGB = 0 }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $r.Auto = [bool]$cs.AutomaticManagedPagefile; $r.RamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $r.Files = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = $_.Name; SizeMB = [int]$_.AllocatedBaseSize } })
        $set = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
        foreach ($f in $r.Files) { $s = $set | Where-Object { $_.Name -eq $f.Name } | Select-Object -First 1; if ($s -and $s.MaximumSize -gt 0) { $f | Add-Member MaxMB ([int]$s.MaximumSize) } }
    } catch { }
    return $r
}

function Invoke-PageFileCheck($Info) {
    if (-not $Info -or $null -eq $Info.Auto) { return }
    $fix = 'Turn the page file back to automatic: press Win+R, type sysdm.cpl, then Advanced > Performance Settings > Advanced > Virtual memory > Change, tick "Automatically manage paging file size for all drives", click OK and restart.'
    $sysDrive = $env:SystemDrive; if (-not $sysDrive) { $sysDrive = 'C:' }
    if ($Info.Auto) { return }
    if (-not $Info.Files.Count) {
        $sev = if ($kind -in 'bsod', 'powerbutton', 'unknown') { 'critical' } else { 'warning' }
        Add-Finding -Sev $sev -Title 'The page file is switched off' `
            -Plain 'The page file is space on your drive that Windows uses as overflow when RAM fills up. It is switched off on this PC. Even with lots of RAM, many games and programs expect it to exist and crash with "out of memory" errors without it. Windows also needs it to save crash information (the "dump") during a blue screen - without it, the cause of a blue screen can''t be recorded.' `
            -Steps @($fix) -Key 'PageFileOff' -Area 'Memory'
        return
    }
    $total = ($Info.Files | ForEach-Object { if ($_.MaxMB) { $_.MaxMB } else { $_.SizeMB } } | Measure-Object -Sum).Sum
    if ($total -lt 4096) {
        Add-Finding -Sev 'warning' -Title ('The page file is set to a small fixed size ({0:0.0} GB)' -f ($total / 1024)) `
            -Plain ('The page file (overflow space for RAM on your drive) is limited to {0:0.0} GB. Modern games can need much more, especially with {1} GB of RAM, and when it runs out they crash with "out of memory" errors.' -f ($total / 1024), $Info.RamGB) `
            -Steps @($fix) -Key 'PageFileSmall' -Area 'Memory'
    }
    if (-not @($Info.Files | Where-Object { $_.Name -like "$sysDrive*" }).Count) {
        Add-Finding -Sev 'info' -Title 'There is no page file on the Windows drive' `
            -Plain ('Your page file is only on {0}. Windows needs a page file on the Windows drive ({1}) to save crash information during a blue screen, so blue screens on this PC may leave no clues behind.' -f (($Info.Files | ForEach-Object { $_.Name }) -join ', '), $sysDrive) `
            -Steps @($fix) -Key 'PageFileNotOnC' -Area 'Memory'
    }
}
# ------------------------------------------------------------------ 23. drives almost full
function Get-VolumeSpace {
    try { return @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Where-Object { $_.Size -gt 0 } |
        ForEach-Object { [pscustomobject]@{ Drive = $_.DeviceID; Label = $_.VolumeName; SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1) } }) } catch { return @() }
}

function Invoke-FreeSpaceCheck([object[]]$Volumes) {
    $sysDrive = $env:SystemDrive; if (-not $sysDrive) { $sysDrive = 'C:' }
    foreach ($v in $Volumes) {
        if ($v.SizeGB -le 0) { continue }
        $pct = 100 * $v.FreeGB / $v.SizeGB
        $isSys = $v.Drive -eq $sysDrive
        # Only a drive with under 1% free is a real crash risk; anything above that is not reported.
        if ($pct -ge 1) { continue }
        $sev = if ($isSys) { 'critical' } else { 'warning' }
        $why = if ($isSys) { 'This is the Windows drive. When it is nearly full, Windows can''t grow the page file (so programs crash with "out of memory"), updates fail, crash information can''t be saved, and games stutter or crash while saving or downloading shaders.' }
               else { 'SSDs also get slower and wear faster when they are kept nearly full, and games installed here can fail to update or save.' }
        Add-Finding -Sev $sev -Title ('Drive {0} is almost full ({1:0.0} GB free, {2:0.0}%)' -f $v.Drive, $v.FreeGB, $pct) `
            -Plain ("Drive $($v.Drive)$(if ($v.Label) { " ($($v.Label))" }) has only {0:0.0} GB free out of {1:0} GB. $why" -f $v.FreeGB, $v.SizeGB) `
            -Steps @('Free up space: open Settings > System > Storage and run "Cleanup recommendations" (temporary files, old Windows update files, Recycle Bin).',
                     'Uninstall games and programs you no longer use (Settings > Apps > Installed apps, sort by size), or move games to another drive from Steam/Epic/etc.',
                     'Aim to keep a few percent of the drive free so Windows and games have room to work.') -Key "DiskFull|$($v.Drive)" -Area 'Drives'
    }
}
# ------------------------------------------------------------------ 24. crash shortly after waking from sleep / Fast Startup
function Get-FastStartupEnabled {
    try { return [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled -eq 1 } catch { return $null }
}

function Invoke-WakeCheck([object[]]$WakeEvents, $End, $SessionStart, $FastStartup) {
    if (-not $End -or $kind -notin 'bsod', 'powerloss', 'powerbutton', 'unknown') { return }
    $fsStep = 'Turn off Fast Startup: Control Panel > Power Options > "Choose what the power buttons do" > "Change settings that are currently unavailable" > untick "Turn on fast startup". It makes Windows resume drivers from a saved state instead of starting fresh, which keeps driver problems alive across shutdowns.'
    $wake = @($WakeEvents | Where-Object { $_.ProviderName -match 'Power-Troubleshooter' -and $_.Id -eq 1 -and $_.TimeCreated -le $End -and $_.TimeCreated -ge $End.AddMinutes(-5) } | Sort-Object TimeCreated) | Select-Object -Last 1
    if ($wake) {
        $after = $End - $wake.TimeCreated
        $steps = @('Update the chipset, graphics and network drivers - these are the drivers that have to "wake up" correctly.', 'Chipset', 'GpuDriver', 'Bios')
        if ($FastStartup) { $steps += $fsStep }
        $steps += 'As a test, stop the PC from sleeping (Settings > System > Power > Screen and sleep > "Never") for a few days. If the crashes stop, the problem is in waking up, not in normal use.'
        Add-Finding -Sev 'warning' -Title ('The crash happened {0} after the PC woke up from sleep' -f (Format-Span $after)) `
            -Plain ('The PC woke from sleep at {0:HH:mm:ss} and went down just {1} later. Crashes right after waking are usually caused by a driver (graphics, network, chipset, USB) that does not restart properly, or by a BIOS power-saving bug - not by the game or program that was running.' -f $wake.TimeCreated, (Format-Span $after)) `
            -Steps $steps -Key 'CrashAfterWake' -Area 'Windows'
        return
    }
    if ($FastStartup -and $SessionStart -and ($End - $SessionStart).TotalMinutes -le 10) {
        Add-Finding -Sev 'info' -Title 'The crash happened soon after turning on, and Fast Startup is on' `
            -Plain 'The PC went down within 10 minutes of starting. Fast Startup is turned on, which means "shut down" doesn''t fully restart Windows - drivers are restored from a saved copy. If a driver was in a bad state, it comes back every time you turn the PC on.' `
            -Steps @($fsStep, 'Use Restart (not Shut down) when you want a completely fresh start - Restart always ignores Fast Startup.') -Key 'FastStartup' -Area 'Windows'
    }
}
# ------------------------------------------------------------------ 26. Memory Integrity / VBS / Hyper-V
function Get-VbsInfo {
    $r = [pscustomobject]@{ Vbs = $null; Hvci = $null; Hypervisor = $null }
    try {
        $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        $r.Vbs = [int]$dg.VirtualizationBasedSecurityStatus -eq 2
        $r.Hvci = @($dg.SecurityServicesRunning) -contains 2
    } catch {
        try { $r.Hvci = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name Enabled -ErrorAction Stop).Enabled -eq 1 } catch { }
    }
    try { $r.Hypervisor = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch { }
    return $r
}

function Invoke-VbsCheck($Info, [int]$AppCrashCount = 0) {
    if (-not $Info) { return }
    $coreIso = 'Open Windows Security > Device security > Core isolation details.'
    if ($kind -eq 'bsod' -and $Info.Hvci) {
        Add-Finding -Sev 'info' -Title 'Memory Integrity (Core isolation) is on' `
            -Plain 'Memory Integrity is a Windows security feature that checks every driver before it runs. It is good for security, but some older drivers - often from RGB, fan-control, overclocking or old anti-cheat software - don''t work properly with it and can cause blue screens. It is worth checking whether Windows lists any incompatible drivers.' `
            -Steps @("$coreIso If you see `"Review incompatible drivers`", update or uninstall the program each driver belongs to (the driver name usually hints at it).", 'As a test only, you can turn Memory Integrity off, restart, and see if the blue screens stop. If they do, find and update the incompatible driver, then turn it back on - it protects you from malware.') `
            -Key 'HvciOn' -Area 'Windows'
    } elseif ($kind -eq 'bsod' -and $Info.Hvci -eq $false) {
        Add-Finding -Sev 'info' -Title 'Memory Integrity (Core isolation) is off' `
            -Plain 'Memory Integrity is a Windows security feature that blocks badly behaved or malicious drivers. It is off on this PC. It does not cause crashes when off, but turning it on can make Windows stop a broken driver from loading, and it will tell you which installed drivers are incompatible - a useful clue.' `
            -Steps @("$coreIso Try turning Memory Integrity on. If Windows refuses and lists incompatible drivers, those drivers are good suspects for the blue screens.") -Key 'HvciOff' -Area 'Windows'
    }
    if ($Info.Hypervisor -and $AppCrashCount -gt 0) {
        Add-Finding -Sev 'info' -Title 'Windows virtualization (Hyper-V / VBS) is running' `
            -Plain 'Windows is running its built-in virtualization layer (used by Memory Integrity, WSL, Windows Sandbox, Hyper-V or Android apps). Some older games, anti-cheat systems and emulators/virtual machines (old VirtualBox or VMware) crash or refuse to start when it is on.' `
            -Steps @('If only one specific game or emulator crashes, search "<game name> Hyper-V" or "<game name> VBS" to see if it is a known problem.', 'Update the game/emulator/VM software first - most current versions work fine with it.') -Key 'Hypervisor' -Area 'Windows'
    }
}
# ------------------------------------------------------------------ 27. high load while nobody was using the PC
function Invoke-IdleLoadCheck([object[]]$Snapshots) {
    $ik = 'User~Session|Idle|Seconds Since Input'
    if (-not $series.ContainsKey($ik)) { return }
    $idle = Get-TimeMap $ik
    $cpu = if ($SensorKey.CpuLoad) { Get-TimeMap $SensorKey.CpuLoad } else { @{} }
    $gpu = if ($SensorKey.GpuLoad) { Get-TimeMap $SensorKey.GpuLoad } else { @{} }
    $busyTimes = @()
    foreach ($t in ($idle.Keys | Sort-Object)) {
        if ($idle[$t] -lt 600) { continue }
        $c = if ($cpu.ContainsKey($t)) { $cpu[$t] } else { 0 }; $g = if ($gpu.ContainsKey($t)) { $gpu[$t] } else { 0 }
        if ($c -ge 50 -or $g -ge 50) { $busyTimes += [pscustomobject]@{ T = $t; Cpu = $c; Gpu = $g } }
    }
    if ($busyTimes.Count -lt 2) { return }
    # length of the longest run of busy readings (gaps up to 60 s allowed)
    $best = 0; $runStart = $busyTimes[0].T; $prev = $busyTimes[0].T; $bestStart = $runStart; $bestEnd = $runStart
    foreach ($b in $busyTimes) {
        if (($b.T - $prev).TotalSeconds -gt 60) { $runStart = $b.T }
        $len = ($b.T - $runStart).TotalSeconds
        if ($len -gt $best) { $best = $len; $bestStart = $runStart; $bestEnd = $b.T }
        $prev = $b.T
    }
    if ($best -lt 300) { return }
    $avgCpu = ($busyTimes | Where-Object { $_.T -ge $bestStart -and $_.T -le $bestEnd } | Measure-Object Cpu -Average).Average
    $avgGpu = ($busyTimes | Where-Object { $_.T -ge $bestStart -and $_.T -le $bestEnd } | Measure-Object Gpu -Average).Average
    # who was busy: count appearances in snapshots during that stretch
    $who = @{}
    foreach ($s in $Snapshots) {
        try { $st = [datetime]$s.t } catch { continue }
        if ($st -lt $bestStart -or $st -gt $bestEnd) { continue }
        foreach ($p in @($s.cpu) + @($s.gpu)) { if ($p -and $p.n -and [double]$p.v -ge 10) { $who[$p.n] = [int]$who[$p.n] + 1 } }
    }
    $top = @($who.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { $_.Key })
    $topText = if ($top.Count) { ' The busiest programs during that time were: ' + ($top -join ', ') + '.' } else { '' }
    $suspect = @($top | Where-Object { $_ -notmatch '^(MsMpEng|TiWorker|TrustedInstaller|SearchIndexer|MoUsoCoreWorker|svchost|System|Idle|CompatTelRunner|wuauserv|SgrmBroker|MpDefenderCoreService|steam|steamwebhelper|EpicGamesLauncher|OneDrive)$' })
    $sev = if ($suspect.Count) { 'warning' } else { 'info' }
    Add-Finding -Sev $sev -Title ('The PC was working hard for {0} while nobody was using it' -f (Format-Span ([TimeSpan]::FromSeconds($best)))) `
        -Plain ('From {0:HH:mm} to {1:HH:mm} no one had touched the keyboard or mouse for over 10 minutes, yet the CPU averaged {2:0}% and the graphics card {3:0}%.{4} Windows updates, antivirus scans and game launchers updating games do this normally. But hidden cryptocurrency miners (malware) also wait until you stop using the PC and then run the CPU or graphics card at full power - which makes it hot and can crash it.' -f $bestStart, $bestEnd, $avgCpu, $avgGpu, $topText) `
        -Steps @('If you don''t recognise a program named above, search its name online. Right-click it in Task Manager > Details > "Open file location" to see where it is installed.',
                 'Run a full scan: Windows Security > Virus & threat protection > Scan options > Full scan, and also "Microsoft Defender Offline scan".',
                 'Antivirus') -Key 'IdleLoad' -Area 'Software'
}
# ------------------------------------------------------------------ 28. monitoring paused / limited
function Get-MonitorMode([string]$SensorSource, $PausedInfo, [bool]$HadSensorData) {
    if ($PausedInfo) { return 'paused' }
    if (-not $HadSensorData) { return 'none' }
    if ($SensorSource -match 'off in settings') { return 'basic-by-choice' }
    if ($SensorSource -match 'basic') { return 'basic' }
    return 'full'
}

function Invoke-MonitorStatusCheck([string]$Mode, $PausedInfo) {
    switch ($Mode) {
        'paused' {
            Add-Finding -Sev 'info' -Title ('Monitoring was paused (since {0})' -f $PausedInfo.Since) `
                -Plain 'You paused the background monitoring, so this report has no temperature, power or program readings - only what Windows itself logged. That is fine for a while, but if the PC crashes, the readings are often the best clue.' `
                -Steps @('Double-click Resume-Monitoring.cmd in the PC Crash Reporter folder to turn it back on.') -Key 'MonitorPaused' -Area 'Tool'
        }
        'basic-by-choice' {
            Add-Finding -Sev 'info' -Title 'Hardware sensors are turned off in the settings' `
                -Plain 'config.json has UseHardwareSensors set to false, so only basic readings were recorded (CPU and memory load, and NVIDIA graphics card data). CPU temperature, power use, voltages and fan speeds are missing, so heat- and power-related problems can''t be detected.' `
                -Steps @('If you turned it off because of an anti-cheat warning, that''s a fair trade-off. Otherwise, open config.json in Notepad, change "UseHardwareSensors": false to true, save, and restart.') -Key 'SensorsOff' -Area 'Tool'
        }
    }
}
# ------------------------------------------------------------------ 29. planned restarts are not crashes
function Get-RestartReason([object[]]$Events) {
    $e = @($Events | Where-Object { $_.ProviderName -eq 'User32' -and $_.Id -eq 1074 } | Sort-Object TimeCreated) | Select-Object -Last 1
    if (-not $e) { return $null }
    $m = Get-EventDataMap $e
    $proc = "$($m['param1'])"; $reason = "$($m['param3'])"; $type = "$($m['param5'])"; $user = "$($m['param7'])"; $comment = "$($m['param6'])"
    if (-not $proc -and "$($e.Message)" -match 'The process (.+?) has initiated') { $proc = $matches[1] }
    if (-not $reason -and "$($e.Message)" -match 'following reason:\s*([^\r\n]+)') { $reason = $matches[1] }
    if (-not $type -and "$($e.Message)" -match 'Shutdown Type:\s*([^\r\n]+)') { $type = $matches[1].Trim() }
    $exe = ($proc -replace '\s*\(.*$', '') -replace '^.*\\', ''
    $who = 'app'
    if ($exe -match '^(TrustedInstaller|MoUsoCoreWorker|usoclient|wuauclt|UpdateOrchestrator|MusNotification|WaaSMedicAgent|SetupHost|setupprep)' -or ($reason -match 'Operating System: (Upgrade|Service pack|Hot ?fix|Security fix|Reconfiguration)' -and $exe -match '^(svchost|TrustedInstaller|MoUsoCoreWorker)')) { $who = 'update' }
    elseif ($exe -match '^(explorer|StartMenuExperienceHost|ShellExperienceHost|shutdown|winlogon|LogonUI|SystemSettings|ShellHost)\.exe$' -or ($exe -match '^shutdown' )) { $who = 'user' }
    return [pscustomobject]@{ Who = $who; Process = $exe; User = $user; Type = $type; Reason = $reason; Comment = $comment; Time = $e.TimeCreated }
}

function Invoke-NotACrashCheck($Restart) {
    if ($kind -ne 'clean' -or -not $Restart) { return }
    $verb = if ($Restart.Type -match 'power ?off|shutdown') { 'shut down' } else { 'restarted' }
    switch ($Restart.Who) {
        'update' {
            Add-Finding -Sev 'info' -Title "This was not a crash - Windows $verb itself to finish installing updates" `
                -Plain ("At {0:HH:mm} Windows Update {1} the PC on purpose to finish installing updates ({2}). Nothing went wrong. If it keeps restarting while you are using the PC, you can set your ""active hours"" so it waits." -f $Restart.Time, $verb, $Restart.Process) `
                -Steps @('Optional: Settings > Windows Update > Advanced options > Active hours - set them to when you usually use the PC.') -Key 'NotACrash|Update' -Area 'Windows'
        }
        'user' {
            Add-Finding -Sev 'info' -Title "This was not a crash - the PC was $verb normally" `
                -Plain ("At {0:HH:mm} someone chose to {1} the PC{2} (from the Start menu or similar). Nothing went wrong." -f $Restart.Time, $(if ($verb -eq 'restarted') { 'restart' } else { 'shut down' }), $(if ($Restart.User) { " (user $($Restart.User))" } else { '' })) `
                -Steps @() -Key 'NotACrash|User' -Area 'Windows'
        }
        default {
            Add-Finding -Sev 'info' -Title "This was not a crash - a program $verb the PC ($($Restart.Process))" `
                -Plain ("At {0:HH:mm} the program {1} asked Windows to {2} - usually an installer or updater finishing its job. Windows shut down normally. If you didn't expect this and it keeps happening, look up the program name." -f $Restart.Time, $Restart.Process, $(if ($verb -eq 'restarted') { 'restart' } else { 'shut down' })) `
                -Steps @() -Key 'NotACrash|App' -Area 'Windows'
        }
    }
}
# ------------------------------------------------------------------ 30. power button: was it really frozen, or just the screen?
function Invoke-DisplayOnlyCheck($LastSample, $PressTime, [int]$GpuHangEvents) {
    if ($kind -ne 'powerbutton' -or -not $LastSample -or -not $PressTime) { return }
    $gap = ($PressTime - $LastSample).TotalSeconds
    if ($gap -le 30 -and $GpuHangEvents -eq 0) {
        Add-Finding -Sev 'warning' -Title 'The PC was probably still running - only the picture was lost' `
            -Plain ('You held the power button at {0:HH:mm:ss}, but this tool was still recording normally until {1:HH:mm:ss} - just seconds before. A truly frozen PC stops recording. So the PC itself was most likely working, and the problem was the picture: the graphics card stopped sending a signal, or the monitor/cable lost it. Windows did not log a graphics driver crash.' -f $PressTime, $LastSample) `
            -Steps @('Next time the screen goes black or freezes, wait 30 seconds, then press Ctrl+Shift+Win+B (this restarts the graphics driver - you''ll hear a beep). Also try pressing Caps Lock to see if its light changes, or switch the monitor off and on.',
                     'Check the display cable is firmly in at both ends; try a different cable or port (DisplayPort vs HDMI). Make sure it is plugged into the graphics card, not the motherboard.',
                     'GpuDriver', 'If you use a high refresh rate (144 Hz+) or G-Sync/FreeSync, try a lower refresh rate for a few days to see if the blackouts stop.') `
            -Key 'DisplayOnly' -Area 'Graphics'
    } elseif ($gap -gt 30) {
        Add-Finding -Sev 'info' -Title ('The PC had really frozen {0} before you pressed the power button' -f (Format-Span ([TimeSpan]::FromSeconds($gap)))) `
            -Plain ('This tool stopped being able to record at {0:HH:mm:ss}, and the power button was held at {1:HH:mm:ss}. So the whole PC had locked up, not just the screen. Full freezes like this usually come from hardware (memory, overheating, power) or a driver that hangs the whole system.' -f $LastSample, $PressTime) `
            -Steps @('RamTest', 'Look at the "Right before it ended" section for temperatures and what was running.', 'DriverRecent') -Key 'RealFreeze' -Area 'Windows'
    }
}
# ------------------------------------------------------------------ 31. patterns across crashes
$script:HistoryExtraCols = 'Game', 'GpuPowerEnd', 'CpuTempMax', 'GpuTempMax', 'AfterWake', 'MonitorMode', 'CpuLoadTemp', 'CpuLoadN', 'CpuIdleTemp', 'CpuIdleN', 'GpuLoadTemp', 'GpuLoadN', 'GpuIdleTemp', 'GpuIdleN'

function Get-MainProgram($Snapshot) {
    # The program most likely in use at the end: top GPU user, else top CPU user that isn't Windows itself
    if (-not $Snapshot) { return '' }
    $skip = '^(System|Idle|dwm|csrss|explorer|svchost|MsMpEng|Memory Compression|Registry|audiodg|WindowsTerminal|powershell|conhost|SearchHost|ShellExperienceHost|StartMenuExperienceHost|TextInputHost|ctfmon|nvcontainer|RuntimeBroker|Discord|chrome|msedge|firefox|steamwebhelper|Spotify)$'
    $g = @($Snapshot.gpu | Where-Object { $_ -and $_.n -notmatch $skip -and [double]$_.v -ge 15 }) | Select-Object -First 1
    if ($g) { return [string]$g.n }
    $c = @($Snapshot.cpu | Where-Object { $_ -and $_.n -notmatch $skip -and [double]$_.v -ge 10 }) | Select-Object -First 1
    if ($c) { return [string]$c.n }
    return ''
}

function Get-CrashPatterns([object[]]$Rows, [datetime]$Now) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $crashes = @($Rows | Where-Object { $_.Outcome -in 'bsod', 'powerloss', 'powerbutton', 'sleepfail' -and $(try { [datetime]::Parse($_.SessionStart, $inv) -ge $Now.AddDays(-60) } catch { $false }) })
    $n = $crashes.Count
    $out = @()
    if ($n -lt 3) { return $out }
    $num = { param($v) $d = 0.0; if ([double]::TryParse("$v", [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { $d } else { $null } }
    # same program
    $games = @($crashes | Where-Object { $_.Game } | Group-Object Game | Sort-Object Count -Descending)
    if ($games.Count -and $games[0].Count -ge 3 -and $games[0].Count -ge 0.6 * $n) {
        $out += [pscustomobject]@{ Text = ('{0} of your last {1} crashes happened while {2} was running.' -f $games[0].Count, $n, $games[0].Name); Step = "Focus on $($games[0].Name): verify/repair its files in the launcher, turn off its overlays and any in-game frame generation, and check its forums for the same crash. If it is the only thing that crashes, the problem may be the game, not your PC - but games are also the heaviest load, so they expose weak power supplies, overheating and unstable memory first." }
    }
    # graphics card power at the moment of the crash
    $gp = @($crashes | ForEach-Object { & $num $_.GpuPowerEnd } | Where-Object { $null -ne $_ })
    if ($gp.Count -ge 3 -and $gp.Count -ge 0.6 * $n) {
        $minGp = ($gp | Measure-Object -Minimum).Minimum
        if ($minGp -ge 150) {
            $out += [pscustomobject]@{ Text = ('All {0} crashes with readings happened with the graphics card drawing at least {1:0} W.' -f $gp.Count, $minGp); Step = 'Crashes only under heavy graphics load point to the power supply or GPU power cables. Test with the GPU power limit lowered to 80% (MSI Afterburner) - if the crashes stop, check cables and the power supply.' }
        } elseif (($gp | Measure-Object -Maximum).Maximum -le 60) {
            $out += [pscustomobject]@{ Text = ('All {0} crashes with readings happened while the graphics card was nearly idle (under {1:0} W).' -f $gp.Count, ($gp | Measure-Object -Maximum).Maximum); Step = 'Crashes at low load (desktop, browsing, idle) point away from power and heat and toward memory (EXPO/XMP), drivers, or the CPU''s low-power states. Try turning EXPO/XMP off for a few days.' }
        }
    }
    # hot every time
    $ct = @($crashes | ForEach-Object { & $num $_.CpuTempMax } | Where-Object { $null -ne $_ })
    if ($ct.Count -ge 3 -and @($ct | Where-Object { $_ -ge $Th.CpuTempWarn }).Count -ge 0.75 * $ct.Count) {
        $out += [pscustomobject]@{ Text = ('In {0} of {1} crashes the CPU had reached {2} C or more.' -f @($ct | Where-Object { $_ -ge $Th.CpuTempWarn }).Count, $ct.Count, $Th.CpuTempWarn); Step = 'Cooling' }
    }
    $gt = @($crashes | ForEach-Object { & $num $_.GpuTempMax } | Where-Object { $null -ne $_ })
    if ($gt.Count -ge 3 -and @($gt | Where-Object { $_ -ge $Th.GpuTempWarn }).Count -ge 0.75 * $gt.Count) {
        $out += [pscustomobject]@{ Text = ('In {0} of {1} crashes the graphics card had reached {2} C or more.' -f @($gt | Where-Object { $_ -ge $Th.GpuTempWarn }).Count, $gt.Count, $Th.GpuTempWarn); Step = 'GpuTemps' }
    }
    # after waking
    $wk = @($crashes | Where-Object { $_.AfterWake -eq 'True' }).Count
    if ($wk -ge 2 -and $wk -ge 0.5 * $n) { $out += [pscustomobject]@{ Text = ('{0} of {1} crashes happened within minutes of waking from sleep.' -f $wk, $n); Step = 'Stop the PC from sleeping for a week as a test (Settings > System > Power > Sleep: Never), and update chipset and graphics drivers.' } }
    # same stop code / driver
    $codes = @($crashes | Where-Object { $_.StopCode } | Group-Object StopCode | Sort-Object Count -Descending)
    if ($codes.Count -and $codes[0].Count -ge 3) {
        $nm = ($codes[0].Group | Where-Object { $_.StopName } | Select-Object -First 1).StopName
        $out += [pscustomobject]@{ Text = ('{0} blue screens had the same error code: {1}{2}.' -f $codes[0].Count, $codes[0].Name, $(if ($nm) { " ($nm)" } else { '' })); Step = 'The same code every time means the same cause - follow the advice for that code in the "Blue screen details" section first.' }
    } elseif ($codes.Count -ge 3 -and @($codes | Where-Object { $_.Count -eq 1 }).Count -ge 3) {
        $out += [pscustomobject]@{ Text = ('Your blue screens had {0} different error codes.' -f $codes.Count); Step = 'Many different blue-screen codes usually means unstable hardware rather than one bad driver - most often memory. Turn EXPO/XMP off and run a memory test.' }
    }
    $drv = @($crashes | Where-Object { $_.Driver } | Group-Object Driver | Sort-Object Count -Descending)
    if ($drv.Count -and $drv[0].Count -ge 2) { $out += [pscustomobject]@{ Text = ('{0} crashes pointed at the same driver: {1}.' -f $drv[0].Count, $drv[0].Name); Step = "Update, roll back, or reinstall whatever $($drv[0].Name) belongs to." } }
    # all the same kind
    $kinds = @($crashes | Group-Object Outcome)
    if ($kinds.Count -eq 1 -and $crashes[0].Outcome -eq 'powerloss') { $out += [pscustomobject]@{ Text = ('All {0} were sudden power-offs with no blue screen.' -f $n); Step = 'Sudden power-offs (no blue screen) almost always come from power: the power supply, its cables, or the wall socket - or from extreme overheating.' } }
    return $out
}

function Invoke-PatternCheck([object[]]$Rows, [datetime]$Now) {
    $p = @(Get-CrashPatterns $Rows $Now)
    if (-not $p.Count) { return }
    Add-Finding -Sev 'warning' -Title ('Patterns found across your recent crashes ({0})' -f $p.Count) `
        -Plain ('Looking at all crashes in the last 60 days together: ' + (($p | ForEach-Object { $_.Text }) -join ' ') + ' Patterns like these are often more useful than any single crash.') `
        -Steps @($p | ForEach-Object { $_.Step }) -Key 'Patterns' -Area 'Patterns'
}