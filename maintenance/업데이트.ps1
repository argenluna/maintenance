# -*- coding: utf-8 -*-
# ============================================================
#  Auto Maintenance - 업데이트 (v1.8.0)
#  알림창의 "업데이트" 버튼이 실행하는 파일.
#  1) GitHub Release 의 최신 ZIP + .sha256 을 받아 해시 검증
#  2) 현재 설치 폴더 옆에 새 버전 폴더를 만든 뒤 상태 파일을 이어받음
#  3) 새 폴더의 install.ps1 -NoFirstRun 으로 예약 작업/바로가기를 새 경로로 변경
#  4) 기존 폴더는 롤백용으로 그대로 둔다 (삭제하지 않음)
# ============================================================
param([switch]$NoPause)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$desktop = [Environment]::GetFolderPath('Desktop')

# --- 인자 안전 조인 (PS 5.1 대응) ---
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

function Test-UpdAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Show-UpdBox {
  param([string]$Text, [string]$Caption = '업데이트')
  try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($Text, $Caption, 'OK', 'Information') | Out-Null
  } catch { Write-Host $Text }
}
function Fail-Upd {
  param([string]$Text)
  Write-Host "[실패] $Text" -ForegroundColor Red
  Show-UpdBox "업데이트하지 못했습니다.`n`n$Text`n`n기존 설치는 그대로 남아 있습니다."
  if (-not $NoPause) { Read-Host 'Enter 키를 누르면 닫힙니다' }
  exit 1
}

if (-not (Test-UpdAdmin)) {
  Write-Host '관리자 권한이 필요합니다. 확인 창에서 "예"를 누르세요...'
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  if ($NoPause) { $argList += '-NoPause' }
  try {
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList (Join-CliArgs $argList) | Out-Null
  } catch { }
  exit
}

$common = Join-Path $root 'update-common.ps1'
if (-not (Test-Path -LiteralPath $common)) { Fail-Upd "공통 파일이 없습니다: $common" }
. $common

Write-Host ''
Write-Host '=========================================='
Write-Host '   자동 유지보수 업데이트'
Write-Host '=========================================='
Write-Host ''

$upd = $null
try { $upd = Get-UpdateInfo -Root $root -TimeoutSec 25 } catch { }
if ($null -eq $upd) { Fail-Upd 'GitHub에서 새 버전 정보를 가져오지 못했습니다. 인터넷 연결을 확인하세요.' }
if ([string]::IsNullOrWhiteSpace([string]$upd.ZipUrl)) { Fail-Upd '최신 릴리스에 ZIP 파일이 첨부되어 있지 않습니다.' }
# 이중 방어: Get-UpdateInfo 필터를 통과했어도 설치 전에 한 번 더 검증한다.
if (-not (Test-TrustedReleaseUrl ([string]$upd.ZipUrl))) { Fail-Upd '허용되지 않은 다운로드 주소입니다.' }
# .sha256 은 이제 필수다. 없으면 무결성 검증 없이 관리자 권한으로 설치되는 것을 막는다.
if ([string]::IsNullOrWhiteSpace([string]$upd.HashUrl)) { Fail-Upd '릴리스에 .sha256 해시 파일이 없습니다. 무결성 검증 없이는 설치하지 않습니다.' }
if (-not (Test-TrustedReleaseUrl ([string]$upd.HashUrl))) { Fail-Upd '허용되지 않은 해시 파일 주소입니다.' }
Write-Host ("현재 v$($upd.Local) → 새 버전 v$($upd.Latest)")

