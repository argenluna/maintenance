# -*- coding: utf-8 -*-
# ============================================================
#  Auto Maintenance - 업데이트 공통 함수 (v1.12.0)
#  - GitHub Release에서 최신 버전/릴리스 노트/ZIP 주소를 읽는다
#  - 커스텀 3버튼 알림창(업데이트 / 취소 / 다시 알리지 않음, 화면 중앙 + TopMost)
#  - 자동 실행용 AutoCloseSeconds 타이머(미클릭 시 취소로 닫힘)
#  - "다시 알리지 않음" 상태를 update-skip.txt 에 저장한다
#  run-maintenance.ps1(직접/자동 공통 알림) 과 업데이트.ps1 이 dot-source 해서 함께 쓴다.
#  ※ 이 파일도 UTF-8 BOM 유지 필수 (PowerShell 5.1)
# ============================================================

$script:UpdateOwner   = 'argenluna'
$script:UpdateRepo    = 'maintenance'
$script:UpdateApi     = 'https://api.github.com/repos/argenluna/maintenance/releases?per_page=100'
$script:UpdatePage    = 'https://github.com/argenluna/maintenance/releases'

# --- 시스템 언어 (install.ps1 의 Get-KitLanguage 과 동일 규칙) ---
function Get-UpdateLanguage {
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
function UL {
  param([string]$Ko, [string]$En)
  if ((Get-UpdateLanguage) -eq 'ko') { return $Ko }
  return $En
}

# --- 버전 파싱 ---
function Get-KitVersionValue {
  param([string]$Root)
  try {
    $vf = Join-Path $Root 'VERSION'
    if (Test-Path -LiteralPath $vf) {
      $lines = @(Get-Content -LiteralPath $vf -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($lines.Count -ge 1) {
        $raw = ([string]$lines[0]).Trim().TrimStart('v', 'V')
        $v = $null
        if ([version]::TryParse($raw, [ref]$v)) { return $v }
      }
    }
  } catch { }
  return [version]'0.0.0'
}
function Convert-ReleaseVersion {
  param([string]$TagName)
  $raw = ([string]$TagName).Trim().TrimStart('v', 'V')
  $v = $null
  if ([version]::TryParse($raw, [ref]$v)) { return $v }
  return $null
}

# --- 다운로드 URL 검증 ---
# 릴리스 응답의 browser_download_url 은 외부 입력이다. HTTPS + 허용된 GitHub 호스트만 통과시킨다.
function Test-TrustedReleaseUrl {
  param([AllowNull()][string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
  try {
    $u = [Uri]$Url
    if ($u.Scheme -ne [Uri]::UriSchemeHttps) { return $false }
    $hostName = $u.Host.ToLowerInvariant()
    if ($hostName -eq 'github.com') {
      return ($u.AbsolutePath -match '^/argenluna/maintenance/releases/download/')
    }
    if ($hostName -eq 'objects.githubusercontent.com') { return $true }
    return $false
  } catch { return $false }
}

# --- GitHub Releases 조회 (공개 저장소 / 인증 불필요) ---
function Get-GitHubReleases {
  param([int]$TimeoutSec = 12)
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'AutoMaintenanceKit/1.8'; 'Accept' = 'application/vnd.github+json' }
    $res = Invoke-WebRequest -Uri $script:UpdateApi -Headers $headers -UseBasicParsing -TimeoutSec $TimeoutSec
    $data = $res.Content | ConvertFrom-Json
    if ($null -eq $data) { return @() }
    return @($data)
  } catch { return @() }
}

# --- 현재 버전보다 새 릴리스가 있는지 종합 ---
function Get-UpdateInfo {
  param([string]$Root, [int]$TimeoutSec = 12)
  $local = Get-KitVersionValue -Root $Root
  $rels = Get-GitHubReleases -TimeoutSec $TimeoutSec
  $newer = @()
  foreach ($r in $rels) {
    $v = Convert-ReleaseVersion -TagName ([string]$r.tag_name)
    if ($null -ne $v -and $v -gt $local) {
      $newer += [pscustomobject]@{ Version = $v; Release = $r }
    }
  }
  if ($newer.Count -eq 0) { return $null }
  $newer = @($newer | Sort-Object Version -Descending)
  $latest = $newer[0]

  # 릴리스 노트의 목록 항목 = "새 기능 n가지" + 안내창에 보여줄 목록
  $featureList = New-Object System.Collections.ArrayList
  foreach ($n in $newer) {
    $body = [string]$n.Release.body
    if (-not [string]::IsNullOrWhiteSpace($body)) {
      foreach ($line in ($body -split "`r?`n")) {
        if ($line -match '^\s*(?:[-*·]|\d+[.)])\s+\S') {
          $item = ([string]$line -replace '^\s*(?:[-*·]|\d+[.)])\s+', '').Trim()
          # 마크다운 장식 제거 + 길이 제한 (안내창에 넣기 위해)
          $item = $item -replace '\*\*|__|`|\[|\]\([^)]*\)', ''
          $item = [regex]::Replace($item, '\s+', ' ').Trim()
          if ($item.Length -gt 72) { $item = $item.Substring(0, 70) + '…' }
          if ($item.Length -ge 4) { $null = $featureList.Add($item) }
        }
      }
    }
  }
  $features = $featureList.Count

  $zipUrl = $null
  $hashUrl = $null
  foreach ($a in @($latest.Release.assets)) {
    $nm = [string]$a.name
    $url = [string]$a.browser_download_url
    # 허용되지 않은 호스트/스킴의 자산은 아예 선택하지 않는다.
    if (-not (Test-TrustedReleaseUrl $url)) { continue }
    if ($nm -match '\.zip$' -and -not $zipUrl) { $zipUrl = $url }
    if ($nm -match '\.sha256$' -and -not $hashUrl) { $hashUrl = $url }
  }
  return [pscustomobject]@{
    Local          = $local
    Latest         = $latest.Version
    VersionsBehind = $newer.Count
    Features       = $features
    FeatureList    = @($featureList)
    ZipUrl         = $zipUrl
    HashUrl        = $hashUrl
    PageUrl        = $script:UpdatePage
    Release        = $latest.Release
  }
}

# --- "다시 알리지 않음" 상태 (그 버전만 건너뛴다) ---
function Get-SkipVersion {
  param([string]$Root)
  try {
    $p = Join-Path $Root 'update-skip.txt'
    if (Test-Path -LiteralPath $p) {
      return ([string](Get-Content -LiteralPath $p -Raw -Encoding UTF8)).Trim().TrimStart('v', 'V')
    }
  } catch { }
  return ''
}
function Set-SkipVersion {
  param([string]$Root, [string]$Version)
  try {
    $p = Join-Path $Root 'update-skip.txt'
    ([string]$Version).Trim() | Set-Content -LiteralPath $p -Encoding UTF8 -NoNewline
  } catch { }
}

# --- 커스텀 3버튼 알림창 ---
# 반환: 'update' / 'cancel' / 'skip'
function Show-UpdateDialog {
  param(
    [string]$Title,
    [string]$Message,
    [string]$UpdateText,
    [string]$CancelText,
    [string]$SkipText,
    [int]$AutoCloseSeconds = 0
  )
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $form = New-Object System.Windows.Forms.Form
  $form.Text = $Title
  $form.StartPosition = 'CenterScreen'
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.ShowInTaskbar = $true
  $form.TopMost = $true
  $form.ClientSize = New-Object System.Drawing.Size(600, 430)
  $form.Font = New-Object System.Drawing.Font('Malgun Gothic', 10)

  $label = New-Object System.Windows.Forms.Label
  $label.Location = New-Object System.Drawing.Point(18, 16)
  $label.Size = New-Object System.Drawing.Size(564, 320)
  $label.Text = $Message
  $form.Controls.Add($label)

  $btnUpdate = New-Object System.Windows.Forms.Button
  $btnUpdate.Text = $UpdateText
  $btnUpdate.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $btnUpdate.Location = New-Object System.Drawing.Point(18, 368)
  $btnUpdate.Size = New-Object System.Drawing.Size(170, 40)
  $form.Controls.Add($btnUpdate)

  $btnCancel = New-Object System.Windows.Forms.Button
  $btnCancel.Text = $CancelText
  $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $btnCancel.Location = New-Object System.Drawing.Point(203, 368)
  $btnCancel.Size = New-Object System.Drawing.Size(170, 40)
  $form.Controls.Add($btnCancel)

  $btnSkip = New-Object System.Windows.Forms.Button
  $btnSkip.Text = $SkipText
  $btnSkip.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
  $btnSkip.Location = New-Object System.Drawing.Point(388, 368)
  $btnSkip.Size = New-Object System.Drawing.Size(194, 40)
  $form.Controls.Add($btnSkip)

  $form.AcceptButton = $btnUpdate
  $form.CancelButton = $btnCancel

  # 자동 실행에서는 사용자가 없을 수 있으므로 일정 시간 뒤 자동으로 닫는다.
  # (취소와 동일하게 처리되어 점검은 계속 진행된다.)
  $timer = $null
  if ($AutoCloseSeconds -gt 0) {
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $AutoCloseSeconds * 1000
    $tick = {
      $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
      $form.Close()
    }.GetNewClosure()
    $timer.add_Tick([System.EventHandler]$tick)
    $timer.Start()
  }
  try {
    $dr = $form.ShowDialog()
  } finally {
    if ($null -ne $timer) { $timer.Stop(); $timer.Dispose() }
    $form.Dispose()
  }
  if ($dr -eq [System.Windows.Forms.DialogResult]::OK) { return 'update' }
  if ($dr -eq [System.Windows.Forms.DialogResult]::Ignore) { return 'skip' }
  return 'cancel'
}

# --- 안내문 생성 + 표시 (직접 실행/자동 실행 공통) ---
# 반환: 'update' / 'cancel' / 'skip'  (자동 실행이면 AutoCloseSeconds 뒤 'cancel')
function Show-UpdateNotice {
  param(
    [Parameter(Mandatory = $true)]$UpdateInfo,
    [int]$AutoCloseSeconds = 0
  )
  $lang = Get-UpdateLanguage
  $list = @($UpdateInfo.FeatureList)
  $local = [string]$UpdateInfo.Local
  $latest = [string]$UpdateInfo.Latest
  $behind = [int]$UpdateInfo.VersionsBehind

  if ($lang -eq 'ko') {
    $title = '자동유지보수 - 새 버전 안내'
    $msg = "자동유지보수 새 버전이 나왔습니다.`n`n"
    $msg += "현재 v$local → v$latest (${behind}버전 뒤)`n`n"
    if ($list.Count -gt 0) {
      $msg += "새 기능 $($list.Count)가지가 생겼습니다.`n"
      foreach ($f in @($list | Select-Object -First 6)) { $msg += "  · $f`n" }
      if ($list.Count -gt 6) { $msg += "  · 외 $($list.Count - 6)건`n" }
    } else {
      $msg += "새 기능·변경 내역은 아래 릴리스 페이지에서 확인할 수 있습니다.`n"
    }
    $msg += "`n업데이트: 안전 검증 후 새 버전을 자동으로 설치합니다.`n"
    $msg += "취소: 이번 점검을 계속 진행합니다.`n"
    $msg += "다시 알리지 않음: 이 버전 알림을 건너뜁니다.`n`n"
    $msg += [string]$UpdateInfo.PageUrl
    $tUpdate = '업데이트'; $tCancel = '취소'; $tSkip = '다시 알리지 않음'
  } else {
    $title = 'Auto Maintenance - New version available'
    $msg = "A new version of Auto Maintenance is available.`n`n"
    $msg += "Current v$local -> v$latest ($behind version(s) behind)`n`n"
    if ($list.Count -gt 0) {
      $msg += "$($list.Count) new feature(s)/change(s) were added:`n"
      foreach ($f in @($list | Select-Object -First 6)) { $msg += "  · $f`n" }
      if ($list.Count -gt 6) { $msg += "  · and $($list.Count - 6) more`n" }
    } else {
      $msg += "See the release page below for what changed.`n"
    }
    $msg += "`nUpdate: verify and install the new version automatically.`n"
    $msg += "Cancel: continue this maintenance run.`n"
    $msg += "Don't show again: skip notice for this version.`n`n"
    $msg += [string]$UpdateInfo.PageUrl
    $tUpdate = 'Update'; $tCancel = 'Cancel'; $tSkip = "Don't show again"
  }

  return Show-UpdateDialog -Title $title -Message $msg `
    -UpdateText $tUpdate -CancelText $tCancel -SkipText $tSkip `
    -AutoCloseSeconds $AutoCloseSeconds
}
