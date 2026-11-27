# RVC 검증 상세 기록

> ## 📌 갱신 규칙 (반드시 지킬 것)
> 1. 이 문서 상단에 새 날짜/차수 섹션을 **추가**한다 (아래로 쌓지 말고 위에).
> 2. 새 오탐/미탐 사례는 반드시 `case_library.py`에 라벨과 함께 등록한다.
> 3. 방법론을 고치면 `METHODOLOGY_VERSION`을 올리고 **전 사례 rescore → report** 한다.
>    `regressions`가 0건이고 `adoptable=true`일 때만 채택.
> 4. 체인 변경은 `effect-verification`, `effect`, `unmixing`에도 반영.
>    `I:\code\AGENTS.md`(색인)는 라우팅 변경 시에만 갱신.

---

## 2026-11-27 (5차) — GPU Whisper A/B도 노래에서는 판정 불가 (환각 확정)

- Applio 학습 종료 후 GPU가 비자(222MB/12GB) `diag_ab_gpu.py`로 레모네이드
  82~85s / 146~151s / 162~165s, `diag_boreum_gpu.py`로 보름달 전 구간
  원곡·완성본을 같은 창으로 비교했다.
- 결과: **양쪽 다 같은 환각에 빠져 차이가 없다.**
  - 83s: 원곡=완성본="구독과 좋아요 부탁드립니다!"
  - 147s: 원곡=완성본="으으으으…" 200자 루프
  - 163s: 원곡="그대의 스토리…" / 완성본="구독과 좋아요 부탁드려요!" (둘 다 환각)
  - 보름달: 원곡 0~25s가 "뱃뱃뱃… 아아아… 오오오…" 루프로 가득. 사용자가
    문제 삼은 "eh eh eheheheh" 구간의 실제 가사/애드리브 판독 불가.
- 결론: **Whisper-small(乃至 대부분 ASR)은 노래에서 절대 판정 도구로 쓸 수 없다.**
  CPU든 GPU든, `lyric_match`/A/B 모두 "같은 환각끼리의 n-gram 비교"가 된다.
  가사 손실 판정은 `_lyrics/*.txt` 원문·USLT 대조만 신뢰하고, 음소 붕괴는
  사용자의 물리적 청취(A/B 파일)로만 확정한다. 재변환 근거로 쓰지 말 것.
- 실행: `diag_ab_gpu.py <원곡> <완성본> <라벨> <t0> <t1> <창> <홉> <out.json>`
  결과 `_lemonade_ab/whisper_{83,147,163}.json`, `_diag_boreum_gpu.json`.

---

## 2026-11-27 (4차) — lyric_match 0.07은 오탐: Whisper 환각 루프끼리 비교한 값

- 거짓말/하루하루 키매칭 재처리 후 `final_check`가
  `lyric_survival 0.076 / 0.072 (< 0.60)` warn을 냈다. **실제 가사 손실 아님.**
- `ref_text_head`를 보면 원곡 판독이 이미 `1. 스프레이트 2. 스프레이트 …` 수백 회,
  `하루하루` 원곡은 `다다다다…` 수백 회로 **환각 루프**에 빠져 있다.
  완성본도 `스페셜 스페셜…`, `히히 히히…`로 다른 환각 루프.
  → 서로 다른 환각의 4-gram 교집합을 재는 값이라 0에 수렴하는 건 당연.
- `lyric_match.py`는 `_lyrics/*.txt`(실제 가사)를 **읽지 않고** 양쪽 mp3를
  Whisper-small로 다시 판독한다. 3차의 "ASR을 가사 누락 직접 증거로 쓰지 말 것"
  교훈이 `lyric_match` 자체에 다시 적용된 케이스.
- ⚠️ 대응: survival < 0.6이면 **원문 `ref_text_head`가 환각인지 먼저 확인**하고,
  환각이면 recheck 트리거로 재변환하지 말 것. 실제 가사는 USLT/`_lyrics` 원문
  대조 또는 더 긴 창·다른 모델로 재판독해야 함.
- 참고: 두 곡의 실제 잔여 warn은 따로 있음 — 거짓말 다이내믹 0.72배 + 샘플점프
  17381회, 하루하루 밴드[6] −10.52dB + 다이내믹 0.76배. `clip_pct_final=0`.

---

## 2026-11-26 (3차) — Cry Cry 실적용 + Whisper 판독 함정 + 청크경계 경고 해석

