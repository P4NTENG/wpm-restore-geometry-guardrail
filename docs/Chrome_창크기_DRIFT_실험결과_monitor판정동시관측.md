# 1016 발생 순간의 monitor 판정 동시 관측 — 실험 결과

**실시:** 2026-09-29
**대상:** Google Chrome `Chrome_WidgetWin_1`, hwnd `2624458`
**목적:** `ptMinTrackSize.x`가 1016이 되는 그 순간에, 위치 기반 monitor 판정과 `WM_GETMINMAXINFO`를 동시 관측
**상태:** 관측 전용. WPM 로직·FancyZones 설정·배율·Chrome 설정·zone correction 모두 변경하지 않음

---

## 1. 설계상 한계 (실험 전 예측)

`MonitorFromPoint(-32000,-32000)`는 **표시 배치의 순수 함수**다. 복원 중 배치는 바뀌지 않으므로, 외부 프로세스에서 아무리 고속으로 찍어도 값이 토글될 수 없다. 즉 "1016과 동시에 192로 바뀌는가"를 **바깥에서 측정하는 것은 구조적으로 불가능**하다.

따라서 관측 가능한 것은 **시간에 따라 실제로 변하는 값**뿐이다. 배치가 고정된 상태에서 `minTrack`가 토글되므로, 토글에 동기화하는 시스템 쿼리를 찾는 것이 목적이었다.

후보에 `GetWindowDpiAwarenessContext`를 1차에 포함한 이유: 이것이 외부에서 관측 가능한 **유일한 시간 변수** 후보였기 때문이다. (결과는 음성이었다.)

---

## 2. 계측 항목

| 컬럼 | 항목 |
|---|---|
| t_ms | 경과 시간 |
| minTrack | `WM_GETMINMAXINFO.ptMinTrackSize.x` |
| width | `GetWindowRect` 폭 |
| dpiForWindow | `GetDpiForWindow(hwnd)` |
| mFromPoint | `MonitorFromPoint(-32000,-32000)` + 해당 모니터 DPI |
| **mFromWindow** | **`MonitorFromWindow(hwnd)` + 해당 모니터 DPI** |
| awarenessCtx | `GetWindowDpiAwarenessContext(hwnd)` |
| awareness | `GetAwarenessFromDpiAwarenessContext()` |
| sysDpi | `GetDpiForSystem()` |

**측정 방법의 두 가지 중요 조건:**

1. **프로세스 DPI 인지 필수.** `GetDpiForMonitor`는 호출 프로세스가 per-monitor aware가 아니면 **모든 모니터에 96을 반환**한다. 처음 실행에서 노트북(200%)이 96으로 나와 깨졌고, 해결책은 `GetDpiForMonitor`를 버리고 **모니터 위의 창으로 `GetDpiForWindow`를 조회**하는 것이었다(모니터 → DPI 맵을 시작 시 1회 구축). WPM의 `MonitorDpi()`와 동일 방식이며, 이것이 올바르게 192/96을 반환한다.
2. **과도 구간 포착에 별도 프로세스 필요.** `ShowWindow`가 동기 호출이므로 동일 스레드에서는 놓친다. 샘플러와 트리거를 별도 프로세스로 실행한다.

---

## 3. Experiment A — 200% 모니터가 가장 왼쪽

### 배치

```
DISPLAY1  laptop  2880x1800 @  0,0        ← 가장 왼쪽, PRIMARY, 192 DPI
DISPLAY2  DEL     1920x1080 @  2880,368   ← 오른쪽, 96 DPI
(-32000,-32000) → laptop, 192 DPI
```

### 결과 (155,639 샘플)

| 항목 | 값 |
|---|---|
| `minTrack.x` = 516 | 155,630 |
| **`minTrack.x` = 1016** | **9** |
| width = 1016 / 974 / 314 | 134,546 / 11,814 / 9,279 |
| `GetDpiForWindow` | **96 (전 구간)** |
| `MonitorFromPoint` | laptop@192 — **155,639 (전 구간, 불변)** |
| **`MonitorFromWindow`** | **DEL@96 155,628 / laptop@192 11** |
| `awarenessCtx` | 34 — 155,639 (불변) |
| `awareness` | 2 (SYSTEM_AWARE) — 155,639 (불변) |
| `GetDpiForSystem` | 96 — 155,639 (불변) |

