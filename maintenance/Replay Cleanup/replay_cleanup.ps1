# -*- coding: utf-8 -*-
# Replay 변환 파일 정리 스크립트
# outputs 폴더의 파일 중 마지막 수정 3개월이 지난 것만 삭제.
# 마커 파일(last_run.txt)로 실제 삭제 간격을 3개월로 유지.
# 스케줄은 자주 돌아도 마커 때문에 3개월 안에는 삭제하지 않음 (재부팅으로 밀려도 안전).
param(
    [switch]$WhatIf,   # 실제 삭제 없이 대상 개수/용량만 출력
    [switch]$Force,    # 마커 무시하고 지금 즉시 삭제 (테스트용)
    [int]$Months = 3
)

$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Target     = 'C:\Users\dal04\AppData\Roaming\Replay\com.replay.Replay\outputs'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$MarkerFile = Join-Path $ScriptDir 'last_run.txt'
$LogFile    = Join-Path $ScriptDir 'replay_cleanup.log'
$Cutoff     = (Get-Date).AddMonths(-$Months)

function Write-Log($msg) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    ("$stamp  $msg") | Add-Content -Path $LogFile -Encoding UTF8
    Write-Host $msg
}

# --- 3개월 간격 마커 체크 (Force 제외) ---
if (-not $Force) {
    if (Test-Path -LiteralPath $MarkerFile) {
        try {
            $last = [datetime]::Parse((Get-Content -LiteralPath $MarkerFile -Raw).Trim())
            if ($last.AddMonths($Months) -gt (Get-Date)) {
                Write-Host "아직 3개월이 안 지났습니다. (마지막 정리: $($last.ToString('yyyy-MM-dd')))"
                exit 0
            }
        } catch { /* 마커 깨짐 -> 무시하고 진행 */ }
    }
}

if (-not (Test-Path -LiteralPath $Target)) {
    Write-Log "대상 폴더 없음 (건너뜀): $Target"
    exit 0
}

$files      = Get-ChildItem $Target -File -Recurse -Force
$old        = $files | Where-Object { $_.LastWriteTime -lt $Cutoff }
$totalAllGB = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1GB, 2)
$oldGB      = [math]::Round(($old | Measure-Object Length -Sum).Sum / 1GB, 2)

Write-Log "=== Replay 정리 시작 (cutoff: $($Cutoff.ToString('yyyy-MM-dd'))) ==="
Write-Log "전체: $($files.Count) files / ${totalAllGB}GB  ->  대상: $($old.Count) files / ${oldGB}GB"

if ($old.Count -eq 0) {
    Write-Log "삭제할 파일 없음."
    exit 0
}

$deleted = 0; $failed = 0; $freedMB = 0
foreach ($f in $old) {
    if ($WhatIf) {
        Write-Host ("  [대상] {0,8:N1}MB  {1}" -f ($f.Length/1MB), $f.FullName)
        continue
    }
    try {
        Remove-Item -LiteralPath $f.FullName -Force
        $deleted++; $freedMB += $f.Length
    } catch {
        $failed++
        Write-Log "  실패: $($f.FullName) ($($_.Exception.Message))"
    }
}

# --- 빈 폴더 정리 (깊은 것부터) ---
if (-not $WhatIf) {
    Get-ChildItem $Target -Directory -Recurse -Force |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            if (-not (Get-ChildItem $_.FullName -Force)) {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force
            }
        }
}

if ($WhatIf) {
    Write-Host ""
    Write-Log "[WhatIf] $($old.Count) 파일 / ${oldGB}GB 가 삭제 대상입니다. 실제 삭제 안 함."
} else {
    Write-Log "완료: 삭제 $deleted / 실패 $failed / 확보 $([math]::Round($freedMB/1MB,0))MB"
    (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') | Set-Content -LiteralPath $MarkerFile -Encoding UTF8
    Write-Log "마커 갱신 완료. 다음 정리는 3개월 후 자동."
}