### Whisper(word) 판독으로 가사 누락을 확인할 때의 함정 ⚠️
- `transformers` ASR pipeline에 **numpy 배열을 넣으면 샘플레이트를 변환하지 않는다**.
  44.1kHz 배열을 넣고 15초 이상 자르면 "3000 mel features 초과" ValueError 발생.
  → 호출 전 **`librosa.resample(seg, orig_sr=44100, target_sr=16000)` 필수**.
  (10초는 우연히 통과하지만 15초부터 실패 — 원인을 청크 길이로 오진하기 쉬움)
- 노래 커버의 Whisper 키프레이즈 매칭은 원곡도 11/19밖에 안 나온다.
  **AWS(automatic speech recognition) 결과를 "가사 누락"의 직접 증거로 쓰면 안 됨.**
  RVC로 화자가 바뀌면 매칭 급감(1/19)은 정상. 태그 USLT 원문 대조가 우선.

### 자음 복원 (원곡 보컬 3~10kHz 가산)
- Cry Cry 후보 채점(Whisper 12키): 원본 2/12 → **C1(자음 −14dB) 3/12** 최고.
  C2(−10dB)/C3(+보컬 2dB)은 2/12로 오히려 하락.
- 전부 `fx_verify.analyze()` pass. over_application 0.019 → 0.027로 소폭 상승하나 임계 이내.
  **낮은 레벨(−14dB)이 최적, 세게 넣으면 역효과.**

### rvc_verify "청크 경계 불연속" warn 해석
- Cry Cry lane0: 경계 점프 2.6배 → 40.1배, `artifacts=0.937`, verdict `warn`.
- 실제 샘플 점프 상위 위치는 25.8/31.1/173.8초 등 **주기적 경계가 아니라 자음 transient**.
  p99.99≈0.29, max≈0.50(1.6배) → 실제 끊김이라기보다 RVC가 증폭한 순간으로 판단.
- 최종 믹스 `fx_verify`는 pass(clicks 17331 < 원곡 27577) → **재변환하지 않고 채택**.
- lesson: RVC warn은 `note_v1`/`v4`의 low-confidence 경고일 수 있음.
  최종 mix 검증이 pass면 레인 warn만으로 재조립하지 말 것.

#### ⚠️ 청크경계 지표의 나눗셈 오탐 (4레인 전수검증에서 확정)
- 12개 리포트 전부 warn이었으나, 경계 점프 240배/119배/40배 지점의
  **실제 샘플 점프는 0.0000**(무음 구간)이었다. 분모 `median(|diff|)`가 ~0이라
  `0/거의0`이 큰 값으로 출력된 것. → **ratio만 보지 말고 absolute jump를 반드시 같이 확인**.
- 최종 mp3의 23초 경계 비율은 1.4~2.8배(정상), 전곡 max jump 0.92/p99.99 0.56으로
  경계 클릭 없음. **재변환 불필요.**
- `dynamics` warn(0.32~0.64배)도 희소한 원본 스텀 crest(11.46)를 밀도 높은 RVC
  출력 crest(7.57)로 나눈 결과 — 최종 믹스 `fx_verify` dynamic_ratio 1.114 pass.
- `phoneme_verify` 라벨 일치도 14~24% warn은 보컬 변환 시 포먼트가 바뀌는
  **설계상 당연한 결과**. `nearest_dist_ratio` 0.97~1.13(임계 2.5)이 실제 상대 판정 근거.
  절대 `label_match_floor=0.6`만으로 "가사 보존 실패"로 판정하면 오탐 — 스킬 원칙
  ("절대 임계 금지, 전부 원본 대비 상대값")과도 배치됨.

---

## 2026-11-24 (2차) — 음 단위 검출 + 기준사례(golden set) + 음소/음색 검증 + 전체 8/8

### 사용자 질문 흐름
1. "음정 같은 것도 검출 가능한가? 원본 한 음을 기준으로 변환 한 음을 검출 가능한가?"
   → 궤적 상관(전체 0.45)만으로는 부족 → **음 분할 → lag 정렬 → 1:1 매칭** 구현.
2. "기초적인 검출 기준 사례를 몇 개 만들어놓는 게 낫나?"
   → **golden_set.py** 구현. 정답=주입 파라미터라 사람 귀 불필요, 완전 자동 캘리브레이션.
3. "megumin 최저~최고 음역 표준 + 한국어 모든 발음 파형 샘플은 어떠냐?"
   → 파형 직접비교는 위상 때문에 실패 → 포먼트/멜 통계로 전환. 단, **절대 문헌값 비교는 오탐** 확인.
