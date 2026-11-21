<#
  Automated tests for PC Crash Reporter's detection checks.
  Feeds each check fake sensor data / fake Windows events and checks the right finding appears.
  Run:  powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Common.ps1')
. (Join-Path $root 'lib\Knowledge.ps1')
. (Join-Path $root 'lib\DumpParser.ps1')
. (Join-Path $root 'lib\Checks.ps1')

$script:pass = 0; $script:fail = 0
$script:inv = [Globalization.CultureInfo]::InvariantCulture
$script:cfg = Get-Config
$script:Th = $cfg.Thresholds
$script:T0 = (Get-Date).Date.AddHours(12)

function Test-That([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}
function Reset-Context {
    $script:findings = New-Object System.Collections.Generic.List[object]
    $script:series = @{}
    $script:SensorKey = [ordered]@{}
    $script:kind = 'running'
    $script:endTime = $T0.AddMinutes(30)
    $script:endedAtCrash = $false
    $script:start = New-Object System.Collections.Generic.List[string]
    $script:story = @()
    $script:sys = [ordered]@{}
}
# Adds a sensor series: one value every $Step seconds starting at $Start
function Set-Series([string]$Key, [double[]]$Values, [datetime]$Start = $T0, [int]$Step = 5) {
    $s = @{ T = New-Object System.Collections.Generic.List[datetime]; V = New-Object System.Collections.Generic.List[double] }
    for ($i = 0; $i -lt $Values.Count; $i++) { $s.T.Add($Start.AddSeconds($i * $Step)); $s.V.Add($Values[$i]) }
    $script:series[$Key] = $s
}
# Get-Repeat <value> <count>: e.g. Get-Repeat 12.1 20 = twenty readings of 12.1
function Get-Repeat([double]$Value, [int]$Count) { return @(1..$Count | ForEach-Object { $Value }) }
function Test-Finding([string]$Pattern) { return @($script:findings | Where-Object { $_.Title -match $Pattern }).Count -gt 0 }
function Get-Finding([string]$Pattern) { return $script:findings | Where-Object { $_.Title -match $Pattern } | Select-Object -First 1 }
# Builds a fake event that works with Get-EventDataMap and .Message/.Properties
function New-FakeEvent([string]$Provider, [int]$Id, [datetime]$Time, [string]$Message = '', [hashtable]$Data = @{}, [int]$Level = 2) {
    $xmlData = ($Data.GetEnumerator() | ForEach-Object { "<Data Name='$($_.Key)'>$([Security.SecurityElement]::Escape([string]$_.Value))</Data>" }) -join ''
    $o = [pscustomobject]@{ ProviderName = $Provider; Id = $Id; TimeCreated = $Time; Message = $Message; Level = $Level; RecordId = Get-Random
        Properties = @($Data.Values | ForEach-Object { [pscustomobject]@{ Value = $_ } }) }
    $x = "<Event><EventData>$xmlData</EventData></Event>"
    $o | Add-Member -MemberType ScriptMethod -Name ToXml -Value ([scriptblock]::Create("'$($x -replace "'", "''")'"))
    return $o
}

Write-Host "`n== Harness self-check" -ForegroundColor Cyan
Reset-Context
Set-Series 'Cpu~Test CPU|Temperature|Core (Tctl/Tdie)' @(40, 50, 60)
$st = Get-Stats 'Cpu~Test CPU|Temperature|Core (Tctl/Tdie)'
Test-That 'Get-Stats max' ($st.Max -eq 60)
Test-That 'Find-SensorKey' ((Find-SensorKey '^Cpu~' 'Temperature' @('Core (Tctl/Tdie)')) -eq 'Cpu~Test CPU|Temperature|Core (Tctl/Tdie)')
Add-Finding -Sev 'info' -Title 'hello' -Plain 'x'
Test-That 'Add-Finding writes to findings' (Test-Finding 'hello')

# ==== TESTS FOR EACH CHECK ARE ADDED BELOW ====

Write-Host "`n== 1. VRM temperature" -ForegroundColor Cyan
Reset-Context
Set-Series 'SuperIO~Nuvoton NCT6687D|Temperature|VRM MOS' @(60, 80, 104, 106, 90)
Invoke-VrmTempCheck
Test-That 'VRM at 106 C gives a warning' ((Get-Finding 'motherboard power circuits').Sev -eq 'warning')
Reset-Context
Set-Series 'SuperIO~Nuvoton NCT6687D|Temperature|VRM MOS' @(60, 112, 90)
Invoke-VrmTempCheck
Test-That 'VRM at 112 C is critical' ((Get-Finding 'motherboard power circuits').Sev -eq 'critical')
Reset-Context
Set-Series 'SuperIO~Nuvoton NCT6687D|Temperature|VRM MOS' @(40, 55, 60)
Set-Series 'SuperIO~Nuvoton NCT6687D|Temperature|PCH' @(40, 105, 60)
Invoke-VrmTempCheck
Test-That 'Cool VRM and non-VRM sensors are not flagged' ($findings.Count -eq 0)

Write-Host "`n== 2. Weak / failing PSU" -ForegroundColor Cyan
function Set-PowerScenario([double[]]$Gpu) {
    Set-Series 'Cpu~Test CPU|Power|Package' (Get-Repeat 40 $Gpu.Count)
    Set-Series 'GpuNvidia~Test GPU|Power|GPU Package' $Gpu
    $script:SensorKey.CpuPower = 'Cpu~Test CPU|Power|Package'; $script:SensorKey.GpuPower = 'GpuNvidia~Test GPU|Power|GPU Package'
}
Reset-Context; $script:kind = 'powerloss'
Set-PowerScenario (@(Get-Repeat 30 20) + @(250, 280, 300))
Invoke-PsuCheck
Test-That 'Shutoff at peak power is flagged as critical' ((Get-Finding 'shut off while drawing').Sev -eq 'critical')
Test-That 'PowerAtEnd recorded' ($PowerAtEnd.EndPeak -eq 340)
Reset-Context; $script:kind = 'powerloss'
Set-PowerScenario (@(Get-Repeat 30 10) + @(300) + (Get-Repeat 30 20))
Invoke-PsuCheck
Test-That 'Earlier spike but calm at shutoff is not flagged' (-not (Test-Finding 'shut off while drawing'))
Reset-Context; $script:kind = 'clean'
Set-PowerScenario (@(Get-Repeat 30 20) + @(250, 280, 300))
Invoke-PsuCheck
Test-That 'High power at a normal shutdown is not flagged' (-not (Test-Finding 'shut off while drawing'))
Reset-Context; $script:kind = 'powerloss'
Set-Series 'SuperIO~Nuvoton|Voltage|+12V' (@(Get-Repeat 12.1 20) + @(11.3, 11.2))
Invoke-PsuCheck
Test-That '12V dip at the end of a power loss is critical' ((Get-Finding '12V power rail').Sev -eq 'critical')
Reset-Context
Set-Series 'SuperIO~Nuvoton|Voltage|+12V' (Get-Repeat 12.1 20)
Set-Series 'SuperIO~Nuvoton|Voltage|+5V' (Get-Repeat 5.05 20)
Invoke-PsuCheck
Test-That 'Healthy rails are not flagged' ($findings.Count -eq 0)
Reset-Context
Set-Series 'SuperIO~Nuvoton|Voltage|+12V' (Get-Repeat 4.2 20)
Invoke-PsuCheck
Test-That 'Nonsense 12V reading (misread sensor) is ignored' ($findings.Count -eq 0)

Write-Host "`n== 3. GPU power cable at shutoff" -ForegroundColor Cyan
Reset-Context; $script:kind = 'powerloss'
Set-PowerScenario (@(Get-Repeat 30 20) + @(220, 230))
Invoke-GpuCableCheck
Test-That 'High GPU power at shutoff suggests separate cables' (Test-Finding 'graphics card was drawing 230 W')
Reset-Context; $script:kind = 'powerloss'
Set-PowerScenario (Get-Repeat 25 20)
Invoke-GpuCableCheck
Test-That 'Idle GPU at shutoff is not flagged' ($findings.Count -eq 0)
Reset-Context; $script:kind = 'bsod'
Set-PowerScenario (@(Get-Repeat 30 20) + @(220, 230))
Invoke-GpuCableCheck
Test-That 'Not flagged for blue screens' ($findings.Count -eq 0)

Write-Host "`n== 5. Temperatures vs own history" -ForegroundColor Cyan
function Set-TempLoad([double]$Temp, [double]$Load, [int]$N) {
    Set-Series 'Cpu~Test CPU|Temperature|Core (Tctl/Tdie)' (Get-Repeat $Temp $N)
    Set-Series 'Cpu~Test CPU|Load|CPU Total' (Get-Repeat $Load $N)
    $script:SensorKey.CpuTemp = 'Cpu~Test CPU|Temperature|Core (Tctl/Tdie)'; $script:SensorKey.CpuLoad = 'Cpu~Test CPU|Load|CPU Total'
}
$base = @(
    [pscustomobject]@{ SessionStart = $T0.AddDays(-40).ToString('s'); CpuLoadTemp = 66; CpuLoadN = 100; CpuIdleTemp = 40; CpuIdleN = 100; GpuLoadTemp = ''; GpuLoadN = 0; GpuIdleTemp = ''; GpuIdleN = 0 },
    [pscustomobject]@{ SessionStart = $T0.AddDays(-30).ToString('s'); CpuLoadTemp = 68; CpuLoadN = 100; CpuIdleTemp = 41; CpuIdleN = 100; GpuLoadTemp = ''; GpuLoadN = 0; GpuIdleTemp = ''; GpuIdleN = 0 },
    [pscustomobject]@{ SessionStart = $T0.AddDays(-2).ToString('s');  CpuLoadTemp = 90; CpuLoadN = 100; CpuIdleTemp = 60; CpuIdleN = 100; GpuLoadTemp = ''; GpuLoadN = 0; GpuIdleTemp = ''; GpuIdleN = 0 })
Reset-Context; Set-TempLoad 83 90 30
$prof = Get-TempProfile
Test-That 'Profile: CPU load temp measured' ($prof.CpuLoadTemp -eq 83 -and $prof.CpuLoadN -eq 30)
Invoke-TempHistoryCheck $prof $base $T0
Test-That '16 C hotter under load than a month ago is critical' ((Get-Finding 'CPU runs 16 C hotter under load').Sev -eq 'critical')
Reset-Context; Set-TempLoad 70 90 30
Invoke-TempHistoryCheck (Get-TempProfile) $base $T0
Test-That 'Similar temps to history are not flagged' ($findings.Count -eq 0)
Reset-Context; Set-TempLoad 83 90 30
Invoke-TempHistoryCheck (Get-TempProfile) @($base[2]) $T0
Test-That 'No flag without at least 2 sessions of history from 2+ weeks ago' ($findings.Count -eq 0)
Reset-Context; Set-TempLoad 83 90 5
Invoke-TempHistoryCheck (Get-TempProfile) $base $T0
Test-That 'No flag with too few readings at load' ($findings.Count -eq 0)

Write-Host "`n== 7. RAM slot placement" -ForegroundColor Cyan
function New-Dimm($Loc, $Bank) { [pscustomobject]@{ DeviceLocator = $Loc; BankLabel = $Bank } }
Reset-Context; Invoke-RamSlotCheck @((New-Dimm 'DIMMA1' 'P0 CHANNEL A'), (New-Dimm 'DIMMB1' 'P0 CHANNEL B')) 4
Test-That 'A1 + B1 on a 4-slot board suggests A2 + B2' (Test-Finding 'first slots of each channel')
Reset-Context; Invoke-RamSlotCheck @((New-Dimm 'DIMMA2' 'P0 CHANNEL A'), (New-Dimm 'DIMMB2' 'P0 CHANNEL B')) 4
Test-That 'A2 + B2 is fine' ($findings.Count -eq 0)
Reset-Context; Invoke-RamSlotCheck @((New-Dimm 'DIMMA1' 'P0 CHANNEL A'), (New-Dimm 'DIMMB1' 'P0 CHANNEL B')) 2
Test-That 'A1 + B1 on a 2-slot board is fine' ($findings.Count -eq 0)
Reset-Context; Invoke-RamSlotCheck @((New-Dimm 'DIMMA1' 'P0 CHANNEL A'), (New-Dimm 'DIMMA2' 'P0 CHANNEL A')) 4
Test-That 'Both on channel A is single-channel warning' ((Get-Finding 'same channel').Sev -eq 'warning')
Reset-Context; Invoke-RamSlotCheck @((New-Dimm 'Controller0-ChannelA-DIMM0' 'BANK 0'), (New-Dimm 'Controller1-ChannelA-DIMM0' 'BANK 0')) 4
Test-That 'Intel-style names: two controllers are not treated as the same channel' (-not (Test-Finding 'same channel'))
Reset-Context; Invoke-RamSlotCheck @((New-Dimm 'ChannelA-DIMM1' 'BANK 0'), (New-Dimm 'ChannelB-DIMM1' 'BANK 2')) 4
Test-That 'Intel-style ChannelA-DIMM1 + ChannelB-DIMM1 is fine' ($findings.Count -eq 0)
Reset-Context; Invoke-RamSlotCheck @((New-Dimm 'DIMMA1' ''), (New-Dimm 'DIMMA2' ''), (New-Dimm 'DIMMB1' '')) 4
Test-That '3 sticks flagged' (Test-Finding '3 RAM sticks')

Write-Host "`n== 8. CPU voltages" -ForegroundColor Cyan
Test-That 'i9-14900K is Raptor Lake' (Test-IsIntelRaptorLake '14th Gen Intel(R) Core(TM) i9-14900K')
Test-That 'i5-13400F is not affected' (-not (Test-IsIntelRaptorLake '13th Gen Intel(R) Core(TM) i5-13400F'))
Test-That 'i5-13600KF is affected' (Test-IsIntelRaptorLake '13th Gen Intel(R) Core(TM) i5-13600KF')
Test-That 'Ryzen 5 8400F is AM5' (Test-IsAmdAm5 'AMD Ryzen 5 8400F 6-Core Processor')
Test-That 'Ryzen 7 5800X is not AM5' (-not (Test-IsAmdAm5 'AMD Ryzen 7 5800X 8-Core Processor'))
Reset-Context
Set-Series 'Motherboard~Board|Voltage|Vcore' (@(Get-Repeat 1.2 10) + @(1.52, 1.53, 1.55))
Invoke-CpuVoltageCheck '14th Gen Intel(R) Core(TM) i7-14700K'
Test-That '1.53 V on a 14700K warns about degradation' (Test-Finding 'too high for a 13th/14th gen')
Reset-Context
Set-Series 'Motherboard~Board|Voltage|Vcore' (@(Get-Repeat 1.2 10) + @(1.52, 1.53, 1.54))
Invoke-CpuVoltageCheck 'AMD Ryzen 7 9700X 8-Core Processor'
Test-That '1.53 V on Ryzen is under the generic limit (normal boost)' ($findings.Count -eq 0)
Reset-Context
Set-Series 'Cpu~AMD Ryzen 5 8400F|Voltage|SoC (SVI2 TFN)' (Get-Repeat 1.5 20)
Set-Series 'Cpu~AMD Ryzen 5 8400F|Voltage|Core (SVI2 TFN)' (Get-Repeat 1.6 20)
Invoke-CpuVoltageCheck 'AMD Ryzen 5 8400F 6-Core Processor'
Test-That 'Bogus SVI2 readings on AM5 are ignored (this PC)' ($findings.Count -eq 0)
Reset-Context
Set-Series 'SuperIO~Board|Voltage|VSOC' (Get-Repeat 1.35 20)
Invoke-CpuVoltageCheck 'AMD Ryzen 7 7800X3D 8-Core Processor'
Test-That 'SoC 1.35 V on AM5 is critical' ((Get-Finding 'SoC voltage').Sev -eq 'critical')

Write-Host "`n== 9. SMART (SATA drives)" -ForegroundColor Cyan
function New-SmartBytes([hashtable]$Attr) {
    $b = New-Object byte[] 512; $i = 0
    foreach ($id in $Attr.Keys) { $o = 2 + $i * 12; $b[$o] = [byte]$id; $raw = [uint64]$Attr[$id]; for ($k = 0; $k -lt 6; $k++) { $b[$o + 5 + $k] = [byte]($raw % 256); $raw = [uint64][math]::Floor($raw / 256) }; $i++ }
    return ,$b
}
$parsed = ConvertFrom-SmartData (New-SmartBytes @{ 5 = 3; 9 = 15000; 199 = 300 })
Test-That 'Parses reallocated sectors' ($parsed[5] -eq 3)
Test-That 'Parses multi-byte raw value (power-on hours 15000)' ($parsed[9] -eq 15000)
Reset-Context; Invoke-SmartCheck @([pscustomobject]@{ Name = 'Test HDD'; Attributes = (ConvertFrom-SmartData (New-SmartBytes @{ 5 = 3; 197 = 0 })) })
Test-That '3 reallocated sectors is a warning' ((Get-Finding 'replaced 3 bad sectors').Sev -eq 'warning')
Reset-Context; Invoke-SmartCheck @([pscustomobject]@{ Name = 'Test HDD'; Attributes = (ConvertFrom-SmartData (New-SmartBytes @{ 197 = 8 })) })
Test-That 'Pending sectors are critical' ((Get-Finding 'unreadable sectors').Sev -eq 'critical')
Reset-Context; Invoke-SmartCheck @([pscustomobject]@{ Name = 'Test SSD'; Attributes = (ConvertFrom-SmartData (New-SmartBytes @{ 199 = 40 })) }) @{ 'Test SSD' = 12 }
Test-That 'Rising CRC count blames the cable' (Test-Finding 'Cable errors on drive .Test SSD. went up \(12 -> 40\)')
Reset-Context; Invoke-SmartCheck @([pscustomobject]@{ Name = 'Test SSD'; Attributes = (ConvertFrom-SmartData (New-SmartBytes @{ 199 = 40 })) }) @{ 'Test SSD' = 40 }
Test-That 'Unchanged CRC count is not flagged' ($findings.Count -eq 0)
Reset-Context; Invoke-SmartCheck @([pscustomobject]@{ Name = 'Good'; Attributes = (ConvertFrom-SmartData (New-SmartBytes @{ 5 = 0; 9 = 100 })) })
Test-That 'Healthy drive is not flagged' ($findings.Count -eq 0)
Test-That 'Get-SmartDrives runs on this PC (NVMe only = empty list)' (@(Get-SmartDrives).Count -ge 0)

Write-Host "`n== 10. SSD firmware" -ForegroundColor Cyan
$drv = @([pscustomobject]@{ Name = 'KINGSTON SNV2S1000G'; Firmware = 'CBG04418'; Media = 'SSD' })
Test-That 'Kingston NV2 -> Kingston SSD Manager' ((Get-SsdTool 'KINGSTON SNV2S1000G') -eq 'Kingston SSD Manager')
Test-That 'Samsung 990 PRO -> Samsung Magician' ((Get-SsdTool 'Samsung SSD 990 PRO 2TB') -eq 'Samsung Magician')
Reset-Context; Invoke-FirmwareCheck $drv @{ 'KINGSTON SNV2S1000G' = 'CBG04418' } $false
Test-That 'Same firmware, no drive trouble: nothing flagged' ($findings.Count -eq 0)
Reset-Context; Invoke-FirmwareCheck $drv @{ 'KINGSTON SNV2S1000G' = 'CBG04300' } $false
Test-That 'Firmware change is noted' (Test-Finding 'firmware changed \(CBG04300 -> CBG04418\)')
Reset-Context; Invoke-FirmwareCheck $drv @{} $true
Test-That 'Drive trouble suggests a firmware update with the right tool' ((Get-Finding 'SSD firmware update').Steps[0] -match 'Kingston SSD Manager')

Write-Host "`n== 11. PCI Express errors" -ForegroundColor Cyan
$msgGpu = "A corrected hardware error has occurred.`r`n`r`nComponent: PCI Express Endpoint`r`nError Source: Advanced Error Reporting (PCI Express)`r`n`r`nPrimary Bus:Device:Function: 0x1:0x0:0x0`r`nSecondary Bus:Device:Function: 0x0:0x0:0x0`r`nPrimary Device Name:PCI\VEN_10DE&DEV_2803&SUBSYS_51601462&REV_A1`r`nVendor ID:Device ID: 0x10DE:0x2803"
$msgRoot = $msgGpu.Replace('PCI Express Endpoint', 'PCI Express Root Port').Replace('0x10DE:0x2803', '0x1022:0x14DB')
$ev = @(1..12 | ForEach-Object { New-FakeEvent 'Microsoft-Windows-WHEA-Logger' 17 $T0.AddMinutes($_) $msgGpu -Level 3 })
Reset-Context; Invoke-WheaPcieCheck $ev
$f = Get-Finding 'PCI Express'
Test-That 'GPU PCIe errors name the NVIDIA card' ($f.Title -match 'NVIDIA graphics card')
Test-That 'Corrected errors are a warning with count 12' ($f.Sev -eq 'warning' -and $f.Count -eq 12)
Test-That 'Advice mentions PCIe Link Speed' (($f.Steps -join ' ') -match 'PCIe Link Speed')
Reset-Context; Invoke-WheaPcieCheck @(New-FakeEvent 'Microsoft-Windows-WHEA-Logger' 18 $T0 ("A fatal hardware error has occurred.`r`n" + $msgRoot))
Test-That 'Fatal root-port error is critical and explains the slot' ((Get-Finding 'PCI Express').Sev -eq 'critical' -and (Get-Finding 'PCI Express').Plain -match 'whatever is plugged into that slot')
Reset-Context; Invoke-WheaPcieCheck @(New-FakeEvent 'Microsoft-Windows-WHEA-Logger' 19 $T0 'A corrected hardware error has occurred. Component: Processor Core Error Source: Corrected Machine Check')
Test-That 'Non-PCIe WHEA events are left to the general check' ($findings.Count -eq 0)

Write-Host "`n== 12. Graphics card dropping out" -ForegroundColor Cyan
function Set-GpuScenario([int]$CpuN, [int]$GpuN, [double[]]$GpuPower = $null) {
    Set-Series 'Cpu~Test CPU|Load|CPU Total' (Get-Repeat 30 $CpuN)
    Set-Series 'GpuNvidia~Test GPU|Temperature|GPU Core' (Get-Repeat 60 $GpuN)
    if ($GpuPower) { Set-Series 'GpuNvidia~Test GPU|Power|GPU Package' $GpuPower; $script:SensorKey.GpuPower = 'GpuNvidia~Test GPU|Power|GPU Package' }
    $script:SensorKey.CpuLoad = 'Cpu~Test CPU|Load|CPU Total'; $script:SensorKey.GpuTemp = 'GpuNvidia~Test GPU|Temperature|GPU Core'
}
Reset-Context; Set-GpuScenario 40 30
Invoke-GpuDropoutCheck
Test-That 'GPU sensors silent 50 s before CPU sensors = critical' ((Get-Finding 'stopped responding').Sev -eq 'critical')
Reset-Context; Set-GpuScenario 40 40
Invoke-GpuDropoutCheck
Test-That 'GPU and CPU sensors ending together is fine' ($findings.Count -eq 0)
Reset-Context; Set-GpuScenario 40 40 (@(Get-Repeat 180 20) + @(0) + (Get-Repeat 170 19))
Invoke-GpuDropoutCheck
Test-That 'Instant drop from 180 W to 0 W is flagged' (Test-Finding 'power suddenly dropped to zero while it was busy \(1 time\)')
Reset-Context; Set-GpuScenario 40 40 (@(Get-Repeat 180 20) + @(90, 40, 15) + (Get-Repeat 15 17))
Invoke-GpuDropoutCheck
Test-That 'Normal ramp-down is not flagged' ($findings.Count -eq 0)

Write-Host "`n== 13. USB errors before the crash" -ForegroundColor Cyan
$end = $T0.AddMinutes(30)
$usbEv = @(
    (New-FakeEvent 'Microsoft-Windows-Kernel-PnP' 219 $end.AddMinutes(-3) 'The driver \Driver\WUDFRd failed to load for the device USB\VID_1B1C&PID_0C1A\6&2b.' -Level 3),
    (New-FakeEvent 'Microsoft-Windows-USB-USBHUB3' 43 $end.AddMinutes(-1) 'Port reset failed' -Level 2))
Reset-Context; $script:kind = 'bsod'; Invoke-UsbCheck $usbEv $end
$f = Get-Finding 'USB error'
Test-That 'USB errors before a blue screen are a warning' ($f.Sev -eq 'warning' -and $f.Count -eq 2)
Test-That 'Device VID/PID is named' ($f.Plain -match 'USB\\VID_1B1C&PID_0C1A')
Reset-Context; $script:kind = 'bsod'; Invoke-UsbCheck @(New-FakeEvent 'Microsoft-Windows-USB-USBHUB3' 43 $end.AddMinutes(-40) 'old' -Level 2) $end
Test-That 'USB errors 40 minutes earlier are ignored' ($findings.Count -eq 0)
Reset-Context; Invoke-UsbCheck @(New-FakeEvent 'Microsoft-Windows-Kernel-PnP' 219 $end.AddMinutes(-2) 'The driver failed to load for the device PCI\VEN_8086.' -Level 3) $end
Test-That 'Non-USB device errors are ignored' ($findings.Count -eq 0)

Write-Host "`n== 14. CMOS battery" -ForegroundColor Cyan
Reset-Context; Set-Series 'SuperIO~Nuvoton|Voltage|VBAT' (Get-Repeat 2.55 20); Invoke-CmosBatteryCheck @()
Test-That 'VBAT 2.55 V gives a warning' ((Get-Finding 'CMOS battery').Sev -eq 'warning')
Reset-Context; Set-Series 'SuperIO~Nuvoton|Voltage|VBAT' (Get-Repeat 3.04 20); Invoke-CmosBatteryCheck @()
Test-That 'VBAT 3.04 V is fine' ($findings.Count -eq 0)
$jump = New-FakeEvent 'Microsoft-Windows-Kernel-General' 1 $T0 'The system time has changed' @{ NewTime = '2019-01-01T00:05:00.000Z'; OldTime = '2026-11-20T12:00:00.000Z'; Reason = '2' } -Level 4
Reset-Context; Invoke-CmosBatteryCheck @($jump)
Test-That 'Motherboard clock reset back to 2019 at boot is detected' ((Get-Finding 'CMOS battery').Plain -match '2019-01-01')
$fix = New-FakeEvent 'Microsoft-Windows-Kernel-General' 1 $T0 'The system time has changed' @{ NewTime = '2026-11-20T12:00:00.000Z'; OldTime = '2019-01-01T00:05:00.000Z'; Reason = '1' } -Level 4
Reset-Context; Invoke-CmosBatteryCheck @($fix)
Test-That 'Time service correcting the clock by years is detected' (Test-Finding 'CMOS battery')
$off = New-FakeEvent 'Microsoft-Windows-Kernel-General' 1 $T0 'The system time has changed' @{ NewTime = '2026-11-21T00:20:09.5Z'; OldTime = '2026-11-20T07:02:26.55Z'; Reason = '2' } -Level 4
Reset-Context; Invoke-CmosBatteryCheck @($off)
Test-That 'Normal startup after being off overnight is NOT flagged (real event from this PC)' ($findings.Count -eq 0)
$small = New-FakeEvent 'Microsoft-Windows-Kernel-General' 1 $T0 'The system time has changed' @{ NewTime = '2026-11-20T12:00:30.000Z'; OldTime = '2026-11-20T12:00:00.000Z'; Reason = '2' } -Level 4
Reset-Context; Invoke-CmosBatteryCheck @($small)
Test-That 'Normal small clock sync is ignored' ($findings.Count -eq 0)

Write-Host "`n== 15. Intel microcode" -ForegroundColor Cyan
Reset-Context; Invoke-MicrocodeCheck '13th Gen Intel(R) Core(TM) i9-13900K' 0x119
Test-That 'i9-13900K on microcode 0x119 is critical' ((Get-Finding 'microcode 0x119').Sev -eq 'critical')
Reset-Context; Invoke-MicrocodeCheck '13th Gen Intel(R) Core(TM) i9-13900K' 0x12F
Test-That 'Microcode 0x12F is fine' ($findings.Count -eq 0)
Reset-Context; Invoke-MicrocodeCheck 'AMD Ryzen 5 8400F 6-Core Processor' 0x10
Test-That 'AMD CPUs are skipped' ($findings.Count -eq 0)
$rev = Get-MicrocodeRevision
Test-That ('Reads this PC''s microcode revision (0x{0:X})' -f $rev) ($rev -gt 0)

Write-Host "`n== 16. Wall power" -ForegroundColor Cyan
Reset-Context; $script:kind = 'powerloss'; Invoke-WallPowerCheck $true
Test-That 'Power loss with everything normal points at wall power (critical)' ((Get-Finding 'wall power first').Sev -eq 'critical')
Reset-Context; $script:kind = 'powerloss'
Add-Finding -Sev 'critical' -Title 'The PC shut off while drawing a lot of power' -Plain 'x' -Area 'Power'
Invoke-WallPowerCheck $true
Test-That 'With a PSU finding, wall power is only a side note' ((Get-Finding 'Also rule out').Sev -eq 'info' -and -not (Test-Finding 'wall power first'))
Reset-Context; $script:kind = 'bsod'; Invoke-WallPowerCheck $true
Test-That 'Not shown for blue screens' ($findings.Count -eq 0)

Write-Host "`n== 19. Overlays / tuning apps" -ForegroundColor Cyan
$names = @(Get-SideAppMatches @('Discord', 'MSIAfterburner', 'RTSS', 'iCUE', 'chrome', 'explorer') | ForEach-Object { $_.Name })
Test-That 'Process names map to friendly app names' ($names.Count -eq 4 -and $names -contains 'Corsair iCUE')
Reset-Context; $script:kind = 'bsod'
Invoke-SideAppsCheck $names @([pscustomobject]@{ n = 'Cyberpunk2077'; v = 97 })
$f = Get-Finding 'overlay/tuning app'
Test-That 'Blue screen with tuning apps running = warning' ($f.Sev -eq 'warning')
Test-That 'Names the top GPU program' ($f.Plain -match 'Cyberpunk2077 \(97%\)')
Reset-Context; $script:kind = 'clean'; Invoke-SideAppsCheck $names @()
Test-That 'Not shown after a normal shutdown with no app crashes' ($findings.Count -eq 0)
Reset-Context; $script:kind = 'clean'; Invoke-SideAppsCheck @('Discord (in-game overlay)') @() 2
Test-That 'Shown as info when games crashed' ((Get-Finding 'overlay/tuning app').Sev -eq 'info')

Write-Host "`n== 21. Commit charge" -ForegroundColor Cyan
Reset-Context; $script:kind = 'bsod'; Set-Series 'Memory~Virtual Memory|Load|Memory' (@(Get-Repeat 60 30) + (Get-Repeat 96 10)); Invoke-CommitCheck
Test-That 'Commit at 96% at the moment of a blue screen is critical' ((Get-Finding 'nearly out of memory').Sev -eq 'critical')
Reset-Context; $script:kind = 'clean'; Set-Series 'Memory~Virtual Memory|Load|Memory' (@(Get-Repeat 60 30) + @(92) + (Get-Repeat 60 40)); Invoke-CommitCheck
Test-That 'Short 92% peak earlier in the session is info' ((Get-Finding 'nearly out of memory').Sev -eq 'info')
Reset-Context; Set-Series 'Memory~Virtual Memory|Load|Memory' (Get-Repeat 70 30); Set-Series 'Memory~Total Memory|Load|Memory' (Get-Repeat 95 30); Invoke-CommitCheck
Test-That 'Physical RAM load alone does not trigger it' ($findings.Count -eq 0)

Write-Host "`n== 22. Page file" -ForegroundColor Cyan
Reset-Context; $script:kind = 'bsod'; Invoke-PageFileCheck ([pscustomobject]@{ Auto = $false; Files = @(); RamGB = 32 })
Test-That 'Page file off + blue screen = critical' ((Get-Finding 'page file is switched off').Sev -eq 'critical')
Reset-Context; Invoke-PageFileCheck ([pscustomobject]@{ Auto = $false; Files = @([pscustomobject]@{ Name = 'C:\pagefile.sys'; SizeMB = 2048; MaxMB = 2048 }); RamGB = 16 })
Test-That '2 GB fixed page file is flagged as small' (Test-Finding 'small fixed size \(2\.0 GB\)')
Reset-Context; Invoke-PageFileCheck ([pscustomobject]@{ Auto = $false; Files = @([pscustomobject]@{ Name = 'D:\pagefile.sys'; SizeMB = 16384 }); RamGB = 16 })
Test-That 'Page file only on D: is noted' (Test-Finding 'no page file on the Windows drive')
Reset-Context; Invoke-PageFileCheck ([pscustomobject]@{ Auto = $true; Files = @(); RamGB = 16 })
Test-That 'Automatic page file is fine' ($findings.Count -eq 0)
$pf = Get-PageFileInfo
Test-That ('Reads this PC''s page file (auto={0}, files={1})' -f $pf.Auto, $pf.Files.Count) ($null -ne $pf.Auto)
Reset-Context; Invoke-PageFileCheck $pf
Test-That ('This PC: {0} page file finding(s)' -f $findings.Count) $true

Write-Host "`n== 23. Drives almost full" -ForegroundColor Cyan
Reset-Context; Invoke-FreeSpaceCheck @([pscustomobject]@{ Drive = 'C:'; Label = ''; SizeGB = 931; FreeGB = 34 })
Test-That 'C: at 3.7% free is critical' ((Get-Finding 'Drive C: is almost full').Sev -eq 'critical')
Reset-Context; Invoke-FreeSpaceCheck @([pscustomobject]@{ Drive = 'D:'; Label = 'Games'; SizeGB = 2000; FreeGB = 150 })
Test-That 'D: at 7.5% free is info' ((Get-Finding 'Drive D:').Sev -eq 'info')
Reset-Context; Invoke-FreeSpaceCheck @([pscustomobject]@{ Drive = 'C:'; Label = ''; SizeGB = 120; FreeGB = 13 })
Test-That 'Small C: with under 15 GB free is flagged even above 10%' (Test-Finding 'Drive C:')
Reset-Context; Invoke-FreeSpaceCheck @([pscustomobject]@{ Drive = 'C:'; Label = ''; SizeGB = 931; FreeGB = 300 })
Test-That 'Plenty of space is fine' ($findings.Count -eq 0)
Reset-Context; Invoke-FreeSpaceCheck (Get-VolumeSpace)
Test-That ('This PC: ' + (($findings | ForEach-Object { $_.Title }) -join '; ')) $true

Write-Host "`n== 24. Crash after waking / Fast Startup" -ForegroundColor Cyan
$end = $T0.AddMinutes(30)
$wakeEv = New-FakeEvent 'Microsoft-Windows-Power-Troubleshooter' 1 $end.AddMinutes(-2) 'The system has returned from a low power state.' -Level 4
Reset-Context; $script:kind = 'bsod'; Invoke-WakeCheck @($wakeEv) $end $T0 $true
$f = Get-Finding 'woke up from sleep'
Test-That 'Blue screen 2 minutes after waking is flagged' ($f.Sev -eq 'warning' -and $f.Title -match '2 minutes')
Test-That 'Fast Startup advice included when it is on' (($f.Steps -join ' ') -match 'fast startup')
Reset-Context; $script:kind = 'bsod'; Invoke-WakeCheck @(New-FakeEvent 'Microsoft-Windows-Power-Troubleshooter' 1 $end.AddMinutes(-20) 'x' -Level 4) $end $T0 $false
Test-That 'Wake 20 minutes earlier is not blamed' ($findings.Count -eq 0)
Reset-Context; $script:kind = 'bsod'; Invoke-WakeCheck @() $T0.AddMinutes(4) $T0 $true
Test-That 'Crash 4 min after start with Fast Startup on = info' ((Get-Finding 'Fast Startup is on').Sev -eq 'info')
Reset-Context; $script:kind = 'clean'; Invoke-WakeCheck @($wakeEv) $end $T0 $true
Test-That 'Normal shutdowns are ignored' ($findings.Count -eq 0)
Test-That ('Reads Fast Startup setting on this PC ({0})' -f (Get-FastStartupEnabled)) ($null -ne (Get-FastStartupEnabled))

Write-Host "`n== 25. Repair Windows" -ForegroundColor Cyan
Test-That 'Repair-Windows.cmd exists' (Test-Path (Join-Path $root 'Repair-Windows.cmd'))
Test-That 'Report advice points to Repair-Windows.cmd' ([bool]((Resolve-Steps @('Sfc')) -join ' ' -match 'Repair-Windows\.cmd'))

Write-Host "`n== 26. Memory Integrity / VBS" -ForegroundColor Cyan
Reset-Context; $script:kind = 'bsod'; Invoke-VbsCheck ([pscustomobject]@{ Vbs = $true; Hvci = $true; Hypervisor = $true })
Test-That 'Blue screen with Memory Integrity on suggests checking incompatible drivers' (((Get-Finding 'Memory Integrity').Steps -join ' ') -match 'incompatible drivers')
Reset-Context; $script:kind = 'bsod'; Invoke-VbsCheck ([pscustomobject]@{ Vbs = $false; Hvci = $false; Hypervisor = $false })
Test-That 'Blue screen with it off explains the clue it can give' (Test-Finding 'Memory Integrity .* is off')
Reset-Context; $script:kind = 'clean'; Invoke-VbsCheck ([pscustomobject]@{ Vbs = $true; Hvci = $true; Hypervisor = $true }) 3
Test-That 'App crashes with Hyper-V running mention virtualization' ((Test-Finding 'virtualization') -and -not (Test-Finding 'Memory Integrity'))
Reset-Context; $script:kind = 'clean'; Invoke-VbsCheck ([pscustomobject]@{ Vbs = $true; Hvci = $true; Hypervisor = $true }) 0
Test-That 'No crashes = no noise' ($findings.Count -eq 0)
$vi = Get-VbsInfo
Test-That ('Reads this PC (VBS={0}, HVCI={1}, hypervisor={2})' -f $vi.Vbs, $vi.Hvci, $vi.Hypervisor) ($null -ne $vi.Hypervisor)

Write-Host "`n== 27. Busy while idle" -ForegroundColor Cyan
function Set-IdleScenario([double]$Idle, [double]$Cpu, [int]$N) {
    Set-Series 'User~Session|Idle|Seconds Since Input' (@(1..$N | ForEach-Object { $Idle + 5 * $_ }))
    Set-Series 'Cpu~Test CPU|Load|CPU Total' (Get-Repeat $Cpu $N)
    $script:SensorKey.CpuLoad = 'Cpu~Test CPU|Load|CPU Total'
}
$snaps = @(0..10 | ForEach-Object { [pscustomobject]@{ t = $T0.AddSeconds(60 * $_).ToString('o'); cpu = @([pscustomobject]@{ n = 'xmrig'; v = 85 }); gpu = @() } })
Reset-Context; Set-IdleScenario 900 90 120; Invoke-IdleLoadCheck $snaps
$f = Get-Finding 'while nobody was using it'
Test-That '10 minutes at 90% CPU while idle is flagged' ($f.Sev -eq 'warning' -and $f.Title -match '9 minutes')
Test-That 'Names the busy program' ($f.Plain -match 'xmrig')
Reset-Context; Set-IdleScenario 900 90 120; Invoke-IdleLoadCheck @([pscustomobject]@{ t = $T0.AddMinutes(2).ToString('o'); cpu = @([pscustomobject]@{ n = 'MsMpEng'; v = 60 }); gpu = @() })
Test-That 'Only Windows Defender busy = info' ((Get-Finding 'while nobody').Sev -eq 'info')
Reset-Context; Set-IdleScenario 30 90 120; Invoke-IdleLoadCheck $snaps
Test-That 'Busy while the user is active (gaming) is fine' ($findings.Count -eq 0)
Reset-Context; Set-IdleScenario 900 90 30; Invoke-IdleLoadCheck $snaps
Test-That 'Under 5 minutes busy is ignored' ($findings.Count -eq 0)
Reset-Context; Set-IdleScenario 900 5 120; Invoke-IdleLoadCheck $snaps
Test-That 'Idle and quiet is fine' ($findings.Count -eq 0)

Write-Host "`n== 28. Pause / sensors off" -ForegroundColor Cyan
$pz = [pscustomobject]@{ Since = '2026-11-20T10:00:00' }
Test-That 'Mode: paused' ((Get-MonitorMode 'LibreHardwareMonitor' $pz $false) -eq 'paused')
Test-That 'Mode: sensors off by choice' ((Get-MonitorMode 'windows-basic (hardware sensors off in settings)' $null $true) -eq 'basic-by-choice')
Test-That 'Mode: full' ((Get-MonitorMode 'LibreHardwareMonitor' $null $true) -eq 'full')
Reset-Context; Invoke-MonitorStatusCheck 'paused' $pz
Test-That 'Paused monitoring is explained with how to resume' (((Get-Finding 'Monitoring was paused').Steps -join ' ') -match 'Resume-Monitoring.cmd')
Reset-Context; Invoke-MonitorStatusCheck 'full' $null
Test-That 'Full monitoring = no note' ($findings.Count -eq 0)
Test-That 'Pause/Resume scripts exist' ((Test-Path (Join-Path $root 'Pause-Monitoring.cmd')) -and (Test-Path (Join-Path $root 'Resume-Monitoring.cmd')) -and (Test-Path (Join-Path $root 'Monitor-Control.ps1')))
Test-That 'UseHardwareSensors setting defaults to on' ($cfg.UseHardwareSensors -eq $true)

Write-Host "`n== 29. Not a crash (planned restarts)" -ForegroundColor Cyan
function New-1074([string]$Proc, [string]$Reason, [string]$Type, [string]$User = 'PC\chad') {
    New-FakeEvent 'User32' 1074 $T0 "The process $Proc has initiated the restart" @{ param1 = $Proc; param2 = 'PC'; param3 = $Reason; param4 = '0x80020010'; param5 = $Type; param6 = ''; param7 = $User } -Level 4
}
$r = Get-RestartReason @(New-1074 'C:\WINDOWS\servicing\TrustedInstaller.exe (PC)' 'Operating System: Upgrade (Planned)' 'restart' 'NT AUTHORITY\SYSTEM')
Test-That 'TrustedInstaller restart = Windows Update' ($r.Who -eq 'update')
$r2 = Get-RestartReason @(New-1074 'C:\WINDOWS\System32\svchost.exe (PC)' 'Operating System: Service pack (Planned)' 'restart' 'NT AUTHORITY\SYSTEM')
Test-That 'svchost with service-pack reason = Windows Update' ($r2.Who -eq 'update')
$r3 = Get-RestartReason @(New-1074 'C:\WINDOWS\Explorer.EXE (PC)' 'Other (Unplanned)' 'power off')
Test-That 'Explorer power off = user' ($r3.Who -eq 'user')
$r4 = Get-RestartReason @(New-1074 'C:\Program Files\Steam\steam.exe (PC)' 'Application: Installation (Planned)' 'restart')
Test-That 'Steam restart = app' ($r4.Who -eq 'app' -and $r4.Process -eq 'steam.exe')
Reset-Context; $script:kind = 'clean'; Invoke-NotACrashCheck $r
Test-That 'Windows Update restart says "This was not a crash"' (Test-Finding 'not a crash - Windows restarted itself to finish installing updates')
Reset-Context; $script:kind = 'clean'; Invoke-NotACrashCheck $r3
Test-That 'User shutdown says "shut down normally"' (Test-Finding 'not a crash - the PC was shut down normally')
Reset-Context; $script:kind = 'bsod'; Invoke-NotACrashCheck $r
Test-That 'Never shown for real crashes' ($findings.Count -eq 0)

Write-Host "`n== 30. Screen-only freeze vs real freeze" -ForegroundColor Cyan
Reset-Context; $script:kind = 'powerbutton'; Invoke-DisplayOnlyCheck $T0.AddSeconds(-6) $T0 0
Test-That 'Logging until the press + no GPU errors = picture lost' ((Get-Finding 'only the picture was lost').Sev -eq 'warning')
Reset-Context; $script:kind = 'powerbutton'; Invoke-DisplayOnlyCheck $T0.AddSeconds(-6) $T0 2
Test-That 'GPU hang events present = left to the GPU findings' ($findings.Count -eq 0)
Reset-Context; $script:kind = 'powerbutton'; Invoke-DisplayOnlyCheck $T0.AddMinutes(-4) $T0 0
Test-That 'Logging stopped 4 min before the press = real freeze' (Test-Finding 'really frozen 4 minutes before')
Reset-Context; $script:kind = 'powerloss'; Invoke-DisplayOnlyCheck $T0.AddSeconds(-6) $T0 0
Test-That 'Only for power-button shutdowns' ($findings.Count -eq 0)

Write-Host "`n== 31. Patterns across crashes" -ForegroundColor Cyan
function New-HistRow([int]$DaysAgo, [string]$Outcome, [string]$Game = '', [string]$Gpu = '', [string]$Code = '', [string]$Wake = 'False', [string]$CpuT = '') {
    [pscustomobject]@{ SessionStart = $T0.AddDays(-$DaysAgo).ToString('s'); Outcome = $Outcome; Game = $Game; GpuPowerEnd = $Gpu; StopCode = $Code; StopName = ''; Driver = ''; AfterWake = $Wake; CpuTempMax = $CpuT; GpuTempMax = '' }
}
$rows = @((New-HistRow 1 'powerloss' 'Cyberpunk2077' '310'), (New-HistRow 3 'powerloss' 'Cyberpunk2077' '295'), (New-HistRow 5 'powerloss' 'Cyberpunk2077' '288'),
          (New-HistRow 6 'clean' 'chrome' '20'), (New-HistRow 8 'powerloss' 'Cyberpunk2077' '305'), (New-HistRow 9 'powerloss' 'eldenring' '270'))
$pt = @(Get-CrashPatterns $rows $T0)
Test-That '"4 of 5 crashes while Cyberpunk2077"' (@($pt | Where-Object { $_.Text -match '^4 of your last 5 crashes happened while Cyberpunk2077' }).Count -eq 1)
Test-That '"all with GPU above 270 W"' (@($pt | Where-Object { $_.Text -match 'All 5 crashes .* at least 270 W' }).Count -eq 1)
Test-That 'All power-offs noted' (@($pt | Where-Object { $_.Text -match 'All 5 were sudden power-offs' }).Count -eq 1)
$rows2 = @((New-HistRow 1 'bsod' '' '' '0x0000000A'), (New-HistRow 2 'bsod' '' '' '0x0000000A'), (New-HistRow 4 'bsod' '' '' '0x0000000A' 'True'), (New-HistRow 4 'bsod' '' '' '0x00000050' 'True'))
$pt2 = @(Get-CrashPatterns $rows2 $T0)
Test-That 'Same stop code 3 times' (@($pt2 | Where-Object { $_.Text -match '3 blue screens had the same error code: 0x0000000A' }).Count -eq 1)
Test-That 'Half after waking' (@($pt2 | Where-Object { $_.Text -match '2 of 4 crashes happened within minutes of waking' }).Count -eq 1)
Test-That 'Only 2 crashes = no patterns' (@(Get-CrashPatterns @($rows2[0], $rows2[1]) $T0).Count -eq 0)
Test-That 'Crashes over 60 days old are ignored' (@(Get-CrashPatterns @((New-HistRow 90 'bsod'), (New-HistRow 91 'bsod'), (New-HistRow 92 'bsod')) $T0).Count -eq 0)
Reset-Context; Invoke-PatternCheck $rows $T0
Test-That 'Pattern finding lists everything in plain English' ((Get-Finding 'Patterns found').Plain -match 'Cyberpunk2077.*270 W')
$snap = [pscustomobject]@{ cpu = @([pscustomobject]@{ n = 'System'; v = 30 }, [pscustomobject]@{ n = 'Cyberpunk2077'; v = 25 }); gpu = @([pscustomobject]@{ n = 'dwm'; v = 40 }, [pscustomobject]@{ n = 'Cyberpunk2077'; v = 95 }) }
Test-That 'Main program = the game using the GPU, not Windows' ((Get-MainProgram $snap) -eq 'Cyberpunk2077')

# ==== END OF TESTS ====

Write-Host ''
$color = if ($script:fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $color
exit $script:fail
