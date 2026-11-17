# Windows 자동 유지보수 키트 (v1.4.0)
# Windows Auto Maintenance Kit (v1.4.0)

🪟🔧✨ 컴퓨터를 잘 모르는 사람도 3단계로 설치하고, 이후에는 아무것도 하지 않아도 6일에 한 번 스스로 점검하는 윈도우 유지보수 도구입니다.
🪟🔧✨ A Windows maintenance tool that anyone can install in 3 steps, then forget about — it checks itself every 6 days automatically.

---

## 목차 / Table of Contents

| 한국어 | English |
|---|---|
| [이건 뭐예요?](#이건-뭐예요) | [What is this?](#what-is-this) |
| [왜 만들었나요?](#왜-만들었나요) | [Why was it made?](#why-was-it-made) |
| [안전 원칙](#안전-원칙) | [Safety principles](#safety-principles) |
| [빠른 시작 (3단계)](#빠른-시작-3단계) | [Quick start (3 steps)](#quick-start-3-steps) |
| [38개 검사 항목](#38개-검사-항목) | [38 checks](#38-checks) |
| [결과 읽는 법](#결과-읽는-법) | [How to read the report](#how-to-read-the-report) |
| [피드백 보내기](#피드백-보내기) | [Send feedback](#send-feedback) |
| [파일 구성](#파일-구성) | [File layout](#file-layout) |
| [설정](#설정) | [Configuration](#configuration) |
| [자주 묻는 질문](#자주-묻는-질문) | [FAQ](#faq) |
| [면책 / Disclaimer](#면책--disclaimer) | [Disclaimer](#disclaimer) |

---

## 이건 뭐예요 / What is this?

**한국어**
윈도우 PC가 켜져 있는 동안 백그라운에서 조용히健康检查을 하는 도구입니다.
- 스케줄 태스크가 매일 04:00(및 로그온 5분 후)에 "오늘 점검할 차례인가?"만 확인합니다.
- 실제 점검은 **6일에 한 번** 실행됩니다(설정으로 변경 가능).
- 발견한 문제 중 **안전하다고 판단된 것만 자동으로 고치고**, 나머지는 결과 파일에 적어 알려줍니다.
- 사진·문서·다운로드 같은 **사용자 파일은 절대 지우지 않습니다.**

**English**
A tool that quietly runs health checks on your Windows PC in the background.
- A scheduled task checks daily at 04:00 (and 5 min after logon) whether a check is due.
- The actual scan runs **every 6 days** (configurable).
- It **auto-repairs only what is safe**, and reports everything else in a text file.
- It **never deletes your personal files** (photos, documents, downloads).

```
install.cmd (1회 / once)
   └─ install.ps1  → 예약 작업 등록 + 바탕화면 바로가기 3개
        └─ OpenCode-Maintenance (매일 / daily 04:00 + logon+5m)
              └─ run-maintenance.ps1   (주기 게이트 / cadence gate)
                    └─ Simple maintenance\maintenance.ps1  (38단계 실제 점검)
```

---

## 왜 만들었나요 / Why was it made?

**한국어**
윈도우는 시간이 지나면서 임시 파일이 쌓이고, 설정이 어긋나고, 백신이 꺼지고, 하드디스크에 나쁜 섹터가 생깁니다.
이런 것들을 하나씩 수동으로 확인하려면 30개가 넘는 명령어를 알아야 합니다.
이 키트는 그걸 **한 번에, 자동으로, 안전하게** 해줍니다.

**English**
Over time, Windows accumulates temp files, settings drift, antivirus turns off, and disks develop bad sectors.
Checking all of that manually means knowing 30+ commands.
This kit does it **all at once, automatically, and safely**.

---

## 안전 원칙 / Safety principles

**한국어**
| 원칙 | 설명 |
|---|---|
| 자동 삭제 없음 | 임시 파일·캐시·휴지통도 목록을 보여주고 `y` 를 눌러야만 지웁니다. |
| 100MB 남아도 자동 삭제 금지 | 디스크가 거의 꽉 찼어도 사용자 파일을 실수로 지우지 않게 하려는 안전 장치입니다. |
| 확인은 실행당 1회 | 삭제 확인 프롬프트는 한 번 실행에 한 번만 뜹니다. |
| 위험한 명령 금지 | `w32tm /unregister` 같은 위험한 명령은 쓰지 않습니다. |
| 사용자 파일 보호 | 사진·문서·다운로드·바탕화면 파일은 건드리지 않습니다. |

**English**
| Principle | Details |
|---|---|
| No automatic deletion | Even temp/cache/recycle-bin items are only removed after showing a list and requiring `y`. |
| No auto-delete at 100MB free | Even when the disk is nearly full, user files are never auto-removed. |
| One confirmation per run | The delete prompt appears at most once per execution. |
| No dangerous commands | e.g. `w32tm /unregister` is never used. |
| User files protected | Photos, documents, downloads, Desktop files are untouched. |

---

## 빠른 시작 (3단계) / Quick start (3 steps)

**한국어**
1. ZIP을 받아 **폴더째로** 풀고, `install.cmd` 를 **더블클릭**합니다. (`.ps1` 은 메모장으로 열리므로 `.cmd` 를 쓰세요.)
   - 파란 확인 창에서 **"예"** → 첫 점검 끝까지 대기(약 1분).
2. 그 뒤로는 **아무것도 하지 않아도 됩니다.** PC가 켜져 있으면 6일에 한 번 자동 점검합니다.
3. 결과는 바탕화면 `자동유지보수_날짜시간.txt` 에 적힙니다. **맨 위 3줄만** 보면 됩니다.
   - 지금 바로 점검: 바탕화면 **"자동 유지보수 점검"** 더블클릭
   - 자동 점검 끄기: 바탕화면 **"자동 유지보수 제거"** 더블클릭 (로그·설정은 보존)
   - 컴퓨터를 전혀 모른다면: **`maintenance/newbie.txt`** 를 먼저 읽어보세요. 38개 검사를 레고·집·주방 비유로 설명합니다.

**English**
1. Download the ZIP, extract the **whole folder**, and **double-click `install.cmd`**. (Use `.cmd` — `.ps1` opens in Notepad.)
   - Click **"Yes"** in the blue UAC prompt, then wait for the first check (~1 min).
2. After that, **do nothing.** It checks itself every 6 days while the PC is on.
3. Results go to `자동유지보수_날짜시간.txt` on your Desktop. **Read only the top 3 lines.**
   - Check now: double-click **"자동 유지보수 점검"** on the Desktop.
   - Disable: double-click **"자동 유지보수 제거"** (logs and settings are kept).
   - Brand new to computers? Read **`maintenance/newbie.txt`** first — it explains all 38 checks with Lego/house/kitchen analogies.

---

## 38개 검사 항목 / 38 checks

**한국어** — 가벼운 검사는 매 실행(6일), 무거운 검사는 주기를 늘렸습니다.

| 구분 / Category | 검사 / Checks | 주기 / Cadence |
|---|---|---|
| 매 실행 / Every run | OS, CPU, Memory, Disk, Service, VSS, DiskHealth, SysFix, SecureBoot, Recovery, WMI, CertStore, TaskHealth, GPU, Battery, WHEA, DriverStore, BrowserCache, HostFile, DNS, AdQuiet, AdFilter, Network, GhostDev, PkgCache, Startup, RecycleBin, RegHive, BSOD, Defrag(상태만), TimeSync, Stability, BootPerf, Updates, Auto-Heal | 6일 / 6 days |
| 12일 / 12 days | CHKDSK (`/scan`, 모든 NTFS 볼륨) — 2~3분 걸려서 2회에 1번 | 12일 |
| 30일 / 30 days | SFC (`/verifyonly`) + WinSxS(DISM 분석/정리) + 정품 인증 확인 | 30일 |

**English** — Light checks run every cycle (6 days); heavy checks are gated by elapsed days.

| Category | Checks | Cadence |
|---|---|---|
| Every run | OS, CPU, Memory, Disk, Service, VSS, DiskHealth, SysFix, SecureBoot, Recovery, WMI, CertStore, TaskHealth, GPU, Battery, WHEA, DriverStore, BrowserCache, HostFile, DNS, AdQuiet, AdFilter, Network, GhostDev, PkgCache, Startup, RecycleBin, RegHive, BSOD, Defrag (status only), TimeSync, Stability, BootPerf, Updates, Auto-Heal | 6 days |
| CHKDSK | `/scan` on all NTFS volumes (2–3 min) | 12 days |
| Heavy | SFC (`/verifyonly`), WinSxS (DISM analyze/cleanup), license status | 30 days |

핵심 검사 Explained:
- **SFC** = 레고 설명서(정상 윈도우)와 내 작품(현재 PC)을 비교해 잘못 끼운 블록을 새 블록으로 교체합니다.
  Compares the original Lego manual (healthy Windows) with your build (current PC) and replaces wrong blocks with fresh ones.
- **CHKDSK** = 책장(디스크)의 찢어진 페이지를 찾아 복구합니다. Finds and repairs torn pages in the bookshelf (disk).
- **DiskHealth** = 하드디스크가 스스로 쓴 건강 진단서(SMART)를 읽습니다. Reads the disk's own health report (SMART).
- **AdQuiet / AdFilter** = 윈도우 추천 알림을 끄고(선택), hosts 파일로 광고를 차단합니다(선택·되돌리기 가능). Mutes Windows promos (opt-in) and blocks ads via hosts file (opt-in, reversible).

---

## 결과 읽는 법 / How to read the report

**한국어**
결과 파일 맨 위 3줄:
- `정상 — 문제를 찾지 못했습니다` → 아무 문제 없음. 안심.
- `확인이 필요한 항목이 있습니다` → 자동으로 못 고친 게 1~2개. 아래 [직접 확인할 것] 을 보세요.
- `자동으로 고친 것: N건` → 컴퓨터가 알아서 고침. 할 일 없음.

상태 단어:
`PASS` 통과 · `WARN` 확인 권장 · `FAIL` 고쳐야 함 · `FIX` 자동 수리됨 · `SKIP` 오늘은 안 하는 검사

**English**
Top 3 lines of the report:
- `정상 — 문제를 찾지 못했습니다` → No issues found. All good.
- `확인이 필요한 항목이 있습니다` → 1–2 items couldn't be auto-fixed. See the "check manually" section below.
- `자동으로 고친 것: N건` → N items were auto-repaired. Nothing to do.

Status words:
`PASS` ok · `WARN` worth checking · `FAIL` needs action · `FIX` auto-repaired · `SKIP` not scheduled today

---

## 피드백 보내기 / Send feedback

**한국어**
바탕화면 **"자동 유지보수 피드백"** 더블클릭 → `feedback.ps1` 이 민감정보를 지운 사본을 바탕화면에 만들고 메모장으로 엽니다.
- 자동으로 지우는 것: 사용자 경로, hosts 도메인, IP, MAC, 이메일, SSID, 시리얼, `도메인\사용자`
- 남기는 것(진단용): PASS/WARN/FAIL 상태, 단계 이름, 수리 건수, KB 번호
- **네트워크로 자동 전송하지 않습니다.** 직접 확인·편집한 뒤 GitHub Discussion에 붙여넣으세요.
- 셀프 테스트: `powershell -File feedback.ps1 -SelfTest` → **10/10 PASS**

Discussions: https://github.com/argenluna/maintenance/discussions

**English**
Double-click **"자동 유지보수 피드백"** on the Desktop → `feedback.ps1` creates a masked copy on the Desktop and opens it in Notepad.
- Auto-masked: user paths, hosts domains, IP, MAC, email, SSID, serial, `DOMAIN\user`
- Kept for diagnosis: PASS/WARN/FAIL status, check names, repair counts, KB numbers
- **Nothing is uploaded automatically.** Review/edit it yourself, then paste it into a GitHub Discussion.
- Self-test: `powershell -File feedback.ps1 -SelfTest` → **10/10 PASS**

---

## 파일 구성 / File layout

`maintenance/` 폴더 안:

| 파일 / File | 역할 / Role |
|---|---|
| `install.cmd` | 더블클릭 진입점 (ASCII 전용) / Double-click entry point (ASCII only) |
| `install.ps1` | 설치: 승격 → 문법검사 → 예약 작업 → 바로가기 3개 → 첫 점검 / Install |
| `newbie.txt` | 완전 초보자용 38기능 비유 설명서 / Beginner guide with analogies |
| `readme.txt` | 일반 사용자용 사용법 / User guide |
| `README.md` |개발자 문서 / Developer documentation |
| `run-maintenance.ps1` | 주기 게이트, 예약 작업 대상 / Cadence gate, scheduled task target |
| `run-now.ps1` | "지금 점검" 바로가기 / "Check now" shortcut |
| `feedback.ps1` | 민감정보 마스킹 피드백 생성 / Masked feedback generator |
| `uninstall.ps1` | 예약 작업/바로가기 제거, `-RestoreAds` 로 광고 설정 복원 / Uninstall |
| `Simple maintenance\maintenance.ps1` | 실제 점검/자동 수리 (38단계) / Actual checks |
| `config.json`, `Simple maintenance\config.json` | 설정 / Configuration |

---

## 설정 / Configuration

`config.json` (또는 `Simple maintenance\config.json`):

| 키 / Key | 기본값 / Default | 뜻 / Meaning |
|---|---|---|
| `maintenanceCadenceHours` | `144` | 점검 주기(시간) = 6일 / Check interval in hours (6 days) |
| `resultRetentionDays` | `90` | 이 키트가 만든 결과 txt 중 90일 지난 것만 자동 삭제 / Auto-delete only this kit's result txt older than 90 days |
| `chkdskDays` | `12` | CHKDSK 주기 / CHKDSK interval |
| `heavyCheckDays` | `30` | SFC/DISM 주기 / SFC/DISM interval |
| `licenseCheckDays` | `30` | 정품 인증 확인 주기 / License check interval |
| `idleConsoleMinutes` | `5` | 자동+사용중일 때 헤드리스 실행 / Headless when user is active |
| `adQuiet` | `true` | 추천 알림 끄기 / Mute promos |
| `adBlockEnabled` | `false` | hosts 광고 차단(선택) / hosts ad blocking (opt-in) |

---

## 자주 묻는 질문 / FAQ

**Q. 백신이 경고합니다. 바이러스인가요? / Antivirus flags it. Is it a virus?**
**A.** 아니요. 서비스·예약 작업·레지스트리·hosts·광고 설정을 만져서 민감하게 반응하는 것입니다. 사용자 파일을 지우거나 해킹하지 않습니다.
No. It touches services, tasks, registry, hosts and ad settings, so antivirus may react. It never deletes user files or phones home.

**Q. 6일이 너무 길어요. / 6 days is too long.**
**A.** `maintenanceCadenceHours` 를 줄이면 됩니다. 다만 24시간으로 줄이면 WHEA/GPU/BSOD 중복제거가 없어 가짜 FAIL이 늘어납니다. 144시간(6일)을 권장합니다.
Change `maintenanceCadenceHours`. But at 24h, WHEA/GPU/BSOD dedupe breaks and false FAILs appear. 144h is recommended.

**Q. 설치를 되돌리려면? / How to undo?**
**A.** 바탕화면 **"자동 유지보수 제거"** 더블클릭. 예약 작업·바로가기를 지우고 광고 설정도 원래대로 복원합니다(로그·설정은 보존). 광고만 복원하려면 `uninstall.ps1 -RestoreAds`.
Double-click **"자동 유지보수 제거"**. It removes the task/shortcuts and restores ad settings (logs kept). For ads only: `uninstall.ps1 -RestoreAds`.

**Q. 프로필 사진に GIF 써도 되나요? / Can I use a GIF avatar?**
**A.** 네, GitHub은 PNG·GIF·JPG 아바타를 허용합니다. / Yes — GitHub accepts PNG, GIF and JPG avatars.

---

## 면책 / Disclaimer

**한국어**
이 키트는 개인용 비공식 도구이며 Microsoft 및 각 제조사와 무관합니다. 서비스·예약 작업·레지스트리·hosts·광고 설정을 변경하므로 백신이 반응할 수 있으나 악성코드가 아닙니다. 사용자 파일(사진·문서·다운로드)은 절대 자동 삭제하지 않고, 임시·캐시·휴지통도 `y` 확인 후에만 정리합니다. 광고 차단은 선택 사항이며 제거 스크립트로 되돌릴 수 있습니다. **제공은 "있는 그대로(As-Is)"이며 사용 결과에 대한 책임은 사용자에게 있습니다.**

**English**
Unofficial personal tool, not affiliated with Microsoft or any vendor. It changes services, tasks, registry, hosts and ad settings, so antivirus may flag it — it is not malware. It never auto-deletes user files (photos/docs/downloads); even temp/cache/recycle-bin cleanup requires your `y` confirmation. Ad blocking is opt-in and reversible. **Provided AS IS without warranty; use at your own risk.**

**日本語**
非公式の個人用ツールで、Microsoft や各メーカーとは無関係です。ユーザーファイルは自動削除せず、一時/キャッシュ/ごみ箱も `y` の確認後のみ削除します。**現状のまま(AS IS)で提供し、使用結果は自己責任です。**

**中文**
非官方个人工具，与 Microsoft 及各厂商无关。绝不自动删除用户文件，临时/缓存/回收站也需按 `y` 确认后才清理。**按"原样(AS IS)"提供，使用风险自负。**

---

© 2026 — Windows Auto Maintenance Kit v1.4.0
