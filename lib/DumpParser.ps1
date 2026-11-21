# Reads Windows kernel crash dumps (C:\Windows\Minidump\*.dmp, C:\Windows\MEMORY.DMP).
# Without a debugger: reads the stop code from the header, and for small (triage) dumps
# finds which drivers appear on the crashing thread's stack - the same trick BlueScreenView uses.
# With WinDbg/cdb installed: runs "!analyze -v" for an exact answer.
# ASCII only.

function Read-UInt32At([IO.BinaryReader]$R, [int64]$Off) { $R.BaseStream.Position = $Off; return $R.ReadUInt32() }
function Read-UInt64At([IO.BinaryReader]$R, [int64]$Off) { $R.BaseStream.Position = $Off; return $R.ReadUInt64() }

function Read-DumpString([IO.BinaryReader]$R, [int64]$Off, [int64]$FileLen) {
    # DUMP_STRING: ULONG Length (in WCHARs) followed by UTF-16 text
    if ($Off -le 0 -or $Off + 4 -gt $FileLen) { return $null }
    $len = Read-UInt32At $R $Off
    if ($len -eq 0 -or $len -gt 260 -or ($Off + 4 + 2 * $len) -gt $FileLen) { return $null }
    $bytes = $R.ReadBytes([int](2 * $len))
    return [Text.Encoding]::Unicode.GetString($bytes)
}

function Get-TriageDrivers([IO.BinaryReader]$R, [int64]$FileLen, [int64]$TriageBase) {
    # Returns list of drivers (Name, Base, Size) or $null if the layout does not validate.
    $count   = Read-UInt32At $R ($TriageBase + 0x34)
    $listOff = Read-UInt32At $R ($TriageBase + 0x30)
    if ($count -lt 5 -or $count -gt 2000) { return $null }
    foreach ($origin in @(0, $TriageBase)) {
        foreach ($stride in @(0x88, 0x90, 0x98, 0xA0, 0xA8, 0xB0, 0xB8, 0xC0, 0xC8, 0xD0)) {
            $drivers = New-Object System.Collections.Generic.List[object]
            $ok = $true
            for ($i = 0; $i -lt $count; $i++) {
                $e = $origin + $listOff + $i * $stride
                if ($e + $stride -gt $FileLen) { $ok = $false; break }
                $nameOff = Read-UInt32At $R $e
                $base = Read-UInt64At $R ($e + 8 + 0x30)
                $size = Read-UInt32At $R ($e + 8 + 0x40)
                $name = Read-DumpString $R ($origin + $nameOff) $FileLen
                if (-not $name -or $name -notmatch '^[\w\.\-]+\.(sys|dll|exe)$' -or $base -lt [UInt64]18446603336221196288 -or $size -lt 0x1000 -or $size -gt 0x10000000) {
                    $ok = $false; break
                }
                $drivers.Add([pscustomobject]@{ Name = $name; Base = $base; End = [UInt64]([decimal]$base + [decimal]$size) })
            }
            if ($ok -and $drivers.Count -eq $count) { return [pscustomobject]@{ Drivers = $drivers; Origin = $origin } }
        }
    }
    return $null
}

function Find-DriverForAddress($Drivers, [UInt64]$Addr) {
    foreach ($d in $Drivers) { if ($Addr -ge $d.Base -and $Addr -lt $d.End) { return $d.Name } }
    return $null
}