### 시퀀스 (3회)

```
t=2309-2311  mFromWindow=laptop@192   minTrack=1016   width=314
t=5351       mFromWindow=laptop@192   minTrack=516    ← 전이 직전
t=5352-5353  mFromWindow=laptop@192   minTrack=1016
t=8418       mFromWindow=laptop@192   minTrack=516    ← 전이 직전
t=8419-8422  mFromWindow=laptop@192   minTrack=1016
```

**`MonitorFromWindow`가 200% 모니터로 바뀐 11개 샘플 중 9개가 `minTrack=1016` 샘플과 정확히 일치**한다. 나머지 2개는 전이 직전 샘플이다.

---

## 4. Experiment B — 100% 모니터가 가장 왼쪽

### 배치

```
DISPLAY1  laptop  2880x1800 @  0,0        ← 주 화면 유지, 192 DPI
DISPLAY2  DEL     1920x1080 @  -1920,368   ← 왼쪽으로 이동, 96 DPI
(-32000,-32000) → DEL, 96 DPI
```

**§14/§16이 시험하지 않은 구성이다.** 노트북이 주 화면을 유지하면서 DEL만 가장 왼쪽에 있다.

### 결과 (182,292 샘플)

| 항목 | 값 |
|---|---|
| `minTrack.x` = 516 | **182,292 (전 구간)** |
| **`minTrack.x` = 1016** | **0** |
| width = 974 / 314 | 171,503 / 10,789 |
| width = 1016 | **0** |
| `GetDpiForWindow` | 96 — 182,292 (불변) |
| `MonitorFromPoint` | DEL@96 — 182,292 (불변) |
| **`MonitorFromWindow`** | **DEL@96 — 182,292 (불변)** |
| `awarenessCtx` / `awareness` / `sysDpi` | 34 / 2 / 96 — 182,292 (불변) |

**최소화 중(`width=314`, 10,789 샘플)에도 `MonitorFromWindow`는 DEL@96을 유지**했고, `minTrack`는 516에 머물렀다.

---

## 5. A/B 대조

| 항목 | A (200% 왼쪽) | B (100% 왼쪽) |
|---|---|---|
| 총 샘플 | 155,639 | 182,292 |
| `minTrack` = 1016 | **9** | **0** |
| width = 1016 | 134,546 | **0** |
| `MonitorFromWindow` 가 200% 모니터로 전환 | **11 샘플** | **0** |
| `MonitorFromWindow` 전환 ↔ minTrack=1016 중첩 | **9/9** | 해당 없음 |
| `MonitorFromPoint` 변화 | 없음 (192 고정) | 없음 (96 고정) |
| `GetDpiForWindow` 변화 | 없음 (96 고정) | 없음 (96 고정) |
| `awarenessCtx` 변화 | 없음 (34 고정) | 없음 (34 고정) |
| `awareness` 변화 | 없음 (2 고정) | 없음 (2 고정) |
| `GetDpiForSystem` 변화 | 없음 (96 고정) | 없음 (96 고정) |

---

## 6. 확인됨 — 측정값으로 직접 입증

1. `MonitorFromWindow(hwnd)`는 **최소화 중에** 200% 모니터를 반환하는 구간이 있으며(A: 11 샘플), 그 구간의 9개가 `minTrack.x = 1016`과 **정확히 중첩**된다.
2. 100% 모니터가 가장 왼쪽인 조건(B)에서는 `MonitorFromWindow`가 **최소화 중에도** DEL@96을 유지하고, `minTrack = 1016`은 182,292 샘플에서 **0회**다.
3. `minTrack.x`가 1016인 **모든 9개 샘플에서 `GetDpiForWindow`는 96**이었다.
4. 다음 항목은 A·B **양쪽에서 전 구간 불변**이었다: `GetDpiForWindow`, `MonitorFromPoint`, `GetWindowDpiAwarenessContext`, awareness 종류, `GetDpiForSystem`.

## 7. 가설 수정