4. "음소 샘플로 판정할 수 있나? 발음이 이상할 수 있잖아"
   → 정확한 지적. 문헌값은 **라벨 좌표계로만**, 판정은 **원본 대비 상대 비교로만**.
5. "이 검출기까지 완성하면 모든 단계가 잘 작동하는지 시험해봐"
   → **test_all.py** 8 스테이지 하네스 → 8/8 통과.

### 새 모듈
| 파일 | 역할 |
|---|---|
| `note_verify.py` | 연속 f0(50% overlap) → 음 이벤트 분할 → lag 정렬 → 원본음↔변환음 1:1. 반음/온셋/지속 오차 + `wrong_notes`. 방법론 `note_v1`. |
| `golden_set.py` | 정답이 공짜인 주입 신호 8사례(+2/-3반음, 50/150ms 지연, 다이내믹, HF, 청크끊김, 무음). 자동 오차 측정. |
| `timbre_standard.py` | 음역별 포먼트/멜 뱅크(`megumin_bank.json`) + 한국어 21모음 문헌 포먼트. **라벨 좌표계 전용**. |
| `phoneme_verify.py` | 발음 보존(원본라벨==변환라벨) / 왜곡(라벨뒤집힘+거리급증) / 음색전이 3축. 방법론 `phoneme_v2`. |
| `test_all.py` | 전체 8 스테이지 독립 하네스 → `_calibration/test_all_report.json`. |

### 실측으로 잡은 결함과 수정 (중요)
1. **note_verify 저음 누락**: `_f0_continuous`의 `vp>=0.5` 게이트가 voiced 594→386프레임(35%)으로 깎아 196~247Hz 저음 5개 누락.
   → vp 분포 실측(25%=0.485, median=0.549) 바탕으로 **0.3으로 완화** → 12/12음 검출, 단일 +2반음 정확히 콕집음.
2. **LPC 포먼트 절대값 부정확** (`_formant_diag.py`): 10kHz/order12 최적에서도 ㅣ의 F2를 2250→1077Hz로 읽음.
   → phoneme 판정에서 **절대 `nearest_dist_floor` 제거**, 라벨 일치도 + 거리 **증가 배율(상대)** 만 사용.
   자기자신 1378Hz 거리로 '왜곡' 오탐하던 문제 해결 → self=pass / ㅏ→ㅣ=warn.
3. **golden_set 주입기 버그 3개** (검증기 결함 아님):
   - 피드백 반음: median은 12음 중 1음 변화에 0 → `note_verify` 1:1로 라우팅 → 2.00/3.00 정확.
   - 다이내믹: 스칼라 곱은 peak/rms 동시 스케일로 crest 무변화 → 전력곡선(sign·|x|^p) 이분탐색으로 crest 정확히 0.5배.
   - 청크끊김: 3s 신호에 23s 경계 주입 → `chunk_s=1.0` 파라미터화(`rvc_verify.analyze`에 `chunk_s` 인자 추가) → 191x 검출.

### 최종 검증 결과
- **golden_set: 8/8** (detector v4_low_confidence_no_penalty)
- **case_library: F1=1.0, FP=0, FN=0, 회귀=0**
- **test_all: 8/8** (compile, rvc_lag 46.4ms/50ms, note 1음검출, golden, case, fx 오탐0, timbre self pass, phoneme 상대판정)
- 리포트: `_calibration/golden_report.json`, `_calibration/test_all_report.json`, `_calibration/megumin_bank.json`, `_calibration/korean_vowels.json`

### 교훈 (일반화)
- **기준 사례는 사람 귀가 정답인 실제 사례와 역할이 다르다**: 실제=오탐/미탐, 기준=측정 오차(주입값=정답).
- **절대 임계는 오탐의 온상**: 포먼트/밴드/거리 모두 원본 대비 상대값으로만 판정.
- 검증기가 "pass"라고 해도 **주입 신호로 정답을 확인하기 전엔 믿지 말 것** (12음 중 1음 못잡고 pass했던 실제 사례).

---

## 2026-11-24 (1차) — rvc verification 스킬 신규 + 사례집 기반 방법론 수렴 (F1 0.5→1.0)

### 사용자 요구 (순서대로)
1. "effect verification 말고 rvc verification도 만들어야 하나? 제대로 변환됐는지 어떻게 확신하지?
   나는 최종본만 듣게 되는 거잖아" → RVC 직후 검증 단계 신설.
2. "음정 정확도, 음색 전이 여부, 아티팩트 등등은 뭘 기준으로 잡고 검출하는 거야?" → 기준 문서화.
3. "리포트 모아 측정 오차 수정 및 방법론 수정하면 완벽한 검증이 될 수 있는 거 아냐?"
   → **원곡 대비 일치도는 reference가 있는 측정 문제라 수렴한다**는 결론.
