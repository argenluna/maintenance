# -*- coding: utf-8 -*-
# ============================================================
#  Auto Maintenance - 지금 점검
#  바탕화면 "자동 유지보수 점검" 바로가기가 실행하는 파일.
#  - 관리자 권한 자동 요청
#  - 6일 주기를 무시하고 즉시 점검(-Force)
#  - 끝나면 쉬운 말 요약 + 데스크톱 결과 파일 열기
#
#  2026-11-14 수정
#   - 관리자 권한으로 다시 띄울 때 "사용자 바탕화면" 경로를 -ReportTo 로 넘긴다.
#     (관리자 계정이 다르면 결과가 관리자 바탕화면에 생겨 사용자가 못 보던 문제)
#   - 점검 중 오류가 나도 창이 그냥 사라지지 않고, 안내 + 로그 경로를 보여주고 대기한다.
# ============================================================

param([string]$ReportTo = '')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sm = Join-Path $root 'Simple maintenance'
$wrapper = Join-Path $root 'run-maintenance.ps1'
$myDesktop = [Environment]::GetFolderPath('Desktop')

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

if (-not (Test-Admin)) {
  Write-Host '관리자 권한이 필요합니다. 확인 창에서 "예"를 누르세요...'
  try {
    # 원래(사용자) 바탕화면 경로를 그대로 넘겨 결과 파일이 항상 이 사용자 바탕화면에 생기게 한다.
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ReportTo "{1}"' -f $PSCommandPath, $myDesktop
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
  } catch {
    Write-Host '점검을 취소했습니다(관리자 권한 거부).'
    Start-Sleep -Seconds 2
  }
  exit
}

if ([string]::IsNullOrWhiteSpace($ReportTo)) { $ReportTo = $myDesktop }

if (-not (Test-Path $wrapper)) {
  Write-Host "오류: $wrapper 를 찾을 수 없습니다. 먼저 install.ps1 을 실행하세요."
  Read-Host 'Enter 키를 누르면 닫힙니다'
  exit 1
}

Write-Host ''
Write-Host '=========================================='
Write-Host '   자동 유지보수 점검 (지금 실행)'
Write-Host ("   {0}" -f $kitVersionText)
Write-Host '=========================================='
Write-Host ''
# 2026-11-16: 삭제 확인을 한 번만 묻도록 바꿨다(v1.2.0). 항목마다 묻던 안내 문구를 갱신한다.
Write-Host '※ 파일을 지워야 하는 항목이 있으면, 점검 시작할 때 지울 수 있는 항목을 한 번 보여주고'
Write-Host '   "한 번에 모두 지울까요? (y = 모두 지움 / n 또는 Enter = 모두 그대로 / s = 항목마다 따로 묻기)"'
Write-Host '   를 한 번만 물어봅니다. y 를 눌러야만 지웁니다. (s 를 고르면 예전처럼 항목마다 묻습니다)'
Write-Host ''
# 2026-11-17 (v1.3.0 / v1.4.0): 바탕화면이 결과 파일로 지저분해지지 않도록 자동 정리한다.
Write-Host '※ 결과 파일이 4개 이상 쌓이면 지난 결과 파일을 바탕화면의 "자동점검결과" 폴더로 모두 옮깁니다'
Write-Host '  (최신 것까지 옮기고, 이번 결과 1개만 바탕화면에 남습니다).'
Write-Host '※ 3개월(90일) 이상 지난 결과 파일은 묻지 않고 자동으로 삭제됩니다.'
Write-Host ''

