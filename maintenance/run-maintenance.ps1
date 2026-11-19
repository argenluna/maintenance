# OpenCode Maintenance Runner (Migration)
# Thin wrapper: checks cadence, delegates to "Simple maintenance\maintenance.ps1" with -Mode scheduled,
# then updates status.json (the cadence anchor for the next run).
#
# IMPORTANT: the scheduled task launches this with Windows PowerShell 5.1 (powershell.exe).
# Keep this file 5.1-compatible: no PS7-only syntax (ternary "? :", "??", "?.", "&&", "||").
# 2026-11-01: removed a PS7 ternary that made the whole script fail to parse in 5.1
#             (the scheduled task had therefore never actually run the maintenance).
# 2026-11-09: -Force = "지금 점검" 버튼용. 주기 게이트를 건너뛰고 즉시 실행한다(데스크톱 리포트 생성).

param([switch]$Force, [string]$ReportTo = '')

Set-StrictMode -Version Latest

# --- 인자 안전 조인 (PS 5.1 대응) ---
# 문자열 보간으로 만든 -ArgumentList 는 경로에 공백/따옴표/$ 가 있으면 쪼개지거나 재해석된다.
# 인자를 배열로 분리한 뒤 Windows 커맨드라인 규칙으로 이스케이프해 하나의 문자열로 조인한다.
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

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptRoot 'config.json'
$statusPath = Join-Path $scriptRoot 'status.json'
$psPath = Join-Path $scriptRoot 'Simple maintenance\maintenance.ps1'

