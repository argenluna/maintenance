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
#  - 토큰은 하드코딩하지 않는다: 인자 → GH_TOKEN/GITHUB_TOKEN → 배포본 동봉 토큰 파일
#    → gh auth token → 사용자 입력.
#  v1.14.1 (2026-11-21) 추가 — 배포본 동봉 피드백 전용 토큰
#  - feedback.ps1 과 같은 폴더의 feedback-token.txt 를 읽어 자동 업로드에 사용.
#    상대 PC는 토큰 입력 없이 y 한 번으로 업로드 완료.
#  - 반드시 Discussions 쓰기 권한만 가진 최소 권한 토큰을 동봉할 것.
#    (일반 repo/workflow 토큰을 넣으면 공개 ZIP 을 통해 저장소 전체가 유출된다.)
#
#  v1.5.0 안전/가시성 강화 (2026-11-18)
#  - 업로드 전 악성코드·이상 코드 패턴을 검사하고 <BLOCKED:...> 로 치환한다.
#    (스크립트 태그, javascript: URL, 인코딩된 PowerShell, IEX/FromBase64String,
#     긴 base64 blob, HTML 엔티티, eval 계열 등)
#  - 실행 결과(성공/실패/비동의·URL·오류·차단 건수)를 바탕화면
#    "자동유지보수_피드백상태.txt" 에 덮어써서 남기고, 콘솔에도 배너로 표시한다.
#  - Discussion 본문 하단에 버전·시각·안전검증 결과 메타데이터를 붙인다.
#  v1.6.0 (2026-11-18) 시스템 언어 대응 / v1.7.0 이름·결과 txt 영어 출력
#  - Windows UI 언어가 한국어면 한국어, 아니면 영어로 출력한다.
#    SelfTest 결과(테스트 결과), 상태 파일, 콘솔 배너가 언어를 따라간다.
#  - 바탕화면 바로가기도 한국어=자동 유지보수 점검/제거/피드백,
#    그 외 언어=auto-maintenance / remove maintenance / feedback maintenance.
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

# --- Windows UI 언어 감지: 한국어면 'ko', 아니면 'en' ---
# 우선순위: CurrentUICulture → 사용자 언어 목록 → CurrentCulture → 시스템 로캘
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
  # 주의: PowerShell 5.1 의 CurrentUICulture 는 설치 언어(en-US)를 반환해
  # 실제 Windows 언어와 다를 수 있다. 따라서 첫 값만 보지 말고 모든 후보를 훑는다.
  foreach ($tag in @($tags | Where-Object { $_ })) {
    if ($tag -match '^ko([-_]|$)') { return 'ko' }
  }
  return 'en'
}