$runError = $null
try {
  & $wrapper -Force -ReportTo $ReportTo
} catch {
  $runError = [string]$_.Exception.Message
  Write-Host ''
  Write-Host "[오류] 점검 실행 중 문제가 발생했습니다: $runError" -ForegroundColor Yellow
}
# --- 쉬운 말 요약 ---
$resPath = Join-Path $sm 'last-result.json'
$statusPath = Join-Path $root 'status.json'
$resultUnknown = $false
if (Test-Path $statusPath) {
  try {
    $st = Get-Content $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$st.result -eq 'unknown') { $resultUnknown = $true }
  } catch { }
}
Write-Host ''
if ($resultUnknown) {
  # 결과 파일이 새로 생기지 않은 경우(중복 실행/차단/오류)에는 지난 결과를 보여주지 않는다.
  Write-Host '※ 이번에는 점검이 완료되지 않았습니다.' -ForegroundColor Yellow
  Write-Host '   이전 점검이 아직 실행 중이었거나, 실행이 차단되었을 수 있습니다.'
  Write-Host '   바탕화면의 "자동유지보수_안내_…" / "자동유지보수_실패_…" 파일을 확인하세요.'
} elseif (Test-Path $resPath) {
  try {
    $r = Get-Content $resPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host '--------------- 결과 ---------------'
    if ($r.status -eq 'PASS') { Write-Host '결과: 정상 — 문제를 찾지 못했습니다.' }
    else { Write-Host '결과: 확인이 필요한 항목이 있습니다.' }
    Write-Host ("소요 시간: {0}초" -f $r.wallSeconds)
    if ($null -ne $r.PSObject.Properties['version'] -and $r.version) { Write-Host ("버전: {0}" -f $r.version) }
    $fixes = @($r.autoFixes)
    $recs = @($r.recommendations)
    if ($fixes.Count -gt 0) {
      Write-Host ''
      Write-Host '[자동으로 고친 것]'
      foreach ($f in $fixes) { Write-Host "  · $f" }
    }
    if ($recs.Count -gt 0) {
      Write-Host ''
      Write-Host '[직접 확인할 것]'
      foreach ($c in $recs) { Write-Host "  · $c" }
    }
    $adWarn = @()
    if ($null -ne $r.adWarnings) { $adWarn = @($r.adWarnings) }
    if ($adWarn.Count -gt 0) {
      Write-Host ''
      Write-Host '[광고 설정 주의 — 문제가 생기면 여기부터 확인하세요]' -ForegroundColor Yellow
      foreach ($w in $adWarn) { Write-Host "  ! $w" -ForegroundColor Yellow }
    }
    $delRev = @()
    if ($null -ne $r.deleteReview) { $delRev = @($r.deleteReview) }
    if ($delRev.Count -gt 0) {
      Write-Host ''
      Write-Host '[삭제 전 확인 목록 — 지우기 전에 보여준 파일 목록]'
      foreach ($x in $delRev) {
        Write-Host ("  · [{0}] {1}개 / {2} → {3}" -f $x.target, $x.count, $x.size, $x.decisionText)
        foreach ($nm in @($x.shown | Select-Object -First 5)) { Write-Host "      - $nm" }
        if ($x.more -gt 0) { Write-Host "      - ... 외 $($x.more)개" }
      }
    }
    if ($fixes.Count -eq 0 -and $recs.Count -eq 0) { Write-Host '고친 것도, 할 일도 없습니다.' }
    # 결과 파일 정리 내역 (2026-11-17, v1.4.0): 폴더로 옮긴 것 / 3개월 지나 자동 삭제한 것
    if ($null -ne $r.PSObject.Properties['desktopReportMove'] -and $r.desktopReportMove -and [int]$r.desktopReportMove.moved -gt 0) {
      Write-Host ''
      Write-Host '[바탕화면 정리 — 지난 결과 파일을 자동점검결과 폴더로]'
      Write-Host ("  · {0}개를 옮겼습니다 (최신 것까지 모두 옮김). 이번 결과 1개만 바탕화면에 남습니다." -f [int]$r.desktopReportMove.moved)
      if ($r.desktopReportMove.folder) { Write-Host ("  · 옮긴 곳: {0}" -f [string]$r.desktopReportMove.folder) }
    }
    if ($null -ne $r.PSObject.Properties['resultCleanup'] -and $r.resultCleanup -and [int]$r.resultCleanup.deleted -gt 0) {
      Write-Host ''
      Write-Host '[오래된 결과 파일 자동 삭제 — 되돌릴 수 없음]' -ForegroundColor Yellow
      Write-Host ("  · {0}일(3개월) 이상 지난 결과 파일 {1}개를 자동으로 지웠습니다." -f [int]$r.resultCleanup.retentionDays, [int]$r.resultCleanup.deleted)
      foreach ($dp in @($r.resultCleanup.paths)) { Write-Host ("      - $dp") }
    }
  } catch {
    Write-Host "결과 파일을 읽지 못했습니다: $($_.Exception.Message)"
  }
} else {
  Write-Host '결과 파일이 없습니다(점검이 완료되지 않았을 수 있습니다). 아래 로그를 확인하세요:'
  Write-Host ("  " + (Join-Path $sm 'logs\maintain-*.log'))
  Write-Host ("  " + (Join-Path $root 'logs\runner-*.log'))
}

# --- 결과 파일 열기 (정상/중단/안내 모두) ---
#   사용자 바탕화면 → 설치 폴더 logs\last-report.txt 순서로 찾는다.
#   (관리자 계정이 달라 바탕화면에 못 쓴 경우에도 결과를 보여주기 위함)
$latest = $null
foreach ($dir in @($ReportTo, $myDesktop, ([Environment]::GetFolderPath('Desktop')))) {
  if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path $dir)) { continue }
  # 2026-11-17 (v1.3.0): 결과 파일이 4개 이상이면 '자동점검결과' 폴더로 옮겨지므로 그 폴더도 함께 본다.
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
  Write-Host ''
  Write-Host "결과 파일: $($latest.FullName)"
  try { Invoke-Item $latest.FullName } catch { }
} else {
  Write-Host ''
  Write-Host '결과 파일을 찾지 못했습니다. 아래 로그를 확인하세요:'
  Write-Host ("  " + (Join-Path $sm 'logs\maintain-*.log'))
  Write-Host ("  " + (Join-Path $root 'logs\runner-*.log'))
}

Write-Host ''
Read-Host 'Enter 키를 누르면 닫힙니다'
