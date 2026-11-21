# Plain-English knowledge base for PC Crash Reporter. ASCII only.
# Each entry: Name/Title, Plain (what it means), Steps (what to do, in order), Area (hardware area).

# ------------------------------------------------------------------ common step texts
$script:Step = @{
    GpuDriver   = 'Clean-reinstall your graphics driver: download the latest from NVIDIA/AMD/Intel, then in the installer choose "Custom" -> "Perform a clean installation" (or use DDU in Safe Mode for a deeper clean).'
    GpuOlder    = 'If the crashes started right after a driver update, install the previous driver version instead - new drivers sometimes have bugs.'
    GpuOc       = 'If you overclocked or undervolted the graphics card (MSI Afterburner etc.), reset it to default and test again.'
    GpuPower    = 'Check the graphics card power cables: push both ends in firmly, use separate cables from the power supply for each 8-pin plug (no daisy-chain "pigtail"), and make sure 12VHPWR/12V-2x6 plugs click fully in.'
    GpuTemps    = 'Look at the GPU temperature chart in this report. Above about 85 C under load means you should clean dust from the card and improve case airflow.'
    RamTest     = 'Test your memory (RAM): press Start, type "Windows Memory Diagnostic", choose "Restart now and check". For a stronger test, run MemTest86 from a USB stick overnight.'
    RamXmp      = 'If EXPO/XMP (memory overclock profile) is enabled in the BIOS, turn it off as a test. If crashes stop, the memory overclock is unstable - try a lower speed or a BIOS update.'
    RamReseat   = 'Power off, unplug, and reseat the RAM sticks (take them out and push them back in until both clips snap). Try one stick at a time to find a bad one.'
    CpuOc       = 'Undo any CPU overclock, undervolt, Curve Optimizer or PBO settings (or "Load Optimized Defaults" in the BIOS) and test again.'
    Bios        = 'Update the motherboard BIOS from the manufacturer''s website - BIOS updates fix lots of stability problems, especially on newer AMD/Intel platforms.'
    Sfc         = 'Repair Windows system files: right-click Start -> "Terminal (Admin)", run:  sfc /scannow   then   DISM /Online /Cleanup-Image /RestoreHealth'
    WinUpdate   = 'Install all Windows updates (Settings -> Windows Update), including "Optional updates" -> driver updates.'
    DriverRecent= 'Think about what changed just before the crashes started (new driver, new program, new hardware, Windows update) and undo it to test.'
    Chipset     = 'Install the latest chipset driver from AMD/Intel or your motherboard''s support page.'
    DiskCheck   = 'Check the drive for errors: open "This PC", right-click the drive -> Properties -> Tools -> "Check". Also install the drive maker''s tool (Samsung Magician, Kingston SSD Manager, WD Dashboard, Crucial Storage Executive) and check its health and firmware.'
    DiskBackup  = 'Back up your important files NOW - disk errors can be the first sign of a failing drive.'
    DiskCable   = 'For SATA drives, replace or reseat the SATA data cable and power cable. For NVMe (M.2) drives, reseat the drive.'
    Psu         = 'Suspect the power supply (PSU): check it is a quality unit with enough wattage for your parts (see the power section in this report), that all cables are firmly plugged in, and that the PC is not on an overloaded power strip.'
    Cooling     = 'Check cooling: clean dust out of fans and heatsinks, make sure all fans spin, and check the CPU cooler is mounted firmly.'
    Antivirus   = 'If you use a third-party antivirus (Avast, AVG, Norton, McAfee, Kaspersky...), uninstall it as a test - Windows Defender is enough for most people.'
    AntiCheat   = 'Game anti-cheat drivers can crash Windows. Update or reinstall the game/anti-cheat, or uninstall games you no longer play.'
    Verifier    = 'Advanced: if crashes keep happening and nothing else helps, Driver Verifier can find the bad driver - search for a guide before using it, because it causes crashes on purpose.'
    NetDriver   = 'Update your network driver (Wi-Fi or Ethernet) from the motherboard or laptop maker''s website, or from Intel/Realtek/Killer directly.'
    AudioDriver = 'Update or reinstall your audio driver and any USB audio/headset software.'
    Usb         = 'Unplug USB devices you do not need (especially hubs, cheap adapters, RGB controllers, capture cards) and test again.'
    SearchCode  = 'Search the web for the exact code shown in the technical details - many people have had the same error and posted fixes.'
}

