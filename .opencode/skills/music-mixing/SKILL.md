---
name: music-mixing
description: 음악/노래/보컬/오디오 작업의 유일한 진입점 스킬. 원곡 커버·보컬 변환 곡을 스템 분리(언믹싱)→RVC 변환→이펙트→믹싱→검증→마스터링까지 전체 파이프라인을 실행·재개할 때. "음악", "노래", "보컬", "목소리", "변환", "분리", "언믹싱", "RVC", "이펙트", "믹스", "믹싱", "리메이크", "커버 곡", "보컬 갈아끼우기", "마스터링", "음원", "하루하루 bam 세션" 관련 요청이면 "변환만/분리만" 같은 좁은 발화도 예외 없이 이 스킬을 먼저 로드. 실제 검증된 명령과 환경 경로 포함.
metadata:
  opencode/slash: "true"
---

# 음악 믹싱 파이프라인 (하루하루 bam 세션 표준)

> ⭐ 진입 규칙 (2026-11-27 사용자 확정): 음악·노래·보컬·오디오 관련 요청은
> "변환만", "분리만", "이펙트만" 같은 좁은 발화도 예외 없이 이 스킬을 **먼저** 로드한다.
> 이 스킬이 체인을 판단하고 필요하면 `voice-conversion`, `unmixing`, `effect`,
> `effect-verification`, `master-volume` 등 단계 스킬을 추가로 로드한다.

2026-10-18~10-20 "음악 믹싱" 세션에서 검증된 작업 흐름. 원곡 보컬을 메구밍(meguminV2d_e420) RVC 보컬로 교체하는 커버制作 파이프라인.

## 작업 폴더 구조

```
I:\code\haruharu\bam\<곡명>\          # 곡별 작업 루트 (yeon, ily, ily2, ziae, holssi)
    <곡명>_orig.wav                   # 원곡
    sep\step1\                        # 1단계 분리: (vocals)/(other)
    sep\step2\                        # 2단계 분리: (Vocals)/(Instrumental)
    dereverb*\                        # 디리버브 산출물
    work\                             # 변환·패치·AB·로그 전부
I:\completesong\                      # 최종 납품 (mp3)
```

