<#
  PC Crash Reporter - idle helper.
  Runs hidden in the logged-in user's session and writes how many seconds since the last
  keyboard/mouse input to logs\idle.txt every 30 seconds. The monitor (which runs as SYSTEM
  and cannot see this itself) reads that file. Uses almost no CPU.
#>
param([int]$Loops = 0)
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
Add-Type -Namespace PCCR -Name Idle -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
public static uint Seconds() {
    LASTINPUTINFO i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(i);
    if (!GetLastInputInfo(ref i)) return 0;
    return ((uint)Environment.TickCount - i.dwTime) / 1000;
}
"@
$mutex = New-Object Threading.Mutex($false, 'Local\PCCrashReporterIdleHelper')
if (-not $mutex.WaitOne(0)) { exit 0 }   # already running in this session
$path = Join-Path $script:Paths.Logs 'idle.txt'
$n = 0
while ($true) {
    try { [IO.File]::WriteAllText($path, ('{0},{1}' -f [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), [PCCR.Idle]::Seconds())) } catch { }
    $n++; if ($Loops -gt 0 -and $n -ge $Loops) { break }
    Start-Sleep -Seconds 30
}