# ------------------------------------------------------------------ blue screen (bugcheck) codes
$script:BugCheckKB = @{
    0x0000000A = @{ Name='IRQL_NOT_LESS_OR_EQUAL'; Area='Driver or RAM'
        Plain='A driver tried to use memory it was not allowed to touch. Usually a buggy driver, sometimes faulty or overclocked RAM.'
        Steps=@('DriverRecent','RamXmp','RamTest','WinUpdate') }
    0x00000019 = @{ Name='BAD_POOL_HEADER'; Area='Driver or RAM'
        Plain='Windows found its internal memory bookkeeping damaged. Usually caused by a bad driver (often antivirus, VPN or storage drivers) or bad RAM.'
        Steps=@('Antivirus','DriverRecent','RamTest') }
    0x0000001A = @{ Name='MEMORY_MANAGEMENT'; Area='RAM'
        Plain='Windows memory management found corrupted data. This is very often faulty or unstable RAM, sometimes a driver.'
        Steps=@('RamXmp','RamTest','RamReseat','Bios') }
    0x0000001E = @{ Name='KMODE_EXCEPTION_NOT_HANDLED'; Area='Driver'
        Plain='A driver (low-level software that talks to hardware) made an error Windows could not recover from.'
        Steps=@('DriverRecent','WinUpdate','RamTest') }
    0x00000024 = @{ Name='NTFS_FILE_SYSTEM'; Area='Drive'
        Plain='A problem happened while reading or writing the file system on a drive. Can be drive corruption, a failing drive, or a bad cable.'
        Steps=@('DiskBackup','DiskCheck','DiskCable','RamTest') }
    0x0000003B = @{ Name='SYSTEM_SERVICE_EXCEPTION'; Area='Driver'
        Plain='Something crashed while switching between a program and the Windows core. Very often a graphics, antivirus or anti-cheat driver.'
        Steps=@('GpuDriver','Antivirus','AntiCheat','Sfc') }
    0x0000004E = @{ Name='PFN_LIST_CORRUPT'; Area='RAM'
        Plain='The list Windows uses to track memory got corrupted. Usually bad/unstable RAM or a buggy driver.'
        Steps=@('RamXmp','RamTest','DriverRecent') }
    0x00000050 = @{ Name='PAGE_FAULT_IN_NONPAGED_AREA'; Area='Driver or RAM'
        Plain='Windows tried to read memory that should always be there but was not. Common causes: bad RAM, a buggy driver, or antivirus.'
        Steps=@('RamXmp','RamTest','DriverRecent','Antivirus') }
    0x00000077 = @{ Name='KERNEL_STACK_INPAGE_ERROR'; Area='Drive'
        Plain='Windows could not load needed data back from the drive (page file). Usually a drive, cable or RAM problem.'
        Steps=@('DiskBackup','DiskCheck','DiskCable','RamTest') }
    0x0000007A = @{ Name='KERNEL_DATA_INPAGE_ERROR'; Area='Drive'
        Plain='Windows could not read needed data back from the drive. Usually a failing drive, loose cable, or bad RAM.'
        Steps=@('DiskBackup','DiskCheck','DiskCable','RamTest') }
    0x0000007B = @{ Name='INACCESSIBLE_BOOT_DEVICE'; Area='Drive'
        Plain='Windows could not access the drive it starts from. Often after changing BIOS storage settings (AHCI/RAID), a failing drive, or a bad update.'
        Steps=@('DiskCable','DiskCheck','Bios') }
    0x0000007E = @{ Name='SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'; Area='Driver'
        Plain='A driver crashed in a way Windows could not handle. The driver named in this report is the main suspect.'
        Steps=@('DriverRecent','GpuDriver','WinUpdate') }
    0x0000007F = @{ Name='UNEXPECTED_KERNEL_MODE_TRAP'; Area='Hardware or driver'
        Plain='The processor hit an error it could not recover from. Often hardware: unstable overclock, bad RAM, or overheating.'
        Steps=@('CpuOc','RamXmp','Cooling','RamTest') }
    0x0000009C = @{ Name='MACHINE_CHECK_EXCEPTION'; Area='CPU / hardware'
        Plain='The processor itself reported a hardware error. Usually overclocking, overheating, not enough voltage, or a power supply problem.'
        Steps=@('CpuOc','Cooling','Bios','Psu') }
    0x0000009F = @{ Name='DRIVER_POWER_STATE_FAILURE'; Area='Driver (sleep/power)'
        Plain='A driver did not respond while the PC was going to sleep, waking up, or changing power state. Often Wi-Fi, USB, graphics or storage drivers.'
        Steps=@('NetDriver','GpuDriver','Chipset','Usb') }
    0x000000BE = @{ Name='ATTEMPTED_WRITE_TO_READONLY_MEMORY'; Area='Driver'
        Plain='A driver tried to change memory that is protected. Usually a buggy driver.'
        Steps=@('DriverRecent','WinUpdate','RamTest') }
    0x000000C2 = @{ Name='BAD_POOL_CALLER'; Area='Driver'
        Plain='A driver made an invalid memory request. Usually antivirus, VPN, or an outdated driver.'
        Steps=@('Antivirus','DriverRecent','WinUpdate') }
    0x000000C4 = @{ Name='DRIVER_VERIFIER_DETECTED_VIOLATION'; Area='Driver'
        Plain='Driver Verifier (a Windows testing tool) caught a driver misbehaving. The driver named in this report is the problem. Turn Driver Verifier off with:  verifier /reset  (then restart).'
        Steps=@('DriverRecent') }
    0x000000D1 = @{ Name='DRIVER_IRQL_NOT_LESS_OR_EQUAL'; Area='Driver'
        Plain='A driver tried to use memory it was not allowed to. Network (Wi-Fi/Ethernet), graphics and USB drivers are the usual suspects.'
        Steps=@('NetDriver','GpuDriver','DriverRecent','RamTest') }
    0x000000EF = @{ Name='CRITICAL_PROCESS_DIED'; Area='Windows / drive'
        Plain='A process Windows cannot live without stopped unexpectedly. Can be corrupted Windows files, drive problems, or bad RAM.'
        Steps=@('Sfc','DiskCheck','RamTest') }
    0x000000F4 = @{ Name='CRITICAL_OBJECT_TERMINATION'; Area='Drive'
        Plain='An essential Windows process ended. Most often the drive stopped responding (failing SSD/HDD, bad cable, or old SSD firmware).'
        Steps=@('DiskBackup','DiskCheck','DiskCable','Sfc') }
    0x000000FC = @{ Name='ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY'; Area='Driver or RAM'
        Plain='A driver tried to run code from memory marked as data-only. Usually a buggy driver or bad RAM.'
        Steps=@('DriverRecent','RamTest') }
    0x00000101 = @{ Name='CLOCK_WATCHDOG_TIMEOUT'; Area='CPU'
        Plain='One processor core stopped responding. Usually an unstable CPU overclock/undervolt, BIOS problem, or (rarely) a faulty CPU.'
        Steps=@('CpuOc','Bios','Chipset','Cooling') }
    0x00000109 = @{ Name='CRITICAL_STRUCTURE_CORRUPTION'; Area='Driver or RAM'
        Plain='Windows found its core code or data had been modified. Caused by bad drivers, cheat/overclocking tools, or faulty RAM.'
        Steps=@('DriverRecent','RamTest','Antivirus') }
    0x00000116 = @{ Name='VIDEO_TDR_FAILURE'; Area='Graphics card'
        Plain='The graphics card stopped responding and Windows could not reset it. This is a graphics driver or graphics card problem (driver bug, overclock, overheating, or not enough power to the card).'
        Steps=@('GpuDriver','GpuOc','GpuTemps','GpuPower','GpuOlder') }
    0x00000117 = @{ Name='VIDEO_TDR_TIMEOUT_DETECTED'; Area='Graphics card'
        Plain='The graphics card stopped responding for too long. Same causes as other graphics crashes: driver, overclock, heat or power.'
        Steps=@('GpuDriver','GpuOc','GpuTemps','GpuPower') }
    0x00000119 = @{ Name='VIDEO_SCHEDULER_INTERNAL_ERROR'; Area='Graphics card'
        Plain='The part of Windows that hands work to the graphics card hit an error. Usually the graphics driver.'
        Steps=@('GpuDriver','GpuOlder','WinUpdate') }
    0x0000010E = @{ Name='VIDEO_MEMORY_MANAGEMENT_INTERNAL'; Area='Graphics card'
        Plain='The graphics driver had a memory error. Usually the graphics driver, sometimes a graphics card overclock.'
        Steps=@('GpuDriver','GpuOc') }
    0x00000113 = @{ Name='VIDEO_DXGKRNL_FATAL_ERROR'; Area='Graphics card'
        Plain='The Windows graphics system hit a fatal error. Usually the graphics driver.'
        Steps=@('GpuDriver','WinUpdate') }
    0x00000124 = @{ Name='WHEA_UNCORRECTABLE_ERROR'; Area='Hardware'
        Plain='Your hardware reported an error it could not fix. This is almost always hardware or settings: unstable CPU/RAM overclock or undervolt, overheating, not enough voltage, a weak power supply, or (rarely) a failing CPU/motherboard.'
        Steps=@('CpuOc','RamXmp','Cooling','Bios','Psu') }
    0x00000133 = @{ Name='DPC_WATCHDOG_VIOLATION'; Area='Driver or drive'
        Plain='A driver took too long to finish a task. Very often old SSD firmware/storage drivers, graphics drivers, or network drivers.'
        Steps=@('DiskCheck','Chipset','GpuDriver','NetDriver') }
    0x00000139 = @{ Name='KERNEL_SECURITY_CHECK_FAILURE'; Area='Driver or RAM'
        Plain='Windows detected that its core data was corrupted (a safety check failed). Usually a bad driver or faulty RAM.'
        Steps=@('DriverRecent','RamTest','Sfc') }
    0x0000013A = @{ Name='KERNEL_MODE_HEAP_CORRUPTION'; Area='Driver'
        Plain='A driver damaged memory it was using. Graphics, audio and anti-cheat drivers are common causes.'
        Steps=@('GpuDriver','AudioDriver','AntiCheat','RamTest') }
    0x00000141 = @{ Name='VIDEO_ENGINE_TIMEOUT_DETECTED'; Area='Graphics card'
        Plain='The graphics card froze. Same causes as other graphics crashes.'
        Steps=@('GpuDriver','GpuOc','GpuTemps','GpuPower') }
    0x00000154 = @{ Name='UNEXPECTED_STORE_EXCEPTION'; Area='Drive or RAM'
        Plain='Windows had a problem with its compressed memory store - usually the drive or RAM.'
        Steps=@('DiskCheck','RamTest','DiskBackup') }
    0x000001CA = @{ Name='SYNTHETIC_WATCHDOG_TIMEOUT'; Area='CPU / drivers'
        Plain='The system stopped responding for too long. Often related to drivers or CPU power-saving issues.'
        Steps=@('Chipset','Bios','GpuDriver') }
    0x0000003D = @{ Name='INTERRUPT_EXCEPTION_NOT_HANDLED'; Area='Driver'
        Plain='A hardware interrupt was not handled. Usually a driver problem.'
        Steps=@('DriverRecent','Chipset') }
    0x000000ED = @{ Name='UNMOUNTABLE_BOOT_VOLUME'; Area='Drive'
        Plain='Windows could not open the drive it starts from. Drive corruption or a failing drive.'
        Steps=@('DiskBackup','DiskCheck','DiskCable') }
    0xC000021A = @{ Name='STATUS_SYSTEM_PROCESS_TERMINATED'; Area='Windows'
        Plain='A core Windows process failed. Usually corrupted system files or a bad update.'
        Steps=@('Sfc','WinUpdate') }
    0x000001A1 = @{ Name='WIN32K_CALLOUT_WATCHDOG_BUGCHECK'; Area='Windows graphics'
        Plain='The Windows graphics subsystem stopped responding.'
        Steps=@('GpuDriver','WinUpdate') }
    0x0000018B = @{ Name='SECURE_KERNEL_ERROR'; Area='Driver / security'
        Plain='Windows'' protected kernel hit an error. Often a driver incompatible with Memory Integrity or virtualization features.'
        Steps=@('DriverRecent','Bios','WinUpdate') }
    0x00000162 = @{ Name='KERNEL_AUTO_BOOST_INVALID_LOCK_RELEASE'; Area='Driver'
        Plain='A driver mishandled an internal lock. Usually a buggy driver.'
        Steps=@('DriverRecent','NetDriver') }
    0x000000C5 = @{ Name='DRIVER_CORRUPTED_EXPOOL'; Area='Driver'
        Plain='A driver damaged Windows memory. Usually a buggy driver.'
        Steps=@('DriverRecent','RamTest') }
    0x000000CE = @{ Name='DRIVER_UNLOADED_WITHOUT_CANCELLING_PENDING_OPERATIONS'; Area='Driver'
        Plain='A driver shut down without cleaning up properly.'
        Steps=@('DriverRecent') }
    0x00000051 = @{ Name='REGISTRY_ERROR'; Area='Drive or RAM'
        Plain='Windows could not read or write the registry. Usually drive or RAM trouble.'
        Steps=@('DiskCheck','RamTest','Sfc') }
    0x000000E2 = @{ Name='MANUALLY_INITIATED_CRASH'; Area='Manual'
        Plain='This crash was triggered on purpose (keyboard shortcut or a debugging tool). Not a real fault.'
        Steps=@() }
    0x000001E2 = @{ Name='MANUALLY_INITIATED_POWER_BUTTON_HOLD'; Area='Manual'
        Plain='The power button was held down to force a crash dump. This usually means the PC was frozen and someone held the power button.'
        Steps=@('GpuDriver','RamTest') }
}

