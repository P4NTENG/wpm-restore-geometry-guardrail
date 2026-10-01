# WM_GETMINMAXINFO 관측 실험 결과

**실시:** 2026-09-29
**대상:** Google Chrome `Chrome_WidgetWin_1`, hwnd `2624458`
**목적:** Chrome 복원 시 `WM_GETMINMAXINFO.ptMinTrackSize.x`가 실제로 516 또는 1016으로 변하는지 검증
**상태:** 관측 전용. WPM 동작 로직·FancyZones 설정·디스플레이 배율·배치·Chrome 설정·zone correction 모두 변경하지 않음

---

## 1. 실험 결과 요약 (지시서 §12 형식)

| Experiment | 최소화 위치 판정 | DPI | Initial width | minTrack.x (최대) | Restore width | 반복 |
|---|---|---:|---:|---:|---:|---:|
| A | Laptop (200%) | 192 | 974 | **1016** | **1016** | 3 |
| B | DEL (100%) | 96 | 974 | **516** | **974** | 3 |

추가 표:

| 항목 | Experiment A (200% 왼쪽) | Experiment B (100% 왼쪽) |
|---|---:|---:|
| 총 샘플 수 | 201,195 | 194,771 |
| `GetDpiForWindow` (전 구간) | 96 | 96 |
| `WM_GETMINMAXINFO` minTrack.x = 1016 | **9** | **0** |
| `WM_GETMINMAXINFO` minTrack.x = 516 | 201,186 | 194,771 |
| restore 후 폭 = 1016 | 188,541 샘플 | **0** |
| restore 후 폭 = 974 | — | 183,174 샘플 |

**결과 A에 해당한다.** 200% 조건에서만 `ptMinTrackSize.x`가 1016으로 관측되고, 100% 조건에서는 516이 유지된다.

---

## 2. 실험 A — 200% 모니터가 최소화 위치에 해당

### 배치

```
DISPLAY1  laptop  2880x1800 @  0,0        ← 가장 왼쪽, PRIMARY, 192 DPI
DISPLAY2  DEL     1920x1080 @  2880,340   ← 오른쪽, 96 DPI
(-32000,-32000) 위치 조회 → laptop, 192 DPI
```

### 측정값 (일반 상태)

```
hwnd    = 2624458
rect       : 3833,340 974x1039   (L3833 T340 R4807 B1379)
placement  : showCmd=1  minPos=-16000,-16000  maxPos=-1,-1
             rcNormal = 3833,340 974x1039
monitor    : handle=131073  rect=2880,340 1920x1080  windowDpi=96
WM_GETMINMAXINFO:
  minTrack = 516x129    maxTrack = 0x0
  maxSize  = 0x0        maxPos   = 0,0    reserved = 0,0
```

### 전이 시퀀스 (3회 반복, 모두 동일)

```
t=2314  minTrack.x=516   width=314     ← 최소화 상태
t=2315  minTrack.x=1016  width=314     ← 최소화된 채로 minTrack가 팽창
t=2316  minTrack.x=1016  width=314
t=2318  minTrack.x=516   width=1016    ← 복원, 이미 1016로 클램프됨
```

| Cycle | minTrack=1016 구간 | 해당 샘플 수 | 직후 폭 |
|---|---|---:|---:|
| 1 | t=2315 – 2316 | 3 | 1016 |
| 2 | t=5382 – 5400 | 3 | 1016 |
| 3 | t=8449 – 8450 | 3 | 1016 |

과도 구간은 각 약 1–2 ms.

---

## 3. 실험 B — 100% 모니터가 최소화 위치에 해당

### 배치

```
DISPLAY1  laptop  2880x1800 @  0,0        ← 주 화면 유지 (192 DPI)
DISPLAY2  DEL     1920x1080 @  -1920,381   ← 왼쪽으로 이동, 96 DPI
(-32000,-32000) 위치 조회 → DEL, 96 DPI
```

**이 배치는 기존 §14가 시험하지 않은 것이다.** §14는 DEL이 주 화면이자 가장 왼쪽인 경우만 측정했다. 여기서는 **노트북이 주 화면을 유지하면서** DEL만 가장 왼쪽에 있다. 결과는 동일했다.

### 측정값 (일반 상태)