4. "A곡 A1, B곡 B1-1처럼 틀린 부분을 모아 사례집으로 하나씩 체크할 수 있는 거아냐?"
   → `case_library.py` 구현 + 실제 3사례로 루프 실증.
5. "음색 제외하고 원곡 노래와 얼마나 일치하는가" → timbre 축을 일치도에서 분리.

### 체인 (6단계로 확정)
```
unmix → RVC → rvc verification → effect → mix → effect verification
```

### `rvc_verify.py` 구현
- `analyze(orig, conv, sr)` → 5축 + `original_fidelity`(최대 오차, 음색 제외) + `timbre_reference_only`.
- `verify()` → 오디오 변경 없이 리포트만 (RVC 재변환은 상위 판단).
- f0: pyin 8초×4 윈도우 + voiced-prob 게이트 + lag 보정 cross-correlation.
- 아티팩트: 밴드 dB, f0 계단성 **증가분**, 청크 경계 ±20ms 국소 점프 배율.
- 전부 원곡 대비 상대값 (절대 임계 금지 — 40k→44.1k 밴드 왜곡에 강인).

### 사례집 (`case_library.py`)
- 스키마: `case_id / song / region_sec / symptom / root_cause / axis / label / versions`.
- `label`: `defect` | `false_alarm` | `ok` (최종 정답은 사람 귀, 의심 구간만 확인).
- `rescore`: 현재 검증기로 전 사례 재채점 → `versions[버전]` 기록.
- `report`: 사람 라벨 대비 precision/recall/F1 + 이전 버전 대비 **회귀 자동 검사**.
- 회귀 0건이면 `adoptable=true` → 그 버전 채택.

### 🔬 방법론 수렴 실측 (사례 A1 / B1-1 / C1)

| 버전 | 수정 | A1 | B1-1 | C1 | 정밀도 | F1 | 회귀 |
|---|---|---|---|---|---|---|---|
| v2_lag_corrected | lag 보정, ±7 클램프 | 오탐(1.0) | 오탐(1.0) | 정답(0.74) | 0.333 | 0.500 | — |
| v3_confidence_gate_chunk_boundary | voiced-prob 게이트 + 청크경계 불연속 | 오탐(1.0) | **해결(0.051)** | 정답(0.74) | 0.500 | 0.667 | 0 |
| **v4_low_confidence_no_penalty** | 저신뢰 구간 판정불가(감점없음) | **해결(0.0)** | 해결(0.051) | 정답(0.74) | **1.000** | **1.000** | **0** |

- **A1**: 아웃트로(186.5~194.4s) 유성 커버리지 45% → f0 쓰레기, lag 319ms 오진.
  원인 = "판정 불가 구간을 결함으로 점수화" → v4에서 info 처리 + 스코어 0.
- **B1-1**: 디리버브 스텀 vs RVC 고역노이즈 전역 파형 비교 → 클릭 +8231 오탐.
  원인 = "비교 범위가 넓음" → v3에서 청크 경계 ±20ms 국소 배율로 변경.
- **C1**: 다이내믹 0.40 → 실제 결함, 전 버전에서 정상 검출 (회귀 없음).

### 버그/교훈
1. pyin 전체 호출 시 `Target size must be at least input size` → 8초 윈도우 분할.
2. 데시메이션 비율은 자르기 **직전** 길이 기준으로 계산해야 sr_a가 맞다.
3. f0 계단성 절대 임계 금지 — 지속음은 원래 step=1 → 원본 대비 증가분만.
4. 순수 사인파 lag 테스트는 2배(주기 모호성), chirp는 lag 0(선형 램프 불변) → **멜로디**로 테스트.
   실제 멜로디 검증: 30ms→-29, 50ms→-46, 100ms→-99, 200ms→-197 (오차 <7%),
   raw 상관 0.499 → lag 보정 후 1.000 복구.
5. fmin=60 @ 44.1k/1024는 2주기 미만 → fmin=86.
6. 메트릭 딕셔너리가 변수 계산보다 앞에 오면 `UnboundLocalError` — 계산 순서 주의.

### 검증 세션
- lag 검출 합성 테스트 5/5 통과 (위 표).
- 사례집 3건 rescore/report 반복 → v4에서 FP 0 / FN 0 / 회귀 0 / F1 1.000. ✅
- `assemble.py`에 `lanes[].rvc_verification` 연동 완료 (음색 제외, use_embed=False).
