# -*- coding: utf-8 -*-
# ============================================================
#  Auto Maintenance - 피드백 내보내기 (마스킹 + 안전검증 + GitHub 자동 업로드)
#  바탕화면 "자동 유지보수 피드백" 바로가기가 실행하는 파일.
#
#  v1.4.0 (2026-11-17) 추가
#  - 원본 결과 txt 를 그대로 올리면 사용자명· hosts 차단 도메인·하드웨어
#    정보가 그대로 노출된다. 민감정보를 마스킹한 요약을 만든다.
#  v1.5.0 (2026-11-18) 변경 — 동의/비동의 선택형 자동 업로드
#  - 마스킹 파일을 만든 뒤 "GitHub 에 올릴까요?" 를 묻는다.
#      y(동의)  → GraphQL createDiscussion 으로 자동 업로드, 성공 시 로컬 파일 삭제
#      n/Enter(비동의) → 업로드하지 않고 파일을 바탕화면에 유지
#  - 업로드 실패 시에도 파일을 유지한다(사용자가 직접 올릴 수 있게).
#  - GitHub REST 는 Discussion 생성을 지원하지 않아(404) GraphQL 을 사용한다.
#  - 토큰은 하드코딩하지 않는다: gh auth token → GH_TOKEN/GITHUB_TOKEN → 사용자 입력.
#
#  v1.5.0 안전/가시성 강화 (2026-11-18)
#  - 업로드 전 악성코드·이상 코드 패턴을 검사하고 <BLOCKED:...> 로 치환한다.
#    (스크립트 태그, javascript: URL, 인코딩된 PowerShell, IEX/FromBase64String,
#     긴 base64 blob, HTML 엔티티, eval 계열 등)
#  - 실행 결과(성공/실패/비동의·URL·오류·차단 건수)를 바탕화면
#    "자동유지보수_피드백상태.txt" 에 덮어써서 남기고, 콘솔에도 배너로 표시한다.
#  - Discussion 본문 하단에 버전·시각·안전검증 결과 메타데이터를 붙인다.
#  - PowerShell 5.1 호환 / UTF-8 BOM 필수.
#
#  사용법:
#    feedback.ps1                 : 마스킹 → 안전검증 → 동의/비동의 → (동의 시) 자동 업로드
#    feedback.ps1 -NoUpload       : 업로드 없이 파일만 만들고 메모장으로 열기 (구 동작)
#    feedback.ps1 -Yes            : 동의 질문 없이 바로 업로드 (자동화/재전송용)
#    feedback.ps1 -NoOpen         : 메모장을 열지 않기
#    feedback.ps1 -Token <토큰>   : 토큰을 인자로 전달 (테스트용, 저장하지 않음)
#    feedback.ps1 -DryRun         : 실제 업로드 없이 대상/payload/검증 결과만 출력
#    feedback.ps1 -SelfTest       : 마스킹 + 안전검증 규칙 자체 검사
# ============================================================

