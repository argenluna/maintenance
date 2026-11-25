# -*- coding: utf-8 -*-
# ============================================================
#  Auto Maintenance - 버전 안내 (Ulanzi 버튼용)
#  Ulanzi 플러그인의 '버전 안내' 버튼이 실행하는 파일 (바탕화면 바로가기 없음).
#  - Ulanzi 버튼 화면용 3줄만 txt 로 저장한다 (플러그인이 이 값을 읽음)
#  - 비교 내용은 HTML 표로 만들어 기본 브라우저에서 연다 (임시 폴더에만 생성, 바탕화면에 남기지 않음)
#  - 읽기 전용: 설치본·예약 작업·설정은 절대 바꾸지 않는다
# ============================================================
param([switch]$NoOpen, [switch]$NoWriteButtonFile)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
# 확인용 생성 파일은 Z:\opencode 에만 만든다 (바탕화면에는 만들지 않음).
$outDir = 'Z:\opencode'
if (-not (Test-Path -LiteralPath $outDir)) { $outDir = $env:TEMP }

function L([string]$ko, [string]$en) {
  try {
    if ([Globalization.CultureInfo]::CurrentUICulture.Name -like 'ko*') { return $ko }
    if ([Globalization.CultureInfo]::CurrentCulture.Name -like 'ko*') { return $ko }
  } catch { }
  return $en
}

# --- 현재 버전 (VERSION 파일이 유일 기준) ---
function Get-CurrentVersion {
  $vf = Join-Path $root 'VERSION'
  $lines = @(Get-Content -LiteralPath $vf -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $v = ([string]$lines[0]).Trim()
  $d = if ($lines.Count -ge 2) { ([string]$lines[1]).Trim() } else { '' }
  return [pscustomobject]@{ Ver = $v; Date = $d }
}

# --- 예약 슬롯 (UPDATE_SCHEDULE.md 의 W1~W4 / M1 행) ---
# 버전 규칙: 오류·문구=PATCH, 기능·동작=MINOR, 구조=MAJOR.
# 현재 1.18.1(W1 구현 + 긴급 수정) → 예약 W2는 1.19.0, 이후 W3~W8은 1.20.0~1.25.0으로 MINOR씩 밀어 표시한다.
function Get-ScheduleRows {
  $p = Join-Path $root 'UPDATE_SCHEDULE.md'
  $rows = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $p)) { return @($rows) }
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ($line -match '^\|\s*(W\d+|M1)\s*\|') {
      $cells = @($line -split '\|' | ForEach-Object { $_.Trim() })
      if ($cells.Count -ge 5) {
        $parsed = $null
        $raw = [string]$cells[3]
        $candidate = ((($raw -replace '^\*{0,2}\s*v\s*', '') -replace '\*+$', '').Trim())
        if ($candidate -match '^\d+\.\d+\.\d+$') { [void][version]::TryParse($candidate, [ref]$parsed) }
        $descRaw = (([string]$cells[4]) -replace '　', ' ')
        $descLines = @($descRaw -split '<br\s*/?>' | ForEach-Object { (($_ -replace '^\s*(?:·|[+~*](?!\*))\s*', '') -replace '\*\*|`', '').Trim() } | Where-Object { $_.Length -gt 0 })
        [void]$rows.Add([pscustomobject]@{
          Slot = $cells[1]; Date = $cells[2]; Ver = $raw; Parsed = $parsed
          Desc = ($descLines -join ' · ')
          DescLines = $descLines
          Status = $(if ($cells.Count -ge 6) { $cells[5] } else { '' })
        })
      }
    }
  }
  return @($rows)
}

# --- 다음 버전 불릿을 추가/변경/기타로 분류 ---
function Get-FeatureGroup {
  param([string]$Text)
  $t = [string]$Text
  if ($t -match '추가|신규|새로|도입|appended|Added|New') { return (L '추가된 기능' 'Added features') }
  if ($t -match '변경|개선|수정|고침|강화|확장|대응|통합|조정|개편|보완|일반화|분리|대체|구체화|적용|Changed|Improved') { return (L '변경 기능' 'Changed features') }
  return (L '기타' 'Other')
}

# --- 원문 설명을 ' · ' 기준 불릿 조각으로 나누기 ---
function Get-DescriptionParts {
  param([string]$Text)
  $t = [string]$Text
  $t = $t -replace '\*\*|__|`', ''
  $t = $t -replace '^\s*우선처리\s*:\s*', ''
  $t = [regex]::Replace($t, '\s+', ' ').Trim()
  $parts = @($t -split '\s+·\s+' | ForEach-Object { ($_ -replace '^\s*[·+~*]\s*', '').Trim() } | Where-Object { $_.Length -ge 2 })
  return @($parts)
}

