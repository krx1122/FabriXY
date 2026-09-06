# ═════════════════════════════════════════════════════════════════════════════
#  RDP FABRIC PRO v8.0 "Menlít" — Core Engine  (shared by full + MVP workflows)
#  Invoke:  pwsh -NoProfile -File .github/scripts/Fabric-Core.ps1 -Mode full
#                                     ...                      -Mode mvp
# ═════════════════════════════════════════════════════════════════════════════
[CmdletBinding()]
param(
    [string]$Mode            = "full",            # full | mvp
    [string]$WorkloadProfile = "auto",
    [string]$RdpCompression  = "auto",
    [string]$QuickTest       = "false",
    [string]$EnableRamdisk   = "false",
    [string]$ReclaimDisk     = "true",
    [string]$DisableMitigations = "false",
    [string]$StartupUrl      = "https://fabric-x-xi.vercel.app/"
)

$ErrorActionPreference  = 'Continue'
$ProgressPreference     = 'SilentlyContinue'
$script:IsFull          = ($Mode -eq 'full')

$script:FabricRoot = $env:FABRIC_ROOT
if (-not $script:FabricRoot) { $script:FabricRoot = 'C:\ProgramData\RDPFabric' }
$script:User = $env:RDP_USER
if (-not $script:User) { $script:User = 'FabricAdmin' }
$script:RdpUser     = $env:RDP_USER
$script:DataRoot    = $null
$script:Deadline    = $null
$script:TsHostname  = $null
$script:TsIp        = $null
$script:TsDirect    = $null
$script:BestLetter  = $null
$script:RamGB       = 16
$script:Cpu         = 4
$script:Profile     = 'interactive'