```
hwnd    = 2624458
rect       : -967,381 974x1039   (L-967 T381 R7 B1420)
placement  : showCmd=1  minPos=-1,-1  maxPos=-1,-1
             rcNormal = -967,191 971x1229   ← 레이아웃 변경 잔재, 아래 비고 참조
monitor    : handle=131073  rect=-1920,381 1920x1080  windowDpi=96
WM_GETMINMAXINFO:
  minTrack = 516x129    maxTrack = 0x0
  maxSize  = 0x0        maxPos   = 0,0    reserved = 0,0
```

### 전이 시퀀스 (3회 반복)

```
t=8549  minTrack.x=516  width=314    ← 최소화 상태
t=8550  minTrack.x=516  width=314
t=8551  minTrack.x=516  width=974    ← 복원, 클램프 없음
t=8553  minTrack.x=516  width=974
```

**`minTrack.x = 1016` 이 194,771개 샘플 중 0회. `width = 1016` 도 0회.**

---

## 4. 최소 폭 sweep과의 관계 (지시서 §8)

Experiment A에서 이미 분리된 값들:

| 시점 | 폭 |
|---|---:|
| zone 배치 직후 | 974 |
| 일반 상태 `minTrack.x` | 516 |
| 복원 전이 중 `minTrack.x` | **1016** |
| 복원 직후 실제 폭 | 1016 |
| 복원 후 안정화 `minTrack.x` | 516 |

`minTrack.x`는 1016인 채로 폭을 클램프한 **뒤** 516으로 되돌아온다. 1016이 974 위에 적용되어 폭을 밀어 올린 것이 관측 순서와 일치한다.

---

## 5. 516 / 1016 산술 관계 (지시서 §9)

| 조건 | `ptMinTrackSize.x` 최대값 | `GetDpiForWindow` | DPI/96 | 500×scale+16 |
|---|---:|---:|---:|---:|
| A (200% 왼쪽) | **1016** | 96 | 1.00 | 516 |
| B (100% 왼쪽) | **516** | 96 | 1.00 | 516 |

관측된 두 값은 516과 1016으로, 기존 보고서의 `500 × scale + 16` 모델과 일치한다.

**단, `GetDpiForWindow`는 두 조건 모두 96이었다.** 즉 창이 200% 모니터를 물려받았다고 해서 `GetDpiForWindow`가 192를 반환하지는 않는다. 배율이 어디서 나오는지(`GetDpiForWindow`가 아닌 경로)는 이번 관측으로 결정되지 않았다.

**이 식을 증명한 것이 아니다.** 두 실측점(516, 1016)만으로 식이 정해지지는 않으며, 세 번째 배율에서의 검증은 하지 않았다.

---

## 6. 1026 문제 (지시서 §10)

세 값을 독립적으로 기록한다.

| 항목 | 값 | 시점 |
|---|---:|---|
| Chrome 완전 재시작 직후 initial width | **1026** | 이전 세션, zone 배치 전 |
| `WM_GETMINMAXINFO` minTrack.x | 516 | zone 배치 후 |
| restore result width (zone 974) | 974 (B) / 1016 (A) | 이번 실험 |

**1026은 `minTrack.x` 값이 아니다.** 1016과도 516과도 다르며, zone 배치 이전의 Chrome 초기 상태에만 관측됐다. `minTrack.x`와 별개 개념으로 기록한다.

**원인은 미설명이다.** 재시작 직후 1026이 나온 뒤 974 이하로 내려가지 않는 현상은 이번 실험의 범위 밖이다.

---

## 7. 1554x1290 (지시서 §11)

```
1554x1290: not reproduced
```

임의로 조건을 바꾸어 재현을 시도하지 않았다. 실험 A·B 모두 3회 반복에서 1016 또는 974만 관측됐고 1554는 한 번도 나오지 않았다.

**재현되지 않은 것을 설명하지 않는다.** 이 현상은 여전히 미해결이며, 이번 관측으로기각된 것도 아니다.

---

## 8. 최소화 위치 → monitor 판정 (지시서 §6)

| 조건 | `MonitorFromPoint(-32000,-32000)` | monitor DPI |
|---|---|---:|
| A | laptop, `0,0 2880x1800` | 192 |
| B | DEL, `-1920,381 1920x1080` | 96 |

- `MonitorFromWindow(hwnd)` : 두 조건 모두 창이 있는 모니터(DEL, 96)를 반환
- `GetWindowRect` : 최소화 시 두 조건 모두 `-32000,-32000`
- `GetDpiForWindow` : 두 조건 모두 **96**

**API 관련 메모:** `MonitorFromPoint`는 PowerShell 프로세스에서는 정상 값을 반환했으나, WPM(AutoHotkey) 프로세스 안에서는 NULL을 반환했다. 지시대로 **억지로 수정하지 않고 기록만 남겼다.** WPM 코드의 판단 로직은 변경하지 않았다.

