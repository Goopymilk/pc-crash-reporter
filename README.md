# PC Crash Reporter

A beginner-friendly crash detective for Windows. It keeps an eye on your PC in the background, and after every restart it gives you a report in plain English about **what went wrong and what to try first**.

**[Download the latest version](https://github.com/Goopymilk/pc-crash-reporter/releases/latest)**: get `PC-Crash-Reporter.zip` from the release page. It works on Windows 10 and 11.

## What it does

- **Records temperatures, power draw, fan speeds, voltages and load** every 5 seconds (CPU, graphics card, RAM, drives). Each reading is saved to disk straight away, so the readings from the moments before a crash survive the crash.
- **Works out how your last session ended:** a normal shutdown, a Windows Update restart, a blue screen, a sudden power-off, a crash during sleep, or the power button being held.
- **Reads blue-screen crash dumps.** It explains the stop code (for example `VIDEO_TDR_FAILURE`) and names the driver that was most likely involved.
- **Collects and explains Windows errors:** hardware (WHEA) errors, drive errors, graphics driver resets, program crashes, services failing and more. Each one comes with a plain-English explanation and a "what to do" list. Harmless noise (like DistributedCOM 10016) is filtered out.
- **Tracks history,** so you can see patterns like "the same blue screen happened 3 times this month".
- **Shows what changed recently:** Windows updates, driver installs and program installs from the 7 days before a crash, as a timeline. Anything from the last 3 days gets highlighted in the to-do list, along with how to undo it.
- **Spots dead fans:** a fan that was spinning, then shows 0 RPM while its part is hot. Fans that never spin (nothing plugged in) and graphics cards that stop their fans when cool are ignored.
- **Detects overclocks:** EXPO/XMP memory profiles, RAM running above or below the speed it's rated for, and CPUs going faster than their normal top speed. It knows the stock speeds of common Ryzen and Intel CPUs.
- **Checks your setup,** for example mismatched RAM sticks, an old graphics driver, how old your BIOS is (with how to check for a newer one), drive health and SSD wear.
- **Looks for common crash causes** and explains each one in plain English, with what to try next:
  - *Power:* the PC shutting off at peak power draw, sagging 12V/5V/3.3V rails, daisy-chained GPU power cables, the graphics card "falling off" or its power dropping to zero, and wall-power advice (socket, power strip, UPS) when nothing inside the PC explains a shutoff.
  - *Heat:* hot motherboard power circuits (VRMs), and temperatures creeping up compared with this PC's own readings from weeks ago (dust, old thermal paste, a loose cooler).
  - *Hardware:* RAM in the wrong slots or sharing one channel, unsafe CPU voltages (including 13th/14th gen Intel and Ryzen SoC voltage), Intel 13th/14th gen microcode older than 0x12B, failing SATA drives (SMART), SSD firmware with the right update tool named, PCI Express errors with the device named, USB errors just before a crash, and a weak CMOS battery.
  - *Windows:* running out of memory (commit charge), a page file that is off or too small, a drive with less than 1% free space, crashes right after waking from sleep, Fast Startup, and Memory Integrity / Hyper-V. Also overlays and RGB/tuning apps that were running, and programs working hard while nobody is using the PC (possible hidden miners).
  - *Not really crashes:* says clearly when a restart was Windows Update, you, or an installer, and tells a frozen PC apart from a screen that only went black.
  - *Patterns:* "4 of your last 5 crashes happened while X was running", "all with the graphics card above 270 W", the same stop code again and again, and so on.
- **One-click Windows repair:** `Repair-Windows.cmd` runs DISM and SFC for you and saves a log.
- **Pause anytime:** `Pause-Monitoring.cmd` / `Resume-Monitoring.cmd`, or set `UseHardwareSensors` to `false` if the sensor driver bothers a game's anti-cheat.

## Install (about 2 minutes)

0. **If you downloaded this as a zip:** before extracting, right-click the zip, choose **Properties**, tick **Unblock**, and click **OK**. Then extract it to a folder you'll keep (for example `Documents\PC-Crash-Reporter`). Don't run it from inside the zip or from your Downloads folder if you tend to clear that out.
1. Double-click **`Install.cmd`** and click **Yes** on the administrator prompt.
2. When it asks about **PawnIO**, say **Y**. PawnIO is a small, free, open-source driver that lets the tool read your CPU temperature and power. Without it you still get graphics card, drive and memory readings.
3. When it asks about **WinDbg**, say **Y** (recommended). It's Microsoft's free debugger, and with it the report names the exact driver behind a blue screen instead of making a best guess.
4. Your first report opens at the end. **Restart once** after installing so the monitor starts collecting data for the next report.

## Using it

| You want to... | Do this |
|---|---|
| See the report after a crash or restart | Nothing to do. It opens by itself about 1 minute after you log in. |
| Re-open the last report | Desktop shortcut **PC Crash Report - Latest** |
| Check the PC right now (after gaming, when it feels unstable) | Desktop shortcut **PC Crash Report - Check Now** |
| Rebuild the report about the previous session | `Run-Report-Now.cmd` |
| See what a crash report looks like | `Show-Example-Crash-Report.cmd` (just an example, nothing is saved) |
| See all past reports | `reports\index.html` |
| Uninstall | `Uninstall.cmd` |

### How to read a report

1. **The coloured box at the top** is the verdict: green means all good, yellow means worth a look, red means a problem was found.
2. **Where to start** is the to-do list. Do the steps **one at a time, in order**, and use the PC normally in between, so you know which fix worked.
3. Everything below that is supporting evidence: crash details, the readings from right before the crash, temperature charts (hover over them for exact values), drive health, history and info about your PC. Each problem has a **Technical details** section with the original Windows message, which is useful when you ask for help online.

## Settings (`config.json`)

Open it with Notepad. The most useful setting:

- **`PsuWatts`**: your power supply's wattage (it's on the PSU's label). Set this and the report will warn you when your parts draw close to its limit.
- `OpenReportOnlyIfProblems`: set to `true` if you only want the report to pop up when something is wrong.
- `UseHardwareSensors`: `false` turns off the detailed hardware sensors (LibreHardwareMonitor). Only basic Windows readings are kept.
- `Thresholds`: the temperature warning levels in degrees C (including `VrmTempWarn`/`VrmTempCrit` for the motherboard power circuits).

## Files

| Path | What |
|---|---|
| `Monitor.ps1` | Background sensor logger (runs at startup as SYSTEM) |
| `Report.ps1` | Builds the HTML report |
| `lib\Knowledge.ps1` | The plain-English explanations of stop codes, drivers and events. Add your own here. |
| `lib\DumpParser.ps1` | Reads crash dump files |
| `logs\sensors\` | Sensor readings (CSV, one file per session, kept 10 days) |
| `reports\` | All reports (`latest.html` is always the newest) |
| `data\history.csv`, `data\error-index.csv` | History of every session and every error found |
| `tools\` | LibreHardwareMonitor (sensor library) and the symbol cache for WinDbg |

## Testing

Run `tests\Run-Tests.ps1` to check every detection against made-up sensor data and Windows events.

## Limits

- Sensor readings are every 5 seconds, so very short power spikes won't show up.
- Without WinDbg, the "driver involved" in a blue screen is an educated guess, made the same way the BlueScreenView tool does it.
- If the PC loses power completely, the last second or two of readings can be lost.
- Motherboard voltage readings are approximate on many boards.
- With **Fast Startup** on, "Shut down" doesn't actually restart Windows, so a report appears after a **Restart** or a crash, not after every power-on.

## Credits

- Sensor readings come from [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) (MPL-2.0), which the installer downloads.
- CPU and motherboard sensor access uses the [PawnIO](https://github.com/namazso/PawnIO.Setup) driver.

## License

MIT. See [LICENSE](LICENSE).