**폐기:** "Chromium이 `(-32000,-32000)` 위치를 직접 조회해 200% 배율을 얻는다."

`MonitorFromPoint(-32000,-32000)`는 A에서 155,639 샘플 **전부** 192를 반환했고 **한 번도 변하지 않았다.** 이 값이 1016을 만든다면 매 순간 192여야 하는데, 1016이 아닌 155,630개 순간에도 192였다. 따라서 이 API의 반환값은 `minTrack`를 설명하지 못한다.

**수정:** "Windows가 **최소화된 창을 200% 모니터 소속으로 보고**하고, Chromium이 그 소속에 따라 최소 트랙 폭에 배율을 적용한다."

- 트리거는 `MonitorFromWindow`의 답이 바뀌는 순간이다(A: 전환 11회, 1016 발생 9회가 중첩).
- B에서 이 전환이 **발생하지 않아** 1016도 발생하지 않았다(0회).
- 주체는 Chromium의 위치 조회가 아니라 **Windows의 창 소속 판정**으로 보인다.

## 8. 강하게 지지됨 / 미확정

**강하게 지지됨:** 최소화 상태의 창 소속 판정(200% vs 100%)이 최소 트랙 폭 하한을 결정한다. A/B 통제 비교이며 시간 순서도 일치한다.

**미확정:**
1. Chromium이 실제로 `MonitorFromWindow`를 호출하는지 (내부 구현 미검토). Windows가 그것을 호출했을 가능성도 있다.
2. 배율이 최소 트랙 폭의 **어떤 부분**에 곱해지는지. `500 × scale + 16`은 516·1016 두 점과 일치하나 증명되지 않았다.
3. Chromium이 최소화 구간에 진입/이탈할 때 어떤 트리거(메시지, 상태 변화)로 재계산하는지.
4. `1026`의 출처, `1554x1290`의 출처 — 별개 미해결.

---

## 9. 데이터

| 파일 | 내용 |
|---|---|
| `sample2_expA_200pct_leftmost.csv` | 155,639행, 9컬럼 |
| `sample2_expB_100pct_leftmost.csv` | 182,292행, 9컬럼 |
| `sampler2.ps1` | 9항목 동시 샘플러 (별도 프로세스) |
| `trigger3.ps1` | 3회 최소/복원 트리거 (별도 프로세스) |
| `observe.ps1` | WM_GETMINMAXINFO / WINDOWPLACEMENT / monitor 측정 |

**데이터 판독 주의:** `grep "1016"`은 B 데이터에서 253건을 찾았으나, **전부 timestamp 컬럼**(`t=1016`, `t=10160`~`t=10169`)이었다. 판정 시 컬럼을 지정해야 한다: `awk -F, '$2==1016'` (minTrack), `$3==1016` (width). 두 컬럼 모두 B에서 0건.

---

## 10. 순서 판정 — 모니터 소속 전환이 먼저

기존 A/B 데이터에서 전이 구간을 시간축으로 분리하면 **순서가 판정**된다.

### A (200% 왼쪽) 3개 전이 구간

```
── 구간 1 (2.0 ms)
   직전  t=2308.000  mfw= 96dpi  minTrack=516   width=314
   전환  t=2309.000  mfw=192dpi  minTrack=1016  width=314
   전환  t=2311.000  mfw=192dpi  minTrack=1016  width=314
   직후  t=2312.000  mfw= 96dpi  minTrack=516   width=1016

── 구간 2 (2.0 ms)
   직전  t=5351.000  mfw= 96dpi  minTrack=516   width=314
   전환  t=5351.000  mfw=192dpi  minTrack=516   width=314   ← 모니터 먼저, minTrack 아직 516
   전환  t=5352.000  mfw=192dpi  minTrack=1016  width=314   ← 1샘플 뒤 따라옴
   전환  t=5353.000  mfw=192dpi  minTrack=1016  width=314

── 구간 3 (4.0 ms)
   직전  t=8417.000  mfw= 96dpi  minTrack=516   width=314
   전환  t=8418.000  mfw=192dpi  minTrack=516   width=314   ← 모니터 먼저
   전환  t=8419.000  mfw=192dpi  minTrack=1016  width=314
   전환  t=8422.000  mfw=192dpi  minTrack=1016  width=314
   직후  t=8424.000  mfw= 96dpi  minTrack=516   width=1016
```