# --- 현재 버전 설명 원문 (README 버전 표) ---
function Get-CurrentRawDescription {
  param([string]$Version)
  $p = Join-Path $root 'README.md'
  if (-not (Test-Path -LiteralPath $p)) { return '' }
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ($line -match ('^\|\s*' + [regex]::Escape($Version) + '\s*\|')) {
      $cells = @($line -split '\|' | ForEach-Object { $_.Trim() })
      if ($cells.Count -ge 4) { return $cells[3] }
    }
  }
  # 로컬 카나리 버전은 README에 아직 올라가기 전이라 행이 없다.
  # 이 경우 공개 예약표(UPDATE_SCHEDULE.md)의 해당 버전 행을 써서
  # "전 버전 대비 현재 기능 변경점"을 채운다. 예: v1.16.0 → 1.18.1 의 7건(긴급 수정 + A/Y/N/X 개정 포함).
  $row = @(Get-ScheduleRows | Where-Object { (($_.Ver -replace '^v', '').Trim()) -eq $Version } | Select-Object -First 1)
  if ($row.Count -gt 0) { return $row[0].Desc }
  return ''
}

# --- 현재 기능 전체 (README 의 "자동으로 하는 것" + "검사 항목" 표) ---
# 버전 이력·패치 노트·사용자가 건든 항목은 쓰지 않는다.
function Get-CurrentFeatureLines {
  $p = Join-Path $root 'README.md'
  if (-not (Test-Path -LiteralPath $p)) { return @() }
  $out = New-Object System.Collections.ArrayList
  # 단계별 짧은 설명 (초보자 비유가 아니라 기능 자체를 설명한다)
  $desc = @{
    OS          = '운영체제 버전·빌드 확인'
    CPU         = '프로세서 모델 확인'
    MEMORY      = '설치된 메모리 용량 확인'
    DISK        = '디스크 여유 공간 확인'
    SERVICE     = '주요 서비스 실행 상태 확인'
    VSS         = '볼륨 섀도 복사 서비스 확인'
    DISKHEALTH  = '디스크 SMART·건강 상태 확인'
    SYSFIX      = '시스템 설정 이상 확인'
    SECUREBOOT  = '보안 부팅 활성화 확인'
    RECOVERY    = 'WinRE 복구 환경 확인'
    WMI         = 'WMI 리포지토리 무결성 확인'
    CERTSTORE   = '인증서 만료 여부 확인'
    TASKHEALTH  = '예약 작업 생존 여부 확인'
    GPU         = '그래픽 카드 정보 확인'
    BATTERY     = '노트북 배터리 마모 확인'
    WHEA        = '하드웨어 오류 이벤트 확인'
    DRIVERSTORE = '드라이버 저장소 용량 확인'
    BROWSERCACHE = '오래된 브라우저 캐시 확인'
    HOSTFILE    = 'hosts 파일 변조 확인'
    DNS         = 'DNS 설정·캐시 확인'
    ADQUIET     = '광고·추천 설정 확인'
    ADFILTER    = '광고 도메인 차단 상태 확인'
    NETWORK     = '네트워크 어댑터 상태 확인'
    GHOSTDEV    = '유령 장치 확인'
    PKGCACHE    = 'pip·conda 캐시 용량 확인'
    STARTUP     = '시작 프로그램 목록 확인'
    RECYCLEBIN  = '휴지통 보관 항목 확인'
    REGHIVE     = '레지스트리 하이브 용량 확인'
    BSOD        = '블루스크린 덤프 확인'
    OLDDRIVERS  = '이전 버전 드라이버 잔존 확인'
    DEFRAG      = '디스크 최적화 예약 상태 확인'
    CHKDSK      = '파일 시스템 오류 검사'
    SFC         = '시스템 파일 무결성 검사'
    WINSXS      = 'WinSxS 구성 요소 저장소 확인'
    TIMESYNC    = '시각 동기화 상태 확인'
    STABILITY   = '최근 시스템 오류 이력 확인'
    BOOTPERF    = '부팅 시간 추이 확인'
    UPDATES     = 'Windows 업데이트·Defender 상태 확인'
    AUTOHEAL    = '반복 오류 자동 복구 이력 확인'
  }
  $inAuto = $false
  $inCheck = $false
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ($line -match '^\*\*자동으로 하는 것') { $inAuto = $true; continue }
    if ($line -match '^\*\*자동으로 하지 않는 것') { $inAuto = $false }
    if ($line -match '^###\s') { $inCheck = $false }
    if ($line -match '^##\s') {
      $inCheck = [bool]($line -match '검사 항목')
      $inAuto = $false
    }
    if ($inAuto -and $line -match '^\s*-\s+') {
      $t = $line -replace '^\s*-\s+', ''
      $t = $t -replace '\*\*|__|`', ''
      $t = [regex]::Replace([string]$t, '\s+', ' ').Trim()
      if ($t.Length -gt 0 -and -not $out.Contains($t)) { [void]$out.Add($t) }
    }
    if ($inCheck -and $line -match '^\|') {
      $cells = @($line -split '\|' | ForEach-Object { $_.Trim() })
      if ($cells.Count -ge 4 -and $cells[2] -ne '단계' -and $cells[2] -notmatch '^[-:]+$') {
        # 괄호 안의 쉼표(예: `chkdsk /scan`, 모든 NTFS 볼륨)는 쪼개지 않는다.
        foreach ($it in ([regex]::Split($cells[2], '[,·]\s*(?![^()]*\))'))) {
          $t = $it -replace '\*\*|__|`', ''
          $t = [regex]::Replace([string]$t, '\s+', ' ').Trim()
          if ($t.Length -eq 0) { continue }
          if ($t -match '\s+[—–]\s+') {
            if (-not $out.Contains($t)) { [void]$out.Add($t) }
            continue
          }
          $name = ($t -split '\s*\(')[0].Trim()
          $d = ''
          if ($name -match '정품') { $d = 'Windows 정품 인증 상태 확인' }
          else {
            $key = ($name -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
            if ($desc.ContainsKey($key)) { $d = $desc[$key] }
          }
          if ($d.Length -gt 0) { $t = $t + ' — ' + $d }
          if (-not $out.Contains($t)) { [void]$out.Add($t) }
        }
      }
    }
  }
  return @($out)
}