param(
  [switch]$NoOpen,
  [switch]$NoUpload,
  [switch]$Yes,
  [switch]$DryRun,
  [switch]$SelfTest,
  [string]$ResultPath = '',
  [string]$Token = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$desktop = [Environment]::GetFolderPath('Desktop')
$statusPath = Join-Path $desktop '자동유지보수_피드백상태.txt'

# --- GitHub 업로드 대상 (공개 저장소 정보; 토큰은 절대 넣지 않는다) ---
$ghOwner = 'argenluna'
$ghRepo  = 'maintenance'
$ghRepoIdFallback    = 'R_kgDOSOy8Gg'          # 조회 실패 시 fallback
$ghCategoryFallback  = 'DIC_kwDOSOy8Gs4DLV_4'  # General 카테고리

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

# ------------------------------------------------------------
# 안전 검증: 악성코드/이상 코드 패턴을 찾아 <BLOCKED:...> 로 치환
# 원본 결과 txt 는 이 키트가 만들지만, 사용자가 편집했거나 외부에서
# 가져온 파일일 수 있다. GitHub 에 올려질 텍스트를 한 번 더 정제한다.
# 반환: @{ Text = ...; Blocked =건수; Kinds = @('종류', ...) }
# ------------------------------------------------------------
function Sanitize-FeedbackText {
  param([Parameter(Mandatory = $true)][string]$Text)

  $result = [string]$Text
  $total = 0
  $kinds = New-Object System.Collections.ArrayList

  $patterns = @(
    @{ Name = 'HTML/스크립트태그'; Regex = '(?i)<\s*/?\s*(script|iframe|object|embed|svg|link|meta|style)\b[^>]*>' }
    @{ Name = '이벤트핸들러';      Regex = '(?i)\bon(?:error|load|click|mouseover|focus|submit)\s*=' }
    @{ Name = 'JS/데이터스킴';     Regex = '(?i)\b(?:javascript|vbscript|data:text/html)\s*:' }
    @{ Name = 'HTML엔티티';        Regex = '(?i)&#(?:x[0-9a-f]+|[0-9]+);' }
    @{ Name = '인코딩PowerShell';  Regex = '(?i)-(?:enc|encodedcommand)\s+[A-Za-z0-9+/=]{8,}' }
    @{ Name = '코드실행cmdlet';    Regex = '(?i)\b(?:Invoke-Expression|FromBase64String|DownloadString|DownloadFile|Set-ExecutionPolicy|Add-Type|New-Object\s+System\.Net\.WebClient)\b|\bIEX\s*\(' }
    @{ Name = 'eval계열';          Regex = '(?i)\b(?:eval|exec|system|shell_exec|os\.system|subprocess\.)\s*\(' }
    @{ Name = '긴base64블롭';      Regex = '\b[A-Za-z0-9+/]{100,}={0,2}\b' }
    @{ Name = '악성마크다운링크';  Regex = '!?\[[^\]]{0,200}\]\(\s*(?:javascript|data|vbscript):' }
    @{ Name = '셸주입';            Regex = '(?i)(?:\|\s*(?:sh|bash|cmd|powershell)\b|&&\s*\w+|`\s*\w+|\$\((?:curl|wget|bash)\b)' }
  )

  foreach ($p in $patterns) {
    $hits = [regex]::Matches($result, $p.Regex)
    if ($hits.Count -gt 0) {
      $total += $hits.Count
      $null = $kinds.Add($p.Name)
      $result = [regex]::Replace($result, $p.Regex, ('<BLOCKED:' + $p.Name + '>'))
    }
  }
  return @{ Text = $result; Blocked = $total; Kinds = @($kinds) }
}

# 실행 결과 상태 파일 (고정 이름에 덮어쓰기 → 파일이 쌓이지 않음)
function Write-FeedbackStatus {
  param(
    [Parameter(Mandatory = $true)][string]$ResultText,
    [string]$Detail = '',
    [string]$Url = ''
  )
  $ver = Get-KitVersionText
  $lines = @()
  $lines += '=========================================='
  $lines += '  자동 유지보수 - 피드백 실행 결과'
  $lines += '=========================================='
  $lines += "실행 시각: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $lines += "키트 버전: $ver"
  $lines += "결과: $ResultText"
  if ($Url)        { $lines += "업로드 주소: $Url" }
  if ($Detail)     { $lines += "상세: $Detail" }
  $lines += ''
  $lines += '이 파일은 마지막 피드백 실행 결과를 덮어써서 보여줍니다.'
  try {
    [IO.File]::WriteAllText($statusPath, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
  } catch { }
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

  # 안전검증 5건
  $safeCases = @(
    @{ Name = '스크립트태그 차단'; In = '<script>alert(1)</script>'; MustNot = @('<script>') },
    @{ Name = '자바스크립트 URL';  In = '[click](javascript:alert(1))'; MustNot = @('javascript:') },
    @{ Name = 'IEX 실행 차단';     In = 'IEX([Text.Encoding]::UTF8.GetString($x))'; MustNot = @('IEX(') },
    @{ Name = '인코딩 명령 차단';  In = 'powershell -enc SGVsbG8gV29ybGQ='; MustNot = @('-enc') },
    @{ Name = '정상 진단 유지';    In = '상태: PASS / KB5132061 / Intel AX200'; MustNot = @(); Must = @('PASS', 'KB5132061') }
  )
  foreach ($c in $safeCases) {
    $s = Sanitize-FeedbackText -Text $c.In
    $ok = $true
    foreach ($x in $c.MustNot) { if ($s.Text -like "*$x*") { $ok = $false } }
    foreach ($x in $c.Must)    { if ($s.Text -notlike "*$x*") { $ok = $false } }
    if ($ok) { $pass++; Write-Host "PASS  $($c.Name)" } else { $fail++; Write-Host "FAIL  $($c.Name)  => $($s.Text)" }
  }

  Write-Host ""
  Write-Host "자체검사: $pass PASS / $fail FAIL (마스킹 10 + 안전 5)"
  if ($fail -gt 0) { exit 1 }
  exit 0
}

# ------------------------------------------------------------
# GitHub 자동 업로드 (v1.5.0)
# REST /repos/.../discussions 는 404 → GraphQL createDiscussion 사용.
# ------------------------------------------------------------

function Get-GitHubToken {
  param([string]$Given)

  if (-not [string]::IsNullOrWhiteSpace($Given)) { return $Given.Trim() }
  foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN')) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
  }
  try {
    $fromGh = & gh auth token 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($fromGh)) {
      return ([string]$fromGh).Trim()
    }
  } catch { }

  Write-Host ''
  Write-Host 'GitHub 토큰이 필요합니다(한 번만 입력하면 이 창에서만 사용하고 저장하지 않습니다).'
  Write-Host '발급: https://github.com/settings/tokens → "Generate new token (classic)" → repo 체크 → Generate token'
  $sec = Read-Host '토큰을 붙여넣으세요 (입력 내용은 화면에 표시되지 않습니다)' -AsSecureString
  $plain = (New-Object System.Net.NetworkCredential('', $sec)).Password
  return $plain
}