원곡 스템 소스: `H:\` 드라이브 (`H:\연 M.wav`, `H:\홀씨 M.wav`, `H:\I love you M/B/V.wav` 등 — M=리드, B=화음/잔향, V=분리보컬).

## 표준 6단계 (곡당)

```
1) 원곡 스템 확인/분리   → H:\ 원본 또는 sep_gpu.py로 원곡에서 분리
2) F0/옥타브 진단        → crepe로 f0 추출, 옥타브 에러 구간 스캔
3) 2단계 스템 분리       → sep_gpu.py (보컬/반주 → 리드/화음)
4) RVC 변환             → 분리 M/B 각각 변환 (합쳐변환보다 항상 우세)
5) 후처리 믹스           → 게이트 → 톤매칭 EQ → 리버브 → rms 정규화+리미터 → AB → PCM_24
6) 최종 음량 평탄화      → 2패스 loudnorm I=-9:TP=-1:LRA=7 → mp3 320k → 디코드 재검증
```

### ⭐ 6단계 "음량 평탄화"는 곡 만들기 시작부터 적용 (2026-11-23 확정)
> ⚠️ 이 절과 아래 LRA=7 명령은 **과거 bam 세션 기준**이다. 현재 납품 체인은
> `master-volume` 스킬(`master_unify_v3.py`, −9 LUFS / TP −1, LRA 고정 없음)을 쓰고,
> `auto_chain.py`가 5단계에서 자동 호출한다. 새 곡은 아래 151행의 전체 체인을 따른다.

- rms 정규화만 하면 **곡별 체감 음량이 제각각**이 된다. 납품 mp3는 반드시 아래 2패스 loudnorm을 거친다.
- 목표: **통합 음량 I=−9 LUFS / 트루피크 TP=−1 dBTP / LRA=7** (K-pop·CD 마스터 기준. 유튜브·스포티파이 업로드용은 I=−14).
- **평탄화 = 곡 전체 평균 음량을 맞추는 것**. 곡 안의 다이내믹(LRA)은 유지한다(추가 압축 금지). 단, LRA가 10 LU를 넘어 게인 캡에 걸리는 곡만 전단 압축 예외 적용.
- 1패스 → JSON의 `input_i/input_tp/input_lra/input_thresh/target_offset` 획득 → 2패스에서 `measured_*` + `offset` 주입 → **디코드된 mp3로 재측정**까지가 원칙(MP3 인코딩 시 TP +1~2 dBTP 솟음).
- 상세 명령·예외 처리·검증 스크립트: `tone-adjust\톤-조절.md` 상단 "대량 mp3 음량 일괄 정규화" 절 + `I:\code\normalize_audio\batch_loudnorm.py`.
- ⚠️ **고크레스트 곡 예외**: 원곡의 `measured_TP`가 −1.0dBTP를 조금이라도 넘으면 2패스 loudnorm의 `linear=true`가 dynamic 모드로 폴백해 **LRA가 4 이하로 뭉개진다**. 이때는 전단 압축 대신 `volume=+9dB,alimiter=limit=0.74:level=disabled` 그리드(재인코딩 후 I/TP/LRA 측정)로 LRA를 최대한 보존할 것 (2026-11-23 첫사랑 백아 실측, `bam\ofl\ofl_finalize.py`).

## ⚠️ "변환본이 악기 같다 / 사람처럼 안 들림" → 리버브 부재가 1순위 suspect (2026-10-22 검증)

RVC 변환본이 **신디/패드처럼** 들릴 때, EQ나 화음 레이어를 만지기 전에 **리버브 유무**를 먼저 확인한다.

| 지표 | 의미 | 원곡보컬 예시 | 드라이 렌더 예시 |
|------|------|-------------|-----------------|
| **side/mid** | 스테레로 폭 (클수록 넓은 공간) | 1.251 | 0.45 |
| **L/R 상관** | 음수면 좌우 역위상(와이드 공간) | −0.221 | +0.62 |
| **잔향테일** | 유성 종료 후 잔존 시간 | 0.650s | 0.000s |

- 원곡은 **분리본 자체가 wet** (원곡mix = 1.335×보컬 + 1.335×반주 + 잔차 0.0%) → 변환본과 구조가 다름
- 해결: `HS_REVERB="1,T60,pre(초)"` + `HS_WETDB` (wet dB) + `HS_REVWIDE` (사이드 강조)
- **리버브는 최종 rms 정규화 "이후"에 가산** (그 전에 더하면 wet↑ 에 따라 보컬이 깎여 희석됨)
- **pre-delay 20~30ms** 가 자연스러움 (적당히 긴 것이 사람 느낌)
- 상세: `음악-믹싱.md` → holssi 저음구간 재작업 절

## ⭐ "가사가 뭉개진다 / 특정 구간만 깨진다" — 2단 진단 (2026-10-22 확정)

| 단계 | 지표 | 기준 | 처방 |
|------|------|------|------|
| 1 | **6~12kHz 비율** (100~16k 총합 대비) | 변환 0.3% vs 원곡 2.1% | 국소 자음복원: 원곡 3~10kHz 를 **−14dB** 가산 |
| 2 | **Whisper 판독** (`openai/whisper-small`) | `바이차라…`=자음0 / 반복어=붕괴 | 자음복원 후 `날 따라` 회복 확인 |
| 3 | **같은 멜로디 이식** | 크로마 CENS 슬라이딩(≥0.85) + 가사 일치 + f0 ±20센트 | 그 구간의 "변환된" 리드를 떠서 이식 |

- 이식은 렌더러 합산식 `conv=0.745*(convM+convB)` 를 이용: `conv_M[구간]=0`, `conv_B[구간]=(소스리드)/0.745` → 0.15~0.2s 크로스페이드
- 실적: holssi 133.1~138.4s ← 66.9s 이식 → 사용자 "완벽" 판정, **v52 납품**
- ⚠️ f0 를 강제로 펴는 것(f0_file 스무딩)은 **역효과**(판독 0.125→0.005). 10ms 프레임 f0 요동은 고치지 말고 이식할 것
- 상세: `음악-믹싱.md` holssi v52 절 / `톤-조절.md` 자음복원 절 / `음-조절.md` 이식 절

## 핵심 명령 (복사-붙여넣기)

```powershell
# 0) 원곡 통합 분석 (신규 곡은 이것부터 — 해체+레이어+f0/옥타브/화음/오토튠/잔향/에코/EQ + 재조립 파라미터 리포트)
python I:\code\haruharu\analyze_orig.py "H:\곡.wav"                # → <입력위치>\analysis\<곡명>\analyze_report.txt
python I:\code\haruharu\analyze_orig.py "H:\곡.mp3" --maxsec 60     # 스모크(빠른 확인)
python I:\code\haruharu\analyze_orig.py "H:\곡.wav" --no-sep        # sep 폴더 재사용 시

# 1) 2단계 스템 분리 (GPU)
I:\code\haruharu\uvr_env\Scripts\python.exe I:\code\haruharu\sep_gpu.py "H:\홀씨 M.wav" "I:\code\haruharu\bam\holssi\sep"

# 2) 전체 파이프라인 (holssi 기준, cwd = I:\code\haruharu\bam)
python holssi_full.py v12            # 분리변환(M+B 각각 변환 후 합성) — 표준
python holssi_full.py v13 --sum      # 합쳐변환 (0.745*(M+B)를 한 번에) — 음색 일관성 후보
python holssi_full.py v14 g0.9       # 반주 gain 고정

# 3) 하모니 레이어 (옥타브 정합 마스크 자동 적용)
$env:HS_HARM="-3"; $env:HS_HARMF0="hyb"
python holssi_full.py v20h3

# 3b) 저음구간 보정 (근본주기 524 / 합산후 EQ / 후적용 리버브) — holssi 2026-10-22 확정
$env:HS_MIXEQ="143.40,150.35:330,1.0,4;393,1.0,3|155.65,161.40:330,1.0,4;393,1.0,3"
$env:HS_ORIGRANGE="143.40,150.35,155.65,161.40"; $env:HS_ORIGMIX="0.0"
$env:HS_REVERB="1,1.90,0.024"; $env:HS_WETDB="-10.0"; $env:HS_REVWIDE="1.5"
python holssi_render25.py v46     # env 세트 일괄 렌더

# 4) AB 청취 비교 ("삐 1번=1항목, 삐 2번=2항목" 1400Hz 0.09s)
python holssi_ab.py v12 v13 --spot 35.0,15 --spot 120.0,2.3 --out ab_v12v13.wav

