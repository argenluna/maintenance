# -*- coding: utf-8 -*-
# ============================================================
#  Auto Maintenance - 설치 (1회만 실행)
#  - 관리자 권한을 자동으로 요청합니다.
#  - 6일 주기 자동 점검 예약 작업을 등록합니다.
#  - 바탕화면에 "자동 유지보수 점검" / "자동 유지보수 피드백" 바로가기를 만듭니다.
#  - 첫 점검을 지금 실행합니다(35초 내외).
#  컴맹용: 이 파일을 더블클릭 → "예" → 끝.
# ============================================================
param([switch]$NoFirstRun, [string]$ReportTo = '')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sm = Join-Path $root 'Simple maintenance'
$wrapper = Join-Path $root 'run-maintenance.ps1'
$maint = Join-Path $sm 'maintenance.ps1'
$runNow = Join-Path $root 'run-now.ps1'
$uninstall = Join-Path $root 'uninstall.ps1'
$feedback = Join-Path $root 'feedback.ps1'
$taskName = 'OpenCode-Maintenance'

# --- 버전 (2026-11-14) --- VERSION 파일(1줄: 버전, 2줄: 날짜)이 기준.
function Get-KitVersionText {
  try {
    $vf = Join-Path $root 'VERSION'
    if (Test-Path $vf) {
      $vlines = @(Get-Content -Path $vf -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($vlines.Count -ge 1) {
        $v = ([string]$vlines[0]).Trim()
        if ($vlines.Count -ge 2) { return ("v$v (" + ([string]$vlines[1]).Trim() + ")") }
        return "v$v"
      }
    }
  } catch { }
  return 'vunknown'
}
$kitVersionText = Get-KitVersionText

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Step($msg) { Write-Host "  $msg" }

# --- 1. 관리자 권한 (없으면 스스로 다시 실행) ---
if (-not (Test-Admin)) {
  Write-Host '관리자 권한이 필요합니다. 확인 창에서 "예"를 누르세요...'
  # 사용자 바탕화면 경로를 미리 잡아 관리자 권한으로 넘긴다(관리자 계정이 다를 때 대비).
  $userDesktop = [Environment]::GetFolderPath('Desktop')
  $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ReportTo "{1}"' -f $PSCommandPath, $userDesktop
  if ($NoFirstRun) { $argLine += ' -NoFirstRun' }
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
  } catch {
    Write-Host '설치를 취소했습니다(관리자 권한 거부).'
  }
  exit
}

if ([string]::IsNullOrWhiteSpace($ReportTo)) { $ReportTo = [Environment]::GetFolderPath('Desktop') }

Write-Host ''
Write-Host '=========================================='
Write-Host '   자동 유지보수 설치'
Write-Host ("   {0}" -f $kitVersionText)
Write-Host '=========================================='
Write-Host ''

# --- 2. 파일 확인 ---
foreach ($f in @($wrapper, $maint, $runNow, $uninstall, $feedback)) {
  if (-not (Test-Path $f)) {
    Write-Host "오류: 필요한 파일이 없습니다 → $f"
    Write-Host '압축을 풀지 않았거나 파일이 이동되었습니다. 폴더째로 다시 받아 실행하세요.'
    Read-Host 'Enter 키를 누르면 닫힙니다'
    exit 1
  }
}
Write-Step '파일 확인 완료'

# --- 3. 스크립트 문법 검사 (깨진 파일로 예약 작업을 걸지 않기 위해) ---
foreach ($f in @($maint, $wrapper, $runNow, $uninstall, $feedback)) {
  $tok = $null; $err = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
  if ($err -and $err.Count -gt 0) {
    Write-Host "오류: 스크립트가 손상되었습니다 → $f"
    Write-Host ('  ' + $err[0].Message)
    Read-Host 'Enter 키를 누르면 닫힙니다'
    exit 1
  }
}
Write-Step '스크립트 검사 완료'

# --- 4. 설정 파일 (없을 때만 기본값 생성) ---
$cfgPath = Join-Path $sm 'config.json'
if (-not (Test-Path $cfgPath)) {
  $cfg = [ordered]@{
    setupComplete            = $true
    schedule                 = $false
    logToFile                = $false
    closeBehavior            = 'none'
    registerTask             = $false
    enableLogging            = $false
    maintenanceCadenceHours  = 144
    idleConsoleMinutes       = 5
    resultRetentionDays      = 90
    chkdskDays               = 12
    heavyCheckDays           = 30
    licenseCheckDays         = 30
    watchedTasks             = @('\OpenCode-Maintenance', '\FixNetworkMetric', '\opencode-cleanup', '\OpenCode-ReplayCleanup-3mo')
    watchedTaskMaxAgeDays    = 8
    eventLookbackDays        = 7
    notifyOnFail             = $true
    hfCacheWarnGB            = 150
    # 삭제 전 확인 + 임시 폴더 정리 안전장치 (2026-11-12 사고 후 추가)
    #   ※ 삭제는 항상 목록 확인 + y 입력 후에만 실행된다(끄는 설정 없음).
    tempMinAgeDays           = 1
    tempCleanupMaxGB         = 5
    # 광고/추천 정리: 기본은 "조용히"만 (hosts/DNS 차단은 사용자가 켜야 동작)
    adQuiet                  = $true
    adQuietKeepLockScreen    = $true
    adQuietMutePromoToasts   = $true
    adQuietDisableTipsTasks  = $true
    adBlockEnabled           = $false
    adBlockCategories        = @('ads')
    adBlockExtraDomains      = @()
    adBlockAllowDomains      = @()
    adBlockMaxDomains        = 500
    adDnsEnabled             = $false
    adDnsServers             = @('94.140.14.14', '94.140.15.15')
  }
  $cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $cfgPath -Encoding UTF8
  Write-Step '설정 파일 생성'
} else {
  Write-Step '설정 파일 유지(기존 설정 사용)'
}

