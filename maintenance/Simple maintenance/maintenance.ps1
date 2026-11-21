<#
.SYNOPSIS
  OpenCode 통합 시스템 유지보수 스크립트
.DESCRIPTION
  하나의 자체-완결적 스크립트로 세 가지 모드를 지원:
  - check:     주문형 상태 검사 (로그 출력)
  - scheduled: 주기(기본 12시간)에 따라 검사 후 데스크톱 리포트 생성
  - idle:      유휴시간 + GPU 감시로 실행 제어, 잠금파일 + 데스크톱 리포트
.PARAMETER Mode
  실행 모드: check, scheduled, idle
.EXAMPLE
  .\maintenance.ps1 -Mode check
  .\maintenance.ps1 -Mode scheduled
  .\maintenance.ps1 -Mode idle
#>

param(
  [Parameter(Position = 0)]
  [ValidateSet('check', 'scheduled', 'idle')]
  [string]$Mode = 'check',
  [string]$ExeDir = '',
  # "지금 점검" 버튼용: scheduled 모드의 주기 게이트를 건너뛴다(데스크톱 리포트는 그대로 생성).
  [switch]$SkipCadence,
  # 사용자가 직접 실행한 경우: 삭제 전 목록을 보여주고 y/N 을 물어본다.
  #   예약(자동) 실행에서는 넘어오지 않으므로 아무것도 지우지 않고 목록만 남긴다(안전 기본값).
  [switch]$PromptForDelete,
  # "지금 점검" 처럼 사람이 보고 있는 창에서 실행될 때 콘솔을 숨기지 않는다(2026-11-14).
  #   사고: scheduled 모드가 창을 숨기는데, run-now.ps1 이 같은 콘솔에서 자식을 띄우므로
  #         사용자 눈에는 "잠깐 진행되다가 창이 사라진" 것으로 보였다.
  [switch]$NoHideConsole,
  # 자동 실행에서 창을 숨기라는 명시적 지시(2026-11-17, v1.3.0).
  #   래퍼(run-maintenance.ps1)가 "사용 중"으로 판단해 창을 만들지 않고 실행한 경우 넘어온다.
  #   (유휴 → 보이게 / 사용 중 → 헤드리스 판단은 래퍼 한 곳에서만 한다)
  [switch]$HideConsole,
  # 결과 txt 를 만들 데스크톱 경로(관리자 계정이 다를 때 사용자 데스크톱으로 지정).
  [string]$ReportTo = '',
  # v1.13.0: 오래된 드라이버 판정 로직만 가상 데이터로 검증하고 종료 (개발/회귀 테스트용).
  [switch]$SelfTestDrivers
)

Set-StrictMode -Version Latest

# --- 단일 인스턴스 보장 (Mutex) 초기화 ---
$script:mutex = $null

# --- 실행 시간 측정 ---
$script:executionTimings = [System.Collections.ArrayList]@()
$script:executionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:runStartTime = Get-Date    # 전체 벽시계 시간 (단계 합계와 별개로 last-result.json 에 기록)

# I/O 우선순위를 Background로 설정 (시스템 반응성 보호)
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }

# --- 경로 설정 ---
$scriptRoot = if ($ExeDir -and (Test-Path -LiteralPath $ExeDir)) { $ExeDir }
  elseif ($PSScriptRoot) { $PSScriptRoot }
  else { try { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { Split-Path -Parent $MyInvocation.MyCommand.Definition } }
# --- 인자 안전 조인 (PS 5.1 대응) ---
# Start-Process -ArgumentList 로 넘길 때 경로/인자의 공백·따옴표·$ 로 인한 분리·재해석을 막는다.
# CANONICAL HELPER v1: 아래 2개 함수는 6개 스크립트 사본이 모두 동일해야 함. 변경 시 전부 갱신 + tests\verify-helper-parity.ps1 검증.
function ConvertTo-CliArg {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { return '""' }
  $v = [string]$Value
  $v = [regex]::Replace($v, '(\\*)"', '$1$1\"')
  $v = [regex]::Replace($v, '(\\+)$', '$1$1')
  if ($v -match '[\s"]') { return '"' + $v + '"' }
  return $v
}
function Join-CliArgs {
  param([string[]]$Arguments)
  return (@($Arguments | ForEach-Object { ConvertTo-CliArg $_ }) -join ' ')
}

$configPath = Join-Path $scriptRoot 'config.json'                          # 외부 설정 파일 (선택)
$lockFilePath = Join-Path $scriptRoot 'idle_maintenance.lock'              # 중복 실행 방지 잠금 파일
$logDir = Join-Path $scriptRoot 'logs'                                       # 실행파일 경로의 logs 폴더
$logPath = Join-Path $logDir "maintain-$(Get-Date -Format 'yyyy-MM-dd').log"  # 일별 로그 파일
# 2026-11-17 (v1.3.0): logs 폴더를 스크립트 시작 시점에 미리 만든다.
#   예전에는 삭제 목록 파일(deleted-*.txt)을 쓸 때(377행)만 폴더를 만들었기 때문에,
#   설치 직후 첫 실행에서는 Add-Content 가 실패해 앞부분 로그가 통째로 유실되고 stderr 만 남았다.
# 2026-11-17 (v1.3.1): 'logs' 가 **파일**로 남아 있는 설치본(옛 버전 버그)에서는 폴더를 만들 수 없어
#   로그가 계속 유실됐다(이 PC 실측: Simple maintenance\logs = 15KB 짜리 파일, 2026-11-13 로그).
#   → 그 파일을 logs-legacy-<시각>.txt 로 **이름만 바꿔 보존**하고 폴더를 만든다(지우지 않음).
if (Test-Path -LiteralPath $logDir -PathType Leaf) {
  try {
    $legacyLog = Join-Path $scriptRoot ('logs-legacy-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
    Move-Item -LiteralPath $logDir -Destination $legacyLog -Force -ErrorAction Stop
    Write-Output "Logs: '$logDir' was a file - renamed to '$legacyLog' (folder recreated)"
  } catch { Write-Output "Logs: WARN - '$logDir' is a file and could not be renamed: $($_.Exception.Message)" }
}
if (-not (Test-Path -LiteralPath $logDir)) {
  try { New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null } catch { }
}
$lastRunFile = Join-Path $scriptRoot '.last_run'                             # 마지막 "완료" 시각 (cadence 기준)

# --- 버전 (2026-11-14) ---
#   키트 루트의 VERSION 파일이 유일한 기준(1줄: 버전, 2줄: 배포 날짜).
#   수정할 때마다 이 값을 올린다 → 결과 txt 첫 줄에 찍혀서 "어느 버전이 돌았는지" 확인 가능.
$kitVersion = 'unknown'
$kitVersionDate = ''
try {
  $versionCandidates = @()
  $parentRoot = ''
  try { $parentRoot = Split-Path -Parent $scriptRoot } catch { }
  if ($parentRoot) { $versionCandidates += (Join-Path $parentRoot 'VERSION') }
  $versionCandidates += (Join-Path $scriptRoot 'VERSION')
  foreach ($vf in $versionCandidates) {
    if ($vf -and (Test-Path -LiteralPath $vf)) {
      $vlines = @(Get-Content -LiteralPath $vf -Encoding UTF8 -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($vlines.Count -ge 1) { $kitVersion = ([string]$vlines[0]).Trim() }
      if ($vlines.Count -ge 2) { $kitVersionDate = ([string]$vlines[1]).Trim() }
      break
    }
  }
} catch { }
$kitVersionText = if ($kitVersionDate) { "v$kitVersion ($kitVersionDate)" } else { "v$kitVersion" }

# --- Windows 언어 감지 (v1.7.0): 한국어면 ko, 아니면 en ---
# PowerShell 5.1 의 CurrentUICulture 는 설치 언어(en-US)를 반환할 수 있어 모든 후보를 훑는다.
function Get-KitLanguage {
  $tags = @()
  try {
    $t = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    if (-not [string]::IsNullOrWhiteSpace($t)) { $tags += $t }
  } catch { }
  try {
    $l = @(Get-WinUserLanguageList) | Select-Object -First 1
    if ($l -and -not [string]::IsNullOrWhiteSpace($l.LanguageTag)) { $tags += $l.LanguageTag }
  } catch { }
  try {
    $t = [System.Globalization.CultureInfo]::CurrentCulture.Name
    if (-not [string]::IsNullOrWhiteSpace($t)) { $tags += $t }
  } catch { }
  try {
    $t = (Get-WinSystemLocale).Name
    if (-not [string]::IsNullOrWhiteSpace($t)) { $tags += $t }
  } catch { }
  foreach ($tag in @($tags | Where-Object { $_ })) {
    if ($tag -match '^ko([-_]|$)') { return 'ko' }
  }
  return 'en'
}
$script:kitLang = Get-KitLanguage
function L {
  param([string]$Ko, [string]$En)
  if ($script:kitLang -eq 'ko') { return $Ko }
  return $En
}

# ============================================================
# v1.13.0: 오래된 드라이버 감지 (순수 함수 — 가상 데이터로 SelfTest 가능)
#   기준: "드라이버 저장소에 이미 더 새 버전이 설치되어 있는데 이전 버전이 남아 있는 것"
#   인터넷 조회/자동 설치 없음. 사용 중이거나 부팅 필수 드라이버는 후보에서 제외.
# ============================================================
$script:oldDriverStatus = $null

function ConvertTo-DriverVersion {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  try {
    $parts = @($Text.Split('.'))
    if ($parts.Count -lt 1 -or $parts.Count -gt 4) { return $null }
    $nums = @()
    foreach ($p in $parts) {
      if ($p -notmatch '^\d{1,5}$') { return $null }
      $nums += [int]$p
    }
    while ($nums.Count -lt 4) { $nums += 0 }
    return [Version]::new([int]$nums[0], [int]$nums[1], [int]$nums[2], [int]$nums[3])
  } catch { return $null }
}

function Get-OldDriverCandidatesFrom {
  param(
    [Parameter(Mandatory = $true)][object[]]$Drivers,
    [hashtable]$InUseInf = @{},
    # Win32_PnPSignedDriver 의 INF → 장치 이름(여러 장치가 한 INF를 쓸 수 있어 배열).
    [hashtable]$DeviceNames = @{}
  )
  # 부팅/입력/스토리지 핵심 클래스는 설령 구버전이 남아 있어도 건드리지 않는다.
  $protectedClasses = @('System', 'Filter', 'Boot', 'HAL', 'Disk', 'SCSI', 'Volume', 'FileSystem', 'ftdisk', 'Keyboard', 'Mouse')
  $buckets = @{}
  foreach ($d in $Drivers) {
    try {
      $inf = [string]$d.Driver
      if ($inf -notmatch '^oem\d+\.inf$') { continue }
      if ($d.Inbox -or $d.BootCritical) { continue }
      if ([string]$d.ClassName -in $protectedClasses) { continue }
      $orig = [IO.Path]::GetFileName([string]$d.OriginalFileName)
      if ([string]::IsNullOrWhiteSpace($orig)) { continue }
      $ver = ConvertTo-DriverVersion ([string]$d.Version)
      if (-not $ver) { continue }
      $key = ('{0}|{1}|{2}' -f [string]$d.ProviderName, [string]$d.ClassName, $orig).ToLowerInvariant()
      if (-not $buckets.ContainsKey($key)) { $buckets[$key] = @() }
      # INF 로 실제 장치 이름을 찾는다 (없으면 빈 문자열 → 출력에서 라벨 자체를 생략).
      $devText = ''
      $dkey = $inf.ToLowerInvariant()
      if ($DeviceNames.ContainsKey($dkey)) {
        $names = @($DeviceNames[$dkey] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($names.Count -gt 0) {
          $devText = (@($names | Select-Object -First 2) -join ', ')
          if ($names.Count -gt 2) { $devText += (L ' 외 {0}개' ' (+{0} more)') -f ($names.Count - 2) }
        }
      }
      $buckets[$key] += [pscustomobject]@{
        Inf      = $inf
        Provider = [string]$d.ProviderName
        Class    = [string]$d.ClassName
        File     = $orig
        Version  = [string]$d.Version
        Ver      = $ver
        InUse    = [bool]$InUseInf.ContainsKey($dkey)
        Device   = $devText
      }
    } catch { }
  }
  $older = @()
  foreach ($key in $buckets.Keys) {
    $items = @($buckets[$key])
    if ($items.Count -lt 2) { continue }
    $newest = @($items | Sort-Object -Property Ver -Descending | Select-Object -First 1)[0]
    foreach ($item in @($items | Where-Object { $_.Ver -lt $newest.Ver })) {
      $older += [pscustomobject]@{
        Inf           = $item.Inf
        Provider      = $item.Provider
        Class         = $item.Class
        File          = $item.File
        Version       = $item.Version
        NewestInf     = $newest.Inf
        NewestVersion = $newest.Version
        InUse         = $item.InUse
        Device        = $item.Device
        Reason        = if ($item.InUse) { L '현재 장치가 사용 중' 'Currently used by a device' } else { '' }
        Deleted       = $false
      }
    }
  }
  return @($older | Sort-Object -Property Provider, Class, File, Version)
}

if ($SelfTestDrivers) {
  $fixtures = @(
    [pscustomobject]@{ Driver='oem1.inf';  OriginalFileName='C:\D\a.inf'; ProviderName='ACME'; ClassName='Net';  Version='1.0.0.0'; Inbox=$false; BootCritical=$false },
    [pscustomobject]@{ Driver='oem2.inf';  OriginalFileName='C:\D\a.inf'; ProviderName='ACME'; ClassName='Net';  Version='2.0.0.0'; Inbox=$false; BootCritical=$false },
    [pscustomobject]@{ Driver='oem3.inf';  OriginalFileName='C:\D\b.inf'; ProviderName='ACME'; ClassName='Media'; Version='3.0.0.0'; Inbox=$false; BootCritical=$false },
    [pscustomobject]@{ Driver='oem4.inf';  OriginalFileName='C:\D\b.inf'; ProviderName='ACME'; ClassName='Media'; Version='4.0.0.0'; Inbox=$false; BootCritical=$false },
    [pscustomobject]@{ Driver='oem5.inf';  OriginalFileName='C:\D\c.inf'; ProviderName='ACME'; ClassName='USB';  Version='1.0.0.0'; Inbox=$false; BootCritical=$true },
    [pscustomobject]@{ Driver='oem6.inf';  OriginalFileName='C:\D\c.inf'; ProviderName='ACME'; ClassName='USB';  Version='2.0.0.0'; Inbox=$false; BootCritical=$false },
    [pscustomobject]@{ Driver='oem7.inf';  OriginalFileName='C:\D\d.inf'; ProviderName='Other'; ClassName='Net';  Version='1.0.0.0'; Inbox=$false; BootCritical=$false },
    [pscustomobject]@{ Driver='oem8.inf';  OriginalFileName='C:\D\e.inf'; ProviderName='ACME'; ClassName='Net';  Version='9.0.0.0'; Inbox=$false; BootCritical=$false }
  )
  $use = @{ 'oem3.inf' = $true }
  $names = @{ 'oem1.inf' = @('ACME Gigabit Ethernet'); 'oem3.inf' = @('ACME Sound Card', 'ACME Audio', 'ACME Spdif') }
  $got = @(Get-OldDriverCandidatesFrom -Drivers $fixtures -InUseInf $use -DeviceNames $names)
  $fail = 0
  function Assert-OD([string]$Name, [bool]$Ok) {
    if ($Ok) { "PASS $Name" } else { "FAIL $Name"; $script:odFail++ }
  }
  $script:odFail = 0
  Assert-OD '두 버전 중 이전 것만 후보' (@($got | Where-Object Inf -eq 'oem1.inf').Count -eq 1)
  Assert-OD '최신은 후보 아님' (@($got | Where-Object Inf -eq 'oem2.inf').Count -eq 0)
  Assert-OD '사용 중 드라이버도 목록에 포함' (@($got | Where-Object Inf -eq 'oem3.inf').Count -eq 1)
  Assert-OD '사용 중이면 이유 기록' ([string]($got | Where-Object Inf -eq 'oem3.inf').Reason -ne '')
  Assert-OD '부팅 필수는 제외' (@($got | Where-Object Inf -eq 'oem5.inf').Count -eq 0)
  Assert-OD '다른 제조사는 그룹 안 섞임' (@($got | Where-Object Inf -eq 'oem7.inf').Count -eq 0)
  Assert-OD '단일 버전은 후보 아님' (@($got | Where-Object Inf -eq 'oem8.inf').Count -eq 0)
  Assert-OD '최신 버전 정보 유지' ([string]($got | Where-Object Inf -eq 'oem1.inf').NewestVersion -eq '2.0.0.0')
  Assert-OD '장치 이름 표시' ([string]($got | Where-Object Inf -eq 'oem1.inf').Device -eq 'ACME Gigabit Ethernet')
  Assert-OD '여러 장치는 앞 2개만 표시' ([string]($got | Where-Object Inf -eq 'oem3.inf').Device -match '^ACME Sound Card, ACME Audio')
  "SelfTestDrivers: fail=$script:odFail"
  if ($script:odFail -gt 0) { exit 1 }
  exit 0
}

# 결과 txt 파일명/보관 폴더 (v1.7.0): 한국어=기존 이름 / 그 외=영어 이름
$script:resultPrefix    = if ($script:kitLang -eq 'ko') { '자동유지보수_' } else { 'auto-maintenance_' }
$script:resultFailPrefix = if ($script:kitLang -eq 'ko') { '자동유지보수_실패_' } else { 'auto-maintenance_failed_' }
$script:resultFolderName = if ($script:kitLang -eq 'ko') { '자동점검결과' } else { 'maintenance results' }
# 정리/보관 대상: 언어 전환 전 파일까지 모두 포함(사용자 파일은 패턴이 달라 건드리지 않음).
$script:resultFilePatterns = @('자동유지보수_*.txt', 'MaintenanceReport_*.txt', 'auto-maintenance_*.txt')

# 진행률 표시용 전역 변수 사전 초기화 (StrictMode 에러 방지)
$script:stepBarPending = $false
$script:progressTotal = 39   # 2026-11-19: 오래된 드라이버 정리 추가(38 -> 39, v1.13.0)
$script:progressCurrent = 0
$script:stepName = ''
$script:subStep = ''
$script:subCurrent = -1
$script:subTotal = 0
$script:lockCreated = $false
$script:interimLines = 0

# 유휴 시간 측정용 어셈블리 사전 로드 (headless, csc.exe 호출 없음)
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { }

# --- 내장 기본 설정 (외부 config.json 없을 때 사용) ---
$defaults = @{
  diskThresholdGB          = 10        # 디스크 부족 판단 기준 (GB)
  maintenanceCadenceHours  = 144       # scheduled 모드 실행 간격 (시간) - 6일. WHEA/AutoHeal 7일 조회창보다 짧게 유지
  idleTriggerSeconds       = 3600      # idle 모드 유휴 대기 시간 (초)
  # 자동 실행 시 콘솔 창 표시 기준 (2026-11-17, v1.3.0 사용자 요청)
  #   "유휴기간에는 cmd 창이 보이게 돌아가고, 사용 중에는 헤드리스로 결과 파일만 저장되게 해달라."
  #   0 = 항상 보이게, N = N분 이상 입력이 없으면(유휴) 보이게. 직접 실행은 이 값과 무관하게 항상 보인다.
  idleConsoleMinutes       = 5
  # 결과 txt(자동유지보수_*.txt / MaintenanceReport_*.txt / auto-maintenance_*.txt) 보관 일수 (2026-11-17, v1.4.0 / v1.7.0)
  #   "날짜상 3개월 이상 지난 결과 파일은 자동삭제하고" → 기본 90일 넘은 파일만 자동 삭제(묻지 않음).
  #   0 이하 = 자동 삭제 끄기. 이 키트가 만든 결과 txt 만 대상이며 사용자 파일은 건드리지 않는다.
  resultRetentionDays      = 90
  logsRetentionDays        = 7         # 로그 보관 일수
  tempDirs                 = @("$env:TEMP", "$env:windir\Temp")  # 디스크 정리 대상 폴더
  # --- 임시 폴더 자동 정리 안전장치 (2026-11-12 사고 대응) ---
  #   사고: 사용자 PC 의 TEMP/TMP 가 드라이브 루트(I:\) 였고, 디스크 부족 판정이 나자
  #         "임시 폴더 = I:\" 로 보고 그 드라이브의 사진/문서를 전부 지웠다.
  #   → 드라이브 루트·사용자 데이터 폴더는 무조건 제외하고, 최근 파일은 건드리지 않으며,
  #     한 번에 지우는 양도 제한한다.
  tempMinAgeDays           = 1         # 이 일수보다 최근에 만들어진/수정된 파일은 지우지 않음
  tempCleanupMaxGB         = 5         # 한 번 실행에서 임시 폴더 정리로 지우는 최대 용량 (GB)
  servicesToCheck          = @('Spooler', 'BITS', 'WinDefend', 'RpcSs', 'SamSs', 'PlugPlay', 'EventLog', 'ProfSvc', 'gpsvc', 'Power', 'DCOMLAUNCH', 'CoreMessaging')  # 상태 확인할 서비스 목록
  restartServices          = @('Spooler')                             # 자동 재시작할 서비스 목록
  #   BITS/VSS 는 제거(2026-11-05): 둘 다 Manual(요청 시 시작) 서비스라 "중지됨"이 정상인데
  #   매 실행 강제 재시작해 CHANGE 로그만 남기고, 진행 중인 다운로드/섀도 복사본을 끊을 수 있다.
  #   Spooler 만 유지(인쇄 대기열 멈춤은 실제로 흔한 고장).
  criticalServices         = @('RpcSs', 'SamSs', 'PlugPlay', 'EventLog', 'ProfSvc')  # 시스템 구동 필수 서비스 (중지 시 시스템 손상)
  #   defragThreshold 제거(2026-11-06): 볼륨 최적화는 Windows ScheduledDefrag(defrag /O)에 위임.
  chkdskDays               = 12        # CHKDSK(/scan) 실행 간격 (일). 144h 주기의 2배 = 정확히 2회마다 실행. 0이면 매 실행
  heavyCheckDays           = 30        # SFC/WinSxS(무거운 검사) 실행 간격 (일). 0이면 매 실행
  licenseCheckDays         = 30        # Windows 정품 인증 확인 간격 (일). 첫 조회가 콜드 15s 라 게이트함
  watchedTasks             = @('\OpenCode-Maintenance', '\FixNetworkMetric', '\opencode-cleanup', '\OpenCode-ReplayCleanup-3mo')  # 생존 확인할 자동화 예약 작업
  watchedTaskMaxAgeDays    = 8         # 감시 작업이 이 일수보다 오래 실행되지 않았으면 INFO 로 알림 (0=끔)
  eventLookbackDays        = 7         # 이벤트 로그 조회 기간 (일)
  notifyOnFail             = $true     # FAIL 시 알림(토스트 + last-result.json) 표시
  hfCacheWarnGB            = 150       # HuggingFace 캐시 경고 기준 (GB). 절대 자동 삭제하지 않음
  autoInstallUpdates       = $false    # Windows Update 자동 설치(기본 꺼짐). 재부팅이 필요한 업데이트는 사용자가 결정
  # --- 삭제 전 확인 (2026-11-12 사용자 요청) ---
  #   파일을 지우기 전에 항상 목록을 보여주고 y 를 눌러야만 지운다.
  #   예약(자동) 실행은 물어볼 사람이 없으므로 아무것도 지우지 않고 보류만 기록한다.
  #   ※ 2026-11-20(v1.14.0)부터 A(언제나 삭제) 선택을 단계별로 기억할 수 있다.
  #      A 는 사용자가 명시적으로 눌렀을 때만 저장되며, 저장된 경우에만 자동 삭제한다.
  # --- v1.14.0: A(언제나 삭제) 기억 설정 ---
  #   "A는 언제나 삭제 / Y는 현재 삭제 / N은 거부" (2026-11-20 사용자 요청)
  #   true 이면 해당 단계에서 묻지 않고 지운다. 기본 false = 매번 묻는다.
  tempAutoDelete           = $false   # 임시 폴더의 오래된 파일
  browserCacheAutoDelete   = $false   # 브라우저 캐시 (30일 이상)
  recycleAutoDelete        = $false   # 휴지통 (30일 이상)
  # --- 광고/추천 (2026-11-09 추가) ---
  #   Windows 11 은 기본값이 "광고 ON" 이라 새 PC/재설치 후 프로모션이 다시 나타난다.
  #   adQuiet 는 HKCU 값만 바꾸므로 관리자 없이도 되고, 전부 되돌릴 수 있다.
  adQuiet                  = $true     # Windows 광고/추천 스위치를 끈다 (HKCU, 가역)
  adQuietKeepLockScreen    = $true     # 잠금화면 "사진 로테이션"은 유지 (광고/프로모션만 끔)
  adQuietMutePromoToasts   = $true     # Store/Office/날씨 앱의 프로모션 알림 끔
  adQuietDisableTipsTasks  = $true     # SoftLanding(팁/광고 알림을 쏘는 예약 작업) 비활성
  # --- 오래된 드라이버 정리 (2026-11-19, v1.13.0) ---
  #   기본 켜짐. 단, 삭제는 사람이 보는 창에서 y 를 눌러야만 실행한다.
  #   예약/유휴 실행에서는 목록만 남기고 절대 지우지 않는다.
  #   "새 버전" = 같은 제조사·클래스·INF 의 더 새 버전이 이미 드라이버 저장소에 설치된 상태.
  oldDriverCleanup         = $true     # false 로 바꾸면 목록만 보고 아무것도 지우지 않음
  oldDriverCheckDays       = 30        # 감지 주기(일). SFC/WinSxS 와 함께 가장 긴 주기. 0 이하면 매 실행
  adBlockEnabled           = $false    # hosts 광고 도메인 차단 (기본 꺼짐 = 사용자가 켜야 동작)
  adBlockCategories        = @('ads')  # ads / trackers
  adBlockExtraDomains      = @()       # 사용자가 추가로 막을 도메인 (정확한 호스트명만)
  adBlockAllowDomains      = @()       # 앱이 깨질 때 예외로 둘 도메인
  adBlockMaxDomains        = 500       # 안전 상한 (사람이 검토 가능한 크기)
  adDnsEnabled             = $false    # 시스템 DNS를 필터링 리졸버로 변경 (opt-in)
  adDnsServers             = @('94.140.14.14', '94.140.15.15')  # AdGuard DNS (광고+트래커)
}

# --- 외부 config.json 설정 불러오기 (있으면 내장 기본값보다 우선) ---
$config = $null
if (Test-Path -LiteralPath $configPath) {
  try { $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Output "Config: WARN - Failed to load config: $_" }
}

# config.json 스키마 검증 (알 수 없는 키 경고)
function Assert-ConfigSchema {
  param($cfg)
  if (-not $cfg) { return }
  $known = @('registerTask','registerIdleAuto','registerCpuPrompt','enableLogging','closeBehavior','setupComplete','diskThresholdGB','tempDirs',
             'servicesToCheck','restartServices','criticalServices','schedule','logToFile',
             'maintenanceCadenceHours','maintenanceEnabled','idleTriggerSeconds','idleConsoleMinutes','logsRetentionDays','resultRetentionDays',
             'chkdskDays','heavyCheckDays','licenseCheckDays','eventLookbackDays','notifyOnFail','hfCacheWarnGB','autoInstallUpdates',
             'tempMinAgeDays','tempCleanupMaxGB',
             'watchedTasks','watchedTaskMaxAgeDays',
             'adQuiet','adQuietKeepLockScreen','adQuietMutePromoToasts','adQuietDisableTipsTasks',
             'oldDriverCleanup','oldDriverCheckDays',
              'tempAutoDelete','browserCacheAutoDelete','recycleAutoDelete','autoFeedback',
             'adBlockEnabled','adBlockCategories','adBlockExtraDomains','adBlockAllowDomains','adBlockMaxDomains',
             'adDnsEnabled','adDnsServers')
  $types = @{ diskThresholdGB = [int]; tempDirs = [string[]]; servicesToCheck = [string[]]; restartServices = [string[]]; criticalServices = [string[]];
              registerIdleAuto = [bool]; registerCpuPrompt = [bool];
              chkdskDays = [int]; heavyCheckDays = [int]; licenseCheckDays = [int]; eventLookbackDays = [int]; notifyOnFail = [bool]; hfCacheWarnGB = [int];
              idleConsoleMinutes = [int]; resultRetentionDays = [int];
              watchedTasks = [string[]]; watchedTaskMaxAgeDays = [int];
              autoInstallUpdates = [bool];
              tempMinAgeDays = [int]; tempCleanupMaxGB = [int];
              adQuiet = [bool]; adQuietKeepLockScreen = [bool]; adQuietMutePromoToasts = [bool]; adQuietDisableTipsTasks = [bool];
              oldDriverCleanup = [bool]; oldDriverCheckDays = [int];
              tempAutoDelete = [bool]; browserCacheAutoDelete = [bool]; recycleAutoDelete = [bool];
              adBlockEnabled = [bool]; adBlockCategories = [string[]]; adBlockExtraDomains = [string[]]; adBlockAllowDomains = [string[]]; adBlockMaxDomains = [int];
              adDnsEnabled = [bool]; adDnsServers = [string[]] }
  foreach ($prop in $cfg.PSObject.Properties) {
    if ($prop.Name -notin $known) {
      Write-Warning "config.json: Unknown key '$($prop.Name)' (ignored)"
    } elseif ($types.ContainsKey($prop.Name)) {
      $expected = $types[$prop.Name]
      $actual = $prop.Value.GetType()
      $typeOk = ($actual -eq $expected -or $actual -eq ([int]))
      # JSON 배열은 Object[] 로 역직렬화되므로 [string[]] 기대값과 타입이 다르다 → 문자열 배열 허용
      if ($expected -eq [string[]] -and $prop.Value -is [System.Collections.IEnumerable] -and -not ($prop.Value -is [string])) {
        $typeOk = $true
      }
      if (-not $typeOk) {
        Write-Warning "config.json: '$($prop.Name)' should be $expected, got $actual"
      }
    }
  }
}
Assert-ConfigSchema $config

# StrictMode-safe config property helpers (Get-ConfigProp 누락 방지)
function Test-ConfigProp($obj, $name) {
  if (-not $obj) { return $false }
  try { return ($obj.PSObject.Properties.Match($name).Count -gt 0) } catch { return $false }
}
function Get-ConfigProp($obj, $name) {
  if (Test-ConfigProp $obj $name) { return $obj.$name }
  return $null
}

# 설정값 조회 헬퍼: 외부 설정 우선, 없으면 내장 기본값 반환
function Get-Cfg([string]$key) {
  $val = Get-ConfigProp $config $key
  if ($null -eq $val) { return $defaults[$key] }
  # config.json 에 잘못된 타입이 들어오면 관리자 권한 작업에 그대로 쓰지 않고 기본값으로 되돌린다.
  $def = $null
  if ($defaults.ContainsKey($key)) { $def = $defaults[$key] }
  if ($null -ne $def) {
    if (($def -is [bool]) -and ($val -isnot [bool])) { return $def }
    if (($def -is [int]) -and ($val -isnot [int]) -and ($val -isnot [long])) { return $def }
    if (($def -is [string]) -and ($val -isnot [string])) { return $def }
    # [string] 도 IEnumerable 이므로 문자열은 배열로 인정하지 않는다.
    if (($def -is [array]) -and -not (($val -is [System.Collections.IEnumerable]) -and -not ($val -is [string]))) { return $def }
  }
  return $val
}

# v1.14.0: A(언제나 삭제) 선택을 config.json 에 영구 저장하고 메모리 설정도 갱신한다.
#   저장에 실패하면 false 를 돌려 "이번 실행만 삭제"로 처리한다(설정 오류 때문에 삭제 자체가 막히지 않게).
function Set-CfgBool {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][bool]$Value
  )
  try {
    $cfgObj = $null
    if (Test-Path -LiteralPath $configPath) {
      $cfgObj = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    if (-not $cfgObj) { $cfgObj = New-Object PSObject }
    $cfgObj | Add-Member -Force -NotePropertyName $Key -NotePropertyValue $Value
    $cfgObj | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $configPath -Encoding UTF8 -Force
    if ($null -eq $config) { $config = $cfgObj }
    else { $config | Add-Member -Force -NotePropertyName $Key -NotePropertyValue $Value }
    return $true
  } catch {
    Write-LogEntry "Delete Review: WARN - '$Key' 설정 저장 실패: $($_.Exception.Message)"
    return $false
  }
}

# IPv4 리터럴 검증: 999.999.999.999 같은 형식만 맞는 값도 거른다.
function Test-IPv4Literal {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  if ($Value -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
  foreach ($oct in @($Matches[1], $Matches[2], $Matches[3], $Matches[4])) {
    $n = 0
    if (-not [int]::TryParse($oct, [ref]$n)) { return $false }
    if ($n -lt 0 -or $n -gt 255) { return $false }
  }
  return $true
}

# ============================================================
# 삭제 전 확인 (2026-11-12 사용자 요청)
#   "자료를 지우기 전에 지우려는 목록을 보여주고 yes/no 를 고르게 해달라"
#   - 예약(자동) 실행은 물어볼 사람이 없으므로 **아무것도 지우지 않고 목록만 기록**한다(안전 기본값).
#   - 사용자가 직접 실행("지금 점검" / 설치 첫 점검)하면 목록을 보여주고 y/N 을 묻는다.
#   - 결정 내용과 목록은 로그, 데스크톱 결과 txt, last-result.json(deleteReview) 에 남는다.
#
#   2026-11-12 사용자 지시(2차):
#     "용량이 적게 남았더라도(극단적으로 100MB 라도) 최소 용량 확보를 위해 알아서 지우지 마라.
#      '용량이 이만큼 남았으니 오래된 파일부터 삭제합니다. 필요한 자료가 있으시면 백업하세요.
#       삭제하시겠습니까?' 라고 물어보고 y 를 눌러야만 지워라."
#   → 자동 삭제 경로를 없앴다. y/yes 를 입력한 경우에만 지운다(설정으로 끄는 옵션 없음).
# ============================================================
$script:deleteReview = @()   # 리포트/last-result.json 에 남길 기록
$script:resultCleanup = $null   # 3개월 지난 결과 파일 자동 삭제 내역 (v1.4.0)
$script:reportMove = $null      # 바탕화면 결과 파일 → '자동점검결과' 폴더 이동 내역 (v1.4.0)
$script:desktopPathForReport = ''
$script:askDelete = $false
if ($PromptForDelete) {
  $script:askDelete = $true
} elseif ($Mode -ne 'scheduled' -and $Mode -ne 'idle' -and [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected) {
  $script:askDelete = $true   # 콘솔에서 직접 실행한 check 모드
}

# ------------------------------------------------------------
# 삭제 확인은 **단계마다 한 번** (2026-11-20, v1.14.0 사용자 요청)
#   "임시파일 및 휴지통 삭제할 때 A 를 추가해. A는 언제나 삭제, Y는 현재 삭제, N은 거부."
#   임시 폴더 / 브라우저 캐시 / 휴지통 단계에서 목록을 보여주고 A/Y/N 을 묻는다.
#     - A = 해당 단계의 config 키를 true 로 저장 → 다음 실행부터 묻지 않고 자동 삭제
#     - Y = 이번 실행에서만 삭제 (설정은 바뀌지 않음)
#     - N 또는 Enter = 거부 (기본값)
#   ⚠ 자동 삭제는 사용자가 A 를 명시적으로 눌러 저장한 경우에만 동작한다.
#     저장된 A 가 없는 예약 실행은 여전히 아무것도 지우지 않는다.
#     (지난 결과 파일 3개월 자동 삭제는 별개 — v1.4.0 사용자 요청)
# ------------------------------------------------------------

function Format-ByteSize([double]$Bytes) {
  if ($Bytes -ge 1GB) { return ('{0:0.00}GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:0.0}MB' -f ($Bytes / 1MB)) }
  return ('{0:0}KB' -f [math]::Max(1, $Bytes / 1KB))
}

# "여유 공간이 위험할 만큼 적은가?" — 경고 문구를 언제 띄울지 결정한다(2026-11-13 사용자 지시).
#   "500GB·3TB 남았는데 '몇 GB 남았습니다. 문제가 생길 수 있습니다' 는 말이 안 된다.
#    적정 용량 이하로 남았을 때만 그런 경고가 나와야 한다."
#   → 5GB 미만(작은 드라이브는 용량의 5%)일 때만 '디스크 속도/이용에 문제가 있을 수 있다' 고 말한다.
function Test-CriticalFreeSpace {
  param([double]$FreeBytes, [double]$TotalBytes = 0)
  $crit = [double](5GB)
  if ($TotalBytes -gt 0 -and $TotalBytes -lt 100GB) {
    $fivePct = [double]$TotalBytes * 0.05
    if ($fivePct -lt $crit) { $crit = [math]::Max([double](1GB), [double]$fivePct) }
  }
  return ($FreeBytes -lt $crit)
}

# 삭제 후보 목록을 보여주고 승인 여부를 반환한다. 승인된 경우에만 DeleteAction 을 실행한다.
#   $Items  : @( @{ Name='표시할 경로'; Size=바이트; Date=날짜 } )  ← $Items[i].Name/.Size/.Date 로 접근
#   $Notice : 목록 위에 함께 보여줄 안내문(예: "지금 C 드라이브 여유 공간은 0.1GB 입니다.")
#             물어볼 수 없는 실행(예약)에서도 로그/결과 txt 에 남기기 위해 기록에 포함한다.
function Invoke-DeleteReview {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
    [scriptblock]$DeleteAction = $null,
    [int]$ShowMax = 20,
    [AllowEmptyCollection()][string[]]$Notice = @(),
    # v1.14.0: A(언제나 삭제) 선택을 저장할 config 키. 비우면 A 저장 없이 Y/N 만 묻는다.
    [string]$PolicyKey = ''
  )

  $list = @($Items)
  if ($list.Count -eq 0) { return $false }

  $totalBytes = 0.0
  foreach ($it in $list) { if ($null -ne $it.Size) { $totalBytes += [double]$it.Size } }
  $sizeText = Format-ByteSize $totalBytes

  # 화면에 보여줄 목록 (큰 것부터 ShowMax 개) — 콘솔 출력 전용
  #   ⚠ 기록용 목록($paths)은 따로 만든다. 화면에는 20개만 보여도 결과 txt·복구용 파일에는
  #     "폴더 경로 + 파일명"을 전부 남긴다(2026-11-13 사용자 요청).
  #     → 만화 폴더 수십 개에 각각 1.jpg 2.jpg 3.jpg 가 있어도 어느 폴더의 파일인지 구분된다.
  $preview = @()
  $paths = @()
  $pathLimit = 5000
  $sorted = @($list | Sort-Object -Property @{ Expression = { [double]$_.Size } } -Descending)
  foreach ($it in $sorted) {
    $dateText = ''
    $dateFull = ''
    if ($it.Date) {
      try { $dateFull = ([datetime]$it.Date).ToString('yyyy-MM-dd HH:mm'); $dateText = ', ' + ([datetime]$it.Date).ToString('yyyy-MM-dd') } catch { }
    }
    if ($paths.Count -lt $pathLimit) {
      $paths += [ordered]@{ path = [string]$it.Name; size = [double]$it.Size; date = $dateFull }
    }
    if ($preview.Count -lt $ShowMax) {
      $preview += ('{0} ({1}{2})' -f $it.Name, (Format-ByteSize ([double]$it.Size)), $dateText)
    }
  }
  $moreCount = $list.Count - $preview.Count
  if ($moreCount -lt 0) { $moreCount = 0 }
  $pathsMore = $list.Count - $paths.Count
  if ($pathsMore -lt 0) { $pathsMore = 0 }

  # --- 결정: 설정에 기억된 A / 사용자 A·Y·N / 보류(물어볼 사람 없음) ---
  #   v1.14.0 (2026-11-20): "A는 언제나 삭제 / Y는 현재 삭제 / N은 거부"
  #     - A : config 에 true 저장 → 이후 실행(예약 포함)에서 묻지 않고 삭제
  #     - Y : 이번 실행만 삭제
  #     - N : 거부 (기본값)
  #   저장된 A 가 없으면 예약 실행은 여전히 보류(아무것도 지우지 않음).
  $decision = 'deferred'
  $always = $false
  $answerA = $false
  if (-not [string]::IsNullOrWhiteSpace($PolicyKey)) { $always = [bool](Get-Cfg $PolicyKey) }
  if ($always) {
    Write-Host ''
    Write-TestHeader ("[삭제 확인] {0} — {1}개 / {2}" -f $Target, $list.Count, $sizeText)
    Write-Host (L '  → A(언제나 삭제)가 설정에 저장되어 있어 묻지 않고 지웁니다.' '  -> "Always delete" (A) is saved in config; deleting without asking.')
    Write-LogEntry (L "Delete Review: 설정의 A에 따라 자동 삭제 — $Target" "Delete Review: auto-deleted by saved A - $Target")
    $decision = 'yes'
  } elseif ($script:askDelete) {
    Write-Host ''
    Write-TestHeader ("[삭제 확인] {0} — {1}개 / {2}" -f $Target, $list.Count, $sizeText)
    foreach ($n in @($Notice)) { if (-not [string]::IsNullOrWhiteSpace($n)) { Write-Host "  $n" } }
    Write-Host (L '  지우려는 목록:' '  Files to delete:')
    foreach ($p in $preview) { Write-Host "    · $p" }
    if ($moreCount -gt 0) { Write-Host "    · ... 외 $moreCount 개" }
    $ans = ''
    try {
      $ans = Read-Host (L '  A = 언제나 삭제(설정에 기억) / Y = 현재만 삭제 / N 또는 Enter = 거부' '  A = always delete (save to config) / Y = delete this time only / N or Enter = keep')
    } catch { $ans = '' }
    if ("$ans" -match '^\s*(a|all|언제나|항상)\s*$') {
      $answerA = $true
      $saved = $true
      if (-not [string]::IsNullOrWhiteSpace($PolicyKey)) { $saved = Set-CfgBool -Key $PolicyKey -Value $true }
      if ($saved) {
        Write-Host (L '  → A: 앞으로 이 항목은 묻지 않고 자동 삭제합니다. (설정에 저장됨)' '  -> A: this item will be deleted automatically from now on (saved).')
      } else {
        Write-Host (L '  → A: 설정 저장에 실패했지만 이번 실행에서는 삭제합니다.' '  -> A: could not save the setting, but deleting this run anyway.')
      }
      $decision = 'yes'
    } elseif ("$ans" -match '^\s*(y|yes|예|ㅇ|1)\s*$') {
      $decision = 'yes'   # Y = 현재만. 설정은 바꾸지 않는다.
    } else {
      $decision = 'no'
    }
  }

  $decisionText = switch ($decision) {
    'yes'  {
      if ($always) { L '지움 (A — 설정에 기억된 자동 삭제)' 'Deleted (A - remembered auto-delete)' }
      elseif ($answerA) { L '지움 (A — 언제나 삭제 선택)' 'Deleted (A - always delete chosen)' }
      else { L '지움 (Y — 현재만 삭제)' 'Deleted (Y - this time only)' }
    }
    'no'   { L '그대로 둠 (N — 거부)' 'Left as-is (N - rejected)' }
    default { L '그대로 둠 (자동 실행 — 물어볼 사람이 없어 보류)' 'Left as-is (automatic run - nobody to ask, deferred)' }
  }

  # --- 실행 ---
  if ($decision -eq 'yes') {
    if ($DeleteAction) {
      try { & $DeleteAction } catch { Write-LogEntry "Delete Review: WARN - $Target 삭제 중 오류: $($_.Exception.Message)" }
    }
  }

  # --- 복구용 전체 목록 파일 (2026-11-13) ---
  #   사용자 요청: "삭제한 파일의 폴더 경로까지 남아야 복구할 수 있다. 결과 txt 에도 있어야 한다."
  #   y 를 눌러 실제로 지운 경우 logs\deleted-<시각>.txt 에 전체 경로를 탭 구분으로 남긴다.
  #   (현장에서 복구 도구(Recuva/PhotoRec/winfr)에 그대로 붙여넣을 수 있게 하기 위함)
  $deletedFile = ''
  if ($decision -eq 'yes') {
    try {
      if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
      $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
      $deletedFile = Join-Path $logDir ("deleted-$stamp.txt")
      $dup = 2
      while (Test-Path -LiteralPath $deletedFile) {
        $deletedFile = Join-Path $logDir ("deleted-$stamp-$dup.txt")
        $dup++
      }
      $buf = New-Object System.Collections.Generic.List[string]
      $buf.Add('# 자동 유지보수 — 실제로 삭제한 파일 전체 목록 (복구용)')
      $buf.Add('# 삭제 시각: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
      $buf.Add('# 대상: ' + $Target)
      $buf.Add(('# 개수 / 용량: ' + $list.Count + '개 / ' + $sizeText))
      foreach ($nt in @($Notice)) { if (-not [string]::IsNullOrWhiteSpace($nt)) { $buf.Add('# 안내: ' + $nt) } }
      $buf.Add('#')
      $buf.Add('# 전체경로' + "`t" + '크기(바이트)' + "`t" + '수정/삭제일')
      foreach ($pth in $paths) {
        $line = ([string]$pth.path) + "`t" + ([string]$pth.size) + "`t" + ([string]$pth.date)
        $buf.Add($line)
      }
      if ($pathsMore -gt 0) { $buf.Add(('# ... 외 ' + $pathsMore + '개 (파일 기록 한도 ' + $pathLimit + '개 초과)')) }
      [IO.File]::WriteAllLines($deletedFile, $buf, (New-Object System.Text.UTF8Encoding($true)))
    } catch {
      Write-LogEntry "Delete Review: WARN - 삭제 목록 파일을 만들지 못했습니다: $($_.Exception.Message)"
      $deletedFile = ''
    }
  }

  # --- 기록(로그 + 리포트 + last-result.json) ---
  Write-LogEntry ("Delete Review: {0} - {1}개 / {2} → {3}" -f $Target, $list.Count, $sizeText, $decisionText)
  foreach ($n in @($Notice)) { if (-not [string]::IsNullOrWhiteSpace($n)) { try { Add-Content -Path $logPath -Value "    $n" -Encoding UTF8 } catch { } } }
  # 로그에는 화면(20개)이 아니라 전체 경로를 남긴다 — 나중에 복구할 때 필요하다.
  foreach ($pth in $paths) {
    $logLine = "    · " + [string]$pth.path + " (" + (Format-ByteSize ([double]$pth.size)) + ", " + [string]$pth.date + ")"
    try { Add-Content -Path $logPath -Value $logLine -Encoding UTF8 } catch { }
  }
  if ($pathsMore -gt 0) { try { Add-Content -Path $logPath -Value "    · ... 외 $pathsMore 개 (기록 한도 ${pathLimit}개 초과)" -Encoding UTF8 } catch { } }
  if ($deletedFile) { try { Add-Content -Path $logPath -Value "    → 삭제 기록 파일: $deletedFile" -Encoding UTF8 } catch { } }

  $entry = [ordered]@{
    target       = $Target
    count        = $list.Count
    size         = $sizeText
    decision     = $decision
    decisionText = $decisionText
    notice       = @($Notice)
    paths        = @($paths)
    pathsMore    = $pathsMore
    deletedFile  = $deletedFile
    shown        = @($preview)
    more         = $moreCount
  }
  if ($null -eq $script:deleteReview) { $script:deleteReview = @() }
  $script:deleteReview = @($script:deleteReview) + @($entry)

  if ($decision -eq 'deferred') {
    $script:recommendations += ("[삭제 보류] {0} {1}개 ({2}) — 바탕화면 '자동 유지보수 점검'을 실행하면 목록을 보여주고 지울지 물어봅니다." -f $Target, $list.Count, $sizeText)
  }

  return ($decision -eq 'yes')
}

# ============================================================
# 임시 폴더 자동 정리 안전 가드 (2026-11-12 실제 사고 대응)
#
#   사고: 배포받은 PC 의 TEMP/TMP 가 드라이브 루트(I:\)로 설정되어 있었다.
#         디스크 부족 판정이 나자 "임시 폴더 = I:\" 로 보고 그 드라이브의 사진/문서를 전부 지웠다.
#   원인: (1) 드라이브 루트여도 검사 없이 -Recurse 로 전부 삭제
#         (2) 오늘 만든 파일도 삭제(나이 제한 없음)
#         (3) 어느 드라이브가 부족하든 "전역" tempDirs 를 지움(부족한 드라이브와 무관)
#         (4) 배포본에는 확인 프롬프트 자체가 없었음
#   → 아래 4가지를 코드로 막는다.
# ============================================================
function Get-ProtectedPathList {
  $list = @()
  foreach ($n in @('Desktop', 'MyDocuments', 'MyPictures', 'MyVideos', 'MyMusic', 'UserProfile')) {
    try { $p = [Environment]::GetFolderPath($n); if (-not [string]::IsNullOrWhiteSpace($p)) { $list += $p } } catch { }
  }
  #   SystemDrive('C:') 는 넣지 않는다 — 드라이브 루트는 Test-SafeTempDir 의 루트 검사에서 따로 막고,
  #   여기에 넣으면 C:\Temp 같은 정상 임시 폴더까지 전부 거부된다.
  $extra = @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\OneDrive", "$env:USERPROFILE\Dropbox",
             "$env:USERPROFILE\Google Drive", "$env:USERPROFILE\Documents", "$env:USERPROFILE\Pictures",
             "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Videos", "$env:USERPROFILE\Music", "$env:USERPROFILE\Favorites",
             $env:USERPROFILE, $env:windir, $env:ProgramFiles, $env:ProgramData, $scriptRoot)
  foreach ($p in $extra) { if (-not [string]::IsNullOrWhiteSpace($p)) { $list += $p } }
  try { $pf86 = ${env:ProgramFiles(x86)}; if (-not [string]::IsNullOrWhiteSpace($pf86)) { $list += $pf86 } } catch { }
  $out = @()
  foreach ($p in $list) {
    try { $out += ([IO.Path]::GetFullPath($p).TrimEnd('\')) } catch { }
  }
  #   드라이브 문자 하나짜리(GetFullPath 가 'C:' 로 남기는 경우)는 제외 — 상위 전체를 막아버린다.
  return @($out | Where-Object { $_ -match '^[A-Za-z]:\\' } | Sort-Object -Unique)
}

# 경로가 "지워도 되는 임시 폴더"인지 검사한다. Ok=false 면 절대 지우지 않는다.
#   -Explicit : 사용자가 config.json 에 직접 적은 경로(기본값이 아님) → 이름 규칙은 완화, 루트/보호폴더는 그대로 금지
function Test-SafeTempDir {
  param([string]$Path, [switch]$Explicit)
  $res = [pscustomobject]@{ Path = $Path; Ok = $false; Reason = '' }
  if ([string]::IsNullOrWhiteSpace($Path)) { $res.Reason = '빈 경로'; return $res }
  $norm = $null
  try { $norm = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { $res.Reason = '경로 해석 실패'; return $res }
  $res.Path = $norm

  # (1) 드라이브 루트는 절대 금지 — 이번 사고의 직접 원인
  $root = ''
  try { $root = [IO.Path]::GetPathRoot($norm) } catch { }
  if ([string]::IsNullOrWhiteSpace($root)) { $res.Reason = '드라이브 문자 없음'; return $res }
  if ($norm -ieq $root.TrimEnd('\')) { $res.Reason = "드라이브 루트($root)는 정리 대상이 될 수 없음"; return $res }

  $leaf = ''
  try { $leaf = Split-Path $norm -Leaf } catch { }
  if ([string]::IsNullOrWhiteSpace($leaf)) { $res.Reason = '폴더 이름이 없음'; return $res }

  # (2) Windows\Temp 는 항상 허용
  $winTemp = ''
  try { $winTemp = [IO.Path]::GetFullPath("$env:windir\Temp").TrimEnd('\') } catch { }
  $underWinTemp = (-not [string]::IsNullOrWhiteSpace($winTemp)) -and
                  ($norm -ieq $winTemp -or $norm.StartsWith($winTemp + '\', 'OrdinalIgnoreCase'))
  if ($underWinTemp) { $res.Ok = $true; return $res }

  # (3) 임시 폴더처럼 보이는 이름인지 (기본 설정에만 적용 — 명시 설정은 사용자 의도로 본다)
  $underAppDataTemp = $norm -match '(?i)\\AppData\\Local\\Temp(\\|$)'
  $tempish = $leaf -match '(?i)^(temp|tmp|cache|caches|crashdumps|d3dscache|.*[_-]temp|temp[_-].*|tmp[_-].*)'
  if (-not ($underAppDataTemp -or $tempish) -and -not $Explicit) {
    $res.Reason = "이름이 임시 폴더가 아님($leaf) — 사진/문서 폴더로 의심됨"
    return $res
  }

  # (4) 사용자 데이터 폴더는 절대 금지 (AppData\Local\Temp 만 예외)
  foreach ($p in (Get-ProtectedPathList)) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if ($norm -ieq $p) { $res.Reason = "보호된 폴더($p)"; return $res }
    if ($norm.StartsWith($p + '\', 'OrdinalIgnoreCase')) {
      if ($underAppDataTemp) { continue }
      $res.Reason = "사용자 데이터 폴더 하위($p)"
      return $res
    }
  }

  $res.Ok = $true
  return $res
}

# 임시 폴더 안의 파일 목록을 구한다.
#   Get-ChildItem -Recurse 는 정션/심볼릭 링크(디렉터리)를 따라가서 **다른 드라이브의 실제 파일**까지
#   목록에 넣는다. 그 상태로 Remove-Item 하면 링크 대상(사진 폴더 등)이 지워진다.
#   → 링크 디렉터리는 건너뛰고 직접 순회한다.
function Get-FilesNoReparse {
  param([Parameter(Mandatory = $true)][string]$Root)
  $out = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $Root)) { return @() }
  $stack = New-Object System.Collections.Stack
  $stack.Push($Root)
  $seen = 0
  while ($stack.Count -gt 0 -and $seen -lt 20000) {
    $seen++
    $cur = [string]$stack.Pop()
    try { $children = @(Get-ChildItem -LiteralPath $cur -Force -ErrorAction Stop) } catch { continue }
    foreach ($c in $children) {
      if ($c.PSIsContainer) {
        $isLink = (($c.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        if (-not $isLink) { $stack.Push($c.FullName) }
      } else {
        [void]$out.Add($c)
      }
    }
  }
  return @($out)
}

# === util.ps1에서 인라인화된 유틸리티 함수들 ===

# 사용자 입력 없이 경과된 유휴 시간(초) 반환 (System.Windows.Forms 사용, csc.exe 호출 없음)
function Get-IdleTimeSeconds {
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    return [int][Math]::Floor([System.Windows.Forms.SystemInformation]::IdleTime.TotalSeconds)
  } catch {
    return 0
  }
}

# 바탕화면 결과 txt 가 너무 많이 쌓이지 않게 정리한다 (2026-11-17, v1.3.0 / v1.4.0 사용자 요청).
#   "바탕화면에 결과 파일이 4개 이상 되면 '자동점검결과' 폴더를 만들어 자동으로 안에 넣어달라."
#   "최신 1개도 폴더 안으로 정리하고" (2026-11-17 v1.4.0)
#   - 이번에 만들 파일까지 합쳐 Threshold(기본 4)개 이상이 되면 동작한다.
#   - 기존 결과 파일을 **전부**(최신 것 포함) '자동점검결과' 폴더로 **이동**한다.
#     → 이번 실행에서 새로 만들어지는 결과 1개만 바탕화면에 남는다.
#   - 지우지 않는다(안전·가역). 3개월(기본 90일) 지난 파일은 Remove-OldResultFiles 가 자동 삭제한다.
function Move-OldDesktopReports {
  param(
    [string]$DesktopPath,
    [int]$Threshold = 4,
    [int]$IncomingCount = 1,
    [string]$FolderName = $script:resultFolderName
  )
  $info = [pscustomobject]@{ Folder = ''; Moved = 0; Paths = @(); Error = '' }
  if ([string]::IsNullOrWhiteSpace($DesktopPath) -or -not (Test-Path -LiteralPath $DesktopPath)) {
    $info.Error = 'desktop not found'
    return $info
  }
  $files = @()
  foreach ($pat in $script:resultFilePatterns) {
    $files += @(Get-ChildItem -LiteralPath $DesktopPath -Filter $pat -File -ErrorAction SilentlyContinue)
  }
  if ($files.Count -eq 0) { return $info }
  # 최신이 맨 앞. (같은 분에 두 개가 생기면 이름 기준으로 안정 정렬)
  $files = @($files | Sort-Object -Property @{ Expression = { $_.LastWriteTime } }, @{ Expression = { $_.Name } } -Descending)
  if (($files.Count + $IncomingCount) -lt $Threshold) { return $info }

  $folder = Join-Path $DesktopPath $FolderName
  if (Test-Path -LiteralPath $folder -PathType Leaf) {
    $info.Error = "path exists as a file: $folder"
    return $info
  }
  if (-not (Test-Path -LiteralPath $folder)) {
    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
  }
  $info.Folder = $folder

  $movedPaths = @()
  # 2026-11-17 (v1.4.0): 최신 1개도 남기지 않고 **전부** 폴더로 옮긴다(사용자 요청).
  foreach ($f in $files) {
    # 같은 이름이 이미 폴더에 있으면(예: 같은 분에 두 번 실행) 초 단위 시각을 붙여 덮어쓰지 않는다.
    $dest = Join-Path $folder $f.Name
    if (Test-Path -LiteralPath $dest) {
      $dest = Join-Path $folder ($f.BaseName + '_' + $f.LastWriteTime.ToString('yyyyMMdd_HHmmss') + $f.Extension)
    }
    try {
      Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop
      $movedPaths += [string]$dest
    } catch {
      $info.Error = $_.Exception.Message
    }
  }
  $info.Paths = @($movedPaths)
  $info.Moved = $movedPaths.Count
  return $info
}

# 3개월(기본 90일) 이상 지난 결과 파일을 **자동 삭제**한다 (2026-11-17, v1.4.0 사용자 요청).
#   "날짜상 3개월 이상 지난 결과 파일은 자동삭제하고"
#   - 지우는 대상은 이 키트가 만든 결과 txt 뿐이다(자동유지보수_*.txt, MaintenanceReport_*.txt, auto-maintenance_*.txt).
#     사용자가 만든 다른 파일·폴더는 절대 건드리지 않는다.
#   - 검색 위치: 바탕화면 + 그 안의 '자동점검결과' 폴더(하위 폴더는 보지 않는다).
#   - 삭제한 파일의 전체 경로·크기·날짜를 돌려줘서 결과 txt / 로그 / last-result.json 에 남긴다(복구 확인용).
function Remove-OldResultFiles {
  param(
    [string]$DesktopPath,
    [int]$RetentionDays = 90,
    [string]$FolderName = $script:resultFolderName
  )
  $info = [pscustomobject]@{ Deleted = 0; Bytes = 0; Paths = @(); Items = @(); Error = '' }
  if ([string]::IsNullOrWhiteSpace($DesktopPath) -or -not (Test-Path -LiteralPath $DesktopPath)) {
    $info.Error = 'desktop not found'
    return $info
  }
  if ($RetentionDays -le 0) { return $info }   # 0 이하 = 자동 삭제 끄기
  $cutoff = (Get-Date).AddDays(-$RetentionDays)
  $deletedPaths = @()
  $deletedItems = @()
  $bytes = 0.0
  foreach ($dir in @($DesktopPath, (Join-Path $DesktopPath $FolderName))) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    foreach ($pat in $script:resultFilePatterns) {
      $old = @(Get-ChildItem -LiteralPath $dir -Filter $pat -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })
      foreach ($of in $old) {
        try {
          $ofSize = [double]$of.Length
          Remove-Item -LiteralPath $of.FullName -Force -ErrorAction Stop
          $deletedPaths += [string]$of.FullName
          $deletedItems += [pscustomobject]@{ Name = $of.FullName; Size = $ofSize; Date = $of.LastWriteTime }
          $bytes += $ofSize
        } catch {
          $info.Error = $_.Exception.Message
        }
      }
    }
  }
  $info.Paths = @($deletedPaths)
  $info.Items = @($deletedItems)
  $info.Deleted = $deletedPaths.Count
  $info.Bytes = $bytes
  return $info
}

# 오래된 로그 파일 삭제 (지정 일수보다 오래된 maintain-*.log)
function Clear-OldLogs {
  param([int]$DaysToKeep = 7, [string]$Dir = $logDir)
  if (-not (Test-Path -LiteralPath $Dir)) { return }
  $cutoff = (Get-Date).AddDays(-$DaysToKeep)
  Get-ChildItem -Path $Dir -File -Filter 'maintain-*.log' | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force -ErrorAction SilentlyContinue
  # 삭제 기록(deleted-*.txt)은 복구에 필요하므로 로그 보관기간과 무관하게 최소 30일은 남긴다(2026-11-13).
  $delKeepDays = [Math]::Max($DaysToKeep, 30)
  $delCutoff = (Get-Date).AddDays(-$delKeepDays)
  Get-ChildItem -Path $Dir -File -Filter 'deleted-*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $delCutoff } | Remove-Item -Force -ErrorAction SilentlyContinue
  # 단일 로그 파일이 10MB 초과 시 새 파일로 분리
  $logFile = Get-ChildItem -Path $Dir -File -Filter 'maintain-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($logFile -and $logFile.Length -gt 10MB) {
    $newName = $logFile.BaseName + "_$(Get-Date -Format 'HHmmss')" + $logFile.Extension
    Rename-Item -Path $logFile.FullName -NewName $newName -Force -ErrorAction SilentlyContinue
  }
}

# 마지막 "완료된" 실행까지 경과 시간(시간). 기록이 없으면 $null.
#   .last_run 우선, 없으면 오늘 실행 중인 로그($logPath)를 제외한 가장 최근 로그를 사용.
#   (기존 구현은 자기 자신이 방금 만든 로그를 "마지막 실행"으로 읽어 scheduled 실행이 항상 SKIP 되었음)
function Get-LastRunHours {
  if (Test-Path -LiteralPath $lastRunFile) {
    try {
      $stamp = (Get-Content -LiteralPath $lastRunFile -Raw -ErrorAction Stop).Trim()
      if ($stamp) { return ((Get-Date) - [datetime]::Parse($stamp)).TotalHours }
    } catch { }
  }
  $prev = Get-ChildItem -Path $logDir -File -Filter 'maintain-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $logPath } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($prev) { return ((Get-Date) - $prev.LastWriteTime).TotalHours }
  return $null
}

# 정상 완료 시 마지막 실행 시각 기록
function Set-LastRunStamp {
  try { (Get-Date).ToString('o') | Set-Content -LiteralPath $lastRunFile -Encoding UTF8 -NoNewline -ErrorAction Stop } catch { }
}

# --- 범용 상태 파일(JSON) 읽기/쓰기 ---
# 검사 결과를 다음 실행과 비교하기 위한 최소 상태 저장. 손상된 파일은 조용히 무시(다음 실행에서 재생성).
function Get-JsonState {
  param([string]$Path)
  $state = @{}
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $state }
  try {
    $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $obj.PSObject.Properties) { $state[$prop.Name] = $prop.Value }
  } catch { }
  return $state
}
function Save-JsonState {
  param([string]$Path, $State)
  try { $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop } catch { }
}

# 단일 시각 타임스탬프(.last_heavy 등). 없거나 깨졌으면 $null
function Get-StampDate {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return [datetime]::Parse((Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()) } catch { return $null }
}
function Set-StampDate {
  param([string]$Path)
  try { (Get-Date).ToString('o') | Set-Content -LiteralPath $Path -Encoding UTF8 -NoNewline -ErrorAction Stop } catch { }
}

# 마지막 실행 후 Days일이 지났는가? (기록 없음 = 실행, Days<=0 = 항상 실행)
function Test-DueByDays {
  param($Last, [int]$Days)
  if ($Days -le 0) { return $true }
  if ($null -eq $Last) { return $true }
  return (((Get-Date) - $Last).TotalDays -ge $Days)
}

# FAIL 알림용 토스트 (Windows PowerShell 5.1 + WinRT). 실패하면 조용히 무시하고 로그만 남긴다.
#   배경: 데스크톱 리포트는 7일 후 삭제되고, 실행 중에는 아무도 화면을 보지 않으므로
#         "FAIL 이 있었다"는 사실이 사용자에게 전달되지 않았다.
function Show-ToastNotification {
  param([string]$Title, [string]$Body)
  try {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $t = [System.Security.SecurityElement]::Escape($Title)
    $b = [System.Security.SecurityElement]::Escape($Body)
    $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual></toast>")
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    return $true
  } catch { return $false }
}

# 네트워크 인터페이스 메트릭 우선순위 적용: 0 = 가장 빠른 "유선", 나머지 = 속도 내림차순 (0,1,2,3...)
#   - 규칙(2026-11-10, 사용자 확정):
#       1) 유선이 하나라도 연결돼 있으면 **가장 빠른 유선이 무조건 0순위**(Wi-Fi가 더 빨라도 유선 우선)
#       2) 나머지(나머지 유선 + 모든 Wi-Fi)는 **실측 링크 속도 내림차순**
#       3) 유선이 하나도 없으면 연결된 것 전체를 속도순으로
#   - 같은 값(동률)이면 경로 선택이 비결정적이 되므로 순위를 반드시 다르게 유지 (동률은 유선→무선→이름 순으로 깸)
#   - 연결 안 된 어댑터는 속도를 알 수 없으므로(0 bps) 뒤 순위로 밀어 둔다 → 다시 연결되면 다음 실행/부팅 태스크에서 재정렬
#   - WlanSvc 재시작, netsh int ip reset 등은 Windows가 Wi-Fi를 AutomaticMetric(35 등)으로
#     되돌려 순위를 초기화함(실측 확인) → Auto-Heal 이후 다시 호출한다
#   - 부팅 태스크 C:\ProgramData\FixNetworkMetric.ps1 도 "같은 규칙"을 쓴다(한쪽만 바꾸면 churn 재발)
#   - 반환값: 실제로 변경한 어댑터 수
function Set-NetworkMetricPriority {
  param([switch]$Quiet)

  $vpnKeywords = @('VPN', 'Tunnel', 'OpenVPN', 'WireGuard', 'VPN Tunnel', 'Wintun', 'NordVPN', 'ExpressVPN', 'ProtonVPN', 'Surfshark')
  $changed = 0

  # netsh로 현재 메트릭 조회: Get-NetIPInterface 는 메트릭 0 을 $null 로 돌려주는 버그가 있어 판정에 못 씀
  $metricMap = @{}
  foreach ($line in (& netsh.exe interface ipv4 show interfaces 2>&1)) {
    if ("$line" -match '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+)$') {
      $metricMap[[int]$Matches[1]] = [int]$Matches[2]
    }
  }

  # 블루투스 PAN/루프백/가상 어댑터 제외, 유선(14)·무선(9) 어댑터는 연결 여부와 무관하게 대상
  $targetAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
    $_.NdisPhysicalMedium -in @(9, 14) -and $_.Name -notmatch '(?i)bluetooth|loopback'
  }
  if (-not $targetAdapters) {
    if (-not $Quiet) { Write-LogEntry 'Network Metrics: SKIP - No Ethernet/WiFi adapter found' }
    return 0
  }

  # VPN 어댑터가 있으면 경로 보존을 위해 건드리지 않음
  $vpnActive = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -match ($vpnKeywords -join '|')) -or ($_.InterfaceDescription -match ($vpnKeywords -join '|'))
  }
  if ($vpnActive) {
    if (-not $Quiet) { Write-LogEntry "Network Metrics: SKIP - VPN adapter detected ($($vpnActive.Name -join ', ')), skipping metric change to preserve routing" }
    return 0
  }

  # --- 순위 계산(2026-11-10 확정) ---
  #   0순위 = 가장 빠른 유선(연결된 것 중). 유선이 없으면 전체 속도순으로 0.
  #   나머지 = 나머지 유선 + 모든 Wi-Fi 를 속도 내림차순. 미연결 어댑터는 맨 뒤.
  $sortBySpeed = @(
    @{ Expression = { [double]$_.Speed }; Descending = $true },
    @{ Expression = { if ($_.NdisPhysicalMedium -eq 14) { 0 } else { 1 } } },
    @{ Expression = { $_.Name } }
  )
  $upAdapters = @($targetAdapters | Where-Object { $_.Status -eq 'Up' })
  $downAdapters = @($targetAdapters | Where-Object { $_.Status -ne 'Up' } |
    Sort-Object -Property @(
      @{ Expression = { if ($_.NdisPhysicalMedium -eq 14) { 0 } else { 1 } } },
      @{ Expression = { $_.Name } }
    ))

  $ranked = @()
  $wiredUp = @($upAdapters | Where-Object { $_.NdisPhysicalMedium -eq 14 } | Sort-Object -Property $sortBySpeed)
  if ($wiredUp.Count -gt 0) {
    $topWired = $wiredUp[0]
    $ranked += $topWired
    $topIdx = [int]$topWired.ifIndex
    $ranked += @($upAdapters | Where-Object { [int]$_.ifIndex -ne $topIdx } | Sort-Object -Property $sortBySpeed)
  } else {
    # 유선이 하나도 연결돼 있지 않으면 Wi-Fi 포함 전체를 속도순으로
    $ranked += @($upAdapters | Sort-Object -Property $sortBySpeed)
  }
  $ranked += $downAdapters

  # ifIndex → rank(0,1,2...) 매핑 + 로그용 요약("이더넷(1Gbps)=0")
  $metricPlanByIndex = @{}
  $planParts = @()
  for ($ri = 0; $ri -lt $ranked.Count; $ri++) {
    $ra = $ranked[$ri]
    $metricPlanByIndex[[int]$ra.ifIndex] = $ri
    $speedText = if ($ra.Status -ne 'Up') { '미연결' }
      elseif ([double]$ra.Speed -ge 1e9) { '{0:0.#}Gbps' -f ([double]$ra.Speed / 1e9) }
      elseif ([double]$ra.Speed -ge 1e6) { '{0:0.#}Mbps' -f ([double]$ra.Speed / 1e6) }
      else { '{0:0}Kbps' -f ([double]$ra.Speed / 1e3) }
    $planParts += "$($ra.Name)($speedText)=$ri"
  }
  if (-not $Quiet) { Write-LogEntry "Network Metrics: 순위(유선 최우선 → 나머지 속도순) - $($planParts -join ', ')" }

  foreach ($adapter in $ranked) {
    # 해시 키는 Int32 로 통일 (ifIndex 는 UInt32 → 타입이 달라 ContainsKey 가 항상 false)
    $idxKey = [int]$adapter.ifIndex
    $targetMetric = $metricPlanByIndex[$idxKey]
    $curMetric = if ($metricMap.ContainsKey($idxKey)) { $metricMap[$idxKey] } else { $null }
    $autoMetric = (Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).AutomaticMetric
    if ($curMetric -eq $targetMetric -and "$autoMetric" -eq 'Disabled') {
      if (-not $Quiet) { Write-LogEntry "Network Metrics ($($adapter.Name)): PASS - InterfaceMetric=$targetMetric, AutomaticMetric disabled" }
      continue
    }
    try {
      Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -InterfaceMetric $targetMetric -AutomaticMetric Disabled -ErrorAction Stop
      # 적용 결과를 netsh로 재확인 (Get-NetIPInterface 는 0 을 못 읽음)
      $verifyMap = @{}
      foreach ($line in (& netsh.exe interface ipv4 show interfaces 2>&1)) {
        if ("$line" -match '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+)$') { $verifyMap[[int]$Matches[1]] = [int]$Matches[2] }
      }
      $newMetric = if ($verifyMap.ContainsKey($idxKey)) { $verifyMap[$idxKey] } else { $null }
      if ($newMetric -eq $targetMetric) {
        $changed++
        Write-LogEntry "Network Metrics ($($adapter.Name)): CHANGE - Metric $(if ($null -eq $curMetric) { '?' } else { $curMetric })->$targetMetric, AutoMetric->disabled"
      } else {
        Write-LogEntry "Network Metrics ($($adapter.Name)): WARN - Metric 적용 실패 (요청 $targetMetric, 실제 $newMetric)"
        $script:failureReasons += "[Network] $($adapter.Name) 메트릭을 $targetMetric 로 설정하지 못했습니다 (현재 $newMetric)"
      }
    } catch {
      Write-LogEntry "Network Metrics ($($adapter.Name)): WARN - Metric 설정 실패: $($_.Exception.Message)"
      $script:failureReasons += "[Network] $($adapter.Name) 메트릭 설정 실패: $($_.Exception.Message)"
    }
  }
  return $changed
}

# 로그 파일에 메시지 추가 및 콘솔 출력 (테스트 진행도 바 포함)
function Write-LogEntry {
  param([string]$Message)
  $retries = 5; $delay = 200
  while ($retries -gt 0) {
    try { Add-Content -Path $logPath -Value $Message -Encoding UTF8 -ErrorAction Stop; $retries = 0 } catch {
      $retries--
      if ($retries -eq 0) { Write-Host "[LogWARN] 로그 파일 잠김 - 메시지 누락: $($Message.Substring(0,[Math]::Min(80,$Message.Length)))" }
      else { Start-Sleep -Milliseconds $delay }
    }
  }
  
  $result = $Message -replace '^[^:]+:\s*', ''
  $consoleMsg = $Message
  if ($Message -match ':\s*(PASS|SKIP)') { $consoleMsg = $Message -replace ':\s*(PASS|SKIP)\s*-\s*', ': ✓ ' }
  elseif ($Message -match ':\s*(WARN|FAIL|CRITICAL|CHANGE)') {
    $short = ($Message -split '-\s*', 2 | Select-Object -Last 1).Trim()
    if ($short -and $short -ne $Message) { $consoleMsg = "⚠ $short" } else { $consoleMsg = $Message }
  }
  
  if ($script:stepBarPending) {
    $script:stepBarPending = $false
    Write-Host "[$("#" * 15)] 100% ${script:stepName}: $result"
  } else {
    Write-Host "$consoleMsg"
  }
  
  # 맨 아래 2줄: 현재 세부 항목 + 전체 진행도 (커서 저장/복원)
  if ($script:progressTotal -gt 0 -and $script:stepName -and $Host.UI.RawUI -and -not [Console]::IsOutputRedirected) {
    try {
      $st = [Console]::CursorTop; $sl = [Console]::CursorLeft
      $bottom = [Console]::WindowTop + [Console]::WindowHeight - 1
      $p = [math]::Min(100, [math]::Round(($script:progressCurrent / $script:progressTotal) * 100))
      $f = [math]::Round(($p / 100) * 15)
      # Line bottom-1: 현재 작업 항목 (세부 진행률 포함)
      if ($bottom -ge 1) { [Console]::SetCursorPosition(0, $bottom - 1) } else { throw }
      $subInfo = if ($script:subTotal -gt 0 -and $script:subCurrent -ge 0) { " [$($script:subCurrent + 1)/$($script:subTotal)]" } else { "" }
       $lineContent = "▶ ${script:stepName}${subInfo}${script:subStep}  "
       Write-Host ($lineContent + " " * [math]::Max(0, [Console]::WindowWidth - $lineContent.Length - 1)) -NoNewline
      # Line bottom: 전체 진행도
      [Console]::SetCursorPosition(0, $bottom)
      Write-Host "진행도: [$("#" * $f)$("-" * (15 - $f))] ${p}%  " -NoNewline
      [Console]::SetCursorPosition($sl, $st)
    } catch { }
  }
}

# 자동 조치 기록 (2026-11-06): 검사에서 문제가 나왔을 때 실제로 수행한 조치를 남긴다.
#   - 로그에는 "FIX:" 로 기록되어 데스크톱 리포트/이벤트에도 그대로 남는다.
#   - last-result.json 의 autoFixes 배열에도 들어가므로 "무엇을 자동으로 고쳤는지" 추적 가능.
$script:autoFixes = @()
function Add-AutoFix {
  param([string]$Message)
  $script:autoFixes += $Message
  Write-LogEntry "FIX: $Message"
}

# 재부팅 보류 판정 — 한 곳으로 통일 (2026-11-15)
#   문제: 두 곳(초반 REBOOT 검사 / Updates 검사)이 각자 판정했고, 초반 검사는
#         `Get-ItemProperty '<키>\PendingFileRenameOperations'` 처럼 **값 경로**를 읽어
#         항상 $null 이 나왔다 → 같은 실행에서 `REBOOT: PASS` 와
#         `Updates: WARN - 재부팅 대기 중` 이 동시에 찍히는 모순(사용자 리포트 2026-11-15).
function Test-PendingReboot {
  $pending = $false
  $reasons = @()
  try {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
      $pending = $true; $reasons += 'CBS(구성 요소 서비스)'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
      $pending = $true; $reasons += 'Windows Update'
    }
    try {
      $pfro = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
      if ($pfro -and $pfro.PendingFileRenameOperations) {
        $pending = $true; $reasons += '파일 교체(PendingFileRename)'
      }
    } catch { }
  } catch { }
  return [pscustomobject]@{ Pending = $pending; Reasons = ($reasons -join ', ') }
}

# 광고/추천 설정 (2026-11-09): "무엇을 켜 두었는지"와 "이 기능으로 생길 수 있는 문제"를
#   last-result.json / 데스크톱 리포트 / run-now 콘솔에 함께 남기기 위한 전역 상태.
#   $recommendations(할 일 목록)에 섞지 않는다 — 매 실행 5줄씩 노이즈가 되기 때문.
$script:adStatus = [ordered]@{ quiet = 'off'; hosts = 'off'; dns = 'off'; changes = @() }
$script:adWarning = @()
$script:adBackupDir = Join-Path $scriptRoot 'adbackup'

# 테스트 헤더 (한국어 설명)를 콘솔과 로그에 기록 (진행바와 별개)
function Write-TestHeader {
  param([string]$Message)
  try { Add-Content -Path $logPath -Value $Message -Encoding UTF8 } catch { }
  Write-Host $Message
}

# 안전 종료: 잠금파일/Mutex 정리 후 메시지 출력 후 종료
function Exit-Maintenance {
  param([int]$ExitCode = 0, [string]$Message = '')
  if ($script:lockCreated) { Remove-Item -LiteralPath $lockFilePath -Force -ErrorAction SilentlyContinue }
  if ($script:mutex) { try { $script:mutex.ReleaseMutex(); $script:mutex.Dispose() } catch { } }
  if ($Message) { Write-Output $Message }
  exit $ExitCode
}

# --- 예상치 못한 오류 대비 (2026-11-14) ---
#   문제: 다른 PC 에서 점검이 중간에 죽으면 결과 txt 가 아예 생기지 않아
#         사용자는 "점검을 누르면 잠깐 되다가 프로그램이 꺼진다" 고만 느낀다.
#   → 어떤 이유로든 중단되면 '실패 리포트'를 데스크톱에 남기고 로그 경로를 알려준다.
trap {
  $errMsg = [string]$_.Exception.Message
  $errPos = ''
  try { $errPos = [string]$_.InvocationInfo.PositionMessage } catch { }
  try { Write-LogEntry "FATAL: $errMsg" } catch { }
  try {
    if ($errPos) { try { Add-Content -Path $logPath -Value $errPos -Encoding UTF8 } catch { } }
    $failDir = if (-not [string]::IsNullOrWhiteSpace($ReportTo)) { $ReportTo } else { [Environment]::GetFolderPath('Desktop') }
    if (-not [string]::IsNullOrWhiteSpace($failDir) -and (Test-Path -LiteralPath $failDir)) {
      $failFile = Join-Path $failDir ($script:resultFailPrefix + (Get-Date -Format 'yyyyMMdd_HHmm') + ".txt")
      $failLines = @()
      $failLines += L '================ 자동 유지보수 — 점검 중단 ================' '================ Auto Maintenance - Check Aborted ================'
      $failLines += ((L '실행: ' 'Run: ') + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
      $failLines += ((L '버전: ' 'Version: ') + $kitVersionText)
      $failLines += (L '점검이 끝나기 전에 오류로 중단되었습니다.' 'The check stopped due to an error before completion.')
      $failLines += ''
      $failLines += ((L '오류: ' 'Error: ') + $errMsg)
      if ($errPos) { $failLines += ((L '위치: ' 'Location: ') + $errPos) }
      $failLines += ''
      $failLines += L '로그 파일을 함께 보내주시면 원인을 확인할 수 있습니다:' 'Please send the log file as well so the cause can be identified:'
      $failLines += ('  ' + $logPath)
      $failLines += ''
      $failLines += L '※ 파일 삭제·설정 변경은 실행되지 않았습니다(중단됨).' 'NOTE: No files were deleted and no settings were changed (aborted).'
      $failLines | Out-File -LiteralPath $failFile -Encoding UTF8
      Write-Output (L "점검 중단 리포트: $failFile" "Aborted-check report: $failFile")
    }
  } catch {
    # 실패 리포트를 만들지 못한 경우에도 원인을 남긴다(진단용).
    try { Write-Output ((L '점검 중단 리포트 생성 실패: ' 'Failed to create aborted-check report: ') + [string]$_.Exception.Message) } catch { }
    try { Add-Content -Path $logPath -Value ("FATAL-REPORT: " + [string]$_.Exception.Message) -Encoding UTF8 } catch { }
  }
  Exit-Maintenance -ExitCode 1
}

# === auto_heal_and_continue.ps1에서 인라인화된 자동 치유 함수들 ===

# 미니덤프(.dmp) 바이너리 분석: 버그체크 코드(Stop Code) 추출
function Get-MinidumpBugcheck {
  param([string]$Path)
  try {
    $fs = [System.IO.File]::OpenRead($Path)
    $br = New-Object System.IO.BinaryReader($fs)
    try {
      $sig = $br.ReadUInt32()
      $code = 0; $p1 = 0; $p2 = 0; $p3 = 0; $p4 = 0
      $name = 'UNKNOWN'
      if ($sig -eq 0x504D444D) {
        # MDMP (minidump) format
        $null = $br.ReadUInt32()
        $numStreams = $br.ReadUInt32()
        $streamDirRva = $br.ReadUInt32()
        $br.BaseStream.Seek($streamDirRva, [System.IO.SeekOrigin]::Begin) | Out-Null
        for ($i = 0; $i -lt $numStreams; $i++) {
          $streamType = $br.ReadUInt32()
          $dataSize = $br.ReadUInt32()
          $rva = $br.ReadUInt32()
          if ($streamType -eq 7) { # SystemInfoStream
            $savedPos = $br.BaseStream.Position
            $br.BaseStream.Seek($rva + 36, [System.IO.SeekOrigin]::Begin) | Out-Null
            $code = $br.ReadUInt32()
            $p1 = $br.ReadUInt32(); $p2 = $br.ReadUInt32()
            $p3 = $br.ReadUInt32(); $p4 = $br.ReadUInt32()
            $br.BaseStream.Seek($savedPos, [System.IO.SeekOrigin]::Begin) | Out-Null
          }
        }
      } else {
        $sig8 = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4)) # skip next 4
        $br.BaseStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        $fullSig = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(8))
        if ($fullSig -eq 'PAGEDU64') {
          # PAGEDU64 (page file) format: BugCheckCode at 0x38, params as UInt64 at 0x40/0x48/0x50/0x58
          $br.BaseStream.Seek(0x38, [System.IO.SeekOrigin]::Begin) | Out-Null
          $code = $br.ReadUInt32()
          $br.BaseStream.Seek(0x40, [System.IO.SeekOrigin]::Begin) | Out-Null
          $p1 = $br.ReadUInt64()
          $p2 = $br.ReadUInt64()
          $p3 = $br.ReadUInt64()
          $p4 = $br.ReadUInt64()
        } else {
          return $null
        }
      }
      $name = switch ($code) {
        0x01     { 'APC_INDEX_MISMATCH' }; 0x0A { 'IRQL_NOT_LESS_OR_EQUAL' }
        0x19     { 'BAD_POOL_HEADER' }; 0x1A { 'MEMORY_MANAGEMENT' }
        0x1E     { 'KMODE_EXCEPTION_NOT_HANDLED' }; 0x24 { 'NTFS_FILE_SYSTEM' }
        0x3B     { 'SYSTEM_SERVICE_EXCEPTION' }; 0x44 { 'MULTIPLE_IRP_COMPLETE_REQUESTS' }
        0x4E     { 'PFN_LIST_CORRUPT' }; 0x4F { 'NDIS_INTERNAL_ERROR' }
        0x50     { 'PAGE_FAULT_IN_NONPAGED_AREA' }; 0x51 { 'REGISTRY_ERROR' }
        0x5A     { 'CRITICAL_SERVICE_FAILED' }
        0x73     { 'CONFIG_LIST_FAILED' }; 0x74 { 'BAD_SYSTEM_CONFIG_INFO' }
        0x76     { 'PROCESS_HAS_LOCKED_PAGES' }; 0x77 { 'KERNEL_STACK_INPAGE_ERROR' }
        0x79     { 'MISMATCHED_HAL' }; 0x7A { 'KERNEL_DATA_INPAGE_ERROR' }
        0x7B     { 'INACCESSIBLE_BOOT_DEVICE' }; 0x7E { 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED' }
        0x7F     { 'UNEXPECTED_KERNEL_MODE_TRAP' }; 0x80 { 'NMI_HARDWARE_FAILURE' }
        0x8E     { 'KERNEL_MODE_EXCEPTION_NOT_HANDLED' }
        0x9C     { 'MACHINE_CHECK_EXCEPTION' }; 0x9F { 'DRIVER_POWER_STATE_FAILURE' }
        0xA0     { 'INTERNAL_POWER_ERROR' }; 0xA5 { 'ACPI_BIOS_ERROR' }
        0xBE     { 'ATTEMPTED_WRITE_TO_READONLY_MEMORY' }
        0xC1     { 'SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION' }; 0xC2 { 'BAD_POOL_CALLER' }
        0xC4     { 'DRIVER_VERIFIER_DETECTED_VIOLATION' }; 0xC5 { 'DRIVER_CORRUPTED_EXPOOL' }
        0xCE     { 'DRIVER_UNLOADED_WITHOUT_CANCELLING_PENDING_OPERATIONS' }
        0xD1     { 'DRIVER_IRQL_NOT_LESS_OR_EQUAL' }
        0xD5     { 'DRIVER_PAGE_FAULT_IN_FREED_SPECIAL_POOL' }
        0xD8     { 'DRIVER_USED_EXCESSIVE_PTES' }
        0xE3     { 'RESOURCE_NOT_OWNED' }
        0xEA     { 'THREAD_STUCK_IN_DEVICE_DRIVER' }
        0xED     { 'IO_OBJECT_TERMINATION' }; 0xEF { 'CRITICAL_PROCESS_DIED' }
        0xF3     { 'DISORDERLY_SHUTDOWN' }; 0xF4 { 'CRITICAL_OBJECT_TERMINATION' }
        0xF7     { 'DRIVER_OVERRAN_STACK_BUFFER' }; 0xF9 { 'DRIVER_RETURNED_STATUS_REPARSE_FOR_VOLUME_OPEN' }
        0xFE     { 'BUGCODE_USB_DRIVER' }
        0x101    { 'CLOCK_WATCHDOG_TIMEOUT' }; 0x109 { 'CRITICAL_STRUCTURE_CORRUPTION' }
        0x10D    { 'WDF_VIOLATION' }; 0x10E { 'VIDEO_MEMORY_MANAGEMENT_INTERNAL' }
        0x116    { 'VIDEO_TDR_APPLICATION_BLOCKED' }; 0x119 { 'VIDEO_TDR_TIMEOUT_DETECTED' }
        0x11A    { 'EMULATOR_ACCESS_VIOLATION' }
        0x121    { 'DRIVER_VIOLATION' }; 0x124 { 'WHEA_UNCORRECTABLE_ERROR' }
        0x12B    { 'WORKER_THREAD_RETURNED_WITH_NON_DEFAULT_WORKQUEUE_TYPE' }
        0x133    { 'DPC_WATCHDOG_VIOLATION' }; 0x139 { 'KERNEL_SECURITY_CHECK_FAILURE' }
        0x141    { 'VIDEO_DXGKRNL_FATAL_ERROR' }; 0x142 { 'VIDEO_TDR_FAILURE' }
        0x1BC    { 'CRITICAL_PROCESS_DIED' }
        default { 'UNKNOWN' }
      }
      $max32 = [System.UInt64]0xFFFFFFFF
      $fmtP1 = if ($p1 -gt $max32) { '{0:X16}' -f $p1 } else { '{0:X8}' -f $p1 }
      $fmtP2 = if ($p2 -gt $max32) { '{0:X16}' -f $p2 } else { '{0:X8}' -f $p2 }
      $fmtP3 = if ($p3 -gt $max32) { '{0:X16}' -f $p3 } else { '{0:X8}' -f $p3 }
      $fmtP4 = if ($p4 -gt $max32) { '{0:X16}' -f $p4 } else { '{0:X8}' -f $p4 }
      return "BugCheck 0x$('{0:X8}' -f $code) ($name)  P1:0x${fmtP1} P2:0x${fmtP2} P3:0x${fmtP3} P4:0x${fmtP4}"
    } finally { $br.Dispose(); $fs.Dispose() }
  } catch { return $null }
}

# 가장 최근 유지보수 로그 파일 경로 반환
function Get-LatestLog {
  $files = @(Get-ChildItem -Path $logDir -Filter 'maintain-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  if ($files.Count -gt 0) { return $files[0].FullName } else { return $null }
}

# winget 소스 불안정 시 강제 리셋 시도, 실패하면 winget 비활성화
function Update-ConfigWingetDisabled {
  if (-not (Test-Path -LiteralPath $configPath)) { return }
  try {
    $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfg.winget -or $cfg.winget.enabled -eq $false) { return }
    $null = winget source reset --force 2>&1
    if ($LASTEXITCODE -eq 0) { return }
    $cfg.winget.enabled = $false
    $cfg | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $configPath -Encoding UTF8 -Force
  } catch { Write-LogEntry "Winget: FAIL - Reset failed: $_" }
}

# PSWindowsUpdate 모듈이 없으면 설치 (check 모드에서만 사용자 동의)
function Ensure-PSWindowsUpdateModule {
  if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    if ($Mode -ne 'check') { return }
    try {
      if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) { return }
      # 종량제 네트워크 감지: 데이터 절약 모드면 설치 스킵
      try {
        $metered = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.Metered -gt 1 }
        if ($metered) { Write-LogEntry "PSWindowsUpdate: SKIP - Metered network detected, skipping download"; return }
      } catch { }
      do { try { $resp = (Read-Host "PSWindowsUpdate 모듈이 필요합니다. 설치하시겠습니까? Y/N").ToUpper() } catch { $resp = $null } } while ($resp -notin @('Y','N'))
      if ($resp -ne 'Y') { return }
      $null = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
      Install-PackageProvider -Name NuGet -Force -ForceBootstrap -ErrorAction SilentlyContinue | Out-Null
      # 게시자 서명 검증을 유지한다(외부 PSGallery 모듈을 -SkipPublisherCheck 로 설치하지 않는다).
      # 실패하면 아래 catch 가 로그에 남기고, 기능은 건너뛴다(필수 기능 아님).
      Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -AllowClobber -ErrorAction SilentlyContinue
    } catch { Write-LogEntry "PSWindowsUpdate: FAIL - Install failed: $_" }
  }
}

# Gigabyte/Aorus/펌웨어/BIOS 등 문제성 드라이버 업데이트 숨김
function Hide-ProblematicDriverUpdates {
  $keywords = @('Gigabyte', 'Aorus', 'Firmware', 'BIOS', 'UEFI', 'Chipset')
  if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) { return }
  try {
    Import-Module PSWindowsUpdate -Force -ErrorAction Stop
    $drivers = Get-WindowsUpdate -Category 'Drivers' -ErrorAction SilentlyContinue
    if (-not $drivers) { return }
    $toHide = $drivers | Where-Object { $_.Title -match ($keywords -join '|') }
    foreach ($update in $toHide) { $update | Hide-WindowsUpdate -ErrorAction SilentlyContinue }
  } catch { Write-LogEntry "DriverHide: FAIL - Failed to hide problematic drivers: $_" }
}

# 2026-11-09: 대화형 설정 프롬프트(Invoke-SetupPrompts) 제거.
#   구버전은 첫 실행 때 Read-Host 로 "스케줄러에 등록할까요?" 를 물었지만, 이제 설치는
#   install.ps1 이 전담한다. 예약 실행(비대화형)에서 프롬프트가 뜨면 작업이 그대로 멈추므로
#   남겨두면 위험하다.

# === 로그 디렉토리 생성 (없을 경우) ===
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# === 관리자 권한 확인 및 자동 상승 (Set-NetIPInterface 등에 필요) ===
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host 'ADMIN: WARN - Not running as administrator. Requesting elevation...'
  # [Environment]::GetCommandLineArgs()[0] 은 외부에서 조작 가능한 프로세스 커맨드라인이다.
  # 스크립트 자신의 경로($PSCommandPath)만 신뢰하고, 인자는 배열로 분리해 안전하게 조인한다.
  $selfPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $PSCommandPath } else { $MyInvocation.MyCommand.Definition }
  if ($selfPath -match '\.ps1$') {
    Write-Host 'ADMIN: INFO - If elevation fails, run "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser" first.'
    $elevArgs = Join-CliArgs @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', $selfPath, '-Mode', $Mode)
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList $elevArgs
  } else {
    # 컴파일된 EXE 로 감싼 배포 형식 대비: 자기 실행 파일 경로만 넘긴다.
    Start-Process -FilePath $selfPath -Verb RunAs -ArgumentList (Join-CliArgs @('-Mode', $Mode))
  }
  exit 0
}
Write-LogEntry 'ADMIN: PASS - Running as administrator'
Write-LogEntry "VERSION: $kitVersionText"

# === 콘솔 창 표시/숨김 (2026-11-17 v1.3.0 개정) ===
#   규칙: "사람이 직접 실행하면 보인다. 자동 실행은 사용자가 자리에 없을 때(유휴)만 보인다."
#     - check 모드(직접 실행) / -PromptForDelete / -NoHideConsole(지금 점검·설치) → 무조건 보임
#     - 자동 실행 + -HideConsole  → 숨김 (래퍼가 "사용 중"으로 판단한 경우)
#     - 그 밖의 자동 실행(idle 모드 직접 호출 등) → idleConsoleMinutes(기본 5분) 이상 유휴면 보이게
#       (숨겨도 결과 txt·json·로그는 그대로 남는다 = 헤드리스)
#   ※ 2026-11-14 사고: -NoHideConsole 없이 숨기면 run-now.ps1 과 같은 콘솔을 쓰는 창까지 사라졌다.
#     → 수동 실행 플래그가 있으면 절대 숨기지 않는 규칙은 그대로 유지한다.
$idleConsoleMinutes = 5
$idleCfgValue = Get-Cfg 'idleConsoleMinutes'
if ($null -ne $idleCfgValue) {
  $idleParsed = 0
  if ([int]::TryParse([string]$idleCfgValue, [ref]$idleParsed)) { $idleConsoleMinutes = $idleParsed }
}
if ($idleConsoleMinutes -lt 0) { $idleConsoleMinutes = 5 }
$idleSecondsNow = Get-IdleTimeSeconds
$autoRun = ($Mode -ne 'check' -and -not $PromptForDelete)
$autoConsoleWanted = $false
if ($autoRun) {
  if ($idleConsoleMinutes -eq 0) { $autoConsoleWanted = $true }
  elseif ($idleSecondsNow -ge ($idleConsoleMinutes * 60)) { $autoConsoleWanted = $true }
}
$wantHide = $false
if ($autoRun -and -not $NoHideConsole) {
  if ($HideConsole) { $wantHide = $true } else { $wantHide = (-not $autoConsoleWanted) }
}

if ($wantHide) {
  try {
    Add-Type -Name NH -Namespace W -MemberDefinition '
      [DllImport("user32.dll")]
      public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
      [DllImport("kernel32.dll")]
      public static extern IntPtr GetConsoleWindow();
    '
    $null = [W.NH]::ShowWindow([W.NH]::GetConsoleWindow(), 0)
    Write-LogEntry ("CONSOLE: hidden (automatic run, user active - idle {0}s < {1}min)" -f $idleSecondsNow, $idleConsoleMinutes)
  } catch { Write-LogEntry "HideConsole: FAIL - $_" }
} elseif ($autoRun) {
  if ($NoHideConsole) {
    Write-LogEntry 'CONSOLE: keep visible (requested by caller)'
  } else {
    Write-LogEntry ("CONSOLE: keep visible (idle {0}min >= {1}min - user away)" -f [int][math]::Floor($idleSecondsNow / 60), $idleConsoleMinutes)
  }
} else {
  Write-LogEntry 'CONSOLE: keep visible (manual run)'
}

# === check 모드: 콘솔 창이 이미 있으면 제목 변경 (식별 용이) ===
if ($Mode -eq 'check') {
  try { [Console]::Title = "Maintenance Check" } catch { }
  $totalTests = 25
  Write-Output ''
  Write-Output '============================================'
  Write-Output ' 이 프로그램은 윈도우 자체 기능들과'
  Write-Output ' 마이크로소프트에서 제공하는 기능들을'
  Write-Output ' 추가로 다운로드해서 실행하는 일종의'
  Write-Output ' 기능 모음집입니다.'
  Write-Output ''
  Write-Output " 총 ${totalTests}가지 기능들을 실행하며 각 기능들은"
  Write-Output ' SSD 기능 테스트, 윈도우 무결성 테스트 등이'
  Write-Output ' 있으며 로그에 각 기능의 설명이 첨부되어있습니다.'
  Write-Output '============================================'
  Write-Output ''
}

# 이벤트 로그 소스 생성 (처음 한 번만)
try { New-EventLog -LogName Application -Source 'Maintenance' -ErrorAction SilentlyContinue } catch { }

# === 로그 시작 ===
$ts = (Get-Date).ToString('o')
Write-LogEntry "[${ts}] Starting maintenance (Mode: ${Mode})"

# Mutex 중복 실행 방지
try { $script:mutex = New-Object System.Threading.Mutex($false, 'Global\OpenCode-Maintenance') } catch { Write-LogEntry "MUTEX: Create failed - $_" }
if ($script:mutex) {
  try {
    $mutexAcquired = $script:mutex.WaitOne(0)
    if (-not $mutexAcquired) {
      Write-LogEntry "MUTEX: SKIP - Another instance is already running"
      Exit-Maintenance -Message "Another instance already running. Exiting."
    }
  } catch [System.Threading.AbandonedMutexException] {
    Write-LogEntry "MUTEX: Previous instance abandoned mutex, proceeding"
  } catch {
    Write-LogEntry "MUTEX: Check failed - $_ , proceeding"
    try { [System.Threading.Mutex]::Exit() } catch { }
  }
}

# 이벤트 로그 기록 (시작)
try { Write-EventLog -LogName Application -Source 'Maintenance' -EntryType Information -EventId 100 -Message "Maintenance started (Mode: ${Mode})" -ErrorAction SilentlyContinue } catch { }

# === 재부팅 보류(Pending Reboot) 확인 ===
#   2026-11-15: 판정을 Test-PendingReboot 로 통일(값 경로 오타로 항상 PASS 였던 버그 수정).
$pendingRebootInfo = Test-PendingReboot
if ($pendingRebootInfo.Pending) {
  Write-LogEntry ("REBOOT: WARN - Pending reboot detected ({0}). Some operations may not work correctly." -f $pendingRebootInfo.Reasons)
} else {
  Write-LogEntry 'REBOOT: PASS - No pending reboot'
}

# 모드별 프로세스 우선순위 조정
try {
  $pClass = switch ($Mode) { 'idle' { 'Idle' } 'scheduled' { 'BelowNormal' } 'check' { 'Normal' } }
  (Get-Process -Id $PID).PriorityClass = $pClass
  Write-LogEntry "PRIORITY: Set to $pClass (Mode: ${Mode})"
} catch { Write-LogEntry "PRIORITY: FAIL - $_" }

# 2026-11-09: 구버전의 "첫 실행 시 예약 작업 자동 등록"(OpenCode-Maintenance-Scheduled/-Idle,
#   SYSTEM 12h/1h 반복) 블록을 제거했다. 지금은 install.ps1 이 단일 작업
#   OpenCode-Maintenance(사용자 컨텍스트, 매일 04:00 + 로그온)를 등록/관리한다.
#   두 체계가 공존하면 같은 점검이 중복 실행되고, check 모드가 기존 작업을 지워버리는
#   부작용(registerTask=false 일 때 'OpenCode-Maintenance-*' 일괄 삭제)도 있었다.
#
# ============================================================
# 모드별 사전 검사 (Mode-Specific Pre-Checks)
# ============================================================

$script:lockCreated = $false

# --- scheduled 모드: 주기 확인 (로그 파일 LastWriteTime 기준) ---
if ($Mode -eq 'scheduled') {
  Clear-OldLogs -DaysToKeep (Get-Cfg 'logsRetentionDays')

  # 최초 실행 시 config.json 백업
  if ((Test-Path -LiteralPath $configPath) -and -not (Test-Path -LiteralPath "$configPath.bak")) {
    Copy-Item -LiteralPath $configPath -Destination "$configPath.bak" -Force
  }

  $cadenceHours = [double](Get-Cfg 'maintenanceCadenceHours')
  $elapsedHours = Get-LastRunHours
  # 허용오차: 이 검사의 기준점은 마지막 "완료" 시각(.last_run)이고, 호출자(status.json/태스크)는
  # 마지막 "시작" 시각을 쓴다. 두 기준점 차이(실행 소요시간) 때문에 주기 경계에 정확히 걸린
  # 호출이 한 번 더 SKIP 되는 것을 막기 위해 최대 2시간(주기의 10%)의 여유를 둔다.
  $cadenceSlackHours = [math]::Min(2.0, $cadenceHours * 0.1)
  $cadenceEffective = $cadenceHours - $cadenceSlackHours
  if ($SkipCadence) {
    Write-LogEntry 'CADENCE: PASS - 강제 실행(-SkipCadence)'
  } elseif ($null -ne $elapsedHours -and $elapsedHours -lt $cadenceEffective) {
    Write-LogEntry "CADENCE: SKIP - Last completed run was $([math]::Round($elapsedHours,2))h ago (cadence: ${cadenceHours}h, slack: $([math]::Round($cadenceSlackHours,2))h)"
    Exit-Maintenance -Message "Cadence not reached ($([math]::Round($elapsedHours,2))h < $([math]::Round($cadenceEffective,2))h). Skipping."
  } else {
    Write-LogEntry 'CADENCE: PASS - Proceeding with scheduled maintenance'
  }
}

# --- idle 모드: 실행 조건 판별 ---
if ($Mode -eq 'idle') {
  Clear-OldLogs -DaysToKeep (Get-Cfg 'logsRetentionDays')

  # 최초 실행 시 config.json 백업
  if ((Test-Path -LiteralPath $configPath) -and -not (Test-Path -LiteralPath "$configPath.bak")) {
    Copy-Item -LiteralPath $configPath -Destination "$configPath.bak" -Force
  }

  # 잠금파일 확인 (PID 기록 + 프로세스 생존 확인)
  if (Test-Path -LiteralPath $lockFilePath) {
    try {
      $oldPid = (Get-Content -LiteralPath $lockFilePath -ErrorAction Stop) -as [int]
      $procAlive = $false
      if ($oldPid -and $oldPid -gt 0) { $procAlive = (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) -ne $null }
      if ($procAlive) {
        Write-LogEntry "LOCK: SKIP - Already running (PID ${oldPid} still alive)"
        Exit-Maintenance -Message 'Maintenance already running. Skipping.'
      }
      Write-Output "Removing stale lock file (previous PID ${oldPid} no longer running)"
      Remove-Item -LiteralPath $lockFilePath -Force -ErrorAction Stop
    } catch {
      Write-LogEntry 'LOCK: SKIP - Could not check lock file'
      Exit-Maintenance -Message 'Could not check lock file. Skipping.'
    }
  }
  [System.IO.File]::WriteAllText($lockFilePath, [string]$PID)
  $script:lockCreated = $true

  # 공통: cadence 이내 재실행 금지 (마지막 "완료" 시각 기준)
  $cadenceHours = [double](Get-Cfg 'maintenanceCadenceHours')
  $elapsedHours = Get-LastRunHours
  # 허용오차: 이 검사의 기준점은 마지막 "완료" 시각(.last_run)이고, 호출자(status.json/태스크)는
  # 마지막 "시작" 시각을 쓴다. 두 기준점 차이(실행 소요시간) 때문에 주기 경계에 정확히 걸린
  # 호출이 한 번 더 SKIP 되는 것을 막기 위해 최대 2시간(주기의 10%)의 여유를 둔다.
  $cadenceSlackHours = [math]::Min(2.0, $cadenceHours * 0.1)
  $cadenceEffective = $cadenceHours - $cadenceSlackHours
  if ($null -ne $elapsedHours -and $elapsedHours -lt $cadenceEffective) {
    Write-LogEntry "CADENCE: SKIP - Last completed run was $([math]::Round($elapsedHours,2))h ago (cadence: ${cadenceHours}h, slack: $([math]::Round($cadenceSlackHours,2))h)"
    Exit-Maintenance -Message "Cadence not reached ($([math]::Round($elapsedHours,2))h < $([math]::Round($cadenceEffective,2))h). Skipping."
  }

  # 실행 조건 판별 (config에서 각 조건 활성화 여부 확인)
  $idleAutoEnabled = (Get-ConfigProp $config 'registerIdleAuto') -ne $false
  $cpuPromptEnabled = (Get-ConfigProp $config 'registerCpuPrompt') -ne $false
  $conditionMet = $false

  # 조건 1: 유휴시간 1시간 이상 → 자동 실행
  if ($idleAutoEnabled) {
    $idleTriggerSec = [int](Get-Cfg 'idleTriggerSeconds')
    $idleSec = Get-IdleTimeSeconds
    Write-LogEntry "IDLE: System idle for ${idleSec}s (threshold: ${idleTriggerSec}s)"

    if ($idleSec -ge $idleTriggerSec) {
      Write-LogEntry 'IDLE: PASS - Idle threshold reached (1h+), proceeding with maintenance'
      # GPU 사용률 검사 (추가 조건)
      if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        try {
          $gpuLines = nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader -ErrorAction Stop
          $maxUtil = ($gpuLines | ForEach-Object { [int](($_ -replace '%', '').Trim()) } | Measure-Object -Maximum).Maximum
          if ($maxUtil -gt 20) {
            Write-LogEntry "GPU: SKIP - Utilization at ${maxUtil}% (above 20%)"
            Exit-Maintenance -Message "GPU usage at ${maxUtil}%. Skipping."
          }
          Write-LogEntry "GPU: PASS - Utilization at ${maxUtil}%"
        } catch { Write-LogEntry 'GPU: SKIP - nvidia-smi error' }
      } else { Write-LogEntry 'GPU: SKIP - nvidia-smi not found' }
      $conditionMet = $true
    } else {
      Write-LogEntry "IDLE: Idle time not met (${idleSec}s < ${idleTriggerSec}s)"
    }
  } else {
    Write-LogEntry 'IDLE: Condition 1 disabled in config'
  }

  # 조건 2: CPU 사용률 30% 미만 20분 이상 → 사용자 확인 (조건 1이 이미 충족되면 skip)
  if ($cpuPromptEnabled -and -not $conditionMet) {
    $cpuLowTracker = Join-Path $scriptRoot '.cpu_low_since'
    $runFromCpu = $false

    try {
      $cpuSample = Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop
      $cpuNow = [Math]::Round($cpuSample.CounterSamples[0].CookedValue, 1)
      Write-LogEntry "CPU: Current usage at ${cpuNow}%"

      if ($cpuNow -lt 30) {
        $cpuLowSince = $null
        if (Test-Path -LiteralPath $cpuLowTracker) {
          $content = (Get-Content -LiteralPath $cpuLowTracker -Raw -ErrorAction SilentlyContinue)
          if ($content) { $cpuLowSince = $content.Trim() -as [DateTime] }
        }
        if (-not $cpuLowSince) {
          [System.IO.File]::WriteAllText($cpuLowTracker, (Get-Date).ToString('o'))
          Write-LogEntry "CPU: Below 30%, tracking started (will check after 20min)"
        } else {
          $cpuLowMinutes = ((Get-Date) - $cpuLowSince).TotalMinutes
          Write-LogEntry "CPU: Below 30% for $([Math]::Round($cpuLowMinutes,1))min"
          if ($cpuLowMinutes -ge 20) {
            # 20분 조건 충족 → 사용자 프롬프트
            $promptFlag = Join-Path $scriptRoot '.cpu_prompt_declined'
            $shouldPrompt = $true
            if (Test-Path -LiteralPath $promptFlag) {
              $declinedSince = (Get-Item -LiteralPath $promptFlag).LastWriteTime
              if (((Get-Date) - $declinedSince).TotalHours -lt 5) {
                Write-LogEntry "CPU: User declined within 5h, skipping prompt"
                $shouldPrompt = $false
              } else {
                Remove-Item -LiteralPath $promptFlag -Force -ErrorAction SilentlyContinue
              }
            }
            if ($shouldPrompt) {
              try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                $notify = New-Object System.Windows.Forms.NotifyIcon
                $notify.Icon = [System.Drawing.SystemIcons]::Information
                $notify.BalloonTipTitle = '시스템 유지보수'
                $notify.BalloonTipText = 'CPU 사용률이 낮아 유지보수를 실행할 수 있습니다.'
                $notify.Visible = $true
                $notify.ShowBalloonTip(5000)
                Start-Sleep -Milliseconds 500
                $result = [System.Windows.Forms.MessageBox]::Show(
                  '유지보수 스크립트를 실행하시겠습니까?',
                  '시스템 유지보수',
                  [System.Windows.Forms.MessageBoxButtons]::YesNo,
                  [System.Windows.Forms.MessageBoxIcon]::Question
                )
                $notify.Visible = $false
                $notify.Dispose()
                if ($result -eq 'Yes') {
                  Write-LogEntry 'CPU: User accepted, proceeding with maintenance'
                  $conditionMet = $true
                } else {
                  Write-LogEntry 'CPU: User declined, flagging 5h cooldown'
                  New-Item -Path $promptFlag -ItemType File -Force | Out-Null
                  Remove-Item -LiteralPath $cpuLowTracker -Force -ErrorAction SilentlyContinue
                }
              } catch {
                Write-LogEntry "CPU: Prompt error - $_"
              }
            }
          }
        }
      } else {
        if (Test-Path -LiteralPath $cpuLowTracker) {
          Remove-Item -LiteralPath $cpuLowTracker -Force -ErrorAction SilentlyContinue
          Write-LogEntry "CPU: Usage spiked to ${cpuNow}%, tracking reset"
        }
      }
    } catch {
      Write-LogEntry "CPU: Unable to measure CPU usage: $_"
    }

    if (-not $conditionMet) {
      Exit-Maintenance -Message 'Conditions not met. Skipping.'
    }
  }
}

# ============================================================
# 핵심 유지보수 검사 (Core Maintenance Checks)
# ============================================================

# 진행률 표시 (테스트명 옆 그래프 + 맨 아래 전체 진행도)
function Write-ProgressBar {
  param([string]$StepName)
  # 이전 단계 실행 시간 기록
  if ($script:stepName -and $script:executionStopwatch) {
    $elapsed = $script:executionStopwatch.Elapsed
    $null = $script:executionTimings.Add(@{ Step = $script:stepName; Time = $elapsed })
  }
  $script:progressCurrent++
  $script:stepBarPending = $true
  $script:interimLines = 0
  $script:stepName = $StepName
  $script:subCurrent = -1
  $script:subTotal = 0
  if ($script:executionStopwatch) { $script:executionStopwatch.Restart() }
}

# 긴 작업(SFC 등) 중간 출력용 (첫 호출 시 0% 헤더 자동 출력)
function Write-InterimLine {
  param([string]$Message)
  $first = ($script:interimLines -eq 0 -and $script:stepBarPending)
  if ($first) {
    Write-Host "▶ ${script:stepName}..."
  }
  if (-not $first -or $Message) {
    Write-Host "  $Message"
  }
  $script:interimLines++
}

# 인코딩을 지정하여 네이티브 명령어 실행 (시스템 OEM 코드 페이지 사용)
$script:oemEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)

function Invoke-NativeWithSpinner {
  param(
    [string]$FilePath,
    [string]$Arguments,
    [string]$Label,
    [int]$TimeoutMs = 120000
  )
  $enc = $script:oemEncoding
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $enc
  $psi.StandardErrorEncoding = $enc
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  $spinner = '|/-\'; $i = 0; $started = Get-Date
  # 출력이 파일/파이프로 리디렉션되면 [Console]::CursorTop 이 "핸들이 잘못되었습니다" 로 실패한다
  #   (스케줄 태스크는 콘솔이 있어 정상이지만, 리디렉션 실행/테스트에서 단계 전체가 실패했음)
  $spinnerLine = -1
  if (-not [Console]::IsOutputRedirected) {
    try { $spinnerLine = [Console]::CursorTop } catch { $spinnerLine = -1 }
  }
  while (-not $p.HasExited) {
    if ($spinnerLine -ge 0) {
      try { [Console]::SetCursorPosition(0, $spinnerLine); Write-Host "  ${Label} ing$($spinner[$i % $spinner.Length])   " -NoNewline } catch { Write-Host -NoNewline "`r  ${Label} ing$($spinner[$i % $spinner.Length])   " }
    }
    Start-Sleep -Milliseconds 200
    if (((Get-Date) - $started).TotalMilliseconds -gt $TimeoutMs) { $p.Kill(); break }
    $i++
  }
  $p.WaitForExit()
  $ec = $p.ExitCode
  $out = $outTask.Result
  $err = $errTask.Result
  $p.Dispose()
  if ($spinnerLine -ge 0) {
    try { [Console]::SetCursorPosition(0, $spinnerLine); Write-Host '                                            ' -NoNewline } catch { Write-Host -NoNewline "`r                                            " }
  }
  return @{ Output = if ($err) { $out + "`r`n" + $err } else { $out }; ExitCode = $ec }
}

# 여러 네이티브 명령어를 병렬 실행 (결합 스피너)
function Invoke-NativeParallel {
  param([array]$Commands, [int]$TimeoutMs = 300000)
  $enc = $script:oemEncoding
  $procs = @()
  foreach ($cmd in $Commands) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd.FilePath; $psi.Arguments = $cmd.Arguments
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $enc; $psi.StandardErrorEncoding = $enc; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $procs += @{ Process = $p; OutTask = $p.StandardOutput.ReadToEndAsync(); ErrTask = $p.StandardError.ReadToEndAsync(); Label = $cmd.Label; Name = $cmd.Name }
  }
  $spinner = '|/-\'; $i = 0; $started = Get-Date
  $remaining = { $procs | Where-Object { -not $_.Process.HasExited } }
  $spinnerLine = -1
  if (-not [Console]::IsOutputRedirected) {
    try { $spinnerLine = [Console]::CursorTop } catch { $spinnerLine = -1 }
  }
  while (@(& $remaining).Count -gt 0) {
    if ($spinnerLine -ge 0) {
      $labels = @(& $remaining | ForEach-Object { $_.Label }) -join ', '
      try { [Console]::SetCursorPosition(0, $spinnerLine); Write-Host "  [$labels] ing$($spinner[$i % $spinner.Length])   " -NoNewline } catch { Write-Host -NoNewline "`r  [$labels] ing$($spinner[$i % $spinner.Length])   " }
    }
    Start-Sleep -Milliseconds 200
    if (((Get-Date) - $started).TotalMilliseconds -gt $TimeoutMs) { $procs | Where-Object { -not $_.Process.HasExited } | ForEach-Object { $_.Process.Kill() }; break }
    $i++
  }
  $results = @{}
  foreach ($p in $procs) {
    $p.Process.WaitForExit()
    $out = $p.OutTask.Result; $err = $p.ErrTask.Result
    $results[$p.Name] = @{ Output = if ($err) { $out + "`r`n" + $err } else { $out }; ExitCode = $p.Process.ExitCode }
    $p.Process.Dispose()
  }
  if ($spinnerLine -ge 0) { try { [Console]::SetCursorPosition(0, $spinnerLine); Write-Host '                                            ' -NoNewline } catch { Write-Host -NoNewline "`r                                            " } }
  return $results
}

$allPass = $true                  # 전체 통과 여부
$failureReasons = @()             # 실패 사유 목록
$recommendations = @()            # 코드로 해결 불가능한 항목 권장 사항 목록

$diskThreshold = Get-Cfg 'diskThresholdGB'
# 부족 판단 기준(2026-11-13 사용자 지시):
#   "디스크 용량은 각 드라이브 용량의 10%를 기준으로 해. 일괄 100GB 로 하지 말고."
#   → 드라이브마다 **그 드라이브 용량의 10%** 를 기준으로 삼는다(1.86TB → 186GB, 4TB → 400GB).
#     설정값 diskThresholdGB 는 용량을 알 수 없는 드라이브(네트워크/가상)의 대체값으로만 쓴다.
if ($null -eq $diskThreshold -or [double]$diskThreshold -le 0) { $diskThreshold = 10 }

# OS 정보 캐싱 (여러 검사에서 재사용)
$osInfo = $null
try { $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }

# 물리 디스크 정보 캐싱 (SSD/SMART/Optimize에서 재사용)
$script:cachedDisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)

# --- OS 상태 확인 ---
Write-ProgressBar "OS"
Write-TestHeader "[OS] 운영체제 버전과 실행 상태를 확인합니다."
if ($osInfo) {
  Write-LogEntry "OS: PASS - $($osInfo.Caption)"
} else {
  Write-LogEntry 'OS: FAIL - Unable to retrieve OS info'
  $allPass = $false
  $failureReasons += '[OS] 운영체제 정보를 가져올 수 없음'
}

# 정품 인증 상태: 미인증이면 Windows Update(보안 패치)가 멈춘다.
#   실측 비용 주의(2026-11-08): SoftwareLicensingProduct 첫 조회는 sppsvc 기동 때문에 콜드 15s 안팎,
#   워밍 후 1.5s. 6일 주기마다 15s 를 쓰는 건 과하므로 `licenseCheckDays`(기본 30일)로 게이트한다.
#   인증 상태는 사용자가 개입하기 전엔 거의 변하지 않는 값이라 30일 지연은 실질 손실이 없다.
$licenseCheckDays = [int](Get-Cfg 'licenseCheckDays')
$licFlag = Join-Path $scriptRoot '.last_license'
$lastLic = Get-StampDate $licFlag
if (-not (Test-DueByDays $lastLic $licenseCheckDays)) {
  Write-LogEntry ("OS: SKIP - 정품 인증 gated ({0}d interval, last {1})" -f $licenseCheckDays, $lastLic.ToString('yyyy-MM-dd'))
} else {
  try {
    $winLic = @(Get-CimInstance SoftwareLicensingProduct `
      -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -Property Name, LicenseStatus -ErrorAction Stop)
    $licOk = @($winLic | Where-Object { $_.LicenseStatus -eq 1 }).Count -gt 0
    if ($licOk) {
      Write-LogEntry 'OS: PASS - Windows 정품 인증됨'
      Set-StampDate $licFlag
    } elseif ($winLic.Count -eq 0) {
      Write-LogEntry 'OS: SKIP - Windows 라이선스 정보 없음'
      Set-StampDate $licFlag
    } else {
      $licStatus = ($winLic | Select-Object -First 1).LicenseStatus
      Write-LogEntry "OS: WARN - Windows 정품 인증 상태 이상 (LicenseStatus=$licStatus)"
      $recommendations += '[OS] Windows 정품 인증이 필요합니다 (설정 > 시스템 > 정품 인증). 미인증 시 보안 업데이트가 중단됩니다.'
      Set-StampDate $licFlag
    }
  } catch {
    Write-LogEntry "OS: SKIP - 정품 인증 확인 실패 ($($_.Exception.Message))"
  }
}

# --- CPU 사용률 확인 ---
Write-ProgressBar "CPU"
Write-TestHeader "[CPU] CPU 사용률을 측정하여 시스템 과부하 여부를 진단합니다."
try {
  $cpuSample = Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop
  $cpuUsage = [Math]::Round($cpuSample.CounterSamples[0].CookedValue, 2)
  if ($cpuUsage -gt 90) {
    Write-LogEntry "CPU: WARN - Usage at ${cpuUsage}% (high but not critical)"
  } else {
    Write-LogEntry "CPU: PASS - Usage at ${cpuUsage}%"
  }
} catch {
  Write-LogEntry "CPU: FAIL - Unable to retrieve CPU usage: $_"
  $allPass = $false
  $failureReasons += "[CPU] CPU 사용률 수집 실패: $_"
}

# --- 메모리 상태 확인 (90% 초과 또는 4GB 미만이면 경고) ---
Write-ProgressBar "Memory"
Write-TestHeader "[Memory] 물리적 메모리 사용량을 분석하고 부족 시 권장 사항을 제공합니다."
if ($osInfo) {
  $memTotalMB = [Math]::Round($osInfo.TotalVisibleMemorySize / 1024)
  $memFreeMB = [Math]::Round($osInfo.FreePhysicalMemory / 1024)
  $memUsedPct = [Math]::Round((($memTotalMB - $memFreeMB) / $memTotalMB) * 100, 2)
  $memWarnings = @()
  if ($memUsedPct -gt 90) { $memWarnings += "usage at ${memUsedPct}%" }
  if ($memFreeMB -lt 4096) { $memWarnings += "only ${memFreeMB}MB free" }
  if ($memWarnings.Count -gt 0) {
    Write-LogEntry "Memory: WARN - $($memWarnings -join '; ')"
    if ($memUsedPct -gt 90) { $recommendations += "[Memory] 메모리 사용량이 ${memUsedPct}%로 매우 높습니다. 불필요한 프로그램을 종료하거나 RAM을 증설하세요." }
    if ($memFreeMB -lt 4096) { $recommendations += "[Memory] 여유 메모리가 ${memFreeMB}MB 미만입니다. 추가 RAM 장착을 고려하세요." }
  } else {
    Write-LogEntry "Memory: PASS - Used ${memUsedPct}% (Free: ${memFreeMB}MB / Total: ${memTotalMB}MB)"
  }
  } else {
    Write-LogEntry 'Memory: FAIL - OS info not available'
    $allPass = $false
    $failureReasons += '[Memory] OS 정보를 사용할 수 없음'
  }

# --- 디스크 공간 확인 + 자동 정리 ---
Write-ProgressBar "Disk"
Write-TestHeader "[Disk] 디스크 여유 공간을 확인하고 임시 파일을 자동 정리합니다."
$diskIssues = @()
try {
  $disksOk = $true
  foreach ($d in Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot -eq $null }) {
    if ($d.Free -ne $null) {
      $freeGB = [math]::Round($d.Free / 1GB, 2)
      # 드라이브별 기준(2026-11-13 사용자 지시): **그 드라이브 용량의 10%**.
      #   "500GB·3TB 남았는데 '몇 GB 남았습니다. 문제가 생길 수 있습니다' 는 말이 안 된다.
      #    일괄 100GB 로 하지 말고 각 드라이브 용량의 10%를 기준으로 해."
      #   → 1.86TB 드라이브는 약 186GB, 4TB 는 400GB 가 기준. 용량을 알 수 없을 때만 설정값 사용.
      $diskTotalBytes = 0.0
      try { if ($null -ne $d.Used) { $diskTotalBytes = [double]$d.Free + [double]$d.Used } } catch { }
      $driveThreshold = [double]$diskThreshold
      if ($diskTotalBytes -gt 0) {
        $driveThreshold = ($diskTotalBytes / 1GB) * 0.10
      }
      if ($driveThreshold -lt 1) { $driveThreshold = 1 }
      if ($freeGB -lt $driveThreshold) {
        Write-LogEntry "Disk $($d.Name): FAIL - Only ${freeGB}GB free (threshold: $([math]::Round($driveThreshold, 2))GB)"
        $diskIssues += "Disk $($d.Name) has only ${freeGB}GB free"
        $disksOk = $false
        $allPass = $false
        $thresholdText = [string][math]::Round($driveThreshold, 1)
        # "문제가 있을 수 있습니다" 경고는 '정말 위험할 만큼'(5GB 미만) 적을 때만 붙인다(2026-11-13).
        if (Test-CriticalFreeSpace -FreeBytes ([double]$d.Free) -TotalBytes $diskTotalBytes) {
          $recommendations += "[Disk] $($d.Name) 드라이브의 여유 공간이 ${freeGB}GB 밖에 없습니다. 현재 용량으로는 디스크 속도나 이용에 문제가 있을 수 있으니, 필요한 자료를 백업한 뒤 ${thresholdText}GB 이상 확보하시는 걸 권장합니다."
        } else {
          $recommendations += "[Disk] $($d.Name) 드라이브의 여유 공간이 ${freeGB}GB 입니다. 필요한 자료를 백업한 뒤 ${thresholdText}GB 이상 확보하시는 걸 권장합니다."
        }
        # 설정된 임시 폴더에서 파일 삭제하여 공간 확보
        #   ⚠ 2026-11-12 사고 대응: 아래 3가지를 반드시 지킨다.
        #      (a) "부족한 그 드라이브" 안에 있는 임시 폴더만 지운다(전역 tempDirs 를 아무 데나 적용 금지)
        #      (b) 드라이브 루트·사용자 데이터 폴더는 Test-SafeTempDir 로 걸러낸다
        #      (c) 최근 파일(tempMinAgeDays 이내)과 상한(tempCleanupMaxGB) 초과분은 지우지 않는다
        $driveRoot = "$($d.Name):\"
        $configuredDirs = @(Get-Cfg 'tempDirs')
        $explicitDirs = ($null -ne (Get-ConfigProp $config 'tempDirs'))
        $minAgeDays = 1
        try { $minAgeDays = [int](Get-Cfg 'tempMinAgeDays') } catch { }
        if ($minAgeDays -lt 1) { $minAgeDays = 1 }
        $maxBytes = 0.0
        try { $maxBytes = [double](Get-Cfg 'tempCleanupMaxGB') * 1GB } catch { }
        if ($maxBytes -le 0) { $maxBytes = 5GB }
        $modCutoff = (Get-Date).AddDays(-$minAgeDays)
        $deletedBytes = 0.0
        foreach ($td in $configuredDirs) {
          if ($deletedBytes -ge $maxBytes) {
            Write-LogEntry "Cleanup: SKIP - 이번 실행 정리 상한 $([math]::Round($maxBytes / 1GB, 1))GB 도달"
            break
          }
          $chk = Test-SafeTempDir -Path $td -Explicit:$explicitDirs
          if (-not $chk.Ok) {
            Write-LogEntry "Cleanup ($td): SKIP - 안전 가드: $($chk.Reason)"
            $recommendations += "[정리 제외] '$td' 는 자동 정리에서 제외했습니다 — $($chk.Reason). TEMP/TMP 위치나 config 의 tempDirs 를 확인하세요."
            continue
          }
          if ([IO.Path]::GetPathRoot($chk.Path) -ine $driveRoot) { continue }   # 그 드라이브가 부족할 때 처리
          if (-not (Test-Path -LiteralPath $chk.Path)) { continue }
          try {
            $all = @(Get-FilesNoReparse -Root $chk.Path |
                       Where-Object { $_.LastWriteTime -lt $modCutoff })
            if ($all.Count -eq 0) { Write-LogEntry "Cleanup ($($chk.Path)): PASS - No files older than ${minAgeDays}d"; continue }

            # 상한까지만, 오래된 것부터
            $budget = $maxBytes - $deletedBytes
            $picked = @()
            $pickedBytes = 0.0
            foreach ($f in @($all | Sort-Object LastWriteTime)) {
              if ($pickedBytes + [double]$f.Length -gt $budget) { continue }
              $picked += [pscustomobject]@{ Name = $f.FullName; Size = [double]$f.Length; Date = $f.LastWriteTime }
              $pickedBytes += [double]$f.Length
            }
            if ($picked.Count -eq 0) {
              Write-LogEntry "Cleanup ($($chk.Path)): SKIP - 상한 $([math]::Round($maxBytes / 1GB, 1))GB 초과"
              continue
            }
            $dumpCands = $picked
            # 사용자 지시(2026-11-12): 용량이 아무리 부족해도 알아서 지우지 않는다.
            #   남은 용량을 알려주고 "백업하세요" 안내와 함께 y/N 을 묻는다.
            $freeNowBytes = 0.0
            try { $freeNowBytes = [double](Get-PSDrive -Name $d.Name -ErrorAction Stop).Free } catch { $freeNowBytes = [double]$d.Free }
            $notice = @(("지금 {0} 드라이브 여유 공간은 {1} 입니다." -f $d.Name, (Format-ByteSize $freeNowBytes)))
            if (Test-CriticalFreeSpace -FreeBytes $freeNowBytes -TotalBytes $diskTotalBytes) {
              # 정말 위험할 만큼 적을 때만(5GB 미만) 이 경고를 띄운다.
              $notice += '현재 용량으로는 디스크 속도나 이용에 문제가 있을 수 있습니다.'
              $notice += '용량이 이만큼 남았으니 오래된 파일부터 삭제합니다.'
            } else {
              $notice += '여유 공간을 조금 확보하려고 오래된 임시 파일부터 정리하려고 합니다.'
            }
            $notice += '필요한 자료가 있으시면 백업을 하세요.'
            $approved = Invoke-DeleteReview -Target "임시 폴더 ($($chk.Path))" -Items $dumpCands -Notice $notice -PolicyKey 'tempAutoDelete' -DeleteAction {
              foreach ($c in $dumpCands) { try { Remove-Item -LiteralPath $c.Name -Force -ErrorAction SilentlyContinue } catch { } }
            }
            if ($approved) {
              $deletedBytes += $pickedBytes
              $remaining = @(Get-FilesNoReparse -Root $chk.Path)
              $remainCount = $remaining.Count
              $remainBytes = 0.0
              $sum = ($remaining | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
              if ($sum) { $remainBytes = [double]$sum }
              # 남은 파일 = 최근 파일(보존 대상) + 사용 중이라 못 지운 파일
              $remainMsg = if ($remainCount -gt 0) { " (남은 ${remainCount}개 / $(Format-ByteSize $remainBytes) — 최근·사용 중 파일은 유지)" } else { "" }
              Write-LogEntry "Cleanup ($($chk.Path)): Removed $(Format-ByteSize $pickedBytes)${remainMsg}"
              if ($pickedBytes -gt 0) { Add-AutoFix ("디스크 부족({0}) → 임시 폴더 정리 {1} ({2})" -f $d.Name, (Format-ByteSize $pickedBytes), $chk.Path) }
            } else {
              Write-LogEntry "Cleanup ($($chk.Path)): SKIP - 지우지 않기로 함 ($($picked.Count)개 / $(Format-ByteSize $pickedBytes) 유지)"
            }
            # 남은 여유 공간은 참고용으로만 기록한다(목표 용량을 채우기 위해 추가 삭제하지 않는다).
            try {
              $nowFreeGB = [math]::Round((Get-PSDrive -Name $d.Name -ErrorAction Stop).Free / 1GB, 2)
              Write-LogEntry "Cleanup: $($d.Name) 여유 공간 ${nowFreeGB}GB (자동 추가 삭제 없음)"
            } catch { }
          } catch {
            Write-LogEntry "Cleanup ($($chk.Path)): Error during cleanup: $_"
          }
        }
      } else {
        Write-LogEntry "Disk $($d.Name): PASS - ${freeGB}GB free"
      }
    }
  }
  if ($disksOk) { Write-LogEntry 'Disk check: PASS - All drives have sufficient space' }
} catch {
  Write-LogEntry "Disk: FAIL - Unable to check disk space: $_"
  $allPass = $false
  $failureReasons += "[Disk] 디스크 공간 확인 실패: $_"
}

# --- 중요 서비스 상태 확인 + 자동 재시작 ---
$servicesToCheck = Get-Cfg 'servicesToCheck'
$criticalServices = Get-Cfg 'criticalServices'
$servicesOk = $true
Write-ProgressBar "Service"
Write-TestHeader "[Service] 주요 Windows 서비스(Spooler, BITS, WinDefend, RpcSs, SamSs 등)의 실행 상태를 점검합니다."
$svcDescMap = @{
  'RpcSs' = '원격 프로시저 호출(RPC) - Windows 서비스 인프라의 핵심'
  'DCOMLAUNCH' = 'DCOM 서버 프로세스 시작 관리 - COM 인프라'
  'SamSs' = '보안 계정 관리자 - 사용자 로그온 및 계정 보안'
  'PlugPlay' = '플러그 앤 플레이 - 하드웨어 자동 인식'
  'EventLog' = 'Windows 이벤트 로그 - 시스템 오류 추적'
  'ProfSvc' = '사용자 프로필 서비스 - 사용자 계정 로드'
  'gpsvc' = '그룹 정책 클라이언트 - 보안 정책 적용'
  'Power' = '전원 관리 - 절전 모드 및 전원 정책'
  'CoreMessaging' = 'CoreMessaging - 시스템 구성 요소 간 통신'
  'Spooler' = '인쇄 스풀러 - 프린터 작업 대기열 관리'
  'BITS' = '백그라운드 지능형 전송 - Windows 업데이트 다운로드'
  'WinDefend' = 'Windows Defender - 맬웨어 방지 및 보안'
}
$svcDescs = $servicesToCheck | Where-Object { $svcDescMap.ContainsKey($_) } | ForEach-Object { "  → [$_] $($svcDescMap[$_])" }
foreach ($descLine in $svcDescs) { Write-TestHeader $descLine }
foreach ($svcName in $servicesToCheck) {
  try {
    $svc = Get-Service -Name $svcName -ErrorAction Stop
    if ($svc.Status -eq 'Running') {
      Write-LogEntry "Service ${svcName}: PASS - Status: $($svc.Status)"
    } else {
      $isCritical = $svcName -in $criticalServices
      $restartList = $defaults.restartServices
      $remediateObj = Get-ConfigProp $config 'remediate'
      if ($remediateObj) {
        $cfgRestartServices = Get-ConfigProp $remediateObj 'restartServices'
        if ($cfgRestartServices) { $restartList = $cfgRestartServices }
      }
      if ($isCritical) {
        Write-LogEntry "Service ${svcName}: CRITICAL - Status: $($svc.Status) (시스템 구동 필수 서비스)"
        $servicesOk = $false
        $allPass = $false
        $failureReasons += "[Service] $svcName (필수) 서비스가 중지됨 - 시스템 손상 위험"
        $recommendations += "[Service] $svcName 서비스는 Windows 구동에 필수적입니다. 이벤트 뷰어에서 오류 코드를 확인하고 시스템 복원 또는 Windows 복구를 고려하세요."
      } elseif ($svcName -in $restartList) {
        try {
          $oldStatus = $svc.Status
          Restart-Service -Name $svcName -Force -ErrorAction Stop
          $svc.WaitForStatus('Running', '00:00:30')
          Write-LogEntry "Service ${svcName}: CHANGE - Restarted successfully (was $oldStatus)"
          Add-AutoFix "${svcName} 서비스 재시작 (was $oldStatus → Running)"
        } catch {
          Write-LogEntry "Service ${svcName}: FAIL - Status: $($svc.Status), restart attempted but failed: $_"
          $servicesOk = $false
          $allPass = $false
          $failureReasons += "[Service] $svcName 서비스 재시작 실패: $_"
          $recommendations += "[Service] $svcName 서비스를 시작할 수 없습니다. services.msc에서 수동으로 시작하거나 시스템 복원을 고려하세요."
        }
      } else {
        $autoSvc = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
        $startMode = if ($autoSvc) { $autoSvc.StartMode } else { 'Unknown' }
        if ($startMode -eq 'Manual' -or $svcName -eq 'gpsvc') {
          Write-LogEntry "Service ${svcName}: PASS - Status: $($svc.Status) (수동 시작 서비스, 필요 시 자동 실행)"
        } else {
          Write-LogEntry "Service ${svcName}: FAIL - Status: $($svc.Status) (Expected: Running)"
          $servicesOk = $false
          $allPass = $false
          $failureReasons += "[Service] $svcName 서비스가 실행 중이 아님 (상태: $($svc.Status))"
          $recommendations += "[Service] $svcName 서비스가 실행 중이 아닙니다. 관리자 권한으로 'net start $svcName'을 실행하세요."
        }
      }
    }
  } catch {
    Write-LogEntry "Service ${svcName}: FAIL - Unable to check service: $_"
    $servicesOk = $false
    $allPass = $false
    $failureReasons += "[Service] $svcName 서비스 확인 실패: $_"
  }
}

# --- WinSxS 정리 필요 여부 미리 확인 (SFC 병렬 실행용) ---
#   주기는 `heavyCheckDays`(기본 30일) 하나로 통일한다: SFC/WinSxS/CHKDSK 를 각자 다른 주기로
#   돌리면 "왜 이번엔 SFC만 돌았나"를 추적하기 어려워진다. CHKDSK 만 `chkdskDays`(12일)로 따로 둔다.
$winsxsFlag = Join-Path $scriptRoot '.last_winsxs_clean'
$heavyCheckDays = [int](Get-Cfg 'heavyCheckDays')
$shouldCleanWinSxS = $false; $lastWinSxs = $null
if (Test-Path -LiteralPath $winsxsFlag) {
  $lastWinSxs = (Get-Item -LiteralPath $winsxsFlag).LastWriteTime
  if (((Get-Date) - $lastWinSxs).TotalDays -ge $heavyCheckDays) { $shouldCleanWinSxS = $true }
} else {
  $shouldCleanWinSxS = $true
}
$script:winsxsAnalysisOutput = $null

# --- VSS(볼륨 섀도우 복사본) 상태 점검 ---
Write-ProgressBar "VSS"
Write-TestHeader "[VSS] 볼륨 섀도우 복사본 서비스 상태를 확인합니다."
try {
  $vssService = Get-Service -Name VSS -ErrorAction Stop
  if ($vssService.Status -ne 'Running') {
    try {
      Restart-Service -Name VSS -Force -ErrorAction Stop
      (Get-Service -Name VSS).WaitForStatus('Running', '00:00:30')
      Write-LogEntry "VSS: PASS - Service restarted (was $($vssService.Status))"
      Add-AutoFix "VSS(볼륨 섀도 복사본) 서비스 재시작 (was $($vssService.Status))"
    } catch {
      Write-LogEntry "VSS: WARN - Service status: $($vssService.Status) (shadow copies may fail)"
      $failureReasons += "[VSS] 볼륨 섀도우 복사본 서비스가 실행 중이 아님 (상태: $($vssService.Status))"
      $recommendations += "[VSS] 볼륨 섀도우 복사본 서비스가 중지되었습니다. 관리자 권한으로 'net start VSS'를 실행하세요."
    }
  } else {
    # 로캘 독립적 조회: vssadmin 출력은 언어별로 달라 파싱 불가 → Win32_ShadowStorage 사용
    $vssList = @(Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue)
    if ($vssList.Count -gt 0) {
      foreach ($ss in $vssList) {
        if (-not $ss.Volume) { continue }
        $ssLetter = if ($ss.Volume.DriveLetter) { $ss.Volume.DriveLetter } else { '?' }
        $usedGB = [math]::Round($ss.UsedSpace / 1GB, 2)
        $allocGB = [math]::Round($ss.AllocatedSpace / 1GB, 2)
        # Win32_ShadowStorage.MaxSpace 는 "제한 없음"일 때 2^64-1(≈17179869184GB)을 돌려준다.
        # 그대로 표시하면 로그가 17179869184GB 로 오염되므로 볼륨 용량으로 보정한다.
        $maxBytes = [double]$ss.MaxSpace
        if ($maxBytes -ge 1e18 -or $maxBytes -le 0) {
          try { if ($ss.Volume.Capacity -gt 0) { $maxBytes = [double]$ss.Volume.Capacity } } catch { }
        }
        $maxGB = [math]::Round($maxBytes / 1GB, 2)
        $unlimited = ($maxBytes -le 0 -or $maxBytes -ge 1e18)
        $pctUsed = if ($maxGB -gt 0) { [math]::Round(($usedGB / $maxGB) * 100, 1) } else { 0 }
        $maxLabel = if ($unlimited) { '무제한' } else { "${maxGB}GB" }
        if ($pctUsed -gt 90) {
          Write-LogEntry "VSS: WARN - [${ssLetter}] shadow copy storage at ${pctUsed}% (${usedGB}GB / ${maxLabel}, allocated ${allocGB}GB)"
          $failureReasons += "[VSS] [${ssLetter}] shadow storage ${pctUsed}% used (${usedGB}GB / ${maxLabel})"
        } else {
          Write-LogEntry "VSS: PASS - [${ssLetter}] Service running, storage at ${pctUsed}% (${usedGB}GB / ${maxLabel})"
        }
      }
    } else {
      Write-LogEntry 'VSS: PASS - Service running (no shadow copies allocated)'
    }
  }
} catch {
  Write-LogEntry "VSS: SKIP - Unable to check VSS: $_"
}

# --- 디스크 건강 상태 통합 분석 (SSD Wear + SMART) ---
Write-ProgressBar "DiskHealth"
Write-TestHeader "[DiskHealth] 모든 디스크의 SMART/SSD wear 상태를 분석합니다."
try {
  # SATA SMART 원시 속성 캐시 (NVMe는 ATAPI SMART 미지원 → 해당 없음)
  #   5=재할당 섹터, 183=런타임 불량블록, 197=보류 섹터, 198=수정불가 섹터, 199=UDMA CRC 오류
  $smartAttrMap = @{}
  try {
    foreach ($sd in (Get-CimInstance -Namespace 'root/wmi' -ClassName 'MSStorageDriver_ATAPISmartData' -ErrorAction SilentlyContinue)) {
      $vs = $sd.VendorSpecific
      if (-not $vs -or $vs.Length -lt 14) { continue }
      $prodKey = if ($sd.InstanceName -match 'Prod_([^\\]+)') { ($Matches[1] -replace '[^A-Za-z0-9]', '').ToUpper() } else { ($sd.InstanceName -replace '[^A-Za-z0-9]', '').ToUpper() }
      $attrs = @{}
      for ($i = 2; $i + 12 -le $vs.Length; $i += 12) {
        $attrId = [int]$vs[$i]
        if ($attrId -le 0) { continue }
        $rawVal = 0L
        for ($b = 5; $b -ge 0; $b--) { $rawVal = ($rawVal * 256) + $vs[$i + 5 + $b] }
        $attrs[$attrId] = $rawVal
      }
      if ($attrs.Count -gt 0 -and $prodKey) { $smartAttrMap[$prodKey] = $attrs }
    }
  } catch { }

  # 누적 카운터(199 UDMA CRC / 183 런타임 불량블록)는 0 으로 되돌아가지 않으므로
  # 이전 실행 값을 저장해 두고 "증가분"이 있을 때만 WARN 을 올린다.
  $dhStatePath = if ($scriptRoot) { Join-Path $scriptRoot 'diskhealth-state.json' } else { $null }
  $dhState = @{}
  if ($dhStatePath -and (Test-Path -LiteralPath $dhStatePath)) {
    try {
      $dhLoaded = Get-Content -LiteralPath $dhStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($prop in $dhLoaded.PSObject.Properties) { $dhState[$prop.Name] = $prop.Value }
    } catch { $dhState = @{} }
  }
  $dhNewState = @{}

  $smartIssues = $false
  $smartLogs = @()
  foreach ($disk in $script:cachedDisks) {
    $rel = $disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    $diskInfo = "$($disk.FriendlyName) ($($disk.MediaType))"
    $issues = @()

    # 모델명 매칭 (예: "WDC WD80EFZZ-68BTXN0" → "WD80EFZZ-68BTXN0")
    $smartAttrs = $null
    $modelToken = ($disk.FriendlyName -split '\s+')[-1]
    $modelKey = ($modelToken -replace '[^A-Za-z0-9]', '').ToUpper()
    if ($modelKey.Length -ge 6) {
      foreach ($k in $smartAttrMap.Keys) {
        $kShort = if ($k.Length -ge 8) { $k.Substring(0, 8) } else { $k }
        $mShort = if ($modelKey.Length -ge 8) { $modelKey.Substring(0, 8) } else { $modelKey }
        if ($kShort -eq $mShort) { $smartAttrs = $smartAttrMap[$k]; break }
      }
    }
    $smartInfo = ''
    if ($smartAttrs) {
      $reallocated = if ($smartAttrs.ContainsKey(5)) { $smartAttrs[5] } else { 0 }
      $runtimeBad  = if ($smartAttrs.ContainsKey(183)) { $smartAttrs[183] } else { 0 }
      $pending     = if ($smartAttrs.ContainsKey(197)) { $smartAttrs[197] } else { 0 }
      $uncorrect   = if ($smartAttrs.ContainsKey(198)) { $smartAttrs[198] } else { 0 }
      $crcErr      = if ($smartAttrs.ContainsKey(199)) { $smartAttrs[199] } else { 0 }
      if ($reallocated -gt 0) { $issues += "Reallocated=$reallocated" }
      if ($pending -gt 0)     { $issues += "Pending=$pending" }
      if ($uncorrect -gt 0)   { $issues += "Uncorrectable=$uncorrect" }

      # 직전 실행 대비 증가분 계산 (기준값이 없으면 이번 값을 기준으로 저장만)
      $prevBad = if ($dhState.ContainsKey($modelKey) -and $null -ne $dhState[$modelKey].badblocks) { [int64]$dhState[$modelKey].badblocks } else { $null }
      $prevCrc = if ($dhState.ContainsKey($modelKey) -and $null -ne $dhState[$modelKey].crc) { [int64]$dhState[$modelKey].crc } else { $null }
      $dhNewState[$modelKey] = @{
        model     = $disk.FriendlyName
        realloc   = $reallocated
        pending   = $pending
        uncorrect = $uncorrect
        badblocks = $runtimeBad
        crc       = $crcErr
        updated   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      }

      $badNote = ''
      $crcNote = ''
      if ($null -eq $prevBad -and $null -eq $prevCrc) {
        # 첫 측정: 기준값으로만 저장하고 FAIL 사유로 올리지 않음
        if ($runtimeBad -gt 0) { $badNote = '(이력)' }
        if ($crcErr -gt 0)     { $crcNote = '(이력)' }
        if ($runtimeBad -gt 0 -or $crcErr -gt 0) {
          Write-LogEntry "DiskHealth ($diskInfo): INFO - SMART 기준값 기록 (불량블록=$runtimeBad, CRC=$crcErr) — 이후 증가분부터 경고"
        }
      } else {
        $dBad = if ($null -ne $prevBad) { $runtimeBad - $prevBad } else { 0 }
        $dCrc = if ($null -ne $prevCrc) { $crcErr - $prevCrc } else { 0 }
        if ($dBad -gt 0) {
          $badNote = "(+$dBad 증가)"
          $issues += "BadBlocks=$runtimeBad(+$dBad 증가)"
          $recommendations += "[DiskHealth] $($disk.FriendlyName): 런타임 불량블록이 ${dBad}건 증가(누적 $runtimeBad) — 즉시 백업 후 표면 검사/교체 검토"
        } elseif ($runtimeBad -gt 0) { $badNote = '(이력)' }
        if ($dCrc -gt 0) {
          $crcNote = "(+$dCrc 증가)"
          $issues += "UDMA_CRC=$crcErr(+$dCrc 증가, 케이블/포트)"
          $recommendations += "[DiskHealth] $($disk.FriendlyName): SATA UDMA CRC 오류가 ${dCrc}건 증가(누적 $crcErr) — 케이블/포트 교체·재장착 후 재확인 (재할당·보류 섹터가 0이면 NAND 불량보다 링크 문제)"
        } elseif ($crcErr -gt 0) { $crcNote = '(이력)' }
      }
      $smartInfo = "SMART(재할당=$reallocated 보류=$pending 수정불가=$uncorrect 불량블록=$runtimeBad$badNote CRC=$crcErr$crcNote)"
    }

    if ($rel) {
      if ($rel.ReadErrorsTotal -gt 0) { $issues += "ReadErrors=$($rel.ReadErrorsTotal)" }
      if ($rel.Wear -gt 0) {
        $warnWear = $rel.Wear -ge 90
        $issues += "Wear=$($rel.Wear)%$(if($warnWear){' ⚠'})"
        if ($warnWear) {
          try { Write-EventLog -LogName Application -Source 'Maintenance' -EntryType Warning -EventId 1001 -Message "Disk $($disk.FriendlyName) wear level at $($rel.Wear)% - replacement recommended" -ErrorAction SilentlyContinue } catch { }
        }
      }
      if ($rel.Temperature -gt 65) { $issues += "Temp=$($rel.Temperature)C" }
      if ($rel.PowerOnHours -gt 0 -and $rel.Wear -gt 0) { $issues += "PowerOn=$($rel.PowerOnHours)h" }
    } else {
      if ($disk.MediaType -in @('SSD','NVMe')) { Write-LogEntry "DiskHealth ($diskInfo): PASS - Wear data not reported by drive" }
    }
    if ($issues.Count -gt 0) {
      Write-LogEntry "DiskHealth ($diskInfo): WARN - $($issues -join ', ')"
      $failureReasons += "[DiskHealth] $diskInfo 에 문제 발견 ($($issues -join ', '))"
      $smartIssues = $true
      $smartLogs += "DiskHealth ($diskInfo): WARN - $($issues -join ', ')"
    } elseif ($disk.MediaType -in @('SSD','NVMe')) {
      Write-LogEntry "DiskHealth ($diskInfo): PASS - Wear=$($rel.Wear)% (normal) | ReadErrors=0 | Temp=$($rel.Temperature)C$(if ($smartInfo) { " | $smartInfo" })"
    } else {
      Write-LogEntry "DiskHealth ($diskInfo): PASS - All attributes normal$(if ($smartInfo) { " | $smartInfo" })"
    }
  }
  if (-not $smartIssues) {
    Write-LogEntry 'DiskHealth: PASS - All drives OK'
  }
  if ($dhStatePath -and $dhNewState.Count -gt 0) {
    try {
      ($dhNewState | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $dhStatePath -Encoding UTF8
      Write-LogEntry "DiskHealth: SMART 기준값 저장 ($dhStatePath)"
    } catch {
      Write-LogEntry "DiskHealth: WARN - SMART 기준값 저장 실패: $($_.Exception.Message)"
    }
  }
} catch {
  Write-LogEntry "DiskHealth: FAIL - Unable to check disk health: $_"
  $allPass = $false
  $failureReasons += "[DiskHealth] 디스크 건강 상태 확인 실패: $_"
}

# --- 시스템 설정 자동 점검/복구 (SysFix) ---
Write-ProgressBar "SysFix"
Write-TestHeader "[SysFix] 크래시 덤프·시스템 복원·시간 동기화·이벤트 로그·섀도 저장소·대화형 서비스 설정을 점검하고 복구합니다."

# (1) 크래시 덤프 설정 (0=없음 1=전체 2=커널 3=작은 메모리 7=자동 메모리 덤프)
try {
  $ccPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
  $cc = Get-ItemProperty -Path $ccPath -ErrorAction Stop
  $dumpVal = [int]$cc.CrashDumpEnabled
  if ($dumpVal -notin @(1, 2, 7)) {
    Set-ItemProperty -Path $ccPath -Name 'CrashDumpEnabled' -Value 7 -Type DWord -ErrorAction Stop
    Write-LogEntry "SysFix: CHANGE - 크래시 덤프 형식 $dumpVal → 7(자동 메모리 덤프) — 블루스크린 원인 추적 가능"
    Add-AutoFix "크래시 덤프 형식 ${dumpVal} → 7(자동 메모리 덤프)로 변경"
  } else {
    Write-LogEntry "SysFix: PASS - 크래시 덤프 형식 정상 (CrashDumpEnabled=$dumpVal)"
  }
  $miniDir = if ($cc.MinidumpDir) { $cc.MinidumpDir } else { "$env:windir\Minidump" }
  if (-not (Test-Path -LiteralPath $miniDir)) {
    New-Item -Path $miniDir -ItemType Directory -Force | Out-Null
    Write-LogEntry "SysFix: CHANGE - 미니덤프 폴더 생성 ($miniDir)"
    Add-AutoFix "미니덤프 폴더 생성 ($miniDir)"
  }
} catch {
  Write-LogEntry "SysFix: WARN - 크래시 덤프 설정 확인 실패 ($($_.Exception.Message))"
  $recommendations += "[SysFix] 시스템 속성 > 고급 > 시작 및 복구에서 덤프 형식을 '자동 메모리 덤프'로 설정하세요."
}

# (2) 시스템 복원 활성화 + 복원 지점 예약 작업 (비활성 시 VSS 8193/0x80070422 반복)
try {
  $srClass = Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -ErrorAction SilentlyContinue
  if (-not $srClass) {
    Enable-ComputerRestore -Drive 'C:\' -ErrorAction Stop
    Write-LogEntry 'SysFix: CHANGE - 시스템 복원 활성화 (C:)'
    Add-AutoFix '시스템 복원 비활성 → C: 복원 활성화'
  } else {
    Write-LogEntry 'SysFix: PASS - 시스템 복원 활성화됨'
  }
  foreach ($srTask in @('\Microsoft\Windows\SystemRestore\SR', '\Microsoft\Windows\SystemRestore\SRNotify')) {
    $tq = & schtasks.exe /query /tn $srTask /fo list 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { continue }
    if ($tq -match '(?i)Disabled|사용 안 함') {
      $null = & schtasks.exe /change /tn $srTask /enable 2>&1
      if ($LASTEXITCODE -eq 0) { Write-LogEntry "SysFix: CHANGE - 복원 지점 예약 작업 활성화: $srTask"; Add-AutoFix "복원 지점 예약 작업 활성화: $srTask" }
    }
  }
  if ($Mode -ne 'check') {
    $needRp = $true
    try {
      $lastRp = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object CreationTime -Descending | Select-Object -First 1
      if ($lastRp) {
        $ctStr = [string]$lastRp.CreationTime
        if ($ctStr.Length -ge 14) {
          $ct = [datetime]::ParseExact($ctStr.Substring(0, 14), 'yyyyMMddHHmmss', $null)
          if (((Get-Date).ToUniversalTime() - $ct).TotalHours -lt 20) { $needRp = $false }
        }
      }
    } catch { }
    if ($needRp) {
      try {
        Checkpoint-Computer -Description 'Maintenance checkpoint' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-LogEntry 'SysFix: CHANGE - 복원 지점 생성 완료'
        Add-AutoFix '복원 지점 생성 (Maintenance checkpoint)'
      } catch {
        Write-LogEntry "SysFix: WARN - 복원 지점 생성 실패 ($($_.Exception.Message))"
      }
    } else {
      Write-LogEntry 'SysFix: PASS - 최근 24시간 내 복원 지점 존재'
    }
  }
} catch {
  Write-LogEntry "SysFix: WARN - 시스템 복원 점검 실패 ($($_.Exception.Message))"
  $recommendations += "[SysFix] 시스템 보호 탭에서 C: 드라이브 보호를 켜고 '만들기'로 복원 지점을 생성하세요."
}

# (3) 시간 동기화 (소스가 Local CMOS Clock/Free-running이면 NTP 재구성)
try {
  # 서비스가 멈춰 있으면 `w32tm /query /source` 가 오류 문자열을 돌려주는데, 예전 코드는 그 문자열을
  #   "정상 소스"로 오인해 PASS 로 기록했다(2026-11-06 실측: "오류가 발생했습니다... (0x80070426)").
  #   → 먼저 서비스를 켜고(자동 조치), 소스가 오류/로컬 클럭이면 재구성한다.
  $w32State = Get-Service w32time -ErrorAction SilentlyContinue
  if ($w32State -and $w32State.Status -ne 'Running') {
    try {
      Start-Service -Name w32time -ErrorAction Stop
      (Get-Service -Name w32time).WaitForStatus('Running', '00:00:15')
      Write-LogEntry "SysFix: CHANGE - W32Time 서비스 시작 (was $($w32State.Status))"
      Add-AutoFix "W32Time 서비스 시작 (was $($w32State.Status))"
    } catch {
      Write-LogEntry "SysFix: WARN - W32Time 서비스 시작 실패 ($($_.Exception.Message))"
    }
  }
  $timeSource = ((& w32tm /query /source 2>&1 | Out-String) -replace "`r?`n", ' ').Trim()
  $sourceBad = (-not $timeSource) -or
               ($timeSource -match '(?i)Local CMOS Clock|Free-running System Clock') -or
               ($timeSource -match '(?i)오류|error|0x8007|시작되지|not started')
  if ($sourceBad) {
    $peers = 'time.google.com,0x9 kr.pool.ntp.org,0x9 pool.ntp.org,0x9'
    $null = & w32tm.exe /config "/manualpeerlist:$peers" /syncfromflags:manual /reliable:no /update 2>&1
    # ⚠️ /unregister + /register 조합은 쓰지 않는다(2026-11-06 실제 사고):
    #   /unregister 는 서비스 "등록 자체"를 제거하고, /register 로 되살리면 StartType 이 Manual/Stopped 로
    #   돌아온다. 정상 상태에서 매번 반복하면 시간 동기화가 조용히 죽는다.
    #   → 서비스가 아예 없을 때만(트윅 도구로 삭제된 경우) 복구 등록하고, 그 외에는 시작+재검색만 한다.
    if (-not (Get-Service w32time -ErrorAction SilentlyContinue)) {
      $null = & w32tm.exe /register 2>&1
      Start-Sleep -Seconds 1
      Set-Service -Name w32time -StartupType Automatic -ErrorAction SilentlyContinue
      Add-AutoFix 'W32Time 서비스 등록 복구 (w32tm /register)'
    }
    $w32Now = Get-Service w32time -ErrorAction SilentlyContinue
    if ($w32Now -and $w32Now.Status -ne 'Running') {
      try {
        Start-Service -Name w32time -ErrorAction Stop
        (Get-Service -Name w32time).WaitForStatus('Running', '00:00:15')
      } catch {
        Write-LogEntry "SysFix: WARN - W32Time 서비스 시작 실패 ($($_.Exception.Message))"
      }
    }
    $null = & w32tm.exe /resync /rediscover 2>&1
    Start-Sleep -Seconds 2
    $newSource = ((& w32tm /query /source 2>&1 | Out-String) -replace "`r?`n", ' ').Trim()
    if ($newSource -and $newSource -notmatch '(?i)Local CMOS Clock|Free-running System Clock' -and $newSource -notmatch '(?i)오류|error|0x8007|시작되지|not started') {
      Write-LogEntry "SysFix: CHANGE - 시간 동기화 복구 (소스: $newSource)"
      Add-AutoFix "시간 동기화 소스 재구성 (Local CMOS → $newSource)"
    } else {
      Write-LogEntry "SysFix: WARN - 시간 동기화 실패 (소스: $newSource)"
      $recommendations += "[SysFix] UDP 123 차단 여부(공유기/방화벽)를 확인하세요. NTP 서버 후보: time.google.com, kr.pool.ntp.org"
    }
  } else {
    Write-LogEntry "SysFix: PASS - 시간 동기화 정상 (소스: $timeSource)"
  }
} catch {
  Write-LogEntry "SysFix: WARN - 시간 동기화 점검 실패 ($($_.Exception.Message))"
}

# (4) 주요 이벤트 로그 최대 크기 64MB 확보 (기본 20MB는 덮어쓰기로 증거 소실)
try {
  $wantLogBytes = 64MB
  $resizedLogs = 0
  foreach ($logName in @('System', 'Application', 'Security')) {
    $lg = Get-WinEvent -ListLog $logName -ErrorAction SilentlyContinue
    if (-not $lg) { continue }
    if ($lg.IsEnabled -and $lg.MaximumSizeInBytes -lt $wantLogBytes) {
      try { Limit-EventLog -LogName $logName -MaximumSize $wantLogBytes -ErrorAction Stop; $resizedLogs++ } catch { }
    }
  }
  if ($resizedLogs -gt 0) {
    Write-LogEntry "SysFix: CHANGE - 이벤트 로그 최대 크기 64MB 확장 ($resizedLogs 개)"
    Add-AutoFix "이벤트 로그 최대 크기 64MB 확장 (${resizedLogs}개)"
  } else {
    Write-LogEntry 'SysFix: PASS - 주요 이벤트 로그 최대 크기 64MB 이상'
  }
} catch {
  Write-LogEntry "SysFix: WARN - 이벤트 로그 크기 조정 실패 ($($_.Exception.Message))"
}

# (5) 섀도 복사 저장소가 너무 작으면 20GB로 확장 (너무 작으면 복원 지점 삭제됨)
try {
  $shadowList = @(Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue)
  $shadowChanged = 0
  foreach ($ss in $shadowList) {
    if ($null -eq $ss.MaxSpace) { continue }
    $forLetter = $ss.Volume.DriveLetter
    if (-not $forLetter) { continue }
    $maxGB = [math]::Round($ss.MaxSpace / 1GB, 1)
    if ($maxGB -lt 10) {
      $onLetter = if ($ss.DiffVolume.DriveLetter) { $ss.DiffVolume.DriveLetter } else { $forLetter }
      $null = & vssadmin resize shadowstorage /for=$forLetter /on=$onLetter /maxsize=20GB 2>&1
      if ($LASTEXITCODE -eq 0) {
        Write-LogEntry "SysFix: CHANGE - 섀도 복사 저장소 ${forLetter} 최대 ${maxGB}GB → 20GB"
        Add-AutoFix "섀도 복사 저장소 ${forLetter} 최대 ${maxGB}GB → 20GB 확장"
        $shadowChanged++
      } else {
        Write-LogEntry "SysFix: WARN - 섀도 복사 저장소 ${forLetter} 확장 실패 (vssadmin 종료 코드 $LASTEXITCODE)"
      }
    }
  }
  if ($shadowChanged -eq 0) {
    Write-LogEntry "SysFix: PASS - 섀도 복사 저장소 크기 정상 ($($shadowList.Count)개 볼륨, 모두 10GB 이상)"
  }
} catch {
  Write-LogEntry "SysFix: WARN - 섀도 복사 저장소 점검 실패 ($($_.Exception.Message))"
}

# (6) 대화형(interactive) 플래그가 남은 3rd 파티 서비스 정리 (Type 0x1xx → 0x10)
#     인박스 서비스(Spooler/PrintNotify 등)는 정상 동작이므로 건드리지 않는다.
try {
  $interactiveSvc = @()
  foreach ($svcKey in (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)) {
    $svcProps = Get-ItemProperty -Path $svcKey.PSPath -ErrorAction SilentlyContinue
    if (-not $svcProps) { continue }
    $typeProp = $svcProps.PSObject.Properties['Type']
    if (-not $typeProp -or $null -eq $typeProp.Value) { continue }
    $svcType = [int]$typeProp.Value
    if (-not ($svcType -band 0x100)) { continue }
    $imgProp = $svcProps.PSObject.Properties['ImagePath']
    $img = if ($imgProp) { [string]$imgProp.Value } else { '' }
    $isInbox = ($img -match '(?i)%SystemRoot%|\\System32\\|\\SysWOW64\\')
    $interactiveSvc += [pscustomobject]@{ Name = $svcKey.PSChildName; Type = ('0x{0:X}' -f $svcType); Inbox = $isInbox }
  }
  $fixedSvc = 0
  foreach ($s in $interactiveSvc) {
    if ($s.Inbox) { continue }
    $null = & sc.exe config $s.Name type= own 2>&1
    if ($LASTEXITCODE -eq 0) {
      Write-LogEntry "SysFix: CHANGE - 대화형 서비스 정리: $($s.Name) ($($s.Type) → 0x10)"
      Add-AutoFix "대화형 서비스 정리: $($s.Name) ($($s.Type) → 0x10)"
      $fixedSvc++
    }
  }
  if ($fixedSvc -eq 0) {
    $inboxCount = @($interactiveSvc | Where-Object { $_.Inbox }).Count
    Write-LogEntry "SysFix: PASS - 3rd 파티 대화형 서비스 없음 (인박스 ${inboxCount}개는 정상)"
  }
} catch {
  Write-LogEntry "SysFix: WARN - 대화형 서비스 점검 실패 ($($_.Exception.Message))"
}

# --- 보안 부팅 / TPM / UEFI CA 2023 인증서 갱신 상태 ---
Write-ProgressBar "SecureBoot"
Write-TestHeader "[SecureBoot] 보안 부팅·TPM·UEFI CA 2023 인증서 갱신 상태를 확인합니다."
# 배경(2026-11): 2011년 Secure Boot 인증서가 2026-06부터 만료된다. Windows Update가 2023 CA를 배포하며
#   HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing 의 UEFICA2023Status 가 진행 상태를 알려준다
#   (Updated=완료, NotStarted/InProgress=미완료). 미완료면 부팅 신뢰 체인이 만료된 CA에 묶여 있을 수 있다.
#   실측 비용: Confirm-SecureBootUEFI 0.2s + Get-Tpm 0.2s + 레지스트리 0.3s.
try {
  $sbState = $null
  try { $sbState = Confirm-SecureBootUEFI -ErrorAction Stop } catch { $sbState = $null }
  if ($null -eq $sbState) {
    Write-LogEntry 'SecureBoot: INFO - UEFI Secure Boot 조회 불가 (레거시 BIOS 또는 미지원)'
  } elseif ($sbState) {
    Write-LogEntry 'SecureBoot: PASS - Secure Boot 활성'
  } else {
    Write-LogEntry 'SecureBoot: WARN - Secure Boot 비활성'
    # 2026-11-16: 게임 안티치트(Vanguard)는 Windows 11 에서 Secure Boot + TPM 2.0 을 요구한다.
    #   친구 PC(2026-11-15)가 Secure Boot 비활성 + Vanguard 게임을 쓰고 있어, 왜 켜야 하는지까지 적는다.
    $recommendations += '[SecureBoot] BIOS/UEFI 설정에서 Secure Boot를 켜세요 (부팅 무결성 보호). 리그 오브 레전드·발로란트 등 일부 게임(안티치트 Vanguard)은 Windows 11 에서 Secure Boot + TPM 2.0 이 필요합니다. UEFI CA 2023 갱신도 미완료라면 최신 누적 업데이트 설치 후 재부팅 2회 필요.'
  }

  try {
    $tpm = Get-Tpm -ErrorAction Stop
    if ($tpm.TpmPresent -and $tpm.TpmReady) {
      Write-LogEntry 'SecureBoot: PASS - TPM 준비됨'
    } else {
      Write-LogEntry "SecureBoot: WARN - TPM 상태 (Present=$($tpm.TpmPresent), Ready=$($tpm.TpmReady))"
      $recommendations += '[SecureBoot] TPM이 준비되지 않았습니다. BIOS에서 fTPM/PTT를 켜고 tpm.msc 에서 상태를 확인하세요.'
    }
  } catch {
    Write-LogEntry "SecureBoot: SKIP - TPM 조회 실패 ($($_.Exception.Message))"
  }

  $sbSvc = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' -ErrorAction SilentlyContinue
  $caStatus = if ($sbSvc -and $sbSvc.PSObject.Properties['UEFICA2023Status']) { [string]$sbSvc.UEFICA2023Status } else { '' }
  if ($caStatus -eq 'Updated') {
    Write-LogEntry 'SecureBoot: PASS - UEFI CA 2023 인증서 갱신 완료'
  } elseif ($caStatus) {
    Write-LogEntry "SecureBoot: WARN - UEFI CA 2023 갱신 미완료 ($caStatus)"
    $recommendations += "[SecureBoot] 2026년 만료되는 Secure Boot 인증서 교체가 미완료입니다($caStatus). 최신 누적 업데이트 설치 후 재부팅하세요."
  } else {
    Write-LogEntry 'SecureBoot: INFO - UEFI CA 2023 상태 키 없음 (구형 펌웨어 또는 미지원)'
  }
} catch {
  Write-LogEntry "SecureBoot: SKIP - 점검 실패 ($($_.Exception.Message))"
}

# --- Windows 복구 환경(WinRE) 등록 상태 ---
Write-ProgressBar "Recovery"
Write-TestHeader "[Recovery] Windows 복구 환경(WinRE)이 정상 등록되어 있는지 확인합니다."
# 배경: 업데이트/디스크 정리/트윅 도구가 WinRE 등록을 끊는 경우가 있다. WinRE가 없으면 안전 모드·복구·
#   시스템 복원 진입이 불가능해진다. reagentc /enable 은 /disable 로 되돌릴 수 있는 조치다.
#   실측 비용: reagentc /info 0.4s.
try {
  $reInfo = & reagentc /info 2>&1 | Out-String
  # 주의: 아래 정규식은 영문/한글 출력을 모두 받아야 한다.
  #   reagentc 는 콘솔에 직접 출력할 때는 영문이지만, stdout 이 파일/파이프로 리다이렉션되면
  #   OS 표시 언어(한글)로 출력한다 → 영문 라벨만 매칭하면 예약 작업 실행에서 항상 FAIL 로 오판했다(2026-11-10 실측).
  #   값(Enabled/Disabled)과 BCD GUID 는 로캘과 무관하게 그대로 나오므로 라벨 부분만 관대하게 매칭한다.
  $reEnabled = $reInfo -match '(?im)^\s*Windows RE[^:\r\n]*:\s*Enabled'
  $reBcdZero = $reInfo -match '(?im)^\s*BCD[^:\r\n]*:\s*0{8}-'
  if ($reEnabled -and -not $reBcdZero) {
    Write-LogEntry 'Recovery: PASS - WinRE 등록됨'
  } elseif ($reEnabled -and $reBcdZero) {
    Write-LogEntry 'Recovery: WARN - WinRE Enabled 이지만 BCD 식별자가 0 (등록 손상)'
    $recommendations += '[Recovery] WinRE BCD 등록이 손상되었습니다. 관리자 PowerShell에서 reagentc /disable 후 /enable 로 재등록하세요.'
  } else {
    $null = & reagentc /enable 2>&1
    Start-Sleep -Milliseconds 500
    $reInfo2 = & reagentc /info 2>&1 | Out-String
    if ($reInfo2 -match '(?im)^\s*Windows RE[^:\r\n]*:\s*Enabled') {
      Write-LogEntry 'Recovery: CHANGE - WinRE 비활성 → reagentc /enable 로 복구'
      Add-AutoFix 'WinRE 비활성 → reagentc /enable 로 복구'
    } else {
      Write-LogEntry 'Recovery: FAIL - WinRE 비활성 (자동 복구 실패)'
      $allPass = $false
      $failureReasons += '[Recovery] Windows 복구 환경(WinRE)이 비활성이며 자동 복구에 실패'
      $recommendations += '[Recovery] 복구 파티션/Winre.wim 확인 후 관리자 PowerShell에서 reagentc /enable 실행'
    }
  }
} catch {
  Write-LogEntry "Recovery: SKIP - 점검 실패 ($($_.Exception.Message))"
}

# --- WMI 리포지토리 무결성 ---
Write-ProgressBar "WMI"
Write-TestHeader "[WMI] WMI 리포지토리 무결성을 검사합니다."
# 배경: WMI 리포지토리가 손상되면 Get-CimInstance 기반 점검/도구가 조용히 실패한다.
#   Microsoft 권장 순서는 verify → (불일치 시) salvage 이며, rebuild 는 최후 수단이다.
#   실측 비용: winmgmt /verifyrepository 1.3s.
try {
  $wmiVerify = & winmgmt /verifyrepository 2>&1 | Out-String
  # 주의: winmgmt 도 stdout 리다이렉션 시 OS 표시 언어로 출력한다("WMI 리포지토리가 일관적입니다.").
  #   영문만 매칭하면 항상 "판정 불가(SKIP)" 로 새서 손상 여부를 놓친다(2026-11-10 실측).
  #   부정(불일치)을 먼저 본다 — "일관적이지 않습니다" 안에 "일관적" 이 들어 있기 때문.
  $wmiBad = $wmiVerify -match '(?im)(WMI repository is inconsistent|일관적이지|일관되지|일관성이 없|불일치)'
  $wmiGood = $wmiVerify -match '(?im)(WMI repository is consistent|일관적입니다|일관됩니다|일관성이 있)'
  if ($wmiBad) {
    Write-LogEntry 'WMI: WARN - 리포지토리 불일치 → salvage 시도'
    $null = & winmgmt /salvagerepository 2>&1
    $wmiVerify2 = & winmgmt /verifyrepository 2>&1 | Out-String
    if ($wmiVerify2 -match '(?im)(WMI repository is consistent|일관적입니다|일관됩니다|일관성이 있)') {
      Write-LogEntry 'WMI: CHANGE - 리포지토리 복구 완료 (salvagerepository)'
      Add-AutoFix 'WMI 리포지토리 불일치 → winmgmt /salvagerepository 로 복구'
    } else {
      Write-LogEntry 'WMI: FAIL - 리포지토리 복구 실패'
      $allPass = $false
      $failureReasons += '[WMI] WMI 리포지토리 손상이 자동 복구되지 않음'
      $recommendations += '[WMI] 관리자 PowerShell에서 winmgmt /resetrepository 실행 후 재부팅 (마지막 수단)'
    }
  } elseif ($wmiGood) {
    Write-LogEntry 'WMI: PASS - 리포지토리 정상'
  } else {
    $wmiFirst = ($wmiVerify.Trim() -split "`r?`n")[0]
    Write-LogEntry "WMI: SKIP - 판정 불가 ($wmiFirst)"
  }
} catch {
  Write-LogEntry "WMI: SKIP - 점검 실패 ($($_.Exception.Message))"
}

# --- 로컬 컴퓨터 인증서 만료 ---
Write-ProgressBar "CertStore"
Write-TestHeader "[CertStore] 로컬 컴퓨터 인증서의 만료 임박/만료 상태를 확인합니다."
# 배경: RDP/IIS/개발용 인증서가 조용히 만료되면 인증 실패가 산발적으로 발생한다.
#   갱신 여부는 소유자가 결정할 일이라 자동 교체하지 않고 만료 전에 알리기만 한다.
#   실측 비용: 전체 스토어 스캔 0.4s 이하.
try {
  $certWarnDays = 30
  $certNow = Get-Date
  $certIssues = @()
  $certTotal = 0
  foreach ($storePath in @('Cert:\LocalMachine\My', 'Cert:\LocalMachine\WebHosting')) {
    if (-not (Test-Path -LiteralPath $storePath)) { continue }
    foreach ($cert in (Get-ChildItem $storePath -ErrorAction SilentlyContinue)) {
      $certTotal++
      $daysLeft = [int][math]::Floor(($cert.NotAfter - $certNow).TotalDays)
      $cn = if ($cert.Subject -match 'CN=([^,]+)') { $Matches[1] } else { [string]$cert.Subject }
      if ($daysLeft -lt 0) {
        $certIssues += "만료 ${daysLeft}일: $cn (${storePath})"
      } elseif ($daysLeft -le $certWarnDays) {
        $certIssues += "${daysLeft}일 남음: $cn (${storePath})"
      }
    }
  }
  if ($certIssues.Count -gt 0) {
    Write-LogEntry "CertStore: WARN - 만료/임박 $($certIssues.Count)건 (전체 ${certTotal}건)"
    foreach ($ci in $certIssues) { Write-LogEntry "  $ci" }
    $recommendations += "[CertStore] 인증서 $($certIssues.Count)건 만료/임박 — certlm.msc 에서 갱신하거나 불필요 인증서를 제거하세요."
  } else {
    Write-LogEntry "CertStore: PASS - 만료 임박 인증서 없음 (전체 ${certTotal}건)"
  }
} catch {
  Write-LogEntry "CertStore: SKIP - 점검 실패 ($($_.Exception.Message))"
}

# --- 유지보수 자동화 예약 작업의 건강 상태 ---
Write-ProgressBar "TaskHealth"
Write-TestHeader "[TaskHealth] 유지보수 자동화에 쓰는 예약 작업이 정상 실행 중인지 확인합니다."
# 배경: 2026-11-01, OpenCode-Maintenance 태스크가 PS7 전용 문법 때문에 "한 번도 실행되지 않은 채"
#   몇 달을 조용히 지나간 사례가 있었다. 스크립트가 자기 자동화의 생존을 확인하지 않으면 같은 사고가
#   재발해도 알 수 없다. 다른 업체 작업(게임 런처 등)은 결과 코드가 정상적으로 비-0 인 경우가 흔해
#   노이즈가 되므로 config `watchedTasks` 에 적은 작업만 본다(실측: 비MS 작업 33개 중 11개가 비-0).
#   실측 비용: 4개 작업 Get-ScheduledTaskInfo 합계 0.2s.
try {
  $watched = @(Get-Cfg 'watchedTasks')
  $maxAgeDays = [int](Get-Cfg 'watchedTaskMaxAgeDays')
  $watchProblems = @()
  $watchChecked = 0
  # 비용 실측: COM(Task Scheduler) 4개 작업 0.28s vs Get-ScheduledTask 작업당 ~1.2s(전체 290개 열거).
  $tsSvc = $null
  try { $tsSvc = New-Object -ComObject 'Schedule.Service'; $null = $tsSvc.Connect() } catch { $tsSvc = $null }
  foreach ($wt in $watched) {
    if ([string]::IsNullOrWhiteSpace($wt)) { continue }
    $parts = $wt.Split('\')
    $tName = $parts[-1]
    $tPath = if ($parts.Count -gt 2) { ($parts[0..($parts.Count - 2)] -join '\') + '\' } else { '\' }
    $state = 0
    $lastResult = 0
    $lastRun = $null
    $exists = $true
    if ($tsSvc) {
      try {
        $folderPath = if ($tPath -eq '\') { '\' } else { $tPath.TrimEnd('\') }
        $t = $tsSvc.GetFolder($folderPath).GetTask($tName)
        $state = [int]$t.State
        $lastResult = [int]$t.LastTaskResult
        try { if ($t.LastRunTime -and ([datetime]$t.LastRunTime).Year -gt 1900) { $lastRun = [datetime]$t.LastRunTime } } catch { }
      } catch { $exists = $false }
    } else {
      $task = Get-ScheduledTask -TaskName $tName -TaskPath $tPath -ErrorAction SilentlyContinue
      if (-not $task) { $exists = $false } else {
        $ti = Get-ScheduledTaskInfo -TaskName $tName -TaskPath $tPath -ErrorAction SilentlyContinue
        $state = if ($task.State -eq 'Disabled') { 1 } elseif ($task.State -eq 'Running') { 4 } else { 3 }
        if ($ti) {
          $lastResult = [int]$ti.LastTaskResult
          try { if ($ti.LastRunTime) { $lastRun = [datetime]$ti.LastRunTime } } catch { }
        }
      }
    }
    if (-not $exists) {
      # 이 키트가 직접 만드는 작업만 "없음"을 문제로 본다. 그 밖의 감시 목록은 다른 PC에 없을 수 있으므로
      #   정보(INFO)로만 남긴다 — 새 PC 설치 직후 TaskHealth WARN 이 쏟아지는 것을 막는다.
      if ($wt -ieq '\OpenCode-Maintenance') { $watchProblems += "없음: $wt" }
      else { Write-LogEntry "TaskHealth: INFO - 감시 작업 없음(무시): $wt" }
      continue
    }
    $watchChecked++
    if ($state -eq 1) { $watchProblems += "비활성: $wt"; continue }
    # 267009 = 실행 중, 267011 = 아직 실행 안 됨 (둘 다 실패가 아니다)
    if ($lastResult -ne 0 -and $lastResult -ne 267009 -and $lastResult -ne 267011) {
      $watchProblems += ("결과 {0}: {1}" -f $lastResult, $wt)
    }
    if ($lastRun -and $maxAgeDays -gt 0) {
      $ageDays = [int]((Get-Date).Subtract($lastRun).TotalDays)
      if ($ageDays -gt $maxAgeDays) {
        Write-LogEntry ("TaskHealth: INFO - {0} 마지막 실행 {1:yyyy-MM-dd} ({2}일 전)" -f $wt, $lastRun, $ageDays)
      }
    }
  }
  if ($watchProblems.Count -eq 0) {
    Write-LogEntry "TaskHealth: PASS - 감시 작업 ${watchChecked}개 정상"
  } else {
    Write-LogEntry "TaskHealth: WARN - 문제 $($watchProblems.Count)건: $($watchProblems -join ' | ')"
    foreach ($wp in $watchProblems) { $recommendations += "[TaskHealth] 예약 작업 확인: $wp" }
  }
} catch {
  Write-LogEntry "TaskHealth: SKIP - 점검 실패 ($($_.Exception.Message))"
}

# --- GPU 상태 진단 (NVIDIA/AMD/Intel 등 모든 GPU 지원) ---
Write-ProgressBar "GPU"
Write-TestHeader "[GPU] 모든 GPU의 상태와 드라이버 충돌 이벤트를 확인합니다."
try {
  $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
  if ($gpus) {
    foreach ($gpu in $gpus) {
      Write-LogEntry "GPU: PASS - $($gpu.Name) (Driver: $($gpu.DriverVersion), $($gpu.Status))"
    }
  } else {
    Write-LogEntry 'GPU: PASS - No display adapters detected'
  }
  # NVIDIA 추가 정보 (nvidia-smi)
  if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $nvidiaRaw = nvidia-smi --query-gpu=name,driver_version,temperature.gpu,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader -ErrorAction SilentlyContinue
    if ($nvidiaRaw) {
      foreach ($line in ($nvidiaRaw -split "`n" | Where-Object { $_ -ne '' })) {
        $parts = @($line -split ', ' | ForEach-Object { $_.Trim() })
        if ($parts.Count -ge 5) {
          Write-LogEntry "GPU: PASS - NVIDIA ($($parts[0])): Driver $($parts[1]), Temp $($parts[2])C, PCIe Gen$($parts[3]) x$($parts[4])"
        }
      }
    }
  }
  # GPU 드라이버 충돌 확인 (Event ID 4101) - 모든 GPU 공통
  $gpuCrash = Get-WinEvent -FilterHashtable @{LogName='System'; Id=4101; StartTime=(Get-Date).AddDays(-30)} -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($gpuCrash) {
    Write-LogEntry "GPU: WARN - Display driver crash on $($gpuCrash.TimeCreated.ToString('yyyy-MM-dd HH:mm'))"
    $failureReasons += "[GPU] 그래픽 드라이버 충돌 발생 (Event ID 4101, $($gpuCrash.TimeCreated.ToString('yyyy-MM-dd')))"
    $recommendations += "[GPU] 그래픽 드라이버 충돌이 감지되었습니다. GPU 제조사 사이트에서 최신 드라이버로 업데이트하거나 DDU로 기존 드라이버를 완전 제거 후 재설치하세요."
  }
} catch {
  Write-LogEntry "GPU: SKIP - GPU check failed: $_"
}

# --- 배터리 상태 확인 (노트북 전용) ---
Write-ProgressBar "Battery"
Write-TestHeader "[Battery] 배터리 잔존 수명을 확인하여 교체 시기를 알립니다."
try {
  $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
  if (-not $battery) {
    Write-LogEntry 'Battery: SKIP - No battery found (desktop PC)'
  } else {
    # AC 어댑터 연결 상태 (BatteryStatus: 1=방전중, 2=AC연결됨)
    $acStatus = switch ($battery.BatteryStatus) { 1 { 'Discharging' } 2 { 'On AC' } default { 'Unknown' } }
    $acMsg = if ($acStatus -eq 'On AC') { 'PASS' } elseif ($acStatus -eq 'Discharging') { 'WARN' } else { 'INFO' }
    Write-LogEntry "Battery: $acMsg - AC adapter status: $acStatus"
    $designed = $battery.DesignCapacity
    $current = $battery.FullChargeCapacity
    if ($designed -gt 0 -and $current -gt 0) {
      $health = [math]::Round(($current / $designed) * 100, 1)
      if ($health -lt 50) {
        Write-LogEntry "Battery: WARN - Health at ${health}% (${current}mWh / ${designed}mWh) - Replacement recommended"
        $failureReasons += "[Battery] 배터리 수명 ${health}% - 교체 권장"
        $recommendations += "[Battery] 배터리 수명이 ${health}%입니다. 배터리 교체를 권장합니다."
      } else {
        Write-LogEntry "Battery: PASS - Health at ${health}% (${current}mWh / ${designed}mWh)"
      }
    } else {
      Write-LogEntry 'Battery: PASS - Capacity data not available'
    }
  }
} catch {
  Write-LogEntry "Battery: SKIP - Unable to check battery: $_"
}

# --- WHEA 하드웨어 에러 모니터링 (Event ID 3, 17~21, 46~48) ---
Write-ProgressBar "WHEA"
Write-TestHeader "[WHEA] 하드웨어 오류(Microsoft-Windows-WHEA-Logger) 이벤트 발생 여부와 원인 구성 요소를 추적합니다."
try {
  # 주의: 공급자 이름은 'Microsoft-Windows-WHEA-Logger' (구버전 표기 'WHEA-Logger'는 조회 실패)
  $wheaEvents = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; Id=3,17,18,19,20,21,46,47,48; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue | Select-Object -First 10
  $wheaCount = @($wheaEvents).Count
  if ($wheaCount -gt 0) {
    Write-LogEntry "WHEA: WARN - $wheaCount hardware error(s) in last 7 days"
    $wheaAllText = ''
    foreach ($evt in $wheaEvents) {
      # 원인 구성 요소 추정: WHEA 이진 데이터(Byte[])를 ASCII로 풀어 드라이버/장치 토큰 검색
      $raw = ([string]$evt.ToXml())
      try {
        foreach ($prop in $evt.Properties) {
          if ($prop.Value -is [byte[]]) {
            $raw += ' ' + (-join ($prop.Value | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } }))
          } else { $raw += ' ' + [string]$prop.Value }
        }
      } catch { }
      $wheaAllText += ' ' + $raw
      $hint = ''
      if ($raw -match '(?i)STORPORT|storport\.sys|storahci') { $hint = '저장장치/스토리지 드라이버(STORPORT/storahci) — SSD/HDD 상태·케이블·포트 점검' }
      elseif ($raw -match '(?i)nvme') { $hint = 'NVMe 장치 — SSD 펌웨어/슬롯 점검' }
      elseif ($raw -match '(?i)PCIe|PCIE') { $hint = 'PCIe 장치 — 슬롯 재장착·전원·라이저 점검' }
      elseif ($raw -match '(?i)ECC|memory') { $hint = '메모리 — MemTest86 진단' }
      $devHint = ''
      if ($raw -match '(?i)(SanDisk|Samsung|Crucial|WDC|WD[0-9]|Seagate|Micron|SK ?hynix|CT[0-9]{3,})[ ._\-]{0,3}([A-Z0-9]{4,}[A-Z0-9 ._\-]{0,20})') { $devHint = " [장치: $(($Matches[0] -replace '[._]', ' ').Trim())]" }
      Write-LogEntry "  [$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm'))] ID $($evt.Id) - $($evt.LevelDisplayName)${devHint}$(if ($hint) { " → $hint" })"
    }
    $failureReasons += "[WHEA] 7일 내 하드웨어 오류 ${wheaCount}건 감지"
    if ($wheaAllText -match '(?i)STORPORT|storport\.sys|storahci') {
      $recommendations += "[WHEA] 이벤트 원시 데이터에 STORPORT(스토리지 스택) 흔적이 있습니다. CPU 전압 문제로 단정하지 말고 SSD/HDD SMART·케이블·포트를 우선 점검하세요."
    } else {
      $recommendations += "[WHEA] 하드웨어 오류(WHEA)가 감지되었습니다. 원시 데이터의 ErrorSource/드라이버 토큰을 확인하고, CPU/메모리 오버클럭 설정 또는 문제 장치를 점검하세요."
    }
  } else {
    Write-LogEntry 'WHEA: PASS - No hardware errors in last 7 days'
  }
} catch {
  Write-LogEntry "WHEA: SKIP - Unable to query WHEA event log ($($_.Exception.Message))"
}

# --- 드라이버 스토어(DriverStore) 오래된 드라이버 분석 ---
Write-ProgressBar "DriverStore"
Write-TestHeader "[DriverStore] 드라이버 저장소(FileRepository) 용량을 분석합니다."
try {
  $driverStorePath = "$env:windir\System32\DriverStore\FileRepository"
  if (Test-Path -LiteralPath $driverStorePath) {
    $oemDirs = Get-ChildItem -Path $driverStorePath -Directory -ErrorAction SilentlyContinue
    $oemCount = @($oemDirs).Count
    $totalSizeGB = [math]::Round(((Get-ChildItem -Path $driverStorePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum) / 1GB, 2)
    if ($totalSizeGB -gt 10) {
      Write-LogEntry "DriverStore: WARN - ${totalSizeGB}GB ($oemCount packages) - consider cleaning with DISM"
      $failureReasons += "[DriverStore] 드라이버 저장소 ${totalSizeGB}GB - DISM 정리 필요"
    } else {
      Write-LogEntry "DriverStore: PASS - ${totalSizeGB}GB ($oemCount packages)"
    }
  } else {
    Write-LogEntry 'DriverStore: SKIP - Path not found'
  }
} catch {
  Write-LogEntry "DriverStore: SKIP - Unable to analyze: $_"
}

# --- 브라우저 캐시 정리 (30일 이상 경과) ---
Write-ProgressBar "BrowserCache"
Write-TestHeader "[BrowserCache] 오래된 브라우저 캐시 파일을 삭제하여 공간을 확보합니다."
try {
  $cacheCutoff = (Get-Date).AddDays(-30)
  $browserPaths = @(
    "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
    "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",
    "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache"
  )
  $totalCleaned = 0
  $cleanedCount = 0
  # 삭제 전에 "어느 파일을 지울지" 모아서 한 번에 확인한다(2026-11-12).
  $cacheCands = @()
  foreach ($bp in $browserPaths) {
    if (Test-Path -LiteralPath $bp) {
      try {
        $oldFiles = @(Get-ChildItem -Path $bp -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cacheCutoff })
        if ($oldFiles.Count -gt 0) {
          foreach ($of in $oldFiles) {
            $cacheCands += [pscustomobject]@{ Name = $of.FullName; Size = [double]$of.Length; Date = $of.LastWriteTime }
          }
        }
      } catch { Write-LogEntry "BrowserCache: WARN - Scan error: $_" }
    }
  }
  if ($cacheCands.Count -gt 0) {
    $dumpCands = $cacheCands
    $approved = Invoke-DeleteReview -Target '브라우저 캐시 (30일 이상)' -Items $dumpCands -PolicyKey 'browserCacheAutoDelete' -DeleteAction {
      foreach ($c in $dumpCands) { try { Remove-Item -LiteralPath $c.Name -Force -ErrorAction SilentlyContinue } catch { } }
    }
    if ($approved) {
      foreach ($c in $dumpCands) { $totalCleaned += [double]$c.Size; $cleanedCount++ }
    }
  }
  if ($totalCleaned -gt 0) {
    Write-LogEntry "BrowserCache: PASS - Removed $([math]::Round($totalCleaned/1MB,1))MB browser cache (older than 30d)"
    Add-AutoFix ("브라우저 캐시 {0}MB 정리 (30일 이상 경과, {1}개 파일)" -f [math]::Round($totalCleaned / 1MB, 1), $cleanedCount)
  } elseif ($cacheCands.Count -gt 0) {
    Write-LogEntry 'BrowserCache: SKIP - 사용자가 지우지 않기로 함'
  } else {
    Write-LogEntry 'BrowserCache: PASS - No old browser cache to clean'
  }
} catch {
  Write-LogEntry "BrowserCache: SKIP - Error cleaning browser cache: $_"
}

# --- Hosts 파일 변조 확인 ---
Write-ProgressBar "HostFile"
Write-TestHeader "[HostFile] HOSTS 파일에 비정상적인 엔트리가 있는지 확인합니다."
try {
  $hostsPath = "$env:windir\System32\drivers\etc\hosts"
  if (Test-Path -LiteralPath $hostsPath) {
    $hostsContent = Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue
    $suspicious = @()
    foreach ($line in $hostsContent) {
      $trimmed = $line.Trim()
      if ($trimmed -and $trimmed -notmatch '^#' -and $trimmed -notmatch '^\s*$') {
        $parts = $trimmed -split '\s+'
        if ($parts.Count -ge 2) {
          $ip = $parts[0]
          $domain = $parts[1]
          if ($ip -notin @('127.0.0.1', '::1', '255.255.255.255', '0.0.0.0') -and $domain -notmatch '^localhost$') {
            $suspicious += "$domain -> $ip"
          }
        }
      }
    }
    if ($suspicious) {
      Write-LogEntry 'HostFile: WARN - Suspicious entries found:'
      foreach ($s in $suspicious) { Write-LogEntry "  $s" }
      $failureReasons += "[HostFile] HOSTS 파일에 의심스러운 항목 $($suspicious.Count)건 발견"
    } else {
      Write-LogEntry 'HostFile: PASS - No suspicious entries'
    }
    # 2026-11-09: hosts 는 와일드카드를 지원하지 않는다(예: "0.0.0.0 *.example.com").
    #   이런 줄은 에러 없이 저장되지만 아무것도 차단하지 않아 사용자가 "막았다"고 오해한다.
    $deadWildcard = @()
    foreach ($line in $hostsContent) {
      $t = $line.Trim()
      if (-not $t -or $t.StartsWith('#')) { continue }
      $p = $t -split '\s+'
      if ($p.Count -ge 2 -and $p[1].Contains('*')) { $deadWildcard += $t }
    }
    if ($deadWildcard.Count -gt 0) {
      Write-LogEntry "HostFile: WARN - hosts 와일드카드 $($deadWildcard.Count)줄은 작동하지 않습니다: $(($deadWildcard | Select-Object -First 3) -join ' | ')"
      $recommendations += "[HostFile] hosts 의 와일드카드 줄 $($deadWildcard.Count)개는 Windows 가 지원하지 않아 차단되지 않습니다. 정확한 호스트명으로 바꾸세요: $(($deadWildcard | Select-Object -First 2) -join ', ')"
    }
  } else {
    Write-LogEntry 'HostFile: SKIP - Hosts file not found'
  }
} catch {
  Write-LogEntry "HostFile: SKIP - Unable to check hosts file: $_"
}

# --- DNS 캐시 플러시 ---
Write-ProgressBar "DNS"
Write-TestHeader "[DNS] DNS 캐시를 플러시하여 네트워크 이름 해결 문제를 개선합니다."
try {
  $null = ipconfig /flushdns 2>&1
  Write-LogEntry 'DNS: PASS - DNS cache flushed'
} catch {
  Write-LogEntry 'DNS: SKIP - Unable to flush DNS cache'
}

# ============================================================
# 광고/추천 끄기 (AdQuiet)  [2026-11-09]
# ============================================================
# 배경: Windows 11 은 기본값이 "광고 ON" 이라 새 PC/재설치 후 프로모션이 다시 나타난다.
#   끄는 공식 스위치는 대부분 HKCU 레지스트리 값이고 전부 되돌릴 수 있다.
#   파일 삭제/앱 제거/서드파티 업데이트 중지는 하지 않는다(시스템 구성요소는 스위치만 끈다).
#   되돌리기 데이터: adbackup\ad-state.json  →  uninstall.ps1 -RestoreAds
#   ⚠ adQuiet=false 로 바꾸면 "이전에 바꾼 값을 자동으로 되돌린다" (완전 가역).
Write-ProgressBar "AdQuiet"
Write-TestHeader "[AdQuiet] Windows 광고/추천/프로모션 스위치를 끕니다(HKCU, 되돌릴 수 있음)."
try {
  $adStatePath = Join-Path $script:adBackupDir 'ad-state.json'
  $adState = Get-JsonState $adStatePath
  $isSystemCtx = $false
  try { $isSystemCtx = ([Security.Principal.WindowsIdentity]::GetCurrent().Name -match '\\SYSTEM$') } catch { }

  if (-not (Get-Cfg 'adQuiet')) {
    if (Test-Path -LiteralPath $adStatePath) {
      $restored = 0
      foreach ($sv in @($adState['values'])) {
        if ($null -eq $sv) { continue }
        try {
          if ($sv.existed) { Set-ItemProperty -Path $sv.path -Name $sv.name -Value $sv.value -ErrorAction Stop }
          else { Remove-ItemProperty -Path $sv.path -Name $sv.name -ErrorAction SilentlyContinue }
          $restored++
        } catch { }
      }
      foreach ($st in @($adState['tasks'])) {
        if ($null -eq $st) { continue }
        try {
          $null = Enable-ScheduledTask -TaskPath $st.path -TaskName $st.name -ErrorAction Stop
          $restored++
        } catch { }
      }
      Remove-Item -LiteralPath $adStatePath -Force -ErrorAction SilentlyContinue
      if ($restored -gt 0) { Add-AutoFix "광고/추천 설정 원래대로 복원 ($restored 항목)" }
      Write-LogEntry "AdQuiet: PASS - adQuiet=false 이므로 이전에 바꾼 설정을 복원했습니다 ($restored 항목)"
      $script:adStatus.quiet = 'restored'
    } else {
      Write-LogEntry 'AdQuiet: SKIP - 설정에서 꺼져 있음(adQuiet=false)'
      $script:adStatus.quiet = 'off'
    }
  } elseif ($isSystemCtx) {
    Write-LogEntry 'AdQuiet: SKIP - SYSTEM 계정에서 실행 중이라 사용자 설정(HKCU)을 건드리지 않습니다.'
    $script:adStatus.quiet = 'skip(system)'
  } else {
    if (-not (Test-Path -LiteralPath $script:adBackupDir)) { $null = New-Item -ItemType Directory -Path $script:adBackupDir -Force }
    $savedValues = @()
    $savedKeys = @{}
    foreach ($sv in @($adState['values'])) {
      if ($null -eq $sv) { continue }
      $savedValues += $sv
      $savedKeys[("{0}|{1}" -f $sv.path, $sv.name)] = $true
    }

    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $targets = @(
      @{ Path = $cdm; Name = 'ContentDeliveryAllowed';               Value = 0 },
      @{ Path = $cdm; Name = 'SubscribedContent-LocksreenEnabled';   Value = 0 },
      @{ Path = $cdm; Name = 'SubscribedContent-338387Enabled';      Value = 0 },
      @{ Path = $cdm; Name = 'SubscribedContent-338388Enabled';      Value = 0 },
      @{ Path = $cdm; Name = 'SubscribedContent-338389Enabled';      Value = 0 },
      @{ Path = $cdm; Name = 'SubscribedContent-338393Enabled';      Value = 0 },
      @{ Path = $cdm; Name = 'SubscribedContent-353694Enabled';      Value = 0 },
      @{ Path = $cdm; Name = 'SubscribedContent-353696Enabled';      Value = 0 },
      @{ Path = $cdm; Name = 'SubscribedContent-353698Enabled';      Value = 0 },
      @{ Path = $cdm; Name = 'PreInstalledAppsEnabled';              Value = 0 },
      @{ Path = $cdm; Name = 'OemPreInstalledAppsEnabled';           Value = 0 },
      @{ Path = $cdm; Name = 'PreInstalledAppsEverEnabled';          Value = 0 },
      @{ Path = $cdm; Name = 'SilentInstalledAppsEnabled';           Value = 0 },
      @{ Path = $cdm; Name = 'SystemPaneSuggestionsEnabled';         Value = 0 },
      @{ Path = $cdm; Name = 'SoftLandingEnabled';                   Value = 0 },
      @{ Path = $cdm; Name = 'RotatingLockScreenOverlayEnabled';     Value = 0 },
      @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0 },
      @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Value = 0 },
      @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_IrisRecommendations'; Value = 0 }
      # TaskbarDa(위젯 버튼)는 넣지 않는다: 2026-11-09 실측에서 Windows 11 이 쓰기를 거부(Access denied)했고,
      #   위젯은 화면에서 바로 보이는 UI 변경이라 "광고 끄기" 범위를 넘는다. 사용자가 직접 토글.
    )
    if (-not (Get-Cfg 'adQuietKeepLockScreen')) {
      $targets += @{ Path = $cdm; Name = 'RotatingLockScreenEnabled'; Value = 0 }
    }
    if (Get-Cfg 'adQuietMutePromoToasts') {
      $targets += @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested'; Name = 'Enabled'; Value = 0 }
      $targets += @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'LockScreenToastEnabled'; Value = 0 }
    }

    $changes = @()
    foreach ($t in $targets) {
      try {
        if (-not (Test-Path -LiteralPath $t.Path)) { $null = New-Item -Path $t.Path -Force -ErrorAction Stop }
        $prop = $null
        try { $prop = (Get-ItemProperty -Path $t.Path -ErrorAction Stop).PSObject.Properties[$t.Name] } catch { }
        $exists = ($null -ne $prop)
        $cur = if ($exists) { $prop.Value } else { $null }
        $key = ("{0}|{1}" -f $t.Path, $t.Name)
        if (-not $savedKeys.ContainsKey($key)) {
          $savedValues += @{ path = $t.Path; name = $t.Name; existed = $exists; value = $cur }
          $savedKeys[$key] = $true
        }
        if (-not $exists -or "$cur" -ne "$($t.Value)") {
          Set-ItemProperty -Path $t.Path -Name $t.Name -Value $t.Value -Type DWord -ErrorAction Stop
          $changes += $t.Name
        }
      } catch {
        Write-LogEntry "AdQuiet: WARN - $($t.Name) 설정 실패: $($_.Exception.Message)"
      }
    }

    # 팁/광고 알림을 쏘는 SoftLanding 예약 작업 비활성 (되돌리기는 Enable-ScheduledTask)
    $savedTasks = @()
    foreach ($st in @($adState['tasks'])) { if ($null -ne $st) { $savedTasks += $st } }
    $savedTaskKeys = @{}
    foreach ($st in $savedTasks) { $savedTaskKeys[("{0}|{1}" -f $st.path, $st.name)] = $true }
    if (Get-Cfg 'adQuietDisableTipsTasks') {
      $adTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -like '\SoftLanding\*' })
      foreach ($task in $adTasks) {
        try {
          $k = ("{0}|{1}" -f $task.TaskPath, $task.TaskName)
          if (-not $savedTaskKeys.ContainsKey($k)) {
            $savedTasks += @{ path = $task.TaskPath; name = $task.TaskName }
            $savedTaskKeys[$k] = $true
          }
          if ($task.State -ne 'Disabled') {
            $null = Disable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop
            $changes += "task:$($task.TaskName)"
          }
        } catch {
          # 2026-11-16: Microsoft 보호 작업(SoftLanding 등)은 관리자여도 Access is denied 로 실패한다.
          #   매 실행 반복되는 해결 불가 WARN 은 사용자를 피로하게 하므로 SKIP + 설명으로 남긴다.
          Write-LogEntry "AdQuiet: SKIP - 작업 비활성 불가 $($task.TaskName): $($_.Exception.Message) (Windows 보호 작업이면 정상 — 무시해도 됩니다)"
        }
      }
    }

    $adState['created'] = if ($adState.ContainsKey('created')) { $adState['created'] } else { (Get-Date).ToString('o') }
    $adState['values'] = @($savedValues)
    $adState['tasks'] = @($savedTasks)
    Save-JsonState $adStatePath $adState

    if ($changes.Count -gt 0) {
      Add-AutoFix "광고/추천 설정 끔 $(($changes | Select-Object -First 6) -join ', ')$(if ($changes.Count -gt 6) { " 외 $($changes.Count - 6)개" } else { '' })"
      Write-LogEntry "AdQuiet: PASS - $($changes.Count)개 설정을 껐습니다"
      $script:adStatus.quiet = "on($($changes.Count) changed)"
      $script:adStatus.changes = @($changes)
      $script:adWarning += '광고/추천 스위치를 껐습니다 → 설정·시작 메뉴의 "추천/팁"과 잠금화면 문구가 달라질 수 있습니다(기능에는 영향 없음).'
    } else {
      Write-LogEntry 'AdQuiet: PASS - 이미 모두 꺼져 있음(변경 없음)'
      $script:adStatus.quiet = 'on(no change)'
      $script:adWarning += '광고/추천 스위치는 이미 꺼져 있습니다 → 설정·시작 메뉴의 "추천/팁"이 보이지 않는 것이 정상입니다.'
    }
  }
} catch {
  Write-LogEntry "AdQuiet: WARN - 광고 설정 처리 실패: $($_.Exception.Message)"
  $recommendations += "[AdQuiet] 광고/추천 설정을 처리하지 못했습니다: $($_.Exception.Message)"
}

# ============================================================
# 광고 도메인 차단 (AdFilter: hosts + DNS)  [2026-11-09]
# ============================================================
# 기본값은 꺼짐(adBlockEnabled=false / adDnsEnabled=false). 사용자가 켜야 동작한다.
#   hosts 는 정확한 호스트명만 막는다(와일드카드 불가). 마커 블록만 교체하므로 사용자 줄은 보존.
#   최초 1회 hosts.orig.bak 백업, DNS 는 어댑터별 이전 값을 dns-state.json 에 저장 → 복원 가능.
Write-ProgressBar "AdFilter"
Write-TestHeader "[AdFilter] hosts/DNS 로 광고·추적 도메인을 차단합니다(기본 꺼짐, 설정에서 켜야 동작)."
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$markerStart = '# >>> AutoMaintenance AdBlock v1 >>>'
$markerEnd = '# <<< AutoMaintenance AdBlock v1 <<<'
# 기본 목록: 광고 서버(ads) / 추적 스크립트(trackers). 정확한 호스트명만 넣는다.
$adsDomains = @(
  'doubleclick.net',
  'googlesyndication.com',
  'pagead2.googlesyndication.com',
  'tpc.googlesyndication.com',
  'securepubads.g.doubleclick.net',
  'pubads.g.doubleclick.net',
  'ad.doubleclick.net',
  'static.doubleclick.net',
  'stats.g.doubleclick.net',
  'googleads.g.doubleclick.net',
  'adservice.google.com',
  'www.googleadservices.com',
  'partner.googleadservices.com',
  'ads.youtube.com',
  'ads.linkedin.com',
  'ads.tiktok.com',
  'an.facebook.com',
  'ads.yahoo.com',
  'ads.yap.yahoo.com',
  'adserver.yahoo.com',
  'ads.bing.com',
  'bat.bing.com',
  'c.bing.com',
  'ads.reddit.com',
  'c.amazon-adsystem.com',
  's.amazon-adsystem.com',
  'aax.amazon-adsystem.com'
)
$trackerDomains = @(
  'www.google-analytics.com',
  'google-analytics.com',
  'ssl.google-analytics.com',
  'www.googletagmanager.com',
  'connect.facebook.net',
  'script.hotjar.com',
  'static.hotjar.com',
  'sb.scorecardresearch.com',
  'b.scorecardresearch.com',
  'mc.yandex.ru',
  'top-fwz1.mail.ru',
  'hm.baidu.com',
  'pixel.quantserve.com',
  'www.statcounter.com',
  'c.statcounter.com'
)
try {
  if (-not (Test-Path -LiteralPath $script:adBackupDir)) { $null = New-Item -ItemType Directory -Path $script:adBackupDir -Force }
  if (-not (Test-Path -LiteralPath $hostsPath)) {
    Write-LogEntry 'AdFilter: WARN - hosts 파일을 찾을 수 없습니다.'
    $script:adStatus.hosts = 'off(no hosts)'
  } else {
    $backupPath = Join-Path $script:adBackupDir 'hosts.orig.bak'
    if (-not (Test-Path -LiteralPath $backupPath)) { Copy-Item -LiteralPath $hostsPath -Destination $backupPath -Force -ErrorAction Stop }
    $raw = [IO.File]::ReadAllText($hostsPath, [Text.Encoding]::Default)
    $kept = New-Object System.Collections.ArrayList
    $inBlock = $false
    foreach ($ln in @($raw -split "`r?`n")) {
      $t = $ln.Trim()
      if ($t -eq $markerStart) { $inBlock = $true; continue }
      if ($t -eq $markerEnd) { $inBlock = $false; continue }
      if (-not $inBlock) { $null = $kept.Add($ln) }
    }
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string]$kept[$kept.Count - 1])) { $kept.RemoveAt($kept.Count - 1) }

    $domainCount = 0
    if (Get-Cfg 'adBlockEnabled') {
      $cats = @(Get-Cfg 'adBlockCategories')
      $list = @()
      if ($cats -contains 'ads') { $list += $adsDomains }
      if ($cats -contains 'trackers') { $list += $trackerDomains }
      $badExtra = @()
      foreach ($d in @(Get-Cfg 'adBlockExtraDomains')) {
        $t = ([string]$d).Trim().ToLowerInvariant()
        if (-not $t) { continue }
        if ($t -notmatch '^[a-z0-9]([a-z0-9\-]{0,62}\.)+[a-z]{2,}$') { $badExtra += $t; continue }
        $list += $t
      }
      if ($badExtra.Count -gt 0) {
        Write-LogEntry "AdFilter: WARN - adBlockExtraDomains 형식 오류 $($badExtra.Count)개: $(($badExtra | Select-Object -First 3) -join ', ')"
        $recommendations += "[AdFilter] adBlockExtraDomains 에는 정확한 도메인만 넣으세요(와일드카드/URL 불가): $(($badExtra | Select-Object -First 3) -join ', ')"
      }
      $allow = @(@(Get-Cfg 'adBlockAllowDomains') | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
      if ($allow.Count -gt 0) { $list = @($list | Where-Object { $allow -notcontains $_ }) }
      $list = @($list | Select-Object -Unique)
      $maxD = [int](Get-Cfg 'adBlockMaxDomains')
      if ($maxD -gt 0 -and $list.Count -gt $maxD) {
        Write-LogEntry "AdFilter: WARN - 도메인 $($list.Count)개가 상한($maxD)을 넘어 앞에서 $maxD 개만 적용합니다."
        $list = @($list | Select-Object -First $maxD)
      }
      if ($list.Count -eq 0) {
        Write-LogEntry 'AdFilter: WARN - 적용할 도메인이 없습니다(카테고리/허용 목록 확인).'
      } else {
        $null = $kept.Add('')
        $null = $kept.Add($markerStart)
        foreach ($d in $list) { $null = $kept.Add("0.0.0.0 $d") }
        $null = $kept.Add($markerEnd)
        $domainCount = $list.Count
      }
    }
    $newText = (($kept -join "`r`n").TrimEnd()) + "`r`n"
    $changedHosts = (($newText -replace "`r`n", "`n") -ne ($raw -replace "`r`n", "`n"))
    if ($changedHosts) { [IO.File]::WriteAllText($hostsPath, $newText, [Text.Encoding]::Default) }
    $checkText = if ($changedHosts) { [IO.File]::ReadAllText($hostsPath, [Text.Encoding]::Default) } else { $newText }
    if ($domainCount -gt 0) {
      $verifyCount = @([regex]::Matches($checkText, '(?m)^0\.0\.0\.0\s+\S+')).Count
      if ($checkText.Contains($markerStart) -and $checkText.Contains($markerEnd) -and $verifyCount -ge $domainCount) {
        Write-LogEntry "AdFilter: PASS - hosts 광고 차단 켜짐 ($domainCount 도메인, 변경 $(if ($changedHosts) { '있음' } else { '없음' }))"
        $script:adStatus.hosts = "on($domainCount domains)"
        $script:adStatus.changes += 'hosts'
        if ($changedHosts) { Add-AutoFix "hosts 광고 도메인 차단 ($($domainCount)개)" }
        $script:adWarning += "hosts 로 광고 도메인 $domainCount 개를 막았습니다 → 앱 로그인·설치·업데이트가 실패할 수 있습니다. 그때는 adBlockAllowDomains 에 예외를 넣거나 adBlockEnabled=false 로 끄세요."
      } else {
        Write-LogEntry 'AdFilter: WARN - hosts 적용 후 확인 실패(차단 줄 수 불일치).'
        $recommendations += '[AdFilter] hosts 파일에 차단 목록을 쓰지 못했습니다(권한/백신 잠금 가능).'
        $script:adStatus.hosts = 'off(write failed)'
      }
    } else {
      if ($checkText.Contains($markerStart)) {
        Write-LogEntry 'AdFilter: WARN - hosts 차단 블록이 남아 있습니다.'
        $script:adStatus.hosts = 'off(leftover)'
      } else {
        Write-LogEntry 'AdFilter: PASS - hosts 광고 차단 꺼짐(마커 없음)'
        $script:adStatus.hosts = 'off'
      }
    }
    $null = ipconfig /flushdns 2>&1
  }
} catch {
  Write-LogEntry "AdFilter: WARN - hosts 처리 실패: $($_.Exception.Message)"
  $recommendations += "[AdFilter] hosts 파일 처리 실패: $($_.Exception.Message)"
  $script:adStatus.hosts = 'off(error)'
}

# --- (2) DNS 필터링 (기본 꺼짐, opt-in) ---
try {
  $dnsStatePath = Join-Path $script:adBackupDir 'dns-state.json'
  $dnsState = Get-JsonState $dnsStatePath
  if (Get-Cfg 'adDnsEnabled') {
    $servers = @(@(Get-Cfg 'adDnsServers') | ForEach-Object { [string]$_ } | Where-Object { Test-IPv4Literal $_ })
    if ($servers.Count -eq 0) {
      Write-LogEntry 'AdFilter: WARN - adDnsServers 가 비어 있거나 형식이 잘못되어 DNS 변경을 건너뜁니다.'
      $recommendations += '[AdFilter] adDnsEnabled=true 인데 adDnsServers 가 올바른 IPv4 주소가 아닙니다.'
      $script:adStatus.dns = 'off(bad config)'
    } else {
      $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
      if ($adapters.Count -eq 0) {
        Write-LogEntry 'AdFilter: WARN - 연결된 유선/무선 어댑터가 없어 DNS 를 바꾸지 않았습니다.'
        $script:adStatus.dns = 'off(no adapter)'
      } else {
        $records = @()
        foreach ($rec in @($dnsState['adapters'])) { if ($null -ne $rec) { $records += $rec } }
        $applied = 0
        foreach ($ad in $adapters) {
          try {
            $prev = @((Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses | Where-Object { $_ })
            if (@($records | Where-Object { [string]$_.guid -eq [string]$ad.InterfaceGuid }).Count -eq 0) {
              $records += [ordered]@{ guid = [string]$ad.InterfaceGuid; ifIndex = [int]$ad.ifIndex; alias = [string]$ad.Name; servers = @($prev) }
            }
            Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $servers -ErrorAction Stop
            $applied++
          } catch {
            Write-LogEntry "AdFilter: WARN - $($ad.Name) DNS 변경 실패: $($_.Exception.Message)"
          }
        }
        if ($applied -gt 0) {
          Save-JsonState $dnsStatePath @{ created = (Get-Date).ToString('o'); adapters = @($records) }
          $null = ipconfig /flushdns 2>&1
          Add-AutoFix "DNS 서버 변경 ($($servers -join ', ')) — 어댑터 $($applied)개"
          $script:adStatus.dns = "on($($servers -join ', '))"
          $script:adStatus.changes += 'dns'
          $dnsOk = $false
          try {
            $null = Resolve-DnsName -Name 'www.msftconnecttest.com' -Server $servers[0] -QuickTimeout -ErrorAction Stop
            $dnsOk = $true
          } catch { }
          if ($dnsOk) {
            Write-LogEntry 'AdFilter: PASS - DNS 필터 서버 응답 확인'
          } else {
            Write-LogEntry 'AdFilter: WARN - DNS 필터 서버 응답을 확인하지 못했습니다.'
            $recommendations += '[AdFilter] DNS 필터 서버가 응답하지 않습니다. 인터넷이 안 되면 adDnsEnabled=false 로 되돌리세요.'
          }
          $script:adWarning += "DNS 를 필터링 서버($($servers -join ', '))로 바꿨습니다 → 공유기·프린터·NAS 같은 내부 주소를 못 찾거나 VPN/보안 프로그램과 충돌할 수 있습니다."
        } else {
          $script:adStatus.dns = 'off(apply failed)'
        }
      }
    }
  } else {
    $records = @($dnsState['adapters'])
    $restoredDns = 0
    $restoreFailed = 0
    foreach ($rec in $records) {
      if ($null -eq $rec) { continue }
      try {
        $ad = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq [string]$rec.guid } | Select-Object -First 1
        if (-not $ad) { continue }
        $prevServers = @($rec.servers | Where-Object { $_ })
        if ($prevServers.Count -gt 0) {
          Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $prevServers -ErrorAction Stop
        } else {
          Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ResetServerAddresses -ErrorAction Stop
        }
        $restoredDns++
      } catch {
        $restoreFailed++
        Write-LogEntry "AdFilter: WARN - DNS 복원 실패($($rec.alias)): $($_.Exception.Message)"
      }
    }
    if ($records.Count -gt 0 -and $restoredDns -eq 0 -and $restoreFailed -gt 0) {
      # 복원에 실패했으면 원래 값(dns-state.json)을 지우지 않는다 — 다음 실행에서 다시 시도할 수 있게.
      Write-LogEntry 'AdFilter: WARN - DNS 를 원래대로 되돌리지 못했습니다. dns-state.json 을 보관합니다.'
      $recommendations += '[AdFilter] DNS 복원에 실패했습니다. 네트워크 어댑터 DNS 설정을 직접 확인하세요(어댑터를 삭제/교체하면 자동 복원 불가).'
      $script:adStatus.dns = 'off(restore failed)'
    } else {
      if (Test-Path -LiteralPath $dnsStatePath) {
        Remove-Item -LiteralPath $dnsStatePath -Force -ErrorAction SilentlyContinue
        $null = ipconfig /flushdns 2>&1
        if ($restoredDns -gt 0) {
          Add-AutoFix "DNS 서버 원래대로 복원 (어댑터 $($restoredDns)개)"
          Write-LogEntry "AdFilter: PASS - DNS 원래대로 복원 (어댑터 $($restoredDns)개)"
        }
      } else {
        Write-LogEntry 'AdFilter: SKIP - DNS 필터링 꺼짐(adDnsEnabled=false)'
      }
      $script:adStatus.dns = 'off'
    }
  }
} catch {
  Write-LogEntry "AdFilter: WARN - DNS 처리 실패: $($_.Exception.Message)"
  $recommendations += "[AdFilter] DNS 설정 처리 실패: $($_.Exception.Message)"
  $script:adStatus.dns = 'off(error)'
}

# 경고 문구: 실제로 켜 둔 기능이 있을 때만, 마지막에 "되돌리는 방법"을 한 줄 붙인다.
if ($script:adWarning.Count -gt 0) {
  $script:adWarning += '광고 차단은 100%가 아닙니다. 앱 안에 직접 그려지는 광고와 이미 설치된 광고 앱은 막히지 않습니다(이 키트는 파일 삭제·앱 제거를 하지 않습니다).'
  $script:adWarning += '되돌리기: 바탕화면 "자동 유지보수 제거" → 광고 설정 복원, 또는 uninstall.ps1 -RestoreAds'
}

# --- 네트워크 인터페이스 메트릭 확인 (이더넷 강제, WiFi는 있으면 적용) ---
Write-ProgressBar "Network"
Write-TestHeader "[Network] 네트워크 어댑터 연결 상태와 인터페이스 메트릭을 최적화합니다."
try {
  # 실제 적용 로직은 Set-NetworkMetricPriority (Auto-Heal 이후에도 재적용됨)
  $null = Set-NetworkMetricPriority
} catch {
  Write-LogEntry "Network Metrics: FAIL - Error enforcing interface metrics: $_"
  $failureReasons += "[Network] 네트워크 메트릭 설정 실패: $_"
}

# --- 방화벽 프로필 (도메인/개인/공용) ---
# 배경: 방화벽이 꺼져 있으면 Defender 가 켜져 있어도 인바운드 공격에 그대로 노출된다.
#   보안 프로그램이 설치/제거되며 프로필을 끄는 경우가 흔하고, 사용자는 알림을 끄고 잊는다.
#   `Set-NetFirewallProfile -Enabled True` 는 즉시 되돌릴 수 있는 조치다(관리자 권한 필요).
#   실측 비용: Get-NetFirewallProfile 0.2s.
try {
  $fwProfiles = @(Get-NetFirewallProfile -ErrorAction Stop)
  $fwOff = @($fwProfiles | Where-Object { -not $_.Enabled })
  if ($fwOff.Count -eq 0) {
    Write-LogEntry "Network: PASS - 방화벽 켜짐 ($(@($fwProfiles | ForEach-Object { "$($_.Name)=On" }) -join ', '))"
  } else {
    $fwNames = ($fwOff | ForEach-Object { $_.Name }) -join ', '
    Write-LogEntry "Network: WARN - 방화벽 꺼짐: $fwNames"
    $fwFixed = $false
    try {
      Set-NetFirewallProfile -Profile ($fwOff | ForEach-Object { $_.Name }) -Enabled True -ErrorAction Stop
      Start-Sleep -Milliseconds 500
      $fwAfter = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled })
      if ($fwAfter.Count -eq 0) {
        $fwFixed = $true
        Add-AutoFix "방화벽 프로필 활성화 ($fwNames)"
      }
    } catch {
      Write-LogEntry "Network: WARN - 방화벽 자동 활성화 실패: $($_.Exception.Message)"
    }
    if (-not $fwFixed) {
      $recommendations += "[Network] 방화벽이 꺼져 있습니다($fwNames) — Windows 보안 > 방화벽 및 네트워크 보호에서 켜세요."
    }
  }
} catch {
  Write-LogEntry "Network: SKIP - 방화벽 상태 확인 실패 ($($_.Exception.Message))"
}

# --- 유령 장치(Ghost Devices) 점검 ---
Write-ProgressBar "GhostDev"
Write-TestHeader "[GhostDev] 장치 관리자에서 더 이상 사용되지 않는 유령 장치를 정리합니다."
try {
  $allDevices = Get-PnpDevice -PresentOnly $false -ErrorAction SilentlyContinue
  $ghostDevices = $allDevices | Where-Object { $_.Present -eq $false -and $_.Class -ne 'USB' -and $_.Class -ne 'HIDClass' -and $_.Class -ne 'Ports' }
  $ghostCount = @($ghostDevices).Count
  if ($ghostCount -gt 0) {
    Write-LogEntry "GhostDev: WARN - $ghostCount ghost device(s) found (disconnected hardware drivers)"
    $failureReasons += "[GhostDev] 유령 장치 ${ghostCount}개 발견"
  } else {
    Write-LogEntry 'GhostDev: PASS - No ghost devices found'
  }
} catch {
  Write-LogEntry "GhostDev: SKIP - Unable to enumerate devices: $_"
}

# --- 패키지 매니저(pip, conda, npm, HuggingFace) 캐시 용량 확인 ---
Write-ProgressBar "PkgCache"
Write-TestHeader "[PkgCache] 패키지/모델 캐시 용량을 확인합니다. (HuggingFace 캐시는 절대 자동 삭제하지 않음)"
# 실측(2026-11-05): HF 캐시 113.56GB 중 gemma-4 74.56GB — 대부분 "사용 중인 모델"이라 삭제 대상이 아니다.
#   기존 동작은 총합 5GB 초과 시 매 실행 WARN + pip/conda 강제 정리였고, HF 캐시가 100GB라 항상 WARN이었다(영구 노이즈).
#   변경: 용량은 항상 정보로 기록, 정리는 pip/conda가 2GB 초과일 때만, HF는 경고 기준 초과 시에만 알림.
$hfCacheWarnGB = [int](Get-Cfg 'hfCacheWarnGB')
$purgeThresholdGB = 2
$cacheInfo = [ordered]@{}
$pkgCacheDirs = @(
  @{Name='pip';   Path="$env:LOCALAPPDATA\pip\cache";       AutoPurge=$true },
  @{Name='conda'; Path="$env:USERPROFILE\.conda\pkgs";     AutoPurge=$true },
  @{Name='npm';   Path="$env:APPDATA\npm-cache";           AutoPurge=$false },
  @{Name='huggingface'; Path="$env:USERPROFILE\.cache\huggingface"; AutoPurge=$false }
)
foreach ($cp in $pkgCacheDirs) {
  if (-not (Test-Path -LiteralPath $cp.Path)) { continue }
  $sz = Get-ChildItem -Path $cp.Path -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue
  $szGB = if ($sz -and $sz.Sum) { [math]::Round($sz.Sum / 1GB, 2) } else { 0 }
  if ($szGB -le 0) { continue }
  $cacheInfo[$cp.Name] = $szGB

  if (-not $cp.AutoPurge) { continue }
  if ($szGB -le $purgeThresholdGB) { continue }
  try {
    if ($cp.Name -eq 'pip' -and (Get-Command pip -ErrorAction SilentlyContinue)) {
      $out = & pip cache purge 2>&1 | Out-String
      Write-LogEntry "PkgCache: CHANGE - pip 캐시 ${szGB}GB → 정리 실행"
      Add-AutoFix "pip 캐시 ${szGB}GB 정리 (기준 ${purgeThresholdGB}GB 초과)"
    } elseif ($cp.Name -eq 'conda' -and (Get-Command conda -ErrorAction SilentlyContinue)) {
      $out = & conda clean --all -y 2>&1 | Out-String
      Write-LogEntry "PkgCache: CHANGE - conda 캐시 ${szGB}GB → 정리 실행"
      Add-AutoFix "conda 캐시 ${szGB}GB 정리 (기준 ${purgeThresholdGB}GB 초과)"
    }
  } catch {
    Write-LogEntry "PkgCache: WARN - $($cp.Name) 캐시 정리 실패: $($_.Exception.Message)"
  }
}

$detailStr = (($cacheInfo.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)GB" }) -join ', ')
$totalCacheGB = [math]::Round((($cacheInfo.Values | Measure-Object -Sum).Sum), 2)
if ($cacheInfo.Count -eq 0) {
  Write-LogEntry 'PkgCache: PASS - 패키지/모델 캐시 없음'
} else {
  Write-LogEntry "PkgCache: INFO - 총 ${totalCacheGB}GB ($detailStr)"
  $hfGB = if ($cacheInfo.Contains('huggingface')) { [double]$cacheInfo['huggingface'] } else { 0 }
  if ($hfCacheWarnGB -gt 0 -and $hfGB -gt $hfCacheWarnGB) {
    # 삭제가 아니라 "확인" 안내. 다운로드한 모델은 지우면 다시 받아야 하므로 자동 삭제 금지.
    Write-LogEntry "PkgCache: WARN - HuggingFace 캐시 ${hfGB}GB (기준 ${hfCacheWarnGB}GB 초과) — 사용하지 않는 모델만 수동 정리 검토"
    $recommendations += "[PkgCache] HuggingFace 캐시 ${hfGB}GB — 사용하지 않는 모델 저장소만 수동 삭제 (자동 삭제 금지: 재다운로드 비용 큼)"
  } else {
    Write-LogEntry "PkgCache: PASS - HuggingFace 캐시 ${hfGB}GB (기준 ${hfCacheWarnGB}GB 이내)"
  }
}

# --- 윈도우 시작 프로그램 개수 확인 ---
Write-ProgressBar "Startup"
Write-TestHeader "[Startup] 시작 프로그램을 이전 실행과 비교해 새로 추가된 항목만 보고합니다."
try {
  # 기존: 15개 초과면 매 실행 WARN + FAIL 사유 → 25개가 고정값이라 영구 노이즈였음.
  # 변경: 기준선(startup-baseline.json) 대비 "신규 항목"만 경고. 개수는 정보로만 기록.
  $startupItems = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue
  $names = @($startupItems | ForEach-Object { "$($_.Name) [$($_.Location)]" } | Sort-Object -Unique)
  $startupCount = $names.Count
  $baselinePath = Join-Path $scriptRoot 'startup-baseline.json'
  $baseline = Get-JsonState $baselinePath
  $prevNames = @()
  if ($baseline.ContainsKey('items')) { $prevNames = @($baseline['items']) }
  if ($prevNames.Count -eq 0) {
    Write-LogEntry "Startup: PASS - ${startupCount}개 (기준선 저장: 다음 실행부터 신규 항목만 경고)"
  } else {
    $newItems = @($names | Where-Object { $prevNames -notcontains $_ })
    if ($newItems.Count -gt 0) {
      $preview = ($newItems | Select-Object -First 5) -join ', '
      # 새 프로그램 설치는 "고장"이 아니므로 FAIL 사유로 올리지 않는다(컴맹 사용자에게 겁을 주지 않기).
      #   → WARN 로그 + 권고만. 기준선은 아래에서 갱신되므로 1회만 보고된다.
      Write-LogEntry "Startup: WARN - 신규 시작 프로그램 $($newItems.Count)개 (총 ${startupCount}개): $preview"
      foreach ($n in $newItems) { $recommendations += "[Startup] 새 항목 확인/비활성화 검토: $n" }
    } else {
      Write-LogEntry "Startup: PASS - ${startupCount}개 (기준선 대비 신규 없음)"
    }
  }
  Save-JsonState $baselinePath @{ items = $names; updated = (Get-Date).ToString('o') }
} catch {
  Write-LogEntry "Startup: SKIP - Unable to check startup programs: $_"
}

# --- Recycle Bin (30일 이상 지난 파일 비우기) ---
Write-ProgressBar "RecycleBin"
Write-TestHeader "[RecycleBin] 30일 이상 지난 휴지통 파일을 확인하고, 목록을 보여준 뒤 지웁니다."
try {
  $shell = New-Object -ComObject Shell.Application
  $recycleBin = $shell.NameSpace(0xa)
  $cutoff = (Get-Date).AddDays(-30)
  # 2026-11-12: 지우기 전에 목록을 먼저 모은다(사용자 요청 — 목록 확인 후 y/N).
  $rbCands = @()
  foreach ($item in $recycleBin.Items()) {
    try {
      $delDate = $item.ExtendedProperty('{9B174B34-40FF-11D2-A27E-00C04FC30871} 2')
      if (-not $delDate) {
        $delDate = $item.ModifyDate
        if (-not $delDate) { continue }
      }
      $dt = if ($delDate -is [DateTime]) { $delDate } else { try { [DateTime]::Parse($delDate) } catch { continue } }
      if ($dt -lt $cutoff) {
        # 휴지통 항목은 Name 이 파일명뿐이라 "어느 폴더에서 지웠는지" 알 수 없다.
        #   → 원래 위치(원본 폴더)를 앞에 붙여 전체 경로로 기록한다(2026-11-13, 복구 목적).
        $origPath = ''
        try { $origPath = [string]$item.ExtendedProperty('{9B174B33-40FF-11D2-A27E-00C04FC30871} 2') } catch { }
        if ([string]::IsNullOrWhiteSpace($origPath)) {
          # 확장속성이 비어 있는 Windows/언어판 대비: 쉘 상세정보 열에서 '경로처럼 생긴' 값을 찾는다.
          foreach ($ci in @(1, 2, 0)) {
            $v = ''
            try { $v = [string]$recycleBin.GetDetailsOf($item, $ci) } catch { $v = '' }
            if ($v -match '^([A-Za-z]:\\|\\\\)') { $origPath = $v; break }
          }
        }
        $nameForRecord = [string]$item.Name
        if (-not [string]::IsNullOrWhiteSpace($origPath)) {
          $nameForRecord = $origPath.TrimEnd('\') + '\' + $nameForRecord
        }
        $rbCands += [pscustomobject]@{
          Name = $nameForRecord
          Size = [double]$(if ($item.Size) { $item.Size } else { 0 })
          Date = $dt
          Item = $item
        }
      }
    } catch { }
  }
  if ($rbCands.Count -gt 0) {
    $sizeMB = [math]::Round((($rbCands | Measure-Object -Property Size -Sum).Sum) / 1MB, 1)
    $approved = Invoke-DeleteReview -Target '휴지통 (30일 이상 지난 파일)' -Items $rbCands -PolicyKey 'recycleAutoDelete' -DeleteAction {
      foreach ($c in $rbCands) { try { $c.Item.InvokeVerb('delete') } catch { } }
    }
    if ($approved) {
      Write-LogEntry "RecycleBin: PASS - Removed $($rbCands.Count) files ($sizeMB MB) older than 30 days"
      Add-AutoFix ("휴지통 $($rbCands.Count)개 파일 ${sizeMB}MB 비움 (30일 이상 경과)")
    } else {
      Write-LogEntry "RecycleBin: SKIP - 사용자가 지우지 않기로 함 ($($rbCands.Count)개 / ${sizeMB}MB 유지)"
    }
  } else {
    Write-LogEntry 'RecycleBin: PASS - No old recycle bin files'
  }
} catch {
  Write-LogEntry "RecycleBin: SKIP - $($_.Exception.Message)"
}

# --- 레지스트리 하이브(Registry Hive) 크기 모니터링 ---
Write-ProgressBar "RegHive"
Write-TestHeader "[RegHive] 레지스트리 하이브 파일의 크기를 모니터링합니다."
try {
  $configPath = "$env:windir\System32\config"
  $hiveFiles = Get-ChildItem -Path $configPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(SAM|SECURITY|SOFTWARE|SYSTEM|DEFAULT|COMPONENTS)$' -or $_.Extension -eq '' }
  $largeHives = @()
  foreach ($hf in $hiveFiles) {
    $szMB = [math]::Round($hf.Length / 1MB, 2)
    if ($szMB -gt 500) { $largeHives += "$($hf.Name)=${szMB}MB" }
  }
  if ($largeHives.Count -gt 0) {
    Write-LogEntry "RegHive: WARN - Large hive(s): $($largeHives -join ', ')"
    $failureReasons += "[RegHive] 레지스트리 하이브 파일 500MB 초과: $($largeHives -join ', ')"
  } else {
    Write-LogEntry 'RegHive: PASS - All registry hives within normal size'
  }
} catch {
  Write-LogEntry "RegHive: SKIP - Unable to check registry hive sizes: $_"
}

# --- 볼륨 최적화(조각모음/TRIM)는 Windows 기본 작업에 위임 (2026-11-06) ---
#   실행 주체: \Microsoft\Windows\Defrag\ScheduledDefrag  (%windir%\system32\defrag.exe -c -h -o -$)
#     - /O = "Perform the proper optimization for each media type"
#       → 볼륨마다 HDD(조각모음)/SSD(retrim)/티어공간(TierOptimize)을 Windows가 알아서 선택
#     - 트리거가 아니라 자동 유지보수(Automatic Maintenance) 엔진이 실행 (Period P7D, Deadline P1M)
#   여기서는 "그 작업이 켜져 있는지"만 확인한다. 최적화 자체는 실행하지 않는다(중복 실행 방지).
Write-ProgressBar "Defrag"
Write-TestHeader "[Defrag] 볼륨 최적화(조각모음/TRIM)는 Windows 기본 작업(ScheduledDefrag)에 위임되어 있습니다."
try {
  $script:subTotal = 0
  $script:subStep = ''
  $defragTask = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
  $defragInfo = $defragTask | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
  $defragSvc = Get-Service -Name defragsvc -ErrorAction SilentlyContinue
  $svcStart = if ($defragSvc) { $defragSvc.StartType } else { 'Unknown' }
  $lastDefrag = '없음'
  if ($defragInfo -and $defragInfo.LastRunTime -and $defragInfo.LastRunTime.Year -gt 2000) {
    $lastDefrag = $defragInfo.LastRunTime.ToString('yyyy-MM-dd HH:mm')
  }
  if ($defragTask.State -ne 'Disabled') {
    Write-LogEntry "Defrag: PASS - ScheduledDefrag=$($defragTask.State), 마지막 실행 $lastDefrag, defragsvc=$svcStart (실행은 자동 유지보수 창)"
  } else {
    # 자동 조치(가역/안전): 작업을 다시 켠다. 트윅 도구가 꺼놓으면 SSD TRIM/HDD 조각모음이 영구히 멈추기 때문.
    Write-LogEntry "Defrag: WARN - ScheduledDefrag 작업이 Disabled 상태입니다. TRIM/조각모음이 자동 실행되지 않습니다."
    try {
      $null = Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
      $now = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
      if ($now -and $now.State -ne 'Disabled') {
        Add-AutoFix "ScheduledDefrag 작업을 다시 켰습니다(TRIM/조각모음 자동 실행 복구)."
      } else {
        throw "재활성화 후에도 상태가 $($now.State)"
      }
    } catch {
      Write-LogEntry "Defrag: FAIL - ScheduledDefrag 재활성화 실패: $($_.Exception.Message)"
      $failureReasons += "[Defrag] ScheduledDefrag 작업을 켤 수 없습니다: $($_.Exception.Message)"
      $recommendations += "[Defrag] '드라이브 최적화'에서 일정 최적화를 직접 켜세요(TRIM/조각모음이 실행되지 않고 있습니다)."
    }
  }
} catch {
  Write-LogEntry "Defrag: SKIP - ScheduledDefrag 상태 확인 실패: $($_.Exception.Message)"
}

# --- CHKDSK 디스크 오류 검사 (모든 볼륨) ---
Write-ProgressBar "CHKDSK"
Write-TestHeader "[CHKDSK] 모든 NTFS 볼륨의 파일 시스템 오류를 검사하고 복구합니다."
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
function Test-ChkdskNameBlocked {
  # 이미지 이름 단위 실행 차단 탐지: 같은 이름(chkdsk.exe)의 무해한 실행 파일로 테스트
  # (내용/경로/ACL과 무관하게 이름만으로 차단되는 드라이버가 존재함 - 예: Riot Vanguard vgk)
  # 예측 가능한 이름($env:TEMP\chkdsk.exe)은 심볼릭 링크/사전 배치로 악용될 수 있으므로
  # GUID 파일명 + 배타적 생성에 가까운 쓰기를 쓰고, cmd.exe 경유 없이 직접 실행한다.
  $probe = Join-Path ([IO.Path]::GetTempPath()) ('chkdsk_probe_' + [guid]::NewGuid().ToString('N') + '.exe')
  try {
    Copy-Item -LiteralPath "$env:SystemRoot\System32\hostname.exe" -Destination $probe -Force -ErrorAction Stop
    $out = & $probe 2>&1 | Out-String
    return ($out -match '(?i)access is denied|액세스가 거부')
  } catch {
    return $false
  } finally {
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
  }
}

function Get-KnownSecurityProduct {
  # 2026-11-16: 이벤트에 찍히는 이름만으로는 사용자가 무엇인지 알 수 없다.
  #   친구 PC 두 대 모두 'grap-core64.aes' 반복 충돌 — 검색 전에는 원인을 알 수 없었고,
  #   "앱 업데이트" 같은 일반론은 틀린 안내다(안티치트는 게임이 꺼지면 사라지는 잔여 프로세스인 경우가 많다).
  #   정확한 이름 매칭만 한다(오탐으로 엉뚱한 제품명을 알려주면 더 나쁘다).
  param([string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
  $n = $Name.ToLowerInvariant()
  if ($n -match 'grap-core64|grap64|blackcipher') {
    return [pscustomobject]@{
      Product = 'Nexon Game Security (NGS, 구 BlackCipher)'
      Note    = '메이플스토리·블루아카이브 등 넥슨 게임 안티치트'
      Advice  = '게임과 런처를 완전히 종료(트레이 아이콘까지)하면 사라집니다. 게임을 끈 상태에서도 반복되면 게임 파일 무결성 검사/재설치'
    }
  }
  if ($n -match '^vgc\.exe$|^vgk\.sys$|^vgm\.sys$|^vgr\.sys$|^vgk$') {
    return [pscustomobject]@{
      Product = 'Riot Vanguard'
      Note    = '리그 오브 레전드·발로란트 안티치트'
      Advice  = 'Windows 11 에서는 TPM 2.0 + Secure Boot 가 필요합니다(꺼져 있으면 게임이 실행되지 않음). Riot 클라이언트의 복구/재설치로 다시 깔 수 있습니다'
    }
  }
  if ($n -match 'sguard64|sguardsvc64|^ace-base|^ace-game|^ace-boot|^acesys|tesafe') {
    return [pscustomobject]@{
      Product = 'Tencent ACE 안티치트'
      Note    = 'PUBG·FC온라인 등 텐센트 계열 게임 안티치트'
      Advice  = '게임 종료 후에도 남는 경우가 있습니다. 트레이에서 종료하거나 게임을 재설치하세요'
    }
  }
  if ($n -match 'xigncode|xhunter1|xnina\.xem|wellbia') {
    return [pscustomobject]@{
      Product = 'XignCode3 (Wellbia)'
      Note    = '구형 온라인 게임 안티치트'
      Advice  = '게임 종료 후 남은 프로세스를 종료하고, 반복되면 해당 게임 재설치'
    }
  }
  if ($n -match 'gamemon|npggnt|^npgg') {
    return [pscustomobject]@{
      Product = 'nProtect GameGuard'
      Note    = '구형 온라인 게임 안티치트'
      Advice  = '게임 종료 후 남은 프로세스를 종료하고, 반복되면 해당 게임 재설치'
    }
  }
  if ($n -match 'easyanticheat|^eac_|^eac-') {
    return [pscustomobject]@{
      Product = 'Easy Anti-Cheat'
      Note    = '에픽/스팀 게임 안티치트'
      Advice  = '게임 설치 폴더의 EasyAntiCheat_Setup.exe 로 복구하거나 게임 무결성 검사를 실행하세요'
    }
  }
  if ($n -match '^beservice|battleye|^bedaisy') {
    return [pscustomobject]@{
      Product = 'BattlEye'
      Note    = '배틀그라운드 등 게임 안티치트'
      Advice  = '게임 파일 무결성 검사를 실행하고, 반복되면 게임 재설치'
    }
  }
  return $null
}

function Get-ImageNameBlockerHint {
  # 실행 중인 커널 필터/보안 드라이버 중 이름 차단 후보를 힌트로 제공.
  # 2026-11-15: 후보 목록에 없으면 **서드파티(비 Microsoft) 커널 드라이버**를 나열한다.
  #   (사용자 리포트 2026-11-15: 후보 7개가 모두 없어 "의심 드라이버" 줄이 비어 있었음)
  # 2026-11-16: 게임 안티치트 커널 드라이버(NGS/ACE/XignCode/EAC/BattlEye 등)를 후보에 추가하고,
  #   잡히면 제품명을 함께 적는다(이름만 보면 무엇인지 알 수 없음).
  $candidates = @(
    'vgk','vgm','file_tracker','volume_tracker','fltsrv','TKFsFtM','TKPcFt','FancyCcV',
    'BlackCipher64','BlackCipher','ACE-BASE','ACE-GAME','ACE-BOOT','xhunter1','BEDaisy',
    'EasyAntiCheat','EasyAntiCheat_EOS','npggNT','GameGuard','TesSafe'
  )
  $running = @()
  foreach ($n in $candidates) {
    $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { $running += $n }
  }
  if ($running.Count -gt 0) {
    $annotated = @()
    foreach ($r in $running) {
      $kp = Get-KnownSecurityProduct $r
      if ($kp) { $annotated += ("{0} ({1})" -f $r, $kp.Product) } else { $annotated += $r }
    }
    return ($annotated -join ', ')
  }
  try {
    $third = @()
    $drivers = @(Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' })
    foreach ($d in $drivers) {
      if ($third.Count -ge 8) { break }
      $path = [string]$d.PathName
      if ([string]::IsNullOrWhiteSpace($path)) { continue }
      $sysPath = $path -replace '^\\\?\?\\', ''
      if ($sysPath -match '^\\SystemRoot\\') { $sysPath = $sysPath -replace '^\\SystemRoot\\', ($env:SystemRoot + '\') }
      if (-not (Test-Path -LiteralPath $sysPath)) { continue }
      $co = ''; $desc = ''
      try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($sysPath)
        $co = [string]$vi.CompanyName
        $desc = [string]$vi.FileDescription
      } catch { }
      if ($co -match '(?i)microsoft') { continue }
      $label = if ($co) { $co } elseif ($desc) { $desc } else { '제조사 미상' }
      $kp = Get-KnownSecurityProduct ([string]$d.Name)
      if ($kp) { $label = $kp.Product }
      $third += ("{0} ({1})" -f $d.Name, $label)
    }
    if ($third.Count -gt 0) { return ('서드파티 커널 드라이버: ' + ($third -join ', ')) }
  } catch { }
  return ''
}

function Invoke-ChkdskElevated {
  param([string]$Drive, [string]$Arg)
  # 드라이브와 스위치는 화이트리스트로 제한한다. cmd.exe 메타문자(& | > ^ 등)가 섞일 여지를 없앤다.
  if ($Drive -notmatch '^[A-Za-z]:$') { throw "유효하지 않은 드라이브 지정입니다: $Drive" }
  if ($Arg -notin @('/scan', '/spotfix', '/f')) { throw "유효하지 않은 chkdsk 인자입니다: $Arg" }
  # 예측 가능한 임시 파일명(Get-Random) 대신 GUID 를 쓴다.
  $tmpOut = Join-Path ([IO.Path]::GetTempPath()) ('chkdsk_' + [guid]::NewGuid().ToString('N') + '.tmp')
  $exe = '%SystemRoot%\System32\chkdsk.exe'
  if ($isAdmin) {
    # cmd.exe 경유 없이 chkdsk.exe 를 직접 호출한다(출력은 파이프로 파일에 기록).
    $null = & "$env:SystemRoot\System32\chkdsk.exe" $Drive $Arg 2>&1 | Out-File -LiteralPath $tmpOut -Encoding UTF8
    $ec = $LASTEXITCODE
  } else {
    # 상승이 필요한 경우에만 cmd /c 를 쓰고, 검증된 값 + GUID 경로만 조합한다.
    $cmdBody = $exe + ' ' + $Drive + ' ' + $Arg + ' > "' + $tmpOut + '" 2>&1'
    $cArg = Join-CliArgs @('/d', '/c', $cmdBody)
    $p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList $cArg -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    $ec = $p.ExitCode
  }
  if (Test-Path -LiteralPath $tmpOut) {
    $result = Get-Content -LiteralPath $tmpOut -Raw
    Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
  } else { $result = '' }
  return @{ ExitCode = $ec; Output = $result }
}

# CHKDSK 게이트 (기본 12일 = 144h 주기의 2회마다):
#   - /scan 은 **온라인 검사**(볼륨 분리/재부팅 없음)이고 실측 비용은 볼륨 합계 130~140초(대부분 C:).
#   - 2026-10~11 9회 연속 무결성 이상 0건이지만, 파일시스템 손상은 조용히 쌓이므로 30일보다 촘촘하게 둔다.
#   - 매 실행(6일)은 이득 대비 비용이 커서 2회마다(12일)로 정렬. `chkdskDays: 0`이면 매 실행.
$chkdskDays = [int](Get-Cfg 'chkdskDays')
$lastChkdsk = Get-StampDate (Join-Path $scriptRoot '.last_chkdsk')
$chkdskDue = Test-DueByDays $lastChkdsk $chkdskDays
if (-not $chkdskDue) {
  Write-LogEntry ("CHKDSK: SKIP - gated ({0}d interval, last {1})" -f $chkdskDays, $(if ($lastChkdsk) { $lastChkdsk.ToString('yyyy-MM-dd') } else { 'never' }))
} else {
try {
  $volumes = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue
  $chkdskIssues = $false
  foreach ($vol in $volumes) {
    $drive = $vol.DeviceID
    if ($vol.FileSystem -ne 'NTFS') { Write-LogEntry "CHKDSK ($drive): SKIP - File system is $($vol.FileSystem)"; continue }
    Write-ProgressBar "CHKDSK: $drive"
    $scan = Invoke-ChkdskElevated -Drive $drive -Arg '/scan'
    if ($scan.ExitCode -eq 0) {
      Write-LogEntry "CHKDSK ($drive): PASS - No file system errors"
    } else {
      $failureReasons += "[CHKDSK] $drive 드라이브에서 파일 시스템 오류 발견 (종료 코드 $($scan.ExitCode))"
      Write-LogEntry "CHKDSK ($drive): WARN - 오류 발견 (종료 코드 $($scan.ExitCode)), 복구 시도 중..."
      $chkdskIssues = $true
      # 2026-11-15: chkdsk 실제 출력 일부를 로그에 남긴다(차단/오류 원인 판별용 — 이전엔 버려졌음).
      try {
        $snip = @(($scan.Output -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 8)
        foreach ($sl in $snip) { Write-LogEntry ("  chkdsk: " + $sl.Trim()) }
      } catch { }
      if ($drive -eq 'C:') {
        # 이미지 이름 단위 실행 차단 여부 확인 (chkdsk.exe/chkntfs.exe/autochk.exe 3개만 차단하는 커널 드라이버)
        if (Test-ChkdskNameBlocked) {
          Write-LogEntry "CHKDSK ($drive): FAIL - chkdsk.exe 실행이 이름 기반으로 차단됨 (제3자 커널 드라이버)"
          $blocker = Get-ImageNameBlockerHint
          if ($blocker) { Write-LogEntry "CHKDSK ($drive):   의심 드라이버: $blocker" }
          $failureReasons += "[CHKDSK] $drive 검사 불가 - chkdsk.exe/autochk.exe 실행이 이미지 이름 단위로 차단되고 있습니다."
          # 2026-11-16: "드라이버를 제거/비활성화하세요"는 위험한 안내였다(게임 보안 해제 = 게임 실행 불가).
          #   안티치트는 게임이 꺼지면 로드되지 않으므로, 끄지 않고도 검사할 수 있는 순서를 먼저 제시한다.
          $recommendations += "[CHKDSK] $drive 검사가 게임 안티치트/보안 프로그램에 막혔습니다. 해결 순서: (1) 게임과 런처를 완전히 종료(트레이 아이콘까지)한 뒤 이 점검을 다시 실행, (2) 그래도 막히면 재부팅 직후(게임 실행 전)에 점검, (3) 계속 막히면 안전 모드에서 'chkdsk $drive /f' 실행 — 안전 모드에서는 안티치트가 로드되지 않습니다."
        } else {
          # 주의: fsutil dirty set은 spotfix만 유발한다. 전체 검사는 chkdsk /f 예약(Y)으로만 설정된다.
          # $drive 는 Win32_LogicalDisk.DeviceID 이지만 방어적으로 형식을 검증한다.
          if ($drive -notmatch '^[A-Za-z]:$') { throw "유효하지 않은 드라이브 지정입니다: $drive" }
          # %SystemRoot% 는 시스템이 관리하는 값이라 exe 경로 하이재킹 여지가 없다.
          # 드라이브만 화이트리스트 값으로 들어가므로 echo Y| ... 문자열에 메타문자가 끼어들 수 없다.
          # echo Y| 는 cmd.exe 파이프로 재부팅 검사 질문에 자동 응답하기 위한 것이다.
          # Invoke-ChkdskElevated 와 동일하게 Join-CliArgs 로 인자를 조립한다.
          # 문자열을 직접 이어 붙이지 않아 검증된 드라이브 값과 고정 문자열만 전달된다.
          $fixCmd = 'echo Y| %SystemRoot%\System32\chkdsk.exe ' + $drive + ' /f'
          $cArg = Join-CliArgs @('/d', '/c', $fixCmd)
          if ($isAdmin) {
            $null = & "$env:SystemRoot\System32\cmd.exe" /d /c $fixCmd 2>&1
          } else {
            Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList $cArg | Out-Null
          }
          $boot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name BootExecute -ErrorAction SilentlyContinue).BootExecute
          $bootStr = if ($boot) { $boot -join ' ' } else { '' }
          if ($bootStr -match [regex]::Escape($drive)) {
            Write-LogEntry "CHKDSK ($drive): CHANGE - 재부팅 시 전체 검사(chkdsk /f) 예약됨"
          } else {
            Write-LogEntry "CHKDSK ($drive): WARN - 전체 검사 예약 확인 실패 (BootExecute에 $drive 항목 없음)"
          }
          $recommendations += "[CHKDSK] $drive 드라이브는 재부팅 후 전체 검사(chkdsk /f)가 실행됩니다. 검사 중에는 전원을 끄지 마세요."
        }
      } else {
        $fix = Invoke-ChkdskElevated -Drive $drive -Arg '/spotfix'
        $fixMode = '/spotfix'
        if ($fix.ExitCode -gt 1) {
          $fix = Invoke-ChkdskElevated -Drive $drive -Arg '/f'
          $fixMode = '/f'
        }
        if ($fix.ExitCode -le 1) {
          # 2026-11-15: 복구 성공을 PASS/CHANGE 로 남기고, 방금 넣은 실패 사유를 제거한다.
          #   이전: "Repaired successfully" 문장이 PASS/WARN 필터에 걸리지 않아 리포트에는
          #   WARN 만 남고 failureReasons 때문에 Overall Status 는 FAIL 로 남았다
          #   (사용자 리포트 2026-11-15: D: 가 복구됐는지 알 수 없고 결과는 FAIL).
          Write-LogEntry "CHKDSK ($drive): PASS - Repaired via $fixMode (exit $($fix.ExitCode))"
          Add-AutoFix "CHKDSK: $drive 파일 시스템 오류 복구 ($fixMode)"
          $staleReason = "[CHKDSK] $drive 드라이브에서 파일 시스템 오류 발견"
          $failureReasons = @($failureReasons | Where-Object { -not ([string]$_).StartsWith($staleReason) })
        } else {
          Write-LogEntry "CHKDSK ($drive): FAIL - Repair failed (exit code $($fix.ExitCode), $fixMode)"
          $recommendations += "[CHKDSK] $drive 드라이브 수정에 실패했습니다. 데이터를 백업하고 디스크 교체를 고려하세요."
        }
      }
    }
  }
  if (-not $chkdskIssues) {
    Write-LogEntry 'CHKDSK: PASS - All volumes clean'
  }
  Set-StampDate (Join-Path $scriptRoot '.last_chkdsk')
} catch {
  Write-LogEntry "CHKDSK: SKIP - 관리자 권한이 없거나 검사 실패: $_"
}
}

# --- 블루스크린(BSOD) 이력 확인 (Minidump 분석) ---
Write-ProgressBar "BSOD"
Write-TestHeader "[BSOD] 블루스크린 Minidump 파일 존재 여부를 확인합니다."
try {
  $dumpDir = "$env:windir\Minidump"
  if (-not (Test-Path -LiteralPath $dumpDir)) {
    Write-LogEntry 'BSOD: PASS - No minidump directory (no BSOD history)'
  } else {
    $dumps = @(Get-ChildItem -Path $dumpDir -Filter '*.dmp' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($dumps.Count -eq 0) {
      Write-LogEntry 'BSOD: PASS - No dump files found'
    } else {
      $recentDumps = @($dumps | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-90) })
      if ($recentDumps.Count -eq 0) {
        Write-LogEntry "BSOD: PASS - Only old dumps found (latest: $($dumps[0].LastWriteTime.ToString('yyyy-MM-dd')))"
      } else {
        foreach ($d in $recentDumps) {
          $ts = $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
          $sz = [math]::Round(($d.Length/1KB),0)
          $analysis = Get-MinidumpBugcheck -Path $d.FullName
          if ($analysis) {
            $dName = $d.Name
            Write-LogEntry "BSOD: WARN - Crash dump found (${dName}, $ts, ${sz}KB)"
            Write-LogEntry "  $analysis"
            if ($analysis -match 'BugCheck (0x[0-9A-F]+)') {
              $bc = $Matches[1]
              $bcDesc = switch -Regex ($bc) {
                '0x0000000A|0x0A'    { @{ Cause='IRQL_NOT_LESS_OR_EQUAL - 드라이버가 잘못된 메모리 주소에 접근'; Fix='최신 드라이버로 업데이트하거나 최근 설치한 드라이버를 롤백하세요.'; Detail='IRQL_NOT_LESS_OR_EQUAL은 주로 불량 드라이버가 너무 높은 인터럽트 요청 수준에서 메모리에 접근하려 할 때 발생합니다. 그래픽 드라이버, 네트워크 드라이버, 가상화 소프트웨어가 주요 원인입니다.' } }
                '0x00000019|0x19'    { @{ Cause='BAD_POOL_HEADER - 드라이버 메모리 풀 손상'; Fix='드라이버 업데이트, 메모리 진단(mdsched.exe) 실행'; Detail='BAD_POOL_HEADER는 드라이버가 메모리 풀 헤더를 손상시켰을 때 발생합니다. 불량 RAM, 불안정한 드라이버, 오버클럭이 원인일 수 있습니다.' } }
                '0x0000001A|0x1A'    { @{ Cause='MEMORY_MANAGEMENT - 메모리 관리 치명적 오류'; Fix='메모리 진단(mdsched.exe) 실행, 드라이버 업데이트, 오버클럭 해제'; Detail='MEMORY_MANAGEMENT는 Windows 메모리 관리자에서 치명적 오류가 발생했음을 의미합니다. 불량 RAM, 불량 드라이버, 손상된 페이지 파일이 원인일 수 있습니다.' } }
                '0x0000001E|0x1E'    { @{ Cause='KMODE_EXCEPTION_NOT_HANDLED - 커널 모드 예외 처리 실패'; Fix='메모리 진단(mdsched.exe)을 실행하고 드라이버를 업데이트하세요.'; Detail='KMODE_EXCEPTION_NOT_HANDLED는 커널 모드 프로그램이나 드라이버에서 처리되지 않은 예외가 발생했음을 의미합니다. 불량 드라이버, 손상된 시스템 파일, 하드웨어 결함이 원인일 수 있습니다.' } }
                '0x00000024|0x24'    { @{ Cause='NTFS_FILE_SYSTEM - NTFS 파일 시스템 드라이버 오류'; Fix='chkdsk /f를 실행하고 디스크 상태를 확인하세요.'; Detail='NTFS_FILE_SYSTEM은 NTFS 파일 시스템 드라이버에 치명적 오류가 발생했음을 의미합니다. 디스크 배드 섹터, 파일 시스템 손상, SSD 펌웨어 문제가 원인일 수 있습니다.' } }
                '0x0000003B|0x3B'    { @{ Cause='SYSTEM_SERVICE_EXCEPTION - 드라이버 충돌 또는 CPU 전압 불안정'; Fix='Curve Optimizer 사용 시 CO 값을 -5~-10 완화하거나 특정 코어를 개별 조정하세요. 드라이버 업데이트도 병행하세요.'; Detail='SYSTEM_SERVICE_EXCEPTION (P1=0xC0000005 = ACCESS_VIOLATION)은 시스템 서비스나 드라이버가 유효하지 않은 메모리에 접근할 때 발생합니다. 저부하(새벽/idle) 시간대에 집중된다면 CPU Curve Optimizer의 CO 값이 특정 코어에 너무 공격적으로 설정되어 idle 전압이 부족한 것이 원인일 가능성이 높습니다. 모든 코어에 동일한 CO 값을 적용하지 말고, CoreCycler 등으로 약한 코어를 식별하여 개별 조정하세요.' } }
                '0x00000044|0x44'    { @{ Cause='MULTIPLE_IRP_COMPLETE_REQUESTS - 드라이버 IRP 중복 완료'; Fix='해당 드라이버 제조사에 업데이트 문의, 최근 설치한 드라이버 롤백'; Detail='MULTIPLE_IRP_COMPLETE_REQUESTS는 드라이버가 동일한 I/O 요청 패킷(IRP)을 두 번 이상 완료하려고 할 때 발생합니다. 결함 있는 드라이버가 원인입니다.' } }
                '0x0000004E|0x4E'    { @{ Cause='PFN_LIST_CORRUPT - 메모리 PFN 리스트 손상'; Fix='메모리 진단, 드라이버 업데이트, 최근 하드웨어 변경사항 점검'; Detail='PFN_LIST_CORRUPT는 Windows 메모리 관리자의 PFN(Page Frame Number) 데이터베이스가 손상되었음을 의미합니다. DMA를 사용하는 불량 드라이버, 손상된 RAM이 원인입니다.' } }
                '0x0000004F|0x4F'    { @{ Cause='NDIS_INTERNAL_ERROR - 네트워크 드라이버 내부 오류'; Fix='네트워크 드라이버 업데이트, 네트워크 어댑터 펌웨어 업데이트'; Detail='NDIS_INTERNAL_ERROR는 네트워크 드라이버 스택에서 내부 오류가 발생했음을 의미합니다. 네트워크 카드 드라이버, Wi-Fi 드라이버, VPN/방화벽 소프트웨어가 원인일 수 있습니다.' } }
                '0x00000050|0x50'    { @{ Cause='PAGE_FAULT_IN_NONPAGED_AREA - 페이징 불가 영역 메모리 접근 위반'; Fix='메모리 진단(mdsched.exe) 실행, 불필요한 드라이버 제거, BIOS 기본값으로 초기화'; Detail='PAGE_FAULT_IN_NONPAGED_AREA는 드라이버가 페이징되지 않은 메모리 영역에서 페이지 폴트를 발생시켰을 때 나타납니다. 주로 결함 있는 드라이버, 손상된 RAM, 또는 호환되지 않는 하드웨어가 원인입니다.' } }
                '0x00000051|0x51'    { @{ Cause='REGISTRY_ERROR - 레지스트리 치명적 오류'; Fix='시스템 복원, 레지스트리 백업 복구, Windows 복구 설치'; Detail='REGISTRY_ERROR는 Windows 레지스트리에서 I/O 오류가 발생했음을 의미합니다. 디스크 손상, 파일 시스템 손상, 또는 레지스트리 하이브 파일 손상이 원인입니다.' } }
                '0x00000073|0x73'    { @{ Cause='CONFIG_LIST_FAILED 또는 BAD_SYSTEM_CONFIG_INFO - 레지스트리/구성 손상'; Fix='시스템 복원, 레지스트리 백업 복구, 최근 변경사항 롤백'; Detail='레지스트리 하이브 파일이 손상되었거나 Windows 구성을 로드할 수 없습니다. 최근 레지스트리 변경, 디스크 손상, Windows 업데이트 실패가 원인일 수 있습니다.' } }
                '0x00000074|0x74'    { @{ Cause='CONFIG_LIST_FAILED 또는 BAD_SYSTEM_CONFIG_INFO - 레지스트리/구성 손상'; Fix='시스템 복원, 레지스트리 백업 복구, 최근 변경사항 롤백'; Detail='레지스트리 하이브 파일이 손상되었거나 Windows 구성을 로드할 수 없습니다. 최근 레지스트리 변경, 디스크 손상, Windows 업데이트 실패가 원인일 수 있습니다.' } }
                '0x00000077|0x77'    { @{ Cause='KERNEL_STACK_INPAGE_ERROR - 커널 스택 페이지 파일 오류'; Fix='디스크 오류 검사(chkdsk), 페이지 파일 재설정, RAM 진단'; Detail='KERNEL_STACK_INPAGE_ERROR는 커널이 페이지 파일에서 필요한 데이터를 읽을 수 없을 때 발생합니다. 디스크 배드 섹터, 손상된 페이지 파일, 불량 RAM, 디스크 연결 문제가 원인입니다.' } }
                '0x0000007A|0x7A'    { @{ Cause='KERNEL_DATA_INPAGE_ERROR - 커널 데이터 페이지 파일 읽기 실패'; Fix='디스크 오류 검사(chkdsk /f), RAM 진단, 페이지 파일 크기 재설정'; Detail='KERNEL_DATA_INPAGE_ERROR는 시스템이 페이지 파일이나 메모리 매핑 파일에서 데이터를 읽지 못할 때 발생합니다. 디스크 오류, 불량 RAM, 파일 시스템 손상이 원인입니다.' } }
                '0x0000007B|0x7B'    { @{ Cause='INACCESSIBLE_BOOT_DEVICE - 부팅 장치에 접근 불가'; Fix='부팅 드라이버(특히 SATA/NVMe/RAID) 업데이트, BIOS 부팅 모드 확인, 디스크 연결 점검'; Detail='INACCESSIBLE_BOOT_DEVICE는 Windows 부팅 중 시스템 파티션에 접근할 수 없을 때 발생합니다. 저장장치 드라이버 누락/손상, BIOS 설정 변경(AHCI/RAID 모드), 디스크 고장이 원인입니다.' } }
                '0x0000007E|0x7E'    { @{ Cause='SYSTEM_THREAD_EXCEPTION_NOT_HANDLED - 시스템 스레드 예외 처리 실패'; Fix='최근 Windows 업데이트를 롤백하거나 드라이버를 업데이트하세요.'; Detail='SYSTEM_THREAD_EXCEPTION_NOT_HANDLED는 시스템 스레드에서 처리되지 않은 예외가 발생했음을 의미합니다. 불량 드라이버, 손상된 시스템 파일, 또는 최근 Windows 업데이트와의 호환성 문제가 주요 원인입니다.' } }
                '0x0000007F|0x7F'    { @{ Cause='UNEXPECTED_KERNEL_MODE_TRAP - 커널 모드 트랩 오류'; Fix='CPU 오버클럭 해제, 메모리 진단, 전원 공급 장치 점검, CPU 발열 확인'; Detail='UNEXPECTED_KERNEL_MODE_TRAP은 커널이 예상치 못한 예외(0으로 나누기, 정밀도 오류 등)를 발생시켰을 때 나타납니다. CPU 오버클럭 불안정, 불량 RAM, CPU 발열 문제가 주요 원인입니다.' } }
                '0x00000080|0x80'    { @{ Cause='NMI_HARDWARE_FAILURE - NMI 하드웨어 오류'; Fix='메모리 진단, CPU/메모리 오버클럭 해제, 전원 공급 장치 점검, 마더보드 점검'; Detail='NMI_HARDWARE_FAILURE는 마스크 불가능 인터럽트(NMI)가 하드웨어 오류를 감지했음을 의미합니다. RAM 오류, CPU 캐시 오류, PCIe 장치 결함, 전원 공급 불안정이 원인입니다.' } }
                '0x0000008E|0x8E'    { @{ Cause='KERNEL_MODE_EXCEPTION_NOT_HANDLED - 커널 모드 예외 미처리'; Fix='드라이버 업데이트, 최근 설치한 소프트웨어 제거, Windows 업데이트'; Detail='KERNEL_MODE_EXCEPTION_NOT_HANDLED (0x8E)는 0x1E의 레거시 버전입니다. 불량 드라이버, 손상된 시스템 파일, 호환되지 않는 하드웨어가 원인입니다.' } }
                '0x0000009C|0x9C'    { @{ Cause='MACHINE_CHECK_EXCEPTION - CPU 하드웨어 오류'; Fix='CPU 오버클럭/Curve Optimizer 해제, CPU 발열 및 전압 점검, BIOS 업데이트'; Detail='MACHINE_CHECK_EXCEPTION은 CPU가 치명적인 하드웨어 오류를 감지했음을 의미합니다. CPU 전압 부족(Curve Optimizer), CPU 발열, 전원 공급 불안정, 마더보드 문제가 주요 원인입니다.' } }
                '0x0000009F|0x9F'    { @{ Cause='DRIVER_POWER_STATE_FAILURE - 전원 관리 드라이버 타임아웃'; Fix='BIOS 업데이트, 전원 관리 드라이버 재설치, 절전 모드 설정 초기화'; Detail='DRIVER_POWER_STATE_FAILURE는 드라이버가 전원 상태 전환(절전/깨우기)을 제시간에 완료하지 못할 때 발생합니다. BIOS, 칩셋 드라이버, 그래픽 드라이버 업데이트로 해결됩니다.' } }
                '0x000000A0|0xA0'    { @{ Cause='INTERNAL_POWER_ERROR - 내부 전원 관리 오류'; Fix='전원 관리 드라이버 업데이트, BIOS 업데이트, 전원 설정 초기화'; Detail='INTERNAL_POWER_ERROR는 Windows 전원 관리자에서 내부 오류가 발생했음을 의미합니다. ACPI 드라이버, 전원 관리 드라이버, BIOS 호환성 문제가 원인일 수 있습니다.' } }
                '0x000000A5|0xA5'    { @{ Cause='ACPI_BIOS_ERROR - ACPI BIOS 오류'; Fix='BIOS 업데이트, BIOS 설정을 기본값으로 초기화, 최근 하드웨어 변경사항 점검'; Detail='ACPI_BIOS_ERROR는 ACPI(고급 전원 관리 인터페이스) BIOS에 호환성 문제가 있을 때 발생합니다. 오래된 BIOS 버전, 불안정한 펌웨어, 마더보드 결함이 원인일 수 있습니다.' } }
                '0x000000BE|0xBE'    { @{ Cause='ATTEMPTED_WRITE_TO_READONLY_MEMORY - 읽기 전용 메모리에 쓰기 시도'; Fix='드라이버 업데이트, 최근 설치한 소프트웨어/드라이버 제거'; Detail='ATTEMPTED_WRITE_TO_READONLY_MEMORY는 드라이버가 읽기 전용으로 표시된 메모리 영역에 쓰기를 시도했을 때 발생합니다. 불량 드라이버, 특히 그래픽/비디오 드라이버가 주요 원인입니다.' } }
                '0x000000C1|0xC1'    { @{ Cause='SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION - 드라이버 검증기 메모리 손상 감지'; Fix='Driver Verifier가 활성화된 경우 비활성화, 해당 드라이버 업데이트/제거'; Detail='SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION은 Driver Verifier의 특수 풀에서 메모리 손상이 감지되었음을 의미합니다. Driver Verifier가 켜져 있을 때만 발생하며, 어떤 드라이버가 문제인지 식별하는 데 도움을 줍니다.' } }
                '0x000000C2|0xC2'    { @{ Cause='BAD_POOL_CALLER - 드라이버의 잘못된 메모리 풀 호출'; Fix='드라이버 업데이트, 최근 설치한 소프트웨어/드라이버 제거, 메모리 진단'; Detail='BAD_POOL_CALLER는 드라이버나 커널 모드 코드가 메모리 풀에 대해 잘못된 작업(이중 해제, 잘못된 크기 할당 등)을 요청했을 때 발생합니다. 불량 드라이버가 가장 흔한 원인입니다.' } }
                '0x000000C4|0xC4'    { @{ Cause='DRIVER_VERIFIER_DETECTED_VIOLATION - 드라이버 검증기 위반'; Fix='Driver Verifier 비활성화(verifier /reset), 문제 드라이버 업데이트/제거'; Detail='DRIVER_VERIFIER_DETECTED_VIOLATION은 Driver Verifier가 드라이버의 잘못된 동작을 감지했음을 의미합니다. 이는 Driver Verifier를 활성화한 경우에만 나타나며, 특정 드라이버에 버그가 있음을 나타냅니다.' } }
                '0x000000C5|0xC5'    { @{ Cause='DRIVER_CORRUPTED_EXPOOL - 드라이버가 페이징 풀 메모리 손상'; Fix='드라이버 업데이트, 최근 설치한 하드웨어/소프트웨어 제거, 메모리 진단'; Detail='DRIVER_CORRUPTED_EXPOOL은 드라이버가 페이징 가능한 메모리 풀을 손상시켰을 때 발생합니다. 그래픽 드라이버, 네트워크 드라이버, 파일 시스템 필터 드라이버가 주요 원인입니다.' } }
                '0x000000CE|0xCE'    { @{ Cause='DRIVER_UNLOADED_WITHOUT_CANCELLING_PENDING_OPERATIONS - 드라이버가 보류 중인 작업을 취소하지 않고 언로드됨'; Fix='해당 드라이버 업데이트 또는 제거'; Detail='드라이버가 언로드되기 전에 보류 중인 I/O 요청을 취소하지 않았습니다. 특정 드라이버를 동적으로 로드/언로드하는 소프트웨어에서 발생할 수 있습니다.' } }
                '0x000000D1|0xD1'    { @{ Cause='DRIVER_IRQL_NOT_LESS_OR_EQUAL - 네트워크 또는 그래픽 드라이버 충돌'; Fix='네트워크/그래픽 드라이버를 DDU로 제거 후 최신 버전으로 재설치'; Detail='DRIVER_IRQL_NOT_LESS_OR_EQUAL은 드라이버가 너무 높은 IRQL에서 메모리에 접근하려 했을 때 발생합니다. 주로 네트워크 드라이버, 그래픽 드라이버, 또는 가상화 소프트웨어가 원인입니다.' } }
                '0x000000D5|0xD5'    { @{ Cause='DRIVER_PAGE_FAULT_IN_FREED_SPECIAL_POOL - 드라이버가 이미 해제된 특수 풀에 접근'; Fix='Driver Verifier 비활성화, 해당 드라이버 업데이트'; Detail='DRIVER_PAGE_FAULT_IN_FREED_SPECIAL_POOL은 드라이버가 이미 해제된 Driver Verifier 특수 풀 메모리에 접근하려 할 때 발생합니다. Driver Verifier가 활성화된 상태에서만 발생합니다.' } }
                '0x000000D8|0xD8'    { @{ Cause='DRIVER_USED_EXCESSIVE_PTES - 드라이버가 과도한 페이지 테이블 엔트리 사용'; Fix='그래픽 드라이버 업데이트, GPU 메모리 제한 설정 확인, 오버클럭 해제'; Detail='DRIVER_USED_EXCESSIVE_PTES는 드라이버(주로 그래픽 드라이버)가 너무 많은 페이지 테이블 엔트리를 사용하여 시스템 PTEs를 고갈시켰을 때 발생합니다. 그래픽 집약적 작업이나 GPU 메모리 누수가 원인입니다.' } }
                '0x000000E3|0xE3'    { @{ Cause='RESOURCE_NOT_OWNED - 드라이버가 소유하지 않은 리소스에 접근'; Fix='드라이버 업데이트, 해당 소프트웨어 제거'; Detail='RESOURCE_NOT_OWNED는 스레드가 현재 소유하지 않은 커널 리소스를 해제하려고 할 때 발생합니다. 파일 시스템 필터나 디스크 관련 드라이버에서 주로 발생합니다.' } }
                '0x000000EA|0xEA'    { @{ Cause='THREAD_STUCK_IN_DEVICE_DRIVER - 그래픽 드라이버 응답 없음 (TDR)'; Fix='그래픽 드라이버를 DDU로 완전 제거 후 재설치, PCIe 설정 확인'; Detail='THREAD_STUCK_IN_DEVICE_DRIVER는 그래픽 드라이버가 너무 오랫동안 응답하지 않을 때 발생합니다. GPU 오버클럭, 불안정한 드라이버 버전, PCIe 대역폭 문제가 원인일 수 있습니다.' } }
                '0x000000ED|0xED'    { @{ Cause='IO_OBJECT_TERMINATION - I/O 객체 종료 오류'; Fix='디스크 오류 검사, 저장장치 드라이버 업데이트, 시스템 파일 검사'; Detail='IO_OBJECT_TERMINATION은 I/O 관리자가 객체 종료 중 오류를 감지했을 때 발생합니다. 불량 저장장치 드라이버, 파일 시스템 손상, 디스크 오류가 원인일 수 있습니다.' } }
                '0x000000EF|0xEF'    { @{ Cause='CRITICAL_PROCESS_DIED - 중요 시스템 프로세스 종료'; Fix='SFC /scannow, DISM 복구, Windows 업데이트, 최근 설치한 소프트웨어 제거'; Detail='CRITICAL_PROCESS_DIED는 Windows의 중요한 사용자 모드 프로세스(csrss.exe, winlogon.exe 등)가 종료되었음을 의미합니다. 시스템 파일 손상, 디스크 오류, 맬웨어가 원인일 수 있습니다.' } }
                '0x000000F3|0xF3'    { @{ Cause='DISORDERLY_SHUTDOWN - 비정상 시스템 종료 감지'; Fix='시스템 파일 검사(SFC), 디스크 오류 검사, 전원 공급 장치 점검'; Detail='DISORDERLY_SHUTDOWN은 시스템이 비정상적인 순서로 종료되거나 불안정한 상태가 감지되었음을 의미합니다. 전원 문제, 시스템 파일 손상, 드라이버 문제가 원인일 수 있습니다.' } }
                '0x000000F4|0xF4'    { @{ Cause='CRITICAL_OBJECT_TERMINATION - 시스템 중요 프로세스/스레드 종료'; Fix='디스크 오류 검사, SFC /scannow, Windows 복구 도구 실행'; Detail='CRITICAL_OBJECT_TERMINATION은 Windows 시스템에 필수적인 프로세스나 스레드가 종료되었음을 의미합니다. 디스크 손상, 시스템 파일 손상, 또는 맬웨어 감염이 원인일 수 있습니다.' } }
                '0x000000F7|0xF7'    { @{ Cause='DRIVER_OVERRAN_STACK_BUFFER - 드라이버 스택 버퍼 오버런'; Fix='해당 드라이버 업데이트 또는 제거, Driver Verifier로 문제 드라이버 식별'; Detail='DRIVER_OVERRAN_STACK_BUFFER는 드라이버가 스택에 할당된 버퍼를 초과하여 데이터를 썼을 때 발생합니다. 이는 보안 취약점(CVE)으로 이어질 수 있는 심각한 드라이버 버그입니다.' } }
                '0x000000FE|0xFE'    { @{ Cause='BUGCODE_USB_DRIVER - USB 드라이버 오류'; Fix='USB 컨트롤러 드라이버 업데이트, USB 장치 분리 후 테스트, BIOS 업데이트'; Detail='BUGCODE_USB_DRIVER는 USB 드라이버 스택에서 오류가 발생했음을 의미합니다. 결함 있는 USB 장치, USB 컨트롤러 드라이버, 전원 공급 부족이 원인입니다.' } }
                '0x00000101|0x101'   { @{ Cause='CLOCK_WATCHDOG_TIMEOUT - CPU 코어 응답 없음 (오버클럭 불안정)'; Fix='CPU 오버클럭/Curve Optimizer 해제, BIOS 기본값 복원, 전원 설정 확인'; Detail='CLOCK_WATCHDOG_TIMEOUT은 CPU 코어가 예상 시간 내에 인터럽트에 응답하지 않을 때 발생합니다. CPU 오버클럭이 불안정하거나 Curve Optimizer CO 값이 너무 낮을 때 idle 상태에서 주로 발생합니다.' } }
                '0x00000109|0x109'   { @{ Cause='CRITICAL_STRUCTURE_CORRUPTION - 중요 시스템 구조 손상'; Fix='메모리 진단, 최근 하드웨어 변경사항 점검, BIOS 업데이트'; Detail='CRITICAL_STRUCTURE_CORRUPTION은 Windows 커널의 중요한 데이터 구조가 손상되었음을 의미합니다. 불량 RAM, CPU 캐시 오류, 또는 심각한 드라이버 버그가 원인입니다.' } }
                '0x0000010D|0x10D'   { @{ Cause='WDF_VIOLATION - Windows 드라이버 프레임워크 위반'; Fix='해당 WDF 드라이버 업데이트, Windows 업데이트'; Detail='WDF_VIOLATION은 Windows Driver Framework(WDF) 기반 드라이버에서 규칙 위반이 발생했음을 의미합니다. WDF 드라이버의 버그나 호환성 문제가 원인입니다.' } }
                '0x0000010E|0x10E'   { @{ Cause='VIDEO_MEMORY_MANAGEMENT_INTERNAL - GPU 메모리 관리 내부 오류'; Fix='그래픽 드라이버 업데이트, GPU 오버클럭 해제, GPU 전원 설정 확인'; Detail='VIDEO_MEMORY_MANAGEMENT_INTERNAL은 그래픽 드라이버의 메모리 관리자에서 내부 오류가 발생했음을 의미합니다. GPU 오버클럭, 불안정한 드라이버, GPU 메모리 결함이 원인입니다.' } }
                '0x00000119|0x119'   { @{ Cause='VIDEO_TDR_TIMEOUT_DETECTED - 그래픽 드라이버 TDR 타임아웃'; Fix='그래픽 드라이버 업데이트, TDR 레지스트리 값 증가, GPU 오버클럭 해제'; Detail='VIDEO_TDR_TIMEOUT_DETECTED는 GPU가 디스플레이 드라이버 모델 내에서 정해진 시간 내에 응답하지 않을 때 발생합니다. GPU 오버클럭, 불안정한 드라이버, 전원 공급 부족이 원인입니다.' } }
                '0x0000011A|0x11A'   { @{ Cause='EMULATOR_ACCESS_VIOLATION - Android 에뮬레이터/WSL 메모리 접근 위반'; Fix='WSL/Android 에뮬레이터 업데이트, 가상화 설정 확인, Hyper-V 설정 점검'; Detail='EMULATOR_ACCESS_VIOLATION은 Windows 에뮬레이터(Android, WSL 등)가 잘못된 메모리에 접근했을 때 발생합니다. 가상화 소프트웨어 업데이트나 Hyper-V 설정 변경으로 해결됩니다.' } }
                '0x00000121|0x121'   { @{ Cause='DRIVER_VIOLATION - 드라이버 일반 위반'; Fix='드라이버 업데이트, 최근 설치한 하드웨어/소프트웨어 제거'; Detail='DRIVER_VIOLATION은 드라이버가 Windows 규칙을 위반했음을 의미합니다. 다양한 드라이버 버그, 호환성 문제가 원인일 수 있습니다.' } }
                '0x00000124|0x124'   { @{ Cause='WHEA_UNCORRECTABLE_ERROR - WHEA 하드웨어 오류 (CPU/전압 불안정)'; Fix='CPU 오버클럭/Curve Optimizer CO 값 완화, CPU 발열 및 전압 점검, BIOS 업데이트'; Detail='WHEA_UNCORRECTABLE_ERROR는 치명적인 하드웨어 오류를 의미합니다. CPU 코어 전압 부족(Curve Optimizer), CPU 오버클럭 불안정, 메모리 오버클럭, 전원 공급 장치 불량이 주요 원인입니다. 저부하에서만 발생하면 CO 값이 원인일 가능성이 높습니다.' } }
                '0x0000012B|0x12B'   { @{ Cause='WORKER_THREAD_RETURNED_WITH_NON_DEFAULT_WORKQUEUE - 드라이버 작업자 스레드 오류'; Fix='해당 드라이버 업데이트, Windows 업데이트'; Detail='작업자 스레드가 기본이 아닌 작업 큐로 반환되었습니다. 주로 파일 시스템 필터 드라이버나 저장장치 드라이버에서 발생합니다.' } }
                '0x00000133|0x133'   { @{ Cause='DPC_WATCHDOG_VIOLATION - DPC 타이머 오버런 (드라이버 지연)'; Fix='SSD 펌웨어 업데이트, 저장장치 드라이버 업데이트, BIOS 기본값 복원'; Detail='DPC_WATCHDOG_VIOLATION은 Deferred Procedure Call이 너무 오래 실행되어 watchdog 타이머가 만료되었음을 의미합니다. 불량 저장장치 드라이버, SSD 펌웨어 문제, 전원 관리 설정이 원인일 수 있습니다.' } }
                '0x00000139|0x139'   { @{ Cause='KERNEL_SECURITY_CHECK_FAILURE - 커널 보안 검사 실패'; Fix='드라이버 호환성 확인, 최근 설치한 소프트웨어 제거, 시스템 복원'; Detail='KERNEL_SECURITY_CHECK_FAILURE는 Windows 커널의 보안 검사가 실패했음을 의미합니다. 서명되지 않은 드라이버, 손상된 시스템 파일, 또는 악성 소프트웨어가 원인일 수 있습니다.' } }
                '0x00000141|0x141'   { @{ Cause='VIDEO_DXGKRNL_FATAL_ERROR - 그래픽 하위 시스템 치명적 오류'; Fix='그래픽 드라이버를 DDU로 완전 제거 후 최신 버전 재설치, GPU 오버클럭 해제'; Detail='VIDEO_DXGKRNL_FATAL_ERROR는 DirectX 그래픽 커널에서 복구 불가능한 오류가 발생했음을 의미합니다. GPU 오버클럭, 불안정한 드라이버, GPU 메모리 결함이 원인입니다.' } }
                '0x00000142|0x142'   { @{ Cause='VIDEO_TDR_FAILURE - 그래픽 드라이버 TDR 실패'; Fix='그래픽 드라이버 DDU 제거 후 재설치, GPU 전원/발열 점검, PCIe 설정 확인'; Detail='VIDEO_TDR_FAILURE는 Timeout Detection and Recovery가 실패하여 GPU가 복구되지 못했음을 의미합니다. GPU 하드웨어 불안정, 전원 공급 부족, 드라이버 충돌이 원인입니다.' } }
                '0x000001BC|0x1BC'   { @{ Cause='CRITICAL_PROCESS_DIED - 중요 프로세스 예기치 않은 종료'; Fix='SFC /scannow 실행, Windows 복구 도구, 최근 업데이트 제거'; Detail='CRITICAL_PROCESS_DIED는 Windows의 중요한 사용자 모드 프로세스가 종료되었음을 의미합니다. 시스템 파일 손상, 디스크 오류, 또는 최근 Windows 업데이트 결함이 원인일 수 있습니다.' } }
                default              { @{ Cause='알 수 없는 오류'; Fix='이벤트 뷰어 및 메모리 진단(mdsched.exe)을 통해 추가 분석이 필요합니다.'; Detail='버그체크 코드에 대한 상세 정보가 없습니다. Windows 이벤트 뷰어에서 시스템 로그의 BugCheck 이벤트(ID 1001)를 확인하세요.' } }
              }
              Write-Host "→ ${bc} ($($bcDesc.Cause))"
              Write-LogEntry "  → 원인: $($bcDesc.Cause)"
              try { Add-Content -Path $logPath -Value "  → 해결: $($bcDesc.Fix)" -Encoding UTF8 } catch { }
              try { Add-Content -Path $logPath -Value "  → 상세 분석: $($bcDesc.Detail)" -Encoding UTF8 } catch { }
              $failureReasons += "[BSOD] ${bc} ($($bcDesc.Cause)) - $($d.Name) ($ts)"
              $recommendations += "[BSOD] $($d.Name) - $($bcDesc.Cause) $($bcDesc.Fix)"
            }
          } else {
            $altInfo = try { $fs2 = [System.IO.File]::OpenRead($d.FullName); $r = New-Object System.IO.BinaryReader($fs2); $s=$r.ReadUInt32(); $sigBytes=[System.BitConverter]::GetBytes($s); $next4=$r.ReadBytes(4); $r.Close(); [System.Text.Encoding]::ASCII.GetString($sigBytes)+[System.Text.Encoding]::ASCII.GetString($next4) } catch { '읽기오류' }
            $fmtName = if ($altInfo -match 'PAGEDU64') { '페이지 파일 덤프(PAGEDU64)' } elseif ($altInfo -match 'MDMP') { '미니덤프(MiniDump)' } else { "알 수 없는 덤프 형식 - 추후 업데이트 시 분석 가능할 수 있습니다" }
            Write-LogEntry "BSOD: WARN - $($d.Name) ($ts, ${sz}KB) (분석 불가: $fmtName)"
            Write-Host "→ $($d.Name): $fmtName — 블루스크린 원인을 자동 분석할 수 없습니다. Windows 이벤트 뷰어에서 시스템 로그의 BugCheck 이벤트(ID 1001)를 확인해보세요."
            $failureReasons += "[BSOD] 덤프 파일 발견 (분석 불가) — 블루스크린 원인 식별 불가: $($d.Name)"
          }
        }
      }
    }
  }
} catch {
  Write-LogEntry "BSOD: SKIP - Unable to analyze crash dumps: $_"
}

# --- SFC 시스템 파일 무결성 검사 (WinSxS 분석과 병렬) ---
Write-ProgressBar "SFC"
Write-TestHeader "[SFC] 시스템 파일 검사기로 Windows 보호 파일의 무결성을 검증합니다."
# 무거운 검사 게이트(기본 30일): 실측 SFC 112~240초/회, 7회 연속 정상 → 6일마다 중복 실행 불필요
$lastSfc = Get-StampDate (Join-Path $scriptRoot '.last_sfc')
$sfcDue = Test-DueByDays $lastSfc $heavyCheckDays
if (-not $sfcDue) {
  Write-LogEntry ("SFC: SKIP - gated ({0}d interval, last {1})" -f $heavyCheckDays, $(if ($lastSfc) { $lastSfc.ToString('yyyy-MM-dd') } else { 'never' }))
} else {
try {
  # DISM 병렬 실행 (SFC와 동시에)
  $dismProc = if ($shouldCleanWinSxS) { Start-Process -FilePath 'DISM' -ArgumentList '/online /Cleanup-Image /AnalyzeComponentStore' -NoNewWindow -PassThru } else { $null }
  $sfcTemp = Join-Path $env:TEMP "sfc_verify_$(Get-Random).txt"
  $sfcProc = Start-Process -FilePath 'sfc' -ArgumentList '/verifyonly' -NoNewWindow -PassThru -RedirectStandardOutput $sfcTemp
  # sfc /verifyonly 는 시스템에 따라 3분 이상 걸린다 → 10분 대기
  $sfcTimedOut = -not $sfcProc.WaitForExit(600000)
  if ($sfcTimedOut) { $sfcProc.Kill(); Start-Sleep 1 }
  $sfcRaw = ''
  if (Test-Path -LiteralPath $sfcTemp) {
    # sfc는 UTF-16LE(BOM 없음)로 출력 → 바이트로 읽어 인코딩 판별 (Get-Content 기본 디코딩은 깨짐)
    try {
      $sfcBytes = [System.IO.File]::ReadAllBytes($sfcTemp)
      $isUtf16 = ($sfcBytes.Length -gt 3 -and (($sfcBytes[0] -eq 0xFF -and $sfcBytes[1] -eq 0xFE) -or ($sfcBytes[1] -eq 0 -and $sfcBytes[3] -eq 0)))
      $sfcRaw = if ($isUtf16) { [System.Text.Encoding]::Unicode.GetString($sfcBytes) } else { [System.Text.Encoding]::UTF8.GetString($sfcBytes) }
    } catch { $sfcRaw = Get-Content -LiteralPath $sfcTemp -Raw -ErrorAction SilentlyContinue }
  }
  Remove-Item -LiteralPath $sfcTemp -Force -ErrorAction SilentlyContinue
  $sfcOut = $sfcRaw -replace "`0", ""
  if ($dismProc) { $dismProc.WaitForExit(); $script:winsxsAnalysisOutput = "DISM exit code: $($dismProc.ExitCode)"; $script:winsxsAnalysisEc = $dismProc.ExitCode }
  if ($sfcOut -match '(?i)(무결성 위반을.{0,4}지 못했습니다|찾지 못했습니다|did not find any integrity violations|no integrity violations)') {
    Write-LogEntry 'SFC: PASS - 문제 없음'
  } elseif ($sfcOut -match '(?i)(무결성 위반을 발견|found corrupt files|integrity violations|repairing|복구)') {
    # 2026-11-16: 기존 '✓/⚠/✗' 기호는 결과 txt 필터(: PASS|FAIL|WARN|CHANGE)에 걸리지 않아
    #   SFC 가 유일한 실패 사유인데도 리포트에 SFC 줄이 하나도 없었다(친구 PC 2026-11-15).
    #   → PASS/WARN/FAIL 로 통일하고, 복구 성공 시 실패 사유를 제거한다(CHKDSK 와 같은 규칙).
    Write-LogEntry 'SFC: WARN - 시스템 파일 무결성 위반 발견, 복구 시도 중...'
    $sfcReason = '[SFC] 시스템 파일 무결성 위반 발견'
    $failureReasons += $sfcReason
    try { Checkpoint-Computer -Description "Maintenance backup before SFC repair" -ErrorAction SilentlyContinue } catch { }
    try {
      $p2 = Start-Process -FilePath 'sfc' -ArgumentList '/scannow' -NoNewWindow -Wait -PassThru
      if ($p2.ExitCode -eq 0) {
        Write-LogEntry 'SFC 복구: PASS - sfc /scannow 완료 (위반 파일 복구)'
        Add-AutoFix 'SFC: 시스템 파일 무결성 위반 복구 (sfc /scannow)'
        $failureReasons = @($failureReasons | Where-Object { -not ([string]$_).StartsWith($sfcReason) })
      } else {
        Write-LogEntry "SFC 복구: WARN - sfc /scannow 종료 코드 $($p2.ExitCode)"
        $recommendations += "[SFC] 시스템 파일 일부를 복구하지 못했습니다(종료 코드 $($p2.ExitCode)). Windows 업데이트 후 'DISM /Online /Cleanup-Image /RestoreHealth' → 'sfc /scannow' 순서로 재시도하세요."
      }
    } catch { Write-LogEntry "SFC 복구: FAIL - $_" }
    try {
      $dismP = Start-Process -FilePath 'DISM' -ArgumentList '/Online /Cleanup-Image /ScanHealth' -NoNewWindow -Wait -PassThru
      $dismEc = $dismP.ExitCode
      $dismMsg = switch ($dismEc) { 0 { 'PASS - 구성 요소 저장소 손상 없음' } 87 { 'WARN - DISM 오류 87: 잘못된 인수' } 112 { 'WARN - DISM 오류 112: 디스크 공간 부족' } 1392 { 'WARN - DISM 오류 1392: 파일 손상 (RestoreHealth 필요)' } default { "WARN - DISM 종료 코드 $dismEc" } }
      Write-LogEntry "DISM: $dismMsg"
    } catch { Write-LogEntry "DISM: FAIL - $_" }
  } else {
    if ($sfcTimedOut) {
      Write-LogEntry 'SFC: WARN - sfc /verifyonly 가 10분 내에 끝나지 않아 중단됨 (다음 실행에서 재시도)'
    } else {
      Write-LogEntry 'SFC: FAIL - 시스템 파일 검사 결과를 읽을 수 없음 (출력 없음)'
      $allPass = $false
      $failureReasons += "[SFC] sfc /verifyonly 실행 불가 (출력 없음)"
    }
  }
  Set-StampDate (Join-Path $scriptRoot '.last_sfc')
} catch {
  Write-LogEntry "SFC: FAIL - $_"
  $allPass = $false
  $failureReasons += "[SFC] 시스템 파일 검사 실패: $_"
}
}

# --- WinSxS 정리 (30일 주기) ---
Write-ProgressBar "WinSxS"
Write-TestHeader "[WinSxS] WinSxS 구성 요소 저장소 크기를 확인하고 정리합니다."
if ($shouldCleanWinSxS) {
  try {
    if ($script:winsxsAnalysisOutput) {
      $analysis = $script:winsxsAnalysisOutput
    } else {
      Write-InterimLine 'Analyzing component store...'
      $analysis = & DISM /online /Cleanup-Image /AnalyzeComponentStore 2>&1 | Out-String
    }
    if ($analysis -match 'Component Store Cleanup Recommended\s*:\s*Yes') {
      Write-LogEntry 'WinSxS: Analysis shows cleanup needed, proceeding...'
      # /ResetBase 제거(2026-11-05): Microsoft 문서 — ResetBase 를 쓰면 "기존 업데이트 패키지를
      #   제거(롤백)할 수 없다". 자동 유지보수가 되돌릴 수 없는 상태를 만들 이유가 없다.
      #   Windows 는 StartComponentCleanup 을 자체 스케줄로 이미 수행하며(30일 유예), 우리는 그보다
      #   적극적인 /StartComponentCleanup 만 실행한다. 공간이 급박할 때만 수동으로 ResetBase 를 쓴다.
      $null = & DISM /online /Cleanup-Image /StartComponentCleanup 2>&1
      if ($LASTEXITCODE -eq 0) {
        Write-LogEntry 'WinSxS: PASS - Component store cleanup completed (ResetBase 미사용: 업데이트 롤백 가능 유지)'
      } else {
        Write-LogEntry "WinSxS: WARN - DISM returned exit code $LASTEXITCODE"
      }
    } else {
      Write-LogEntry 'WinSxS: SKIP - Component store does not need cleanup'
    }
    New-Item -Path $winsxsFlag -ItemType File -Force | Out-Null
  } catch {
    Write-LogEntry "WinSxS: FAIL - $($_.Exception.Message)"
    $failureReasons += "[WinSxS] WinSxS 정리 실패: $_"
  }
} else {
  $daysSince = [math]::Round(((Get-Date) - $lastWinSxs).TotalDays, 1)
  Write-LogEntry "WinSxS: SKIP - Last cleanup was ${daysSince}d ago (threshold: 30d)"
}

# --- 이벤트 로그 펼침 데이터(EventData)를 이름→값 해시로 변환 ---
#   ToXml() 의 Data Name 은 언어에 독립적이라, 지역화된 메시지 문자열을 파싱하지 않아도 된다.
function ConvertFrom-EventData {
  param($Event)
  $map = @{}
  try {
    $xml = [xml]$Event.ToXml()
    foreach ($d in $xml.Event.EventData.Data) {
      if ($d.Name) { $map[[string]$d.Name] = [string]$d.'#text' }
    }
  } catch { }
  return $map
}

# --- 시간 동기화 상태 (NTP 오프셋 실측) ---
Write-ProgressBar "TimeSync"
Write-TestHeader "[TimeSync] NTP 오프셋을 실측해 시계 오차를 확인합니다."
# 배경(11-05 실측): Time-Service 134/135 는 7일간 37건이지만 전부 부팅 0~2초 후 발생한다.
#   = 네트워크/DNS 준비 전 NTP 조회 실패이며 실제 동기화는 정상(소스 pool.ntp.org).
#   따라서 재설정이 아니라 "지금 오프셋이 얼마인가"만 재는 것이 의미 있는 검사다.
try {
  $w32svc = Get-Service w32time -ErrorAction SilentlyContinue
  if ($w32svc) {
    if ($w32svc.Status -ne 'Running') {
      # 자동 조치(가역): 시간 서비스가 멈춰 있으면 재동기화가 불가능하다 → 시작한다.
      try {
        Start-Service -Name w32time -ErrorAction Stop
        (Get-Service -Name w32time).WaitForStatus('Running', '00:00:15')
        Write-LogEntry "TimeSync: CHANGE - W32Time 서비스 시작 (was $($w32svc.Status))"
        Add-AutoFix "W32Time 서비스 시작 (was $($w32svc.Status))"
      } catch {
        Write-LogEntry "TimeSync: WARN - W32Time 서비스가 $($w32svc.Status) 상태 (시작 실패: $($_.Exception.Message))"
        $recommendations += '[TimeSync] W32Time 서비스가 중지됨 — services.msc에서 시작 유형 확인 후 Start-Service w32time'
      }
    }
  } else {
    Write-LogEntry 'TimeSync: WARN - W32Time 서비스를 찾을 수 없음'
  }

  $ntpHost = 'pool.ntp.org'
  # 오프셋 측정은 두 번(보정 전/후) 필요하므로 scriptblock 으로 묶는다.
  #   출력 예: "11:15:29, +00.6550236s" → 부호/숫자만 추출(언어 독립)
  $measureNtp = {
    param([string]$NtpServer)
    $r = Invoke-NativeWithSpinner -FilePath "$env:SystemRoot\System32\w32tm.exe" `
      -Arguments "/stripchart /computer:$NtpServer /samples:3 /dataonly" -Label 'NTP' -TimeoutMs 25000
    $vals = @()
    if ($r -and $r.Output) {
      foreach ($m in [regex]::Matches($r.Output, '([+-]\d+(?:[.,]\d+)?)s')) {
        $raw = ($m.Groups[1].Value).Replace(',', '.')
        $v = 0.0
        if ([double]::TryParse($raw, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
          $vals += $v
        }
      }
    }
    if ($vals.Count -eq 0) { return $null }
    $abs = @($vals | ForEach-Object { [math]::Abs($_) } | Sort-Object)
    return $abs[[int][math]::Floor($abs.Count / 2)]
  }
  $median = & $measureNtp $ntpHost
  if ($null -eq $median) {
    Write-LogEntry "TimeSync: SKIP - $ntpHost 응답 없음 (네트워크 또는 UDP 123 차단 여부 확인)"
  } else {
    $medianMs = [math]::Round($median * 1000)
    if ($median -lt 1) {
      Write-LogEntry "TimeSync: PASS - 시계 오차 ${medianMs}ms (${ntpHost} 기준)"
    } else {
      $severity = if ($median -ge 5) { 'FAIL' } else { 'WARN' }
      Write-LogEntry "TimeSync: $severity - 시계 오차 ${medianMs}ms (${ntpHost} 기준, 1초 이상)"
      # 자동 조치(가역/안전): w32tm /resync /force 로 즉시 재동기화하고 오프셋을 다시 잰다.
      #   - 시간은 언제든 되돌릴 수 있고(다음 동기화가 덮어씀) TLS/인증 오류의 실제 원인이므로 자동화 가치가 크다.
      #   - 서비스가 멈춰 있으면 재동기화가 실패하므로 먼저 시작한다.
      $fixPrefix = ''
      $fixedMs = $null
      try {
        $svcNow = Get-Service -Name w32time -ErrorAction SilentlyContinue
        if (-not $svcNow -or $svcNow.Status -ne 'Running') {
          Start-Service -Name w32time -ErrorAction Stop
          (Get-Service -Name w32time).WaitForStatus('Running', '00:00:15')
          $fixPrefix = 'W32Time 서비스 시작 + '
        }
        $rs = Invoke-NativeWithSpinner -FilePath "$env:SystemRoot\System32\w32tm.exe" `
          -Arguments '/resync /force' -Label 'resync' -TimeoutMs 30000
        if ($rs -and $rs.ExitCode -eq 0) {
          Start-Sleep -Seconds 1
          $after = & $measureNtp $ntpHost
          if ($null -ne $after) { $fixedMs = [math]::Round($after * 1000) }
        }
      } catch {
        Write-LogEntry "TimeSync: WARN - 재동기화 실패: $($_.Exception.Message)"
      }
      if ($null -ne $fixedMs -and $fixedMs -lt 1000) {
        Add-AutoFix "${fixPrefix}시계 오차 ${medianMs}ms → ${fixedMs}ms 자동 보정 (w32tm /resync /force)"
      } else {
        $afterNote = if ($null -ne $fixedMs) { " (재측정 ${fixedMs}ms)" } else { '' }
        if ($median -ge 5) {
          $allPass = $false
          $failureReasons += "[TimeSync] 시계 오차 ${medianMs}ms — 자동 재동기화로 해결되지 않음"
          $recommendations += "[TimeSync] 시계 오차 ${medianMs}ms${afterNote} — w32tm /resync /rediscover 수동 실행. 반복되면 CMOS 배터리/가상화 시간 동기화 확인"
        } else {
          $recommendations += "[TimeSync] 시계 오차 ${medianMs}ms${afterNote} — 자동 보정이 1초 미만으로 떨어지지 않음(재동기화 반복 또는 NTP 서버 변경 검토)"
        }
      }
    }
  }
} catch {
  Write-LogEntry "TimeSync: SKIP - 확인 실패: $($_.Exception.Message)"
}

# --- 안정성 추세: 반복되는 오류 유형/앱 크래시 집계 ---
Write-ProgressBar "Stability"
Write-TestHeader "[Stability] 반복되는 오류 유형과 앱 크래시를 집계해 추세를 비교합니다."
# 배경: 7일간 경고/오류 1,911건. 대부분 고정 패턴(SecurityCenter 1120)이라 "총량"은 의미가 없고,
#   (a) 같은 앱이 반복 크래시하는지 (b) 이전 실행에 없던 새 오류 유형이 생겼는지가 실제 신호다.
try {
  $stabDays = [int](Get-Cfg 'eventLookbackDays')
  $stabCutoff = (Get-Date).AddDays(-$stabDays)
  $stabEvts = @(Get-WinEvent -FilterHashtable @{LogName = 'System', 'Application'; Level = 1, 2, 3; StartTime = $stabCutoff} -ErrorAction SilentlyContinue)
  Write-LogEntry "Stability: INFO - 최근 ${stabDays}일 경고/오류 $($stabEvts.Count)건"

  if ($stabEvts.Count -gt 0) {
    $groups = @($stabEvts | Group-Object { "$($_.ProviderName)/$($_.Id)" } | Sort-Object Count -Descending)
    $topStr = (@($groups | Select-Object -First 5 | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', ')
    Write-LogEntry "Stability: INFO - 상위: $topStr"

    # 앱 크래시(이벤트 1000)는 첫 번째 EventData(프로세스 이름)로 묶는다 → 언어 독립
    $crashEvts = @($stabEvts | Where-Object { $_.ProviderName -eq 'Application Error' -and $_.Id -eq 1000 })
    if ($crashEvts.Count -gt 0) {
      $crashByApp = @{}
      $crashMeta = @{}     # 앱 → "모듈: x.dll, 예외: 0xc0000005"
      foreach ($ce in $crashEvts) {
        $app = ''
        try { if ($ce.Properties.Count -gt 0) { $app = [string]$ce.Properties[0].Value } } catch { }
        if (-not $app) { $app = '(unknown)' }
        if ($crashByApp.ContainsKey($app)) { $crashByApp[$app]++ } else { $crashByApp[$app] = 1 }
        # 2026-11-15: 이벤트 1000 의 '오류 모듈'(Properties[3])과 예외 코드(Properties[6])를 같이 남긴다.
        #   이전에는 "이벤트 뷰어에서 오류 모듈을 확인하세요"라고만 안내해서 사용자가 직접 찾아야 했다
        #   (사용자 리포트 2026-11-15: grap-core64.aes 7회 충돌 — 어떤 모듈인지 알 수 없었음).
        if (-not $crashMeta.ContainsKey($app)) {
          try {
            if ($ce.Properties.Count -ge 7) {
              $crashMod = [string]$ce.Properties[3].Value
              $crashCode = [string]$ce.Properties[6].Value
              if ($crashMod) { $crashMeta[$app] = ("모듈: $crashMod, 예외: $crashCode") }
            }
          } catch { }
        }
      }
      $crashStr = (@($crashByApp.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ', ')
      Write-LogEntry "Stability: INFO - 앱 크래시 $($crashEvts.Count)건: $crashStr"
      $frequent = @($crashByApp.GetEnumerator() | Where-Object { $_.Value -ge 5 } | Sort-Object Value -Descending)
      # 반복 크래시는 "일반론"이 아니라 원인 지목이 필요하다(자동 복구로는 절대 해결되지 않는 유형).
      #   WLANExt.exe = Windows WLAN 확장 호스트 → 제조사 IHV DLL(이 머신은 IntelIHVRouter10.dll)을 로드하므로
      #   Wi-Fi 드라이버가 실제 원인이다(실측: WLAN-AutoConfig 10003 33건도 같은 DLL을 지목).
      # Wi-Fi 드라이버 검출: WLANExt.exe(Windows WLAN 확장 호스트) 크래시는 제조사 IHV DLL 을 로드하다 생기는
      #   "드라이버 문제"이므로, 앱 업데이트 같은 일반론 대신 이 PC에 설치된 Wi-Fi 드라이버를 직접 지목한다(2026-11-10).
      $wifiAdapter = $null
      try { $wifiAdapter = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.NdisPhysicalMedium -eq 9 }) | Select-Object -First 1 } catch { }
      $wifiDriverHint = 'Wi-Fi 드라이버 문제 — Windows Update/제조사에서 드라이버 업데이트 확인'
      if ($wifiAdapter) {
        $wifiVer = if ($wifiAdapter.DriverVersion) { [string]$wifiAdapter.DriverVersion } else { '버전 ?' }
        $wifiDate = ''
        # PS 5.1 의 Get-NetAdapter.DriverDate 는 DateTime 이 아니라 String 이다 → ToString(포맷) 이 예외를 던져 날짜가 조용히 사라졌다.
        try { if ($wifiAdapter.DriverDate) { $wifiDate = " ($(([datetime]$wifiAdapter.DriverDate).ToString('yyyy-MM-dd')))" } } catch { }
        Write-LogEntry "Stability: INFO - Wi-Fi 드라이버 검출: $($wifiAdapter.InterfaceDescription) $wifiVer$wifiDate"
        $wifiDriverHint = "Wi-Fi 드라이버 문제 [검출: $($wifiAdapter.InterfaceDescription), 드라이버 $wifiVer$wifiDate] — Windows Update/제조사에서 업데이트 확인"
      }
      $crashHint = @{
        'WLANExt.exe'  = $wifiDriverHint
        'GameBar.exe'  = 'Xbox Game Bar 앱 손상 — 설정 > 앱에서 복구/재설정'
        'explorer.exe' = '셸 확장(우클릭 메뉴/동기화 클라이언트) 충돌 — 최근 설치한 셸 확장 확인'
        'Rainmeter.exe' = 'Rainmeter 스킨/플러그인 충돌 — 스킨 업데이트 또는 제거'
      }
      foreach ($f in $frequent) {
        $crashDetail = ''
        if ($crashMeta.ContainsKey([string]$f.Key)) { $crashDetail = ' (' + [string]$crashMeta[[string]$f.Key] + ')' }
        # 2026-11-16: 알려진 안티치트/보안 모듈이면 "앱 업데이트 필요" 대신 제품명과 실제 조치를 적는다.
        $known = Get-KnownSecurityProduct ([string]$f.Key)
        $warnTail = if ($known) { "$($known.Product) — $($known.Note)" } else { '앱/드라이버 업데이트 필요' }
        Write-LogEntry "Stability: WARN - $($f.Key)가 ${stabDays}일간 $($f.Value)회 충돌$crashDetail — $warnTail"
        if ($known) { Write-LogEntry "Stability: INFO - $($f.Key) = $($known.Product) ($($known.Note))" }
        $hint = if ($known) { "$($known.Product) — $($known.Note). $($known.Advice)" } elseif ($crashHint.ContainsKey([string]$f.Key)) { $crashHint[[string]$f.Key] } else { '원인 앱을 업데이트/재설치하거나 제거' }
        $recommendations += "[Stability] $($f.Key) ${stabDays}일 $($f.Value)회 충돌$crashDetail — $hint"
      }
    }

    # 새 오류 유형 감지: 이전 실행에서 본 적 없는 Provider/EventID 조합
    $stabStatePath = Join-Path $scriptRoot 'stability-state.json'
    $stabState = Get-JsonState $stabStatePath
    if ($stabState.Count -gt 0) {
      $newGroups = @($groups | Where-Object { -not $stabState.ContainsKey([string]$_.Name) })
      if ($newGroups.Count -gt 0) {
        $newStr = (@($newGroups | Select-Object -First 5 | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', ')
        Write-LogEntry "Stability: CHANGE - 이전 실행에 없던 오류 유형 $($newGroups.Count)개: $newStr"
        foreach ($ng in @($newGroups | Select-Object -First 5)) {
          $recommendations += "[Stability] 새 오류 유형 $($ng.Name) $($ng.Count)건 — 이벤트 뷰어에서 상세 확인"
        }
      }
    }
    $newState = @{}
    foreach ($g in $groups) { $newState[[string]$g.Name] = [int]$g.Count }
    Save-JsonState $stabStatePath $newState
  }
} catch {
  Write-LogEntry "Stability: SKIP - 이벤트 집계 실패: $($_.Exception.Message)"
}

# --- 부팅/종료 성능 ---
Write-ProgressBar "BootPerf"
Write-TestHeader "[BootPerf] 부팅 소요 시간과 부팅 지연 요인을 확인합니다."
# Win32_StartupCommand 개수는 부팅 속도와 상관이 약하다. 실제 값은 Diagnostics-Performance 100(부팅)/101(지연)/200(종료).
try {
  $perfLog = 'Microsoft-Windows-Diagnostics-Performance/Operational'
  $lookback = [int](Get-Cfg 'eventLookbackDays')
  $perfCutoff = (Get-Date).AddDays(-$lookback)
  $bootEvts = @(Get-WinEvent -LogName $perfLog -MaxEvents 300 -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -eq 100 -and $_.TimeCreated -ge $perfCutoff } |
    Select-Object -First 5)

  if ($bootEvts.Count -eq 0) {
    Write-LogEntry "BootPerf: SKIP - 최근 ${lookback}일 부팅 성능 이벤트 없음 (로그 비활성 또는 재부팅 없음)"
  } else {
    $samples = @()
    foreach ($b in $bootEvts) {
      $d = ConvertFrom-EventData $b
      $bootMs = 0; $mainMs = 0; $postMs = 0
      [void][int]::TryParse([string]$d['BootTime'], [ref]$bootMs)
      [void][int]::TryParse([string]$d['MainPathBootTime'], [ref]$mainMs)
      [void][int]::TryParse([string]$d['BootPostBootTime'], [ref]$postMs)
      $samples += [pscustomobject]@{ Time = $b.TimeCreated; Boot = $bootMs; Main = $mainMs; Post = $postMs }
    }
    $valid = @($samples | Where-Object { $_.Main -gt 0 })
    if ($valid.Count -gt 0) {
      $avgMain = [math]::Round((($valid | Measure-Object -Property Main -Average).Average) / 1000, 1)
      $maxMain = [math]::Round((($valid | Measure-Object -Property Main -Maximum).Maximum) / 1000, 1)
      $avgBoot = [math]::Round((($valid | Measure-Object -Property Boot -Average).Average) / 1000, 1)
      $avgPost = [math]::Round((($valid | Measure-Object -Property Post -Average).Average) / 1000, 1)
      Write-LogEntry "BootPerf: INFO - 최근 $($valid.Count)회: 바탕화면까지 평균 ${avgMain}s (최대 ${maxMain}s), 전체 평균 ${avgBoot}s (로그온 후 ${avgPost}s)"

      if ($avgMain -gt 45 -or $maxMain -gt 90) {
        Write-LogEntry "BootPerf: WARN - 부팅이 느림 (바탕화면까지 평균 ${avgMain}s)"
        $recommendations += "[BootPerf] 부팅 지연 — 시작 프로그램/서비스 축소, 빠른 시작(fast startup) 확인, 저장장치 펌웨어·칩셋 드라이버 업데이트"
      } else {
        Write-LogEntry "BootPerf: PASS - 부팅 시간 정상 범위 (바탕화면까지 평균 ${avgMain}s)"
      }
    }

    # 부팅을 지연시킨 상위 요인 (이벤트 101)
    $delayEvts = @(Get-WinEvent -LogName $perfLog -MaxEvents 300 -ErrorAction SilentlyContinue |
      Where-Object { $_.Id -eq 101 -and $_.TimeCreated -ge $perfCutoff })
    if ($delayEvts.Count -gt 0) {
      $delayMap = @{}
      foreach ($de in $delayEvts) {
        $dd = ConvertFrom-EventData $de
        $name = [string]$dd['Name']; if (-not $name) { $name = [string]$dd['FriendlyName'] }
        if (-not $name) { $name = '(unknown)' }
        $ms = 0; [void][int]::TryParse([string]$dd['TotalTime'], [ref]$ms)
        if ($delayMap.ContainsKey($name)) { $delayMap[$name].Sum += $ms; $delayMap[$name].Count++ }
        else { $delayMap[$name] = @{ Sum = $ms; Count = 1 } }
      }
      # 이벤트 101은 부팅 1회당 1건이므로 합계가 아니라 "부팅당 평균"으로 표기해야 의미가 있다
      $delayStr = (@($delayMap.GetEnumerator() | Sort-Object { $_.Value.Sum } -Descending | Select-Object -First 3 | ForEach-Object {
            $avg = [math]::Round($_.Value.Sum / $_.Value.Count / 1000, 1)
            "$($_.Key) ${avg}s($($_.Value.Count)회)"
          }) -join ', ')
      Write-LogEntry "BootPerf: INFO - 부팅 지연 상위(부팅당 평균): $delayStr"
    }

    # 비정상 종료 (Kernel-Power 41) — WHEA/전원 문제와 함께 봐야 하는 신호
    $unexpected = @(Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 41; StartTime = $perfCutoff} -ErrorAction SilentlyContinue)
    if ($unexpected.Count -gt 0) {
      Write-LogEntry "BootPerf: WARN - 비정상 종료(Kernel-Power 41) ${lookback}일 $($unexpected.Count)건"
      $recommendations += "[BootPerf] 비정상 종료 $($unexpected.Count)건 — 전원 공급/CMOS 배터리/메모리 안정성 점검 (WHEA 단계 결과와 함께 판단)"
    } else {
      Write-LogEntry "BootPerf: PASS - 비정상 종료 없음 (Kernel-Power 41, ${lookback}일)"
    }
  }
} catch {
  Write-LogEntry "BootPerf: SKIP - 성능 로그 확인 실패: $($_.Exception.Message)"
}

# --- Windows Update / 패치 상태 ---
Write-ProgressBar "Updates"
Write-TestHeader "[Updates] 대기 중인 업데이트와 패치/서명 최신 상태를 확인합니다."
# 실측(11-05): COM 검색 19.9s (대기 1건 = Defender 정의). 6일 1회 실행이면 충분히 감당 가능한 비용.
try {
  $swUpdate = [System.Diagnostics.Stopwatch]::StartNew()
  $pendingTitles = @()
  $updateSearchOk = $false
  $wuSession = $null

  # 자동 조치 1: wuauserv 가 Disabled 면 WU 검색/설치가 아예 불가능하다 → Manual 로 되돌린다(가역).
  #   (Stopped 는 정상: wuauserv 는 기본이 Manual + 트리거 시작이라 평소에 멈춰 있는 게 정상 상태다)
  try {
    $wuSvc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    if ($wuSvc -and $wuSvc.StartType -eq 'Disabled') {
      Set-Service -Name wuauserv -StartupType Manual -ErrorAction Stop
      Add-AutoFix 'Windows Update 서비스(wuauserv)가 Disabled 였음 → Manual 로 복구'
    }
  } catch {
    Write-LogEntry "Updates: WARN - wuauserv 시작 유형 복구 실패: $($_.Exception.Message)"
  }

  $wuSearch = {
    $s = New-Object -ComObject Microsoft.Update.Session
    $sr = $s.CreateUpdateSearcher()
    $sr.Online = $true
    $res = $sr.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    return @{ Session = $s; Result = $res }
  }
  try {
    $wu = & $wuSearch
    $wuSession = $wu.Session
    $wuResult = $wu.Result
    $updateSearchOk = $true
  } catch {
    $firstErr = $_.Exception.Message
    # 자동 조치 2: 관련 서비스가 멈춰 검색이 실패하는 경우가 흔하다 → 시작 후 1회만 재시도(가역).
    $startedSvc = @()
    foreach ($n in @('wuauserv', 'bits', 'cryptsvc')) {
      try {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Running') { Start-Service -Name $n -ErrorAction Stop; $startedSvc += $n }
      } catch { }
    }
    if ($startedSvc.Count -gt 0) {
      try {
        $wu = & $wuSearch
        $wuSession = $wu.Session
        $wuResult = $wu.Result
        $updateSearchOk = $true
        Add-AutoFix ("Windows Update 검색 실패 → {0} 시작 후 재검색 성공" -f ($startedSvc -join ', '))
      } catch { }
    }
    if (-not $updateSearchOk) {
      Write-LogEntry "Updates: SKIP - Windows Update 검색 실패: $firstErr"
      $recommendations += "[Updates] Windows Update 검색 실패 — $firstErr (서비스/방화벽/프록시 확인)"
    }
  }
  $searchSec = [math]::Round($swUpdate.Elapsed.TotalSeconds, 1)

  if ($updateSearchOk) {
    foreach ($u in $wuResult.Updates) { $pendingTitles += [string]$u.Title }
    # Defender 정의 업데이트는 하루에도 여러 번 나오므로 '보류 중'으로 취급하지 않는다
    $defenderPending = @($pendingTitles | Where-Object { $_ -match '(?i)defender|antivirus|antimalware|KB2267602' })
    $realPending = @($pendingTitles | Where-Object { $_ -notmatch '(?i)defender|antivirus|antimalware|KB2267602' })
    if ($realPending.Count -gt 0) {
      $preview = (@($realPending | Select-Object -First 3) -join ' | ')
      Write-LogEntry "Updates: WARN - 대기 중인 업데이트 $($realPending.Count)건 (${searchSec}s): $preview"
      $recommendations += "[Updates] Windows Update 대기 $($realPending.Count)건 — 설정 > Windows Update에서 설치 후 재부팅"

      # 자동 조치 3(옵션, 기본 꺼짐): 자동 설치. 재부팅이 필요한 업데이트는 사용자가 결정해야 하므로 기본값은 false.
      if (Get-Cfg 'autoInstallUpdates') {
        $rebootBlocked = (Test-PendingReboot).Pending
        if ($rebootBlocked) {
          Write-LogEntry 'Updates: INFO - 재부팅 대기 중이라 자동 설치를 건너뜁니다(autoInstallUpdates)'
        } else {
          try {
            $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in $wuResult.Updates) {
              if ($u.Title -match '(?i)defender|antivirus|antimalware|KB2267602') { continue }
              try { if (-not $u.EulaAccepted) { $u.AcceptEula() } } catch { }
              $null = $toInstall.Add($u)
            }
            if ($toInstall.Count -gt 0) {
              $dl = $wuSession.CreateUpdateDownloader(); $dl.Updates = $toInstall; $null = $dl.Download()
              $inst = $wuSession.CreateUpdateInstaller(); $inst.Updates = $toInstall
              $instRes = $inst.Install()
              $okCount = 0; $failCount = 0
              for ($i = 0; $i -lt $toInstall.Count; $i++) {
                if ($instRes.GetUpdateResult($i).ResultCode -eq 2) { $okCount++ } else { $failCount++ }
              }
              if ($okCount -gt 0) {
                Add-AutoFix ("Windows Update ${okCount}건 자동 설치 완료{0}" -f $(if ($instRes.RebootRequired) { ' — 재부팅 필요' } else { '' }))
              }
              if ($failCount -gt 0) {
                Write-LogEntry "Updates: WARN - 자동 설치 실패 ${failCount}건 (설치 성공 ${okCount}건)"
              }
            }
          } catch {
            Write-LogEntry "Updates: WARN - 자동 설치 실패: $($_.Exception.Message)"
          }
        }
      }
    } else {
      Write-LogEntry "Updates: PASS - 설치 대기 중인 일반 업데이트 없음 (Defender 정의 $($defenderPending.Count)건, ${searchSec}s)"
    }
  }

  # 마지막 누적 업데이트 설치일 (패치가 오래 끊긴 머신인지)
  try {
    $lastHf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } |
      Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($lastHf) {
      $hfDays = [int]((Get-Date) - $lastHf.InstalledOn).TotalDays
      if ($hfDays -gt 60) {
        Write-LogEntry "Updates: WARN - 마지막 패치가 ${hfDays}일 전 ($($lastHf.HotFixID))"
        $recommendations += "[Updates] 최근 누적 업데이트가 ${hfDays}일 전 — Windows Update로 패치 설치 권장"
      } else {
        Write-LogEntry "Updates: PASS - 마지막 패치 ${hfDays}일 전 ($($lastHf.HotFixID))"
      }
    }
  } catch { }

  # Defender 서명 나이
  $mpStatus = $null
  try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
    $sigAge = [int]$mpStatus.AntivirusSignatureAge
    if ($sigAge -gt 3) {
      Write-LogEntry "Updates: WARN - Defender 서명이 ${sigAge}일 지남 (버전 $($mpStatus.AntivirusSignatureVersion))"
      # 자동 조치(가역/안전): 서명만 갱신한다. 플랫폼/엔진 업데이트나 전체 검사는 자동화하지 않는다.
      $sigFixed = $false
      try {
        $null = Update-MpSignature -ErrorAction Stop
        $mpNew = Get-MpComputerStatus -ErrorAction Stop
        $newAge = [int]$mpNew.AntivirusSignatureAge
        if ($newAge -lt $sigAge) {
          $sigFixed = $true
          Add-AutoFix "Defender 서명 ${sigAge}일 → ${newAge}일 자동 갱신 (버전 $($mpNew.AntivirusSignatureVersion))"
        }
      } catch {
        Write-LogEntry "Updates: WARN - Defender 서명 자동 갱신 실패: $($_.Exception.Message)"
      }
      if (-not $sigFixed) {
        $recommendations += '[Updates] Defender 서명 오래됨 — Update-MpSignature 실행 또는 Windows Update 확인'
      }
    } else {
      Write-LogEntry "Updates: PASS - Defender 서명 ${sigAge}일 (버전 $($mpStatus.AntivirusSignatureVersion))"
    }
  } catch { }

  # Defender 실시간 보호 (꺼져 있으면 감염 위험이 즉시 커진다)
  try {
    $mpProt = if ($mpStatus) { $mpStatus } else { Get-MpComputerStatus -ErrorAction Stop }
    $protOff = @()
    if (-not $mpProt.RealTimeProtectionEnabled) { $protOff += 'RealTimeProtection' }
    if (-not $mpProt.AntivirusEnabled) { $protOff += 'Antivirus' }
    if (-not $mpProt.BehaviorMonitorEnabled) { $protOff += 'BehaviorMonitor' }
    if ($protOff.Count -gt 0) {
      Write-LogEntry "Updates: WARN - Defender 보호 기능 꺼짐: $($protOff -join ', ')"
      # 자동 조치(가역): 꺼진 보호 기능을 다시 켠다. 변조 방지(Tamper Protection)가 켜져 있으면 실패할 수 있다.
      $protFixed = $false
      try {
        if ($protOff -contains 'RealTimeProtection') { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop }
        if ($protOff -contains 'BehaviorMonitor') { Set-MpPreference -DisableBehaviorMonitoring $false -ErrorAction Stop }
        if ($protOff -contains 'Antivirus') { Set-MpPreference -DisableAntivirusProtection $false -ErrorAction Stop }
        $svcDef = Get-Service WinDefend -ErrorAction SilentlyContinue
        if ($svcDef -and $svcDef.Status -ne 'Running') {
          Start-Service WinDefend -ErrorAction Stop
          (Get-Service WinDefend).WaitForStatus('Running', '00:00:20')
        }
        Start-Sleep -Seconds 2
        $mpAfter = Get-MpComputerStatus -ErrorAction Stop
        if ($mpAfter.RealTimeProtectionEnabled -and $mpAfter.AntivirusEnabled) {
          $protFixed = $true
          Add-AutoFix "Defender 보호 기능 재활성화 ($($protOff -join ', '))"
        }
      } catch {
        Write-LogEntry "Updates: WARN - Defender 보호 기능 재활성화 실패: $($_.Exception.Message)"
      }
      if (-not $protFixed) {
        $recommendations += "[Updates] Defender 보호 기능이 꺼져 있습니다($($protOff -join ', ')) — Windows 보안 앱에서 켜거나 변조 방지 설정을 확인하세요."
      }
    } else {
      Write-LogEntry 'Updates: PASS - Defender 실시간 보호 켜짐'
    }
  } catch {
    Write-LogEntry "Updates: SKIP - Defender 보호 상태 확인 실패 ($($_.Exception.Message))"
  }

  # 재부팅 대기 상태 (업데이트가 설치되지 않는 흔한 원인)
  #   2026-11-15: REBOOT 검사와 같은 함수로 판정(같은 실행에서 서로 다른 답이 나오던 문제).
  $pendingRebootInfo = Test-PendingReboot
  if ($pendingRebootInfo.Pending) {
    Write-LogEntry ("Updates: WARN - 재부팅 대기 중 (보류 중인 업데이트/파일 교체 있음: {0})" -f $pendingRebootInfo.Reasons)
    $recommendations += "[Updates] 재부팅 대기 상태($($pendingRebootInfo.Reasons)) — 재부팅 후 업데이트가 마무리됨"
  } else {
    Write-LogEntry 'Updates: PASS - 재부팅 대기 없음'
  }
} catch {
  Write-LogEntry "Updates: SKIP - 확인 실패: $($_.Exception.Message)"
}

# --- 자동 치유: 이벤트 뷰어 점검 + 자동 복구 ---
Write-ProgressBar "Auto-Heal"
Write-TestHeader "[Auto-Heal] 이벤트 뷰어 로그를 분석하고 자동 복구를 시도합니다."
try {
  $evtCutoff = (Get-Date).AddDays(-[int](Get-Cfg 'eventLookbackDays'))
  $healActions = @(
    # ===== 하드웨어 =====
    @{ Label='비정상 종료/전원'; Log='System'; Id=41; Level=1; CanAutoFix=$false; Fix={ $false }
      Help='전원 공급 장치/케이블 점검, CPU/메모리 안정성 테스트(Prime95/MemTest86), 드라이버 업데이트' }
    @{ Label='디스크/볼륨 오류'; Log='System'; Id=7,134,137,148; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='chkdsk /f 실행, 디스크 백업 후 배드 섹터 검사, S.M.A.R.T. 상태 확인(DiskHealth 섹션 참고), 케이블 재연결' }
    @{ Label='WHEA 교정된 하드웨어 오류'; Log='System'; Id=3,47,48; Level=4; ProviderName='Microsoft-Windows-WHEA-Logger'; CanAutoFix=$false; Fix={ $false }
      Help='정보 수준(교정됨) 오류 — 원시 데이터(Byte[] ASCII)의 STORPORT/storahci/nvme/PCIe 토큰과 장치명을 확인. STORPORT 흔적이면 SSD/HDD·케이블·포트 점검, PCIe 흔적이면 슬롯 재장착' }
    @{ Label='WHEA 하드웨어 오류'; Log='System'; Id=17,18,19,20,21,46; Level=2; ProviderName='Microsoft-Windows-WHEA-Logger'; CanAutoFix=$false; Fix={ $false }
      Help='오류 수준 WHEA — 원시 데이터의 ErrorSource 확인. CPU/메모리 오버클럭 해제, 온도/전압 확인, BIOS 기본값 복원, 드라이버 업데이트 (저장장치 토큰이 있으면 SSD/케이블 우선)' }
    @{ Label='USB 오류'; Log='System'; Id=41,42,43,44; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='USB 장치 분리 후 재연결, USB 컨트롤러 드라이버 재설치, USB 선택적 일시 중단 설정 해제(전원 관리)' }
    @{ Label='메모리 오류'; Log='System'; Id=51,52,53; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='MemTest86 실행, RAM 슬롯 재장착, XMP/DOCP 프로필 비활성화, BIOS 업데이트' }
    @{ Label='PCIe 오류'; Log='System'; Id=17,18; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='PCIe 장치 분리 후 재연결, BIOS PCIe 설정 기본값 복원, GPU/SSD 재장착' }

    # ===== DCOM/COM =====
    @{ Label='DCOM 권한 오류'; Log='System'; Id=10001,10010,10016; Level=3; CanAutoFix=$false; Fix={ $false }
      Help='이벤트 ID 10016 검색 → 알려진 해결법 확인(dcomcnfg), 또는 해당 COM 서버 재등록(regsvr32)' }
    @{ Label='DCOM 서버 시작 실패'; Log='System'; Id=10005,10008,10009; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='"실행 중 아님" DCOM 서버가 설치되지 않았거나 손상됨 — 관련 프로그램 재설치, Windows 기능 켜기/끄기 확인' }
    @{ Label='COM+ 이벤트 오류'; Log='System'; Id=4199,4200,4201; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='COM+ 응용 프로그램 재설치, Microsoft Visual C++ 재배포 가능 패키지 업데이트, Windows 업데이트 확인' }
    @{ Label='AAD BrokerPlugin DCOM 시간 초과'; Log='System'; Id=10010; Level=2; ProviderName='Microsoft-Windows-DistributedCOM'; Fix={
      try {
        $pkg = Get-AppxPackage -Name 'Microsoft.AAD.BrokerPlugin' -AllUsers -ErrorAction SilentlyContinue
        if ($pkg) {
          $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
          Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
        }
        $pkg2 = Get-AppxPackage -Name 'Microsoft.Windows.Security.Authentication.Web.Core' -AllUsers -ErrorAction SilentlyContinue
        if ($pkg2) {
          $manifest2 = Join-Path $pkg2.InstallLocation 'AppxManifest.xml'
          Add-AppxPackage -DisableDevelopmentMode -Register $manifest2 -ErrorAction SilentlyContinue
        }
        $true
      } catch { throw "$($_.Exception.Message)" }
    }; Help='AAD BrokerPlugin 패키지 재등록. Microsoft 계정 인증 백그라운드 태스크 타임아웃 해결' }

    # ===== 서비스 =====
    @{ Label='서비스 중단/타임아웃'; Log='System'; Id=7000,7009,7023,7031,7032,7034; Level=2; Fix={
      $errs = @()
      foreach ($svcName in $servicesToCheck) {
        try { $null = sc.exe failure $svcName reset=86400 actions=restart/10000/restart/30000//60000 2>&1 } catch { $errs += "$svcName`: $($_.Exception.Message)" }
      }
      if ($errs.Count -gt 0) { throw ($errs -join '; ') }
      $true
    }; Help='서비스 복구 옵션 자동 설정(10s/30s 후 재시작). 특정 서비스가 계속 중단되면 해당 서비스의 의존성 확인(dependency)' }
    @{ Label='서비스 시작 실패'; Log='System'; Id=7001,7040,7043,7045; Level=2; Fix={
      try { $null = sc.exe failure $($servicesToCheck -join ' ') reset=86400 actions=restart/20000 2>&1; $true } catch { throw "$($_.Exception.Message)" }
    }; Help='서비스 시작 실패 — 해당 서비스의 계정 권한(로그온 계정) 및 의존성 확인, 시스템 복원 지점 사용' }
    @{ Label='대화형 서비스 경고'; Log='System'; Id=7030; Level=3; CanAutoFix=$false; Fix={ $false }
      Help='서비스 Type에 대화형 플래그(0x100)가 남아 있음 — SysFix 섹션에서 인박스(Spooler/PrintNotify)를 제외한 3rd 파티 서비스를 자동으로 type= own(0x10)으로 정리합니다' }
    @{ Label='WinRM/PSRemoting'; Log='System'; Id=10126,10127; Level=2; Fix={
      try { $null = winrm quickconfig -quiet 2>&1; $true } catch { throw "$($_.Exception.Message)" }
    }; Help='WinRM 서비스 및 방화벽 예외 규칙 자동 구성. 원격 관리를 사용하지 않으면 무시 가능' }

    # ===== Windows Update =====
    # catroot2/SoftwareDistribution 자동 삭제는 WU 서명 저장소를 깨뜨릴 수 있어 자동 실행하지 않는다(권장사항만 기록)
    @{ Label='Windows Update 오류'; Log='System'; Id=20,21,24,25,43,44,45,46; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='Windows Update 문제 해결사 실행 또는 수동: net stop wuauserv/bits/cryptsvc → SoftwareDistribution\Download만 삭제 → 재시작. catroot2 삭제는 서명 저장소 손상 위험이 있어 자동화하지 않음' }
    @{ Label='Update Orchestrator'; Log='System'; Id=28,30,32; Level=2; Fix={
      try { $null = usoclient start 2>&1; $true } catch { throw "$($_.Exception.Message)" }
    }; Help='Update Orchestrator(USOClient)로 업데이트 검색 재시작. Windows Update 문제 해결사 실행 권장' }

    # ===== 네트워크 =====
    @{ Label='DNS 클라이언트 오류'; Log='System'; Id=1014,1015,1016; Level=2; Fix={
      try { $null = ipconfig /flushdns 2>&1; $null = ipconfig /registerdns 2>&1; $true } catch { throw "$($_.Exception.Message)" }
    }; Help='DNS 캐시 플러시 + 등록. DNS 서버를 8.8.8.8/1.1.1.1로 변경 또는 router 재시작' }
    # ipconfig /release 는 실제로 연결을 끊는다(원격 세션/다운로드 중 위험) → 권고만
    @{ Label='DHCP/IP 주소 충돌'; Log='System'; Id=1001,1002,1003,1004; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='수동: ipconfig /release → /renew → /flushdns. 반복되면 공유기 DHCP 범위 또는 고정 IP 충돌 확인 (자동 실행 시 네트워크가 일시 끊김)' }
    # netsh int ip reset / winsock reset 은 재부팅이 필요하고 VPN·고정IP·방화벽 설정을 초기화한다 → 자동 실행 금지
    @{ Label='네트워크 어댑터 리셋'; Log='System'; Id=1001,1003,5005,5007; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='네트워크 스택 초기화는 수동으로: netsh int ip reset → netsh winsock reset → 재부팅. (자동 실행 시 VPN/고정IP/방화벽 규칙이 초기화되고 네트워크가 끊김)' }
    @{ Label='Teredo/IPv6'; Log='System'; Id=1001,1002; Level=3; Fix={
      try { $null = netsh interface Teredo set state type=default 2>&1; $true } catch { throw "$($_.Exception.Message)" }
    }; Help='Teredo 터널 어댑터 초기화. Xbox/게임 연결 문제 시 Microsoft Teredo 문제 해결사 실행' }
    # 실측(11-05): WLAN-AutoConfig 10003 33건 + WLANExt.exe 크래시 19건 = Intel 드라이버(IntelIHVRouter10.dll) 문제.
    # WlanSvc 재시작으로는 고쳐지지 않고, 재시작할 때마다 Wi-Fi 메트릭이 35로 되돌아가 우선순위 설정과 충돌한다.
    @{ Label='Wi-Fi 어댑터 오류'; Log='System'; Id=10001,10002,10003; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='WLAN 드라이버(Intel Wi-Fi) 업데이트 또는 재설치. 이벤트 10003의 "오류 모듈: IntelIHVRouter10.dll"은 드라이버 핫스팟 구성요소 문제 — Intel 공식 드라이버로 교체 후 재확인' }

    # ===== 시간 동기화 =====
    # 실측: 이 이벤트는 전부 "부팅 직후 1~2초"에 발생한다(네트워크/DNS 준비 전 NTP 조회 실패). 실제 동기화는 정상.
    #   → 피어 재설정/w32tm 재등록을 자동 실행하면 오히려 시계가 흔들리고 매 실행 반복된다.
    @{ Label='시간 동기화 오류'; Log='System'; Id=34,36,38,50; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='부팅 직후 이벤트(134/135)는 네트워크 준비 전 NTP 조회 실패로 정상이며 무시 가능. 실제 오프셋은 TimeSync 단계에서 확인. 수동 조정: w32tm /resync (온라인 상태에서)' }

    # ===== 인쇄 =====
    @{ Label='프린트 스풀러 오류'; Log='System'; Id=808,810,1003; Level=2; Fix={
      try {
        Stop-Service Spooler -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:windir\System32\spool\PRINTERS\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service Spooler -ErrorAction SilentlyContinue
        $true
      } catch { throw "$($_.Exception.Message)" }
    }; Help='프린트 스풀러 재시작 + 대기 문서 삭제. 프린터 드라이버 재설치 및 최신 업데이트 확인' }

    # ===== Windows Search =====
    @{ Label='Windows 검색 오류'; Log='System'; Id=1001,1004,3001; Level=2; Fix={
      try { $null = net stop WSearch 2>&1; $null = net start WSearch 2>&1; $true } catch { throw "$($_.Exception.Message)" }
    }; Help='Windows Search 서비스 재시작. 검색 인덱스 재구축(설정 > 검색 > 검색 인덱스 고급 옵션 > 다시 빌드)' }

    # ===== 방화벽/보안 =====
    @{ Label='Windows 방화벽 오류'; Log='System'; Id=2002,2004,2006; Level=2; Fix={
      try { $null = net stop MpsSvc 2>&1; $null = net start MpsSvc 2>&1; $true } catch { throw "$($_.Exception.Message)" }
    }; Help='방화벽 서비스(MpsSvc) 재시작. 방화벽 설정 초기화: netsh advfirewall reset' }
    # Defender는 매일 빠른 검사를 자체 스케줄로 수행하므로 여기서 또 돌리지 않는다
    @{ Label='Windows Defender 오류'; Log='System'; Id=3002,3004,3006; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='Get-MpComputerStatus 로 서비스/서명 상태 확인 후 Start-MpScan -ScanType QuickScan 수동 실행. 반복되면 Defender 복구(설정 > Windows 보안 > 문제 해결)' }
    @{ Label='BitLocker 오류'; Log='System'; Id=24577,24578,24586; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='BitLocker 일시 중단 후 다시 활성화: manage-bde -protectors -disable C: -RebootCount 1 후 재부팅' }
    @{ Label='UAC/보안 정책'; Log='System'; Id=5038,5059,5061; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='코드 무결성 검사 실패 — 드라이버 서명 확인, 최신 Windows 업데이트 적용, 서명되지 않은 드라이버 업데이트' }

    # ===== WMI/성능 =====
    @{ Label='WMI 오류'; Log='System'; Id=10,11,28,29; Level=2; Fix={
      try {
        $null = net stop Winmgmt 2>&1
        $null = winmgmt /resyncperf 2>&1
        $null = net start Winmgmt 2>&1
        $true
      } catch { throw "$($_.Exception.Message)" }
    }; Help='WMI 서비스 재시작 + 성능 카운터 재동기화. winmgmt /verifyrepository로 저장소 무결성 확인' }
    @{ Label='성능 카운터 오류'; Log='System'; Id=1001,1003,1008; Level=2; Fix={
      try { $null = lodctr /R 2>&1; $null = lodctr /E:PerfProc 2>&1; $true } catch { throw "$($_.Exception.Message)" }
    }; Help='성능 카운터 재빌드(lodctr /R). perfts.dll 문제 해결. 관리자 PowerShell에서 rundll32.exe advapi32.dll,ProcessIdleTasks' }

    # ===== 앱/런타임 =====
    # wsreset 은 스토어 캐시만 초기화하며 일반 앱 크래시(WLANExt.exe, GameBar.exe 등)의 원인을 고치지 못한다
    @{ Label='앱 충돌/중단'; Log='Application'; Id=1000,1001,1002; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='이벤트 상세의 "오류 모듈"을 확인해 해당 앱/드라이버를 업데이트·재설치. wsreset.exe는 스토어 캐시 문제에만 유효' }
    # sfc/DISM 을 Auto-Heal 안에서 다시 돌리면 SFC 단계와 중복되고 10분 이상 추가 소요된다 → 권고만
    @{ Label='.NET Runtime 오류'; Log='Application'; Id=1023,1024,1025,1026; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='앱별 .NET 예외이므로 해당 앱 업데이트/재설치가 우선. 시스템 파일 손상이 의심될 때만 관리자 PowerShell에서 sfc /scannow + DISM /Online /Cleanup-Image /RestoreHealth (SFC 단계에서 30일마다 자동 수행)' }
    @{ Label='SideBySide 오류'; Log='Application'; Id=32,33,34,35,36,37,38,39; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='Visual C++ 재배포 가능 패키지 누락/손상 — Microsoft Visual C++ 재배포 가능 패키지 최신 버전 설치(all-in-one)' }
    @{ Label='Windows 스토어 오류'; Log='Application'; Id=115,116,117,118; Level=2; Fix={
      try { $null = Get-AppXPackage -AllUsers -Name '*store*' | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue }; $true } catch { throw "$($_.Exception.Message)" }
    }; Help='스토어 앱 재등록 시도. wsreset.exe 실행, Windows 스토어 앱 문제 해결사 실행' }
    @{ Label='SearchIndexer 충돌'; Log='Application'; Id=1000,1001,3103; Level=2; Fix={
      try { $null = net stop WSearch 2>&1; $null = net start WSearch 2>&1; $true } catch { throw "$($_.Exception.Message)" }
    }; Help='검색 인덱서 재시작. 인덱스 위치 확인: searchindexer.exe /Rebuild (관리자)' }
    @{ Label='Office Web Add-in 매니페스트 오류(Forms)'; Log='OAlerts'; Id=300; Level=2; Fix={
      try {
        $guid = '65ff8bd9-e8d3-4581-a27a-75840c41de94'
        $opc = 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\Opc'
        $null = New-Item "$opc\BlockedApps" -Force -ErrorAction SilentlyContinue
        $null = New-Item "$opc\DisabledItems" -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "$opc\BlockedApps" -Name $guid -Value 1 -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path "$opc\DisabledItems" -Name $guid -Value 1 -Type DWord -ErrorAction Stop
        $true
      } catch { throw "$($_.Exception.Message)" }
    }; Help='Microsoft Forms 추가 기능 GUID를 BlockedApps/DisabledItems에 등록하여 매니페스트 파싱 차단. Office 캐시 초기화(ClickToRunSvc 재시작) 후 효과' }

    # ===== 시스템 구성요소 =====
    @{ Label='VSS 섀도 복사 오류'; Log='System'; Id=8193,12290,12291; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='시스템 복원 지점 생성 실패 (8193 + 0x80070422 = System Restore/작업 스케줄러 비활성) — SysFix 섹션이 복원 활성화·SR 예약 작업·섀도 저장소 확장을 자동 처리합니다. 그래도 실패하면 vssadmin list writers로 작성자 확인. RAM 디스크(Z:)의 FAT32 볼륨은 VSS 미지원으로 이 오류는 정상' }
    @{ Label='DLL 등록 오류'; Log='System'; Id=1001,1020; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='대부분 앱 설치/제거 잔재. 문제 DLL을 이벤트 상세에서 확인 후 해당 앱 재설치. 시스템 파일 검사는 SFC 단계(30일 주기)에서 수행' }
    @{ Label='이벤트 로그 손상'; Log='System'; Id=455,456; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='이벤트 로그 파일 확인 — wevtutil al System(백업) 후 wevtutil cl System(초기화)로 복구 가능. 로그 파일 최대 크기 증가(SysFix 섹션에서 System/Application/Security를 64MB로 자동 확장): wevtutil sl System /ms:67108864' }
    @{ Label='레지스트리 오류'; Log='System'; Id=1,2,3; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='레지스트리 손상 가능성 — 시스템 복원, sfc /scannow, 최후 수단으로 Windows 초기화 또는 in-place 업그레이드' }
    @{ Label='Winlogon/사용자 프로필'; Log='System'; Id=1500,1502,1508,1511; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='사용자 프로필 손상 — 새 사용자 계정 생성 후 데이터 마이그레이션, 시스템 복원' }
    @{ Label='TPM/보안 부팅'; Log='System'; Id=1,2,7,14; ProviderName='TPM'; Level=2; CanAutoFix=$false; Fix={ $false }
      Help='TPM 초기화(TPM.msc → "TPM 지우기"), BIOS에서 TPM/보안 부팅 설정 확인, BitLocker 일시 중단 후 재부팅' }
    @{ Label='VBScript 사용 중단 경고'; Log='Application'; Id=4096; ProviderName='VBScriptDeprecationAlert'; Level=4; CanAutoFix=$false; Fix={ $false }
      Help='PatchCleaner 등 VBScript 사용 프로그램을 PowerShell로 대체. 수동 조치: Remove-Item (Join-Path "C:\Program Files (x86)\HomeDev\PatchCleaner\AppData" "WMIProducts.vbs") 후 PowerShell 동등 스크립트 생성' }
    @{ Label='SBAT 업데이트 실패'; Log='System'; Id=1796; ProviderName='Microsoft-Windows-TPM-WMI'; Level=2; Fix={
      try {
        Start-ScheduledTask -TaskPath '\Microsoft\Windows\TPM\' -TaskName 'Tpm-HASCertRetr' -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskPath '\Microsoft\Windows\TPM\' -TaskName 'Tpm-PreAttestationHealthCheck' -ErrorAction SilentlyContinue
        $null = New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot" -Name "SecureBootUpdate" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue
        Restart-Service TpmSvc -Force -ErrorAction SilentlyContinue
        $true
      } catch { throw "$($_.Exception.Message)" }
    }; Help='AMD fTPM 시스템에서 자주 발생하는 경고로, 펌웨어가 SBAT를 지원하지 않으면 항상 실패함. BIOS/TPM 업데이트 또는 무시' }

    # ===== 블루투스 =====
    @{ Label='블루투스 오류'; Log='System'; Id=1001,1002,1003; ProviderName='BTHUSB'; Level=2; Fix={
      try { Get-Service BthServ,BthAvctpSvc,BluetoothUserService* -ErrorAction SilentlyContinue | Restart-Service -Force -ErrorAction SilentlyContinue; $true } catch { throw "$($_.Exception.Message)" }
    }; Help='블루투스 서비스 재시도. 장치 관리자에서 블루투스 어댑터 사용 안 함 → 사용으로 전환. 드라이버 재설치' }
  )

  $issuesFound = $false
  $skippedHandled = 0
  $healStatePath = Join-Path $scriptRoot 'autoheal-state.json'
  $healState = Get-JsonState $healStatePath
  $healSave = @{}
  foreach ($ha in $healActions) {
    $ht = @{LogName=$ha.Log; Id=$ha.Id; Level=$ha.Level; StartTime=$evtCutoff}
    if ($ha.ContainsKey('ProviderName')) { $ht.ProviderName = $ha.ProviderName }
    $evts = try { Get-WinEvent -FilterHashtable $ht -ErrorAction SilentlyContinue } catch { @() }
    $cnt = @($evts).Count
    if ($cnt -eq 0) { continue }

    # 이미 처리한 이벤트만 남아 있으면 건너뛴다.
    #   기존 동작: 7일 조회창 안의 이벤트를 매 실행마다 다시 "수리"해서
    #   같은 서비스 재시작/네트워크 초기화가 6일마다 무한 반복됐다(네트워크 메트릭 35→1 churn의 원인).
    #   이벤트 RecordId는 증가만 하므로 "마지막으로 처리한 RecordId 이하"는 재처리 대상이 아니다.
    $newest = $evts | Sort-Object RecordId -Descending | Select-Object -First 1
    $newestId = if ($newest) { [long]$newest.RecordId } else { 0 }
    $prevId = $null
    if ($healState.ContainsKey($ha.Label)) {
      $pv = $healState[$ha.Label]
      try { $prevId = [long]$pv } catch { $prevId = $null }
    }
    if ($null -ne $prevId -and $newestId -le $prevId) {
      $skippedHandled++
      continue
    }

    $issuesFound = $true
    $canFix = if ($ha.ContainsKey('CanAutoFix')) { $ha.CanAutoFix } else { $true }
    if (-not $canFix) {
      try { Add-Content -Path $logPath -Value "AutoHeal: INFO - $($ha.Label) $($cnt)건 — $($ha.Help)" -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
      $healSave[$ha.Label] = $newestId
      continue
    }
    try {
      $fixOk = & $ha.Fix
      if ($fixOk -eq $true) {
        Write-LogEntry "AutoHeal: PASS - $($ha.Label) $($cnt)건 자동 복구 완료"
        Add-AutoFix "Auto-Heal: $($ha.Label) ${cnt}건 자동 복구"
      } else {
        Write-LogEntry "AutoHeal: WARN - $($ha.Label) $($cnt)건 자동 복구 불가 (알 수 없는 오류)"
        Write-Host "  → 권장: $($ha.Help)"
        $failureReasons += "[AutoHeal] $($ha.Label) 자동 복구 실패"
        $recommendations += "[AutoHeal] $($ha.Label) — $($ha.Help)"
      }
    } catch {
      Write-LogEntry "AutoHeal: WARN - $($ha.Label) $($cnt)건 자동 복구 불가 ($($_.Exception.Message))"
      Write-Host "  → 권장: $($ha.Help)"
      $failureReasons += "[AutoHeal] $($ha.Label) 자동 복구 실패: $($_.Exception.Message)"
      $recommendations += "[AutoHeal] $($ha.Label) — $($ha.Help)"
    }
    $healSave[$ha.Label] = $newestId
  }
  # 상태 병합 저장(이번에 이벤트가 없던 항목은 기존 RecordId 유지)
  foreach ($k in $healState.Keys) {
    if (-not $healSave.ContainsKey($k)) {
      try { $healSave[$k] = [long]$healState[$k] } catch { }
    }
  }
  Save-JsonState $healStatePath $healSave

  if ($skippedHandled -gt 0) {
    # 주의: "$skippedHandled건" 으로 쓰면 PowerShell 이 변수명을 'skippedHandled건' 으로 해석해
    #       StrictMode 에러가 난다(한글은 변수명에 포함 가능). 반드시 ${} 로 감싼다.
    Write-LogEntry "AutoHeal: SKIP - 이미 처리한 이벤트 ${skippedHandled}건 (재수리 안 함)"
  }
  if (-not $issuesFound) {
    Write-LogEntry 'AutoHeal: INFO - 이벤트 뷰어 조회창 내 미처리 이벤트 없음'
  }

  # 기존 로그 기반 치유
  $healLog = Get-LatestLog
  if ($healLog) {
    $healContent = Get-Content -LiteralPath $healLog -Raw -ErrorAction SilentlyContinue
    if ($healContent -match '(?i)Windows Update .*winget.*failed') { Update-ConfigWingetDisabled; Write-LogEntry 'AutoHeal: CHANGE - winget 자동 업데이트 비활성화 완료' }
  }
  Ensure-PSWindowsUpdateModule
  # Hide-ProblematicDriverUpdates 호출 제거(2026-11-05):
  #   - 'Chipset/Firmware/BIOS' 키워드로 드라이버 업데이트를 숨겨, 실제로 필요한 칩셋/Wi-Fi 수정을 차단할 수 있음
  #   - Get-WindowsUpdate 는 네트워크 조회로 30~120초 소요(Auto-Heal 소요시간의 큰 부분)

  # (Auto-Heal은 더 이상 네트워크 서비스를 재시작하지 않으므로 메트릭 재적용도 불필요)
} catch {
  Write-LogEntry "AutoHeal: FAIL - $($_.Exception.Message)"
  $failureReasons += "[AutoHeal] 자동 복구 실패: $($_.Exception.Message)"
}

# --- 오래된 드라이버 정리 (2026-11-19, v1.13.0) ---
#   새 버전이 이미 저장소에 설치되었는데 이전 버전이 남은 것만 후보다.
#   사용 중/부팅 필수/보호 클래스는 감지 단계에서 제외한다.
#   삭제는 oldDriverCleanup=true 이고 **사람이 보는 창에서 y 를 눌렀을 때만** 한다.
#   주기는 가장 긴 30일(oldDriverCheckDays) — 드라이버 목록은 거의 안 바뀌므로 6일마다 볼 필요가 없다.
Write-ProgressBar 'OldDrivers'
$script:oldDriverStatus = $null
$oldDriverCheckDays = [int](Get-Cfg 'oldDriverCheckDays')
$oldDriverFlag = Join-Path $scriptRoot '.last_olddrivers'
$lastOldDrivers = Get-StampDate $oldDriverFlag
if (-not (Test-DueByDays $lastOldDrivers $oldDriverCheckDays)) {
  Write-LogEntry ("OldDrivers: SKIP - gated ({0}d interval, last {1})" -f $oldDriverCheckDays, $lastOldDrivers.ToString('yyyy-MM-dd'))
} else {
  # 시도한 번이면 스탬프를 찍는다 — 조회가 실패해도 30일 뒤에 다시 시도(매 실행 재시도 방지).
  Set-StampDate $oldDriverFlag
  $oldDrivers = @()
  $oldDriverErr = ''
try {
  $installedDrivers = @(Get-WindowsDriver -Online -ErrorAction Stop)
  $inUseInf = @{}
  $deviceNames = @{}
  try {
    foreach ($w in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue)) {
      $infName = [string]$w.InfName
      if ([string]::IsNullOrWhiteSpace($infName)) { continue }
      $inUseInf[$infName] = $true
      # oemNN.inf 만 보여주면 무엇을 담당하는 드라이버인지 알 수 없으므로 장치 이름도 같이 모은다.
      $devName = [string]$w.DeviceName
      if ([string]::IsNullOrWhiteSpace($devName)) { $devName = [string]$w.Description }
      if (-not [string]::IsNullOrWhiteSpace($devName)) {
        $dk = $infName.ToLowerInvariant()
        if (-not $deviceNames.ContainsKey($dk)) { $deviceNames[$dk] = @() }
        if ($devName -notin $deviceNames[$dk]) { $deviceNames[$dk] += $devName }
      }
    }
  } catch { }
  $oldDrivers = @(Get-OldDriverCandidatesFrom -Drivers $installedDrivers -InUseInf $inUseInf -DeviceNames $deviceNames)
} catch {
  $oldDriverErr = $_.Exception.Message
}

$script:oldDriverStatus = [pscustomobject]@{
  Candidates = @($oldDrivers)
  Deleted    = 0
  Skipped    = 0
  Asked      = $false
  Approved   = $false
  Error      = $oldDriverErr
}

if ($oldDriverErr) {
  Write-LogEntry "OldDrivers: WARN - 드라이버 목록을 읽지 못했습니다: $oldDriverErr"
} elseif ($oldDrivers.Count -eq 0) {
  Write-LogEntry 'OldDrivers: PASS - 새 버전이 설치된 이전 드라이버 없음'
} else {
  Write-TestHeader ((L '[오래된 드라이버] 새 버전이 있음에도 남아 있는 이전 드라이버 {0}개' '[Old drivers] {0} older package(s) remain despite a newer version') -f $oldDrivers.Count)
  foreach ($od in $oldDrivers) {
    $devLabel = if ($od.Device) { (L ' [장치: {0}]' ' [device: {0}]') -f $od.Device } else { '' }
    $line = (L '  · {0} — {1} / {2} / {3} {4}{7} → 최신 {5} ({6})' '  · {0} - {1} / {2} / {3} {4}{7} -> newer {5} ({6})') -f $od.Inf, $od.Provider, $od.Class, $od.File, $od.Version, $od.NewestVersion, $od.NewestInf, $devLabel
    if ($od.Reason) { $line += (L '  [보류: {0}]' '  [skipped: {0}]') -f $od.Reason }
    Write-TestHeader $line
  }

  $canAskOldDriver = ($Mode -ne 'scheduled' -and $Mode -ne 'idle' -and [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected)
  $approvedOldDriver = $false
  if ((Get-Cfg 'oldDriverCleanup') -and $canAskOldDriver) {
    try {
      $script:oldDriverStatus.Asked = $true
      $ansOldDriver = Read-Host (L '위 오래된 드라이버를 삭제하시겠습니까? (y = 삭제 / n 또는 Enter = 그대로 두기)' 'Delete the older driver packages above? (y = delete / n or Enter = keep)')
      if ("$ansOldDriver" -match '^\s*(y|yes|예|ㅇ|1)\s*$') { $approvedOldDriver = $true }
    } catch { }
  }
  $script:oldDriverStatus.Approved = $approvedOldDriver

  foreach ($od in $oldDrivers) {
    if (-not $approvedOldDriver) {
      $why = if (-not (Get-Cfg 'oldDriverCleanup')) { L '설정에서 꺼져 있음 (oldDriverCleanup=false)' 'Disabled in config (oldDriverCleanup=false)' }
             elseif (-not $canAskOldDriver) { L '예약 실행이라 확인을 받을 수 없어 보류' 'Scheduled run - no user available to confirm' }
             else { L '삭제하지 않음 (사용자가 y 를 누르지 않음)' 'Not deleted (user did not answer y)' }
      $od.Reason = if ($od.Reason) { $od.Reason + ' / ' + $why } else { $why }
      $script:oldDriverStatus.Skipped++
      continue
    }
    if ($od.Reason) { $script:oldDriverStatus.Skipped++; continue }
    try {
      # INF 이름은 ^oem\d+\.inf$ 로 엄격 검증됐으므로 인자 주입 여지가 없다. /uninstall 은 쓰지 않는다(장치에 설치된 드라이버를 건드리지 않기 위함).
      $pnputilOut = @(& "$env:SystemRoot\System32\pnputil.exe" /delete-driver $od.Inf 2>&1)
      $pnputilCode = $LASTEXITCODE
      if ($pnputilCode -eq 0) {
        $od.Deleted = $true
        $script:oldDriverStatus.Deleted++
        Add-AutoFix ((L '오래된 드라이버 삭제: {0} ({1} {2} → 최신 {3})' 'Deleted old driver: {0} ({1} {2} -> newer {3})') -f $od.Inf, $od.Provider, $od.Version, $od.NewestVersion)
        Write-LogEntry "OldDrivers: CHANGE - 삭제 $($od.Inf) ($($od.Version) -> $($od.NewestVersion))"
      } else {
        $detail = @($pnputilOut | ForEach-Object { [string]$_ } | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
        $msg = if ($detail.Count -gt 0) { [string]$detail[0] } else { "pnputil exit=$pnputilCode" }
        if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) }
        $od.Reason = (L '삭제 실패 — {0}' 'Deletion failed - {0}') -f $msg
        $script:oldDriverStatus.Skipped++
        Write-LogEntry "OldDrivers: WARN - 삭제 실패 $($od.Inf): $msg"
      }
    } catch {
      $od.Reason = (L '삭제 중 오류 — {0}' 'Error while deleting - {0}') -f $_.Exception.Message
      $script:oldDriverStatus.Skipped++
      Write-LogEntry "OldDrivers: WARN - 삭제 오류 $($od.Inf): $($_.Exception.Message)"
    }
  }

  $recommendations += ((L '[오래된 드라이버] 새 버전이 설치되어 있음에도 이전 드라이버 {0}개가 남아 있습니다 (삭제 {1} / 보류 {2}). 확인해보세요. 직접 실행하여 삭제 질문에 y를 누르면 삭제됩니다.' '[Old drivers] {0} older package(s) remain despite a newer version installed (deleted {1} / skipped {2}). Please review. Run the check manually and answer y at the delete prompt to remove them.') -f $oldDrivers.Count, $script:oldDriverStatus.Deleted, $script:oldDriverStatus.Skipped)
  Write-LogEntry (('OldDrivers: WARN - 이전 드라이버 {0}개 (삭제 {1} / 보류 {2})') -f $oldDrivers.Count, $script:oldDriverStatus.Deleted, $script:oldDriverStatus.Skipped)
}  # end of find/delete branch
}  # end of oldDriverCheckDays gate — 감지/삭제/리포트는 30일에 한 번만

# --- 3개월 이상 지난 결과 파일 자동 삭제 (2026-11-17, v1.4.0 사용자 요청) ---
#   "날짜상 3개월 이상 지난 결과 파일은 자동삭제하고"
#   기존(v1.2.0~v1.3.1)에는 '7일 이상'을 지우기 전 확인 목록으로 물어봤다. 이제는 이 키트가 만든
#   결과 txt(자동유지보수_*.txt / MaintenanceReport_*.txt / auto-maintenance_*.txt)만 resultRetentionDays(기본 90일) 기준으로
#   **묻지 않고 자동 삭제**한다. 사용자가 만든 다른 파일은 이름 패턴이 달라 대상이 되지 않는다.
#   리포트를 쓰기 전에 정리해야 (a) 이번 리포트에 삭제 내역이 들어가고 (b) 방금 만든 파일과 섞이지 않는다.
if ($Mode -eq 'scheduled' -or $Mode -eq 'idle') {
  try {
    $desktopCleanupPath = ''
    if (-not [string]::IsNullOrWhiteSpace($ReportTo) -and (Test-Path -LiteralPath $ReportTo)) { $desktopCleanupPath = $ReportTo }
    else { $desktopCleanupPath = [Environment]::GetFolderPath('Desktop') }
    if ([string]::IsNullOrEmpty($desktopCleanupPath)) { $desktopCleanupPath = '' }
    if ($desktopCleanupPath) {
      $script:desktopPathForReport = $desktopCleanupPath
      $retentionDays = 90
      $retentionCfg = Get-Cfg 'resultRetentionDays'
      if ($null -ne $retentionCfg) {
        $retentionParsed = 0
        if ([int]::TryParse([string]$retentionCfg, [ref]$retentionParsed)) { $retentionDays = $retentionParsed }
      }
      $script:resultCleanup = Remove-OldResultFiles -DesktopPath $desktopCleanupPath -RetentionDays $retentionDays
      if ($script:resultCleanup.Deleted -gt 0) {
        $cleanupSize = Format-ByteSize ([double]$script:resultCleanup.Bytes)
        Write-LogEntry ("REPORT: CHANGE - {0}일(3개월) 지난 결과 파일 {1}개 자동 삭제 ({2})" -f $retentionDays, $script:resultCleanup.Deleted, $cleanupSize)
        foreach ($rp in @($script:resultCleanup.Paths)) { try { Add-Content -Path $logPath -Value "    · $rp" -Encoding UTF8 } catch { } }
        Write-Output ("[정리] {0}일 지난 결과 파일 {1}개를 자동 삭제했습니다 ({2})" -f $retentionDays, $script:resultCleanup.Deleted, $cleanupSize)
      } else {
        Write-LogEntry ("REPORT: INFO - {0}일 지난 결과 파일 없음 (자동 삭제 대상 없음)" -f $retentionDays)
      }

      # 바탕화면 결과 파일이 이번 것까지 합쳐 4개 이상이면 '자동점검결과' 폴더로 **전부** 옮긴다(v1.4.0).
      #   최신 1개도 폴더로 들어가고, 이번 실행에서 새로 만드는 결과 1개만 바탕화면에 남는다.
      #   이동만 하므로 안전·가역이다.
      try {
        $script:reportMove = Move-OldDesktopReports -DesktopPath $desktopCleanupPath -Threshold 4 -IncomingCount 1
      } catch {
        Write-LogEntry "REPORT: WARN - 바탕화면 결과 파일 정리 실패: $($_.Exception.Message)"
      }
      if ($script:reportMove -and $script:reportMove.Moved -gt 0) {
        Write-LogEntry ("REPORT: CHANGE - 이전 결과 파일 {0}개를 '자동점검결과' 폴더로 옮김" -f $script:reportMove.Moved)
        foreach ($mvPath in @($script:reportMove.Paths)) { try { Add-Content -Path $logPath -Value "    · $mvPath" -Encoding UTF8 } catch { } }
        Write-Output ("[정리] 지난 결과 파일 {0}개를 바탕화면의 '자동점검결과' 폴더로 옮겼습니다. 이번 결과 1개만 바탕화면에 남습니다." -f $script:reportMove.Moved)
        Write-Output ("       폴더: $($script:reportMove.Folder)")
      } elseif ($script:reportMove -and $script:reportMove.Error) {
        Write-LogEntry "REPORT: WARN - 바탕화면 결과 파일 정리: $($script:reportMove.Error)"
      }
    }
  } catch {
    Write-LogEntry "ResultCleanup: WARN - 지난 결과 파일 자동 삭제 실패: $($_.Exception.Message)"
  }
}

# --- 요약 (Summary) ---
try { Add-Content -Path $logPath -Value "`n[SUMMARY_START]" -Encoding UTF8 } catch { }
# 실패 사유가 하나라도 있으면 FAIL 로 확정한다.
#   기존에는 대부분의 실패 분기가 $allPass 를 건드리지 않아(WHEA/GPU/BSOD/HOSTS/GhostDev/Startup/CHKDSK 등
#   34개 중 24개) 로그에 "Failure Reasons"가 찍혀도 Overall Status 는 PASS 였다.
#   → wrapper/status.json/토스트가 PASS 로 잘못 전달되던 원인.
if ($failureReasons.Count -gt 0 -and $allPass) {
  $allPass = $false
}
if ($allPass) {
  Write-LogEntry 'Overall Status: PASS - All system checks passed'
} else {
  Write-LogEntry 'Overall Status: FAIL - Some checks failed'
  Write-Host "`n실패 사유:"
  $failureMsg = "`nFailure Reasons:"
  try { Add-Content -Path $logPath -Value $failureMsg -Encoding UTF8 } catch { }
  foreach ($reason in $failureReasons) {
    Write-Host "  - $reason"
    try { Add-Content -Path $logPath -Value "  - $reason" -Encoding UTF8 } catch { }
  }
}
# 권장 사항은 PASS/FAIL 과 무관하게 항상 기록한다.
#   - 자동 복구를 없앤 항목은 "권장 사항"이 유일한 출력이므로 PASS 로 끝난 실행에서도 남아야 한다.
if ($recommendations.Count -gt 0) {
  $recMsg = "`nRecommendations:"
  try { Add-Content -Path $logPath -Value $recMsg -Encoding UTF8 } catch { }
  foreach ($rec in $recommendations) {
    try { Add-Content -Path $logPath -Value "  - $rec" -Encoding UTF8 } catch { }
  }
}
# 자동 조치 내역: "문제를 찾아 실제로 무엇을 바꿨는지"를 남긴다(로그 + last-result.json + 데스크톱 리포트).
if ($script:autoFixes.Count -gt 0) {
  $fixMsg = "`nAuto Fixes:"
  try { Add-Content -Path $logPath -Value $fixMsg -Encoding UTF8 } catch { }
  foreach ($fx in $script:autoFixes) {
    try { Add-Content -Path $logPath -Value "  - $fx" -Encoding UTF8 } catch { }
  }
}
# 삭제 전 확인 목록(2026-11-12): 무엇을 지웠는지/보류했는지 + 지우려던 파일 목록.
#   사용자 요청으로 데스크톱 결과 txt 에도 같은 내용을 넣는다.
if ($script:deleteReview.Count -gt 0) {
  try { Add-Content -Path $logPath -Value "`nDelete Review (삭제 전 확인 목록):" -Encoding UTF8 } catch { }
  foreach ($dr in $script:deleteReview) {
    try { Add-Content -Path $logPath -Value ("  - [{0}] {1}개 / {2} → {3}" -f $dr.target, $dr.count, $dr.size, $dr.decisionText) -Encoding UTF8 } catch { }
  }
}
# 광고 기능으로 생길 수 있는 문제 경고: 매 실행 반복되는 "할 일"이 아니므로 recommendations 와 분리한다.
if ($script:adWarning.Count -gt 0) {
  $adMsg = "`nAd Warnings:"
  try { Add-Content -Path $logPath -Value $adMsg -Encoding UTF8 } catch { }
  foreach ($w in $script:adWarning) {
    try { Add-Content -Path $logPath -Value "  - $w" -Encoding UTF8 } catch { }
  }
}
Write-LogEntry "Maintenance completed at $(Get-Date -Format 'o')"
# 마지막 단계(Auto-Heal)는 다음 Write-ProgressBar가 없어 시간이 누적되지 않는다 → 여기서 강제 확정.
# (수정 전: 벽시계 21분 중 13분이 "Execution Timing"에서 사라져 보였음)
if ($script:stepName -and $script:executionStopwatch) {
  $null = $script:executionTimings.Add(@{ Step = $script:stepName; Time = $script:executionStopwatch.Elapsed })
  $script:stepName = ''
}
# 실행 시간 프로파일링
$totalTime = [TimeSpan]::Zero
$timingLines = @()
$stepTimingMap = [ordered]@{}
foreach ($t in $script:executionTimings) {
  $totalTime = $totalTime.Add($t.Time)
  $sec = [math]::Round($t.Time.TotalSeconds, 1)
  # 단계별 시간을 last-result.json 에도 남긴다(기존엔 5s 이상만 로그에 남아 원인 추적이 어려웠음).
  $key = [string]$t.Step
  if ($stepTimingMap.Contains($key)) { $stepTimingMap[$key] = [math]::Round($stepTimingMap[$key] + $sec, 1) }
  else { $stepTimingMap[$key] = $sec }
  if ($t.Time.TotalSeconds -ge 5) {
    $timingLines += "  $($t.Step): ${sec}s"
  }
}
if ($timingLines.Count -gt 0) {
  $totalSec = [math]::Round($totalTime.TotalSeconds, 1)
  $timingHeader = "`nExecution Timing (total: ${totalSec}s, steps >= 5s):"
  try { Add-Content -Path $logPath -Value $timingHeader -Encoding UTF8 } catch { }
  foreach ($tl in $timingLines) {
    try { Add-Content -Path $logPath -Value $tl -Encoding UTF8 } catch { }
  }
}
# --- 결과 요약 파일 + 실패 알림 ---
$wallSec = 0
try { $wallSec = [math]::Round(((Get-Date) - $script:runStartTime).TotalSeconds, 1) } catch { }
$stepSec = [math]::Round($totalTime.TotalSeconds, 1)
$resultObj = [ordered]@{
  timestamp       = (Get-Date).ToString('o')
  version         = $kitVersionText
  mode            = $Mode
  status          = $(if ($allPass) { 'PASS' } else { 'FAIL' })
  wallSeconds     = $wallSec
  stepSeconds     = $stepSec
  stepTimings     = $stepTimingMap
  failureReasons  = @($failureReasons)
  recommendations = @($recommendations)
  autoFixes       = @($script:autoFixes)
  adStatus        = $script:adStatus
  adWarnings      = @($script:adWarning)
  deleteReview    = @($script:deleteReview)
  resultCleanup   = $(if ($script:resultCleanup) { [ordered]@{ retentionDays = $retentionDays; deleted = [int]$script:resultCleanup.Deleted; bytes = [double]$script:resultCleanup.Bytes; paths = @($script:resultCleanup.Paths) } } else { $null })
  desktopReportMove = $(if ($script:reportMove -and $script:reportMove.Moved -gt 0) { [ordered]@{ folder = [string]$script:reportMove.Folder; moved = [int]$script:reportMove.Moved; paths = @($script:reportMove.Paths) } } else { $null })
  log             = $logPath
}
Save-JsonState (Join-Path $scriptRoot 'last-result.json') $resultObj
if (-not $allPass -and (Get-Cfg 'notifyOnFail')) {
  $firstReason = if ($failureReasons.Count -gt 0) { [string]$failureReasons[0] } else { '일부 검사 실패' }
  $notified = Show-ToastNotification -Title '유지보수 검사 실패' -Body $firstReason
  if ($notified) { Write-LogEntry 'Notify: INFO - 실패 알림(토스트) 표시' }
  else { Write-LogEntry 'Notify: WARN - 토스트 알림 표시 실패 (last-result.json 참고)' }
}

# 이벤트 로그 기록 (완료)
$eventMsg = "Maintenance completed. Status: $($(if ($allPass){'PASS'}else{'FAIL'})). Duration: $([math]::Round($totalTime.TotalSeconds, 1))s."
try { Write-EventLog -LogName Application -Source 'Maintenance' -EntryType $(if ($allPass){'Information'}else{'Warning'}) -EventId $(if ($allPass){101}else{102}) -Message $eventMsg -ErrorAction SilentlyContinue } catch { }
try { Add-Content -Path $logPath -Value '[SUMMARY_END]' -Encoding UTF8 } catch { }

# ============================================================
# v1.7.0: 영어 모드에서 상세 로그의 한글 문구를 영어로 바꾼다.
#   요약 블록은 L() 로 이미 번역되지만, 상세 로그는 원본 로그(한글 권장문구 등)를
#   그대로 포함하므로 여기서 문구 단위로 치환한다. 긴 문구를 먼저 처리해
#   짧은 조각이 먼저 치환되는 것을 막는다([ordered] 사용).
# ============================================================
$script:reportEnglishMap = [ordered]@{
  'Windows 정품 인증이 필요합니다 (설정 > 시스템 > 정품 인증). 미인증 시 보안 업데이트가 중단됩니다.' = 'Windows is not activated (Settings > System > Activation). Security updates are paused until activated.'
  'BIOS/UEFI 설정에서 Secure Boot를 켜세요 (부팅 무결성 보호). 리그 오브 레전드·발로란트 등 일부 게임(안티치트 Vanguard)은 Windows 11 에서 Secure Boot + TPM 2.0 이 필요합니다. UEFI CA 2023 갱신도 미완료라면 최신 누적 업데이트 설치 후 재부팅 2회 필요.' = 'Enable Secure Boot in BIOS/UEFI (boot integrity protection). Some games (e.g. Vanguard anti-cheat) require Secure Boot + TPM 2.0 on Windows 11. If UEFI CA 2023 renewal is also pending, install the latest cumulative update and reboot twice.'
  'TPM이 준비되지 않았습니다. BIOS에서 fTPM/PTT를 켜고 tpm.msc 에서 상태를 확인하세요.' = 'TPM is not ready. Enable fTPM/PTT in BIOS and check status in tpm.msc.'
  'WinRE BCD 등록이 손상되었습니다. 관리자 PowerShell에서 reagentc /disable 후 /enable 로 재등록하세요.' = 'WinRE BCD registration is damaged. In admin PowerShell, run reagentc /disable then /enable.'
  '관리자 PowerShell에서 winmgmt /resetrepository 실행 후 재부팅 (마지막 수단)' = 'As a last resort, run winmgmt /resetrepository in admin PowerShell and reboot.'
  '그래픽 드라이버 충돌이 감지되었습니다. GPU 제조사 사이트에서 최신 드라이버로 업데이트하거나 DDU로 기존 드라이버를 완전 제거 후 재설치하세요.' = 'GPU driver conflict detected. Update to the latest driver from the GPU vendor, or fully remove the old driver with DDU and reinstall.'
  '이벤트 원시 데이터에 STORPORT(스토리지 스택) 흔적이 있습니다. CPU 전압 문제로 단정하지 말고 SSD/HDD SMART·케이블·포트를 우선 점검하세요.' = 'Raw event data shows STORPORT (storage stack) traces. Do not assume CPU voltage issues; check SSD/HDD SMART, cables and ports first.'
  '하드웨어 오류(WHEA)가 감지되었습니다. 원시 데이터의 ErrorSource/드라이버 토큰을 확인하고, CPU/메모리 오버클럭 설정 또는 문제 장치를 점검하세요.' = 'Hardware error (WHEA) detected. Check ErrorSource/driver tokens in raw data and review CPU/memory overclock settings or the failing device.'
  '광고 차단은 100%가 아닙니다. 앱 안에 직접 그려지는 광고와 이미 설치된 광고 앱은 막히지 않습니다(이 키트는 파일 삭제·앱 제거를 하지 않습니다).' = 'Ad blocking is not 100%. In-app ads and already-installed ad apps are not blocked (this kit does not delete files or uninstall apps).'
  '되돌리기: 바탕화면 "자동 유지보수 제거" → 광고 설정 복원, 또는 uninstall.ps1 -RestoreAds' = 'To revert: desktop "remove maintenance" -> Restore ad settings, or uninstall.ps1 -RestoreAds'
  'DNS 복원에 실패했습니다. 네트워크 어댑터 DNS 설정을 직접 확인하세요(어댑터를 삭제/교체하면 자동 복원 불가).' = 'DNS restore failed. Check adapter DNS settings manually (automatic restore is not possible if the adapter was removed/replaced).'
  '서비스는 Windows 구동에 필수적입니다. 이벤트 뷰어에서 오류 코드를 확인하고 시스템 복원 또는 Windows 복구를 고려하세요.' = 'service is essential for Windows. Check the error code in Event Viewer and consider System Restore or Windows recovery.'
  '서비스를 시작할 수 없습니다. services.msc에서 수동으로 시작하거나 시스템 복원을 고려하세요.' = 'service could not be started. Start it manually in services.msc or consider System Restore.'
  '광고/추천 스위치를 껐습니다 → 설정·시작 메뉴의 "추천/팁"과 잠금화면 문구가 달라질 수 있습니다(기능에는 영향 없음).' = 'Ad/recommendation switches turned off -> "Tips/suggestions" in Settings/Start and lock-screen text may change (no impact on functionality).'
  '광고/추천 스위치는 이미 꺼져 있습니다 → 설정·시작 메뉴의 "추천/팁"이 보이지 않는 것이 정상입니다.' = 'Ad/recommendation switches are already off -> not seeing "Tips/suggestions" in Settings/Start is normal.'
  'adBlockExtraDomains 에는 정확한 도메인만 넣으세요(와일드카드/URL 불가):' = 'adBlockExtraDomains accepts exact domains only (no wildcards/URLs):'
  ' 개를 막았습니다 → 앱 로그인·설치·업데이트가 실패할 수 있습니다. 그때는 adBlockAllowDomains 에 예외를 넣거나 adBlockEnabled=false 로 끄세요.' = ' ad domains via hosts -> app sign-in/install/update may fail. If so, add exceptions in adBlockAllowDomains or set adBlockEnabled=false.'
  ')로 바꿨습니다 → 공유기·프린터·NAS 같은 내부 주소를 못 찾거나 VPN/보안 프로그램과 충돌할 수 있습니다.' = ') -> local addresses (router/printer/NAS) may not resolve, or conflicts with VPN/security software may occur.'
  'DNS 필터 서버가 응답하지 않습니다. 인터넷이 안 되면 adDnsEnabled=false 로 되돌리세요.' = 'DNS filter server is not responding. If internet stops working, revert adDnsEnabled=false.'
  'hosts 파일에 차단 목록을 쓰지 못했습니다(권한/백신 잠금 가능).' = 'Could not write the blocklist to the hosts file (permissions or antivirus lock possible).'
  'adDnsEnabled=true 인데 adDnsServers 가 올바른 IPv4 주소가 아닙니다.' = 'adDnsEnabled=true but adDnsServers is not a valid IPv4 address.'
  '복구 파티션/Winre.wim 확인 후 관리자 PowerShell에서 reagentc /enable 실행' = 'Check recovery partition/Winre.wim, then run reagentc /enable in admin PowerShell'
  '건 만료/임박 — certlm.msc 에서 갱신하거나 불필요 인증서를 제거하세요.' = ' expired/expiring - renew in certlm.msc or remove unneeded certificates.'
  '드라이브의 여유 공간이' = 'free space:'
  '메모리 사용량이' = 'Memory usage is'
  '여유 메모리가' = 'Free memory is'
  'GB 밖에 없습니다. 현재 용량으로는 디스크 속도나 이용에 문제가 있을 수 있으니, 필요한 자료를 백업한 뒤' = 'GB only. This may affect disk speed or usage. Back up important data, then free at least'
  'GB 입니다. 필요한 자료를 백업한 뒤' = 'GB free. Back up important data, then'
  'GB 이상 확보하시는 걸 권장합니다.' = 'GB or more is recommended.'
  '%로 매우 높습니다. 불필요한 프로그램을 종료하거나 RAM을 증설하세요.' = '% - very high. Close unused programs or add more RAM.'
  'MB 미만입니다. 추가 RAM 장착을 고려하세요.' = 'MB or less. Consider adding more RAM.'
  '현재 용량으로는 디스크 속도나 이용에 문제가 있을 수 있습니다.' = 'This free space may affect disk speed or usage.'
  '용량이 이만큼 남았으니 오래된 파일부터 삭제합니다.' = 'Some space is free; deleting the oldest files first.'
  '여유 공간을 조금 확보하려고 오래된 임시 파일부터 정리하려고 합니다.' = 'Trying to free space by cleaning old temporary files.'
  '필요한 자료가 있으시면 백업을 하세요.' = 'Back up any important data first.'
  '. TEMP/TMP 위치나 config 의 tempDirs 를 확인하세요.' = '. Check TEMP/TMP locations or tempDirs in config.'
  '는 자동 정리에서 제외했습니다 — ' = ' was excluded from automatic cleanup - '
  '서비스가 실행 중이 아닙니다. 관리자 권한으로' = 'service is not running. As administrator, run'
  '볼륨 섀도우 복사본 서비스가 중지되었습니다. 관리자 권한으로' = 'Volume Shadow Copy service is stopped. As administrator, run'
  "을 실행하세요." = "."
  '시스템 속성 > 고급 > 시작 및 복구에서 덤프 형식을' = 'In System Properties > Advanced > Startup and Recovery, set dump type to'
  "'자동 메모리 덤프'로 설정하세요." = "'Automatic memory dump'."
  '시스템 보호 탭에서 C: 드라이브 보호를 켜고' = 'On the System Protection tab, enable protection for C: and click'
  "'만들기'로 복원 지점을 생성하세요." = "'Create' to make a restore point."
  'UDP 123 차단 여부(공유기/방화벽)를 확인하세요. NTP 서버 후보:' = 'Check whether UDP 123 is blocked (router/firewall). NTP server candidates:'
  '2026년 만료되는 Secure Boot 인증서 교체가 미완료입니다(' = 'Secure Boot certificate expiring in 2026 has not been replaced ('
  '). 최신 누적 업데이트 설치 후 재부팅하세요.' = '). Install the latest cumulative update and reboot.'
  '런타임 불량블록이' = 'runtime bad blocks:'
  '건 증가(누적' = ' new (total'
  ') — 즉시 백업 후 표면 검사/교체 검토' = ') - back up immediately, then run a surface scan / consider replacement'
  'SATA UDMA CRC 오류가' = 'SATA UDMA CRC errors:'
  ') — 케이블/포트 교체·재장착 후 재확인 (재할당·보류 섹터가 0이면 NAND 불량보다 링크 문제)' = ') - reseat or replace cable/port and recheck (if reallocated/pending sectors are 0, this is likely a link issue rather than NAND failure)'
  '배터리 수명이' = 'Battery health is'
  '%. 배터리 교체를 권장합니다.' = '% - battery replacement is recommended.'
  'hosts 의 와일드카드 줄' = 'wildcard lines in hosts:'
  '개는 Windows 가 지원하지 않아 차단되지 않습니다. 정확한 호스트명으로 바꾸세요:' = ' are not supported by Windows and will not block anything. Replace with exact hostnames:'
  '광고/추천 설정을 처리하지 못했습니다:' = 'Could not process ad/recommendation settings:'
  'hosts 로 광고 도메인' = 'Blocked'
  'hosts 파일 처리 실패:' = 'hosts file processing failed:'
  'DNS 를 필터링 서버(' = 'DNS changed to filtering server ('
  'DNS 설정 처리 실패:' = 'DNS settings processing failed:'
  '방화벽이 꺼져 있습니다(' = 'Firewall is off ('
  ') — Windows 보안 > 방화벽 및 네트워크 보호에서 켜세요.' = ') - enable it in Windows Security > Firewall & network protection.'
  'HuggingFace 캐시' = 'HuggingFace cache'
  'GB — 사용하지 않는 모델 저장소만 수동 삭제 (자동 삭제 금지: 재다운로드 비용 큼)' = 'GB - manually delete only unused model repos (automatic deletion disabled: re-download is costly)'
  '새 항목 확인/비활성화 검토:' = 'Review new startup item / consider disabling:'
  "드라이브 최적화'에서 일정 최적화를 직접 켜세요(TRIM/조각모음이 실행되지 않고 있습니다)." = "Drive Optimize' and enable scheduled optimization (TRIM/defrag is not running)."
  '검사가 게임 안티치트/보안 프로그램에 막혔습니다. 해결 순서: (1) 게임과 런처를 완전히 종료(트레이 아이콘까지)한 뒤 이 점검을 다시 실행, (2) 그래도 막히면 재부팅 직후(게임 실행 전)에 점검, (3) 계속 막히면 안전 모드에서' = ' scan was blocked by game anti-cheat/security software. Try: (1) fully close the game and launcher (including tray icons), then rerun this check, (2) if still blocked, run right after reboot (before launching the game), (3) if still blocked, run in Safe Mode with'
  '드라이브는 재부팅 후 전체 검사(chkdsk /f)가 실행됩니다. 검사 중에는 전원을 끄지 마세요.' = ' drive will run a full check (chkdsk /f) after reboot. Do not power off during the scan.'
  '드라이브 수정에 실패했습니다. 데이터를 백업하고 디스크 교체를 고려하세요.' = ' drive repair failed. Back up data and consider replacing the disk.'
  '시스템 파일 일부를 복구하지 못했습니다(종료 코드' = 'Some system files could not be repaired (exit code'
  ")). Windows 업데이트 후 'DISM /Online /Cleanup-Image /RestoreHealth' → 'sfc /scannow' 순서로 재시도하세요." = "). After Windows Update, retry in this order: 'DISM /Online /Cleanup-Image /RestoreHealth' -> 'sfc /scannow'."
  'W32Time 서비스가 중지됨 — services.msc에서 시작 유형 확인 후 Start-Service w32time' = 'W32Time service is stopped - check startup type in services.msc, then Start-Service w32time'
  '시계 오차' = 'Clock offset'
  ' — w32tm /resync /rediscover 수동 실행. 반복되면 CMOS 배터리/가상화 시간 동기화 확인' = ' - run w32tm /resync /rediscover manually. If recurring, check CMOS battery / VM time sync'
  ' — 자동 보정이 1초 미만으로 떨어지지 않음(재동기화 반복 또는 NTP 서버 변경 검토)' = ' - auto-correction does not drop below 1 second (consider repeated resync or changing NTP server)'
  '회 충돌' = ' crashes'
  ' — 이벤트 뷰어에서 상세 확인' = ' - see Event Viewer for details'
  '부팅 지연 — 시작 프로그램/서비스 축소, 빠른 시작(fast startup) 확인, 저장장치 펌웨어·칩셋 드라이버 업데이트' = 'Slow boot - reduce startup apps/services, check fast startup, update storage firmware and chipset drivers'
  '비정상 종료' = 'Unexpected shutdowns:'
  '건 — 전원 공급/CMOS 배터리/메모리 안정성 점검 (WHEA 단계 결과와 함께 판단)' = ' - check power supply/CMOS battery/memory stability (review together with WHEA step results)'
  'Windows Update 검색 실패 —' = 'Windows Update search failed -'
  '(서비스/방화벽/프록시 확인)' = '(check service/firewall/proxy)'
  'Windows Update 대기' = 'Pending Windows Updates:'
  '건 — 설정 > Windows Update에서 설치 후 재부팅' = ' - install in Settings > Windows Update, then reboot'
  '최근 누적 업데이트가' = 'Latest cumulative update was'
  '일 전 — Windows Update로 패치 설치 권장' = ' days ago - install patches via Windows Update'
  'Defender 서명 오래됨 — Update-MpSignature 실행 또는 Windows Update 확인' = 'Defender signatures are outdated - run Update-MpSignature or check Windows Update'
  'Defender 보호 기능이 꺼져 있습니다(' = 'Defender protection is off ('
  ') — Windows 보안 앱에서 켜거나 변조 방지 설정을 확인하세요.' = ') - enable in the Windows Security app or check tamper-protection settings.'
  '재부팅 대기 상태(' = 'Reboot pending ('
  ') — 재부팅 후 업데이트가 마무리됨' = ') - updates finish after reboot'
  '자동 복구 실패:' = 'Auto-repair failed:'
  '예약 작업 확인:' = 'Check scheduled task:'
  '인증서' = 'certificate(s)'
  # --- 자동 조치(Auto Fixes) ---
  '볼륨 섀도 복사본) 서비스 재시작 (was ' = 'Volume Shadow Copy) service restarted (was '
  '서비스 재시작 (was ' = ' service restarted (was '
  '디스크 부족(' = 'Low disk space ('
  ' → 임시 폴더 정리 ' = ' -> temp folder cleanup '
  '크래시 덤프 형식 ' = 'Crash dump type '
  ' → 7(자동 메모리 덤프)로 변경' = ' -> 7 (Automatic memory dump)'
  '미니덤프 폴더 생성 (' = 'Minidump folder created ('
  '시스템 복원 비활성 → C: 복원 활성화' = 'System Restore disabled -> C: restore enabled'
  '복원 지점 예약 작업 활성화: ' = 'Restore point scheduled task enabled: '
  '복원 지점 생성 (Maintenance checkpoint)' = 'Restore point created (Maintenance checkpoint)'
  'W32Time 서비스 시작 (was ' = 'W32Time service started (was '
  'W32Time 서비스 등록 복구 (w32tm /register)' = 'W32Time service registration repaired (w32tm /register)'
  '시간 동기화 소스 재구성 (Local CMOS → ' = 'Time sync source reconfigured (Local CMOS -> '
  '이벤트 로그 최대 크기 64MB 확장 (' = 'Event log max size expanded to 64MB ('
  '섀도 복사 저장소 ' = 'Shadow copy storage '
  ' 최대 ' = ' max '
  'GB → 20GB 확장' = 'GB -> 20GB expanded'
  '대화형 서비스 정리: ' = 'Interactive service cleanup: '
  'WinRE 비활성 → reagentc /enable 로 복구' = 'WinRE disabled -> recovered with reagentc /enable'
  'WMI 리포지토리 불일치 → winmgmt /salvagerepository 로 복구' = 'WMI repository mismatch -> repaired with winmgmt /salvagerepository'
  '브라우저 캐시 ' = 'Browser cache '
  'pip 캐시 ' = 'pip cache '
  'conda 캐시 ' = 'conda cache '
  'MB 정리 (30일 이상 경과, ' = 'MB cleaned (older than 30 days, '
  'GB 정리 (기준 ' = 'GB cleaned (threshold '
  'GB 초과)' = 'GB exceeded)'
  '광고/추천 설정 원래대로 복원 (' = 'Ad/recommendation settings restored ('
  '광고/추천 설정 끔 ' = 'Ad/recommendation settings turned off '
  'hosts 광고 도메인 차단 (' = 'Blocked ad domains in hosts ('
  'DNS 서버 변경 (' = 'DNS servers changed ('
  'DNS 서버 원래대로 복원 (어댑터 ' = 'DNS servers restored (adapter(s) '
  ' — 어댑터 ' = ' - adapter(s) '
  '방화벽 프로필 활성화 (' = 'Firewall profile enabled ('
  '휴지통 ' = 'Recycle Bin: '
  '개 파일 ' = ' file(s) '
  'MB 비움 (30일 이상 경과)' = 'MB emptied (older than 30 days)'
  '작업을 다시 켰습니다(TRIM/조각모음 자동 실행 복구).' = ' task re-enabled (TRIM/defrag auto-run restored).'
  '파일 시스템 오류 복구 (' = ' file system errors repaired ('
  '시스템 파일 무결성 위반 복구 (sfc /scannow)' = 'System file integrity violations repaired (sfc /scannow)'
  'ms 자동 보정 (w32tm /resync /force)' = 'ms auto-corrected (w32tm /resync /force)'
  '서비스(wuauserv)가 Disabled 였음 → Manual 로 복구' = ' service (wuauserv) was Disabled -> restored to Manual'
  ' 시작 후 재검색 성공' = ' started; re-search succeeded'
  '건 자동 설치 완료' = ' update(s) installed automatically'
  ' — 재부팅 필요' = ' - reboot required'
  '일 → ' = ' days -> '
  '일 자동 갱신 (' = ' days auto-updated ('
  '버전 ' = 'version '
  '보호 기능 재활성화 (' = ' protection re-enabled ('
  '건 자동 복구' = ' item(s) auto-repaired'
  ' 자동 복구 실패' = ' auto-repair failed'
  '개 파일)' = ' file(s))'
  ' 항목)' = ' item(s))'
  # --- 삭제 확인 / 안내 ---
  '[정리 제외]' = '[Cleanup skipped]'
  '[삭제 확인]' = '[Deletion confirmation]'
  '지우려는 목록:' = 'Files to delete:'
  '지우시겠습니까? (y = 삭제 / N 또는 Enter = 그대로 두기)' = 'Delete these? (y = delete / N or Enter = keep)'
  ' → 앞에서 한 번에 승인하셨으므로 바로 지웁니다.' = ' -> Approved for all earlier; deleting now.'
  ' → 앞에서 "모두 그대로"를 선택하셨으므로 지우지 않습니다.' = ' -> "Keep all" was selected earlier; not deleting.'
  '지움 (앞에서 한 번에 승인)' = 'Deleted (approved earlier for all)'
  '지움 (사용자가 y 선택)' = 'Deleted (user chose y)'
  '그대로 둠 (앞에서 한 번에 보류)' = 'Left as-is (skipped earlier for all)'
  "그대로 둠 (사용자가 '아니오' 선택)" = 'Left as-is (user chose No)'
  '그대로 둠 (자동 실행 — 물어볼 사람이 없어 보류)' = 'Left as-is (automatic run - nobody to ask, deferred)'
  # v1.14.0: A/Y/N 결정 문구
  '지움 (A — 설정에 기억된 자동 삭제)' = 'Deleted (A - remembered auto-delete)'
  '지움 (A — 언제나 삭제 선택)' = 'Deleted (A - always delete chosen)'
  '지움 (Y — 현재만 삭제)' = 'Deleted (Y - this time only)'
  '그대로 둠 (N — 거부)' = 'Left as-is (N - rejected)'
  ' (기록 한도 ' = ' (record limit '
  '개 초과)' = ' exceeded)'
  '삭제 기록 파일: ' = 'Deletion record file: '
  '... 외 ' = '... and '
  ' 외 ' = ' and '
  # --- v1.7.0 추가: 실제 리포트에서 확인된 한글 문구 ---
  "바탕화면 '자동 유지보수 점검'을 실행하면 목록을 보여주고 지울지 물어봅니다." = 'Run the desktop "auto-maintenance" shortcut to see the list and choose what to delete.'
  '[삭제 보류]' = '[Deletion deferred]'
  '30일 이상' = 'older than 30 days'
  '모듈: ' = 'Module: '
  '예외: ' = 'Exception: '
  '검출: ' = 'Detected: '
  '드라이버 문제' = 'driver issue'
  'Windows Update/제조사에서 업데이트 확인' = 'check for updates via Windows Update / the manufacturer'
  '새 오류 유형' = 'New error type'
  '강제 실행(-SkipCadence)' = 'forced run (-SkipCadence)'
  '수동 시작 서비스, 필요 시 자동 실행' = 'manual-start service; auto-starts when needed'
  '재할당=' = 'Reallocated='
  '보류=' = 'Pending='
  '수정불가=' = 'Uncorrectable='
  '불량블록=' = 'BadBlocks='
  '(이력)' = '(historical)'
  '시간 초과' = 'timed out'
  '서비스 중단/타임아웃' = 'Service stopped / timed out'
  '매니페스트 오류' = 'manifest error'
  '충돌' = 'crashes'
  '시스템 복원 활성화됨' = 'System Restore enabled'
  '최근 24시간 내 복원 지점 존재' = 'Restore point exists within the last 24 hours'
  '시간 동기화 정상 (소스: ' = 'Time sync OK (source: '
  '주요 이벤트 로그 max 크기 64MB 이상' = 'Main event log max size at least 64MB'
  '크기 정상 (' = 'size OK ('
  '볼륨, 모두 10GB 이상)' = 'volumes, all at least 10GB)'
  '3rd 파티 대화형 서비스 없음 (인박스 ' = 'No third-party interactive services (inbox '
  '는 정상)' = ' are normal)'
  'Secure Boot 활성' = 'Secure Boot active'
  'TPM 준비됨' = 'TPM ready'
  '갱신 완료' = 'renewed'
  'WinRE 등록됨' = 'WinRE registered'
  '리포지토리 정상' = 'Repository OK'
  '만료 임박' = 'expiring'
  '없음 (전체 ' = 'none (total '
  '감시 작업 ' = 'Watched tasks: '
  '와일드카드 ' = 'wildcard '
  '줄은 작동하지 않습니다:' = 'line(s) do not work:'
  'adQuiet=false 이므로 이전에 바꾼 설정을 복원했습니다' = 'adQuiet=false, so previously changed settings were restored'
  'hosts 광고 차단 꺼짐(마커 없음)' = 'hosts ad blocking off (no marker)'
  '이더넷' = 'Ethernet'
  '방화벽 켜짐' = 'Firewall on'
  '기준 150GB 이내)' = 'threshold 150GB or less)'
  '기준 ' = 'threshold '
  '이내)' = ' or less)'
  '신규 시작 프로그램' = 'New startup item(s)'
  '(총 ' = '(total '
  '마지막 실행 ' = 'Last run '
  '(실행은 자동 유지보수 창)' = '(run from the Auto Maintenance window)'
  ' 기준)' = ' reference)'
  '일간 ' = ' days: '
  '일 ' = ' days '
  '전원 공급' = 'Power supply'
  '디스크 백업 후 배드 섹터 검사' = 'back up the disk, then scan for bad sectors'
  '케이블 재연결' = 'reseat cable'
  'USB 장치 분리 후 재연결' = 'disconnect and reconnect the USB device'
  'RAM 슬롯 재장착' = 'reseat RAM'
  '드라이버 업데이트' = 'update drivers'
  '재부팅' = 'reboot'
  '업데이트' = 'update'
  '드라이버' = 'driver'
  '오류' = 'error'
  '정상' = 'OK'
  '없음' = 'none'
  '완료' = 'completed'
  '실패' = 'failed'
  '서비스' = 'service'
  '메모리' = 'memory'
  '디스크' = 'disk'
  '네트워크' = 'network'
  '방화벽' = 'firewall'
  '백업' = 'backup'
  '검사' = 'check'
  '설정' = 'settings'
  '복원' = 'restore'
  '장치' = 'device'
  'WLANExt.exe가' = 'WLANExt.exe had'
  '기준선 대비 신규 ' = 'new vs baseline: '
  '기준선' = 'baseline'
  '앱/' = 'app / '
  '필요' = 'required'
  '부팅 시간 OK 범위 (바탕화면까지 평균 ' = 'Boot time OK (average '
  '일)' = ' days)'
  ' days 전' = ' days ago'
  '설치 대기 중인 일반 ' = 'Pending regular '
  'Defender 정의 ' = 'Defender definitions '
  '마지막 패치 ' = 'Last patch '
  'Defender 서명 ' = 'Defender signatures '
  'Defender 실시간 보호 켜짐' = 'Defender real-time protection on'
  'reboot 대기 none' = 'no reboot pending'
  '(삭제 전 확인 목록)' = '(deletion review)'
  '개' = ' item(s)'
  '건' = ' item(s)'
}

function ConvertTo-EnglishReportLine {
  param([string]$Line)
  if ($script:kitLang -eq 'ko') { return $Line }
  $out = [string]$Line
  foreach ($k in $script:reportEnglishMap.Keys) { $out = $out.Replace([string]$k, [string]$script:reportEnglishMap[$k]) }
  # 영문/숫자 바로 뒤의 조사 '가' 는 " had " 로 정리 (예: "SearchIndexer가 3건" → "SearchIndexer had 3 item(s)").
  $out = [regex]::Replace($out, '(?<=[A-Za-z0-9\.])가(?=\s)', ' had')
  return $out
}

# ============================================================
# 후처리: 데스크톱 리포트 생성 (scheduled / idle 모드에서만)
# ============================================================

if ($Mode -eq 'scheduled' -or $Mode -eq 'idle') {
  # 관리자 계정이 사용자와 다르면(표준 사용자 + UAC) [Environment]::GetFolderPath('Desktop') 은
  #   관리자 계정의 바탕화면이 된다 → 사용자는 "결과 메모장이 안 생긴다" 고 느낀다(2026-11-14).
  #   run-now.ps1 이 사용자 바탕화면 경로를 -ReportTo 로 넘겨주면 그곳에 쓴다.
  $desktopPath = ''
  if (-not [string]::IsNullOrWhiteSpace($script:desktopPathForReport) -and (Test-Path -LiteralPath $script:desktopPathForReport)) { $desktopPath = $script:desktopPathForReport }
  elseif (-not [string]::IsNullOrWhiteSpace($ReportTo) -and (Test-Path -LiteralPath $ReportTo)) { $desktopPath = $ReportTo }
  else { $desktopPath = [Environment]::GetFolderPath('Desktop') }
  try { Write-LogEntry "REPORT: target desktop = $desktopPath" } catch { }
  if (-not [string]::IsNullOrEmpty($desktopPath)) {
    try {
      $desktopLogPath = Join-Path $desktopPath ($script:resultPrefix + (Get-Date -Format 'yyyyMMdd_HHmm') + ".txt")

      # 바탕화면 정리(이동)는 요약 단계 앞에서 이미 끝냈다(v1.4.0). 여기서는 결과만 요약에 넣는다.
      $reportMove = $script:reportMove

      # --- 컴맹용 요약(맨 위 3줄 + 고친 것/할 일 목록) ---
      # v1.7.0: 시스템 언어가 영어면 요약/파일명/상세 로그의 한글 문구를 영어로 출력한다.
      $fixList = @($script:autoFixes)
      $todoList = @($recommendations)
      $summaryHead = L '================ 자동 유지보수 결과 ================' '================ Auto Maintenance - Results ================'
      $summaryStatus = if ($allPass) { L '정상 — 문제를 찾지 못했습니다.' 'OK - No problems found.' } else { L '일부 확인 필요 — 아래 내용을 보세요.' 'Attention needed - See the details below.' }
      $summaryLine = (L '결과: {0}' 'Result: {0}') -f $summaryStatus
      $summaryWhen = (L '실행: {0}' 'Run: {0}') -f (Get-Date -Format 'yyyy-MM-dd HH:mm')
      $summaryVersion = (L '버전: {0}' 'Version: {0}') -f $kitVersionText
      $summaryCounts = (L '자동으로 고친 것: {0}건 / 직접 확인할 것: {1}건 (소요 {2}초)' 'Automatically fixed: {0} / Needs your review: {1} (took {2}s)') -f $fixList.Count, $todoList.Count, $wallSec
      # 2026-11-16: 10분 이상 걸리면 "무엇이 오래 걸렸는지"를 요약에 적는다.
      $summarySlow = ''
      try {
        if ($wallSec -ge 600 -and $stepTimingMap.Count -gt 0) {
          $topSteps = @($stepTimingMap.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 2)
          $slowParts = @()
          foreach ($ts in $topSteps) {
            $v = [double]$ts.Value
            if ($v -ge 60) {
              $slowParts += ((L '{0} {1}분 {2}초' '{0} {1}m {2}s') -f $ts.Key, [int][math]::Floor($v / 60), [int][math]::Round($v % 60))
            } else {
              $slowParts += ((L '{0} {1}초' '{0} {1}s') -f $ts.Key, [int][math]::Round($v))
            }
          }
          $summarySlow = (L '가장 오래 걸린 단계: ' 'Slowest steps: ') + ($slowParts -join ', ') + (L ' (시스템 파일/디스크 검사는 원래 오래 걸립니다)' ' (system file/disk checks normally take a long time)')
        }
      } catch { }
      $summaryBody = @()
      if ($fixList.Count -gt 0) {
        $summaryBody += ''
        $summaryBody += (L '[자동으로 고친 것]' '[Automatically fixed]')
        foreach ($fx in $fixList) { $summaryBody += "  · $fx" }
      }
      if ($todoList.Count -gt 0) {
        $summaryBody += ''
        $summaryBody += (L '[직접 확인할 것]' '[Needs your review]')
        foreach ($td in $todoList) { $summaryBody += "  · $td" }
      }
      # 광고 기능은 "고장"이 아니라 사용자가 켠 설정이므로, 생길 수 있는 문제를 별도 블록으로 경고한다.
      if ($script:adWarning.Count -gt 0) {
        $summaryBody += ''
        $summaryBody += (L '[광고 설정 주의 — 문제가 생기면 여기부터 확인하세요]' '[Ad settings notice - Check here first if something goes wrong]')
        foreach ($w in $script:adWarning) { $summaryBody += "  ! $w" }
      }

      # 바탕화면 결과 파일을 결과 보관 폴더로 옮겼으면 요약에도 남긴다(2026-11-17, v1.3.0 / v1.4.0).
      if ($reportMove -and $reportMove.Moved -gt 0) {
        $summaryBody += ''
        $summaryBody += (L '[바탕화면 정리 — 결과 파일은 자동점검결과 폴더로]' '[Desktop cleanup - Results moved to the results folder]')
        $summaryBody += ((L "  · 지난 결과 파일 {0}개를 '{1}' 폴더로 옮겼습니다 (최신 것까지 모두 옮김)." "  · Moved {0} old result file(s) to the '{1}' folder (including the newest).") -f $reportMove.Moved, $script:resultFolderName)
        $summaryBody += (L '  · 바탕화면에는 이번에 새로 만든 결과 파일 1개만 남습니다.' '  · Only the new result file remains on the desktop.')
        $summaryBody += ((L '  · 옮긴 곳: {0}' '  · Moved to: {0}') -f [string]$reportMove.Folder)
        foreach ($mvPath in @($reportMove.Paths)) { $summaryBody += ("      " + [string]$mvPath) }
      }
      # 3개월(기본 90일) 지난 결과 파일 자동 삭제 내역 (2026-11-17, v1.4.0).
      if ($script:resultCleanup -and $script:resultCleanup.Deleted -gt 0) {
        $summaryBody += ''
        $summaryBody += (L '[오래된 결과 파일 자동 삭제 — 되돌릴 수 없음]' '[Old result files automatically deleted - Cannot be undone]')
        $summaryBody += ((L '  · {0}일(3개월) 이상 지난 결과 파일 {1}개를 자동으로 지웠습니다 ({2}).' '  · Automatically deleted {1} result file(s) older than {0} days (3 months) ({2}).') -f $retentionDays, $script:resultCleanup.Deleted, (Format-ByteSize ([double]$script:resultCleanup.Bytes)))
        foreach ($pe in @($script:resultCleanup.Items)) {
          $summaryBody += ("      " + [string]$pe.Name + "  (" + (Format-ByteSize ([double]$pe.Size)) + ", " + ([datetime]$pe.Date).ToString('yyyy-MM-dd HH:mm') + ")")
        }
      }

      # 삭제한 파일 / 보류한 파일 목록 (2026-11-12 사용자 요청: "지우는 목록도 결과 txt 에 표기")
      # 2026-11-13: 파일명만으로는 폴더가 여러 개일 때 구분이 안 되므로 **전체 경로**를 남긴다.
      if ($script:deleteReview.Count -gt 0) {
        $summaryBody += ''
        $summaryBody += (L '[삭제 전 확인 목록 — 지운/보류한 파일 요약 (전체 경로는 GitHub 업로드 시 개인정보 보호를 위해 생략)]' '[Deletion review - Summary of deleted/skipped files (full paths omitted when uploaded to GitHub for privacy)]')
        foreach ($dr in $script:deleteReview) {
          $summaryBody += ((L '  · [{0}] {1}개 / {2} → {3}' '  · [{0}] {1} item(s) / {2} -> {3}') -f $dr.target, $dr.count, $dr.size, $dr.decisionText)
          foreach ($nt in @($dr.notice)) { if (-not [string]::IsNullOrWhiteSpace($nt)) { $summaryBody += "      $nt" } }
          foreach ($pe in @($dr.paths)) {
            $summaryBody += ("      " + [string]$pe.path + "  (" + (Format-ByteSize ([double]$pe.size)) + ", " + [string]$pe.date + ")")
          }
          if ($dr.pathsMore -gt 0) { $summaryBody += ((L '      ... 외 {0}개 (기록 한도 초과 — 로그 파일 참고)' '      ... and {0} more (record limit reached - see the log file)') -f $dr.pathsMore) }
          if ($dr.deletedFile) { $summaryBody += ((L '      → 이 목록은 파일로도 저장했습니다: {0} (30일 보관)' '      -> This list was also saved to a file: {0} (kept for 30 days)') -f $dr.deletedFile) }
        }
      }

      # 오래된 드라이버: 새 버전이 있음에도 남은 것 / 삭제한 것 / 못 지운 것 + 이유 (v1.13.0)
      if ($script:oldDriverStatus -and @($script:oldDriverStatus.Candidates).Count -gt 0) {
        $ods = $script:oldDriverStatus
        $summaryBody += ''
        $summaryBody += ((L '[오래된 드라이버] 새 버전이 있음에도 남아 있는 이전 드라이버 {0}개' '[Old drivers] {0} older driver package(s) remain despite a newer version installed') -f @($ods.Candidates).Count)
        foreach ($od in @($ods.Candidates)) {
          $devLabel = if ($od.Device) { (L ' [장치: {0}]' ' [device: {0}]') -f $od.Device } else { '' }
          $summaryBody += ((L '  · {0} — {1} / {2} / {3} {4}{7} → 최신 {5} ({6})' '  · {0} - {1} / {2} / {3} {4}{7} -> newer {5} ({6})') -f $od.Inf, $od.Provider, $od.Class, $od.File, $od.Version, $od.NewestVersion, $od.NewestInf, $devLabel)
        }
        $summaryBody += ((L '  삭제: {0}개' '  Deleted: {0}') -f $ods.Deleted)
        foreach ($od in @($ods.Candidates | Where-Object { $_.Deleted })) {
          $dlabel = if ($od.Device) { (L ' [장치: {0}]' ' [device: {0}]') -f $od.Device } else { '' }
          $summaryBody += ('    · ' + $od.Inf + $dlabel + ' ' + (L '삭제 완료' 'deleted'))
        }
        if ($ods.Skipped -gt 0) {
          $summaryBody += ((L '  삭제되지 않음: {0}개 — 확인해보세요. 직접 실행하여 삭제 질문에 y를 누르면 삭제됩니다.' '  Not deleted: {0} - Please review. Run the check manually and answer y at the delete prompt to remove them.') -f $ods.Skipped)
          foreach ($od in @($ods.Candidates | Where-Object { -not $_.Deleted })) {
            $dlabel = if ($od.Device) { (L ' [장치: {0}]' ' [device: {0}]') -f $od.Device } else { '' }
            $summaryBody += ('    · ' + $od.Inf + $dlabel + ' — ' + $od.Reason)
          }
        }
      }

      $report = @()
      $report += $summaryHead
      $report += $summaryLine
      $report += $summaryWhen
      $report += $summaryVersion
      $report += $summaryCounts
      if ($summarySlow) { $report += $summarySlow }
      $report += $summaryBody
      $report += ''
      $report += (L '[안내] 이 점검은 파일 백업을 하지 않습니다. 중요한 파일(사진/문서)은 별도로 백업하세요.' '[Note] This check does not back up files. Please back up important files (photos/documents) separately.')
      $report += '=================================================='
      $report += ''
      $report += (L '--- 상세 로그 (같은 내용을 기술적인 형태로) ---' '--- Detailed log (same information in technical form) ---')
      $report += "Timestamp: $(Get-Date -Format 'o')"
      $report += "Version: $kitVersionText"
      $report += ''

      # 로그 파일에서 이번 실행 분량만 추출
      $logContent = ''
      if (Test-Path -LiteralPath $logPath) {
        $rawContent = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
        $sections = @($rawContent -split '(?=\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' | Where-Object { $_ -match 'Starting maintenance' })
        $logContent = if ($sections.Count -gt 0) { $sections[-1] } else { $rawContent }
      }

      if ($logContent -match "Overall Status: (PASS|FAIL)") {
        $overallStatus = $Matches[1]
        $report += "Overall Status: $overallStatus"
        $report += ''

        # PASS/FAIL/WARN/CHANGE 라인만 추출하여 리포트에 포함
        $logLines = $logContent -split "`n"
        foreach ($line in $logLines) {
          if ($line -match "^\w.*: (PASS|FAIL|WARN|CHANGE)") {
            $report += $line.Trim()
          }
          elseif ($line -match "^\s+chkdsk:\s*\S" -or $line -match ":\s+의심 드라이버:\s*\S") {
            # 2026-11-16: FAIL/WARN 바로 다음에 붙는 상세 줄(차단 의심 드라이버, chkdsk 실제 출력)도 리포트에 남긴다.
            #   이전에는 들여쓰기 줄이라 필터에서 빠져, 친구 PC 리포트에 "왜 차단됐는지"가 하나도 없었다.
            $report += $line.Trim()
          }
        }

        if ($overallStatus -eq 'FAIL') {
          $report += ''
          $failureStart = $logContent.IndexOf('Failure Reasons:')
          if ($failureStart -ge 0) {
            $failureSection = $logContent.Substring($failureStart)
            $endMarker = $failureSection.IndexOf("`n`n")
            if ($endMarker -lt 0) { $endMarker = $failureSection.Length }
            $report += $failureSection.Substring(0, $endMarker).Trim()
          }
        }

        # 권장 사항(자동 복구 대신 기록만 하는 항목)도 리포트에 포함한다.
        #   PASS 로 끝나도 "확인해 볼 것"이 남아 있을 수 있는데, 기존 리포트는 PASS/FAIL/WARN 줄만 추출해 누락했다.
        #   각 블록은 "다음 블록 머리말"에서 끝낸다(2026-11-10) — 예전에는 Recommendations 블록이
        #   Auto Fixes/Ad Warnings 까지 삼켜서 같은 내용이 리포트에 3번 반복됐다.
        $recStart = $logContent.IndexOf('Recommendations:')
        if ($recStart -ge 0) {
          $recSection = $logContent.Substring($recStart)
          $recEnd = $recSection.Length
          foreach ($stop in @('Auto Fixes:', 'Ad Warnings:', 'Maintenance completed', '[SUMMARY_END]')) {
            $i = $recSection.IndexOf($stop)
            if ($i -gt 0 -and $i -lt $recEnd) { $recEnd = $i }
          }
          $report += ''
          $report += ($recSection.Substring(0, $recEnd)).Trim()
        }

        # 자동 조치 내역(문제 검출 → 자동 해결)도 리포트에 포함한다.
        $fixStart = $logContent.IndexOf('Auto Fixes:')
        if ($fixStart -ge 0) {
          $fixSection = $logContent.Substring($fixStart)
          $fixEnd = $fixSection.Length
          foreach ($stop in @('Ad Warnings:', 'Maintenance completed', '[SUMMARY_END]')) {
            $i = $fixSection.IndexOf($stop)
            if ($i -gt 0 -and $i -lt $fixEnd) { $fixEnd = $i }
          }
          $report += ''
          $report += ($fixSection.Substring(0, $fixEnd)).Trim()
        }

        # 광고 설정 주의(되돌리는 방법 포함)도 기술 로그에 남긴다.
        $adStart = $logContent.IndexOf('Ad Warnings:')
        if ($adStart -ge 0) {
          $adSection = $logContent.Substring($adStart)
          $adEnd = $adSection.Length
          foreach ($stop in @('Maintenance completed', '[SUMMARY_END]')) {
            $i = $adSection.IndexOf($stop)
            if ($i -gt 0 -and $i -lt $adEnd) { $adEnd = $i }
          }
          $report += ''
          $report += ($adSection.Substring(0, $adEnd)).Trim()
        }
      } else {
        $report += "Status: Maintenance completed (unable to parse detailed results)"
        $report += ''
        $report += $logContent
      }

      # v1.7.0: 영어 모드에서는 상세 로그에 남은 한글 문구까지 영어로 치환한다.
      if ($script:kitLang -ne 'ko') { $report = @($report | ForEach-Object { ConvertTo-EnglishReportLine -Line ([string]$_) }) }

      # 데스크톱에 쓰고, 항상 설치 폴더 logs\last-report.txt 에도 사본을 남긴다.
      #   (관리자 계정이 달라 사용자 바탕화면에 못 쓴 경우에도 결과를 찾을 수 있게)
      $savedPath = ''
      try {
        $report | Out-File -LiteralPath $desktopLogPath -Encoding UTF8
        $savedPath = $desktopLogPath
        Write-Output "Desktop maintenance report created: $desktopLogPath"
      } catch {
        Write-Output "Failed to create desktop log: $_"
      }
      try {
        $reportCopyPath = Join-Path $logDir 'last-report.txt'
        $report | Out-File -LiteralPath $reportCopyPath -Encoding UTF8
        if (-not $savedPath) { $savedPath = $reportCopyPath; Write-Output ((L '데스크톱에 저장하지 못해 사본을 남겼습니다: ' 'Could not save to desktop; kept a copy at: ') + $reportCopyPath) }
        else { Write-Output "Report copy: $reportCopyPath" }
      } catch {
        Write-Output "Failed to save report copy: $_"
      }

      # 3개월(기본 90일) 지난 리포트 자동 삭제 + 바탕화면 정리는 요약 단계 앞에서 수행한다(이번 리포트/JSON 기록에 포함되도록).
    } catch {
      Write-Output "Failed to create desktop log: $_"
    }
  }
}

# ============================================================
# 종료
# ============================================================

# cadence 기준이 되는 "마지막 완료 시각" 기록 (정상 완료 지점에서만)
Set-LastRunStamp

if ($allPass) {
  Write-Output 'Maintenance completed: ALL PASSED'
} else {
  Write-Output 'Maintenance completed: SOME CHECKS FAILED'
}

# v1.14.3: 종료 직전 피드백 안내 + A/Y/N 전송 선택.
#   사용자가 "검사가 끝나고 엔터를 누르면 자동으로 꺼진다"고 느끼는 지점에,
#   바탕화면 피드백 바로가기와 아래 선택으로 의견/점검 결과를 보내면
#   기능·문제 수정에 도움이 된다는 뉘앙스를 추가한다.
#   A=항상 자동(설정 저장) / Y=이번만 / N=안 보냄(기본). 예약 실행에서는 묻지 않는다.
Write-Output ''
Write-Output (L '--------------------------------------------------' '--------------------------------------------------')
Write-Output (L '검사가 끝났습니다.' 'Check finished.')
Write-Output (L '의견을 남기시고 싶으면 바탕화면의 "자동 유지보수 피드백"을 실행해 보고서와 함께 기능 추가·개선 방향을 남겨주세요.' 'To leave a comment, run "Auto Maintenance Feedback" on your Desktop and write feature requests or improvements along with the report.')
Write-Output (L '보내주신 의견은 기능 개선과 문제 수정에 큰 도움이 됩니다. 아래 선택은 보고서만 간편하게 보냅니다.' 'Your comments help improve features and fix problems. The choice below sends just the report.')

function Invoke-FeedbackUpload {
  $fb = Join-Path (Split-Path -Parent $scriptRoot) 'feedback.ps1'
  if (-not (Test-Path -LiteralPath $fb)) {
    Write-Output (L '피드백 파일(feedback.ps1)을 찾지 못했습니다.' 'feedback.ps1 not found.')
    return
  }
  Write-Output (L '피드백을 자동으로 보냅니다... (토큰 입력 불필요)' 'Sending feedback automatically... (no token entry needed)')
  try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fb -Yes -NoOpen 2>&1 | ForEach-Object { Write-Output $_ }
    Write-Output (L '피드백 전송 요청이 끝났습니다. 결과는 바탕화면 "자동유지보수_피드백상태.txt" 에도 기록됩니다.' 'Feedback upload finished. See "자동유지보수_피드백상태.txt" on the Desktop for the result.')
  } catch {
    Write-Output ((L '피드백 전송 실패: ' 'Feedback upload failed: ') + $_.Exception.Message)
  }
}

function Save-AutoFeedbackSetting {
  param([string]$Value)
  try {
    $cfgObj = if ($config) { $config } else { [ordered]@{} }
    if ($cfgObj -is [PSCustomObject]) {
      $cfgObj | Add-Member -NotePropertyName 'autoFeedback' -NotePropertyValue $Value -Force
    } else {
      $cfgObj['autoFeedback'] = $Value
    }
    $cfgObj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $script:config = $cfgObj
    Write-Output (L '앞으로 이 질문 없이 자동으로 보냅니다. (다시 묻려면 설정에서 autoFeedback 를 ask 로 바꾸세요)' 'Future checks will send automatically. (Set autoFeedback to "ask" in config.json to ask again)')
  } catch {
    Write-Output ((L '설정 저장 실패: ' 'Could not save setting: ') + $_.Exception.Message)
  }
}

if ($Mode -eq 'check') {
  $fbMode = [string](Get-ConfigProp $config 'autoFeedback')
  if ($fbMode -eq 'always') {
    Write-Output (L '자동 피드백 설정이 켜져 있습니다.' 'Automatic feedback is enabled.')
    Invoke-FeedbackUpload
  } else {
    Write-Output ''
    Write-Output (L '피드백을 보내시겠습니까?' 'Send feedback?')
    Write-Output (L '  A = 항상 자동 보내기 / Y = 이번만 보내기 / N = 보내지 않기 (기본 N)' '  A = always send / Y = send this time / N = do not send (default N)')
    try {
      $fbAnswer = (Read-Host (L '선택 [A/Y/N]' 'Choice [A/Y/N]')).Trim().ToUpperInvariant()
    } catch { $fbAnswer = '' }
    if ($fbAnswer -eq 'A') {
      Save-AutoFeedbackSetting -Value 'always'
      Invoke-FeedbackUpload
    } elseif ($fbAnswer -eq 'Y') {
      Invoke-FeedbackUpload
    } else {
      Write-Output (L '피드백을 보내지 않습니다. 의견이 있으면 바탕화면의 "자동 유지보수 피드백"을 눌러주세요.' 'Feedback skipped. Use "Auto Maintenance Feedback" on the Desktop if you have comments.')
    }
  }
}

# 창 자동 닫힘 처리 (check 모드에서만, closeBehavior=N이면 Enter 대기)
if ($Mode -eq 'check') {
  $doClose = (Get-ConfigProp $config 'closeBehavior') -in @('always', 'once')
  if (-not $doClose) {
    Write-Output ''
    if ((Get-ConfigProp $config 'enableLogging')) {
      Write-Output "로그 파일: $logPath (Ctrl+클릭으로 열기)"
    }
    Write-Output 'Press Enter to exit...'
    $null = Read-Host
  }
}

# 항상 exit 0 반환 (실패 내역은 로그/리포트에 기록됨)
Exit-Maintenance -ExitCode 0