$kitLang = Get-KitLanguage
function L {
  param([string]$Ko, [string]$En)
  if ($kitLang -eq 'ko') { return $Ko }
  return $En
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

  # 2-1) v1.14.4: 키트 폴더(Simple maintenance)는 폴더명이 '<DOMAIN>'으로 뭉개지지 않게 보호.
  #   뒤의 사용자명만 <USER> 로 바꾼다. (아래 도메인\사용자 규칙보다 먼저 실행해야 함)
  $t = [regex]::Replace($t, '(?i)(Simple maintenance\\)[^\\\r\n]+', '$1<USER>')

  # 3) 도메인\사용자  (예: CRIS\dal04)  — C: 는 위에서 처리했으므로 제외
  $t = [regex]::Replace($t, '(?i)\b(?!C:)[A-Za-z0-9_.-]{2,}\\[A-Za-z0-9_.-]{2,}\b', '<DOMAIN>\<USER>')

  # 4) hosts 규칙의 호스트명 (0.0.0.0 *.도메인, 127.0.0.1 도메인 등)
  $t = [regex]::Replace($t, '(?i)\b(0\.0\.0\.0|127\.0\.0\.1)\s+[A-Za-z0-9*._-]+', '$1 <HOST_REDACTED>')

  # 5) 이메일 / MAC / IP
  $t = [regex]::Replace($t, '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b', '<EMAIL>')
  $t = [regex]::Replace($t, '\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b', '<MAC>')

  # v1.14.4: 드라이버 버전(예 32.0.16.1088)은 IP 와 패턴이 같아 <IP> 로 뭉개진다.
  #   진단용으로 남기기 위해 IP 마스킹 전에 임시 토큰으로 보호했다가 복원한다.
  $savedDriverVersions = @()
  foreach ($drvMatch in [regex]::Matches($t, '(?i)\bDriver\s*[:=]\s*\d{1,3}(?:\.\d{1,3}){3}\b')) {
    $savedDriverVersions += $drvMatch.Value
    $t = $t.Replace($drvMatch.Value, "___DRVVER$($savedDriverVersions.Count - 1)___")
  }

  $t = $t.Replace('0.0.0.0', '___ZERO_IP___')
  $t = [regex]::Replace($t, '\b\d{1,3}(?:\.\d{1,3}){3}\b', '<IP>')
  $t = $t.Replace('___ZERO_IP___', '0.0.0.0')
  for ($di = 0; $di -lt $savedDriverVersions.Count; $di++) {
    $t = $t.Replace("___DRVVER$di___", $savedDriverVersions[$di])
  }

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
    @{ Name = 'HTML/스크립트태그'; En = 'HTML/script tag';      Regex = '(?i)<\s*/?\s*(script|iframe|object|embed|svg|link|meta|style)\b[^>]*>' }
    @{ Name = '이벤트핸들러';      En = 'Event handler';        Regex = '(?i)\bon(?:error|load|click|mouseover|focus|submit)\s*=' }
    @{ Name = 'JS/데이터스킴';     En = 'JS/data scheme';       Regex = '(?i)\b(?:javascript|vbscript|data:text/html)\s*:' }
    @{ Name = 'HTML엔티티';        En = 'HTML entity';          Regex = '(?i)&#(?:x[0-9a-f]+|[0-9]+);' }
    @{ Name = '인코딩PowerShell';  En = 'Encoded PowerShell';   Regex = '(?i)-(?:enc|encodedcommand)\s+[A-Za-z0-9+/=]{8,}' }
    @{ Name = '코드실행cmdlet';    En = 'Code-exec cmdlet';     Regex = '(?i)\b(?:Invoke-Expression|FromBase64String|DownloadString|DownloadFile|Set-ExecutionPolicy|Add-Type|New-Object\s+System\.Net\.WebClient)\b|\bIEX\s*\(' }
    @{ Name = 'eval계열';          En = 'eval family';          Regex = '(?i)\b(?:eval|exec|system|shell_exec|os\.system|subprocess\.)\s*\(' }
    @{ Name = '긴base64블롭';      En = 'Long base64 blob';     Regex = '\b[A-Za-z0-9+/]{100,}={0,2}\b' }
    @{ Name = '악성마크다운링크';  En = 'Malicious markdown link'; Regex = '!?\[[^\]]{0,200}\]\(\s*(?:javascript|data|vbscript):' }
    @{ Name = '셸주입';            En = 'Shell injection';      Regex = '(?i)(?:\|\s*(?:sh|bash|cmd|powershell)\b|&&\s*\w+|`\s*\w+|\$\((?:curl|wget|bash)\b)' }
  )

  foreach ($p in $patterns) {
    $hits = [regex]::Matches($result, $p.Regex)
    if ($hits.Count -gt 0) {
      $total += $hits.Count
      $label = L $p.Name $p.En
      $null = $kinds.Add($label)
      $result = [regex]::Replace($result, $p.Regex, ('<BLOCKED:' + $label + '>'))
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
  $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $lines = @()
  $lines += '=========================================='
  $lines += (L '  자동 유지보수 - 피드백 실행 결과' '  Auto Maintenance - Feedback run result')
  $lines += '=========================================='
  $lines += (L "실행 시각: $now" "Run time: $now")
  $lines += (L "키트 버전: $ver" "Kit version: $ver")
  $lines += (L "결과: $ResultText" "Result: $ResultText")
  if ($Url)        { $lines += (L "업로드 주소: $Url" "Upload URL: $Url") }
  if ($Detail)     { $lines += (L "상세: $Detail" "Detail: $Detail") }
  $lines += ''
  $lines += (L '이 파일은 마지막 피드백 실행 결과를 덮어써서 보여줍니다.' 'This file is overwritten with the latest feedback run result.')
  try {
    [IO.File]::WriteAllText($statusPath, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
  } catch { }
}

# --- 자체 검사 ---
if ($SelfTest) {
  $cases = @(
    @{ Ko = '사용자 경로';   En = 'User path';        In = 'C:\Users\dal04\AppData\Local\Edge\Cache\x'; MustNot = @('dal04'); Must = @('C:\Users\<USER>') },
    @{ Ko = '도메인\사용자'; En = 'Domain\user';      In = 'User: CRIS\dal04';                          MustNot = @('CRIS', 'dal04'); Must = @('<DOMAIN>\<USER>') },
    @{ Ko = 'hosts 도메인';  En = 'hosts domain';     In = '0.0.0.0 *.dc-telemetry.net';                MustNot = @('dc-telemetry'); Must = @('0.0.0.0 <HOST_REDACTED>') },
    @{ Ko = '이메일';        En = 'Email';            In = 'mail: test.user@example.com';               MustNot = @('example.com'); Must = @('<EMAIL>') },
    @{ Ko = 'MAC';           En = 'MAC';              In = 'mac AA:BB:CC:DD:EE:FF';                    MustNot = @('AA:BB:CC'); Must = @('<MAC>') },
    @{ Ko = 'IP';            En = 'IP';               In = 'gateway 192.168.0.1';                      MustNot = @('192.168.0.1'); Must = @('<IP>') },
    @{ Ko = '시리얼';        En = 'Serial';           In = 'Serial: AB12CD34EF56';                     MustNot = @('AB12CD34EF56'); Must = @('<REDACTED>') },
    @{ Ko = '컴퓨터명';      En = 'Computer name';    In = 'DESKTOP-ABC123';                           MustNot = @('DESKTOP-ABC123'); Must = @('<HOST>') },
    @{ Ko = 'KB는 유지';     En = 'KB kept';          In = '마지막 패치 KB5132061';                    MustNot = @(); Must = @('KB5132061') },
    @{ Ko = '하드웨어 유지'; En = 'Hardware kept';    In = 'Intel(R) Wi-Fi 6 AX200 160MHz';            MustNot = @(); Must = @('AX200') },
    @{ Ko = '드라이버 버전 유지'; En = 'Driver version kept'; In = 'GPU: RTX 5070 Ti (Driver: 32.0.16.1088, OK)'; MustNot = @('<IP>'); Must = @('32.0.16.1088') },
    @{ Ko = '키트 폴더 경로'; En = 'Kit folder path'; In = 'Simple maintenance\dal04\deleted-20261121.txt'; MustNot = @('<DOMAIN>', 'dal04'); Must = @('Simple maintenance\') }
  )
  $pass = 0; $fail = 0
  foreach ($c in $cases) {
    $out = ConvertTo-MaskedText -Text $c.In
    $ok = $true
    foreach ($s in $c.MustNot) { if ($out -like "*$s*") { $ok = $false } }
    foreach ($s in $c.Must)    { if ($out -notlike "*$s*") { $ok = $false } }
    $nm = L $c.Ko $c.En
    if ($ok) { $pass++; Write-Host "PASS  $nm" } else { $fail++; Write-Host "FAIL  $nm  => $out" }
  }

  # 안전검증 5건
  $safeCases = @(
    @{ Ko = '스크립트태그 차단'; En = 'Script tag blocked';  In = '<script>alert(1)</script>'; MustNot = @('<script>') },
    @{ Ko = '자바스크립트 URL';  En = 'JavaScript URL';      In = '[click](javascript:alert(1))'; MustNot = @('javascript:') },
    @{ Ko = 'IEX 실행 차단';     En = 'IEX execution';       In = 'IEX([Text.Encoding]::UTF8.GetString($x))'; MustNot = @('IEX(') },
    @{ Ko = '인코딩 명령 차단';  En = 'Encoded command';     In = 'powershell -enc SGVsbG8gV29ybGQ='; MustNot = @('-enc') },
    @{ Ko = '정상 진단 유지';    En = 'Valid data kept';     In = '상태: PASS / KB5132061 / Intel AX200'; MustNot = @(); Must = @('PASS', 'KB5132061') }
  )
  foreach ($c in $safeCases) {
    $s = Sanitize-FeedbackText -Text $c.In
    $ok = $true
    foreach ($x in $c.MustNot) { if ($s.Text -like "*$x*") { $ok = $false } }
    foreach ($x in $c.Must)    { if ($s.Text -notlike "*$x*") { $ok = $false } }
    $nm = L $c.Ko $c.En
    if ($ok) { $pass++; Write-Host "PASS  $nm" } else { $fail++; Write-Host "FAIL  $nm  => $($s.Text)" }
  }

  Write-Host ""
  $summary = L '자체검사: {0} PASS / {1} FAIL (마스킹 12 + 안전 5)' 'Self-test: {0} PASS / {1} FAIL (12 masking + 5 safety)'
  Write-Host ($summary -f $pass, $fail)
  $langLine = L '시스템 언어: {0} → {1}' 'System language: {0} → {1}'
  Write-Host ($langLine -f $kitLang, (L '한국어' 'English'))
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

  # v1.14.1: 배포본에 동봉된 피드백 전용 토큰 (디스커션 쓰기 권한만).
  #gh auth token 보다 먼저 확인한다 — 일반 계정 토큰은 디스커션 권한이 없을 수 있다.
  $bundled = Join-Path $PSScriptRoot 'feedback-token.txt'
  if (Test-Path -LiteralPath $bundled) {
    try {
      $bt = ([IO.File]::ReadAllText($bundled, [Text.Encoding]::UTF8)).Trim()
      # 자리표시자/주문/너무 짧은 값은 무시하고 아래 입력 단계로 넘어간다.
      if ($bt.Length -ge 20 -and $bt -notmatch '^(YOUR_|PLACEHOLDER|#|//|여기에)') {
        return $bt
      }
    } catch { }
  }

  try {
    $fromGh = & gh auth token 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($fromGh)) {
      return ([string]$fromGh).Trim()
    }
  } catch { }

  Write-Host ''
  Write-Host (L 'GitHub 토큰이 필요합니다(한 번만 입력하면 이 창에서만 사용하고 저장하지 않습니다).' 'A GitHub token is needed (enter once; used only in this window, never stored).')
  Write-Host (L '발급: https://github.com/settings/tokens → "Generate new token (classic)" → repo 체크 → Generate token' 'Get one: https://github.com/settings/tokens → "Generate new token (classic)" → check repo → Generate token')
  $sec = Read-Host (L '토큰을 붙여넣으세요 (입력 내용은 화면에 표시되지 않습니다)' 'Paste your token (input is hidden)') -AsSecureString
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
    'User-Agent'    = 'AutoMaintenance-Feedback/1.6'
    'Accept'        = 'application/vnd.github+json'
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
  $resp = Invoke-RestMethod -Uri 'https://api.github.com/graphql' -Method Post `
    -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 30
  if ($resp.errors) {
    $msgs = @($resp.errors | ForEach-Object { $_.message }) -join ' / '
    throw ((L 'GitHub GraphQL 오류: ' 'GitHub GraphQL error: ') + $msgs)
  }
  # 빈 응답이 오면 data 가 없는데도 "성공" 처리되어 로컬 파일이 삭제될 수 있다.
  if ($null -eq $resp -or $null -eq $resp.data) {
    throw ((L 'GitHub 응답에 data 가 없습니다(빈 응답).' 'GitHub response has no data (empty response).'))
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

  if ($null -eq $data -or $null -eq $data.repository) {
    throw ((L '저장소 정보를 가져오지 못했습니다.' 'Could not read repository information.'))
  }
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
  $url = $data.createDiscussion.discussion.url
  # URL 이 없으면 업로드 실패로 처리한다. 성공으로 오인해 로컬 파일을 지우지 않게 하는 안전장치.
  $expectedPrefix = '^https://github\.com/' + [regex]::Escape("$ghOwner/$ghRepo") + '/discussions/\d+(?:\?|$)'
  if ([string]::IsNullOrWhiteSpace([string]$url) -or [string]$url -notmatch $expectedPrefix) {
    throw ((L '업로드 확인 URL 이 올바르지 않습니다(업로드 실패로 처리).' 'Invalid upload confirmation URL (treated as failure).'))
  }
  return $url
}

# --- 최신 결과 txt 찾기 ---
function Get-LatestResultFile {
  param([string]$Explicit)
  if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
    if (Test-Path -LiteralPath $Explicit) { return Get-Item -LiteralPath $Explicit }
    return $null
  }
  # v1.7.0: 영어 모드 결과 보관 폴더도 함께 찾는다.
  $desktopDirs = @($desktop, (Join-Path $desktop '자동점검결과'), (Join-Path $desktop 'maintenance results'))
  $best = $null
  foreach ($dir in $desktopDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    $cand = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
      Where-Object {
        ($_.Name -like '자동유지보수_*.txt' -or $_.Name -like 'auto-maintenance_*.txt') -and
        $_.Name -notlike '자동유지보수_피드백_*' -and $_.Name -notlike '자동유지보수_피드백상태*' -and
        $_.Name -notlike 'auto-maintenance_feedback_*'
      } |
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
  $msg = L '마스킹할 결과 파일을 찾지 못했습니다.' 'No result file found to mask.'
  Write-Host $msg
  Write-Host (L "  찾은 위치: $desktop, $desktop\자동점검결과, $root\Simple maintenance\logs" "  Looked in: $desktop, $desktop\자동점검결과, $root\Simple maintenance\logs")
  Write-Host (L '  먼저 "자동 유지보수 점검"을 한 번 실행하거나, -ResultPath 로 파일을 지정하세요.' '  Run a check first, or pass -ResultPath with a file.')
  Write-FeedbackStatus -ResultText (L '실패 - 결과 파일 없음' 'Failed - no result file') -Detail $msg
  Read-Host (L 'Enter 키를 누르면 닫힙니다' 'Press Enter to close')
  exit 1
}

try {
  $raw = Get-Content -LiteralPath $source.FullName -Raw -Encoding UTF8
} catch {
  Write-Host (L "결과 파일을 읽을 수 없습니다: $($_.Exception.Message)" "Cannot read result file: $($_.Exception.Message)")
  Write-FeedbackStatus -ResultText (L '실패 - 결과 파일 읽기 오류' 'Failed - result file read error') -Detail $_.Exception.Message
  Read-Host (L 'Enter 키를 누르면 닫힙니다' 'Press Enter to close')
  exit 1
}

# --- v1.14.5: 보낸 PC 식별 정보 ---
# 공개 Discussion이므로 머신 GUID 원본은 절대 넣지 않고 SHA-256 앞 6자리만 사용한다.
$pcGuid = ''
try { $pcGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction SilentlyContinue).MachineGuid } catch { }
$pcTag = if (-not [string]::IsNullOrWhiteSpace([string]$pcGuid)) {
  $digest = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$pcGuid))
  'PC-' + ([BitConverter]::ToString($digest).Replace('-', '').Substring(0, 6))
} else { 'PC-Unknown' }

$cpuName = ''
try { $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() } catch { }
$gpuName = ''
try {
  $gpuName = (Get-CimInstance Win32_VideoController |
    Where-Object { $_.Name -notmatch 'Virtual|Meta|Mirror|Microsoft Basic' } |
    Select-Object -First 1).Name.Trim()
} catch { }

# 1) 개인정보 마스킹 → 2) 악성/이상 코드 검증
$masked = ConvertTo-MaskedText -Text $raw
$safety = Sanitize-FeedbackText -Text $masked
$safeText = $safety.Text
$blockedCount = $safety.Blocked
$blockedKinds = if ($safety.Kinds.Count -gt 0) { ($safety.Kinds -join ', ') } else { (L '없음' 'none') }

$ver = Get-KitVersionText
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$createdAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$out = @()
$out += '=========================================='
$out += (L '  자동 유지보수 - 피드백 내보내기 (마스킹 + 안전검증)' '  Auto Maintenance - Feedback export (masked + sanitized)')
$out += '=========================================='
$out += (L "생성: $createdAt" "Created: $createdAt")
$out += (L "키트 버전: $ver" "Kit version: $ver")
$out += (L "원본 결과: $($source.Name)  ($($source.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" "Source result: $($source.Name)  ($($source.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))")
$out += (L "안전 검증: 위험 패턴 $blockedCount 건 제거  [$blockedKinds]" "Safety check: $blockedCount risky pattern(s) removed  [$blockedKinds]")
$out += ''
$out += '------------------------------------------'
$out += (L '[ 보낸 PC — 같은 PC에서 들어온 보고서 구분용 ]' '[ Sending PC — distinguishes reports from different machines ]')
$out += '------------------------------------------'
$out += (L "식별자: $pcTag  (머신 GUID 원본은 올리지 않고 해시 앞 6자리만 사용)" "ID: $pcTag  (raw Machine GUID is never uploaded - first 6 hash chars only)")
$out += (L "CPU: $cpuName" "CPU: $cpuName")
$out += (L "GPU: $gpuName" "GPU: $gpuName")
$out += ''
# v1.14.7: 초보자용 결과표가 들어 있는 보고서는 업로드 본문에서도 바로 찾을 수 있게 표시한다.
#   (마스킹된 본문을 기준으로 판단하므로 실제 올라가는 내용과 항상 일치한다.)
if ($safeText -match '\[\s*초보자용 결과표\s*\]|\[\s*Easy-to-read results\s*\]') {
  $out += (L 'ℹ️ 이 보고서에는 초보자용 결과표가 들어 있습니다. 아래 [ 초보자용 결과표 ] 를 먼저 보세요.' 'ℹ️ This report includes an easy-to-read results table. See [ Easy-to-read results ] below first.')
  $out += ''
}
$out += (L '[ 올리기 전에 - 30초만 확인해 주세요 ]' '[ Before posting - please review for 30 seconds ]')
$out += (L ' 1. 이 파일은 민감정보와 위험 코드를 자동으로 지웠습니다. 그래도 한 번 훑어보세요.' ' 1. Sensitive info and risky code were removed automatically. Please still give it a quick look.')
$out += (L '    (하드웨어 모델명/드라이버 버전은 진단용으로 남아 있습니다. 민감하면 지우세요.)' '    (Hardware model/driver versions are kept for diagnosis. Delete them if sensitive.)')
$out += (L ' 2. 동의(y)하면 이 내용이 GitHub Discussion 에 자동으로 올라갑니다.' ' 2. If you consent (y), this is uploaded to a GitHub Discussion automatically.')
$out += (L '    비동의(n/Enter)하면 업로드하지 않고 이 파일을 바탕화면에 남깁니다.' '    If you decline (n/Enter), it is not uploaded and the file stays on the Desktop.')
$out += ' 3. https://github.com/argenluna/maintenance/discussions'
$out += (L ' 4. 원본 결과 txt(마스킹 안 된 것)는 올리지 않습니다.' ' 4. The original (unmasked) result txt is not uploaded.')
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
$out += (L '[ 마스킹된 점검 결과 ]' '[ Masked check result ]')
$out += '------------------------------------------'
# v1.14.5: 상세 로그는 GitHub에서 접히도록 <details> 로 감싼다 (본문 길이 제한·가독성).
$detailMarker = if ($kitLang -eq 'ko') { '--- 상세 로그' } else { '--- Detailed log' }
$detailIdx = $safeText.IndexOf($detailMarker)
if ($detailIdx -gt 0) {
  $summaryPart = $safeText.Substring(0, $detailIdx).TrimEnd()
  $detailPart = $safeText.Substring($detailIdx)
  $out += $summaryPart
  $out += ''
  $out += (L '<details><summary>상세 로그 (기술적 상세 — 펼쳐서 보기)</summary>' '<details><summary>Detailed log (technical details - expand to view)</summary>')
  $out += ''
  $out += '```text'
  $out += $detailPart
  $out += '```'
  $out += ''
  $out += '</details>'
} else {
  $out += $safeText
}
$out += ''
$out += '------------------------------------------'
$out += (L '[ 내 한 줄 ]   <-- 여기에 직접 써주세요' '[ My one line ]   <-- write here yourself')
$out += '------------------------------------------'
$out += (L '좋았던 점 / 아쉬운 점 / 이상했던 동작:' 'What was good / what was lacking / odd behavior:')
$out += ''
$out += ''
$out += (L '(예: "자동으로 고친 게 5건이나 있어서 좋았는데, 왜 고쳤는지 설명이 더 있으면 좋겠어요")' '(e.g. "It auto-fixed 5 things, which was great, but I wish it explained why it fixed them")')
$out += ''
$out += '------------------------------------------'
$out += (L '[ 자동 업로드 정보 ]' '[ Auto-upload info ]')
$out += '------------------------------------------'
$out += (L "키트 버전: $ver" "Kit version: $ver")
$out += (L "생성 시각: $createdAt" "Created: $createdAt")
$out += (L "안전 검증: 위험 패턴 $blockedCount 건 제거 [$blockedKinds]" "Safety check: $blockedCount risky pattern(s) removed [$blockedKinds]")

$outPath = Join-Path $desktop ("자동유지보수_피드백_$stamp.txt")
try {
  $utf8bom = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($outPath, ($out -join "`r`n"), $utf8bom)
} catch {
  $m = L "피드백 파일 저장 실패: $($_.Exception.Message)" "Failed to save feedback file: $($_.Exception.Message)"
  Write-Host $m
  Write-FeedbackStatus -ResultText (L '실패 - 피드백 파일 저장 오류' 'Failed - feedback file save error') -Detail $_.Exception.Message
  Read-Host (L 'Enter 키를 누르면 닫힙니다' 'Press Enter to close')
  exit 1
}

Write-Host ''
Write-Host '=========================================='
Write-Host (L '  피드백 파일을 만들었습니다' '  Feedback file created')
Write-Host '=========================================='
Write-Host "  $outPath"
Write-Host ''
Write-Host (L "안전 검증: 위험 패턴 $blockedCount 건 제거 [$blockedKinds]" "Safety check: $blockedCount risky pattern(s) removed [$blockedKinds]")
Write-Host ''

$uploaded = $false
$openedForReview = $false

if ($NoUpload) {
  Write-Host (L '-NoUpload 지정: GitHub 에 올리지 않고 파일을 유지합니다.' '-NoUpload specified: not uploading to GitHub; keeping the file.')
  Write-FeedbackStatus -ResultText (L '완료 - 파일만 생성 (업로드 안 함)' 'Done - file created only (no upload)') -Detail (L "-NoUpload / 바탕화면에 유지: $outPath / 안전검증 차단 $blockedCount 건" "-NoUpload / kept on Desktop: $outPath / safety blocked $blockedCount")
} else {
  # 규칙 기반 마스킹/필터링은 패턴에 없는 변형을 놓칠 수 있다.
  # 동의를 묻기 전에 파일을 먼저 열어 사용자가 직접 확인할 시간을 준다.
  # (-Yes 는 자동화/재전송용, -DryRun 은 검증용이므로 미리보기를 생략한다.)
  if (-not $Yes -and -not $DryRun -and -not $NoOpen) {
    try { Invoke-Item -LiteralPath $outPath; $openedForReview = $true }
    catch { Write-Host (L '(미리보기 실행 실패 - 위 경로의 파일을 직접 여세요)' '(Could not open preview - open the file at the path above manually)') }
    Write-Host (L '메모장에서 내용을 확인한 뒤 아래 질문에 답해주세요.' 'Review the content in Notepad, then answer below.')
  }
  $consent = $false
  if ($Yes) {
    $consent = $true
  } else {
    $answer = Read-Host (L '이 내용을 GitHub 에 자동 업로드할까요? (y = 업로드 후 이 파일 삭제 / n 또는 Enter = 업로드 안 함, 파일 유지)' 'Upload this to GitHub automatically? (y = upload then delete this file / n or Enter = no upload, keep file)')
    if ($answer -match '^(y|Y|ㅛ|예)$') { $consent = $true }
  }

  if (-not $consent) {
    Write-Host (L '업로드하지 않았습니다. 피드백 파일을 바탕화면에 남겨 둡니다.' 'Not uploaded. The feedback file stays on the Desktop.')
    Write-Host (L '직접 확인·편집한 뒤 https://github.com/argenluna/maintenance/discussions 에 붙여넣을 수 있습니다.' 'You can review/edit it yourself, then paste it at https://github.com/argenluna/maintenance/discussions')
    Write-FeedbackStatus -ResultText (L '비동의 - 업로드 안 함' 'Declined - no upload') -Detail (L "사용자가 업로드를 선택하지 않음 / 파일 유지: $outPath / 안전검증 차단 $blockedCount 건" "User did not choose upload / file kept: $outPath / safety blocked $blockedCount")
  } else {
    try {
      $tok = Get-GitHubToken -Given $Token
      $target = Get-DiscussionTarget -TokenValue $tok
      $bodyText = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8
      if ($bodyText.Length -gt 60000) {
        $bodyText = $bodyText.Substring(0, 60000) + (L "`r`n...(본문이 길어 뒤는 잘렸습니다)" "`r`n...(truncated: body too long)")
      }
      $deviceLabel = if ($gpuName) { $gpuName } else { $pcTag }
  $title = "[피드백/Feedback] $ver ($deviceLabel) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

      if ($DryRun) {
        Write-Host (L '[DryRun] 실제 업로드는 하지 않습니다.' '[DryRun] No actual upload is performed.')
        Write-Host (L "  대상: $ghOwner/$ghRepo (repoId=$($target.RepoId), category=$($target.CategoryId))" "  Target: $ghOwner/$ghRepo (repoId=$($target.RepoId), category=$($target.CategoryId))")
        Write-Host (L "  제목: $title" "  Title: $title")
        Write-Host (L "  본문 길이: $($bodyText.Length) 자 / 안전검증 차단: $blockedCount 건" "  Body length: $($bodyText.Length) chars / safety blocked: $blockedCount")
        Write-FeedbackStatus -ResultText (L 'DryRun - 업로드 안 함' 'DryRun - no upload') -Detail (L "대상 $ghOwner/$ghRepo / 본문 $($bodyText.Length)자 / 안전검증 차단 $blockedCount 건" "Target $ghOwner/$ghRepo / body $($bodyText.Length) chars / safety blocked $blockedCount")
      } else {
        $url = New-FeedbackDiscussion -TokenValue $tok -RepoId $target.RepoId `
          -CategoryId $target.CategoryId -Title $title -Body $bodyText
        Remove-Item -LiteralPath $outPath -Force
        $uploaded = $true
        Write-Host ''
        Write-Host '=========================================='
        Write-Host (L '  실행 결과: 성공 (업로드 완료)' '  Result: SUCCESS (upload complete)')
        Write-Host '=========================================='
        Write-Host "  $url"
        Write-Host (L "  안전검증: 위험 패턴 $blockedCount 건 제거" "  Safety check: $blockedCount risky pattern(s) removed")
        Write-Host (L '  피드백 파일 삭제 완료.' '  Feedback file deleted.')
        Write-FeedbackStatus -ResultText (L '성공 - GitHub 업로드 완료' 'SUCCESS - GitHub upload complete') -Url $url -Detail (L "안전검증 차단 $blockedCount 건 / 피드백 파일 삭제됨" "safety blocked $blockedCount / feedback file deleted")
      }
    } catch {
      $errMsg = $_.Exception.Message
      Write-Host ''
      Write-Host '=========================================='
      Write-Host (L '  실행 결과: 실패 (업로드 오류)' '  Result: FAILED (upload error)')
      Write-Host '=========================================='
      Write-Host "  $errMsg"
      Write-Host (L '  피드백 파일을 삭제하지 않고 유지합니다.' '  Keeping the feedback file (not deleted).')
      Write-FeedbackStatus -ResultText (L '실패 - 업로드 오류' 'FAILED - upload error') -Detail (L "$errMsg / 파일 유지: $outPath / 안전검증 차단 $blockedCount 건" "$errMsg / file kept: $outPath / safety blocked $blockedCount")
    }
  }
}

if (-not $uploaded -and -not $NoOpen -and -not $openedForReview) {
  try { Invoke-Item -LiteralPath $outPath } catch { Write-Host (L "(메모장 자동 실행 실패 - 위 파일을 직접 여세요)" "(Could not open Notepad - please open the file above manually)") }
}

Write-Host ''
Write-Host (L "실행 결과 상세: $statusPath" "Run result details: $statusPath")
Read-Host (L 'Enter 키를 누르면 닫힙니다' 'Press Enter to close')
