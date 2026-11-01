# ============================================================================
#  Refurb audit script - runs in Windows Audit Mode after the unattended install
#  1. Gets online (Wi-Fi from config.ps1 or Ethernet)
#  2. Installs Dell Command | Update and applies drivers + BIOS (reboots/resumes)
#  3. Records specs, drive serial/wear, battery health, activation, problem devices
#  4. Walks you through hands-on QA (screen, keyboard, speakers, ports...)
#  5. Saves everything to the USB (refurb\reports\inventory.csv + a folder per unit)
#  6. Optionally reseals: removes Wi-Fi + script files, sysprep /oobe /shutdown
#  Written for Windows PowerShell 5.1 (built into Windows 11).
# ============================================================================

$ErrorActionPreference = 'Continue'

# --- only one copy at a time (auditUser pass and RunOnce can both start it) ---
$mutex = New-Object System.Threading.Mutex($false, 'Global\RefurbAudit')
$haveLock = $false
try { $haveLock = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
if (-not $haveLock) {
    Write-Host 'The refurb script is already running in another window. You can close this one.' -ForegroundColor Yellow
    return
}

$RefurbDir  = $PSScriptRoot
$ReportsDir = Join-Path $RefurbDir 'reports'
$StateDir   = 'C:\Refurb'
$StageFile  = Join-Path $StateDir 'stage.txt'
$UnitFile   = Join-Path $StateDir 'unit.txt'
$DcuLogDir  = Join-Path $StateDir 'dcu'
New-Item -ItemType Directory -Force -Path $StateDir, $ReportsDir, $DcuLogDir | Out-Null

$configFile = Join-Path $RefurbDir 'config.ps1'
if (-not (Test-Path $configFile)) {
    Write-Host 'config.ps1 not found - using config.example.ps1 (no Wi-Fi set).' -ForegroundColor Yellow
    $configFile = Join-Path $RefurbDir 'config.example.ps1'
}
. $configFile
Start-Transcript -Path (Join-Path $StateDir 'transcript.txt') -Append | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ---------------------------------------------------------------- helpers ---
function Say([string]$Message, [string]$Color = 'Cyan') {
    Write-Host ''
    Write-Host "== $Message" -ForegroundColor $Color
}

function Get-Stage {
    if (Test-Path $StageFile) { return (Get-Content $StageFile -Raw).Trim() }
    return 'start'
}
function Set-Stage([string]$Stage) { Set-Content -Path $StageFile -Value $Stage }

function Set-RegDword([string]$Path, [string]$Name, [int]$Value) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Set-AuditGuards {
    # Store app auto-updates during audit mode are a common cause of sysprep failures,
    # and automatic device encryption must not start before the buyer's setup.
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2
    Set-RegDword 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 1
}
function Remove-AuditGuards {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'AutoDownload' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' -Name 'PreventDeviceEncryption' -ErrorAction SilentlyContinue
}

function Set-ResumeAfterReboot {
    $launch = Join-Path $StateDir 'launch.cmd'
    $cmd = @'
@echo off
for %%i in (D E F G H I J K L M N O P) do if exist %%i:\refurb\audit.ps1 start "Refurb" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File %%i:\refurb\audit.ps1
'@
    Set-Content -Path $launch -Value $cmd -Encoding ASCII
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'RefurbAudit' `
        -Value "cmd.exe /c `"$launch`"" -PropertyType String -Force | Out-Null
}

function Test-Internet {
    try {
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10
        return ($r.Content -match 'Microsoft Connect Test')
    } catch { return $false }
}

function Connect-Network {
    if (Test-Internet) { Say 'Internet connection OK.' 'Green'; return $true }

    if ([string]::IsNullOrWhiteSpace($WifiSsid)) {
        Say 'No internet, and no Wi-Fi set in config.ps1. Plug in a USB Ethernet adapter (waiting 2 minutes)...' 'Yellow'
    } else {
        Say "Joining Wi-Fi '$WifiSsid'..."
        $ssid = [System.Security.SecurityElement]::Escape($WifiSsid)
        $pass = [System.Security.SecurityElement]::Escape($WifiPassword)
        $profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$ssid</name>
  <SSIDConfig><SSID><name>$ssid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
    <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$pass</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>
"@
        $file = Join-Path $StateDir 'wifi.xml'
        Set-Content -Path $file -Value $profileXml -Encoding UTF8
        cmd.exe /c "netsh wlan add profile filename=`"$file`" user=all" | Out-Null
        Remove-Item $file -Force -ErrorAction SilentlyContinue   # don't leave the password in a file
        cmd.exe /c "netsh wlan connect name=`"$WifiSsid`"" | Out-Null
    }

    for ($i = 1; $i -le 24; $i++) {
        Start-Sleep -Seconds 5
        if (Test-Internet) { Say 'Internet connection OK.' 'Green'; return $true }
        if (($i % 6 -eq 0) -and $WifiSsid) { cmd.exe /c "netsh wlan connect name=`"$WifiSsid`"" | Out-Null }
    }
    Say 'Could not get online. Driver/BIOS updates and activation will be skipped (re-run the script later to retry).' 'Red'
    return $false
}

function Wait-ForAC {
    while ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -ne 'Online') {
        Say 'Plug in the charger - BIOS updates need AC power.' 'Yellow'
        Start-Sleep -Seconds 5
    }
}

function Get-DcuCli {
    foreach ($p in @("$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe",
                     "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Install-Dcu {
    $cli = Get-DcuCli
    if ($cli) { return $cli }
    $installer = Get-ChildItem -Path (Join-Path $RefurbDir 'installers') -Filter '*Command*Update*.exe' -ErrorAction SilentlyContinue |
                 Select-Object -First 1
    if (-not $installer) {
        Say 'Dell Command | Update installer not found in refurb\installers - skipping driver/BIOS updates.' 'Yellow'
        return $null
    }
    # Current Dell Command | Update versions need the .NET Desktop Runtime, which a fresh Windows install lacks.
    $dotnet = Get-ChildItem -Path (Join-Path $RefurbDir 'installers') -Filter 'windowsdesktop-runtime*x64*.exe' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if ($dotnet) {
        Say "Installing $($dotnet.Name) (needed by Dell Command | Update)..."
        Start-Process -FilePath $dotnet.FullName -ArgumentList '/install', '/quiet', '/norestart' -Wait
    } else {
        Say 'No .NET Desktop Runtime installer in refurb\installers - Dell Command | Update may fail to install.' 'Yellow'
    }
    Say "Installing $($installer.Name) silently..."
    Start-Process -FilePath $installer.FullName -ArgumentList '/s' -Wait
    Start-Sleep -Seconds 5
    return (Get-DcuCli)
}

function Invoke-DcuRound($Cli, [int]$Round) {
    $log = Join-Path $DcuLogDir "round$Round.log"
    Say "Dell Command | Update, round $Round (drivers + BIOS). Don't unplug the charger."
    & $Cli /applyUpdates -reboot=disable -autoSuspendBitLocker=enable "-outputLog=$log"
    $code = $LASTEXITCODE
    Add-Content -Path (Join-Path $StateDir 'dcu-codes.txt') -Value "round $Round exit code $code"
    Write-Host "dcu-cli exit code: $code"
    return $code
}

function Get-BatteryInfo([string]$HtmlOut) {
    $xmlPath = Join-Path $StateDir 'battery.xml'
    powercfg.exe /batteryreport /output "$HtmlOut" | Out-Null
    powercfg.exe /batteryreport /xml /output "$xmlPath" | Out-Null
    if (-not (Test-Path $xmlPath)) { return $null }
    [xml]$x = Get-Content $xmlPath -Raw
    $b = @($x.BatteryReport.Batteries.Battery)[0]
    if (-not $b) { return $null }
    $design = [double]$b.DesignCapacity
    $full   = [double]$b.FullChargeCapacity
    $pct = $null
    if ($design -gt 0) { $pct = [math]::Round($full / $design * 100) }
    return [ordered]@{ DesignmWh = $design; FullChargemWh = $full; HealthPct = $pct; Cycles = "$($b.CycleCount)" }
}

function Get-SystemInfo {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $os   = Get-CimInstance Win32_OperatingSystem
    $cpu  = "$((Get-CimInstance Win32_Processor | Select-Object -First 1).Name)".Trim()

    $mem      = @(Get-CimInstance Win32_PhysicalMemory)
    $memTotal = [math]::Round(($mem | Measure-Object -Property Capacity -Sum).Sum / 1GB)
    $memInfo  = ($mem | ForEach-Object {
        '{0}: {1}GB {2}MHz {3}' -f $_.DeviceLocator, [math]::Round($_.Capacity / 1GB), $_.ConfiguredClockSpeed, "$($_.PartNumber)".Trim()
    }) -join ' | '

    $disk = Get-PhysicalDisk | Where-Object { $_.BusType -ne 'USB' } | Select-Object -First 1
    $rel  = $null
    if ($disk) { $rel = $disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue }

    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
           Select-Object -First 1
    $oa3 = (Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKeyDescription

    $bad  = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -in 'Error', 'Degraded' })
    $cam  = @(Get-PnpDevice -PresentOnly -Class Camera, Image -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' })
    $bt   = @(Get-PnpDevice -PresentOnly -Class Bluetooth -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' })
    $wifi = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11' } | Select-Object -First 1

    $wifiText = 'NOT FOUND'
    if ($wifi) { $wifiText = "$($wifi.InterfaceDescription) ($($wifi.Status))" }

    return [ordered]@{
        ServiceTag      = "$($bios.SerialNumber)".Trim()
        Model           = "$($cs.Manufacturer) $($cs.Model)".Trim()
        BIOSVersion     = $bios.SMBIOSBIOSVersion
        CPU             = $cpu
        RAM_GB          = $memTotal
        RAM_Sticks      = $mem.Count
        RAM_Detail      = $memInfo
        Disk_Model      = $(if ($disk) { $disk.FriendlyName } else { 'NOT FOUND' })
        Disk_Serial     = $(if ($disk) { "$($disk.SerialNumber)".Trim() } else { '' })
        Disk_GB         = $(if ($disk) { [math]::Round($disk.Size / 1GB) } else { '' })
        Disk_Health     = $(if ($disk) { "$($disk.HealthStatus)" } else { '' })
        Disk_WearPct    = $(if ($rel) { "$($rel.Wear)" } else { '' })
        Disk_PowerOnHrs = $(if ($rel) { "$($rel.PowerOnHours)" } else { '' })
        Windows         = "$($os.Caption) build $($os.BuildNumber)"
        Activated       = $(if ($lic -and $lic.LicenseStatus -eq 1) { 'Yes' } else { 'No' })
        BIOSKeyEdition  = "$oa3"
        WiFiAdapter     = $wifiText
        Bluetooth       = $(if ($bt.Count -gt 0) { 'Yes' } else { 'NOT FOUND' })
        Camera          = $(if ($cam.Count -gt 0) { 'Yes' } else { 'NOT FOUND' })
        ProblemDevices  = (($bad | ForEach-Object { $_.FriendlyName }) -join '; ')
    }
}

function Remove-Bloat {
    if (-not $RemoveApps -or $RemoveApps.Count -eq 0) { return }
    $flag = Join-Path $StateDir 'debloat-done.txt'
    if (Test-Path $flag) { return }
    Say 'Removing preinstalled extra apps (for this account and every future user)...'
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($name in $RemoveApps) {
        # Installed copies first (a copy installed for a user but not provisioned breaks sysprep),
        # then the provisioned copy that would be installed for the buyer's new account.
        Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop } catch { }
        }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $name } | ForEach-Object {
            try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null; $removed.Add($name) } catch { }
        }
    }
    Set-Content -Path $flag -Value ($removed -join ', ')
    if ($removed.Count) { Write-Host "Removed: $($removed -join ', ')" } else { Write-Host 'None of the listed apps were present.' }
}

# --------------------------------------------------------- hands-on tests ---
function Show-ScreenTest {
    $script:colorIdx = 0
    $colors = @('Red', 'Lime', 'Blue', 'White', 'Black', 'Gray')
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.WindowState = 'Maximized'
    $form.TopMost = $true
    $form.KeyPreview = $true
    $form.BackColor = [System.Drawing.Color]::FromName($colors[0])
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Look for dead pixels, lines and backlight bleed. Click or press Space for the next color. Esc to finish.'
    $label.AutoSize = $true
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 14)
    $label.ForeColor = [System.Drawing.Color]::White
    $label.BackColor = [System.Drawing.Color]::Black
    $label.Location = New-Object System.Drawing.Point(20, 20)
    $form.Controls.Add($label)
    $next = {
        $script:colorIdx++
        if ($script:colorIdx -ge $colors.Count) { $form.Close(); return }
        $form.BackColor = [System.Drawing.Color]::FromName($colors[$script:colorIdx])
        $label.Visible = $false
    }
    $form.Add_Click($next)
    $label.Add_Click($next)
    $form.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $form.Close() } else { & $next } })
    [void]$form.ShowDialog()
}

function Show-KeyboardTest {
    $script:keysSeen = New-Object 'System.Collections.Generic.SortedSet[string]'
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Keyboard test - press every key, then close this window with the X'
    $form.Size = New-Object System.Drawing.Size(1000, 520)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.KeyPreview = $true
    $label = New-Object System.Windows.Forms.Label
    $label.Dock = 'Fill'
    $label.Font = New-Object System.Drawing.Font('Consolas', 13)
    $label.Text = 'Press every key on the keyboard (Fn itself is invisible to Windows - test Fn combos instead)...'
    $form.Controls.Add($label)
    $record = {
        param($s, $e)
        [void]$script:keysSeen.Add($e.KeyCode.ToString())
        $label.Text = "Keys registered: $($script:keysSeen.Count)`r`n`r`n" + ($script:keysSeen -join '  ')
        $e.Handled = $true
        $e.SuppressKeyPress = $true
    }
    $form.Add_PreviewKeyDown({ param($s, $e) $e.IsInputKey = $true })
    $form.Add_KeyDown($record)
    $form.Add_KeyUp($record)   # Print Screen only fires on key-up
    [void]$form.ShowDialog()
    return $script:keysSeen.Count
}

function Play-Tone([ValidateSet('left', 'right')][string]$Side) {
    $rate = 44100; $freq = 660; $n = [int]($rate * 1.2); $dataLen = $n * 4
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $ascii = [System.Text.Encoding]::ASCII
    $bw.Write($ascii.GetBytes('RIFF')); $bw.Write([int](36 + $dataLen)); $bw.Write($ascii.GetBytes('WAVE'))
    $bw.Write($ascii.GetBytes('fmt ')); $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]2)
    $bw.Write([int]$rate); $bw.Write([int]($rate * 4)); $bw.Write([int16]4); $bw.Write([int16]16)
    $bw.Write($ascii.GetBytes('data')); $bw.Write([int]$dataLen)
    $zero = [int16]0
    for ($i = 0; $i -lt $n; $i++) {
        $v = [int16](12000 * [math]::Sin(2 * [math]::PI * $freq * $i / $rate))
        if ($Side -eq 'left') { $bw.Write($v); $bw.Write($zero) } else { $bw.Write($zero); $bw.Write($v) }
    }
    $bw.Flush(); $ms.Position = 0
    $player = New-Object System.Media.SoundPlayer($ms)
    $player.PlaySync()
}

function Ask([string]$Question, [string[]]$Allowed = @('y', 'n', 'na')) {
    while ($true) {
        $a = "$(Read-Host "$Question [$($Allowed -join '/')]")".Trim().ToLower()
        if ($Allowed -contains $a) { return $a }
    }
}

# ---------------------------------------------------------------- reseal ---
function Invoke-Reseal {
    Say 'Cleaning up for the buyer...'
    if ($WifiSsid) { cmd.exe /c "netsh wlan delete profile name=`"$WifiSsid`"" | Out-Null }
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'RefurbAudit' -ErrorAction SilentlyContinue
    Remove-AuditGuards

    try {
        $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        if ($bl.VolumeStatus -ne 'FullyDecrypted') {
            Say 'Turning off BitLocker (sysprep requires it)...' 'Yellow'
            Disable-BitLocker -MountPoint 'C:' | Out-Null
            $deadline = (Get-Date).AddMinutes(60)
            while ((Get-BitLockerVolume -MountPoint 'C:').VolumeStatus -ne 'FullyDecrypted') {
                if ((Get-Date) -gt $deadline) { Say 'BitLocker is still on after 60 minutes - sysprep may fail.' 'Red'; break }
                Start-Sleep -Seconds 10
            }
        }
    } catch { }

    # Cached copies of the answer file would send the buyer into audit mode again.
    foreach ($f in @("$env:windir\Panther\unattend.xml", "$env:windir\Panther\autounattend.xml",
                     "$env:windir\Panther\Unattend\unattend.xml", "$env:windir\System32\Sysprep\unattend.xml")) {
        Remove-Item -Path $f -Force -ErrorAction SilentlyContinue
    }

    Stop-Transcript | Out-Null
    Remove-Item -Path $StateDir -Recurse -Force -ErrorAction SilentlyContinue

    Say 'Unplug the USB stick now (the reports are saved on it). Waiting...' 'Yellow'
    while (Test-Path (Join-Path $RefurbDir 'audit.ps1')) { Start-Sleep -Seconds 2 }

    Get-Process -Name sysprep -ErrorAction SilentlyContinue | Stop-Process -Force
    Say 'Resealing with sysprep /oobe - the laptop shuts down when finished.' 'Green'
    & "$env:windir\System32\Sysprep\sysprep.exe" /oobe /shutdown /quiet
    Start-Sleep -Seconds 90
    Say 'Still running? Sysprep may have failed - see C:\Windows\System32\Sysprep\Panther\setuperr.log' 'Red'
}

# ================================================================== main ===
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host '  REFURB AUDIT - drivers, specs, QA, reseal' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan

if (-not (Test-Path $UnitFile)) {
    $id = ''
    while ([string]::IsNullOrWhiteSpace($id)) { $id = Read-Host 'Unit ID on this laptop''s label (e.g. L01)' }
    $safe = ($id.Trim().ToUpper() -replace '[^A-Z0-9_-]', '')
    if (-not $safe) { $safe = 'UNIT' }
    Set-Content -Path $UnitFile -Value $safe
}
$UnitId = (Get-Content $UnitFile -Raw).Trim()
Write-Host "Unit: $UnitId"
Set-AuditGuards

$stage  = Get-Stage
$online = Connect-Network

# ---- stage 1: drivers + BIOS via Dell Command | Update ----
if ($stage -eq 'start' -or $stage -like 'dcu*') {
    $cli = $null
    if ($online) { $cli = Install-Dcu }
    if ($cli) {
        $round = 1
        if ($stage -like 'dcu*') { $round = [int]$stage.Substring(3) }
        while ($round -le $DcuRounds) {
            Wait-ForAC
            $code = Invoke-DcuRound $cli $round
            $round++
            # 1 and 5 = a restart is needed (check 'dcu-cli /help' if your version differs)
            if ($code -eq 1 -or $code -eq 5) {
                if ($round -le $DcuRounds) { Set-Stage "dcu$round" } else { Set-Stage 'report' }
                Set-ResumeAfterReboot
                Say 'Restarting to finish updates. The script resumes by itself after login.' 'Yellow'
                Stop-Transcript | Out-Null
                Start-Sleep -Seconds 5
                Restart-Computer -Force
                return
            }
            if ($code -eq 500) { break }   # no updates available
        }
    }
    Set-Stage 'report'
}

# ---- stage 2: specs + QA ----
Remove-Bloat
if ($online) {
    Say 'Activating Windows with the license stored in the BIOS...'
    $biosKey = (Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKey
    if ($biosKey) { cscript.exe //nologo "$env:windir\System32\slmgr.vbs" /ipk $biosKey | Out-Null }
    cscript.exe //nologo "$env:windir\System32\slmgr.vbs" /ato | Out-Null
}

Say 'Collecting specs...'
$info    = Get-SystemInfo
$unitDir = Join-Path $ReportsDir ('{0}_{1}' -f $UnitId, $info.ServiceTag)
New-Item -ItemType Directory -Force -Path $unitDir | Out-Null
$bat = Get-BatteryInfo (Join-Path $unitDir 'battery-report.html')

$flags = New-Object System.Collections.Generic.List[string]
if (-not $bat) { $flags.Add('No battery data') }
elseif ($null -ne $bat.HealthPct -and $bat.HealthPct -lt $BatteryWarnPercent) { $flags.Add("Battery $($bat.HealthPct)% - disclose in listing") }
if ($info.Activated -ne 'Yes')               { $flags.Add('Windows NOT activated') }
if ($info.BIOSKeyEdition -and $info.BIOSKeyEdition -notmatch 'Professional') {
    $flags.Add("BIOS license is '$($info.BIOSKeyEdition)', not Pro - reinstall the matching edition")
}
if ($info.ProblemDevices)                    { $flags.Add("Problem devices: $($info.ProblemDevices)") }
if ($info.WiFiAdapter -eq 'NOT FOUND')       { $flags.Add('Wi-Fi adapter missing') }
if ($info.Bluetooth -ne 'Yes')               { $flags.Add('Bluetooth not found') }
if ($info.Camera -ne 'Yes')                  { $flags.Add('Webcam not found') }
if ($info.Disk_Health -and $info.Disk_Health -ne 'Healthy') { $flags.Add("Drive health: $($info.Disk_Health)") }
if ($info.RAM_Sticks -lt 2)                  { $flags.Add('Single-channel memory (1 stick)') }

Say "Specs for $UnitId" 'Green'
$info.GetEnumerator() | ForEach-Object { Write-Host ('{0,-16} {1}' -f $_.Key, $_.Value) }
if ($bat) { Write-Host ('{0,-16} {1}% ({2} cycles)' -f 'Battery', $bat.HealthPct, $bat.Cycles) }
if ($flags.Count -gt 0) { Say 'Flags:' 'Yellow'; $flags | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow } }
else { Say 'No automatic flags.' 'Green' }

Say 'Hands-on checks. Answer y (pass), n (fail) or na (not applicable).'
$qa = [ordered]@{}
$qa.Wiped = Ask 'BIOS Data Wipe completed and success screen photographed?'
Say 'Screen test opening...'
Show-ScreenTest
$qa.Screen = Ask 'Screen OK (no dead pixels, lines or bad backlight bleed)?'
Say 'Keyboard test opening...'
$keyCount = Show-KeyboardTest
$qa.Keyboard = Ask "Every key registered? ($keyCount keys seen; also try Fn + brightness/volume)"
Say 'Speaker test: LEFT, then RIGHT...'
Play-Tone left; Start-Sleep -Milliseconds 300; Play-Tone right
$qa.Speakers   = Ask 'Heard LEFT then RIGHT clearly, with no rattle?'
$qa.Trackpad   = Ask 'Trackpad moves, clicks (both buttons) and scrolls?'
$qa.USBPorts   = Ask 'Every USB-A port reads a flash drive?'
$qa.USBC       = Ask 'USB-C port works (data and/or charging)?'
$qa.HDMI       = Ask 'HDMI shows a picture on a monitor?'
$qa.Headphone  = Ask 'Headphone jack plays audio?'
$qa.Mic        = Ask 'Microphone picks up sound (Settings > System > Sound > Input)?'
$qa.Webcam     = Ask 'Webcam shows a picture?'
$qa.Charging   = Ask 'Charges from the charger it will ship with?'
$qa.Hinges     = Ask 'Hinges hold the screen at any angle?'
$grade = Ask 'Cosmetic grade' @('a', 'b', 'c', 'parts')
$notes = Read-Host 'Notes for the listing (optional)'

$failed = @($qa.GetEnumerator() | Where-Object { $_.Value -eq 'n' } | ForEach-Object { $_.Key })
$hard   = @($flags | Where-Object { $_ -match 'NOT activated|Problem devices|Wi-Fi adapter missing|Drive health|not Pro' })
$result = 'PASS'
if ($failed.Count -gt 0 -or $hard.Count -gt 0) { $result = 'CHECK' }

$row = [ordered]@{ Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); UnitID = $UnitId }
foreach ($k in $info.Keys) { $row[$k] = $info[$k] }
$row['Battery_HealthPct'] = $(if ($bat) { $bat.HealthPct } else { '' })
$row['Battery_Cycles']    = $(if ($bat) { $bat.Cycles } else { '' })
$dcuCodesFile = Join-Path $StateDir 'dcu-codes.txt'
$row['DCU_Result'] = $(if (Test-Path $dcuCodesFile) { ((Get-Content $dcuCodesFile) -join '; ') } else { 'not run' })
foreach ($k in $qa.Keys) { $row["QA_$k"] = $qa[$k] }
$debloatFile = Join-Path $StateDir 'debloat-done.txt'
$row['AppsRemoved'] = $(if (Test-Path $debloatFile) { (Get-Content $debloatFile -Raw).Trim() } else { '' })
$row['Grade']  = $grade.ToUpper()
$row['Flags']  = ($flags -join '; ')
$row['Notes']  = $notes
$row['Result'] = $result

[pscustomobject]$row | Export-Csv -Path (Join-Path $ReportsDir 'inventory.csv') -Append -NoTypeInformation -Encoding UTF8 -Force
[pscustomobject]$row | Format-List | Out-File -FilePath (Join-Path $unitDir 'summary.txt') -Encoding UTF8
Copy-Item -Path (Join-Path $DcuLogDir '*') -Destination $unitDir -ErrorAction SilentlyContinue
Copy-Item -Path (Join-Path $StateDir 'transcript.txt') -Destination $unitDir -ErrorAction SilentlyContinue

if ($result -eq 'PASS') { Say "RESULT: PASS - saved to $unitDir" 'Green' }
else {
    Say "RESULT: CHECK - saved to $unitDir" 'Yellow'
    if ($failed.Count) { Write-Host "  Failed checks: $($failed -join ', ')" -ForegroundColor Yellow }
    if ($hard.Count)   { $hard | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow } }
    Write-Host '  Fix these, then run refurb\audit.ps1 again from the USB before resealing.' -ForegroundColor Yellow
}

$go = Ask 'Reseal for the buyer now? (removes your Wi-Fi + script files, then shuts down)' @('y', 'n')
if ($go -eq 'y') { Invoke-Reseal }
else { Say 'Not resealed. Re-run D:\refurb\audit.ps1 (right-click > Run with PowerShell) when ready.' }