# --- 버전 (2026-11-14) --- VERSION 파일(1줄: 버전, 2줄: 날짜)이 기준.
function Get-KitVersionText {
  try {
    $vf = Join-Path $scriptRoot 'VERSION'
    if (Test-Path -LiteralPath $vf) {
      $vlines = @(Get-Content -LiteralPath $vf -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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

function Load-JsonFile($path) {
  if (Test-Path -LiteralPath $path) {
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
  }
  return $null
}

function Get-Prop($obj, $name, $default) {
  if ($null -ne $obj) {
    $p = $obj.PSObject.Properties[$name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
  }
  return $default
}

# --- wrapper log (diagnostics for silent task runs) ---
$logDir = Join-Path $scriptRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$runnerLog = Join-Path $logDir ('runner-{0}.log' -f (Get-Date -Format 'yyyy-MM'))
function Write-RunnerLog([string]$msg) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Write-Output $line
  try { Add-Content -Path $runnerLog -Value $line -Encoding UTF8 } catch { }
}

Write-RunnerLog '--- run-maintenance start ---'
Write-RunnerLog "Kit version: $kitVersionText"

# --- config ---
$config = Load-JsonFile $configPath
if (-not $config) { Write-RunnerLog "ERROR config not found: $configPath"; exit 1 }
if ((Get-Prop $config 'maintenanceEnabled' $true) -eq $false) { Write-RunnerLog 'Maintenance disabled in config - exiting.'; exit 0 }

$cadenceHours = 144
$cadenceRaw = Get-Prop $config 'maintenanceCadenceHours' $null
if ($null -ne $cadenceRaw) {
  $parsed = 0.0
  if ([double]::TryParse([string]$cadenceRaw, [ref]$parsed)) { $cadenceHours = $parsed }
}
Write-RunnerLog "Cadence = ${cadenceHours}h"

# --- cadence check (status.json holds the previous successful start time) ---
$status = Load-JsonFile $statusPath
$lastRun = [DateTime]::MinValue
if ($status) {
  $stamp = Get-Prop $status 'timestamp' $null
  if ($stamp) { try { $lastRun = [DateTime]::Parse([string]$stamp) } catch { } }
}
$now = Get-Date
$elapsedHours = ($now - $lastRun).TotalHours
# Tolerance: maintenance.ps1 gates on the last *finish* time while this wrapper gates on the
# last *start* time. Without slack, a tick that lands exactly on the cadence gets skipped once more.
# Keep the file ASCII-only: PowerShell 5.1 reads BOM-less files as ANSI.
# Slack = min(2h, 10% of cadence).
$cadenceSlackHours = [math]::Min(2.0, $cadenceHours * 0.1)
$cadenceEffective = $cadenceHours - $cadenceSlackHours
if ($elapsedHours -lt $cadenceEffective -and -not $Force) {
  Write-RunnerLog ("Cadence not reached ({0}h < {1}h effective, cadence {2}h, last run {3}) - skipping." -f [math]::Round($elapsedHours, 2), [math]::Round($cadenceEffective, 2), $cadenceHours, $(if ($lastRun -eq [DateTime]::MinValue) { 'never' } else { $lastRun.ToString('yyyy-MM-dd HH:mm') }))
  exit 0
}
if ($Force) {
  # 2026-11-18 (v1.8.0): status.json 이 없으면 lastRun=DateTime.MinValue 라서
  #   "17758482h since last run"(약 2026년) 같은 숫자가 찍히던 문제를 고쳤다.
  $sinceText = if ($lastRun -eq [DateTime]::MinValue) { 'no previous run' } else { ('{0}h since last run' -f [math]::Round($elapsedHours, 2)) }
  Write-RunnerLog ("Force run requested - ignoring cadence ($sinceText)")
} else {
  Write-RunnerLog ("Cadence OK ({0}h since last run) - delegating to maintenance.ps1 -Mode scheduled" -f [math]::Round($elapsedHours, 2))
}

if (-not (Test-Path -LiteralPath $psPath)) { Write-RunnerLog "ERROR script not found: $psPath"; exit 1 }

# --- 새 버전 안내 (2026-11-19, v1.12.0) ---
#   직접 실행(-Force, run-now → wrapper)과 예약 실행 모두 이 한 곳에서만 표시한다.
#   run-now.ps1 에서는 알림을 제거했다(같은 실행에서 두 번 뜨는 것 방지).
#   cadence 통과 뒤에 두어, 건너뛰는 실행에서는 네트워크 조회/팝업이 발생하지 않는다.
#   수동(-Force)은 사용자가 선택할 때까지 기다리고, 자동 실행은 30초 뒤 취소로 닫힌다.
$updateCommon = Join-Path $scriptRoot 'update-common.ps1'
if (Test-Path -LiteralPath $updateCommon) {
  try {
    . $updateCommon
    $upd = Get-UpdateInfo -Root $scriptRoot -TimeoutSec 8
    if ($null -ne $upd) {
      $skipVer = Get-SkipVersion -Root $scriptRoot
      if ($skipVer -ne $upd.Latest.ToString()) {
        $autoClose = if ($Force) { 0 } else { 30 }
        Write-RunnerLog ("update notice: current v$($upd.Local), latest v$($upd.Latest), autoClose=$autoClose s")
        $choice = Show-UpdateNotice -UpdateInfo $upd -AutoCloseSeconds $autoClose
        Write-RunnerLog "update notice choice: $choice"
        if ($choice -eq 'skip') {
          Set-SkipVersion -Root $scriptRoot -Version $upd.Latest.ToString()
          Write-RunnerLog "update notice: v$($upd.Latest) added to skip list"
        } elseif ($choice -eq 'update') {
          # 업데이트는 설치 폴더를 교체하므로 현재 점검을 여기서 끝내고 별도 프로세스로 넘긴다.
          $updater = Join-Path $scriptRoot '업데이트.ps1'
          if (-not (Test-Path -LiteralPath $updater)) { $updater = Join-Path $scriptRoot 'update.ps1' }
          if (Test-Path -LiteralPath $updater) {
            $updArgs = Join-CliArgs @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updater)
            Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $updArgs | Out-Null
            Write-RunnerLog "update launched: $updater (ending this maintenance run)"
            exit 0
          }
          Write-RunnerLog 'WARN updater script not found - continuing maintenance'
        }
      } else {
        Write-RunnerLog "update notice: v$($upd.Latest) is in skip list"
      }
    }
  } catch {
    # 네트워크 실패/팝업 오류가 점검 자체를 막지 않도록 한다.
    Write-RunnerLog "WARN update notice skipped: $($_.Exception.Message)"
  }
}

# --- 콘솔 창 정책 (2026-11-17, v1.3.0 사용자 요청) ---
#   "유휴기간에는 cmd 창이 보이게 돌아가고, 사용 중에는 헤드리스로 결과 파일만 저장되게 해달라.
#    직접 실행하면 창이 보여야 한다."
#     - 직접 실행(-Force, '지금 점검' / 설치 첫 점검): 항상 보이게 — 지금 쓰고 있는 콘솔 창 그대로 사용
#     - 자동 실행 + 유휴(idleConsoleMinutes 이상 입력 없음): 새 창을 띄워 진행 상황을 보여준다
#     - 자동 실행 + 사용 중: 창을 숨기고(헤드리스) 결과 파일·로그만 남긴다
#   설정: 최상위 config.json 의 idleConsoleMinutes (0 = 항상 보이게, N = N분 이상 유휴면 보이게, 기본 5)
$idleConsoleMinutes = 5
$idleRaw = Get-Prop $config 'idleConsoleMinutes' $null
if ($null -ne $idleRaw) {
  $idleParsed = 0
  if ([int]::TryParse([string]$idleRaw, [ref]$idleParsed)) { $idleConsoleMinutes = $idleParsed }
}
if ($idleConsoleMinutes -lt 0) { $idleConsoleMinutes = 5 }

$idleSeconds = 0
try {
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  $idleSeconds = [int][Math]::Floor([System.Windows.Forms.SystemInformation]::IdleTime.TotalSeconds)
} catch { $idleSeconds = 0 }

$isIdle = $false
if ($idleConsoleMinutes -eq 0) { $isIdle = $true }
elseif ($idleSeconds -ge ($idleConsoleMinutes * 60)) { $isIdle = $true }

# -Force(직접 실행)는 무조건 보이게. 자동 실행은 유휴일 때만 보이게.
$showWindow = ($Force -or $isIdle)
if ($Force) {
  Write-RunnerLog 'console: visible (manual run)'
} elseif ($isIdle) {
  Write-RunnerLog ("console: visible (auto run, idle {0}min >= {1}min - user away)" -f [int][math]::Floor($idleSeconds / 60), $idleConsoleMinutes)
} else {
  Write-RunnerLog ("console: hidden (auto run, user active - idle {0}min < {1}min)" -f [int][math]::Floor($idleSeconds / 60), $idleConsoleMinutes)
}

# --- delegate ---
$exitCode = 1
$delegateStarted = (Get-Date).AddSeconds(-10)   # last-result.json must be newer than this
try {
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $psPath, '-Mode', 'scheduled')
  if ($Force) { $argList += '-SkipCadence' }
  # -Force = 사용자가 직접 누른 "지금 점검" → 삭제 전 목록을 보여주고 y/N 을 묻는다.
  #   예약 실행(주기 도달)에는 넘기지 않으므로, 물어볼 사람이 없을 때는 아무것도 지우지 않는다.
  if ($Force) { $argList += '-PromptForDelete' }
  # 2026-11-14: "지금 점검" 창이 사라지던 문제 수정.
  #   maintenance.ps1 은 scheduled 모드에서 콘솔 창을 숨기는데, 같은 콘솔을 쓰는
  #   run-now.ps1 창까지 숨겨져 사용자 눈에는 "잠깐 되다가 꺼졌다" 로 보였다.
  # 2026-11-17 (v1.3.0): 창을 보여주기로 한 경우(직접 실행 / 유휴)에는 항상 -NoHideConsole 을 넘겨
  #   maintenance.ps1 이 스스로 창을 숨기지 않게 한다(이중 판정으로 창이 사라지는 사고 방지).
  if ($showWindow) { $argList += '-NoHideConsole' }
  else { $argList += '-HideConsole' }
  # 사용자 바탕화면 경로를 넘겨 결과 메모장이 항상 사용자 바탕화면에 남게 한다.
  if (-not [string]::IsNullOrWhiteSpace($ReportTo)) {
    $argList += @('-ReportTo', $ReportTo)
  }
  $argLine = Join-CliArgs $argList
  Write-RunnerLog "launch: $argLine"
  if ($Force) {
    # 직접 실행: 사용자가 보고 있는 같은 콘솔 창에서 실행한다(창이 새로 생기지 않는다).
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argLine -NoNewWindow -Wait -PassThru
    $exitCode = $proc.ExitCode
  } elseif ($showWindow) {
    # 유휴 상태: 새 콘솔 창을 띄워 진행 상황이 보이게 한다.
    #   (예약 작업은 -WindowStyle Hidden 으로 이 스크립트를 띄우므로 -NoNewWindow 로는 창이 안 보인다.
    #    Start-Process 기본값은 새 콘솔 창을 만들며, 부모가 숨겨져 있어도 자식 창은 보인다 — 실측 확인.)
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argLine -Wait -PassThru
    $exitCode = $proc.ExitCode
  } else {
    # 사용 중: 콘솔 창을 **아예 만들지 않는다**(헤드리스). 결과 txt/json/로그만 남는다.
    #   -NoNewWindow 는 부모의 숨김 콘솔을 물려주는 것처럼 보이지만, 실측해 보면 새 콘솔 창이
    #   잠깐 보였다(visible=True). CreateNoWindow 는 창 핸들 자체가 0 이라 깜빡임이 없다.
    #   표준출력/표준에러는 logs\console-*.log 로 받아 두어 문제 추적이 가능하게 한다.
    $consoleLog = Join-Path $logDir ('console-{0}.log' -f (Get-Date -Format 'yyyy-MM'))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $headless = New-Object System.Diagnostics.Process
    $headless.StartInfo = $psi
    try {
      $null = $headless.Start()
      # 교착 방지: 한 스트림은 비동기로 읽는다.
      $errTask = $headless.StandardError.ReadToEndAsync()
      $stdoutText = $headless.StandardOutput.ReadToEnd()
      $stderrText = $errTask.Result
      $headless.WaitForExit()
      $exitCode = $headless.ExitCode
      try {
        $banner = '===== {0} headless run (exit {1}) =====' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $exitCode
        Add-Content -Path $consoleLog -Value (@($banner, $stdoutText, $stderrText) -join "`r`n") -Encoding UTF8
      } catch { }
      if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        $errFirst = (@($stderrText -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
        Write-RunnerLog ("headless stderr: {0}" -f $errFirst)
      }
    } finally {
      if ($headless) { try { $headless.Dispose() } catch { } }
    }
  }
  Write-RunnerLog "maintenance.ps1 finished with exit code $exitCode"
} catch {
  Write-RunnerLog "ERROR launching maintenance.ps1: $($_.Exception.Message)"
  $exitCode = 1
}

# --- status.json update (timestamp = this run start, used by the next cadence check) ---
$maintLog = Join-Path (Join-Path $scriptRoot 'Simple maintenance\logs') ('maintain-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))

# maintenance.ps1 always exits 0 (failures are reported in the log), so read the structured
# result file it writes instead. Ignore a stale file from a previous run.
$maintResultPath = Join-Path $scriptRoot 'Simple maintenance\last-result.json'
$resultStatus = 'unknown'
$resultReasons = @()
$resultWallSec = $null
$resultFixes = @()
$resultRecs = @()
$freshResult = $false
if (Test-Path -LiteralPath $maintResultPath) {
  try {
    $r = Get-Content -LiteralPath $maintResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rTs = [DateTime]::MinValue
    if ($r.timestamp) { try { $rTs = [DateTime]::Parse([string]$r.timestamp) } catch { } }
    # Must be NEWER than this run's start. A loose "-1 minute" window could report the previous
    # run's result when the delegated run exits immediately (e.g. mutex skip).
    if ($rTs -ge $delegateStarted) {
      $freshResult = $true
      if ($r.status) { $resultStatus = [string]$r.status }
      if ($r.failureReasons) { $resultReasons = @($r.failureReasons) }
      if ($null -ne $r.wallSeconds) { $resultWallSec = $r.wallSeconds }
      if ($r.autoFixes) { $resultFixes = @($r.autoFixes) }
      if ($r.recommendations) { $resultRecs = @($r.recommendations) }
    }
  } catch { }
}

# 2026-11-14: 점검이 결과 파일조차 남기지 못한 경우(중복 실행으로 즉시 종료, 스크립트 오류,
#   백신/정책 차단 등) 사용자는 "프로그램이 그냥 꺼졌다" 고만 느낀다. 수동 실행이면
#   바탕화면에 무슨 일이 있었는지 적은 안내 파일을 남긴다.
if ($Force -and -not $freshResult) {
  Write-RunnerLog 'WARN - 점검 결과 파일이 새로 생기지 않았습니다(중단/차단/중복 실행 가능성).'
  try {
    $noteDir = ''
    if (-not [string]::IsNullOrWhiteSpace($ReportTo) -and (Test-Path -LiteralPath $ReportTo)) { $noteDir = $ReportTo }
    else { $noteDir = [Environment]::GetFolderPath('Desktop') }
    if (-not [string]::IsNullOrWhiteSpace($noteDir) -and (Test-Path -LiteralPath $noteDir)) {
      # maintenance.ps1 이 이미 '점검 중단' 리포트를 남겼다면 안내 파일을 또 만들지 않는다.
      $failReport = Get-ChildItem -Path $noteDir -Filter '자동유지보수_실패_*.txt' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $delegateStarted } | Select-Object -First 1
      if ($failReport) {
        Write-RunnerLog "failure report already written: $($failReport.FullName)"
      } else {
        $noteFile = Join-Path $noteDir ("자동유지보수_안내_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".txt")
        $note = @()
        $note += '================ 자동 유지보수 — 점검이 완료되지 않았습니다 ================'
        $note += ('실행: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
        $note += ('버전: ' + $kitVersionText)
        $note += ''
        $note += '점검이 결과 파일을 남기지 못했습니다. 가능한 원인:'
        $note += '  1) 이전 점검이 아직 실행 중이어서 이번 실행이 건너뛰어졌습니다'
        $note += '     → 1~2분 기다린 뒤 다시 눌러보세요.'
        $note += '  2) 백신/보안 프로그램이 스크립트 실행을 막았습니다'
        $note += '     → Windows 보안 → 보호 기록에서 "차단" 항목을 확인하세요.'
        $note += '  3) 관리자 권한 확인 창에서 "아니오" 를 눌렀습니다.'
        $note += ''
        $note += ('종료 코드: ' + $exitCode)
        $note += ''
        $note += '로그 파일(이 파일을 함께 보내주시면 원인을 확인할 수 있습니다):'
        $note += ('  ' + $runnerLog)
        if (Test-Path -LiteralPath (Split-Path -Parent $maintLog)) { $note += ('  ' + (Split-Path -Parent $maintLog) + '\maintain-*.log') }
        $note += ''
        $note += '※ 파일 삭제·설정 변경은 실행되지 않았습니다(중단됨).'
        $note | Out-File -LiteralPath $noteFile -Encoding UTF8
        Write-RunnerLog "no-result note written: $noteFile"
      }
    }
  } catch {
    Write-RunnerLog "WARN could not write no-result note: $($_.Exception.Message)"
  }
}

$runStatus = 'completed'
if ($exitCode -ne 0) { $runStatus = 'completed_with_issues' }
elseif ($resultStatus -eq 'FAIL') { $runStatus = 'failed' }
elseif ($resultStatus -eq 'PASS') { $runStatus = 'passed' }

$newStatus = [PSCustomObject]@{
  timestamp      = $now.ToString('o')
  finishedAt     = (Get-Date).ToString('o')
  version        = $kitVersionText
  status         = $runStatus
  result         = $resultStatus
  failureReasons = $resultReasons
  autoFixes      = $resultFixes
  recommendations = $resultRecs
  wallSeconds    = $resultWallSec
  exitCode       = $exitCode
  log            = $(if (Test-Path -LiteralPath $maintLog) { $maintLog } else { '' })
  runner         = 'run-maintenance.ps1'
}
if ($resultStatus -eq 'FAIL') {
  $firstReason = if ($resultReasons.Count -gt 0) { [string]$resultReasons[0] } else { 'see log' }
  Write-RunnerLog ("maintenance result: FAIL - {0}" -f $firstReason)
} else {
  Write-RunnerLog ("maintenance result: {0} (wall {1}s)" -f $resultStatus, $(if ($null -ne $resultWallSec) { $resultWallSec } else { '?' }))
}
if ($resultFixes.Count -gt 0) {
  Write-RunnerLog ("auto fixes applied: {0} - {1}" -f $resultFixes.Count, (($resultFixes | Select-Object -First 3) -join ' | '))
}
try {
  $newStatus | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statusPath -Encoding UTF8
  Write-RunnerLog "status.json updated ($($newStatus.status))"
} catch {
  Write-RunnerLog "WARN could not update status.json: $($_.Exception.Message)"
}

Write-RunnerLog '--- run-maintenance end ---'
exit $exitCode
