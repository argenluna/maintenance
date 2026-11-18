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
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$desktop = [Environment]::GetFolderPath('Desktop')

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
  $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
  if ($NoPause) { $argLine += ' -NoPause' }
  try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null } catch { }
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
Write-Host ("현재 v$($upd.Local) → 새 버전 v$($upd.Latest)")

$tmp = Join-Path $env:TEMP ('AutoMaintenance_Update_' + $upd.Latest.ToString() + '_' + (Get-Date -Format yyyyMMdd_HHmmss))
try {
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $zipPath = Join-Path $tmp 'update.zip'
  Write-Host '새 버전을 내려받는 중...'
  Invoke-WebRequest -Uri $upd.ZipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 180

  # 해시 검증 (릴리스에 .sha256 이 있을 때)
  if (-not [string]::IsNullOrWhiteSpace([string]$upd.HashUrl)) {
    Write-Host '파일 무결성 검사 중...'
    $hashPath = Join-Path $tmp 'update.sha256'
    Invoke-WebRequest -Uri $upd.HashUrl -OutFile $hashPath -UseBasicParsing -TimeoutSec 60
    $expected = @((Get-Content -LiteralPath $hashPath -Raw) -split '\s+' | Where-Object { $_ -match '^[0-9a-fA-F]{64}$' } | Select-Object -First 1)
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($expected.Count -eq 0) { Fail-Upd '릴리스의 해시 파일 형식이 올바르지 않습니다.' }
    if ($actual.ToLowerInvariant() -ne ([string]$expected[0]).ToLowerInvariant()) {
      Fail-Upd '다운로드한 ZIP 의 해시가 일치하지 않습니다. 파일이 변조되었을 수 있어 중단했습니다.'
    }
    Write-Host '해시 검사 통과'
  }

  Write-Host '압축 해제 중...'
  $extractDir = Join-Path $tmp 'extract'
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
  $newRoot = $extractDir
  if (-not (Test-Path -LiteralPath (Join-Path $newRoot 'install.ps1'))) {
    $sub = Get-ChildItem -LiteralPath $extractDir -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'install.ps1') } | Select-Object -First 1
    if ($null -eq $sub) { Fail-Upd 'ZIP 안에 install.ps1 이 없습니다.' }
    $newRoot = $sub.FullName
  }

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