# --- 로컬 전용 이후 계획(W2~W8) — GH 미공개, 로컬 확인용 HTML에만 표시 ---
function Get-LocalPlannedRows {
  $p = Join-Path $root 'research\next\_REORG_PLAN_BY_PRIORITY.md'
  $out = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $p)) { return @($out) }
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ($line -match '^\|\s*\*\*(W\d+)\*\*\s*\(([^)]+)\)\s*\|') {
      $slot = $Matches[1]
      $date = $Matches[2]
      $cells = @($line -split '\|' | ForEach-Object { $_.Trim() })
      $grade = if ($cells.Count -ge 3) { $cells[2] } else { '' }
      $assign = if ($cells.Count -ge 4) { $cells[3] } else { '' }
      $assign = ($assign -replace '<br\s*/?>', ' · ') -replace '\*\*|`', ''
      $assign = [regex]::Replace([string]$assign, '\s+', ' ').Trim()
      $n = 0
      if ([int]::TryParse(($slot -replace 'W', ''), [ref]$n)) {
        $ver = '1.' + (17 + $n) + '.0'   # W2=1.19.0 ~ W8=1.25.0
      } else { $ver = '' }
      [void]$out.Add([pscustomobject]@{ Slot = $slot; Date = $date; Ver = $ver; Grade = $grade; Assign = $assign })
    }
  }
  return @($out)
}

function HE([string]$s) { return [System.Net.WebUtility]::HtmlEncode([string]$s) }

$cur = Get-CurrentVersion
$curV = $null
[void][version]::TryParse($cur.Ver, [ref]$curV)
$sched = @(Get-ScheduleRows)
$cands = @($sched | Where-Object {
    $null -ne $_.Parsed -and $null -ne $curV -and $_.Parsed -gt $curV
  } | Sort-Object Parsed)
$next = if ($cands.Count -gt 0) { $cands[0] } else { $null }
# 로컬 카나리가 다음 주 버전을 먼저 돌리는 동안에는 공개 예약표에 현재 버전이 남지 않는다.
# 이때는 로컬 전용 재배정표(W2~W8)에서 그 다음 주 버전을 예약으로 이어 붙인다.
# 예: VERSION=1.18.1(다음 주 11/28 본배포 예정) → 예약 1.19.0(다다음 주 12/05).
$localRows = @(Get-LocalPlannedRows)
if ($null -eq $next) {
  $localCands = @($localRows | Where-Object {
    $lv = $null
    [void][version]::TryParse([string]$_.Ver, [ref]$lv)
    $null -ne $lv -and $null -ne $curV -and $lv -gt $curV
  } | Sort-Object { [version]$_.Ver })
  if ($localCands.Count -gt 0) {
    $lp = $localCands[0]
    $next = [pscustomobject]@{
      Slot = $lp.Slot; Date = $lp.Date; Ver = $lp.Ver; Parsed = [version]$lp.Ver
      Desc = $lp.Assign; DescLines = @($lp.Assign); Status = '로컬 전용'
    }
  }
}
$nextVer = if ($null -ne $next) { (($next.Ver -replace '^v', '').Trim()) } else { (L '없음' 'none') }
$count = $sched.Count