---

## 9. 결론 (지시서 §13)

### 확인됨 — 실제 측정값으로 직접 입증

1. `ptMinTrackSize.x`는 200% 조건에서 복원 순간의 **1016**으로 관측되며, 100% 조건에서는 194,771 샘플 전체가 **516**이었다.
2. 1016으로 변하는 시점은 **창이 최소화된 상태**이며, 복원 이전이다.
3. 복원 직후 폭은 그 값으로 클램프된 1016이 되며, 이후 `minTrack.x`는 516으로 되돌아온다.
4. 이 순서는 3회 반복에서 동일했다(과도 각 약 1–2 ms).
5. 배치만 바꾸면(노트북 주 화면 유지 + DEL을 왼쪽으로) 1016 발생과 폭 클램프가 **둘 다 사라진다**.
6. `GetDpiForWindow`는 두 조건 모두 96이다.

### 동시 관측 (검토보다 강한 반박)

`minTrack.x = 1016`이 관측된 **바로 그 9개 샘플 각각에서** `GetDpiForWindow`는 **96**이었다.

```
t=2315  minTrack=1016  width=314  GetDpiForWindow=96
t=2316  minTrack=1016  width=314  GetDpiForWindow=96
t=2316  minTrack=1016  width=314  GetDpiForWindow=96
t=5382  minTrack=1016  width=314  GetDpiForWindow=96
t=5398  minTrack=1016  width=314  GetDpiForWindow=96
t=5400  minTrack=1016  width=314  GetDpiForWindow=96
t=8449  minTrack=1016  width=314  GetDpiForWindow=96
t=8449  minTrack=1016  width=314  GetDpiForWindow=96
t=8450  minTrack=1016  width=314  GetDpiForWindow=96
```

`GetDpiForWindow` 값의 전체 분포:

| 데이터셋 | 샘플 | `GetDpiForWindow` |
|---|---:|---|
| Experiment A | 201,195 | **96 (100%)** |
| Experiment B | 194,771 | **96 (100%)** |

즉 `ptMinTrackSize.x`가 1016인 순간에 `GetDpiForWindow`는 96이다. **두 값이 동시에 관측되므로 `minTrack = f(GetDpiForWindow)` 형태는 성립하지 않는다.** 배율은 다른 경로에서 온다.

### 강하게 지지됨 — 관측과 일치하나 내부 구현은 미확인

1. 200% 배율이 최소화된 창의 위치로부터 결정되어 최소 트랙 폭에 적용된다는 해석이, 관측된 순서와 일치한다.
2. `500 × scale + 16` 모델이 516과 1016 두 실측값과 일치한다.

### 미확정

1. Chromium이 배율을 어떤 API로 구하는지 (소스 미검토). `GetDpiForWindow`는 96을 반환하므로 그 경로가 아니다.
2. 최소 트랙 크기의 정확한 산술식. 두 점으로는 식이 결정되지 않는다.
3. 1026의 출처.
4. 1554x1290의 출처와 재현 조건.

**기존 가설에서 유지되는 부분:** 최소 폭 클램프 기전, 배율이 왼쪽 끝 모니터 기준이라는 점, `500 × scale + 16` 모델.
**수정해야 하는 부분:** 배율을 `GetDpiForWindow`에서 얻는다는 암묵적 가정(관측으로는 96). 200% 조건에서 `minTrack.x`는 1016인데 `GetDpiForWindow`는 96이므로, 두 값은 서로 다른 경로에서 나온다.

---

## 10. 데이터

| 파일 | 내용 |
|---|---|
| `sample_expA_200pct_leftmost.csv` | 201,195행. `t_ms,minTrack.x,width,dpi` |
| `sample_expB_100pct_leftmost.csv` | 194,771행. 동일 형식 |
| `observe.ps1` | WM_GETMINMAXINFO / WINDOWPLACEMENT / monitor 측정 |
| `sampler.ps1` | 연속 샘플러 (별도 프로세스) |
| `trigger3.ps1` | 3회 최소/복원 트리거 |

동시 샘플링이 필요한 이유: `ShowWindow`가 동기 호출이므로, 같은 스레드에서 복원 직후 측정하면 과도 구간(~1–2 ms)을 반드시 놓친다. 실제로 첫 시도에서 36,135 샘플을 찍었으나 1016은 0회였다.