function ConvertTo-FabricBool {
    param([string]$v)
    return ($v -eq 'true' -or $v -eq 'True' -or $v -eq '1')
}
function Write-Step  { param([string]$m) Write-Host "── $m" -ForegroundColor Cyan }
function Write-Log {
    param([string]$m)
    $line = '{0:o}  {1}' -f (Get-Date), $m
    New-Item -ItemType Directory -Path $script:FabricRoot -Force -ErrorAction SilentlyContinue | Out-Null
    Add-Content -Path (Join-Path $script:FabricRoot 'launch.log') -Value $line -Encoding UTF8
    Write-Host $m
}
function Set-EnvVar {
    param([string]$k, [string]$v)
    Set-Item -Path "env:$k" -Value $v -Force -ErrorAction SilentlyContinue
    if ($env:GITHUB_ENV -and (Test-Path -LiteralPath $env:GITHUB_ENV)) {
        "$k=$v" | Out-File -Append $env:GITHUB_ENV -Encoding utf8
    }
}
function Get-StateJson {
    $f = Join-Path $script:FabricRoot 'state.json'
    if (Test-Path -LiteralPath $f) {
        try { return Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}
function Save-State {
    param($obj)
    New-Item -ItemType Directory -Path $script:FabricRoot -Force | Out-Null
    ($obj | ConvertTo-Json) | Set-Content -Path (Join-Path $script:FabricRoot 'state.json') -Encoding UTF8
}
function Start-Detached {
    param([string]$FilePath, [string[]]$ArgumentList)
    Start-Process -FilePath $FilePath `
        -ArgumentList $ArgumentList -WindowStyle Hidden | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 0 — INVENTORY / PROFILE / ASYNC TAILSCALE DOWNLOAD
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-PhaseInventory {
    Write-Step "Phase 0: Inventory, adaptive profile, async Tailscale fetch"
    if (-not $env:RDP_PASS)  { throw "CRITICAL: RDP_PASSWORD secret is missing." }
    if (-not $env:TS_AUTHKEY){ throw "CRITICAL: TAILSCALE_AUTH_KEY secret is missing." }

    $runtime = [int]$env:FAB_RUNTIME
    if ($runtime -le 0) { $runtime = 345 }
    if (ConvertTo-FabricBool $QuickTest) { $runtime = 5 }
    if ($runtime -gt 345) { $runtime = 345 }
    if ($runtime -lt 1)   { $runtime = 1 }

    New-Item -ItemType Directory -Path $script:FabricRoot -Force | Out-Null
    $script:Deadline = (Get-Date).AddMinutes($runtime)

    $os      = Get-CimInstance Win32_OperatingSystem
    $cs      = Get-CimInstance Win32_ComputerSystem
    $script:RamGB  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeRamGB     = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $script:Cpu    = [int]$cs.NumberOfLogicalProcessors
    if ($script:Cpu -le 0) { $script:Cpu = [Environment]::ProcessorCount }
    $cpuCores      = [int]$cs.NumberOfProcessors
    $cpuName       = [string]$cs.Name
    if (-not $cpuName) { $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name }

    $sysLetter = $env:SystemDrive.TrimEnd(':')
    $volumes   = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -match 'NTFS' })
    $altVols   = @($volumes | Where-Object { $_.DriveLetter -ne $sysLetter } | Sort-Object SizeRemaining -Descending)
    $best      = $null
    if ($altVols.Count -gt 0 -and ($altVols[0].SizeRemaining / 1GB) -ge 8) { $best = $altVols[0] }
    else { $best = ($volumes | Sort-Object SizeRemaining -Descending | Select-Object -First 1) }

    $script:BestLetter = if ($best) { [string]$best.DriveLetter } else { $sysLetter }
    $script:DataRoot   = if ($best) { "$($best.DriveLetter):\RDPFabric\Data" }
                         else { Join-Path $script:FabricRoot 'Data' }
    foreach ($d in @($script:DataRoot, (Join-Path $script:DataRoot 'Temp'),
                     (Join-Path $script:DataRoot 'Drop'), (Join-Path $script:DataRoot 'Tools'))) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    $req = "$WorkloadProfile".ToLowerInvariant()
    if ($req -eq 'auto' -or [string]::IsNullOrWhiteSpace($req)) {
        if     ($script:RamGB -lt 12)          { $script:Profile = 'memory' }
        elseif ($script:Cpu -ge 8 -and $script:RamGB -ge 24) { $script:Profile = 'compute' }
        else                                   { $script:Profile = 'interactive' }
    } else { $script:Profile = $req }

    $script:RamdiskOk   = (ConvertTo-FabricBool $EnableRamdisk) -and $script:RamGB -ge 28 -and $freeRamGB -ge 12
    $script:Compress    = ($script:Profile -eq 'memory' -or $script:RamGB -lt 20)
    $script:PinKernel   = ($script:RamGB -ge 20 -and $script:Profile -ne 'memory')
    $script:PfMult      = if ($script:RamGB -lt 12) { 2.5 }
                          elseif ($script:RamGB -lt 24) { 2.0 }
                          elseif ($script:Profile -eq 'memory') { 2.0 } else { 1.25 }

    Save-State ([ordered]@{
        version='8.0'; minutes=$runtime; deadline=$script:Deadline.ToString('o')
        data_root=$script:DataRoot; fab_root=$script:FabricRoot; user=$script:User
        profile=$script:Profile; ram_gb=$script:RamGB; free_ram_gb=$freeRamGB
        cpu=$script:Cpu; cpu_cores=$cpuCores; cpu_name=$cpuName
        best_letter=$script:BestLetter; ramdisk=$script:RamdiskOk
        compress=$script:Compress; pin_kernel=$script:PinKernel; pf_mult=$script:PfMult; mode=$Mode
    })

    Write-Log ("Node: {0} | {1}c/{2}t | {3}GB RAM ({4}GB free) | profile={5} scratch={6}:" -f `
        $cpuName, $cpuCores, $script:Cpu, $script:RamGB, $freeRamGB, $script:Profile, $script:BestLetter)
    if ($script:RamGB -lt 24 -or $script:Cpu -lt 8) {
        Write-Host "WARNING: undersized for heavy tools. Use an 8 vCPU / 32 GB+ runner label." -ForegroundColor Red
    }
    Write-Host ("Session: {0} min (ends {1})" -f $runtime, $script:Deadline.ToString('HH:mm:ss')) -ForegroundColor Cyan

    # Async Tailscale MSI — pinned under FABRIC_ROOT so later TEMP redirection cannot orphan it.
    if ($script:IsFull) {
        $cacheDir  = Join-Path $script:FabricRoot 'cache'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $installer = Join-Path $cacheDir 'tailscale.msi'
        Set-EnvVar 'FABRIC_TS_MSI' $installer
        Remove-Item -LiteralPath $installer, "$installer.ok" -Force -ErrorAction SilentlyContinue
        $dl = Join-Path $cacheDir 'ts-download.ps1'
        @'
param($dst)
$u = "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi"
for ($i = 0; $i -lt 8; $i++) {
  & curl.exe -sS -L --retry 2 --retry-all-errors -m 90 --connect-timeout 15 -o $dst $u
  if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $dst) -and (Get-Item -LiteralPath $dst).Length -gt 1MB) {
    "ok" | Set-Content -LiteralPath ($dst + ".ok") -Encoding ASCII
    exit 0
  }
  Start-Sleep -Seconds 2
}
exit 1
'@ | Set-Content -LiteralPath $dl -Encoding UTF8
        Start-Detached "powershell.exe" @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$dl`"",'-dst',"`"$installer`"")
        Write-Log "Tailscale MSI background download started."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 1a — DEFENDER / SERVICES / POWER / GRAPHICS   (full only)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-PhaseServices {
    Write-Step "Phase 1a: Defender off, service quarantine, power & graphics"
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -DisableIOAVProtection $true `
          -DisableBehaviorMonitoring $true -DisableBlockAtFirstSeen $true `
          -DisableScriptScanning $true -DisableArchiveScanning $true `
          -DisableIntrusionPreventionSystem $true -MAPSReporting 0 -SubmitSamplesConsent 2 -Force -ErrorAction SilentlyContinue
    } catch {}
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Force | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    foreach ($svc in @('WinDefend','Sense','WdNisSvc','WdNisDrv','WdBoot','WdFilter','SecurityHealthService')) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    }
    $starve = @('WSearch','WMPNetworkSvc','DiagTrack','dmwappushservice','RetailDemo','SysMain','Superfetch',
                'MapsBroker','lfsvc','SharedAccess','WbioSrvc','XblAuthManager','XblGameSave','XboxGipSvc',
                'XboxNetApiSvc','WpnService','PcaSvc','WerSvc','DoSvc','wuauserv','UsoSvc','bits','WaaSMedicSvc',
                'sppsvc','Fax','PrintNotify','icssvc','PhoneSvc','TabletInputService','FrameServer',
                'BcastDVRUserService*','CaptureService*','CDPUserSvc*')
    foreach ($name in $starve) {
        Get-Service -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }
    foreach ($svc in @('Spooler','LanmanServer','LanmanWorkstation','Winmgmt','CryptSvc','EventLog','RpcSs',
                       'DcomLaunch','ProfSvc','Schedule','TermService','UmRdpService','SessionEnv',
                       'Audiosrv','AudioEndpointBuilder')) {
        Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $svc -ErrorAction SilentlyContinue
    }
    $wuAu = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    New-Item -Path $wuAu -Force | Out-Null
    Set-ItemProperty -Path $wuAu -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $wuAu -Name "NoAutoUpdate" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $wuAu -Name "AUOptions" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Force | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change monitor-timeout-ac 0 | Out-Null
    powercfg /change disk-timeout-ac 0     | Out-Null
    powercfg /hibernate off                | Out-Null
    powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
    $ultimate = (powercfg /list | Select-String "Ultimate Performance") -replace '.*GUID:\s*([a-f0-9-]+).*','$1'
    if ($ultimate) { powercfg -setactive $ultimate } else { powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }

    $scheme = 'scheme_current'; $cpuKey = 'sub_processor'
    foreach ($p in @(@('PERFBOOSTMODE',1),@('PERFINCPOL',0),@('PERFDECPOL',0),@('PERFINCTHRESHOLD',0),
                     @('PERFDECTHRESHOLD',0),@('CPMINCORES',100),@('CPMAXCORES',100),@('PERFEPP',0),
                     @('PERFAUTONOMOUS',0),@('PROCTHROTTLEMAX',100),@('PROCTHROTTLEMIN',100))) {
        powercfg -setacvalueindex $scheme $cpuKey $p[0] $p[1] | Out-Null
    }
    try {
        powercfg -setacvalueindex $scheme $cpuKey 0cc5b647-c1df-4637-891a-dec35c318583 100 | Out-Null
        powercfg -setacvalueindex $scheme $cpuKey ea062031-0e34-4ff1-9b6d-eb1059334028 100 | Out-Null
        powercfg -setacvalueindex $scheme sub_sleep 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0 | Out-Null
        powercfg -setacvalueindex $scheme sub_sleep d639518a-e56d-4345-8af2-b9f32fb26109 0 | Out-Null
    } catch {}
    powercfg -setactive $scheme | Out-Null

    try {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class TimerRes { [DllImport("ntdll.dll")] public static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution); }' -ErrorAction Stop
        [uint32]$cur = 0
        [TimerRes]::NtSetTimerResolution(5000, $true, [ref]$cur) | Out-Null
    } catch {}

    $tsPolicies = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    if (-not (Test-Path $tsPolicies)) { New-Item -Path $tsPolicies -Force | Out-Null }
    Set-ItemProperty -Path $tsPolicies -Name "fEnableH264" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fEnableH264444" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "RemoteDesktopProfile" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Dwm" -Name "DWMFRAMEINTERVAL" -Value 15 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "TdrDelay" -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "TdrDdiDelay" -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue

    $mmProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    Set-ItemProperty -Path $mmProfile -Name "NetworkThrottlingIndex" -Value 0xFFFFFFFF -Type DWord -Force
    Set-ItemProperty -Path $mmProfile -Name "SystemResponsiveness" -Value 0 -Type DWord -Force
    $games = Join-Path $mmProfile 'Tasks\Games'
    if (Test-Path $games) {
        Set-ItemProperty -Path $games -Name "GPU Priority" -Value 8 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $games -Name "Priority" -Value 6 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $games -Name "Scheduling Category" -Value "High" -Type String -Force -ErrorAction SilentlyContinue
    }
    if (ConvertTo-FabricBool $DisableMitigations) {
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "FeatureSettingsOverride" -Value 3 -Type DWord -Force
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "FeatureSettingsOverrideMask" -Value 3 -Type DWord -Force
            Write-Log "Speculative-execution mitigations relaxed (opt-in)."
        } catch {}
    }
    Write-Log "Phase 1a complete."
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 1b — MEMORY + SCHEDULER (adaptive)    (full only)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-PhaseMemory {
    Write-Step "Phase 1b: Adaptive memory manager & scheduler"
    $win32ps = if ($script:Profile -eq 'compute') { 24 } else { 38 }
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name "Win32PrioritySeparation" -Value $win32ps -Type DWord -Force

    $mm = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    Set-ItemProperty -Path $mm -Name "DisablePagingExecutive" -Value $(if ($script:PinKernel) {1} else {0}) -Type DWord -Force
    Set-ItemProperty -Path $mm -Name "LargeSystemCache"  -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $mm -Name "IoPageLockLimit"  -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $mm -Name "SecondLevelDataCache" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $mm -Name "PagedPoolSize"    -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $mm -Name "NonPagedPoolSize" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $mm -Name "PoolUsageMaximum" -Value 60 -Type DWord -Force
    Set-ItemProperty -Path $mm -Name "ClearPageFileAtShutdown" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $mm -Name "DisablePageCombining" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mm -Name "SessionPoolSize"  -Value 64 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mm -Name "SessionViewSize"  -Value 128 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mm -Name "MemoryCompression" -Value $(if ($script:Compress) {1} else {0}) -Type DWord -Force
    try {
        if ($script:Compress) { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue; Disable-MMAgent -PageCombining -ErrorAction SilentlyContinue }
        else { Disable-MMAgent -MemoryCompression -PageCombining -ErrorAction SilentlyContinue }
    } catch {}
    Set-ItemProperty -Path $mm -Name "GDIProcessHandleQuota"  -Value 65536 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mm -Name "USERProcessHandleQuota" -Value 65536 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mm -Name "MaxProcesses" -Value 0xFFFFFFFF -Type DWord -Force -ErrorAction SilentlyContinue

    $splitKb = if ($script:RamGB -ge 24) { 0 } else { 380000 }
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "SvcHostSplitThresholdInKB" -Value $splitKb -Type DWord -Force

    $fs = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
    Set-ItemProperty -Path $fs -Name "NtfsDisableLastAccessUpdate" -Value 0x80000001 -Type DWord -Force
    Set-ItemProperty -Path $fs -Name "NtfsDisable8dot3NameCreation" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $fs -Name "LongPathsEnabled" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $fs -Name "IRPStackSize" -Value 50 -Type DWord -Force
    fsutil behavior set disablelastaccess 1 | Out-Null
    fsutil behavior set disable8dot3 1     | Out-Null
    fsutil behavior set memoryusage 2      | Out-Null
    fsutil behavior set disabledeletenotify 0 | Out-Null

    $desk = "HKCU:\Control Panel\Desktop"
    New-Item -Path $desk -Force | Out-Null
    Set-ItemProperty -Path $desk -Name "HungAppTimeout" -Value 2000 -Type String -Force
    Set-ItemProperty -Path $desk -Name "WaitToKillAppTimeout" -Value 2000 -Type String -Force
    Set-ItemProperty -Path $desk -Name "WaitToKillServiceTimeout" -Value 2000 -Type String -Force
    Set-ItemProperty -Path $desk -Name "AutoEndTasks" -Value "1" -Type String -Force
    Set-ItemProperty -Path $desk -Name "ForegroundLockTimeout" -Value 0 -Type DWord -Force

    $crash = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
    Set-ItemProperty -Path $crash -Name "CrashDumpEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $crash -Name "LogEvent" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name "Disabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name "DontShowUI" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Stop-Service -Name WerSvc -Force -ErrorAction SilentlyContinue
    Set-Service -Name WerSvc -StartupType Disabled -ErrorAction SilentlyContinue

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\FTH" -Name "Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Force | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Name "DisableEngine" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Name "DisablePCA" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    if ($script:Profile -eq 'compute') {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Dwm" -Name "DWMFRAMEINTERVAL" -Value 16 -Type DWord -Force -ErrorAction SilentlyContinue
    }
    Write-Log "Scheduler=$win32ps profile=$($script:Profile) compress=$($script:Compress) pinKernel=$($script:PinKernel)"
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 1c — RDP PROVISIONING  (CRITICAL)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-PhaseRdp {
    Write-Step "Phase 1c: RDP provisioning, channels & firewall"
    $secPass = ConvertTo-SecureString $env:RDP_PASS -AsPlainText -Force
    New-LocalUser -Name $script:User -Password $secPass -Description "Fabric RDP User" -AccountNeverExpires -ErrorAction SilentlyContinue | Out-Null
    Add-LocalGroupMember -Group "Administrators" -Member $script:User -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group "Remote Desktop Users" -Member $script:User -ErrorAction SilentlyContinue

    $tsCtrl = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
    $tsPolicies = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    if (-not (Test-Path -LiteralPath $tsPolicies)) { New-Item -Path $tsPolicies -Force | Out-Null }
    Set-ItemProperty -Path $tsCtrl -Name "fDenyTSConnections" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fClientDisableUDP" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $tsCtrl -Name "fSingleSessionPerUser" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "RDP-TCP-In" -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "RDP-UDP-In" -Direction Inbound -Protocol UDP -LocalPort 3389 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "Tailscale-In-UDP" -Direction Inbound -Protocol UDP -LocalPort 41641 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "Tailscale-Out-UDP" -Direction Outbound -Protocol UDP -RemotePort 41641 -Action Allow -ErrorAction SilentlyContinue | Out-Null

    Set-ItemProperty -Path $tsPolicies -Name "MaxIdleTime" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $tsPolicies -Name "MaxDisconnectionTime" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $tsPolicies -Name "KeepAliveEnable" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $tsPolicies -Name "KeepAliveInterval" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $tsPolicies -Name "fDisableCdm" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fDisableClip" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fDisableCcm" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fDisableCpm" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $tsPolicies -Name "fDisableLPT" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $tsPolicies -Name "fDisableAudioCapture" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

    $rdpTcp = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    if (-not (Test-Path $rdpTcp)) { New-Item -Path $rdpTcp -Force | Out-Null }
    Set-ItemProperty -Path $rdpTcp -Name "FlowControlDisable" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $rdpTcp -Name "SelectNetworkDetect" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $rdpTcp -Name "SelectTransport" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $rdpTcp -Name "OutBufLength" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $rdpTcp -Name "OutBufCount" -Value 128 -Type DWord -Force
    Set-ItemProperty -Path $rdpTcp -Name "OutBufDelay" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $rdpTcp -Name "MaxCompressionLevel" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $rdpTcp -Name "MinEncryptionLevel" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $rdpTcp -Name "ColorDepth" -Value 5 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Log "RDP listener armed."
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 1d — DISK RECLAIM + PAGEFILE + SCRATCH  (full only)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-PhaseDisk {
    Write-Step "Phase 1d: Disk reclaim, virtual RAM, scratch layout"
    if (ConvertTo-FabricBool $ReclaimDisk) {
        try { Disable-WindowsErrorReporting -ErrorAction SilentlyContinue | Out-Null } catch {}
        @("$env:SystemRoot\Temp\*", "$env:SystemRoot\Minidump\*", "$env:SystemDrive\Windows\MEMORY.DMP") |
            ForEach-Object { Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue }
    }
    $vol = Get-Volume -DriveLetter $script:BestLetter -ErrorAction SilentlyContinue
    $freeGB = if ($vol) { [math]::Round($vol.SizeRemaining / 1GB, 1) } else { 0 }
    $targetMB = [math]::Min([math]::Floor($script:RamGB * $script:PfMult * 1024), 65536)
    $capMB = [math]::Floor($freeGB * 0.45 * 1024)
    if ($capMB -gt 0) { $targetMB = [math]::Min($targetMB, $capMB) }

    $pfPath = "$($script:BestLetter):\pagefile.sys"
    $sysLetter = $env:SystemDrive.TrimEnd(':')
    try {
        $mm = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
        $existing = @()
        try { $existing = @((Get-ItemProperty -Path $mm -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles) } catch {}
        $hasC = $existing | Where-Object { $_ -match ("^" + [regex]::Escape("${sysLetter}:")) }
        if (-not $hasC) { $existing = @("${sysLetter}:\pagefile.sys 0 0") + @($existing | Where-Object { $_ -and ($_ -notmatch [regex]::Escape($pfPath)) }) }
        if ($targetMB -ge 2048 -and $script:BestLetter -ne $sysLetter) {
            $existing = @($existing | Where-Object { $_ -and ($_ -notmatch [regex]::Escape($pfPath)) }) + @("$pfPath $targetMB $targetMB")
        }
        Set-ItemProperty -Path $mm -Name "PagingFiles" -Value $existing -Type MultiString -Force
        Write-Log ("Pagefile: {0}" -f ($existing -join ' | '))
    } catch { Write-Log "Pagefile untouched: $($_.Exception.Message)" }

    if ($targetMB -ge 2048 -and $script:BestLetter -ne $sysLetter) {
        $job = Start-Job -ScriptBlock {
            param($letter, $mb, $path)
            $ErrorActionPreference = 'Stop'
            $cs = Get-CimInstance Win32_ComputerSystem
            if ($cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } }
            $already = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $path }
            if (-not $already) {
                New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $path; InitialSize = [int]$mb; MaximumSize = [int]$mb } | Out-Null
            } else {
                $already | Set-CimInstance -Property @{ InitialSize = [int]$mb; MaximumSize = [int]$mb }
            }
        } -ArgumentList $script:BestLetter, $targetMB, $pfPath
        if (-not (Wait-Job $job -Timeout 20)) {
            Stop-Job $job -ErrorAction SilentlyContinue
            Write-Log "Live pagefile add on $($script:BestLetter): timed out at 20s — C: file stays in use."
        } elseif ($job.State -eq 'Completed') {
            Write-Log "Added live pagefile $targetMB MB on $pfPath (C: pagefile kept)."
        }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }

    $scratch = Join-Path $script:DataRoot 'Temp'
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    [Environment]::SetEnvironmentVariable('TEMP', $scratch, 'Machine')
    [Environment]::SetEnvironmentVariable('TMP', $scratch, 'Machine')
    [Environment]::SetEnvironmentVariable('NUGET_PACKAGES', (Join-Path $script:DataRoot 'nuget'), 'Machine')
    [Environment]::SetEnvironmentVariable('npm_config_cache', (Join-Path $script:DataRoot 'npm-cache'), 'Machine')
    [Environment]::SetEnvironmentVariable('PIP_CACHE_DIR', (Join-Path $script:DataRoot 'pip-cache'), 'Machine')
    [Environment]::SetEnvironmentVariable('CARGO_HOME', (Join-Path $script:DataRoot 'cargo'), 'Machine')
    [Environment]::SetEnvironmentVariable('GRADLE_USER_HOME', (Join-Path $script:DataRoot 'gradle'), 'Machine')
    [Environment]::SetEnvironmentVariable('DOTNET_CLI_HOME', (Join-Path $script:DataRoot 'dotnet'), 'Machine')
    $useServerGc = ($script:Profile -eq 'compute' -and $script:Cpu -ge 4)
    [Environment]::SetEnvironmentVariable('DOTNET_gcServer', $(if ($useServerGc) {'1'} else {'0'}), 'Machine')
    [Environment]::SetEnvironmentVariable('COMPlus_gcServer', $(if ($useServerGc) {'1'} else {'0'}), 'Machine')

    if ($script:RamdiskOk) {
        try {
            $imdisk = "C:\Program Files\ImDisk\imdisk.exe"
            if (-not (Test-Path -LiteralPath $imdisk)) {
                $zip = "$env:TEMP\imdisktk.zip"; $ex = "$env:TEMP\imdisktk"; $ok = $false
                foreach ($u in @("https://downloads.sourceforge.net/project/imdisk-toolkit/20240113/ImDiskTk-x64.zip","https://sourceforge.net/projects/imdisk-toolkit/files/latest/download")) {
                    & curl.exe -sS -L --retry 2 -m 240 -o $zip $u
                    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $zip) -and (Get-Item -LiteralPath $zip).Length -gt 1MB) { $ok = $true; break }
                }
                if ($ok) {
                    Expand-Archive -Path $zip -DestinationPath $ex -Force -ErrorAction SilentlyContinue
                    $setup = Get-ChildItem -Path $ex -Recurse -Include "install.bat" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($setup) { Start-Process -FilePath $setup.FullName -ArgumentList "install" -WorkingDirectory (Split-Path $setup.FullName) -Wait -WindowStyle Hidden }
                }
            }
            if (Test-Path -LiteralPath $imdisk) {
                $freeMB = [math]::Floor((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
                $sizeMB = [math]::Min(4096, [math]::Floor($freeMB * 0.15))
                if ($sizeMB -ge 1024) {
                    & $imdisk -a -s ${sizeMB}M -m R: -p "/fs:ntfs /q /y" | Out-Null
                    if (Test-Path "R:\") {
                        New-Item -ItemType Directory -Path "R:\Temp" -Force | Out-Null
                        [Environment]::SetEnvironmentVariable('TEMP', 'R:\Temp', 'Machine')
                        [Environment]::SetEnvironmentVariable('TMP', 'R:\Temp', 'Machine')
                        Write-Log "RAM disk R: ${sizeMB} MB mounted."
                    }
                }
            }
        } catch { Write-Log "RAM disk skipped: $($_.Exception.Message)" }
    }
    Write-Log "Scratch layout ready."
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 2 — TAILSCALE + SPLIT TCP STACK  (CRITICAL)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-PhaseTailscale {
    Write-Step "Phase 2: Tailscale mesh + split network stack"
    $installer = $env:FABRIC_TS_MSI
    if (-not $installer) { $installer = Join-Path $script:FabricRoot 'cache\tailscale.msi' }
    $marker = "$installer.ok"

    if ($script:IsFull) {
        $dlDeadline = (Get-Date).AddSeconds(25)
        while ((Get-Date) -lt $dlDeadline) {
            if ((Test-Path -LiteralPath $marker -PathType Leaf) -and (Test-Path -LiteralPath $installer -PathType Leaf)) { break }
            Start-Sleep -Milliseconds 400
        }
    }
    $msiSize = 0
    if (Test-Path -LiteralPath $installer -PathType Leaf) {
        $fi = Get-Item -LiteralPath $installer -ErrorAction SilentlyContinue
        if ($fi) { $msiSize = $fi.Length }
    }
    if ($msiSize -lt 1MB) {
        Write-Log "MSI not ready — synchronous fetch..."
        New-Item -ItemType Directory -Path (Split-Path $installer) -Force | Out-Null
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        $ok = $false
        for ($i = 0; $i -lt 5 -and -not $ok; $i++) {
            & curl.exe -sS -L --retry 2 --retry-all-errors -m 90 --connect-timeout 15 -o $installer "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi"
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $installer -PathType Leaf) -and (Get-Item -LiteralPath $installer).Length -gt 1MB) { $ok = $true }
            else { Start-Sleep -Seconds 3 }
        }
        if (-not $ok) { throw "Failed to download Tailscale MSI." }
    }
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

    Write-Log ("Installing Tailscale ({0} MB)..." -f [math]::Round((Get-Item -LiteralPath $installer).Length/1MB,1))
    $msiProc = Start-Process msiexec.exe -ArgumentList "/i", "`"$installer`"", "/qn", "/norestart" -PassThru -Wait
    if ($msiProc.ExitCode -notin 0, 1641, 3010) {
        Start-Process msiexec.exe -ArgumentList "/i", "`"$installer`"", "/qn", "/norestart" -Wait
    }
    $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
    if (-not (Test-Path -LiteralPath $tsPath)) { throw "Tailscale installation failed." }

    $script:TsHostname = "fabric-node-$env:RUN_ID-$env:MATRIX_ID"
    if (-not $env:MATRIX_ID) { $script:TsHostname = "fabric-node-$env:RUN_ID" }
    & $tsPath up --authkey="$env:TS_AUTHKEY" --hostname="$script:TsHostname" --accept-routes=false --accept-dns=false --unattended --reset

    $backend = $null
    for ($i = 0; $i -lt 40; $i++) {
        try { $backend = (& $tsPath status --json 2>$null | ConvertFrom-Json).BackendState } catch {}
        if ($backend -eq 'Running') { break }
        Start-Sleep -Seconds 1
    }
    if ($backend -ne 'Running') {
        throw "Tailscale login/start failed (BackendState='$backend'). Verify TAILSCALE_AUTH_KEY validity/ephemerality."
    }

    $script:TsIp = ""; $t = 30
    while (-not ($script:TsIp -match "^\d{1,3}(\.\d{1,3}){3}$") -and $t -gt 0) {
        Start-Sleep -Seconds 1
        $script:TsIp = (& $tsPath ip -4 | Out-String).Trim(); $t--
    }
    if (-not $script:TsIp) { throw "Failed to acquire Tailscale IP." }

    $tsStatus = (& $tsPath status 2>$null | Out-String)
    $script:TsDirect = ($tsStatus -notmatch 'relay')

    # ── Split stack (full only) ───────────────────────────────────────────
    if ($script:IsFull) {
        $tcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
        Set-ItemProperty -Path $tcpParams -Name "Tcp1323Opts" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $tcpParams -Name "SackOpts" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $tcpParams -Name "DefaultTTL" -Value 64 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $tcpParams -Name "EnablePMTUDiscovery" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $tcpParams -Name "EnablePMTUBHDetect" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $tcpParams -Name "TcpTimedWaitDelay" -Value 30 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $tcpParams -Name "MaxUserPort" -Value 65534 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $tcpParams -Name "EnableTCPChimney" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $tcpParams -Name "EnableRSS" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $tcpParams -Name "EnableWsd" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

        netsh int ipv4 set dynamicport tcp start=1025 num=64510 | Out-Null
        netsh int ipv4 set dynamicport udp start=1025 num=64510 | Out-Null
        netsh winhttp reset proxy | Out-Null
        $autoLevel = if ($script:Profile -eq 'network') { 'experimental' } else { 'normal' }
        netsh int tcp set global autotuninglevel=$autoLevel | Out-Null
        netsh int tcp set global rss=enabled | Out-Null
        netsh int tcp set global rsc=enabled | Out-Null
        netsh int tcp set global chimney=disabled | Out-Null
        netsh int tcp set global timestamps=enabled | Out-Null
        netsh int tcp set global ecncapability=enabled | Out-Null
        netsh int tcp set global maxsynretransmissions=2 | Out-Null
        netsh int tcp set global initialrto=2000 | Out-Null
        try {
            Set-NetTCPSetting -SettingName InternetCustom -CongestionProvider CUBIC -InitialCongestionWindowMss 10 -ErrorAction SilentlyContinue
            Set-NetTCPSetting -SettingName Internet -CongestionProvider CUBIC -ErrorAction SilentlyContinue
            Set-NetTCPSetting -SettingName Datacenter -CongestionProvider CUBIC -ErrorAction SilentlyContinue
        } catch {}

        Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
            try { Disable-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue } catch {}
            try {
                $adv = Get-NetAdapterAdvancedProperty -Name $_.Name -ErrorAction SilentlyContinue
                foreach ($p in @('Receive Side Scaling','Recv Segment Coalescing (IPv4)','Recv Segment Coalescing (IPv6)','IPv4 Checksum Offload','TCP Checksum Offload (IPv4)','TCP Checksum Offload (IPv6)','UDP Checksum Offload (IPv4)','UDP Checksum Offload (IPv6)')) {
                    if ($adv | Where-Object { $_.DisplayName -eq $p }) {
                        Set-NetAdapterAdvancedProperty -Name $_.Name -DisplayName $p -DisplayValue 'Enabled' -ErrorAction SilentlyContinue
                    }
                }
            } catch {}
            $netbtKey = "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_$($_.InterfaceGuid)"
            if (Test-Path $netbtKey) { Set-ItemProperty -Path $netbtKey -Name "NetbiosOptions" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue }
        }
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters" -Name "EnableLMHOSTS" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

        $tsAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Tailscale" -or $_.Name -match "Tailscale" } | Select-Object -First 1
        if ($tsAdapter) {
            netsh interface ipv4 set subinterface "$($tsAdapter.Name)" mtu=1280 store=persistent | Out-Null
            $ifKey = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -ErrorAction SilentlyContinue |
                Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DhcpIPAddress -eq $script:TsIp -or (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).IPAddress -contains $script:TsIp } |
                Select-Object -First 1
            if (-not $ifKey) { $ifKey = Get-Item "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($tsAdapter.InterfaceGuid)" -ErrorAction SilentlyContinue }
            if ($ifKey) {
                Set-ItemProperty -Path $ifKey.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $ifKey.PSPath -Name "TcpDelAckTicks" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $ifKey.PSPath -Name "TCPNoDelay" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
        $dnsc = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters"
        New-Item -Path $dnsc -Force | Out-Null
        Set-ItemProperty -Path $dnsc -Name "MaxCacheTtl" -Value 86400 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $dnsc -Name "MaxNegativeCacheTtl" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $dnsc -Name "NegativeCacheTime" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $dnsc -Name "NetFailureCacheTime" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Clear-DnsClientCache -ErrorAction SilentlyContinue

        foreach ($p in @("HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client",
                         "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server")) {
            New-Item -Path $p -Force | Out-Null
            Set-ItemProperty -Path $p -Name "DisabledByDefault" -Value 0 -Type DWord -Force
            Set-ItemProperty -Path $p -Name "Enabled" -Value 1 -Type DWord -Force
        }

        $wantComp = $false
        switch ("$RdpCompression".ToLowerInvariant()) {
            'on'  { $wantComp = $true }
            'off' { $wantComp = $false }
            default { $wantComp = -not $script:TsDirect }
        }
        $rdpTcp = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
        Set-ItemProperty -Path $rdpTcp -Name "fDisableCompression" -Value $(if ($wantComp) {0} else {1}) -Type DWord -Force
        Set-ItemProperty -Path $rdpTcp -Name "MaxCompressionLevel" -Value $(if ($wantComp) {2} else {0}) -Type DWord -Force
        if (-not $script:TsDirect) {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fEnableH264444" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        try {
            New-NetQosPolicy -Name "Fabric-RDP" -IPDstPortStart 3389 -IPDstPortEnd 3389 -DSCPAction 46 -NetworkProfile All -ErrorAction SilentlyContinue | Out-Null
            New-NetQosPolicy -Name "Fabric-TS" -IPDstPortStart 41641 -IPDstPortEnd 41641 -DSCPAction 46 -NetworkProfile All -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }

    Save-State ([ordered]@{
        version='8.0'; host=$script:TsHostname; ip=$script:TsIp
        path=$(if ($script:TsDirect) {'direct'} else {'DERP relay'}); user=$script:User
        minutes=[int]$env:FAB_RUNTIME; deadline=$script:Deadline.ToString('o')
        profile=$script:Profile; ram_gb=$script:RamGB; cpu=$script:Cpu; mode=$Mode
        data_root=$script:DataRoot
    })

    # Telegram login ping (full only) — non-fatal
    if ($script:IsFull -and $env:TG_TOKEN -and $env:TG_CHAT) {
        $msg = "⚡ <b>Fabric Node Online v8.0</b>`n`n🖥 <b>Host:</b> <code>$($script:TsHostname)</code>`n🌐 <b>IP:</b> <code>$($script:TsIp)</code>`n🔗 <b>Path:</b> <code>$(if ($script:TsDirect) {'direct'} else {'relay'})</code>`n👤 <b>User:</b> <code>$($script:User)</code>`n🧠 <b>Profile:</b> <code>$($script:Profile)</code>`n⚙️ <b>HW:</b> <code>$($script:Cpu) CPU / $($script:RamGB) GB</code>`n⏳ <b>Duration:</b> <code>$env:FAB_RUNTIME</code> min`n📁 <b>Drop:</b> <code>$(Join-Path $script:DataRoot 'Drop')</code>"
        try { Invoke-RestMethod -Uri "https://api.telegram.org/bot$($env:TG_TOKEN)/sendMessage" -Method Post -Body @{chat_id=$env:TG_CHAT; text=$msg; parse_mode="HTML"} -TimeoutSec 15 | Out-Null; Write-Log "Telegram ping sent." }
        catch { Write-Log "Telegram ping failed (non-fatal)." }
    }

    Write-Host ("Tailscale online: {0} ({1}) path={2}" -f $script:TsIp, $script:TsHostname, $(if ($script:TsDirect) {'direct'} else {'DERP'})) -ForegroundColor Green
    Write-Log "CONNECT → host=$($script:TsHostname) ip=$($script:TsIp) user=$($script:User) path=$(if ($script:TsDirect) {'direct'} else {'DERP'})"
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 2.5 — RUNTIME BOOTSTRAP (VC++/DX/.NET/WebView2/7-Zip)  (full, async)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-PhaseRuntime {
    Write-Step "Phase 2.5: Runtime bootstrap (background)"
    $tools = Join-Path $script:DataRoot 'Tools'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    $seed = Join-Path $tools 'seed-runtimes.ps1'
    @'
param($tools)
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'SilentlyContinue'
$log = Join-Path $tools 'runtime-bootstrap.log'
"seed start $(Get-Date -Format o)" | Out-File $log -Encoding utf8

function Invoke-Get {
  param([string]$url, [string]$dst)
  & curl.exe -sS -L --retry 2 --retry-all-errors -m 300 -o $dst $url
  return ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $dst) -and (Get-Item -LiteralPath $dst).Length -gt 100KB)
}
function Invoke-Exe {
  param([string]$exe, [string[]]$args1)
  if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe -ArgumentList $args1 -Wait -WindowStyle Hidden }
}

