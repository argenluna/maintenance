# -*- coding: utf-8 -*-
# ============================================================
#  Auto Maintenance - 피드백 내보내기 (마스킹)
#  바탕화면 "자동 유지보수 피드백" 바로가기가 실행하는 파일.
#
#  v1.4.0 (2026-11-17) 추가
#  - 원본 결과 txt 를 그대로 올리면 사용자명· hosts 차단 도메인·하드웨어
#    정보가 그대로 노출된다. 이 스크립트는 민감정보를 마스킹한 요약을 만들어
#    메모장으로 연다. 사용자가 확인/편집한 뒤 직접 GitHub Discussion 에 붙여넣는다.
#  - 네트워크로 자동 전송하는 코드는 없다(업로드는 사용자가 직접 한다).
#  - PowerShell 5.1 호환 / UTF-8 BOM 필수.
#
#  사용법:
#    feedback.ps1                 : 최신 결과를 마스킹해서 메모장으로 열기
#    feedback.ps1 -NoOpen         : 파일만 만들고 열지 않기
#    feedback.ps1 -SelfTest       : 마스킹 규칙 자체 검사 (CI/수동 검증용)
# ============================================================

param(
  [switch]$NoOpen,
  [switch]$SelfTest,
  [string]$ResultPath = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$desktop = [Environment]::GetFolderPath('Desktop')

# --- 버전: VERSION 파일(1줄=버전, 2줄=날짜) 기준 ---
function Get-KitVersionText {
  try {
    $vf = Join-Path $root 'VERSION'
    if (Test-Path -LiteralPath $vf) {
      $vlines = @(Get-Content -LiteralPath $vf -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($vlines.Count -ge 1) {
        $v = ([string]$vlines[0]).Trim()
        if ($vlines.Count -ge 2) { return ('v' + $v + ' (' + ([string]$vlines[1]).Trim() + ')') }
        return ('v' + $v)
      }
    }
  } catch { }
  return 'vunknown'
}

# ------------------------------------------------------------
# 마스킹: 입력 문자열 -> 민감정보 제거된 문자열
# 순서가 중요하다. (개별 파일 경로를 먼저 지우고, 그 다음 사용자명을 치환)
# ------------------------------------------------------------
function ConvertTo-MaskedText {
  param([Parameter(Mandatory = $true)][string]$Text)

  $t = [string]$Text

  # 1) 삭제 전 확인 목록의 개별 파일 경로 줄 (들여쓰기 + 드라이브/UNC 경로)
  #    요약( 몇 개 / 몇 MB )은 남기고 경로만 제거한다.
  $t = [regex]::Replace($t, '(?m)^[ \t]{4,}(?:[A-Za-z]:\\|\\\\).*?\r?$', '')

  # 2) Windows 사용자 프로필 경로
  $t = [regex]::Replace($t, '(?i)C:\\Users\\[^\\\r\n]+', 'C:\Users\<USER>')

  # 3) 도메인\사용자  (예: CRIS\dal04)  — C: 는 위에서 처리했으므로 제외
  $t = [regex]::Replace($t, '(?i)\b(?!C:)[A-Za-z0-9_.-]{2,}\\[A-Za-z0-9_.-]{2,}\b', '<DOMAIN>\<USER>')

  # 4) hosts 규칙의 호스트명 (0.0.0.0 *.도메인, 127.0.0.1 도메인 등)
  $t = [regex]::Replace($t, '(?i)\b(0\.0\.0\.0|127\.0\.0\.1)\s+[A-Za-z0-9*._-]+', '$1 <HOST_REDACTED>')

  # 5) 이메일 / MAC / IP
  $t = [regex]::Replace($t, '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b', '<EMAIL>')
  $t = [regex]::Replace($t, '\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b', '<MAC>')
  #    0.0.0.0 은 hosts 규칙의 형식을 보여주기 위해 남긴다.
  $t = $t.Replace('0.0.0.0', '___ZERO_IP___')
  $t = [regex]::Replace($t, '\b\d{1,3}(?:\.\d{1,3}){3}\b', '<IP>')
  $t = $t.Replace('___ZERO_IP___', '0.0.0.0')

  # 6) SSID / 시리얼 / 컴퓨터명
  $t = [regex]::Replace($t, '(?i)\b(SSID|Wi-?Fi\s*이름|무선\s*네트워크)\s*[:=]\s*\S+', '$1: <REDACTED>')
  $t = [regex]::Replace($t, '(?i)\b(serial|시리얼|S\/N)\s*[:=]?\s*[A-Za-z0-9-]{6,}', '$1: <REDACTED>')
  $t = [regex]::Replace($t, '\b(?:DESKTOP|LAPTOP|WIN|PC)-[A-Z0-9]{6,}\b', '<HOST>')
  $t = [regex]::Replace($t, '(?i)\b(ComputerName|HostName|컴퓨터명)\s*[:=]\s*\S+', '$1: <HOST>')

  return $t
}

# --- 자체 검사 ---
if ($SelfTest) {
  $cases = @(
    @{ Name = '사용자 경로';   In = 'C:\Users\dal04\AppData\Local\Edge\Cache\x'; MustNot = @('dal04'); Must = @('C:\Users\<USER>') },
    @{ Name = '도메인\사용자'; In = 'User: CRIS\dal04';                          MustNot = @('CRIS', 'dal04'); Must = @('<DOMAIN>\<USER>') },
    @{ Name = 'hosts 도메인';  In = '0.0.0.0 *.dc-telemetry.net';                MustNot = @('dc-telemetry'); Must = @('0.0.0.0 <HOST_REDACTED>') },
    @{ Name = '이메일';        In = 'mail: test.user@example.com';               MustNot = @('example.com'); Must = @('<EMAIL>') },
    @{ Name = 'MAC';           In = 'mac AA:BB:CC:DD:EE:FF';                    MustNot = @('AA:BB:CC'); Must = @('<MAC>') },
    @{ Name = 'IP';            In = 'gateway 192.168.0.1';                      MustNot = @('192.168.0.1'); Must = @('<IP>') },
    @{ Name = '시리얼';        In = 'Serial: AB12CD34EF56';                     MustNot = @('AB12CD34EF56'); Must = @('<REDACTED>') },
    @{ Name = '컴퓨터명';      In = 'DESKTOP-ABC123';                           MustNot = @('DESKTOP-ABC123'); Must = @('<HOST>') },
    @{ Name = 'KB는 유지';     In = '마지막 패치 KB5132061';                    MustNot = @(); Must = @('KB5132061') },
    @{ Name = '하드웨어 유지'; In = 'Intel(R) Wi-Fi 6 AX200 160MHz';            MustNot = @(); Must = @('AX200') }
  )
  $pass = 0; $fail = 0
  foreach ($c in $cases) {
    $out = ConvertTo-MaskedText -Text $c.In
    $ok = $true
    foreach ($s in $c.MustNot) { if ($out -like "*$s*") { $ok = $false } }
    foreach ($s in $c.Must)    { if ($out -notlike "*$s*") { $ok = $false } }
    if ($ok) { $pass++; Write-Host "PASS  $($c.Name)" } else { $fail++; Write-Host "FAIL  $($c.Name)  => $out" }
  }
  Write-Host ""
  Write-Host "마스킹 자체검사: $pass PASS / $fail FAIL"
  if ($fail -gt 0) { exit 1 }
  exit 0
}

# --- 최신 결과 txt 찾기 ---
function Get-LatestResultFile {
  param([string]$Explicit)
  if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
    if (Test-Path -LiteralPath $Explicit) { return Get-Item -LiteralPath $Explicit }
    return $null
  }
  # 1순위: 바탕화면(및 자동점검결과 폴더)의 실제 결과 파일
  $desktopDirs = @($desktop, (Join-Path $desktop '자동점검결과'))
  $best = $null
  foreach ($dir in $desktopDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    $cand = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like '자동유지보수_*.txt' -and $_.Name -notlike '자동유지보수_피드백_*' } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($cand -and (-not $best -or $cand.LastWriteTime -gt $best.LastWriteTime)) { $best = $cand }
  }
  if ($best) { return $best }
  # 2순위: 로그 폴더의 마지막 리포트 사본
  $logDir = Join-Path $root 'Simple maintenance\logs'
  if (Test-Path -LiteralPath $logDir -PathType Container) {
    $cand = Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -eq 'last-report.txt' } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($cand) { return $cand }
  }
  return $null
}

