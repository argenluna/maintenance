# -*- coding: utf-8 -*-
# ============================================================
#  Auto Maintenance - 업데이트 공통 함수 (v1.8.0)
#  - GitHub Release에서 최신 버전/릴리스 노트/ZIP 주소를 읽는다
#  - 커스텀 3버튼 알림창(업데이트 / 취소 / 다시 알리지 않음)
#  - "다시 알리지 않음" 상태를 update-skip.txt 에 저장한다
#  run-now.ps1 과 업데이트.ps1 이 dot-source 해서 함께 쓴다.
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

  # 릴리스 노트의 목록 항목 수 = "새로운 기능 n가지"
  $features = 0
  foreach ($n in $newer) {
    $body = [string]$n.Release.body
    if (-not [string]::IsNullOrWhiteSpace($body)) {
      foreach ($line in ($body -split "`r?`n")) {
        if ($line -match '^\s*(?:[-*·]|\d+[.)])\s+\S') { $features++ }
      }
    }
  }

  $zipUrl = $null
  $hashUrl = $null
  foreach ($a in @($latest.Release.assets)) {
    $nm = [string]$a.name
    if ($nm -match '\.zip$' -and -not $zipUrl) { $zipUrl = [string]$a.browser_download_url }
    if ($nm -match '\.sha256$' -and -not $hashUrl) { $hashUrl = [string]$a.browser_download_url }
  }
  return [pscustomobject]@{
    Local          = $local
    Latest         = $latest.Version
    VersionsBehind = $newer.Count
    Features       = $features
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
    [string]$SkipText
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
  $form.ClientSize = New-Object System.Drawing.Size(560, 300)
  $form.Font = New-Object System.Drawing.Font('Malgun Gothic', 10)

  $label = New-Object System.Windows.Forms.Label
  $label.Location = New-Object System.Drawing.Point(18, 16)
  $label.Size = New-Object System.Drawing.Size(524, 176)
  $label.Text = $Message
  $form.Controls.Add($label)

  $btnUpdate = New-Object System.Windows.Forms.Button
  $btnUpdate.Text = $UpdateText
  $btnUpdate.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $btnUpdate.Location = New-Object System.Drawing.Point(18, 240)
  $btnUpdate.Size = New-Object System.Drawing.Size(150, 40)
  $form.Controls.Add($btnUpdate)

  $btnCancel = New-Object System.Windows.Forms.Button
  $btnCancel.Text = $CancelText
  $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $btnCancel.Location = New-Object System.Drawing.Point(203, 240)
  $btnCancel.Size = New-Object System.Drawing.Size(150, 40)
  $form.Controls.Add($btnCancel)

  $btnSkip = New-Object System.Windows.Forms.Button
  $btnSkip.Text = $SkipText
  $btnSkip.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
  $btnSkip.Location = New-Object System.Drawing.Point(388, 240)
  $btnSkip.Size = New-Object System.Drawing.Size(154, 40)
  $form.Controls.Add($btnSkip)

  $form.AcceptButton = $btnUpdate
  $form.CancelButton = $btnCancel

  try {
    $dr = $form.ShowDialog()
  } finally {
    $form.Dispose()
  }
  if ($dr -eq [System.Windows.Forms.DialogResult]::OK) { return 'update' }
  if ($dr -eq [System.Windows.Forms.DialogResult]::Ignore) { return 'skip' }
  return 'cancel'
}