# --- Visual C++ redists: 2008 → 2015+ (x86 + x64) ---
$vc = @(
  @{ n='vc2008_x64.exe'; u='https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe'; a=@('/q') },
  @{ n='vc2008_x86.exe'; u='https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe'; a=@('/q') },
  @{ n='vc2010_x64.exe'; u='https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'; a=@('/q','/norestart') },
  @{ n='vc2010_x86.exe'; u='https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe'; a=@('/q','/norestart') },
  @{ n='vc2012_x64.exe'; u='https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe'; a=@('/install','/quiet','/norestart') },
  @{ n='vc2012_x86.exe'; u='https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe'; a=@('/install','/quiet','/norestart') },
  @{ n='vc2013_x64.exe'; u='https://aka.ms/highdpimfc2013x64enu'; a=@('/install','/quiet','/norestart') },
  @{ n='vc2013_x86.exe'; u='https://aka.ms/highdpimfc2013x86enu'; a=@('/install','/quiet','/norestart') },
  @{ n='vc2015_x64.exe'; u='https://aka.ms/vc14/vc_redist.x64.exe'; a=@('/install','/quiet','/norestart') },
  @{ n='vc2015_x86.exe'; u='https://aka.ms/vc14/vc_redist.x86.exe'; a=@('/install','/quiet','/norestart') }
)
foreach ($p in $vc) {
  $dst = Join-Path $tools $p.n
  if (Invoke-Get -url $p.u -dst $dst) { Invoke-Exe -exe $dst -args1 $p.a; "[ok ] $($p.n)" | Out-File $log -Append -Encoding utf8 }
  else { "[fail] $($p.n)" | Out-File $log -Append -Encoding utf8 }
}

