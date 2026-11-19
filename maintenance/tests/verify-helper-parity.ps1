# -*- coding: utf-8 -*-
# ConvertTo-CliArg / Join-CliArgs 사본 간 드리프트 검증 (PS 5.1)
# 사용법: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-helper-parity.ps1
# Exit 0 = 모두 동일, Exit 1 = 사본 간 차이 또는 누락

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$root = Split-Path -Parent $root  # tests\ 의 부모 = 키트 루트

$files = @(
  'install.ps1',
  'run-maintenance.ps1',
  'run-now.ps1',
  'uninstall.ps1',
  '업데이트.ps1',
  (Join-Path 'Simple maintenance' 'maintenance.ps1')
)

# CRLF/LF 차이는 무시하고 함수 본문만 비교한다.
$pattern = '(?ms)^function ConvertTo-CliArg \{.*?^function Join-CliArgs \{.*?^\}'
$sha = New-Object Security.Cryptography.SHA256Managed
$groups = @{}

foreach ($rel in $files) {
  $path = Join-Path $root $rel
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Write-Output "FAIL: 파일 없음 - $rel"
    exit 1
  }
  $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) -replace "`r`n", "`n"
  $m = [regex]::Match($text, $pattern)
  if (-not $m.Success) {
    Write-Output "FAIL: 헬퍼 함수를 찾지 못함 - $rel"
    exit 1
  }
  $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($m.Value))).Replace('-', '')
  if (-not $groups.ContainsKey($hash)) { $groups[$hash] = @() }
  $groups[$hash] += $rel
  Write-Output ("{0,-42} {1}" -f $rel, $hash.Substring(0, 12))
}

if ($groups.Count -gt 1) {
  Write-Output ''
  Write-Output 'FAIL: 헬퍼 사본 간 차이가 있습니다. 아래 그룹을 동일하게 맞추세요.'
  $i = 0
  foreach ($k in $groups.Keys) {
    $i++
    Write-Output ("  그룹 {0}: {1}" -f $i, ($groups[$k] -join ', '))
  }
  exit 1
}

Write-Output ''
Write-Output ("PASS: {0}개 사본이 모두 동일합니다." -f $files.Count)
exit 0