# ------------------------------------------------------------------ drivers / modules seen in blue screens
# Pattern is a regex against the file name.
$script:DriverKB = @(
    @{ P='^(nvlddmkm|nvkflt|nvdlist|nvhda)'; What='NVIDIA graphics driver'; Steps=@('GpuDriver','GpuOlder','GpuOc','GpuPower') }
    @{ P='^(amdkmdag|amdkmdap|atikmdag|atikmpag|amdkmpfd|amdfendr|amdacpbus|amduw23)'; What='AMD graphics driver'; Steps=@('GpuDriver','GpuOlder','GpuOc') }
    @{ P='^(igdkmd|igdkmdn|igdkmdnd|igfx)'; What='Intel graphics driver'; Steps=@('GpuDriver','WinUpdate') }
    @{ P='^(dxgkrnl|dxgmms1|dxgmms2|watchdog|win32k|win32kbase|win32kfull|cdd)'; What='Windows graphics system (usually triggered by the graphics driver)'; Steps=@('GpuDriver','GpuOc') }
    @{ P='^(ntoskrnl|ntkrnlmp|ntkrpamp|ntkrnlpa)'; What='Windows kernel (core of Windows - it reported the crash, but is rarely the real cause)'; Steps=@('RamXmp','RamTest','DriverRecent') }
    @{ P='^hal\.dll'; What='Hardware Abstraction Layer (points to hardware or BIOS)'; Steps=@('CpuOc','Bios','Chipset') }
    @{ P='^(amdppm|intelppm|processr)'; What='CPU power management driver (often an unstable overclock/undervolt or BIOS issue)'; Steps=@('CpuOc','Bios','Chipset') }
    @{ P='^(amdpsp|amdi2c|amdgpio|amdsbs|amdpcidev|amdxe|amdsafd)'; What='AMD chipset driver'; Steps=@('Chipset','Bios') }
    @{ P='^(stornvme|storport|storahci|iastor|iastora|iastorac|iastorvd|rstmwdrv|nvme|disk|classpnp|ataport|msahci|amd_sata|amd_rc|rcraid|secnvme|samsungnvme)'; What='Storage (drive) driver'; Steps=@('DiskBackup','DiskCheck','Chipset','DiskCable') }
    @{ P='^(ntfs|refs|fltmgr|volsnap|volmgr|partmgr|fvevol)'; What='Windows file system / disk layer (drive problem or a file-filter driver like antivirus)'; Steps=@('DiskCheck','Antivirus','Sfc') }
    @{ P='^(tcpip|ndis|netio|afd|http|wfplwfs|netadaptercx|pacer|wfplwfs|fwpkclnt)'; What='Windows networking (usually triggered by a network, VPN or firewall driver)'; Steps=@('NetDriver','Antivirus') }
    @{ P='^(rt640x64|rt68cx21|rtux64w10|rt25cx21|rtcx21x64|rtwlane|rtwlanu|rtkvhd64)'; What='Realtek network or audio driver'; Steps=@('NetDriver','AudioDriver') }
    @{ P='^(e1d|e1r|e1i|e2f|e1y|ixg|iavf|ixv)'; What='Intel Ethernet driver'; Steps=@('NetDriver') }
    @{ P='^(netwtw|netwbw|netwsw|netwew|netwns)'; What='Intel Wi-Fi driver'; Steps=@('NetDriver') }
    @{ P='^(mtkwl|mt7921|mtkwlan|athw|athwbx|qcwlan|bcmwl|rtwlan)'; What='Wi-Fi driver'; Steps=@('NetDriver') }
    @{ P='^(killer|kfe|knd)'; What='Killer network software'; Steps=@('NetDriver') }
    @{ P='^(usbxhci|usbhub3|ucx01000|usbport|usbhub|usbccgp|usbstor|uaspstor|hidusb|hidclass)'; What='USB system driver (often a USB device or hub)'; Steps=@('Usb','Chipset') }
    @{ P='^(ks|ksthunk|usbaudio|usbaudio2|portcls|hdaudbus|hdaudio|rtkvhd|cmudaxp|nahimicvad|nahimic)'; What='Audio / webcam driver'; Steps=@('AudioDriver','Usb') }
    @{ P='^(vgk|vgc)'; What='Riot Vanguard anti-cheat (Valorant/League)'; Steps=@('AntiCheat') }
    @{ P='^(easyanticheat|eac)'; What='Easy Anti-Cheat'; Steps=@('AntiCheat') }
    @{ P='^bedaisy'; What='BattlEye anti-cheat'; Steps=@('AntiCheat') }
    @{ P='^(faceit|esea)'; What='FACEIT/ESEA anti-cheat'; Steps=@('AntiCheat') }
    @{ P='^(asw|aswsp|aswsnx|aswarpot|avgsp|aswbidsdriver|avgsnx)'; What='Avast/AVG antivirus'; Steps=@('Antivirus') }
    @{ P='^(mfe|mcafee|epfw|eamonm|ehdrv|klif|kneps|klflt|bdsx|trufos|gzflt|avc3|sophos|savonaccess|ccsset|symefasi|srtsp|idsvia|navex|wrkrn|tmeevw|tmactmon|cyverak|cyvrfsfd)'; What='Third-party antivirus / security software'; Steps=@('Antivirus') }
    @{ P='^(wdfilter|wdboot|wdnisdrv)'; What='Windows Defender (usually reacting to another driver)'; Steps=@('DriverRecent','Sfc') }
    @{ P='^(wintun|tap0901|tapwindows|nordvpn|expressvpn|openvpn|wireguard|psi|surfshark)'; What='VPN driver'; Steps=@('NetDriver') }
    @{ P='^(rtcore64|rtcore32|winring0|winring0x64|aida64|gpuz|gpu-z|hwinfo|cpuz|asio|asio64|glckio2|ene|aura|lightingservice|gdrv|msio64|nvoclock|atillk64|amifldrv)'; What='Hardware monitoring / RGB / overclocking tool driver (MSI Afterburner, RGB software, etc.)'; Steps=@('GpuOc','Usb') }
    @{ P='^(vboxdrv|vboxnetlwf|vboxsup|vmx86|vmnetadapter|hvservice)'; What='Virtual machine software driver'; Steps=@('DriverRecent') }
    @{ P='^(bthport|bthusb|rfcomm|bthmini|ibtusb)'; What='Bluetooth driver'; Steps=@('NetDriver','Usb') }
    @{ P='^(acpi|pci|pdc|intelpep|amdpep)'; What='Motherboard / ACPI driver (points to BIOS or power settings)'; Steps=@('Bios','Chipset') }
    @{ P='^(cng|ksecdd|ci|peauth|clipsp)'; What='Windows security component (often triggered by memory corruption)'; Steps=@('RamTest','Sfc') }
    @{ P='^(xboxgip|xinputhid|ds4|vigembus|hidgame)'; What='Game controller driver'; Steps=@('Usb') }
)