# --- .NET Desktop Runtimes 6 / 7 / 8 ---
foreach ($v in @('6.0','7.0','8.0')) {
  $dot = Join-Path $tools ("dotnet-desktop-$v-x64.exe")
  $u = "https://aka.ms/dotnet/$v/windowsdesktop-runtime-win-x64.exe"
  if (Invoke-Get -url $u -dst $dot) { Invoke-Exe -exe $dot -args1 @('/install','/quiet','/norestart'); "[ok ] dotnet $v" | Out-File $log -Append -Encoding utf8 }
  else { "[fail] dotnet $v" | Out-File $log -Append -Encoding utf8 }
}

# --- DirectX End-User Runtime (d3dx9/d3dx11/xinput/dsound) ---
$dx = Join-Path $tools 'dxwebsetup.exe'
if (Invoke-Get -url 'https://download.microsoft.com/download/1/7/1/1718ccc4-6315-4d8e-9543-8e28a4e18c4c/dxwebsetup.exe' -dst $dx) {
  Invoke-Exe -exe $dx -args1 @('/Q'); "[ok ] DirectX" | Out-File $log -Append -Encoding utf8
} else { "[fail] DirectX" | Out-File $log -Append -Encoding utf8 }

# --- WebView2 Evergreen ---
$wv = Join-Path $tools 'MicrosoftEdgeWebview2Setup.exe'
if (Invoke-Get -url 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -dst $wv) {
  Invoke-Exe -exe $wv -args1 @('/silent','/install'); "[ok ] WebView2" | Out-File $log -Append -Encoding utf8
} else { "[fail] WebView2" | Out-File $log -Append -Encoding utf8 }