function Invoke-GitHubGraphQL {
  param(
    [Parameter(Mandatory = $true)][string]$Query,
    [Parameter(Mandatory = $true)][hashtable]$Variables,
    [Parameter(Mandatory = $true)][string]$TokenValue
  )

  $payload = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 8
  $headers = @{
    'Authorization' = ('bearer ' + $TokenValue)
    'User-Agent'    = 'AutoMaintenance-Feedback/1.5'
    'Accept'        = 'application/vnd.github+json'
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
  $resp = Invoke-RestMethod -Uri 'https://api.github.com/graphql' -Method Post `
    -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 30
  if ($resp.errors) {
    $msgs = @($resp.errors | ForEach-Object { $_.message }) -join ' / '
    throw ("GitHub GraphQL 오류: " + $msgs)
  }
  return $resp.data
}

function Get-DiscussionTarget {
  param([Parameter(Mandatory = $true)][string]$TokenValue)

  $q = 'query($owner:String!,$name:String!){repository(owner:$owner,name:$name){id discussionCategories(first:20){nodes{id slug name}}}}'
  $data = Invoke-GitHubGraphQL -Query $q `
    -Variables @{ owner = $ghOwner; name = $ghRepo } -TokenValue $TokenValue

  $repoId = $data.repository.id
  if ([string]::IsNullOrWhiteSpace($repoId)) { $repoId = $ghRepoIdFallback }

  $catId = $null
  foreach ($c in @($data.repository.discussionCategories.nodes)) {
    if ([string]$c.slug -eq 'general') { $catId = $c.id; break }
  }
  if ([string]::IsNullOrWhiteSpace($catId)) { $catId = $ghCategoryFallback }
  return @{ RepoId = $repoId; CategoryId = $catId }
}

function New-FeedbackDiscussion {
  param(
    [Parameter(Mandatory = $true)][string]$TokenValue,
    [Parameter(Mandatory = $true)][string]$RepoId,
    [Parameter(Mandatory = $true)][string]$CategoryId,
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Body
  )

  $mut = 'mutation($repoId:ID!,$catId:ID!,$title:String!,$body:String!){createDiscussion(input:{repositoryId:$repoId,categoryId:$catId,title:$title,body:$body}){discussion{url number}}}'
  $data = Invoke-GitHubGraphQL -Query $mut `
    -Variables @{ repoId = $RepoId; catId = $CategoryId; title = $Title; body = $Body } `
    -TokenValue $TokenValue
  return $data.createDiscussion.discussion.url
}

# --- 최신 결과 txt 찾기 ---
function Get-LatestResultFile {
  param([string]$Explicit)
  if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
    if (Test-Path -LiteralPath $Explicit) { return Get-Item -LiteralPath $Explicit }
    return $null
  }
  $desktopDirs = @($desktop, (Join-Path $desktop '자동점검결과'))
  $best = $null
  foreach ($dir in $desktopDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    $cand = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like '자동유지보수_*.txt' -and $_.Name -notlike '자동유지보수_피드백_*' -and $_.Name -notlike '자동유지보수_피드백상태*' } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($cand -and (-not $best -or $cand.LastWriteTime -gt $best.LastWriteTime)) { $best = $cand }
  }
  if ($best) { return $best }
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
  $msg = '마스킹할 결과 파일을 찾지 못했습니다.'
  Write-Host $msg
  Write-Host "  찾은 위치: $desktop, $desktop\자동점검결과, $root\Simple maintenance\logs"
  Write-Host '  먼저 "자동 유지보수 점검"을 한 번 실행하거나, -ResultPath 로 파일을 지정하세요.'
  Write-FeedbackStatus -ResultText '실패 - 결과 파일 없음' -Detail $msg
  Read-Host 'Enter 키를 누르면 닫힙니다'
  exit 1
}