$tmp = Join-Path $env:TEMP ('AutoMaintenance_Update_' + $upd.Latest.ToString() + '_' + (Get-Date -Format yyyyMMdd_HHmmss))
try {
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $zipPath = Join-Path $tmp 'update.zip'
  Write-Host '새 버전을 내려받는 중...'
  $zipResp = Invoke-WebRequest -Uri $upd.ZipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 180 -PassThru
  # github.com/.../releases/download/ 는 objects.githubusercontent.com 등으로 302 리다이렉트된다.
  # 요청 전 URL 검사만으로 부족하므로 최종 응답 URL도 같은 화이트리스트로 검증한다.
  $finalZipUrl = ''
  try { if ($zipResp.BaseResponse -and $zipResp.BaseResponse.ResponseUri) { $finalZipUrl = $zipResp.BaseResponse.ResponseUri.AbsoluteUri } } catch { }
  if (-not (Test-TrustedReleaseUrl $finalZipUrl)) { Fail-Upd '리다이렉트 후 최종 다운로드 주소가 허용되지 않은 호스트입니다.' }

  # 해시 검증은 이제 필수 (위에서 .sha256 없으면 중단했다).
  Write-Host '파일 무결성 검사 중...'
  $hashPath = Join-Path $tmp 'update.sha256'
  $hashResp = Invoke-WebRequest -Uri $upd.HashUrl -OutFile $hashPath -UseBasicParsing -TimeoutSec 60 -PassThru
  $finalHashUrl = ''
  try { if ($hashResp.BaseResponse -and $hashResp.BaseResponse.ResponseUri) { $finalHashUrl = $hashResp.BaseResponse.ResponseUri.AbsoluteUri } } catch { }
  if (-not (Test-TrustedReleaseUrl $finalHashUrl)) { Fail-Upd '리다이렉트 후 최종 해시 파일 주소가 허용되지 않은 호스트입니다.' }
  $expected = @((Get-Content -LiteralPath $hashPath -Raw) -split '\s+' | Where-Object { $_ -match '^[0-9a-fA-F]{64}$' } | Select-Object -First 1)
  $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
  if ($expected.Count -eq 0) { Fail-Upd '릴리스의 해시 파일 형식이 올바르지 않습니다.' }
  if ($actual.ToLowerInvariant() -ne ([string]$expected[0]).ToLowerInvariant()) {
    Fail-Upd '다운로드한 ZIP 의 해시가 일치하지 않습니다. 파일이 변조되었을 수 있어 중단했습니다.'
  }
  Write-Host '해시 검사 통과'

  Write-Host '압축 해제 중...'
  $extractDir = Join-Path $tmp 'extract'

  # Zip Slip 방어: 해시가 맞더라도 아카이브에 ../·절대경로가 있으면 풀지 않는다.
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zipArchive = $null
  try {
    $zipArchive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    $extractBase = [IO.Path]::GetFullPath($extractDir).TrimEnd([char[]]@('\', '/')) + '\'
    foreach ($entry in $zipArchive.Entries) {
      $entryName = [string]$entry.FullName
      if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
      if ($entryName.StartsWith('\') -or $entryName.StartsWith('/') -or $entryName -match '^[A-Za-z]:') {
        Fail-Upd "ZIP 에 절대 경로 항목이 있습니다: $entryName"
      }
      $dest = [IO.Path]::GetFullPath((Join-Path $extractDir $entryName))
      if (-not $dest.StartsWith($extractBase, [StringComparison]::OrdinalIgnoreCase)) {
        Fail-Upd "ZIP 에 추출 폴더를 벗어나는 경로가 있습니다: $entryName"
      }
    }
  } finally {
    if ($null -ne $zipArchive) { $zipArchive.Dispose() }
  }

  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
  $newRoot = $extractDir
  if (-not (Test-Path -LiteralPath (Join-Path $newRoot 'install.ps1'))) {
    $sub = Get-ChildItem -LiteralPath $extractDir -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'install.ps1') } | Select-Object -First 1
    if ($null -eq $sub) { Fail-Upd 'ZIP 안에 install.ps1 이 없습니다.' }
    $newRoot = $sub.FullName
  }

  # 설치 실행 전에 필수 파일 존재 + 모든 스크립트 구문을 정적 검사한다.
  # 해시가 맞더라도 릴리스 자산이 깨져 있으면 관리자 권한으로 install.ps1 을 실행하지 않는다.
  $requiredFiles = @(
    'install.ps1', 'install.cmd', 'run-maintenance.ps1', 'run-now.ps1', 'uninstall.ps1',
    'update.ps1', 'update-common.ps1', '업데이트.ps1', 'feedback.ps1',
    'config.json', 'VERSION', 'README.md', 'readme.txt', 'newbie.txt', 'LICENSE',
    (Join-Path 'Simple maintenance' 'maintenance.ps1'),
    (Join-Path 'Simple maintenance' 'config.json')
  )
  foreach ($rel in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $newRoot $rel) -PathType Leaf)) {
      Fail-Upd "새 버전에 필수 파일이 없습니다: $rel"
    }
  }
  # dot-source 되거나 하위에서 호출되는 .ps1/.psm1 이 누락되지 않도록 재귀 검사한다.
  $allScripts = @(Get-ChildItem -LiteralPath $newRoot -Recurse -File -ErrorAction Stop |
    Where-Object { $_.Extension -in '.ps1', '.psm1' })
  if ($allScripts.Count -eq 0) { Fail-Upd '새 버전에서 검사할 스크립트를 찾지 못했습니다.' }
  foreach ($scriptFile in $allScripts) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
      $relName = $scriptFile.FullName.Substring($newRoot.Length + 1)
      Fail-Upd "새 버전 스크립트 구문 오류 ($relName): $($parseErrors[0].Message)"
    }
  }
  Write-Host "스크립트 구문 검사 통과 ($($allScripts.Count)개)"

  # 새 폴더 위치: 기존 설치와 같은 드라이브/부모 폴더에 v<버전> 으로
  $parent = Split-Path -Parent $root
  $target = Join-Path $parent ('AutoMaintenance_v' + $upd.Latest.ToString())
  if (Test-Path -LiteralPath $target) { $target = $target + '_' + (Get-Date -Format HHmmss) }
  Copy-Item -LiteralPath $newRoot -Destination $target -Recurse -Force
  Write-Host "새 폴더: $target"

  #state 이어받기 (기존 폴더는 그대로 두고 복사만)
  $carry = @('.last_*', 'config.json', '*-state.json', 'last-result.json', 'status.json', 'adbackup', 'update-skip.txt', 'logs')
  foreach ($pair in @(
      @{ Src = $root; Dst = $target },
      @{ Src = (Join-Path $root 'Simple maintenance'); Dst = (Join-Path $target 'Simple maintenance') }
    )) {
    if (-not (Test-Path -LiteralPath $pair.Src) -or -not (Test-Path -LiteralPath $pair.Dst)) { continue }
    foreach ($pat in $carry) {
      foreach ($item in @(Get-ChildItem -LiteralPath $pair.Src -Filter $pat -Force -ErrorAction SilentlyContinue)) {
        try { Copy-Item -LiteralPath $item.FullName -Destination $pair.Dst -Recurse -Force -ErrorAction Stop }
        catch { Write-Host "  상태 이어받기 실패: $($item.Name)" -ForegroundColor DarkGray }
      }
    }
  }
  Write-Host '기존 설정·로그를 이어받았습니다.'

  # 예약 작업 + 바로가기를 새 폴더로 재등록 (첫 점검은 건너뛴다)
  Write-Host '예약 작업과 바로가기를 새 버전으로 변경하는 중...'
  $install = Join-Path $target 'install.ps1'
  & $install -NoFirstRun -NoPause -ReportTo $desktop
  if ($LASTEXITCODE -and [int]$LASTEXITCODE -ne 0) { Fail-Upd "새 버전 설치가 실패했습니다 (코드 $LASTEXITCODE)." }

  # 확인
  $task = Get-ScheduledTask -TaskName 'OpenCode-Maintenance' -ErrorAction SilentlyContinue
  $actionArg = if ($task) { [string]($task.Actions | Select-Object -First 1).Arguments } else { '' }
  if ($actionArg -notlike "*$target*") {
    Write-Host '  (경고) 예약 작업 경로를 확인하지 못했습니다. 수동으로 확인하세요.' -ForegroundColor Yellow
  }
  $linked = $false
  try {
    $ws = New-Object -ComObject WScript.Shell
    foreach ($lnk in @(Get-ChildItem -LiteralPath $desktop -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
      try { if ([string]$ws.CreateShortcut($lnk.FullName).TargetPath -like "*$target*") { $linked = $true; break } } catch { }
    }
  } catch { }
  if (-not $linked) { Write-Host '  (경고) 바탕화면 바로가기 경로를 확인하지 못했습니다.' -ForegroundColor Yellow }

  Show-UpdBox "업데이트가 완료되었습니다.`n`n새 버전: v$($upd.Latest)`n설치 경로: $target`n`n기존 폴더는 롤백용으로 남겨 두었습니다. 삭제하지 마세요.`n지금 점검 바로가기로 새 버전을 실행할 수 있습니다." '업데이트 완료'
  Write-Host ''
  Write-Host "완료. 새 버전: v$($upd.Latest) / $target"
  Write-Host '기존 폴더는 롤백용으로 남겨 두었습니다.'
  if (-not $NoPause) { Read-Host 'Enter 키를 누르면 닫힙니다' }
} catch {
  Fail-Upd $_.Exception.Message
}