# ------------------------------------------------------------------ Windows events
# Key: "ProviderName|EventId". Use "ProviderName|*" for a provider-wide fallback.
$script:EventKB = @{
    'Microsoft-Windows-WHEA-Logger|1'  = @{ Sev='critical'; Title='Fatal hardware error'; Plain='Your hardware (CPU, RAM, motherboard or PCIe device) reported an error it could not correct.'; Steps=@('CpuOc','RamXmp','Cooling','Bios','Psu') }
    'Microsoft-Windows-WHEA-Logger|18' = @{ Sev='critical'; Title='Fatal CPU hardware error'; Plain='The processor reported an error it could not fix (a "machine check"). Usually unstable overclock/undervolt (PBO, Curve Optimizer), overheating, or power delivery problems.'; Steps=@('CpuOc','Bios','Cooling','Psu') }
    'Microsoft-Windows-WHEA-Logger|19' = @{ Sev='warning'; Title='Corrected CPU/cache hardware error'; Plain='The processor found and fixed an error. A few are okay, but many of them mean the CPU is borderline unstable - often an overclock/undervolt or a BIOS issue.'; Steps=@('CpuOc','Bios') }
    'Microsoft-Windows-WHEA-Logger|17' = @{ Sev='warning'; Title='Corrected PCI Express error'; Plain='A device on the PCIe bus (graphics card, NVMe drive, Wi-Fi card) had a communication error that was fixed. Many of these can mean a loose card, a riser cable problem, or a power-saving bug.'; Steps=@('GpuPower','Bios','Chipset') }
    'Microsoft-Windows-WHEA-Logger|20' = @{ Sev='critical'; Title='Fatal PCI Express error'; Plain='A device on the PCIe bus had an error that could not be corrected.'; Steps=@('GpuPower','Bios','Chipset') }
    'Microsoft-Windows-WHEA-Logger|46' = @{ Sev='critical'; Title='Fatal memory error'; Plain='The memory reported an uncorrectable error.'; Steps=@('RamXmp','RamTest','RamReseat') }
    'Microsoft-Windows-WHEA-Logger|47' = @{ Sev='warning'; Title='Corrected memory error'; Plain='The memory had an error that was fixed. Repeated ones suggest unstable or failing RAM.'; Steps=@('RamXmp','RamTest') }
    'Microsoft-Windows-Kernel-Processor-Power|37' = @{ Sev='warning'; Title='CPU was slowed down by the firmware'; Plain='The BIOS/firmware limited your processor speed. This often happens because of high temperature or power limits.'; Steps=@('Cooling','Bios') }
    'disk|7'   = @{ Sev='critical'; Title='Bad block on a drive'; Plain='Part of a drive could not be read. The drive may be failing.'; Steps=@('DiskBackup','DiskCheck','DiskCable') }
    'disk|11'  = @{ Sev='critical'; Title='Drive controller error'; Plain='Windows had trouble talking to a drive. Often a loose/bad cable, a failing drive, or a power problem.'; Steps=@('DiskCable','DiskCheck','DiskBackup') }
    'disk|51'  = @{ Sev='warning'; Title='Error while writing to a drive'; Plain='Windows had a problem writing memory pages to a drive.'; Steps=@('DiskCheck','DiskCable') }
    'disk|153' = @{ Sev='warning'; Title='Drive operation had to be retried'; Plain='A drive was slow to respond and Windows had to retry. Occasional ones are normal; many suggest a struggling drive or cable.'; Steps=@('DiskCheck','DiskCable') }
    'disk|154' = @{ Sev='critical'; Title='Drive hardware error'; Plain='A drive returned a hardware error.'; Steps=@('DiskBackup','DiskCheck') }
    'Ntfs|55'  = @{ Sev='warning'; Title='File system corruption detected'; Plain='Windows found damage in the file system on a drive.'; Steps=@('DiskCheck','DiskBackup') }
    'Microsoft-Windows-Ntfs|55'  = @{ Sev='warning'; Title='File system corruption detected'; Plain='Windows found damage in the file system on a drive.'; Steps=@('DiskCheck','DiskBackup') }
    'Microsoft-Windows-Ntfs|98'  = @{ Sev='warning'; Title='Drive needs a file system check'; Plain='Windows marked a drive as needing repair.'; Steps=@('DiskCheck') }
    'Microsoft-Windows-Ntfs|137' = @{ Sev='warning'; Title='File system error'; Plain='The file system had an error (sometimes harmless after a crash).'; Steps=@('DiskCheck') }
    'Microsoft-Windows-Ntfs|140' = @{ Sev='warning'; Title='Failed to flush data to a drive'; Plain='Windows could not finish writing data to a drive - data may have been lost. Common after sudden power loss or with failing drives.'; Steps=@('DiskCheck','DiskCable') }
    'stornvme|11'  = @{ Sev='critical'; Title='NVMe drive controller error'; Plain='The NVMe (M.2) drive reported a controller error.'; Steps=@('DiskBackup','DiskCheck','Bios') }
    'stornvme|129' = @{ Sev='warning'; Title='NVMe drive was reset'; Plain='The NVMe drive stopped responding and was reset. Often SSD firmware or power-saving issues.'; Steps=@('DiskCheck','Chipset','Bios') }
    'storahci|129' = @{ Sev='warning'; Title='SATA drive was reset'; Plain='A SATA drive stopped responding and was reset. Often a bad cable or failing drive.'; Steps=@('DiskCable','DiskCheck') }
    'volmgr|161'   = @{ Sev='warning'; Title='Crash dump could not be saved'; Plain='Windows could not save a crash dump. Usually the page file is turned off or too small.'; Steps=@() }
    'volmgr|46'    = @{ Sev='warning'; Title='Crash dump not initialized'; Plain='Windows was not able to prepare for saving crash dumps.'; Steps=@() }
    'Display|4101' = @{ Sev='warning'; Title='Graphics driver stopped responding and recovered'; Plain='Your screen probably flickered or went black for a moment. The graphics driver froze and Windows restarted it. If it happens a lot, it often leads to full crashes.'; Steps=@('GpuDriver','GpuOc','GpuTemps','GpuPower') }
    'nvlddmkm|*'   = @{ Sev='warning'; Title='NVIDIA driver error'; Plain='The NVIDIA graphics driver logged an error (often an "Xid" code meaning the GPU had a problem).'; Steps=@('GpuDriver','GpuOc','GpuPower','GpuTemps') }
    'amdkmdag|*'   = @{ Sev='warning'; Title='AMD graphics driver error'; Plain='The AMD graphics driver logged an error.'; Steps=@('GpuDriver','GpuOc','GpuPower') }
    'amdkmdap|*'   = @{ Sev='warning'; Title='AMD graphics driver error'; Plain='The AMD graphics driver logged an error.'; Steps=@('GpuDriver','GpuOc') }
    'Service Control Manager|7031' = @{ Sev='info'; Title='A Windows service crashed and was restarted'; Plain='A background service stopped unexpectedly. One-off cases are usually harmless.'; Steps=@() }
    'Service Control Manager|7034' = @{ Sev='info'; Title='A Windows service crashed'; Plain='A background service stopped unexpectedly. One-off cases are usually harmless.'; Steps=@() }
    'Service Control Manager|7000' = @{ Sev='info'; Title='A service failed to start'; Plain='A background service could not start. Often leftover from uninstalled software.'; Steps=@() }
    'Service Control Manager|7001' = @{ Sev='info'; Title='A service failed to start (dependency)'; Plain='A service could not start because another service it needs did not start.'; Steps=@() }
    'Service Control Manager|7009' = @{ Sev='info'; Title='A service took too long to start'; Plain='Usually harmless, sometimes a sign of a slow drive at startup.'; Steps=@() }
    'Service Control Manager|7011' = @{ Sev='info'; Title='A service did not respond in time'; Plain='Usually harmless if it is rare.'; Steps=@() }
    'Service Control Manager|7023' = @{ Sev='info'; Title='A service stopped with an error'; Plain='Usually harmless if it is rare.'; Steps=@() }
    'Service Control Manager|7024' = @{ Sev='info'; Title='A service stopped with an error'; Plain='Usually harmless if it is rare.'; Steps=@() }
    'Service Control Manager|7043' = @{ Sev='info'; Title='A service did not shut down properly'; Plain='A service did not stop in time during shutdown. Usually harmless.'; Steps=@() }
    'Microsoft-Windows-Resource-Exhaustion-Detector|2004' = @{ Sev='warning'; Title='Your PC ran low on memory'; Plain='Windows was running out of memory (RAM + page file). Programs may have frozen or closed.'; Steps=@() }
    'Microsoft-Windows-Kernel-PnP|219' = @{ Sev='info'; Title='A device driver failed to load'; Plain='A driver for some device could not load at startup. Often harmless (a disconnected device), but check Device Manager for yellow warning icons.'; Steps=@() }
    'Microsoft-Windows-Kernel-Boot|29' = @{ Sev='warning'; Title='Windows had a startup failure'; Plain='Windows had a problem during startup.'; Steps=@('Sfc') }
    'Microsoft-Windows-MemoryDiagnostics-Results|1101' = @{ Sev='info'; Title='Memory test: no errors'; Plain='Windows Memory Diagnostic finished and found no problems.'; Steps=@() }
    'Microsoft-Windows-MemoryDiagnostics-Results|1201' = @{ Sev='info'; Title='Memory test: no errors'; Plain='Windows Memory Diagnostic finished and found no problems.'; Steps=@() }
    'Microsoft-Windows-MemoryDiagnostics-Results|1102' = @{ Sev='critical'; Title='Memory test FOUND ERRORS'; Plain='Windows Memory Diagnostic found errors in your RAM. This is very likely the cause of crashes.'; Steps=@('RamXmp','RamReseat','RamTest') }
    'Microsoft-Windows-MemoryDiagnostics-Results|1202' = @{ Sev='critical'; Title='Memory test FOUND ERRORS'; Plain='Windows Memory Diagnostic found errors in your RAM. This is very likely the cause of crashes.'; Steps=@('RamXmp','RamReseat','RamTest') }
    'Tcpip|4199' = @{ Sev='info'; Title='IP address conflict on the network'; Plain='Another device on your network used the same IP address. Restarting your router usually fixes it.'; Steps=@() }
    'Microsoft-Windows-Kernel-Power|172' = @{ Sev='info'; Title='Connectivity state changed during sleep'; Plain='Informational.'; Steps=@() }
    'Microsoft-Windows-Kernel-Power|137' = @{ Sev='info'; Title='Firmware power information'; Plain='Informational, usually harmless.'; Steps=@() }
    'Microsoft-Windows-Kernel-Power|125' = @{ Sev='info'; Title='Thermal zone information'; Plain='Informational.'; Steps=@() }
    'Microsoft-Windows-Kernel-Power|86'  = @{ Sev='info'; Title='Thermal zone information'; Plain='Informational.'; Steps=@() }
    'Microsoft-Windows-Kernel-Power|89'  = @{ Sev='info'; Title='Thermal zone information'; Plain='Informational.'; Steps=@() }
}