try {
  $raw = Get-Content -LiteralPath $source.FullName -Raw -Encoding UTF8
} catch {
  Write-Host "결과 파일을 읽을 수 없습니다: $($_.Exception.Message)"
  Write-FeedbackStatus -ResultText '실패 - 결과 파일 읽기 오류' -Detail $_.Exception.Message
  Read-Host 'Enter 키를 누르면 닫힙니다'
  exit 1
}

# 1) 개인정보 마스킹 → 2) 악성/이상 코드 검증
$masked = ConvertTo-MaskedText -Text $raw
$safety = Sanitize-FeedbackText -Text $masked
$safeText = $safety.Text
$blockedCount = $safety.Blocked
$blockedKinds = if ($safety.Kinds.Count -gt 0) { ($safety.Kinds -join ', ') } else { '없음' }

$ver = Get-KitVersionText
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$createdAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$out = @()
$out += '=========================================='
$out += '  자동 유지보수 - 피드백 내보내기 (마스킹 + 안전검증)'
$out += '=========================================='
$out += "생성: $createdAt"
$out += "키트 버전: $ver"
$out += "원본 결과: $($source.Name)  ($($source.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
$out += "안전 검증: 위험 패턴 $blockedCount 건 제거  [$blockedKinds]"
$out += ''
$out += '[ 올리기 전에 - 30초만 확인해 주세요 ]'
$out += ' 1. 이 파일은 민감정보와 위험 코드를 자동으로 지웠습니다. 그래도 한 번 훑어보세요.'
$out += '    (하드웨어 모델명/드라이버 버전은 진단용으로 남아 있습니다. 민감하면 지우세요.)'
$out += ' 2. 동의(y)하면 이 내용이 GitHub Discussion 에 자동으로 올라갑니다.'
$out += '    비동의(n/Enter)하면 업로드하지 않고 이 파일을 바탕화면에 남깁니다.'
$out += ' 3. https://github.com/argenluna/maintenance/discussions'
$out += ' 4. 원본 결과 txt(마스킹 안 된 것)는 올리지 않습니다.'
$out += ''
$out += '=========================================='
$out += '[ 고지 / 면책 — GitHub 에 올리기 전에 읽어주세요 ]'
$out += '=========================================='
$out += '· 이 키트는 개인용 비공식 도구이며, Microsoft 및 각 제조사와 무관합니다.'
$out += '· 서비스·예약 작업·레지스트리·hosts·광고 설정을 변경하므로 백신이 민감하게 반응할 수 있습니다. 악성코드가 아닙니다.'
$out += '· 사용자 파일(사진·문서·다운로드)은 절대 자동 삭제하지 않습니다. 임시/캐시/휴지통도 y 확인 후에만 정리합니다.'
$out += '· 광고 차단·알림 끄기는 선택 사항이며, "자동 유지보수 제거"로 되돌릴 수 있습니다.'
$out += '· 제공은 "있는 그대로(As-Is)"이며, 사용 결과에 대한 책임은 사용자에게 있습니다.'
$out += '· 아래 내용은 민감정보/위험 코드를 기계적으로 지운 것입니다. 100%를 보장하지 않으므로 반드시 직접 확인 후 올리세요.'
$out += ''
$out += '[ DISCLAIMER - read before posting to GitHub ]'
$out += '· Unofficial personal tool; not affiliated with Microsoft or any vendor.'
$out += '· It changes services, scheduled tasks, registry, hosts and ad settings, so antivirus may flag it. Not malware.'
$out += '· It never auto-deletes your files (photos/docs/downloads). Temp/cache/recycle-bin cleanup also requires your y confirmation.'
$out += '· Ad blocking and notification muting are opt-in and can be reverted with the uninstall shortcut.'
$out += '· Provided AS IS without warranty; use at your own risk.'
$out += '· The text below is machine-masked and sanitized. Not guaranteed perfect - review it yourself before posting.'
$out += ''
$out += '[ 免責事項 / GitHub に投稿する前に必ずお読みください ]'
$out += '· 非公式の個人用ツールです。Microsoft および各メーカーとは無関係です。'
$out += '· サービス・タスク・レジストリ・hosts・広告設定を変更するため、ウイルス対策ソフトが反応する場合があります。マルウェアではありません。'
$out += '· 写真・書類・ダウンロードファイルは自動削除しません。一時/キャッシュ/ごみ箱も y の確認後のみ削除します。'
$out += '· 広告ブロック・通知オフは任意で、「自動メンテナンス削除」で元に戻せます。'
$out += '· 現状のまま(AS IS)で提供し、保証はありません。使用結果は自己責任です。'
$out += '· 以下は機械的にマスキング・サニタイズしたものです。完全を保証しないので、投稿前に必ず目を通してください。'
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
$out += $safeText
$out += ''
$out += '------------------------------------------'
$out += '[ 내 한 줄 ]   <-- 여기에 직접 써주세요'
$out += '------------------------------------------'
$out += '좋았던 점 / 아쉬운 점 / 이상했던 동작:'
$out += ''
$out += ''
$out += '(예: "자동으로 고친 게 5건이나 있어서 좋았는데, 왜 고쳤는지 설명이 더 있으면 좋겠어요")'
$out += ''
$out += '------------------------------------------'
$out += '[ 자동 업로드 정보 ]'
$out += '------------------------------------------'
$out += "키트 버전: $ver"
$out += "생성 시각: $createdAt"
$out += "안전 검증: 위험 패턴 $blockedCount 건 제거 [$blockedKinds]"