# --- Ulanzi 버튼 화면용 3줄 (플러그인이 읽는 유일한 txt) ---
$btn = (L '현재 v.' 'Current v.') + ' ' + $cur.Ver + "`n" +
       (L '예약 v.' 'Scheduled v.') + ' ' + $nextVer + "`n" +
       (L '예약수량' 'Scheduled count') + ' ' + $count + (L '개(' ' items(') + $count + (L '주)' ' weeks)')
$btnPath = Join-Path $outDir '자동유지보수_버튼화면.txt'
if (-not $NoWriteButtonFile) {
  [IO.File]::WriteAllText($btnPath, $btn, (New-Object System.Text.UTF8Encoding($false)))
}

# --- HTML 표 (기본 보기) — 버튼 3줄 파일과 같은 폴더(Z:\opencode)에만 만든다 ---
$htmlPath = Join-Path $outDir '자동유지보수_버전안내.html'
# 3열: 현재 기능(전부) / 현재 기능 변경점 / 다음 버전 변경점
# 로컬 화면용 제목은 원래 유지. GH 게시용만 "다음 버전 변경 예정점" + 영문 병기로 별도 작성.
$curParts = @(Get-CurrentFeatureLines)
if ($curParts.Count -eq 0) { $curParts = @(Get-DescriptionParts -Text (Get-CurrentRawDescription -Version $cur.Ver)) }
$curRows = New-Object System.Collections.ArrayList
foreach ($p in @(Get-DescriptionParts -Text (Get-CurrentRawDescription -Version $cur.Ver))) {
  $g = Get-FeatureGroup -Text $p
  if ($g -eq (L '추가된 기능' 'Added features')) { $cls = 'add'; $mk = '+' }
  elseif ($g -eq (L '변경 기능' 'Changed features')) { $cls = 'chg'; $mk = '~' }
  else { $cls = 'etc'; $mk = '*' }
  [void]$curRows.Add([pscustomobject]@{ Cls = $cls; Mark = $mk; Text = $p })
}
$nextRows = New-Object System.Collections.ArrayList
if ($null -ne $next) {
  foreach ($p in @(Get-DescriptionParts -Text $next.Desc)) {
    $g = Get-FeatureGroup -Text $p
    if ($g -eq (L '추가된 기능' 'Added features')) { $cls = 'add'; $mk = '+' }
    elseif ($g -eq (L '변경 기능' 'Changed features')) { $cls = 'chg'; $mk = '~' }
    else { $cls = 'etc'; $mk = '*' }
    [void]$nextRows.Add([pscustomobject]@{ Cls = $cls; Mark = $mk; Text = $p })
  }
}
$h = New-Object System.Collections.ArrayList
[void]$h.Add('<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8">')
[void]$h.Add('<title>자동 유지보수 - 버전 안내</title>')
[void]$h.Add('<style>')
[void]$h.Add('body{font-family:"Malgun Gothic",system-ui,sans-serif;margin:24px;color:#222}')
[void]$h.Add('h1{font-size:20px;margin:0 0 4px} .sub{color:#666;font-size:13px;margin-bottom:16px} h2{font-size:15px;margin:20px 0 8px}')
[void]$h.Add('table{border-collapse:collapse;width:100%;max-width:1100px;table-layout:fixed;margin-bottom:16px}')
[void]$h.Add('th,td{border:1px solid #c8c8c8;padding:8px 10px;vertical-align:top;font-size:13px;line-height:1.55;word-break:break-word}')
[void]$h.Add('th{background:#eef3f8;text-align:left}')
[void]$h.Add('.add{color:#0a7d23;font-weight:bold} .chg{color:#9a6700;font-weight:bold} .etc{color:#666;font-weight:bold} .cur{color:#444}')
[void]$h.Add('pre{font-family:Consolas,monospace;font-size:13px;background:#f7f7f7;padding:10px;border:1px solid #ddd}')
[void]$h.Add('</style></head><body>')
[void]$h.Add('<h1>자동 유지보수 - 버전 안내</h1>')
[void]$h.Add('<div class="sub">현재 v' + (HE $cur.Ver) + ' → 다음 v' + (HE $nextVer) + ' · 생성 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '</div>')
[void]$h.Add('<table><colgroup><col style="width:34%"><col style="width:33%"><col style="width:33%"></colgroup>')
[void]$h.Add('<tr><th>현재 기능<br>v' + (HE $cur.Ver) + ' · ' + (HE $cur.Date) + '</th><th>현재 기능 변경점<br>v' + (HE $cur.Ver) + ' (← 직전 버전 대비)</th><th>다음 버전 변경점<br>v' + (HE $nextVer) + ' · ' + (HE $(if ($next) { $next.Date } else { '' })) + '</th></tr>')
$rowsN = [Math]::Max($curParts.Count, [Math]::Max($curRows.Count, $nextRows.Count))
for ($i = 0; $i -lt $rowsN; $i++) {
  $c1 = if ($i -lt $curParts.Count) { '<span class="cur">·</span> ' + (HE $curParts[$i]) } else { '&nbsp;' }
  $c2 = if ($i -lt $curRows.Count) { '<span class="' + $curRows[$i].Cls + '">' + $curRows[$i].Mark + '</span> ' + (HE $curRows[$i].Text) } else { '&nbsp;' }
  $c3 = if ($i -lt $nextRows.Count) { '<span class="' + $nextRows[$i].Cls + '">' + $nextRows[$i].Mark + '</span> ' + (HE $nextRows[$i].Text) } else { '&nbsp;' }
  [void]$h.Add('<tr><td>' + $c1 + '</td><td>' + $c2 + '</td><td>' + $c3 + '</td></tr>')
}
[void]$h.Add('</table>')
[void]$h.Add('<h2>버튼 화면 3줄</h2><pre>' + (HE $btn) + '</pre>')
[void]$h.Add('<h2>예약 일정 - ' + $count + '건</h2>')
[void]$h.Add('<table><colgroup><col style="width:8%"><col style="width:18%"><col style="width:10%"><col style="width:64%"></colgroup>')
[void]$h.Add('<tr><th>슬롯</th><th>날짜</th><th>버전</th><th>내용</th></tr>')
foreach ($r in $sched) {
  $d = (@($r.DescLines | ForEach-Object { HE $_ }) -join '<br>')
  [void]$h.Add('<tr><td>' + (HE $r.Slot) + '</td><td>' + (HE $r.Date) + '</td><td>' + (HE $r.Ver) + '</td><td>' + $d + '</td></tr>')
}
[void]$h.Add('</table>')
if ($localRows.Count -gt 0) {
  [void]$h.Add('<h2>로컬 전용 — 이후 계획 (W2~W8 · GH 미공개)</h2>')
  [void]$h.Add('<table><colgroup><col style="width:7%"><col style="width:11%"><col style="width:10%"><col style="width:9%"><col style="width:63%"></colgroup>')
  [void]$h.Add('<tr><th>슬롯</th><th>날짜</th><th>버전</th><th>등급</th><th>배정 (실행 순서)</th></tr>')
  foreach ($r in $localRows) {
    [void]$h.Add('<tr><td>' + (HE $r.Slot) + '</td><td>' + (HE $r.Date) + '</td><td>' + (HE $r.Ver) + '</td><td>' + (HE $r.Grade) + '</td><td>' + (HE $r.Assign) + '</td></tr>')
  }
  [void]$h.Add('</table>')
}
[void]$h.Add('</body></html>')
[IO.File]::WriteAllText($htmlPath, ($h -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

$openLog = Join-Path $env:TEMP 'winter_version_open.log'
if (-not $NoOpen) {
  try {
    # Ulanzi 플러그인은 자식 프로세스를 정리(JOB)한다. WMI 로 만들면 그 밖에서 시작돼 브라우저가 유지된다.
    $cmd = 'rundll32.exe url.dll,FileProtocolHandler "' + $htmlPath + '"'
    $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
    Start-Sleep -Milliseconds 1200
    $alive = if ($res.ProcessId -and (Get-Process -Id $res.ProcessId -ErrorAction SilentlyContinue)) { 'alive' } else { 'GONE' }
    [IO.File]::AppendAllText($openLog, (Get-Date -Format 'HH:mm:ss') + " HTML rc=$($res.ReturnValue) pid=$($res.ProcessId) $alive`r`n")
  } catch {
    [IO.File]::AppendAllText($openLog, (Get-Date -Format 'HH:mm:ss') + " ERROR $($_.Exception.Message)`r`n")
  }
} else {
  [IO.File]::AppendAllText($openLog, (Get-Date -Format 'HH:mm:ss') + " SKIP -NoOpen`r`n")
}
Write-Host ('버전 안내 HTML: ' + $htmlPath)
