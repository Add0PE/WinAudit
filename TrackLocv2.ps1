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

# --- DETEKSI AKTIVITAS USER (FINAL-CORE: PROCESS-BASED VPN LIFECYCLE DETECTOR) ---
$CurrentActivity = "• No Active GUI Window"

try {
    $ValidApps = New-Object System.Collections.ArrayList

    # 1. Cari tahu siapa nama user yang sedang aktif di layar
    $ActiveUser = $null
    $Explorers = Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction SilentlyContinue
    if ($Explorers) {
        foreach ($Exp in $Explorers) {
            $OwnerInfo = Invoke-CimMethod -InputObject $Exp -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($OwnerInfo -and $OwnerInfo.User -notmatch "^(SYSTEM|LOCAL SERVICE|NETWORK SERVICE|DWM-.*|UMFD-.*)$") {
                $ActiveUser = $OwnerInfo.User
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ActiveUser)) {
        $QuserResult = quser 2>$null
        if ($QuserResult) {
            foreach ($Line in $QuserResult) {
                if ($Line -match '>\s*([a-zA-Z0-9\.\-_]+)\s+') {
                    $ActiveUser = $Matches[1]
                    break
                }
            }
        }
    }

    # 2. EKSEKUSI JALUR TASKLIST DENGAN ADVANCED PROCESS DETECTION
    if (-not [string]::IsNullOrWhiteSpace($ActiveUser)) {
        
        $TasklistRaw = tasklist /FI "USERNAME eq $ActiveUser" /FO CSV /NH 2>$null
        
        # Blacklist dasar untuk nama file Executable (.exe) bawaan Windows Noise
        $BaseExeBlacklist = @(
            "explorer", "SearchHost", "StartMenuExperienceHost", "RuntimeBroker", "ShellExperienceHost",
            "conhost", "dllhost", "TextInputHost", "ctfmon", "taskhostw", "LockApp", "sihost", "Widgets",
            "avp", "avpui", "backgroundTaskHost", "crashhelper", "CrossDeviceResume", "ETDctrl", "ETDControlCenter",
            "FortiClient-Taskbar", "taskhostex", "ShellHost", "ShowOSD", "WidgetService", 
            "smartscreen", "SecurityHealthSystray", "WindowsPackageManagerServer", "svchost", "SearchProtocolHost", 
            "OutlookComm.*", "PhoneExperienceHost", "PhoneLink", "UserOOBEBroker", "ApplicationFrameHost", 
            "CompPkgSrv", "prevhost", "OneDriveSetUp", "FileCoAuth", "SearchApp", "AppActions", "EPDctrl", 
            "E_TATSU7", "m365copilotautostarter", "CrossDeviceService", "SystemSettings", "PromeCEFSubProcess", 
            "PushNotificationsLongRunningTask", "AdobeCollabSync", "aihost", "splwow64", "LocationNotificationWindows",
            "FMAPP", "RtkAud.*", "Realtek.*", "OneDriveSyncService", "OneDriveStandaloneUpdater",
            "MusNotifyIcon", "crashpadhandler", "MuMuNxDevice", "MuMuVMM", "MuMuVMMHeadless",
            # Menyembunyikan engine enkripsinya agar tidak dobel muncul di laporan telegram
            "fortissl", "fortissl64"
        ) -join "|"

        # FILTER KATA KUNCI KETAT VENDOR HARDWARE & AUDIO
        $VendorKeywordBlacklist = "Lenovo|Intel|Senary|Show OSD|igfx|IGCC|Epson|OneDrive"

        if ($TasklistRaw) {
            foreach ($Row in $TasklistRaw) {
                if ($Row -match '"([^"]+)","([^"]+)","([^"]+)","([^"]+)","([^"]+)"') {
                    $ProcNameWithExe = $Matches[1]
                    $ProcName = $ProcNameWithExe -replace "\.exe$", ""
                    $ProcId   = $Matches[2]

                    # Filter Lapis 1: Cek berdasarkan nama file executable dasar
                    if ($ProcName -match "^($BaseExeBlacklist)$") { continue }
                    
                    # Filter Lapis 2a: Cek kata kunci vendor (Kecuali OneDrive Core Utama)
                    if ($ProcName -match "($VendorKeywordBlacklist)" -and $ProcName -ne "OneDrive") { continue }

                    # Ambil deskripsi asli aplikasi (Friendly Name)
                    $AppName = $ProcName
                    try {
                        $LiveProc = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
                        if ($LiveProc -and (-not [string]::IsNullOrWhiteSpace($LiveProc.Description))) {
                            $AppName = $LiveProc.Description
                        }
                    } catch { }

                    # Filter Lapis 2b: Cek kata kunci deskripsi vendor (Kecuali OneDrive Core Utama)
                    if ($AppName -match "($VendorKeywordBlacklist)" -and $ProcName -ne "OneDrive") { continue }

                    $ContextInfo = "Aplikasi Latar Belakang"
                    
                    # Pemetaan intelijen label aplikasi kerja umum
                    if ($ProcName -match "excel|winword|powerpnt|notepad") {
                        try {
                            $CmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $ProcId" -ErrorAction SilentlyContinue).CommandLine
                            if ($CmdLine -and $CmdLine -match '"([^"\\]+\.[a-z0-9]+)"\s*$' -or $CmdLine -match '([^\\]+\.[a-z0-9]+)"*\s*$') {
                                $ContextInfo = "File: $($Matches[1] -replace '[\*\_`\[\]\(\)]', '')"
                            } else {
                                $ContextInfo = "Dokumen Terbuka"
                            }
                        } catch { $ContextInfo = "Dokumen Terbuka" }
                    }
                    elseif ($ProcName -eq "OUTLOOK") { $ContextInfo = "Email Active" }
                    elseif ($ProcName -match "^(chrome|msedge|brave|firefox)$") { $ContextInfo = "Browser Aktif" }
                    elseif ($ProcName -match "msedgewebview2|msteams|M365Copilot") { $ContextInfo = "Sistem / Subsistem" }
                    elseif ($ProcName -eq "mstsc") { $ContextInfo = "Remote Desktop Aktif" }
                    elseif ($ProcName -match "powershell|powershell_ise") { $ContextInfo = "Konsol PowerShell" }
                    elseif ($ProcName -match "whatsapp") { $ContextInfo = "WhatsApp Messenger" }
                    elseif ($ProcName -eq "anydesk") { $ContextInfo = "Remote Akses" }
                    elseif ($ProcName -eq "LockoutStatus") { $ContextInfo = "Audit Lockout User" }
                    elseif ($ProcName -eq "Taskmgr") { $ContextInfo = "Windows Task Manager" }
                    elseif ($ProcName -eq "Acrobat" -or $ProcName -eq "AcroRd32") { $ContextInfo = "Membuka Dokumen PDF" }
                    elseif ($ProcName -match "MuMuNxMain") { $ContextInfo = "Emulator Android Aktif" }
                    elseif ($ProcName -eq "OneDrive") { $ContextInfo = "Cloud Sync Active" }
                    elseif ($ProcName -match "saplogon") { $ContextInfo = "ERP Client" }
                    elseif ($ProcName -match "zoom") { $ContextInfo = "Zoom Meeting Client" }
                    
                    # LOGIKA ENGINE BARU BERBASIS STATUS PROSES AKTIF RESIDEN ENKRIPSI
                    elseif ($ProcName -match "forticlient|fortisslvpnclient|FortiTray|FortiClientw") {
                        $SslTunnelActive = Get-Process -Name "fortissl", "fortissl64" -ErrorAction SilentlyContinue
                        
                        if ($SslTunnelActive) {
                            $ContextInfo = "VPN Connected"
                        } else {
                            $ContextInfo = "VPN Disconnected"
                        }
                    }

                    $TempObj = [PSCustomObject]@{
                        Name  = $AppName
                        Title = $ContextInfo
                    }
                    [void]$ValidApps.Add($TempObj)
                }
            }
        }
    }

    # 3. KONSOLIDASI LOGIKA DISPLAY
    if ($ValidApps.Count -gt 0) {
        $GroupedApps = $ValidApps | Group-Object Name
        $AppLines = @()

        foreach ($Group in $GroupedApps) {
            $BestRecord = $Group.Group | Where-Object { $_.Title -notmatch "^(Aplikasi Aktif|Aplikasi Latar Belakang)$" } | Select-Object -First 1
            if (-not $BestRecord) {
                $BestRecord = $Group.Group | Select-Object -First 1
            }

            $CleanAppName = $BestRecord.Name
            $CleanTitle   = $BestRecord.Title

            # Sanitisasi String Murni Markdown
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
        $CurrentActivity = "• No Active GUI Window (User: $ActiveUser)"
    }

} catch { $CurrentActivity = "• Debug Error: $($_.Exception.Message)" }

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
           "📟 *CPU:* $CPU % | *⚡ *RAM:* $RAMUsage % | *📁 *Disk:* $DiskUsage % | *🎨 *GPU:* $GPUUsage %`n" +
           "🔋 *Battery:* $BatteryString | *📶 *Network:* $NetUsage Kbps`n" +
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

# 2. Konversi string menjadi Base64 murni (Aman dari segala distorsi encoding)
$utf8Bytes   = [System.Text.Encoding]::UTF8.GetBytes($Message)
$base64Text  = [Convert]::ToBase64String($utf8Bytes)

# 3. Bungkus ke dalam format JSON payload
$bodyJson = @{
    data = $base64Text
} | ConvertTo-Json -Compress

# 4. Kirim ke Cloudflare Gateway
$urlGateway = "https://win-audit-gateway.addohika.workers.dev"
$headers = @{
    "X-Audit-Signature" = "WinAuditS3cretPassw0rd2026"
}

try {
    # Kirim sebagai JSON murni
    Invoke-RestMethod -Uri $urlGateway -Method Post -Headers $headers -Body $bodyJson -ContentType "application/json; charset=utf-8" -ErrorAction Stop | Out-Null
    Write-Host "Laporan terkirim dalam format Base64!" -ForegroundColor Green
} catch {
    Write-Warning "Gagal mengirim laporan: $_"
}
