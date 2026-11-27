# 자동 정리 스크립트 / 예약 작업 상세

이 문서는 `I:\code\scripts\` 작업 전용 상세다. 총괄 색인은 `I:\code\AGENTS.md`.

## 예약 작업

- `opencode-cleanup` (매주 일 03:00, SYSTEM, `-Force`): `I:\code\scripts\cleanup-opencode.ps1`
  — 마지막 수정 30일 초과 임시 코드/로그 영구 삭제(휴지통 이동),
  `I:\code\.cleanup-opencode\state.json` 추적.
- `OpenCode-IDriveCleanup-emp10%` (매주 일 04:00, SYSTEM, `-Force`,
  구 이름 `OpenCode-IDriveCleanup-6mo`에서 변경): `I:\code\scripts\cleanup-idrive.ps1`
  — `I:\` 마지막 수정 자료 + 완전 중복 모델 삭제, `idrive_deleted_manifest.csv`(UTF-8) 기록.
  - **보관 기간은 I: 여유 공간 연동**: 여유 ≥10% → 1년(365일), <10% → 5개월(150일)부터
    시작해 정리 후에도 <10%면 4개월(120일) → 3개월(90일) → 2개월(60일) → 1개월(30일)까지
    단계적 단축, 1개월에서도 부족하면 경고만 하고 그 이하로는 줄이지 않음.
  - 단계별 시뮬레이션(신규/누적 후보·확보량·예상 여유)을 로그에 출력.
  - **보호 경로는 OpenCode 구동 필수 요소만**: `I:\opencode`, `I:\code\.opencode`,
    `I:\code\scripts`, `I:\code\.cleanup-opencode`. 그 외(베이스 모델 캐시·gguf·어댑터·
    학습/음악/배포 자료)는 모두 기간 기준 삭제 범위.
  - 2026-11-27 직접 `-Force` 실행: 67개/109.97GB 삭제(여유 9.2% → 34.2%),
    로그 `I:\code\.cleanup-opencode\idrive_force_20261127.log`.
    원본 백업: `cleanup-idrive.ps1.bak-20261127`.
- `OpenCode-ReplayCleanup-3mo` (매주 월, `last_run.txt` 마커로 간격 보장):
  Replay outputs 3개월 초과 정리.

## 인코딩 / 로그

- ⚠️ 두 정리 스크립트는 **UTF-8 BOM 필수**: 예약 작업이 `powershell.exe`(5.1)를 쓰므로
  BOM 없이 저장하면 한글 리터럴이 cp949로 깨져 파서 에러 → 작업 RESULT=1.
  수정 후 반드시 PS 5.1 파서 검사 + BOM 확인.
- 로그는 `I:\code\.cleanup-opencode\autocleanup.log`, `idrive_autorun.log`
  (PS 5.1 `*>` 리다이렉트라 **UTF-16LE**) → `Get-Content -Encoding Unicode` 로 읽을 것.