$outPath = Join-Path $desktop ("자동유지보수_피드백_$stamp.txt")
try {
  $utf8bom = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($outPath, ($out -join "`r`n"), $utf8bom)
} catch {
  $m = "피드백 파일 저장 실패: $($_.Exception.Message)"
  Write-Host $m
  Write-FeedbackStatus -ResultText '실패 - 피드백 파일 저장 오류' -Detail $_.Exception.Message
  Read-Host 'Enter 키를 누르면 닫힙니다'
  exit 1
}

Write-Host ''
Write-Host '=========================================='
Write-Host '  피드백 파일을 만들었습니다'
Write-Host '=========================================='
Write-Host "  $outPath"
Write-Host ''
Write-Host "안전 검증: 위험 패턴 $blockedCount 건 제거 [$blockedKinds]"
Write-Host ''

$uploaded = $false

if ($NoUpload) {
  Write-Host '-NoUpload 지정: GitHub 에 올리지 않고 파일을 유지합니다.'
  Write-FeedbackStatus -ResultText '완료 - 파일만 생성 (업로드 안 함)' -Detail "-NoUpload / 바탕화면에 유지: $outPath / 안전검증 차단 $blockedCount 건"
} else {
  $consent = $false
  if ($Yes) {
    $consent = $true
  } else {
    $answer = Read-Host '이 내용을 GitHub 에 자동 업로드할까요? (y = 업로드 후 이 파일 삭제 / n 또는 Enter = 업로드 안 함, 파일 유지)'
    if ($answer -match '^(y|Y|ㅛ|예)$') { $consent = $true }
  }

  if (-not $consent) {
    Write-Host '업로드하지 않았습니다. 피드백 파일을 바탕화면에 남겨 둡니다.'
    Write-Host '직접 확인·편집한 뒤 https://github.com/argenluna/maintenance/discussions 에 붙여넣을 수 있습니다.'
    Write-FeedbackStatus -ResultText '비동의 - 업로드 안 함' -Detail "사용자가 업로드를 선택하지 않음 / 파일 유지: $outPath / 안전검증 차단 $blockedCount 건"
  } else {
    try {
      $tok = Get-GitHubToken -Given $Token
      $target = Get-DiscussionTarget -TokenValue $tok
      $bodyText = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8
      if ($bodyText.Length -gt 60000) {
        $bodyText = $bodyText.Substring(0, 60000) + "`r`n...(본문이 길어 뒤는 잘렸습니다)"
      }
      $title = "[피드백/Feedback] $ver - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

      if ($DryRun) {
        Write-Host '[DryRun] 실제 업로드는 하지 않습니다.'
        Write-Host "  대상: $ghOwner/$ghRepo (repoId=$($target.RepoId), category=$($target.CategoryId))"
        Write-Host "  제목: $title"
        Write-Host "  본문 길이: $($bodyText.Length) 자 / 안전검증 차단: $blockedCount 건"
        Write-FeedbackStatus -ResultText 'DryRun - 업로드 안 함' -Detail "대상 $ghOwner/$ghRepo / 본문 $($bodyText.Length)자 / 안전검증 차단 $blockedCount 건"
      } else {
        $url = New-FeedbackDiscussion -TokenValue $tok -RepoId $target.RepoId `
          -CategoryId $target.CategoryId -Title $title -Body $bodyText
        Remove-Item -LiteralPath $outPath -Force
        $uploaded = $true
        Write-Host ''
        Write-Host '=========================================='
        Write-Host '  실행 결과: 성공 (업로드 완료)'
        Write-Host '=========================================='
        Write-Host "  $url"
        Write-Host "  안전검증: 위험 패턴 $blockedCount 건 제거"
        Write-Host '  피드백 파일 삭제 완료.'
        Write-FeedbackStatus -ResultText '성공 - GitHub 업로드 완료' -Url $url -Detail "안전검증 차단 $blockedCount 건 / 피드백 파일 삭제됨"
      }
    } catch {
      $errMsg = $_.Exception.Message
      Write-Host ''
      Write-Host '=========================================='
      Write-Host '  실행 결과: 실패 (업로드 오류)'
      Write-Host '=========================================='
      Write-Host "  $errMsg"
      Write-Host '  피드백 파일을 삭제하지 않고 유지합니다.'
      Write-FeedbackStatus -ResultText '실패 - 업로드 오류' -Detail "$errMsg / 파일 유지: $outPath / 안전검증 차단 $blockedCount 건"
    }
  }
}

if (-not $uploaded -and -not $NoOpen) {
  try { Invoke-Item -LiteralPath $outPath } catch { Write-Host "(메모장 자동 실행 실패 - 위 파일을 직접 여세요)" }
}

Write-Host ''
Write-Host "실행 결과 상세: $statusPath"
Read-Host 'Enter 키를 누르면 닫힙니다'
