# Windows 유지보수 키트 상세

이 문서는 `I:\code\maintenance\` 작업 전용 상세다. 총괄 색인은 `I:\code\AGENTS.md`.

## 버전 / 배포 슬롯

- **버전은 `VERSION` 파일(1줄 버전 / 2줄 날짜)이 유일 기준**이고, 수정할 때마다 올린다
  (오류·문구=PATCH, 기능·동작=MINOR, 구조=MAJOR).
- **배포는 주 1회(토 00:00) 슬롯제**. `maintenance/UPDATE_SCHEDULE.md`가 유일 기준
  (2026-11-27 사용자 지정으로 기존 토 04:00에서 변경). 사용자가 수시로 알려주는 변경사항은
  관련 조치끼리 같은 주 슬롯에 묶고, 맞는 슬롯이 없으면 예약된 다음 주 빈 슬롯에 넣는다.
  새 슬롯을 임의로 만들지 말 것.
- 만료 없는 피드백 토큰만 12/21(1개월 뒤) 업데이트 항목에 함께 묶어 배포
  (만료일 있는 토큰 금지).
- PC 예약 작업: `OpenCode-Maintenance-AutoUpdate-Weekly`(매주 토 00:05 — 00:00 공개·적용
  직후 안정본 확인 설치) + `OpenCode-Maintenance-AutoUpdate-1Month`(12/21, 토큰 포함)
  + `OpenCode-Maintenance-PreVerify`(매일 23:30, 금요일 실행이 본배포 직전 검증).
  `install.ps1`은 점검 작업(매일 04:00)만 재등록하므로 업데이트·미리검증 작업은
  버전 설치에 영향 없음.

## 수정 후 순서

1. PS 5.1 파서 검사(5파일) + **UTF-8 BOM 유지** 확인
2. 필요 시 `dist\AutoMaintenance_v<버전>_<YYYYMMDD>.zip` 재빌드·검증
3. **이 PC에도 즉시 적용**

## 이 PC 적용 절차

`H:\AutoMaintenance_v<버전>` 새 폴더에 ZIP 추출 → `Simple maintenance`의 상태 파일
(`.last_*`, `config.json`, `*-state.json`, `last-result.json`, `adbackup`)·루트
`status.json`/`logs` 이어받기 → `install.ps1 -NoFirstRun` → 예약 작업
(`OpenCode-Maintenance`) Args·바탕화면 바로가기 경로 확인 → 옛 설치 폴더 삭제.

## 안전 원칙

- 자동 삭제·앱 제거·서드파티 업데이터 중지 금지. 삭제는 `y`를 눌러야만, 확인은 실행당 1회.
- 결과 파일 정리는 **이동만**(`자동점검결과` 폴더). 단 v1.4.0부터 이 키트가 만든 결과 txt 중
  3개월(90일) 지난 것만 `resultRetentionDays`로 묻지 않고 자동 삭제(사용자 명시 요청).
- 콘솔 표시 판정은 `run-maintenance.ps1` 한 곳에서만(직접 실행=보임 / 자동+유휴=예약 작업과
  별도로 새 powershell 창을 띄워 보임 / 자동+사용중=헤드리스 `CreateNoWindow`).
  `maintenance.ps1`에는 `-NoHideConsole`/`-HideConsole`로 결과만 전달.
- `dist/`·`status.json`·런타임 로그(`logs/`, `logs-legacy-*.txt`)는 커밋하지 않는다.