# Events that look scary but are normal Windows noise. Shown only as a collapsed count.
$script:NoiseEvents = @(
    'Microsoft-Windows-DistributedCOM|10016','Microsoft-Windows-DistributedCOM|10010','Microsoft-Windows-DistributedCOM|10005',
    'Microsoft-Windows-DistributedCOM|10001','Microsoft-Windows-Time-Service|*','Microsoft-Windows-DNS-Client|1014',
    'Microsoft-Windows-Kernel-EventTracing|*','Microsoft-Windows-WindowsUpdateClient|*','ESENT|*','SecurityCenter|*',
    'Microsoft-Windows-Search|*','VSS|8193','VSS|13','VSS|8194','Microsoft-Windows-WMI|10','Microsoft-Windows-Security-SPP|*',
    'Microsoft-Windows-User Profiles Service|1534','Microsoft-Windows-Perflib|*','Microsoft-Windows-RestartManager|*',
    'Microsoft-Windows-Kernel-General|*','Microsoft-Windows-Winlogon|*','Microsoft-Windows-GroupPolicy|*',
    'Microsoft-Windows-Store|*','Microsoft-Windows-AppModel-Runtime|*','Microsoft-Windows-AppXDeployment*|*',
    'Microsoft-Windows-Defrag|*','Microsoft-Windows-Bits-Client|*','Microsoft-Windows-Kernel-Boot|*',
    'Microsoft-Windows-WLAN-AutoConfig|*','Microsoft-Windows-Dhcp-Client|*','Microsoft-Windows-DHCPv6-Client|*',
    'Microsoft-Windows-Hyper-V*|*','Microsoft-Windows-Kernel-Power|*','EventLog|*','User32|*','Microsoft-Windows-Wininit|*',
    'Microsoft-Windows-Power-Troubleshooter|*','Microsoft-Windows-Iphlpsvc|*','Microsoft-Windows-WinRM|*',
    'Microsoft-Windows-TPM-WMI|*','Microsoft-Windows-Kernel-Processor-Power|55','Microsoft-Windows-Kernel-Processor-Power|26',
    'Microsoft-Windows-Bluetooth-BthLEPrepairing|*','LoadPerf|*','Microsoft-Windows-CAPI2|*','Microsoft-Windows-Folder Redirection|*',
    'Microsoft-Windows-Ntfs|98'
)

