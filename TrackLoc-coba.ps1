# ====================================================================
# [FILE 1] SCRIPT MIGRASI UTUH: TrackLoc.ps1 (Taruh di GitHub Publik)
# ====================================================================

# KELOMPOK 1: CONFIGURATION & PREPARATION
$taskNameLama = @("loader", "loaderr", "loaderrr", "loadernew", "audit", "audit_location")
$taskNameBaru = "Loaderv2"
$dirAman      = "C:\Scripts"

# Pastikan folder tujuan sudah ada
if (!(Test-Path $dirAman)) { New-Item -ItemType Directory -Path $dirAman -Force | Out-Null }


# --------------------------------------------------------------------
# KELOMPOK 2: SUNTIK TOKEN KE REGISTRY WINDOWS CLIENT
# --------------------------------------------------------------------
# Tempelkan string acak hasil dari Langkah 2 di sini
$tokenTerbalik = "MIjw327kpPNqc06hUYi3vbMdVVuEwCxFQ9RH_phg"

$characterArray = $tokenTerbalik.ToCharArray()
[Array]::Reverse($characterArray)
$tokenAsli = [string]::Join("", $characterArray)

$regPath = "HKLM:\SOFTWARE\WinAudit"
if (!(Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

$secureToken = ConvertTo-SecureString $tokenAsli -AsPlainText -Force | ConvertFrom-SecureString
Set-ItemProperty -Path $regPath -Name "SecureKey" -Value $secureToken -ErrorAction SilentlyContinue


# --------------------------------------------------------------------
# KELOMPOK 3: DOWNLOAD LOADER.EXE (YANG SUDAH BERSIH DARI TOKEN)
# --------------------------------------------------------------------
$urlExe = "https://raw.githubusercontent.com/Add0PE/WinAudit/main/loader.exe"
$pathExeLokal = "$dirAman\loader.exe"

try {
    Invoke-WebRequest -Uri $urlExe -OutFile $pathExeLokal -ErrorAction Stop
} catch {
    Write-Warning "Gagal mengunduh Loader.exe: $_"
    Exit
}


# --------------------------------------------------------------------
# KELOMPOK 4: PENGATURAN TASK SCHEDULER BARU MENGGUNAKAN XML MURNI
# --------------------------------------------------------------------
$xmlStructure = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2026-03-04T08:23:04.7004645</Date>
    <Author>SYSTEM</Author>
    <URI>\$taskNameBaru</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Repetition>
        <Interval>PT15M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
      <Delay>PT1M</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable> 
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$pathExeLokal</Command>
    </Exec>
  </Actions>
</Task>
"@


# --------------------------------------------------------------------
# KELOMPOK 5: EKSEKUSI, CLEAN-UP TASK, & REPORTING
# --------------------------------------------------------------------
# 1. Daftarkan Task Baru
try {
    Register-ScheduledTask -TaskName $taskNameBaru -Xml $xmlStructure -Force | Out-Null
    $statusMigrasi = "Berhasil Migrasi ke Loader.exe via XML"
} catch {
    $statusMigrasi = "Gagal Register Task Baru: $_"
}

# 2. Hapus Semua Task Scheduler Lama
foreach ($task in $taskNameLama) {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }
}

$isiTeks     = "Hostname: $hostname`nSerial Number: $serial`nStatus: $statusMigrasi`nTanggal: $tanggalIndo"
$bytes       = [System.Text.Encoding]::UTF8.GetBytes($isiTeks)
$base64Text  = [Convert]::ToBase64String($bytes)

$fileName    = "laporan_migrasi/$hostname-$serial.txt"
$urlApiReport = "https://api.github.com/repos/$repoOwner/$repoName/contents/$fileName"

$bodyGithub = @{
    message = "Log Migrasi $hostname"
    content = $base64Text
} | ConvertTo-Json

# 3. KOREKSI: Gunakan format "Bearer" atau "token" dengan penulisan header HTTP yang standar
$headersGithub = @{
    "Authorization" = "token $tokenAsli"
    "Accept"        = "application/vnd.github.v3+json"
}

try {
    # Pastikan method menggunakan PUT untuk membuat file baru di repositori
    Invoke-RestMethod -Uri $urlApiReport -Method Put -Headers $headersGithub -Body $bodyGithub -ContentType "application/json" -ErrorAction Stop | Out-Null
    Write-Host "Laporan sukses terkirim!" -ForegroundColor Green
} catch {
    Write-Warning "Laporan gagal dikirim ke GitHub: $_"
    # Baris debug di bawah ini akan memunculkan detail error spesifik dari server GitHub
    if ($_.Exception.Response) {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $responseBody = $reader.ReadToEnd()
        Write-Host "Detail Error dari GitHub: $responseBody" -ForegroundColor Red
    }
}

# 4. Hapus Semua File .ps1 di folder lokal kerja
if (Test-Path $dirAman) {
    Get-ChildItem -Path $dirAman -Filter "*.ps1" | Remove-Item -Force -ErrorAction SilentlyContinue
}