### 판정

**3개 구간 중 2개**에서 `mfw=192dpi` 인데 `minTrack=516` 인 **중간 샘플**이 존재한다. 즉

1. `MonitorFromWindow`의 소속이 200% 모니터로 **먼저** 바뀐다
2. 그 다음 샘플(약 0.07–1 ms 뒤)에 `ptMinTrackSize.x`가 1016이 된다
3. 복원 시 폭이 1016에 클램프된다
4. `MonitorFromWindow`와 `minTrack`가 모두 원래 값으로 돌아온다(폭은 1016에 남음)

구간 1에서는 중간 샘플이 없어 동시로 관측되었다. 즉 **"동시에 변한다"와 "순서가 있다"는 배제 관계가 아니며**, 관측된 것은 "최대 1샘플(약 0.07 ms) 이내"이다. 샘플 간격(~0.07 ms)이 전이 시간보다 크기 때문에 더 좁히는 것은 현재 표본율로 불가능하다.

**추가 관찰:** 전이가 일어나는 동안 `width=314`(최소화 상태)로 고정이다. 폭이 1016이 되는 것은 복원 이후이며, 최소화가 먼저다.

### B (100% 왼쪽)

`mfw=192dpi` 샘플 **0건**, `minTrack=1016` **0건**. 최소화 중에도 `MonitorFromWindow`는 96을 유지했다.

### 시사점

"무엇이 먼저인가"에 관해, **시스템의 창 소속 판정이 먼저**이고 **최소 트랙 폭의 변화가 그 응답**이다. 반대 순서는 관측되지 않았다.

다만 이것은 **시각 순서의 관측**이지, **인과 관계의 입증**이 아니다. `MonitorFromWindow`가 바뀐 것이 1016의 원인인지, 둘이 같은 다른 사건의 공통 결과인지는 이 표본율로 구분되지 않는다.

---

## 11. WinEvent 경계 사건 관측 (C# 호스트, A 배치)

별도 도구: `tl2.cs` / `tl2.exe`. 이벤트와 샘플이 **같은 시계**에 기록된다.

### 계측

`EVENT_SYSTEM_MINIMIZESTART` / `EVENT_SYSTEM_MINIMIZEEND` 훅과, 동일 스레드에서 42–93 µs 간격의 샘플 루프. 각 행에 `minTrack`, `width`, `MonitorFromWindow`, 모니터 DPI, `GetDpiForWindow`.

총 221,647 샘플 / 3회 반복.

### 결과 — 전환은 MINIMIZESTART가 아니라 복원 직전

```
사이클1  MINIMIZESTART t=2141.405
         (최소화 상태 ~417ms 동안 mon=DEL@96, minTrack=516 로 유지)
         전환  t=2558.134   minTrack=1016  width=314  monDpi=192
         전환  t=2558.918   minTrack=1016  width=314  monDpi=192
         전환  t=2559.359   minTrack=1016  width=314  monDpi=192
         전환  t=2559.748   minTrack=1016  width=314  monDpi=192
         직후  t=2561.503   minTrack=516   width=1016 monDpi=96
         MINIMIZEEND t=2569.115
```

3회 모두 동일:

| 사이클 | MINIMIZESTART | 전환 시작 | 전환→MINIMIZEEND |
|---|---:|---:|---:|
| 1 | 2141.405 | 2558.134 (**+416.7 ms**) | 11.0 ms 전 |
| 2 | 5206.474 | 5624.545 (**+418.1 ms**) | 12.2 ms 전 |
| 3 | 8277.924 | 8684.153 (**+406.2 ms**) | 28.4 ms 전 |

**최소화 상태 400 ms 이상 동안 `monDpi=96`, `minTrack=516`이었다.** 전환은 복원 시점에만 발생한다.

전이 구간 상세(3회):

