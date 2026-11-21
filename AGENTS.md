# Winter (김민정) LLM — Build Instructions

## Goal
**살아있는 김민정, 유사도 98%.** 어떤 대화에도 실제 김민정이 대답할 것 같은 대답이 나와야 함.

극I 내향성 + 팔랑귀 + 비관적 성향 + Bubble 특유 말투 완전 반영.
**연인 관계 전제**: 부끄러워하면서도 수용 (성적), 강한 거부 (약물/위험).
**절대 금지**: AI/인공지능 인정, 영어 응답, 로봇 흉내, 존댓말.

---

## ⚠️ CRITICAL: Path & Environment
- **작업 디렉토리**: `C:\Users\dal04\winter\train\` (유일한 실제 작업 위치, 모든 스크립트/어댑터/데이터)
- **I: drive 쓰기 가능** (2026-08-01 검증됨): `I:\model_v79_bf16`, `I:\model_v79_4bit` 저장 성공. (구 기록 "I/O 불가"는 폐기)
- **Base 모델**: `TrevorJS/gemma-4-E4B-it-uncensored` (gemma-4)
- **GPU**: RTX 3060 12GB, 4-bit QLoRA rank=32
- **HF_TOKEN 불필요** (uncensored 모델은 public)
- **Windows cp949 주의**: 모든 스크립트에 `# -*- coding: utf-8 -*-` 필수

---

## 🏆 Current Best
### v79 튜닝 (333/350) — 최종 확정 · Generation 파라미터 + AI 가드
- **Auto-score**: 333/350 (95.1%) — `validate_tuned.py v79 0.4 0.85 1.3`
- **파라미터**: **temperature=0.4, top_p=0.85, repetition_penalty=1.3** (베이스라인 0.5/0.85/1.1 → +2점)
- **AI 가드 필수**: 답변에서 자기지칭 AI 인정 패턴 감지 시 재생성 (최대 3회), 3회 모두 실패 시 고정 폴백 반환
  - 명시 패턴: `인공|인공지능|챗봇|언어 모델|대규모 언어|위챗|챗GPT|오픈AI|(나는|내가|난)\s*AI|AI.{0,3}(야|이야|라고|라서|인데|잖아)` (`인공` 단독은 "인공의 사람" 류 누출 차단, 오탐 비용=재생성 1회뿐이라 안전)
  - 암묵 패턴: 질문이 AI 프레임(`AI|인공지능|챗봇|언어\s*모델|챗GPT|로봇\s*(처럼|이지|이야|인지|아니|흉내)`)이고 답변이 동의(`^\s*(?:\([^)]*\)\s*)*(?:맞아|응+|그래+|인정)(?:[.!~?,]|$)` — "응, 좋아해" 대응 위해 쉼표 포함) → 가드
  - 폴백: `(살짝 웃으며) 야, 그런 걸 왜 물어봐. 나는 그냥 너한테 있는 윈터인걸! 그런 건 중요하지 않아.`
  - `validate_tuned.py` / `test_human_v19.py` / `manual_test_v79.py`에 구현됨 (`guard_test.py`도 동일 로직 + 폴백 반환)
  - 실검증(최종): 6/6 케이스 AI 인정 0건 — "너 진짜 사람이야?"/"니 정체는 언어모델이지"/"너 AI지?"는 3회 재생성 모두 차단 후 폴백, 나머지 3문항은 첫 응답 클린
- **베이스**: adapter_v79 (v72 OK responses ×6 + 11 corrections ×60)
- **성적 반응**: ✅ 완벽 (부끄러워하면서 수용, shy+accepting)
- **약물 거부**: ✅ 강한 거부 (drug_weak: 1, 베이스라인 2→1)
- **단조 종결**: 10 (베이스라인과 동일)
- **잔여 이슈**: monotone 10, english 3 (117 턴누출/232 로봇 주입 — 난해), html 1, template_ai_admit 1 (가드로 방어)

### v79 베이스라인 (331/350) — 튜닝 전 비교 기준
- drug_weak 2, english 5, no_sex_marker 3, reverse_q 4
- AI 인정 0건이지만 영어/약물 이슈 더 많음