$source = Get-LatestResultFile -Explicit $ResultPath
if (-not $source) {
  Write-Host '마스킹할 결과 파일을 찾지 못했습니다.'
  Write-Host "  찾은 위치: $desktop, $desktop\자동점검결과, $root\Simple maintenance\logs"
  Write-Host '  먼저 "자동 유지보수 점검"을 한 번 실행하거나, -ResultPath 로 파일을 지정하세요.'
  Read-Host 'Enter 키를 누르면 닫힙니다'
  exit 1
}

try {
  $raw = Get-Content -LiteralPath $source.FullName -Raw -Encoding UTF8
} catch {
  Write-Host "결과 파일을 읽을 수 없습니다: $($_.Exception.Message)"
  Read-Host 'Enter 키를 누르면 닫힙니다'
  exit 1
}

$masked = ConvertTo-MaskedText -Text $raw
$ver = Get-KitVersionText
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'

$out = @()
$out += '=========================================='
$out += '  자동 유지보수 - 피드백 내보내기 (마스킹됨)'
$out += '=========================================='
$out += "생성: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$out += "키트 버전: $ver"
$out += "원본 결과: $($source.Name)  ($($source.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
$out += ''
$out += '[ 올리기 전에 - 30초만 확인해 주세요 ]'
$out += ' 1. 이 파일은 민감정보를 자동으로 지웠습니다. 그래도 메모장에서 한 번 훑어보세요.'
$out += '    (하드웨어 모델명/드라이버 버전은 진단용으로 남아 있습니다. 민감하면 지우세요.)'
$out += ' 2. https://github.com/parkd2912-jpg/maintenance/discussions → New discussion → 사용 후기 카테고리'
$out += ' 3. 파일 전체(아래 고지/면책 문구 포함)를 복사해 붙여넣고, 맨 아래 [내 한 줄]은 꼭 직접 써주세요.'
$out += ' 4. 원본 결과 txt(마스킹 안 된 것)는 올리지 마세요.'
$out += ''
$out += '=========================================='
$out += '[ 고지 / 면책 — GitHub 에 올리기 전에 읽어주세요 ]'
$out += '=========================================='
$out += '· 이 키트는 개인용 비공식 도구이며, Microsoft 및 각 제조사와 무관합니다.'
$out += '· 서비스·예약 작업·레지스트리·hosts·광고 설정을 변경하므로 백신이 민감하게 반응할 수 있습니다. 악성코드가 아닙니다.'
$out += '· 사용자 파일(사진·문서·다운로드)은 절대 자동 삭제하지 않습니다. 임시/캐시/휴지통도 y 확인 후에만 정리합니다.'
$out += '· 광고 차단·알림 끄기는 선택 사항이며, "자동 유지보수 제거"로 되돌릴 수 있습니다.'
$out += '· 제공은 "있는 그대로(As-Is)"이며, 사용 결과에 대한 책임은 사용자에게 있습니다.'
$out += '· 아래 내용은 민감정보를 기계적으로 지운 것입니다. 100%를 보장하지 않으므로 반드시 직접 확인 후 올리세요.'
$out += ''
$out += '[ DISCLAIMER - read before posting to GitHub ]'
$out += '· Unofficial personal tool; not affiliated with Microsoft or any vendor.'
$out += '· It changes services, scheduled tasks, registry, hosts and ad settings, so antivirus may flag it. Not malware.'
$out += '· It never auto-deletes your files (photos/docs/downloads). Temp/cache/recycle-bin cleanup also requires your y confirmation.'
$out += '· Ad blocking and notification muting are opt-in and can be reverted with the uninstall shortcut.'
$out += '· Provided AS IS without warranty; use at your own risk.'
$out += '· The text below is machine-masked. Masking is not guaranteed perfect - review it yourself before posting.'
$out += ''
$out += '[ 免責事項 / GitHub に投稿する前に必ずお読みください ]'
$out += '· 非公式の個人用ツールです。Microsoft および各メーカーとは無関係です。'
$out += '· サービス・タスク・レジストリ・hosts・広告設定を変更するため、ウイルス対策ソフトが反応する場合があります。マルウェアではありません。'
$out += '· 写真・書類・ダウンロードファイルは自動削除しません。一時/キャッシュ/ごみ箱も y の確認後のみ削除します。'
$out += '· 広告ブロック・通知オフは任意で、「自動メンテナンス削除」で元に戻せます。'
$out += '· 現状のまま(AS IS)で提供し、保証はありません。使用結果は自己責任です。'
$out += '· 以下は機械的にマスキングしたものです。完全を保証しないので、投稿前に必ず目を通してください。'
$out += ''
$out += '[ 免责声明 / 发布到 GitHub 前请先阅读 ]'
$out += '· 非官方的个人工具，与 Microsoft 及各厂商无关。'
$out += '· 会修改服务、计划任务、注册表、hosts 和广告设置，杀毒软件可能报警。它不是恶意软件。'
$out += '· 绝不自动删除您的文件（照片/文档/下载）。临时文件/缓存/回收站也必须按 y 确认后才清理。'
$out += '· 广告拦截/通知关闭为可选功能，可用卸载快捷方式还原。'
$out += '· 按原样(AS IS)提供，不作保证，使用风险自负。'
$out += '· 以下内容已做机器脱敏，不能保证 100% 完整，发布前请务必自行检查。'
$out += ''
$out += '------------------------------------------'
$out += '[ 마스킹된 점검 결과 ]'
$out += '------------------------------------------'
$out += $masked
$out += ''
$out += '------------------------------------------'
$out += '[ 내 한 줄 ]   <-- 여기에 직접 써주세요'
$out += '------------------------------------------'
$out += '좋았던 점 / 아쉬운 점 / 이상했던 동작:'
$out += ''
$out += ''
$out += '(예: "자동으로 고친 게 5건이나 있어서 좋았는데, 왜 고쳤는지 설명이 더 있으면 좋겠어요")'
$out += ''

$outPath = Join-Path $desktop ("자동유지보수_피드백_$stamp.txt")
try {
  $utf8bom = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($outPath, ($out -join "`r`n"), $utf8bom)
} catch {
  Write-Host "피드백 파일 저장 실패: $($_.Exception.Message)"
  Read-Host 'Enter 키를 누르면 닫힙니다'
  exit 1
}

Write-Host ''
Write-Host '=========================================='
Write-Host '  피드백 파일을 만들었습니다'
Write-Host '=========================================='
Write-Host "  $outPath"
Write-Host ''
Write-Host '민감정보(사용자명/경로/hosts 도메인/IP/MAC/시리얼)는 마스킹했습니다.'
Write-Host '메모장에서 확인하고, 문제가 없으면 GitHub Discussion 에 붙여넣으세요.'
Write-Host ''

if (-not $NoOpen) {
  try { Invoke-Item -LiteralPath $outPath } catch { Write-Host "(메모장 자동 실행 실패 - 위 파일을 직접 여세요)" }
}

Read-Host 'Enter 키를 누르면 닫힙니다'
