# PC Crash Reporter

A beginner-friendly crash detective for Windows. It keeps an eye on your PC in the background, and after every restart it gives you a report in plain English about **what went wrong and what to try first**.

**[Download the latest version](https://github.com/Goopymilk/pc-crash-reporter/releases/latest)**: get `PC-Crash-Reporter.zip` from the release page. It works on Windows 10 and 11.

## What it does

- **Records temperatures, power draw, fan speeds, voltages and load** every 5 seconds (CPU, graphics card, RAM, drives). Each reading is saved to disk straight away, so the readings from the moments before a crash survive the crash.
- **Works out how your last session ended:** a normal shutdown, a Windows Update restart, a blue screen, a sudden power-off, a crash during sleep, or the power button being held.
- **Reads blue-screen crash dumps.** It explains the stop code (for example `VIDEO_TDR_FAILURE`) and names the driver that was most likely involved.
- **Collects and explains Windows errors:** hardware (WHEA) errors, drive errors, graphics driver resets, program crashes, services failing and more. Each one comes with a plain-English explanation and a "what to do" list. Harmless noise (like DistributedCOM 10016) is filtered out.
- **Tracks history,** so you can see patterns like "the same blue screen happened 3 times this month".
- **Checks your setup,** for example mismatched RAM sticks, an old graphics driver, an old BIOS, drive health and SSD wear.

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
- `Thresholds`: the temperature warning levels in degrees C.

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