function Read-CrashDump([string]$Path) {
    $res = [ordered]@{
        Path = $Path; Time = $null; SizeMB = 0; BugCheckCode = $null; Params = @(); DumpType = $null
        StackDrivers = @(); CrashAddressDriver = $null; ProbableDriver = $null; Method = 'header'; Error = $null
    }
    $fs = $null
    try {
        $fi = Get-Item -LiteralPath $Path
        $res.Time = $fi.LastWriteTime
        $res.SizeMB = [math]::Round($fi.Length / 1MB, 1)
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $r = New-Object IO.BinaryReader($fs)
        $len = $fs.Length
        $sig = [Text.Encoding]::ASCII.GetString($r.ReadBytes(8))
        if ($sig -eq 'PAGEDU64') {
            $res.BugCheckCode = Read-UInt32At $r 0x38
            $res.Params = @( (Read-UInt64At $r 0x40), (Read-UInt64At $r 0x48), (Read-UInt64At $r 0x50), (Read-UInt64At $r 0x58) )
            $res.DumpType = Read-UInt32At $r 0xF98
            $mdmp = $false
        } elseif ($sig -eq 'PAGEDUMP') {
            $res.BugCheckCode = Read-UInt32At $r 0x20
            $res.Params = @( (Read-UInt32At $r 0x24), (Read-UInt32At $r 0x28), (Read-UInt32At $r 0x2C), (Read-UInt32At $r 0x30) )
            $res.Error = '32-bit dump: only the stop code can be read.'
            return [pscustomobject]$res
        } else {
            $res.Error = "Not a kernel crash dump (signature '$sig')."
            return [pscustomobject]$res
        }

        # Triage (small) dump: driver list + call stack follow the 0x2000-byte header.
        if ($res.DumpType -eq 4 -and $len -gt 0x3000) {
            $tb = 0x2000
            $tri = Get-TriageDrivers $r $len $tb
            if ($tri) {
                $drivers = $tri.Drivers
                $origin = $tri.Origin
                $ctxOff = Read-UInt32At $r ($tb + 0x0C)
                $stackOff = Read-UInt32At $r ($tb + 0x28)
                $stackSize = Read-UInt32At $r ($tb + 0x2C)

                # Instruction pointer at the crash (CONTEXT.Rip is at +0xF8 on x64)
                if ($ctxOff -gt 0 -and ($origin + $ctxOff + 0x100) -le $len) {
                    $rip = Read-UInt64At $r ($origin + $ctxOff + 0xF8)
                    $res.CrashAddressDriver = Find-DriverForAddress $drivers $rip
                }
                # Bug check parameters that point into a driver
                $paramDrivers = @()
                foreach ($p in $res.Params) {
                    $d = Find-DriverForAddress $drivers ([UInt64]$p)
                    if ($d) { $paramDrivers += $d }
                }
                # Scan the saved stack for return addresses inside drivers (in order, nearest frame first)
                $seen = [ordered]@{}
                if ($stackOff -gt 0 -and $stackSize -gt 0 -and $stackSize -lt 0x100000 -and ($origin + $stackOff + $stackSize) -le $len) {
                    $fs.Position = $origin + $stackOff
                    $buf = $r.ReadBytes([int]$stackSize)
                    for ($i = 0; $i + 8 -le $buf.Length; $i += 8) {
                        $v = [BitConverter]::ToUInt64($buf, $i)
                        if ($v -lt [UInt64]18446603336221196288) { continue }
                        $d = Find-DriverForAddress $drivers $v
                        if ($d -and -not $seen.Contains($d)) { $seen[$d] = $true }
                    }
                }
                $res.StackDrivers = @($seen.Keys)
                $res.Method = 'triage'

                # Pick the most likely culprit: skip the Windows core, which reports most crashes.
                $core = '^(ntoskrnl|ntkrnlmp|ntkrpamp|hal|ci|cng|ksecdd|clfs|pshed|fltmgr|ntfs|tm|msrpc|wdf01000|wdfldr|acpi|pci|werkernel|kdcom|bootvid|clipsp)\.'
                $cands = @()
                if ($res.CrashAddressDriver) { $cands += $res.CrashAddressDriver }
                $cands += $paramDrivers
                $cands += $res.StackDrivers
                $pick = $cands | Where-Object { $_ -and $_ -notmatch $core } | Select-Object -First 1
                if (-not $pick) { $pick = $cands | Where-Object { $_ } | Select-Object -First 1 }
                $res.ProbableDriver = $pick
            } else {
                $res.Error = 'Could not read the driver list from this dump (format not recognized); stop code only.'
            }
        }
    } catch {
        $res.Error = "Could not read dump: $($_.Exception.Message)"
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    return [pscustomobject]$res
}

function Find-Cdb {
    $c = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe",
        "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\cdb.exe"
    )
    foreach ($p in $c) { if (Test-Path $p) { return $p } }
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.WinDbg' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pkg) { $pkg = Get-AppxPackage -AllUsers -Name 'Microsoft.WinDbg' -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($pkg) {
            $p = Join-Path $pkg.InstallLocation 'amd64\cdb.exe'
            if (Test-Path $p) { return $p }
        }
    } catch { }
    return $null
}

function Invoke-CdbAnalysis([string]$DumpPath, [string]$SymbolCache, [int]$TimeoutSec = 300) {
    $cdb = Find-Cdb
    if (-not $cdb) { return $null }
    Initialize-Folder $SymbolCache
    $out = Join-Path $env:TEMP ("pccr_cdb_{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $sym = "srv*$SymbolCache*https://msdl.microsoft.com/download/symbols"
    $argList = @('-z', "`"$DumpPath`"", '-y', "`"$sym`"", '-c', '"!analyze -v; q"', '-logo', "`"$out`"")
    try {
        $p = Start-Process -FilePath $cdb -ArgumentList $argList -WindowStyle Hidden -PassThru
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; return $null }
        if (-not (Test-Path $out)) { return $null }
        $text = Get-Content $out -Raw
        $get = { param($k) if ($text -match "(?m)^$k\s*:\s*(.+)$") { $matches[1].Trim() } else { $null } }
        return [pscustomobject]@{
            ImageName     = & $get 'IMAGE_NAME'
            ModuleName    = & $get 'MODULE_NAME'
            ProcessName   = & $get 'PROCESS_NAME'
            FailureBucket = & $get 'FAILURE_BUCKET_ID'
            BugCheckStr   = & $get 'BUGCHECK_STR'
            SymbolName    = & $get 'SYMBOL_NAME'
        }
    } catch {
        return $null
    } finally {
        Remove-Item $out -Force -ErrorAction SilentlyContinue
    }
}