# 5) mp3 납품 + 인코딩 후 재검증
ffmpeg -i work\holssi_megumin_v46.wav -codec:a libmp3lame -b:a 320k -ar 44100 -ac 2 "I:\completesong\곡명.mp3"
python holssi_deliver46.py   # peak -1.0dB 정규화 + 320k/44100/stereo + 디코드 재검증
python ziae_checkmp3.py

# 6) 최종 음량 평탄화 (모든 곡 default — 2패스)
ffmpeg -i "I:\completesong\곡명.mp3" -af "loudnorm=I=-9:TP=-1:LRA=7:print_format=json" -f null -   # 1패스: measured_* 획득
ffmpeg -i "I:\completesong\곡명.mp3" -af "loudnorm=I=-9:TP=-1:LRA=7:measured_I=<I>:measured_TP=<TP>:measured_LRA=<LRA>:measured_thresh=<TH>:offset=<OFF>:linear=true" -c:a libmp3lame -b:a 320k -ar 44100 -ac 2 "I:\completesong\곡명_flat.mp3"
python I:\code\normalize_audio\verify_folder.py I:\completesong   # 디코드 재검증
```

## 환경 (그대로 사용)

| 항목 | 값 |
|------|-----|
| 시스템 python | `C:\Program Files\Python310\python.exe` (librosa/soundfile/scipy/numpy) |
| UVR 분리 python | `I:\code\haruharu\uvr_env\Scripts\python.exe` |
| 분리 모델 폴더 | `I:\code\haruharu\sep_models\` |
| RVC | in-process: `sys.path.insert(0, r"D:\ApplioV3.2.9")` → `VoiceConverter` (subprocess 아님) |
| ffmpeg | `c:\ffmpeg\bin\ffmpeg.exe` |
| 납품 | `I:\completesong\` |
| 납품 규격 | mp3 320k CBR / 44100Hz / stereo / **peak −1.0dBFS** (ffmpeg libmp3lame `-b:a 320k -ar 44100 -ac 2`) |

## 완성 곡 목록 (과거 이력)

> ⚠️ 아래 파일명은 **과거 bam 세션 규칙**(수식어 포함)이다. 현재 규칙은
> `I:\completesong\<곡이름>.mp3` — `megumin`/`RVC`/`cover` 등 수식어 금지.
> 곡 설정 핵심은 지금도 유효한 교훈으로 남긴다.

| 곡 | 납품 파일 | 확정 설정 핵심 |
|----|-----------|----------------|
| 너 때문에 미쳐 | `I:\completesong\너 때문에 미쳐 (winter).mp3` | MI_HARM=3 + 리버브(1.8/0.012, wet −14.7) + MI_HFCAP=3,−3.0 + 톤매칭 1.0 |
| **홀씨 (IU)** | `I:\completesong\홀씨 (IU)_megumin_v46.mp3` | v25(발성) + 근본주기 524 + 합산후 MIXEQ + **후적용 스테레오 리버브(T60 1.90/pre 24ms/wet −10/wide 1.5)** + 구간 레벨정합. 320k/44100/stereo/peak −1.0dB, 188.60s |
| **Arabian Nights (박서은)** | `I:\completesong\박서은 - Arabian Nights (메구밍 RVC 커버).mp3` (+`[동굴강]` `[동굴약]` `[동굴저음121]`) | 리드 = 0~138.6s **rmvpe** + 138.6~147.25s crepe(동굴) + 147.25~끝 crepe(0.20s XF, 무음 틈 전환) + 게이트(0.003/0.010) + `spur_clamp` + **제로위상** `env_replace_low` + 톤매칭 0.5 + 틸트(+1.0dB@280/−0.8dB@5.5k) + 동굴 리버브 139.0~147.2s(T60 3.2/pre 35ms/wet −1/dry −2). 포먼트 0. 확정 저음 동굴 = rmvpe +12st(121Hz) + 흉성EQ(`AR_CAVE_CHEST=4.5`) + 보컬 `+4.5dB`(~147.45s). 320k/44100/stereo/peak −1.0dB, 195.66s |
| **Happy Birthday To You (조이 JOY)** | `I:\completesong\조이 JOY - Happy Birthday To You (메구밍 RVC 커버)_v2_revm11.mp3` (+`_v2_revm14`, `_dry`) | 입력 보컬이 **이미 분리된 스텀**이라 UVR 불필요. crepe/index 0.30/protect 0.33/f0max 1100 → 게이트(0.003/0.010) → 7밴드 톤매칭 0.70(고역 +2~5.5dB) → 반주 게인 **1.0**(원곡 lstq 실측) → 합성 리버브 T60 1.60/pre 24ms/wide 1.3/wet −11dB. f0 적중 99.8%·옥타브오류 0%. 320k/44100/stereo/peak −1.0dB, 174.28s |
| **Sixth Sense (브라운아이드걸스)** | `I:\completesong\Brown Eyed Girls - Sixth Sense (메구밍 RVC 커버)_v28g.mp3` | v21(페인/stutter 확정) + **1st/2nd 휘슬 1400Hz 대역만 원곡 복원**. 40k 한계로 700Hz로 깨진 휘슬을 `butter(2,[1300,3000]Hz)` 대역차 가산으로 복구 — 주음 1400 + 배음 2794Hz 포함, 3.7kHz 잡음(mb 스템)은 대역 외라 제외. 1st(176~179.2s)도 원곡 레벨로 맞춰 2nd와 밸런스. 페이드 0.35s. 휘슬 외 레이어 뭉개짐은 40k 변환 한계로 감수. 320k/44100/stereo/peak −1.5dB, 227.46s |

## 상위 / 하위 스킬

- **pthmod** — 모델(.pth) 자체의 인벤토리·음역/감정 커버리지·재학습/교체 판단. 믹싱과 별개 도메인. `I:\code\.opencode\skills\pthmod\`
- **mixing-toolkit** (상위 진입점) — 곡별 스크립트를 공용화한 실행 도구킷 + 전체 워크플로우 자동화/진단 폴백. `I:\code\haruharu\mixing_toolkit\`. 새 곡은 여기서 시작
- **unmixing** — mp3 → 보컬 레인 분리. 화음/백보컬/합창 자동 역할 판정. `I:\code\.opencode\skills\unmixing\`
- **voice-conversion** — RVC 변환 파라미터 전부 (index_rate/protect/f0 method/f0 파일 주입)
- **effect** — ⭐ unmix→RVC→effect→mix→effect-verification 체인의 effect 단계. 원곡에서 이펙트 패턴/파형을 자동 읽어 변환본에 전이. 228개 DSP + 자동 감지/자기검증. 전 레인 일괄 리버브는 삭제됨. `python assemble.py <manifest>`로 전체 조립. `I:\code\.opencode\skills\effect\`
- **effect-verification** — mix 직후 5축 검증(과적용/깨짐/음색죽음/보컬묻힘/밋밋함). 문제 시 강도 피드백으로 effect 재조립. `I:\code\.opencode\skills\effect-verification\`
- **pitch-adjust** — 옥타브 에러 진단·수정, f0 하이브리드, 화음
- **tone-adjust** — 톤매칭 EQ, 디리버브, 게이트/글리치, 리미터/정규화

### 🔗 mk-cover (2026-11-25 추가)
master-volume → I:\\completesong 저장 → **mk-cover** (커버/가수 LUN/가사). I:\\code\\.opencode\\skills\\mk-cover\\

### 🔗 전체 체인 순서 (2026-11-24 확정, 2026-11-26 레인밸런스 명시)
```
unmix(분리) → [레인검출] → RVC(변환) → rvc-verification → pitch
  → effect(자동 감지/추출/적용) → mix(합산 + 레인별 밸런스) → effect-verification(5축+밸런스)
  → supplement-effect → effect-verification 2차 → 게이트 → 수렴 → master-volume → 저장 → mk-cover