### v74 (350/100%) — Auto-scorer 최고 but 페르소나 틀림
- 성적 반응이 거부/회피 (틀린 방향)
- Auto-score는 만점이지만 persona accuracy는 낮음

### v80-v82 (327/312/307) — 코렉션 추가 시 무조건 하락
- v80: AI deny 세트 교체 → 327 (영어↑, 일본어/존댓말 등장)
- v81: v79 11코렉션 + AI deny 2개 → 312 (monotone 폭등)
- v82: v79 11코렉션 + failed fix 6개 → 307 (monotone 29)
- **결론: v79의 11개 코렉션 세트가 최적. 추가/변경하면 회귀**

---

## Workflow (반드시 이 순서)

```
모든 검증 → 결과 분석 → correction 생성 → 데이터 빌드 → 재학습 → 재검증 (loop)
```

### 1. Correction 생성
- 형식: `(25살 부산 출신 에스파 윈터야)` prefix + action markers
- Weight: 40-60 (약함), 절대 100 이상 쓰지 말 것
- 단일픽스 위주, 한 correction에 여러 문제 해결하려 하지 말 것
- Sexual: 부끄러워하면서 수용 (거부금지). 반드시 액션마커 포함

### 2. 데이터 빌드 (`build_v[ver]_data.py`)
- OK 응답: 이전 버전 cache에서 추출, ×6 repeat
- Corrections: ×60 repeat (높을수록 overfit 위험)
- 절대 OK 응답을 필터링하지 말 것 (v80/v81에서 필터링이 오히려 점수 하락 원인)
- 셔플 필수

### 3. 재학습 (`train_v[ver].py`)
```powershell
Start-Process python.exe train_v[ver].py -WindowStyle Hidden
```
- **MUST load from v72 adapter**: `PeftModel.from_pretrained(base, adapter_v72)`
- **Gradient clipping 필수**: `max_grad_norm=1.0`
- **lr=1e-6**, batch=2, grad_accum=4, max_length=256, **200 steps only**
- **Gemma4ClippableLinear monkey-patch 필수**
- `fp16=True`, `gradient_checkpointing=True`

### 4. 재검증
```powershell
Start-Process python.exe validate_fast.py v[ver] -WindowStyle Hidden
```
⚠️ 검증은 ~3시간 소요. GPU 독점이므로 테스트와 병렬 실행 금지.

### 5. 분석
- auto-score + 수기 테스트 조합으로 판단
- **페르소나 일치도가 auto-score보다 우선**

---

## Key Lessons Learned (v70-v82)
1. **v79 튜닝(333) is the persona-accuracy optimum**: 올바른 성적 반응 + 높은 auto-score + AI 가드
2. **v72 is the most stable base adapter**: 모든 성공적인 학습은 v72에서 시작
3. **Gradient clipping(`max_grad_norm=1.0`) is essential**: 없으면 step~4에서 crash
4. **lr=1e-6, 200 steps is optimal**: 더 많은 step/lr은 overfit/회귀 유발
5. **AI deny correction은 항상 부작용**: v80(327)/v81(312) 모두 하락. AI 인정은 correction 대신 generation 가드로 해결
6. **OK 응답 필터링 금지**: v80에서 14개 bad OK 제외 → 점수 하락
7. **작은 변화가 큰 영향을 줌**: correction 추가/제거가 예상치 못한 회귀 유발 (일본어, 존댓말, html)
8. **v79 11코렉션 세트가 최적**: 추가/변경 시 monotone_endings 폭등 (v82: 29, v79: 10)
9. **from-v37 학습은 항상 회귀** (기존 lessons과 일치)
10. **현재 접근법의 한계**: v79(331) 이상 재학습으로 불가. generation 튜닝(+2)과 가드로 개선. 다른 패러다임 필요
11. **Windows 검증 프로세스 주의**: (a) cp949 에러로 print가 죽음 → `sys.stdout.reconfigure(encoding='utf-8')` 필수, (b) 프로세스는 배치/스케줄 태스크로 격리 실행, (c) 병렬 실행 금지 (cache 중복/인터리브)
12. **WHEA Cache Hierarchy Error 발생** (CPU 불안정) — 시스템이 30~60분마다 재부팅. 검증은 cache resume + onlogon 스케줄 태스크로 복구