# --- 7-Zip (winget, best-effort) ---
try {
  winget install -e --id 7zip.7zip --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>$null | Out-Null
  "[ok ] 7-Zip" | Out-File $log -Append -Encoding utf8
} catch { "[fail] 7-Zip" | Out-File $log -Append -Encoding utf8 }

"seed done $(Get-Date -Format o)" | Out-File $log -Append -Encoding utf8
'@ | Set-Content -LiteralPath $seed -Encoding UTF8
    Start-Detached "powershell.exe" @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$seed`"",'-tools',"`"$tools`"")
    try { winget source update --disable-interactivity 2>$null | Out-Null } catch {}
    Write-Log "Runtime bootstrap started in background."
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 2.7 — WORKSTATION MODE (UAC/SmartScreen/MOTW/WER/ACL)  (full only)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-PhaseWorkstation {
    Write-Step "Phase 2.7: Workstation mode, MOTW, crash dumps, shortcuts"
    $drop  = Join-Path $script:DataRoot 'Drop'
    $tools = Join-Path $script:DataRoot 'Tools'
    $crashDumps = Join-Path $script:DataRoot 'CrashDumps'
    New-Item -ItemType Directory -Path $drop, $tools, $crashDumps -Force | Out-Null

    $lu = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-ItemProperty -Path $lu -Name "EnableLUA" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $lu -Name "ConsentPromptBehaviorAdmin" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $lu -Name "PromptOnSecureDesktop" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $lu -Name "EnableInstallerDetection" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $lu -Name "FilterAdministratorToken" -Value 0 -Type DWord -Force

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableSmartScreen" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" -Name "SmartScreenEnabled" -Value "Off" -Type String -Force
    $attach = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments"
    New-Item -Path $attach -Force | Out-Null
    Set-ItemProperty -Path $attach -Name "SaveZoneInformation" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $attach -Name "ScanWithAntiVirus" -Value 1 -Type DWord -Force

    # WER LocalDumps — every crash → mini-dump in CrashDumps
    $wer = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps"
    New-Item -Path $wer -Force | Out-Null
    Set-ItemProperty -Path $wer -Name "DumpFolder" -Value $crashDumps -Type ExpandString -Force
    Set-ItemProperty -Path $wer -Name "DumpType" -Value 2 -Type DWord -Force
    Set-ItemProperty -Path $wer -Name "DumpCount" -Value 10 -Type DWord -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" -Name "ExecutionPolicy" -Value "Bypass" -Type String -Force
    Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
    $ieZone = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\3"
    if (Test-Path $ieZone) { Set-ItemProperty -Path $ieZone -Name "1806" -Value 0 -Type DWord -Force }

    Add-MpPreference -ExclusionPath @($script:FabricRoot, $script:DataRoot, $drop, $tools, $crashDumps, "C:\Users\$($script:User)", "C:\Program Files", "C:\Program Files (x86)", "C:\Temp", "$env:TEMP") -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionExtension @('.exe','.msi','.msix','.appx','.dll','.sys','.bat','.cmd','.ps1','.vbs','.zip','.7z','.rar') -ErrorAction SilentlyContinue

    # Desktop shortcuts (Drop, Crash Dumps)
    $wsh = New-Object -ComObject WScript.Shell
    $desktops = @("C:\Users\$($script:User)\Desktop", "C:\Users\Public\Desktop")
    foreach ($desk in $desktops) {
        if (Test-Path $desk) {
            $sc = $wsh.CreateShortcut((Join-Path $desk "Fabric Drop.lnk"))
            $sc.TargetPath = $drop; $sc.Description = "No MOTW, Defender-excluded, full ACL"; $sc.Save()
            $sc2 = $wsh.CreateShortcut((Join-Path $desk "Crash Dumps.lnk"))
            $sc2.TargetPath = $crashDumps; $sc2.Save()
        }
    }
    foreach ($p in @($script:FabricRoot, $script:DataRoot, $drop, $tools, $crashDumps)) {
        icacls $p /grant "$($script:User):(OI)(CI)F" /T /C /Q | Out-Null
        icacls $p /grant "Everyone:(OI)(CI)F" /T /C /Q | Out-Null
    }

    # Memory governor helper (never kills user apps)
    $gov = @'
param([int]$PressureMb = 768)
$ErrorActionPreference = 'SilentlyContinue'
$os = Get-CimInstance Win32_OperatingSystem
$freeMb = [int]($os.FreePhysicalMemory / 1KB)
if ($freeMb -gt $PressureMb) { return $freeMb }
$code = @"
using System;
using System.Runtime.InteropServices;
public class FabricMem {
  [DllImport("psapi.dll")] public static extern int EmptyWorkingSet(IntPtr hProcess);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint a, bool i, int p);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@
try { Add-Type $code -ErrorAction SilentlyContinue } catch {}
$keep = @('csrss','wininit','winlogon','services','lsass','smss','System','Idle','svchost','explorer','dwm','rdpclip','rdpinput','termsrv','tailscale','tailscaled','msedge','powershell','pwsh','msiexec','winget','vcredist','wmiadap')
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.WorkingSet64 -gt 80MB -and ($keep -notcontains $_.ProcessName) } | ForEach-Object {
  try {
    $h = [FabricMem]::OpenProcess(0x1F0FFF, $false, $_.Id)
    if ($h -ne [IntPtr]::Zero) { [FabricMem]::EmptyWorkingSet($h) | Out-Null; [FabricMem]::CloseHandle($h) | Out-Null }
  } catch {}
}
[gc]::Collect(); [gc]::WaitForPendingFinalizers()
return [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
'@
    Set-Content -Path (Join-Path $script:FabricRoot "Governor.ps1") -Value $gov -Encoding UTF8
    Write-Log ("Workstation mode armed. Drop: {0}" -f $drop)
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 2.8 — SESSION UX (Edge auto-open, timer overlay, shortcuts) (full only)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-PhaseSession {
    Write-Step "Phase 2.8: Session UX — Edge auto-open + timer overlay"
    $taskUser = "$env:COMPUTERNAME\$($script:User)"

    # Edge single-instance bootstrap
    $edgeEnsure = Join-Path $script:FabricRoot 'EdgeEnsure.ps1'
    @"
`$ErrorActionPreference = 'SilentlyContinue'
`$url = '$StartupUrl'
`$mutex = New-Object System.Threading.Mutex(`$false, 'Local\RDPFabricEdge')
if (-not `$mutex.WaitOne(1000)) { exit }
try {
  `$edge = "`${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
  `$edge64 = "`${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
  if (-not (Test-Path -LiteralPath `$edge) -and (Test-Path -LiteralPath `$edge64)) { `$edge = `$edge64 }
  if (-not (Test-Path -LiteralPath `$edge)) { exit }
  `$running = Get-CimInstance Win32_Process -Filter "name='msedge.exe'" -ErrorAction SilentlyContinue |
      Where-Object { `$_.CommandLine -match 'fabric-x-xi' }
  if (-not `$running) {
    `$flags = '--no-first-run --no-default-browser-check --disable-sync --disable-background-networking --disable-features=Translate,MediaRouter --enable-gpu-rasterization --ignore-gpu-blocklist --disable-gpu-vsync --disable-pinch'
    Start-Process -FilePath `$edge -ArgumentList "--new-window `$url `$flags"
  }
} finally { `$mutex.ReleaseMutex() }
"@ | Set-Content -Path $edgeEnsure -Encoding UTF8

    $edgeVbs = Join-Path $script:FabricRoot 'EdgeApp.vbs'
    @"
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$edgeEnsure""", 0, False
"@ | Set-Content -Path $edgeVbs -Encoding ASCII

    # Run key + logon task (repeated every 5 min → relaunch if closed)
    $runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name "RDPFabric-EdgeApp" -Value "wscript.exe `"$edgeVbs`"" -Type String -Force

    $taskAction  = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$edgeVbs`""
    $taskTrig    = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
    $taskTrig.Delay = "PT10S"
    $taskTrig.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
    $taskPrinc   = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Limited
    $taskSet     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName "RDPFabric-Edge" -Action $taskAction -Trigger $taskTrig -Principal $taskPrinc -Settings $taskSet -Force | Out-Null

    $startupDir = "C:\Users\$($script:User)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
    if (Test-Path $startupDir) { Copy-Item -Path $edgeVbs -Destination (Join-Path $startupDir "EdgeApp.vbs") -Force -ErrorAction SilentlyContinue }

    # Edge policy: restore the Fabric site + bookmarks + home button
    $edgePol = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    New-Item -Path $edgePol -Force | Out-Null
    New-ItemProperty -Path $edgePol -Name "RestoreOnStartup" -PropertyType DWord -Value 4 -Force | Out-Null
    New-ItemProperty -Path $edgePol -Name "RestoreOnStartupURLs" -PropertyType String -Value (@($StartupUrl) | ConvertTo-Json -Compress) -Force | Out-Null
    New-ItemProperty -Path $edgePol -Name "HomepageLocation" -PropertyType String -Value $StartupUrl -Force | Out-Null
    New-ItemProperty -Path $edgePol -Name "HomepageIsNewTabPage" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $edgePol -Name "ShowHomeButton" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $edgePol -Name "ShowBookmarksBar" -PropertyType DWord -Value 1 -Force | Out-Null
    $bm = @(@{ toplevel_name = "RDP Fabric" }, @{ name = "Fabric App"; url = $StartupUrl }) | ConvertTo-Json -Depth 10 -Compress
    New-ItemProperty -Path $edgePol -Name "ManagedBookmarks" -PropertyType String -Value $bm -Force | Out-Null

    # Fabrict App.url shortcut
    $urlContent = "[InternetShortcut]`r`nURL=$StartupUrl`r`n"
    foreach ($desk in @("C:\Users\Public\Desktop", "C:\Users\$($script:User)\Desktop")) {
        if (Test-Path $desk) { Set-Content -Path (Join-Path $desk "Fabric App.url") -Value $urlContent -Encoding ASCII -Force }
    }

    # ── Timer overlay (HH:MM:SS + "Remaining: N min") ──
    $timerPath = Join-Path $script:FabricRoot 'FabricTimer.ps1'
    $timerLauncher = Join-Path $script:FabricRoot 'FabricTimer.vbs'
    $minutes = [int]$env:FAB_RUNTIME
    $timerSrc = @"
`$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
`$m = New-Object System.Threading.Mutex(`$false, 'Local\RDPFabricTimerOverlay')
if (-not `$m.WaitOne(0)) { exit }
`$deadlineFile = '$($script:FabricRoot)\deadline.txt'
(Get-Date).AddMinutes($minutes).ToString('o') | Set-Content `$deadlineFile -Encoding ASCII
try {
  `$deadline = [datetime]::Parse((Get-Content -Path `$deadlineFile -Raw).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
} catch { `$deadline = (Get-Date).AddMinutes($minutes) }
`$totalMin = $minutes
`$form = New-Object System.Windows.Forms.Form
`$form.Text = 'Fabric Timer'
`$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
`$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
`$form.Location = New-Object System.Drawing.Point(10, 10)
`$form.ClientSize = New-Object System.Drawing.Size(180, 44)
`$form.TopMost = `$true; `$form.ShowInTaskbar = `$false
`$form.BackColor = [System.Drawing.Color]::FromArgb(15, 15, 18); `$form.Opacity = 0.88
`$lbl = New-Object System.Windows.Forms.Label
`$lbl.Dock = [System.Windows.Forms.DockStyle]::Fill
`$lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
`$lbl.Font = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
`$lbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 230, 140)
`$lbl.Text = 'Remaining: $minutes min'
`$form.Controls.Add(`$lbl)
`$dragging = `$false; `$origin = New-Object System.Drawing.Point(0,0)
`$down = { param(`$s,`$e) if (`$e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { `$script:dragging = `$true; `$script:origin = `$e.Location } }
`$move = { param(`$s,`$e) if (`$script:dragging) { `$form.Location = New-Object System.Drawing.Point((`$form.Location.X + `$e.X - `$script:origin.X), (`$form.Location.Y + `$e.Y - `$script:origin.Y)) } }
`$up   = { `$script:dragging = `$false }
`$lbl.Add_MouseDown(`$down); `$lbl.Add_MouseMove(`$move); `$lbl.Add_MouseUp(`$up)
`$form.Add_MouseDown(`$down); `$form.Add_MouseMove(`$move); `$form.Add_MouseUp(`$up)
`$lbl.Add_DoubleClick({ `$form.Location = New-Object System.Drawing.Point(10, 10) })
`$t = New-Object System.Windows.Forms.Timer; `$t.Interval = 1000
`$t.Add_Tick({
  `$remain = `$deadline - (Get-Date); `$total = [math]::Floor(`$remain.TotalSeconds)
  if (`$total -le 0) { `$lbl.Text = 'Expired'; `$lbl.ForeColor = [System.Drawing.Color]::FromArgb(255,80,80); return }
  `$h = [math]::Floor(`$total / 3600); `$mm = [math]::Floor((`$total % 3600) / 60); `$s = `$total % 60
  `$lbl.Text = ('{0:00}:{1:00}:{2:00}  ({3} min left)' -f `$h, `$mm, `$s, `$totalMin)
  if (`$total -le 300) { `$lbl.ForeColor = [System.Drawing.Color]::FromArgb(255,80,80) }
  elseif (`$total -le 900) { `$lbl.ForeColor = [System.Drawing.Color]::FromArgb(255,176,32) }
  else { `$lbl.ForeColor = [System.Drawing.Color]::FromArgb(0,230,140) }
  if (-not `$form.TopMost) { `$form.TopMost = `$true }
})
`$t.Start()
`$keep = New-Object System.Windows.Forms.Timer; `$keep.Interval = 30000
`$keep.Add_Tick({ `$form.TopMost = `$false; `$form.TopMost = `$true }); `$keep.Start()
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run(`$form)
"@
    Set-Content -Path $timerPath -Value $timerSrc -Encoding UTF8
    @"
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$timerPath""", 0, False
"@ | Set-Content -Path $timerLauncher -Value $vbs -Encoding ASCII

    $tAct  = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$timerLauncher`""
    $tTrig = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
    $tTrig.Delay = "PT5S"
    $tSet  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName "RDPFabric-Timer" -Action $tAct -Trigger $tTrig -Principal $taskPrinc -Settings $tSet -Force | Out-Null
    if (Test-Path $startupDir) { Copy-Item -Path $timerLauncher -Destination (Join-Path $startupDir "FabricTimer.vbs") -Force -ErrorAction SilentlyContinue }

    Write-Log "Session UX armed (Edge auto-open + timer overlay)."
}

# ─────────────────────────────────────────────────────────────────────────────
#  MOTW SWEEP — strip Zone.Identifier from drop/desktop/downloads
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-MotwSweep {
    $paths = @((Join-Path $script:DataRoot 'Drop'), "C:\Users\$($script:User)\Desktop", "C:\Users\$($script:User)\Downloads")
    foreach ($p in $paths) {
        Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath ($_.FullName + ':Zone.Identifier') -Force -ErrorAction SilentlyContinue }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 4 — SESSION HOLD / WATCHDOG / GOVERNOR / CYCLE HANDOFF
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-PhaseHold {
    Write-Step "Phase 4: Session hold, watchdog, governor, cycle handoff"
    $minutes = [int]$env:FAB_RUNTIME
    if ($minutes -le 0) { $minutes = 5 }
    $tsPath   = "C:\Program Files\Tailscale\tailscale.exe"
    $govPath  = Join-Path $script:FabricRoot "Governor.ps1"
    $cycles   = [int]$env:FAB_CYCLES
    if ($cycles -lt 0) { $cycles = 0 }

    Write-Log "Holding for $minutes min. Watchdog tick = 30s."
    $start = Get-Date; $tick = 0
    while ($script:Deadline -and (Get-Date) -lt $script:Deadline) {
        Start-Sleep -Seconds 30
        $tick++
        $remaining = [math]::Max(0, [math]::Round(($script:Deadline - (Get-Date)).TotalMinutes, 1))

        # Tailscale re-up
        $tsOk = $false
        if (Test-Path -LiteralPath $tsPath) {
            $backend = $null
            try { $backend = (& $tsPath status --json 2>$null | ConvertFrom-Json).BackendState } catch {}
            $tsOk = ($backend -eq 'Running')
            if (-not $tsOk) {
                Write-Log "Tailscale '$backend' — re-upping."
                & $tsPath up --authkey="$env:TS_AUTHKEY" --hostname="$script:TsHostname" --accept-routes=false --accept-dns=false --unattended 2>$null | Out-Null
            }
        }
        # RDP re-arm
        $rdpOk = [bool](Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)
        if (-not $rdpOk) {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -Type DWord -Force
            Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
            New-NetFirewallRule -DisplayName "RDP-UDP-In" -Direction Inbound -Protocol UDP -LocalPort 3389 -Action Allow -ErrorAction SilentlyContinue | Out-Null
            Write-Log "RDP listener re-armed."
        }

        $freeMb = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
        if ($script:IsFull) {
            Invoke-MotwSweep
            if ($freeMb -lt 768 -and (Test-Path -LiteralPath $govPath)) {
                try { $freeMb = [int](& $govPath -PressureMb 768) } catch {}
                Write-Log "Governor trim → ${freeMb} MB free."
            }
            if (($tick % 10) -eq 0) {
                try { Set-MpPreference -DisableRealtimeMonitoring $true -Force -ErrorAction SilentlyContinue } catch {}
                foreach ($svc in @('WSearch','SysMain','DoSvc','wuauserv','bits','WerSvc')) { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
            }
        }
        if (($tick % 2) -eq 0) {
            $tsMark = if ($tsOk) {'ok'} else {'recovering'}
            $rdpMark = if ($rdpOk) {'ok'} else {'recovering'}
            Write-Log "Heartbeat: $($script:TsHostname) TS:$tsMark RDP:$rdpMark free=${freeMb}MB left=${remaining}min"
        }
    }

    if ($cycles -gt 0) {
        Invoke-CycleHandoff ($cycles - 1)
    } else {
        Write-Log "No cycles remaining — graceful shutdown."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  CYCLE HANDOFF — self-dispatch via gh (GH_PAT → GITHUB_TOKEN fallback)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-CycleHandoff {
    param([int]$Next)
    Write-Log "Cycle handoff (remaining: $Next)..."
    $repo = $env:GH_REPOSITORY
    $wf   = $env:GH_WORKFLOW
    $ref  = $env:GH_REF
    $token = if ($env:GH_PAT) { $env:GH_PAT } else { $env:GITHUB_TOKEN }
    if (-not $token) { throw "Handoff failed: no token (set GH_PAT secret)." }

    $inputs = [ordered]@{
        runner_image      = $env:FAB_RUNNER_IMAGE
        instance_count    = $env:FAB_INSTANCE_COUNT
        runtime_minutes   = $env:FAB_RUNTIME
        workload_profile  = $env:FAB_PROFILE_INPUT
        quick_test        = $env:FAB_QUICKTEST
        enable_ramdisk    = $env:FAB_RAMDISK
        rdp_compression   = $env:FAB_RDPCOMP
        reclaim_disk      = $env:FAB_RECLAIM
        disable_mitigations = $env:FAB_MITIGATIONS
        cycles            = "$Next"
    }
    $dispatched = $false
    for ($attempt = 1; $attempt -le 3 -and -not $dispatched; $attempt++) {
        try {
            if (Get-Command gh -ErrorAction SilentlyContinue) {
                $args = @()
                foreach ($k in $inputs.Keys) { $args += '-f'; $args += "$k=$($inputs[$k])" }
                & gh workflow run $wf --repo $repo --ref $ref @args 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $dispatched = $true; break }
            }
            $uri  = "https://api.github.com/repos/$repo/actions/workflows/$wf/dispatches"
            $headers = @{ Authorization = "Bearer $token"; Accept = "application/vnd.github+json" }
            $body = @{ ref = $ref; inputs = $inputs } | ConvertTo-Json
            Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
            $dispatched = $true
        } catch {
            Write-Log "Handoff attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 15
        }
    }
    if (-not $dispatched) { throw "Handoff failed after 3 attempts." }
    Write-Log "Handoff dispatched."
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────
function Main {
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  RDP FABRIC PRO v8.0 'Menlít' — mode: $Mode  ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan

    Invoke-PhaseInventory

    if ($script:IsFull) {
        try { Invoke-PhaseServices }   catch { Write-Log "Phase 1a FAILED (non-fatal): $($_.Exception.Message)" }
        try { Invoke-PhaseMemory }     catch { Write-Log "Phase 1b FAILED (non-fatal): $($_.Exception.Message)" }
        try { Invoke-PhaseDisk }       catch { Write-Log "Phase 1d FAILED (non-fatal): $($_.Exception.Message)" }
    }
    try { Invoke-PhaseRdp } catch { Write-Log "Phase 1c CRITICAL: $($_.Exception.Message)"; throw }
    try { Invoke-PhaseTailscale } catch { Write-Log "Phase 2 CRITICAL: $($_.Exception.Message)"; throw }

    if ($script:IsFull) {
        try { Invoke-PhaseRuntime }     catch { Write-Log "Phase 2.5 FAILED (non-fatal): $($_.Exception.Message)" }
        try { Invoke-PhaseWorkstation } catch { Write-Log "Phase 2.7 FAILED (non-fatal): $($_.Exception.Message)" }
        try { Invoke-PhaseSession }     catch { Write-Log "Phase 2.8 FAILED (non-fatal): $($_.Exception.Message)" }
    }

    Invoke-PhaseHold
}

Main
