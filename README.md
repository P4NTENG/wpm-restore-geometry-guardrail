# WPM Restore Geometry Guardrail

> Personal Windows window-geometry experiment. AutoHotkey v2, ~2200 lines of
> readable source. It reads and restores window rectangles and nothing else:
> **no network access, no registry read or write, no process injection, no
> global keyboard/mouse hook, no keystroke or clipboard logging, no credential
> access, no obfuscation.** The complete set of Windows APIs it calls is listed
> below — it is 29 distinct calls, all in `user32`/`shcore`. Source is included and
> builds from source with one script.

Chrome이 FancyZones zone에서 최소화/복원될 때 너비가 `974 → 1016`으로 새는
현상을, **최소화 직전 geometry를 baseline으로 잡고 복원 후 불일치할 때만
되돌리는** 방식으로 외부에서 보정합니다.

DPI 추론 없음, `1016`/`1026`/`516` 상수 없음, zone 폭 강제 없음.

## 원리

```
EVENT_SYSTEM_MINIMIZESTART (0x16)  →  WINDOWPLACEMENT.rcNormalPosition 을 baseline으로 저장
        ↓ (사용자가 최소화)
EVENT_SYSTEM_MINIMIZEEND   (0x17)  →  IsIconic 확인 → 4좌표 비교 → 불일치 시 되돌림 → 재검증
```

교정은 **이벤트 경로에서만** 일어납니다. 주기적 스윕으로 보정하지 않습니다.
스윕은 관측(mirror)용으로만 남겨 두었습니다.

### 제약 (의도적으로 지킨 것)

- DPI를 추론하거나 상수로 보정하지 않음
- 사용자가 직접 resize한 크기를 존중 (Free zone 크기 유지)
- 타 프로세스 subclassing, DLL injection, `WM_DPICHANGED` 후킹 없음
- zone 자체를 강제로 이동/확대하지 않음

## 무엇을 하지 않는가 (소스에서 검증됨)

아래는 `wpm/wpm_v6.ahk` 2200줄을 grep해 확인한 결과입니다. 없는 API를
나열하는 게 아니라, **있는 API를 전부 적은 것**이 이 프로젝트의 요점입니다.

**하지 않는 것 — 전부 0건**

| 항목 | 검색한 API |
|---|---|
| 네트워크 | `WinHttp*`, `WinInet*`, `URLDownloadToFile`, `socket`, `InternetOpen*`, `HttpSendRequest` |
| 레지스트리 | `RegRead`, `RegWrite`, `RegCreateKey`, `RegDelete` — 읽기조차 없음 |
| 프로세스 주입 | `WriteProcessMemory`, `VirtualAllocEx`, `OpenProcess`, `CreateRemoteThread`, `NtCreateThread` |
| 전역 후킹 | `SetWindowsHookEx` (키보드/마우스) |
| 입력 합성 | `SendInput`, `Send`, `SendText`, `keybd_event`, `mouse_event` |
| 클립보드 | `A_Clipboard`, `Clip*` |
| 난독화 | `Crypt*`, `AES`, `Base64`, `LZMA`, `Compress` |
| 프로세스 실행 | `Run`, `ProcessClose` |

**호출하는 것 — 이게 전부입니다 (29개, 전부 `user32`/`shcore`)**

```
창 정보   EnumWindows, IsWindow, IsWindowVisible, IsWindowArranged,
          IsIconic, IsZoomed, GetWindowRect, GetClassNameW,
          GetWindowLongPtrW, GetWindowThreadProcessId, GetCurrentProcessId
배치/모니터 MonitorFromRect, MonitorFromWindow, GetMonitorInfoW, GetDpiForWindow
위치 변경  SetWindowPos, SetWindowPlacement, GetWindowPlacement, ShowWindow
이벤트     SetWinEventHook, UnhookWinEvent, RegisterShellHookWindow,
          DeregisterShellHookWindow, RegisterWindowMessage
메모리     RtlMoveMemory, GlobalFree, GetProcAddress, GetModuleHandleW,
          LoadLibraryW  (user32.dll, Shcore.dll 만)
```

`LoadLibraryW`는 `user32.dll`과 `Shcore.dll`(DPI awareness 확인) 두 개뿐입니다.

**쓰는 파일 — 로그 3개뿐**

| 경로 | 내용 |
|---|---|
| `%APPDATA%\wpm_guard.log` | 에러·교정 실패만. 128KB 초과 시 회전 |
| `%APPDATA%\wpm_debug.log` | 디버그 빌드에서만 |
| `%APPDATA%\WpmSnapWarning.ack` | DPI 경고 ToolTip 표시 여부 (빈 파일) |

설정 파일을 쓰지 않습니다. 레지스트리를 건드리지 않습니다. 네트워크를
쓰지 않습니다. 프로세스를 띄우지 않습니다.

Startup 폴더에 등록되면 창 위치만 관찰하고, 다른 앱을 실행하거나 내용을
읽지 않습니다.

## 구성

| 폴더 | 내용 |
|---|---|
| `wpm/` | 제품. `wpm_v6.ahk`(소스), `Open Downloads.ahk`, PerMonitorV2 매니페스트 |
| `build/` | `build.ps1` — 소스 → exe 빌드 + 매니페스트 주입 |
| `docs/` | 조사·실험·검증 보고서 4건 (최종: `Chrome_창크기_DRIFT_Guardrail검증.md` §28까지) |
| `tools/` | `ahkrun`(AHK 문법·런타임 에러 판독), `inject_manifest.py`, 진단 프로브 |

`data/`(측정 CSV), `archive/`(일회성 프로브·구빌드), `tests/`(회귀 러너)는
로컬 전용입니다. 측정이 130MB 넘고, 러너가 실제 사용자 창을 다루며 창 제목에
환경별 값이 박혀 있어 공개하지 않습니다.

## 빌드

AutoHotkey **v2** 런타임이 필요합니다 (v1 아님).

```powershell
powershell -ExecutionPolicy Bypass -File build/build.ps1            # release
powershell -ExecutionPolicy Bypass -File build/build.ps1 -DebugBuild # debug
```

산출물은 `dist/window_position_manager.exe`입니다. 빌드가 `PerMonitorV2`
매니페스트를 exe에 주입합니다 — 이게 빠지면 크로스 모니터 DPI에서 좌표가
어긋납니다.

### 스모크

```powershell
Start-Process dist\window_position_manager.exe
Start-Sleep 8
# 오류 다이얼로그가 뜨지 않았는지 확인
Get-Process | Where-Object { $_.ProcessName -eq '#32770' }
```

## 설치

```powershell
Copy-Item dist\window_position_manager.exe `
  "$([Environment]::GetFolderPath('Startup'))\window_position_manager.exe" -Force
```

같은 Startup 폴더에 `Open Downloads.exe`를 두면 `Win+E`로 Downloads 폴더가
열립니다 (AutoHotkey 없이 단독 실행).

## 상태

- guardrail: 이벤트 경로 활성. 스윕 교정 코드는 삭제됨
- 판정 기준: 앱별 ≥20사이클, 미교정 드리프트 0, 교정 성공률 100%, `!!` 0
- Chrome 34 cycles 충족. 그 외 앱은 표본 부족으로 관측 중
- 실패 신호는 `%APPDATA%\wpm_guard.log` (에러·교정 실패만 상시 기록)

자세한 실험 과정과 오류 분석은 `docs/`를 참고하세요.