# ------------------------------------------------------------------ app crash exception codes
$script:ExceptionKB = @{
    'c0000005' = 'Access violation - the program tried to use memory it should not. Usually a bug in the program or in a plugin/overlay, sometimes unstable RAM.'
    'c0000409' = 'Stack buffer overrun - the program detected its own memory got damaged and shut itself down for safety. Usually a program bug or a conflicting overlay/injected software.'
    'c0000374' = 'Heap corruption - the program damaged its own memory. Usually a program bug, sometimes unstable RAM.'
    'e0434352' = '.NET error - the program (written in .NET) hit an error it did not handle. Reinstalling the program or the .NET runtime usually helps.'
    'e06d7363' = 'C++ error - the program hit an error it did not handle.'
    '80000003' = 'Breakpoint - the program stopped itself on purpose after detecting a problem.'
    'c000001d' = 'Illegal instruction - the program used a CPU instruction your processor does not support, or the CPU is unstable (overclock).'
    'c0000096' = 'Privileged instruction - usually a program bug or CPU instability.'
    'c00000fd' = 'Stack overflow - the program ran out of working memory for a task (program bug).'
    'c0000142' = 'The program failed to start (DLL initialization failed).'
    'c0000135' = 'A required DLL file is missing - reinstall the program.'
    'c000041d' = 'An error happened inside a callback - usually a program bug.'
    'c0000006' = 'In-page error - the program file could not be read from the drive (drive or network problem).'
    'c0000602' = 'Fail-fast exception - the program shut itself down after detecting a serious problem.'
    '40000015' = 'Fatal app exit - the program shut itself down on purpose.'
    'c0020001' = 'An internal Windows/runtime error in the program.'
}