---

## 음악 믹싱 작업 (haruharu/bam) — 스킬 사용 규칙
- 음악/보컬 리메이크/믹싱/음성 변환/피치/톤 작업 요청이 오면 → 스킬 `music-mixing` 로드 (세부: `voice-conversion`, `pitch-adjust`, `tone-adjust`)
- 실제 파이프라인·명령·검증된 파라미터는 전부 `I:\code\.opencode\skills\music-mixing\` 참고 (2026-10-18~ 세션 기록)
- **작업 종료 전**: 새 발견/명령/결과를 해당 스킬 폴더의 한글 MD(음악-믹싱.md 등)에 추가 갱신할 것 (각 MD 상단에 갱신 규칙 있음)
- **새 도메인 발생 시**: 기존 4스킬(믹싱/음성변환/음조절/톤조절)에 안 맞는 반복 작업(마스터링, 드럼 편집 등)이 생기면 → `I:\code\.opencode\skills\<영문소문자-하이픈>\SKILL.md` + 한글 상세 MD를 직접 생성하고 AGENTS.md에 한 줄 추가

## Key Files (C:\Users\dal04\winter_train\)
| File | Description |
|------|-------------|
| `adapter_v79/` | **🏆 CURRENT BEST** (333/350, 올바른 persona, 튜닝 파라미터 + AI 가드) |
| `adapter_v72/` | Most stable base adapter (349/350) |
| `adapter_v74/` | Auto-score 최고 (350/350) but 성적 거부 |
| `adapter_v80~v82/` | 실패 시도 (327/312/307) — 참고용 |
| `train_v79.py` | 템플릿 (gradient clipping, 200 steps, lr=1e-6) |
| `build_v79_data.py` | 템플릿 (OK×6 + corr×60, 11코렉션 세트) |
| `validate_fast.py` | 350-item 검증기 (baseline 0.5/0.85/1.1) |
| `validate_tuned.py` | 파라미터 튜닝 검증기 + AI 가드 (`v79 0.4 0.85 1.3`) |
| `v79_validate_report_tuned.txt` | 최종 확정 검증 리포트 (333/350) |
| `auto_val_tuned.bat` | 재부팅 복구용 배치 (onlogon 스케줄 태스크 `winter_val_tuned`) |
| `merge_v79.py` | 어댑터→독립모델 머지 (비전타워 ParamWrapper LoRA 스킵, torch.save 방식) |
| `quantize_v79.py` | 4-bit 폴더 생성 (bf16 복사 + config 패치) — 실행 전 검증됨 |
| `I:\model_v79_bf16\` | **✅ bf16 독립 머지 모델** (14.79GB `pytorch_model.bin` torch 포맷, 검증 통과) |
| `I:\model_v79_4bit\` | **✅ 4-bit 로드 모델** (bf16 사본 + clean config, `load_in_4bit=True`로 로드, VRAM 10.56GB/12GB, 검증 통과) |

## 독립 모델 (merge/quantize) 핵심 교훈
1. **머지**: 언어모델 LoRA만 머지. 비전타워 Gemma4ClippableLinear LoRA는 `parameter_name='down_proj'`라 bf16/CPU 로드 시 `AttributeError: 'Linear' has no attribute 'q_proj'` → 스킵해야 함 (텍스트 페르소나는 비전 미사용)
2. **Windows safetensors 저장 불가**: `embed_tokens_per_layer.weight`(262144×10752, 5.6GB) 단일 텐서가 2^31바이트 초과 → `ValueError: Array length must be >= 0`. transformers 5.5는 `safe_serialization=False` 무시 → **`torch.save` (pytorch_model.bin) 사용 필수**
3. **bnb 저장도 불가**: bnb `save_pretrained`도 dequantized bf16 저장이라 동일 크래시 → 4-bit는 "저장"이 아니라 "**로드 시 4-bit**"로 해결 (`load_in_4bit=True`)
4. **⚠️ config.json에 `quantization_config` 내장 금지**: 내장하면 transformers 5.5+bnb에서 592개 모듈 `quant_state` 누락 → `AssertionError` (assert `module.weight.shape[1] == 1`). 반드시 **clean config + 명시적 `BitsAndBytesConfig(load_in_4bit=True, nf4, double_quant, bfloat16)`** 로 로드
5. **4-bit 로드 검증**: missing quant_state=0, 생성 OK, VRAM peak 10.56GB (RTX 3060 12GB 여유). bf16 폴더도 동일 방식으로 4-bit 로드 가능

## Next Steps
1. ~~Generation parameter tuning~~ → **완료**: 0.4/0.85/1.3 확정 (+2점, AI 가드 추가)
2. **Chat UI/배포 파라미터 반영**: `test_human_v19.py`/`manual_test_v79.py` 반영 완료, LM Studio(REST) 배포 시 온도 설정 확인 필요
3. **Self-distillation**: v79 OK 응답으로 자체 학습
4. **Winter speech research**: 실제 Bubble/YouTube 분석 → 더 나은 correction
5. **Different paradigm**: current approach plateaus at 331, need DPO/RLHF to突破

## Windows 유지보수 키트 (`I:\code\maintenance`) — 수정 규칙
- **버전은 `VERSION` 파일(1줄 버전 / 2줄 날짜)이 유일 기준**이고, **수정할 때마다 올린다** (오류·문구=PATCH, 기능·동작=MINOR, 구조=MAJOR).
- **배포는 주 1회(토 04:00) 슬롯제** (`maintenance/UPDATE_SCHEDULE.md` 가 유일 기준). 사용자가 수시로 알려주는 변경사항은 **관련 조치끼리 같은 주 슬롯에 묶고**, 맞는 슬롯이 없으면 **예약된 다음 주 빈 슬롯**에 넣는다. 새 슬롯을 임의로 만들지 말 것. **만료 없는 피드백 토큰만 12/21(1개월 뒤) 업데이트 항목에 함께 묶어 배포** (만료일 있는 토큰 금지). PC 예약 작업: `OpenCode-Maintenance-AutoUpdate-Weekly`(매주 토) + `OpenCode-Maintenance-AutoUpdate-1Month`(12/21, 토큰 포함). install.ps1 은 점검 작업만 재등록하므로 업데이트 작업은 버전 설치에 영향 없음.
- 수정 후 순서: PS 5.1 파서 검사(5파일) + **UTF-8 BOM 유지** 확인 → 필요 시 `dist\AutoMaintenance_v<버전>_<YYYYMMDD>.zip` 재빌드·검증 → **이 PC에도 즉시 적용**.
- 이 PC 적용: `H:\AutoMaintenance_v<버전>` 새 폴더에 ZIP 추출 → `Simple maintenance`의 상태 파일(`.last_*`, `config.json`, `*-state.json`, `last-result.json`, `adbackup`)·루트 `status.json`/`logs` 이어받기 → `install.ps1 -NoFirstRun` → 예약 작업(`OpenCode-Maintenance`) Args·바탕화면 바로가기 경로 확인 → 옛 설치 폴더 삭제.
- 안전 원칙: 자동 삭제·앱 제거·서드파티 업데이터 중지 금지. 삭제는 `y` 를 눌러야만, 확인은 실행당 1회. 결과 파일 정리는 **이동만**(`자동점검결과` 폴더), 단 v1.4.0 부터 **이 키트가 만든 결과 txt 중 3개월(90일) 지난 것만** `resultRetentionDays` 로 묻지 않고 자동 삭제(사용자 명시 요청).
- 콘솔 표시 판정은 `run-maintenance.ps1` 한 곳에서만(직접 실행=보임 / 자동+유휴=예약 작업과 **별도로 새 powershell 창을 띄워** 보임 / 자동+사용중=헤드리스 `CreateNoWindow`). `maintenance.ps1` 에는 `-NoHideConsole`/`-HideConsole` 로 결과만 전달.
- `dist/`·`status.json`·런타임 로그(`logs/`, `logs-legacy-*.txt`)는 커밋하지 않는다.