```
구간1 (1.6ms, 4샘플)   구간2 (2.0ms, 4샘플)   구간3 (1.0ms, 3샘플)
직전  minTrack=516 mon=96  직전  516 mon=96        직전  516 mon=96
전환  minTrack=1016 mon=192 전환 1016 mon=192      전환 1016 mon=192
직후  minTrack=516 width=1016 mon=96             직후  516 width=1016 mon=96
```

### 순서에 대한 자기 정정

`monDpi=192`인 **11개 샘플 전부가 `minTrack=1016`**이다. **`monDpi=192`인데 `minTrack=516`인 중간 상태는 0건**이다.

따라서 §10의 "모니터 소속 전환이 먼저, minTrack가 그다음"이라는 서술은 **철회한다.** 그때 관측된 2개의 중간 샘플은 PowerShell 표본(간격 ~77 µs)에서 생긴 표본 부족이며, 표본율을 높이면 사라진다. 현재 표본율(42–93 µs)로는 두 값이 **한 샘플 안에 동시에** 변한다.

**"무엇이 먼저인가"는 이 표본율로 판정할 수 없다.** 시퀀스는 확정되었으나 인과 방향은 여전히 미확정이다.

### 갱신된 모델

```
최소화 (MINIMIZESTART)
  → 400 ms 이상, mon=DEL@96, minTrack=516 로 그대로
  ↓
[복원 개시]
  ↓
~1–2 ms 구간: mon → laptop@192 과 minTrack → 1016 이 동시 발생
  ↓
폭이 1016 로 클램프
  ↓
mon → DEL@96, minTrack → 516 로 동시 복귀 (폭은 1016 에 남음)
  ↓
MINIMIZEEND 이벤트 전달 (실제 복원보다 7–28 ms 늦음)
```

**1016 구간은 최소화 전체가 아니라 복원 직전 1–2 ms뿐이다.** 최소화는 트리거가 아니다. 트리거는 복원이며, 그 순간 창이 아직 최소화 좌표에 있기 때문에 소속 판정이 200% 모니터로 나간다.

`MINIMIZEEND` 이벤트가 실제 복원보다 7–28 ms 늦게 기록되는 것은 out-of-context 큐의 전달 지연이며, 이벤트의 `sysTime`이 권위 있는 시각이다.

### 이 관측이 갱신하는 것

| 항목 | 이전 | 현재 |
|---|---|---|
| 전환 시점 | 최소화 시점 | **복원 시점** |
| 1016 구간 길이 | 최소화 전체로 추정 | **1–2 ms** |
| 최소화가 1016을 유발 | 가설 | **배제** |
| mon 전환 → minTrack 순서 | 모니터 먼저 | **미확정** (동시) |

### 도구 관련 기록

C# 호스트로 옮기면서 드러난 실제 결함 3개:

1. **대리 개체 GC → 훅의 dangling 함수 포인터.** 훅은 원시 포인터만 보관하므로, 지역 변수로 둔 대리 개체가 수집되면 첫 이벤트에서 죽은 메모리를 호출한다. 정적 필드로 루팅해 해결.
2. **콜백 내 대상 창으로의 동기 `SendMessage` 재진입.** 콜백은 대상 창이 자기 이벤트를 처리 중이라, 그 안에서 대상 창으로 `SendMessage`를 하면 창 프로시저가 재진입해 멈춘다. 제거(minTrack는 메인 루프가 읽으므로 손해 없음).
3. **`EVENT_OBJECT_LOCATIONCHANGE` 폭발.** 이 창에서 초당 수천 회 발생해 out-of-context 큐가 따라가지 못하고 프로세스가 죽는다. 최소화 페어만 계측.

PowerShell 호스트에서는 이 셋이 "이벤트 0건 + 37 ms/샘플"이라는 비진단적 증상으로만 나타났고, C#로 옮기자 원인이 드러났다.

**미계측:** `EVENT_OBJECT_LOCATIONCHANGE`를 빼야 했으므로 위치 메시지 단위의 세분화는 이번에 얻지 못했다. `WM_SIZE` / `WM_WINDOWPOSCHANGED`의 flags는 외부 관측이 원천적으로 불가하며, 크로스 프로세스 서브클래싱은 코드 주입이라 관측 범위를 벗어난다.