$script:ModuleKB = @(
    @{ P='^(nvwgf2umx|nvwgf2um|nvd3dumx|nvoglv64|nvoglv32|nvldumdx|nvgpucomp64|nvcuda|nvapi64)'; What='NVIDIA graphics driver (user part)'; Steps=@('GpuDriver','GpuOlder','GpuOc') }
    @{ P='^(atiumd|atidxx|amdxx|amdxc|atio6axx|atig6pxx|amdvlk)'; What='AMD graphics driver (user part)'; Steps=@('GpuDriver','GpuOlder') }
    @{ P='^(igd10|igd11|igd12|igdumd|ig9icd|igc64|igxelpicd)'; What='Intel graphics driver (user part)'; Steps=@('GpuDriver') }
    @{ P='^(d3d11|d3d12|d3d12core|dxgi|d3d9|dxcore)'; What='DirectX (graphics) - often caused by the graphics driver or an overlay'; Steps=@('GpuDriver','GpuOc') }
    @{ P='^(ntdll|kernelbase|kernel32|ucrtbase|msvcp140|vcruntime140|msvcrt)'; What='Windows/runtime library (the program itself had the error - this file just reported it)'; Steps=@() }
    @{ P='^(clr|coreclr|clrjit|mscorwks)'; What='.NET runtime'; Steps=@() }
    @{ P='^(gameoverlayrenderer|discordhook|rtsshooks|overlay|igo64|igo32|nvspcap|easyhook|reshade|dxgi\.dll_reshade|mangohud|xboxgamebar)'; What='An overlay (Steam/Discord/RivaTuner/Xbox/ReShade) injected into the game'; Steps=@() }
    @{ P='^(unityplayer|ue4|unrealengine|ue5)'; What='The game engine itself'; Steps=@() }
    @{ P='^(xinput|dinput|hid)'; What='Game controller input'; Steps=@('Usb') }
    @{ P='^(audioses|xaudio|mmdevapi|fmod|wwise|dsound)'; What='Audio system'; Steps=@('AudioDriver') }
    @{ P='^(mfplat|mfcore|msmpeg2vdec)'; What='Windows video playback'; Steps=@('GpuDriver') }
)