# wrapper(주기 게이트)가 읽는 최상위 config.json — 없으면 wrapper 가 즉시 exit 1 로 죽는다.
$runnerCfgPath = Join-Path $root 'config.json'
if (-not (Test-Path $runnerCfgPath)) {
  $runnerCfg = [ordered]@{
    diskThresholdGB       = 10
    maintenanceCadenceHours = 144
    maintenanceEnabled    = $true
    setupComplete         = $true
    logToFile             = $false
    closeBehavior         = 'once'
    registerTask          = $false
    enableLogging         = $false
    schedule              = $false
    idleConsoleMinutes    = 5
  }
  $runnerCfg | ConvertTo-Json -Depth 4 | Set-Content -Path $runnerCfgPath -Encoding UTF8
  Write-Step '실행 설정 생성 (config.json)'
}

# --- 5. 예약 작업 등록 (매일 04:00 + 로그온 시, 실제 실행 여부는 6일 주기 게이트가 판단) ---
try {
  $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $wrapper)
  $triggers = @(
    (New-ScheduledTaskTrigger -Daily -At '04:00'),
    (New-ScheduledTaskTrigger -AtLogOn -User ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME))
  )
  $triggers[1].Delay = 'PT5M'
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 72) -MultipleInstances IgnoreNew
  $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null
  Write-Step '자동 점검 예약 등록 완료 (6일에 1번, PC가 꺼져 있었으면 다음에 켤 때)'
} catch {
  Write-Host "오류: 예약 작업 등록 실패 → $($_.Exception.Message)"
  Read-Host 'Enter 키를 누르면 닫힙니다'
  exit 1
}

# --- 6. 바탕화면 바로가기 ---
try {
  $desktop = [Environment]::GetFolderPath('Desktop')
  $ws = New-Object -ComObject WScript.Shell
  $defs = @(
    @{ Name = '자동 유지보수 점검.lnk'; Script = $runNow; Desc = '지금 바로 점검하고 결과를 보여줍니다' },
    @{ Name = '자동 유지보수 피드백.lnk'; Script = $feedback; Desc = '개인정보·위험코드를 지운 뒤 동의/비동의를 선택해 GitHub에 올립니다' },
    @{ Name = '자동 유지보수 제거.lnk'; Script = $uninstall; Desc = '자동 점검을 끄고 바로가기를 지웁니다' }
  )
  foreach ($d in $defs) {
    $lnkPath = Join-Path $desktop $d.Name
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $d.Script
    $lnk.WorkingDirectory = $root
    $lnk.IconLocation = "$env:SystemRoot\System32\imageres.dll,68"
    $lnk.Description = $d.Desc
    $lnk.Save()
  }
  Write-Step '바탕화면 바로가기 생성 (점검 / 피드백 / 제거)'
} catch {
  Write-Host "  (경고) 바로가기 생성 실패: $($_.Exception.Message)"
}

# --- 7. 첫 점검 ---
if (-not $NoFirstRun) {
  Write-Host ''
  Write-Host '첫 점검을 시작합니다. 창을 닫지 마세요 (35초 내외).'
  Write-Host ''
  & $wrapper -Force -ReportTo $ReportTo
  $resPath = Join-Path $sm 'last-result.json'
  if (Test-Path $resPath) {
    $r = Get-Content $resPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ''
    Write-Host '--------------- 결과 ---------------'
    Write-Host $(if ($r.status -eq 'PASS') { '결과: 정상 — 문제를 찾지 못했습니다.' } else { '결과: 확인이 필요한 항목이 있습니다.' })
    Write-Host ("자동으로 고친 것: {0}건 / 직접 확인할 것: {1}건" -f @($r.autoFixes).Count, @($r.recommendations).Count)
    $latest = $null
    foreach ($dir in @($ReportTo, ([Environment]::GetFolderPath('Desktop')))) {
      if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path $dir)) { continue }
      # 2026-11-17 (v1.3.0): 4개 이상이면 '자동점검결과' 폴더로 옮겨지므로 그 폴더도 본다.
      foreach ($scanDir in @($dir, (Join-Path $dir '자동점검결과'))) {
        if (-not (Test-Path -LiteralPath $scanDir -PathType Container)) { continue }
        $cand = Get-ChildItem -LiteralPath $scanDir -Filter '자동유지보수_*.txt' -File -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($cand -and (-not $latest -or $cand.LastWriteTime -gt $latest.LastWriteTime)) { $latest = $cand }
      }
      if ($latest) { break }
    }
    if (-not $latest) {
      $copy = Join-Path $sm 'logs\last-report.txt'
      if (Test-Path $copy) { $latest = Get-Item $copy }
    }
    if ($latest) {
      Write-Host "자세한 결과 파일: $($latest.FullName)"
      try { Invoke-Item $latest.FullName } catch { }
    }
  } else {
    Write-Host ''
    Write-Host '첫 점검이 완료되지 않았습니다. 로그를 확인하세요:'
    Write-Host ("  " + (Join-Path $root 'logs\runner-*.log'))
  }
}

Write-Host ''
Write-Host '설치 완료. 이제부터 6일에 한 번 자동으로 점검합니다.'
Write-Host '바탕화면의 "자동 유지보수 점검"을 더블클릭하면 언제든 직접 점검할 수 있습니다.'
Write-Host '컴퓨터를 잘 모르면 "newbie.txt"를, 의견을 보내려면 "자동 유지보수 피드백"을 사용하세요.'
Read-Host 'Enter 키를 누르면 닫힙니다'