```
음정 수준은 효과 **보다 먼저** 맞춘다. 리버브는 감지된 레인에만 감지된 만큼.
검증은 mix 직후 자동 실행되며, 과적용/깨짐/음색죽음/보컬묻힘/밋밋함을 잡아
effect 강도 배율을 되돌려 최대 2회 재조립한다(`assemble.py --no-feedback`로 끔).

#### ⚠️ 레인별 음량 밸런스 (사용자 명시 — 별도 스킬 아님, mix 단계 내부)
- **두 층으로 동작** (2026-11-26 구현 완료):
  1. `lane_balance.py` — 검출된 **역할(lead/sub/harm_hi/harm_lo/back_vox)** 별로
     원본/변환 프레임 에너지 비(상대 게인 곡선) + 역할별 전역 레벨을 맞춘 뒤 합산.
     RVC가 전 레인을 같은 RMS로 정규화해 화음이 리드를 덮는 문제를 실제로 해결.
     `assemble._build_mix()`가 합산 전에 호출, `bus_envelope.lane_balance`에 기록.
  2. `assemble._restore_bus_envelope()` — 합산 **이후** 버스 시간축 엔벨로프 미세 복원.
     피드백 루프가 레인 scale을 0.4~2.2로 재조정.
- 체감 지표: `vocal_balance` = 원본 보컬버스 상위10%(리드)/하위30%(화음) 구간의
  에너지를 **원본 풀믹스 기준**과 **최종본 기준**으로 비교
  (`orig_contrast` → `final_contrast`, `lead_ratio`, `harm_ratio`).
  `assemble.py` 결과와 `fx_verify.analyze()["metrics"]["vocal_balance"]` **둘 다** 나온다.
  `fx_verify`는 `balance_ok`(리드/화음 비 0.75~1.33)도 반환하되, effect 강도
  배율(`strength_scale`)에는 섞지 않는다(잘못된 피드백 방지).
- 실적: eight 리드/화음 1.71 → 2.28(원본 2.37), Karma 1.32 → 1.37(원본 1.32).
  Cry Cry 검출기본(_cry_out_pa) 실측: 원본 2.34 → 2.226, 리드 0.97 / 화음 1.019 → OK.
- ⚠️ 성부별 **전역 RMS만으로는 부족**. `pitch` 이펙트 off는 RVC `pitch=0`과
  이중보정이라 의도적. crest 기반 `dynamic_ratio`는 원곡 클리핑 시 오탐이므로
  밸런스 근거로 쓰지 말 것.
- 자기검증: 합성 2레인(리드 0.5배 누출) → 역할 게인 2.0, 대비 5.0→5.0 복원 확인. ✅

#### 🤖 전체 체인 자동 실행 + 사례 루프 (2026-11-26)
- `I:\code\haruharu\unmixer\auto_chain.py <원곡.mp3> <작업폴더> <제목> [--key-shift N]`
  한 곡을 위 체인 **전부** 돌리고 사례까지 등록한다. 단계별 산출물 있으면 skip.
  남성 보컬곡은 `key_match.py`로 실측한 반음 수를 `--key-shift`에 넣고,
  **곡 전체를 transpose한 뒤 RVC pitch=0** (보컬만 transpose하면 반주와 어긋남).
- 결과: `<work>/auto_chain_report.json` + `_calibration/lane_cases.json` +
  `_calibration/auto_cases.json`. 사례에는 검출信心·RVC verdict·밸런스 게인·
  보충 게이트·수렴 거리·최종 verdict를 evidence로 붙인다(순환검증 회피).
- 목표: 사례가 쌓일수록 `lane_detector`의 역할 사전확률과 `lane_balance`의
  역할별 게인 기준이 정교해져 사람 개입 없이 검출→변환→편집이 수렴하게 만든다.

#### 🧠 스킬별 사례 기반 자기수정 (`skill_cases.py`)
- 검증/검출 스킬 **7종**(`lane-detector`, `effect`, `rvc-verification`,
  `effect-verification`, `lane-balance`, `supplement-effect`,
  `phoneme-verification`)은 호출할 때마다
  파라미터 + 결과를 `_calibration/skill_cases/<skill>.json`에 기록하고,
  다음 호출에서는 **성공 사례의 가중 중앙값**으로 자기 파라미터를 되먹는다.
- 사례 <3건이면 기본값 유지, 변화 폭은 기본값의 0.5~1.8배 — 절대 임계 신설 금지.
- `auto_chain`이 곡 최종 품질을 같은 곡의 스킬 사례 outcome에 되먹여
  "성공했던 설정이 다음 곡으로 이어진다."
- ⚡ 체인 내부 RVC 검증은 `quick=True`(4초×2 윈도우) + 레인별 결과 캐시로
  피드백 라운드마다 pyin을 다시 돌리지 않는다. 연구용 단독 검증은 기존 8초×4 유지.

상세 진행 기록·교훈 전체는 이 폴더의 `음악-믹싱.md` 참고.

## ⚠️ 자동 기록 규칙 (이 스킬을 로드한 세션 = 음악 작업 세션)

작업 종료 전에 반드시 수행:
1. **새 곡 작업** → `음악-믹싱.md`에 "### 곡명 (날짜)" 섹션 추가: 입력 파일, 사용 명령, 버전 이력, 결과
2. **RVC 파라미터/모델/발음 발견** → `voice-conversion\음성-변환.md` A/B 기록표에 추가
3. **f0/피치/옥타브/화음 발견** → `pitch-adjust\음-조절.md`에 추가
4. **EQ/리버브/게이트/레벨 발견** → `tone-adjust\톤-조절.md`에 추가
5. **확정 기본값이 바뀜** → 해당 `SKILL.md`의 파라미터 표도 함께 수정
6. 파일은 UTF-8 유지, 추가 후 변경 파일 요약을 사용자에게 보고

## 필수 교훈 (세션에서 직접 얻은 것)

1. **분리 변환(M/B 각각) > 합쳐변환** — QA 97.7% vs 미달, 최종은 항상 분리 계열
2. **crepe가 저역(0~350Hz)에서 rmvpe 압도** — ≤1반음 적중 95.7% vs 83.9%. rmvpe는 옥타브 오류 다발 구간의 프레이즈별 교체에만
3. **원곡 보컬 ≈ 0.745×(M+B)** — lstsq 설명률 98.2%. M과 B는 원곡 보컬의 두 조각
4. **자음 보존율(1.5~6k)이 최종 채택 기준** — f0가 더 정확해도 자음 보존 떨어지면 기각 (ziae v33 vs v31)
5. **화음 레이어는 옥타브 정합 마스크 필수** — 없으면 위화감 (harmony_mask + 0.2s 페이드)
6. **mp3 인코딩 후 재검증 필수** — 인코딩이 패치 구간을 손상시킬 수 있음
7. **작업 시작 시 `sys.stdout.reconfigure(encoding='utf-8')`** — Windows cp949 필수
8. 모든 스크립트 첫 줄: `# -*- coding: utf-8 -*-`
9. **톤매칭 고역 상한 `MI_HFCAP`** — 고음 쇳소리 방지. michyeo 확정 `"3,-3.0"` (→ tone-adjust 상세)
10. **고음 국소 옥타브 오류는 RVC 파라미터로 불가** — 수동 패치만 (→ pitch-adjust 상세)
11. **"목소리 더 낮게" = transpose가 아니라 포먼트 시프트** — `pitch=-12`는 옥타브·발음·톤이 전부 바뀌고, 저역 그로울 구간에선 오히려 옥타브 업이 남는다. pyworld로 스펙트럼 포락만 `np.interp(k*2**(semis/12), k, sp)` 시프트하면 f0는 그대로(실측 +0.000반음) 두고 몸통만 두꺼워진다 (arab −2.4st 확정, 195초 62s)
12. **저역 그로울(110~170Hz) 구간은 crepe f0max1100이 한 옥타브 위로 뜬다** — `librosa.yin(fmin=70,fmax=320)`로 만든 저역강제 f0_file(`t,f0` 10ms 격자) 주입 재변환 + 0.2s 크로스페이드 스플라이스가 유일한 해결책. pitch −12도 무효 (→ pitch-adjust 상세)
13. **동굴/대공간 리버브는 "구간 wet/dry 비"로 정량 검증** — 보컬이 끊긴 틈의 wet rms가 dry보다 +10dB 이상이면 "엄청" 수준. wet/dry를 구간 rms 기준으로 맞추고(`wet *= 10**(wetdb/20)*rms(dry)/rms(wet)`), dry도 −2~−3.5dB 깎아야 잔향이 앞으로 나온다 (→ tone-adjust 상세)
14. **"고음에서 묵음처럼 변환된다" = 3중 원인, 전부 따로 잡아야 함** — (a) `f0_max` 부족(원곡 f0 1400Hz까지인데 1100), (b) **전체 파일 1회 변환**(긴 입력에서 모델이 노트를 닫음: 322프레임 → 23s 청크+1s 크로스페이드로 134), (c) **게이트 임계값**(`fl=0.015/fu=0.05`가 조용한 어택을 잘라 928프레임 손실 → `0.003/0.010`이면 95, 무보컬 누출 0.003). 최종 보컬 기준 누락 프레임으로 계측할 것 (변환본만 보면 게이트 손실을 놓친다)
15. **`pitch=-12` 청크 변환은 조용한 구간에서 오히려 실패** — 옥타브다운은 저역 그로울/저레벨 구간에서 묵음이 폭증(363 → 853프레임). 그 구간만 전체변환본에서 0.2s 크로스페이드로 스플라이스하면 180 → 미세수리 91프레임
16. **잔여 딥은 "원곡이 조용한 꼬리"인지 먼저 확인** — 남은 60ms 딥의 소스 rms가 0.005~0.015(−36~−46dBFS)면 모델 탓이 아니고 반주에 묻힌다. 파라미터 스윕(6종)으로도 안 메워지면 소스 자체가 무음인 것
17. **"목소리가 변조됐다 / 원래 음색이 안 난다" = 포먼트 시프트가 1순위** — pyworld `harvest`는 저역 그로울(100Hz대)에서 f0를 2~4배로 읽고, `synthesize`가 그 f0로 재합성해 옥타브 점프(235/455/1099Hz)를 만든다. 게다가 −2.4st는 MFCC를 크게 벌려 "다른 사람 목소리"가 된다. 대안(켑스트럼 포락 워프·pyin f0 주입)도 저역에서 20~55% 옥타브오류로 실패 → **저역 그로울 구간이 있는 곡은 포먼트 시프트를 쓰지 말고 톤매칭+저역 틸트로 "낮은 느낌"을 낼 것**
18. **저역 포락 치환(`env_replace_low`)은 상한을 반드시 걸어라** — ratio 상한 4.0(+12dB)이면 모델 출력이 잠깐 꺼지는 구간(8dB)에서 저역만 부풀어 "부밍·깨짐"이 된다. **상한 1.7(+4.6dB) / 스무딩 30ms**가 안전
19. **crepe가 특정 구간에서 출력 레벨을 떨어뜨릴 수 있다** — 105.9~106.8s에서 −7dB(원곡 정상), 같은 구간 rmvpe는 +3dB. 그 구간만 rmvpe로 재변환(0.30s 크로스페이드 스플라이스)하면 피치정확도 64.1→78.8%, 옥타브오류 29.7→18.4%. **곡 전체를 rmvpe로 바꾸지 말고 구간만** (저역은 crepe 우위 유지)
20. **화음(back) 레이어는 "전곡 일정 레벨"이라 조용한 구간에서 리드를 덮는다** — 화음은 원음 back rms가 전곡 ~0.001로 고정인데 리드는 구간별로 0.03~0.12로 변한다. 저역 그로울 구간에서 **harm/lead −5.9dB**(곡 평균 −20dB)까지 올라와 톤을 흐리고 f0 측정을 235Hz대로 오염 → **동굴 구간만 화음 마스크**(`ramp(CAVE±1.0s, fade 0.6)`). 결과 동굴 f0 |d|≤1반음 41.4→70.6%, 옥타브점프 44.4→24.7%. "동굴이 변조됐다"의 마지막 조각 (**최종적으로는 이 스템 자체를 제거 — 21번**)
21. **"화음 스템이 잡음 같다"는 판정은 4개 지표로** — (a) 리드 대비 레벨, (b) 리드와의 상관, (c) `원곡보컬 = a·lead + b·back` 잔차 설명률, (d) pyin f0 신뢰도. arab back: −40dB / 상관 0.10 / 잔차 설명 1.25% / f0신뢰 0.06 → **화음이 아니라 블리드**. 이런 스템을 −11dB로 올리면 −40dB 잡음을 **+30dB 증폭**해 까는 것(변환본이 잡음을 노래함, 믹스 대비 −19.3dB의 중역 레이어) → **레이어 제거가 정답**. 제거하면 화음이 덮던 딥이 드러나 레벨누락 프레임이 2배가 되지만, 10~80ms·소스 rms 0.008~0.019(−34~−42dBFS)면 반주에 묻혀 무해
22. **리버브 구간 마스크는 `ramp()`의 앞 페이드를 그대로 쓰지 말 것** — `ramp(n, t0, t1, fade)`는 **t0 이전**에서 페이드인을 시작한다. "2:19부터" 같은 요구에서는 `m[:a0]=0` + 구간 안 0.25s 페이드인으로 직접 만들어야 앞 소절 테일이 젖지 않는다
23. **"기계음 삑삑삑"은 믹스가 아니라 3곳에서 나온다 — 3개 다 잡아야 사라진다** — (a) `pitch_repair`가 무음/자음 틈에 pyworld 합성음을 꽂음(62.25s +35dB, 174.36s +35dB 등 29구간 → **기본 OFF**), (b) `env_replace_low`의 **인과 `sosfilt` 3kHz 크로스오버**: `conv − low` 구조라 ratio<1에서 위상 상쇄가 깨져 2.6~2.9kHz가 솟음(2.5k+ 단일피크 **38→456프레임**) → **`sosfiltfilt` 제로위상 필수**, (c) `GATE_SM=200ms` 때문에 음절 사이 30~100ms 쉼에서도 게이트가 열려 모델이 숨소리를 +15~+25dB 톤으로 뱉음(51프레임) → **`spur_clamp`**(원곡 조용한 틈에서 모델이 1.5배 이상 솟은 톤만 12ms 페이드로 누름). 결과 2.5k+피크 249→74, 무음돌출 51→0
24. **"삑" 감사는 2.5kHz+ 단일빈 에너지비율 + 무음돌출 두 지표로** — `(S[2.5k:]**2).max(0)/(S**2).sum(0) > 0.25` & 프레임 rms>0.01 (휘슬/삑), 그리고 `src rms<0.008 & out>0.025·gain` (무음 틈 돌출). `spectral_flatness`/토널버스트 단독 검출은 1978건처럼 과검출된다
25. **고음부가 1옥타브 아래로 깨지는 원인은 "동굴 마스크가 그 음을 덮음"** — `CAVE=(136.8,147.8)`가 2:17~18의 522Hz를 덮어 저역 변환본이 −12.0st(261Hz)로 떨어졌다. **동굴 경계를 실제 그로울 시작(138.6s)으로 옮기고 그 앞은 rmvpe** → 2:16~18.6s |d|≤1반음 79.5→93.9%, 옥타브오류 19.3→0.0%. 서브하모닉 검사(`median −56dB`)로 다른 구간은 무죄임을 먼저 확인할 것
26. **rmvpe는 crepe보다 전곡에서 낫지만, 동굴 그로울만 crepe 유지 (구간 전환은 반드시 무음 틈 안에서)** — 전곡 rmvpe: |d|≤1반음 98.5%(crepe 97.7%) / 옥타브오류 0.0%(0.3%) / 스퓨리어스 134(191). 단 0~10s(무음 인트로)는 rmvpe가 전부 옥타브 오류지만 게이트가 닫혀 출력 0.0002 → 무해. 하이브리드 조립 시 `CAVE` 구간을 비워두고 양쪽만 청크 변환하면 경계 직전 `0.25s`가 **0으로 페이드아웃됐다가 점프**해 다음 소절 어택에 구멍이 난다(arab `147.56~147.80s` `0.25→0.002→0.237`). **구간 스플라이스·전용 EQ/볼륨 마스크는 반드시 소절 사이 무음 틈(`147.25s`) 안에서 끝낼 것**
27. **동굴 키 올리기는 "원곡 f0 × 2^(n/12)"로 계산해 고를 것** — arab 동굴 원곡은 **62Hz 그로울**이라 pitch −12는 오히려 117Hz로 올린 럼블(유성 8/707프레임)이었다. rmvpe +19 = 180Hz(남자 테너) / +22 = 213Hz / +24 = 239Hz(소년) — 피치만 올리고 포먼트 시프트는 0으로 두면 메구밍 음색 유지(MFCC 거리 그로울 130 → +24 113)
28. **"소년 키"가 "소녀"로 들리면 f0가 너무 높은 것** — f0만으로 성별 인상이 결정되지 않는다. 여성 포먼트 모델에서 239Hz는 소녀로 들리고, **107~141Hz**라야 남자 인상이 난다. 성별 판정에 켑스트럼 포락 피크 F1/F2를 쓰면 **배음 간격을 재는 착시**가 생긴다 → f0 + 밴드비로 볼 것
29. **저역 남자키(110~130Hz)에서 두께감을 줄 때는 켑스트럼 `formant_shift` 금지 → 흉성 EQ + 레벨 보강** — `formant_shift(+2~+3st)`는 포락 기울기까지 깎아 **RMS 4~5dB 증발 + pyin 유성 프레임 반토막(454→173, 63Hz 서브하모닉 추락)**. 대신 `175Hz +4.5dB / 310Hz +2.25dB / 4.2kHz −2.25dB` 흉성 EQ(RMS 정규화 후) + `AR_CAVE_VOL=+4.5dB`를 쓰면 유성 434~456 유지한 채 100~400Hz 두께 +2.2~2.4dB, 동굴 보컬이 반주보다 +4.8dB 앞으로 나온다(arab `v23~v25`)
30. **"원곡 밸런스·효과를 완벽히"는 전역 게인이 아니라 STFT 밴드 엔벨로프 이식으로 푼다** — M/B 각각 원곡 스템과 STFT(2048/512) 후 6개 밴드의 0.25s 엔벨로프 비를 0.4s 스무딩해 magnitude에 곱하면 화음 B/M −0.45dB → −8.2dB(원곡 −7.86dB)로 복원되고 자음보존 0.95→1.01이 된다. 좌우를 따로 계산하면 원곡 공간감까지 이식. 리버브는 `(t60,pre,wide)`별 wet을 한 번만 만든 뒤 wet_db 스케일로 원곡 side/mid·L/R에 그리드 서치(아틀란티스 1.8/0.035/1.0/−6dB, 오차 <1%) — 상세는 `tone-adjust\톤-조절.md` 2026-11-23 절
31. **crepe "고음 옥타브 하락" 플래그는 원곡도 같은 값이면 false positive — 40ms FFT로 확인 전 +12반음 패치 금지** — 근본음이 거의 없고 2·3차 하모닉만 강한 구간에서 crepe가 1050Hz를 525Hz로 오검출. 원곡/변환본 dominant peak가 둘 다 1050Hz면 이미 일치하며, 패치하면 2080Hz로 깨진다(아틀란티스 183s). 음량은 RMS+peak 그리드 서치 후 **loudnorm LUFS로 최종 확인**(ref −13.98 → v4 −14.10).
32. **RVC는 "조용한 지속 고음 꼬리"에서 출력 레벨이 1/20로 붕괴할 수 있다** — 아틀란티스 183.64~184.18s(원곡 1050Hz, rms 0.01~0.02)에서 conv rms 0.0006~0.002. f0/주기는 정상(1050Hz, per 0.9)이나 볼륨만 붕괴. f0_max 상향(1100→1400/1600) 무효, 개별 청크 재변환은 레벨 스케일이 달라 스플라이스 실패. **해결=매칭 후 음성에 원곡 엔벨로프 대비 부족 프레임만 게인 보상(최대 15x), 해당 구간만 0.25s 크로스페이드로 적용**. 전역 적용하면 76개 구간 +5dB 과부스트되므로 반드시 구간 제한할 것(v6).
33. **"보컬이 작게 들린다"면 근사 원곡과의 계측이 일치해도 청각을 우선** — 원곡 full mix가 없어 UVR 스템으로 합성한 ref는 추출 손실만큼 보컬이 작게 구성된다. v6는 ref와 보컬/반주 −9.25dB로 일치했지만 사용자에게는 작게 들림. `COEF`에 `10^(dB/20)` 곱해 보컬만 올리고 **최종 합산 RMS/LUFS를 ref에 재정규화**하면 보컬 +2.5dB / 반주 −0.5dB로 밸런스만 개선(아틀란티스 v7 +3dB → −6.25dB, LUFS −14.1 유지). 단 side/mid가 0.375→0.387로 다소 좁아지므로 공간감 재매칭이 필요하면 리버브 wide를 다시 서치할 것.
34. **원곡이 거의 무음인 스템을 RVC 변환하면 "고스트 보컬"이 생겨 음정이 떨어지고 떨린다** — 아틀란티스 55~65s / 112~142s은 srcM rms 0.006(실제 리드 구간 0.07~0.13)인데 convM이 0.03~0.12 생성. 40ms FFT로 `src mag 2~7 vs conv mag 28~65` 확인 필요(crepe 플래그만으로 판단 금지). 두 스템 F0 상관이 −0.15 / 0.46으로 엉뚱한 음이 겹쳐 맥놀이 발생. **해결=원곡 스템 50ms RMS로 lo=0.010/hi=0.025 소프트 게이트(0.15s 페이드)** — 고스트는 −22dB 감쇠, 실리드 구간은 −0.2dB 이내 변화. 단 기존 묵음 복구 구간은 게이트 강제 개방으로 보호할 것(v8).
35. **crepe 옥타브 플래그는 "원곡 dominant peak와 비교" 없이 절대 패치하지 말 것(재확인)** — 아틀란티스 B 111.7 / 134.1 / 137.9~138.5s에서 crepe는 ±12st를報告했으나 40ms FFT는 원곡/변환본 모두 1033~1076Hz·839~883Hz로 동일. 실제 오류는 M 고스트였음(교훈 31과 동일 함정 반복).
36. **RVC 고음 "찢어짐"은 클립/HF가 아니라 주기성 붕괴이며, 스펙트럼 보간으로는 고치지 말 것** — 아틀란티스 121~183s는 v8/ref HF비 0.9~1.1·clip 0인데도 원곡 per>0.7 구간의 13.6%(M)~23.2%(B)에서 변환 per<0.4로 붕괴(168.37s 877Hz→489Hz 등). 스펙트럼은 오히려 flatness가 낮아져 과토널. 크랙 프레임 magnitude를 이웃 프레임으로 보간한 v9은 **위상 불일치로 "다 뭉개졌다"는 청취 결과로 거부**. 추론 파라미터도 i0.30→i0.00(붕괴 12.6→12.0%), crepe→rmvpe(13.3%, 오차 7.3%)로 유의미한 개선 없음. `G_Megumin*_init.pth`는 generator-only라 `get_vc()` 실패. → **모델 한계 확정**. 2026-11-24에 만든 학습 모델 4종 36개 .pth는 전량 삭제됨(음색 양보 거부). 모델 수준 재시도·판단은 `pthmod` 스킬로 이관. 무의미한 재시도 금지.
37. **음량 평탄화는 곡 생성 파이프라인의 마지막 단계(6단계)이지 사후 선택이 아니다** — rms/peak 정규화만으로는 곡별 LUFS가 ±5dB 이상 어긋난다(CRIS 실측 −3.4~−22.4). 모든 납품본에 2패스 loudnorm `I=-9:TP=-1:LRA=7`을 기본 적용하고 **디코드 mp3로 재측정**할 것. 단 "평탄화"는 곡 전체 평균을 맞추는 것이지 곡 안 다이내믹을 지우는 게 아니다(LRA는 유지, 10 LU 초과 곡만 전단 압축 예외). 새 보컬 부스트 버전을 나중에 덮어쓰면 다시 조용해지므로 **최종 파일 확정 후 반드시 재적용**할 것(아틀란티스 본편/v7이 작업 후 재교체되어 −14로 회귀한 사례).