# ------------------------------------------------------------------ live kernel events (GPU hangs that Windows recovered from)
$script:LiveKernelKB = @{
    '141' = 'The graphics card froze and was reset (no blue screen).'
    '117' = 'The graphics driver timed out and was reset (no blue screen).'
    '1a8' = 'A graphics hang was detected.'
    '193' = 'The Windows graphics system recorded an internal error.'
    '1b8' = 'A graphics scheduler problem was detected.'
    '15f' = 'The display connection had an error.'
    'ab'  = 'A session had a problem while shutting down.'
    '1a1' = 'The Windows graphics subsystem stopped responding.'
    '1d2' = 'A watchdog timeout was detected in the graphics or storage stack.'
}

function Resolve-Steps([object[]]$Keys) {
    # Turns step keys (or literal text) into sentences.
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Keys) {
        if (-not $k) { continue }
        if ($script:Step.ContainsKey($k)) { $out.Add($script:Step[$k]) } else { $out.Add([string]$k) }
    }
    return ,$out
}

function Get-BugCheckInfo([int64]$Code) {
    # Note: in PowerShell 5.1 hex literals above 0x7FFFFFFF are negative Int32, so compare as masked Int64.
    $mask = [int64]4294967295
    $c = ([int64]$Code) -band $mask
    $hex = '0x{0:X8}' -f $c
    # 0x1000007E etc. are the same as 0x7E with an extra flag
    if (($c -band [int64]4026531840) -eq [int64]268435456) { $c = $c -band [int64]268435455 }
    foreach ($k in $script:BugCheckKB.Keys) {
        if (([int64]$k -band $mask) -eq $c) {
            $e = $script:BugCheckKB[$k]
            return [pscustomobject]@{ Code=$hex; Name=$e.Name; Plain=$e.Plain; Area=$e.Area; Steps=$e.Steps; Known=$true }
        }
    }
    return [pscustomobject]@{ Code=$hex; Name='Unknown stop code'; Area='Unknown'
        Plain="This is a less common stop code ($hex). The driver named in this report (if any) is the best lead."
        Steps=@('SearchCode','DriverRecent','WinUpdate','RamTest'); Known=$false }
}

function Get-DriverInfo([string]$FileName) {
    if (-not $FileName) { return $null }
    $f = $FileName.ToLowerInvariant()
    foreach ($d in $script:DriverKB) {
        if ($f -match $d.P) { return [pscustomobject]@{ File=$FileName; What=$d.What; Steps=$d.Steps } }
    }
    return [pscustomobject]@{ File=$FileName; What='A third-party driver (search the file name to find which program or device it belongs to)'
        Steps=@("Search the web for `"$FileName`" to see which program or device installs it, then update or uninstall that program/driver.") }
}

function Get-EventKBEntry([string]$Provider, [int]$Id) {
    $k = "$Provider|$Id"
    if ($script:EventKB.ContainsKey($k)) { return $script:EventKB[$k] }
    $k2 = "$Provider|*"
    if ($script:EventKB.ContainsKey($k2)) { return $script:EventKB[$k2] }
    return $null
}

function Test-NoiseEvent([string]$Provider, [int]$Id) {
    foreach ($n in $script:NoiseEvents) {
        $parts = $n -split '\|'
        if ($Provider -like $parts[0] -and ($parts[1] -eq '*' -or $parts[1] -eq [string]$Id)) { return $true }
    }
    return $false
}

function Get-ModuleInfo([string]$Module) {
    if (-not $Module) { return $null }
    $m = $Module.ToLowerInvariant()
    foreach ($d in $script:ModuleKB) { if ($m -match $d.P) { return $d } }
    return $null
}

$script:Glossary = [ordered]@{
    'Blue screen (BSOD)' = 'When Windows hits an error it cannot safely recover from, it stops everything, shows a blue (or black) screen with a "stop code", saves a crash dump file, and restarts.'
    'Stop code / bug check' = 'The name of the error on a blue screen, like VIDEO_TDR_FAILURE. It tells you what kind of problem happened, not always which part caused it.'
    'Driver' = 'Small software that lets Windows talk to a piece of hardware (graphics card, Wi-Fi, sound...). Bad or outdated drivers are the #1 cause of blue screens.'
    'Crash dump' = 'A file Windows saves when it blue-screens (in C:\Windows\Minidump). It records what was happening at the moment of the crash.'
    'Unexpected shutdown' = 'The PC turned off or restarted without Windows shutting down normally - a crash, a freeze followed by holding the power button, or a sudden loss of power.'
    'PSU' = 'Power supply unit - the box that powers all the parts. A weak or failing PSU can make a PC turn off suddenly with no blue screen.'
    'WHEA' = 'Windows Hardware Error Architecture - how your CPU, RAM and motherboard report hardware errors to Windows.'
    'TDR' = 'Timeout Detection and Recovery - when the graphics card freezes, Windows tries to reset it. If that works, the screen flickers; if not, you get a blue screen.'
    'EXPO / XMP' = 'A one-click memory overclock setting in the BIOS. It makes RAM faster but is a common cause of instability on some systems.'
    'Hot spot' = 'The hottest point on the graphics chip. It is always higher than the normal GPU temperature.'
    'Tctl/Tdie' = 'The main AMD Ryzen CPU temperature sensor.'
    'BIOS / UEFI' = 'Your motherboard''s built-in settings screen (press Del or F2 while the PC starts).'
}
