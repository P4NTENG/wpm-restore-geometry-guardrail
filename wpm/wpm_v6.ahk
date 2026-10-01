; ============================================================
;  Window Position Manager v6   (AutoHotkey v2)
;
;  Why v6 exists
;  -------------
;  v1 bug: a "#e::" hotkey sat inside the auto-execute section, which
;  ended it before RegisterShellHookWindow / RegisterCallback /
;  SetWinEventHook could run. No window events were ever received and
;  the INI was never created. Hotkeys now live at the bottom.
;
;  v6 runs from a compiled exe carrying a PerMonitorV2 manifest.
;  AutoHotkey is DPI-unaware by default, so SetWindowPos distorted the
;  coordinates of per-monitor-aware windows: asking for 1440x1704 on a
;  200% display landed the window at 2880x3408. With the manifest the
;  same call returns 1440x1704 exactly.
;
;  INI value layout
;    x | y | w | h | max | snap | nx | ny | nw | nh
;      max : 1 when maximized
;      snap: "-" or L/R/T/B, Q:TL..Q:BR, T3:L..T3:B
;      n*  : geometry before snapping, so minimize / maximize round
;            trips return to the user's own size
; ============================================================

#Requires AutoHotkey v2.0
#SingleInstance Force
; Send warnings to stdout instead of a modal dialog. AHK v2 raises a
; spurious "never assigned" note for Callback() and friends, and a
; dialog during startup would block the tray script from ever running.
#Warn All, StdOut

SetWinDelay(-1)
SetControlDelay(-1)

; ============================================================
;  Configuration
; ============================================================

IniPath   := A_AppData "\WindowPositions.ini"
LearnPath := A_AppData "\WindowPositions_learned.ini"
DebugOn   := false
DebugPath := A_AppData "\wpm_debug.log"
GuardLogPath := A_AppData "\wpm_guard.log"

SkipClasses := "^(Shell_TrayWnd|Shell_SecondaryTrayWnd|Progman|WorkerW|Windows\.UI\.Core\.CoreWindow|MultitaskingViewFrame|TaskListThumbnailWnd|Ghost|SearchHost)$"
SkipProcs   := "^(SearchHost\.exe|StartMenuExperienceHost\.exe|TextInputHost\.exe|ShellExperienceHost\.exe|ClickToDo\.exe|LockApp\.exe|ApplicationFrameHost\.exe|SystemSettings\.exe|RuntimeBroker\.exe|sihost\.exe|AutoHotkey.*\.exe|Open Downloads\.exe)$"

WidgetClasses := "^(Chrome_RenderWidgetHostHWND|.*RenderWidgetHost.*|.*_ChromeProcess$|DirectCompositionHWND|EdgeUiInputTopWndClass|DummyDWMListenerWindow|.*_WDAgilityCoreWnd$|ForegroundStaging|XamlExplorerHostIslandWindow|ShellHandwritingCanvas.*|ThumbnailDeviceHelperWnd|tooltips_class32|SystemTray_Main|ATL:.*|ScreenrayOwnerWindow|Cua\.AgentCursorOverlay|unsharing frame|.*ZConf.*|CCReceiver.*|.*_W?ndProc$|.*_Recv.*|NetUIHWND|MonoEdit.*|SysEdit_32|.*_IME.*|IMEWindow|MSCTFIMEUI|Default IME|NUIDialog|WMPlayer.*|.*MediaPlayer.*|EVA_Window.*|ZPFloat.*|VideoFrameWndClass|Duilib_Anim_StageWindowClassName|#32770|Intermediate D3D Window|.*D3D Window|NotepadTextBox|RichEditD2D.*|.*(TextBox|RichEdit[0-9A-Za-z]*|Edit$|_Ed$|Scintilla|CodeEdit))$"

MinSaveW := 200
OwnPid   := 0
EventCount := 0
MinSaveH := 200
; The snap engine allocates the outer frame, so an app that draws its
; own border or scrollbar does not land on the exact fraction. Chrome on
; a 1920x1032 work area occupies 1016x523 for a quarter snap, which is
; 0.529 of the width against an expected 0.5.
;
; The window has to stay clear of the gap between layouts that are
; actually told apart. A full-height left half and a bottom half differ
; by 0.5 in fy, and a quarter sits 0.25 from each of them, so anything
; much above 0.2 would start reading a bottom half as a quarter. 0.06
; covers a frame of a few tens of pixels and still separates all of them.
SnapTol  := 0.06

; ============================================================
;  State
; ============================================================

ShellMsg       := 0
ShellRegistered := false

hMoveStartHook := 0
hMoveEndHook   := 0
hLocationHook  := 0
hDestroyHook   := 0
hShowHook      := 0

MoveStartProc := 0
MoveEndProc   := 0
LocationProc  := 0
DestroyProc   := 0
ShowProc      := 0

MovingWindows    := Map()
MovingUntil      := Map()
LastSaved        := Map()
PendingSelfCheck := ""
SeenAtCreate     := Map()
TinyAtCreate     := Map()

; A window we have just placed is left alone for a moment. Without this
; the correction and the app reaction to it alternate and neither side
; ever settles.
SettleUntil      := Map()
SettleMs         := 1500
; A window that has just appeared is given time to reach its real size
; before anything is measured or written about it.
BornMs           := 1500
; Executables FancyZones has placed in a zone, keyed on the lower case
; image path. Re-read when the history file changes.
;
; This is the whole of the FancyZones awareness, and it is deliberately
; read only. FancyZones owns the geometry of a zoned window: this only
; declines to remember such a window, so that a zone rectangle is never
; stored as if it were a free position and later fought over. Nothing
; here measures, learns or corrects a zone.
FZZoneApps       := Map()
FZStamp          := ""
FZNextCheck      := 0

; ============================================================
;  Restore geometry guardrail
;
;  A window that comes back from a minimise is not always restored to the
;  geometry it went down with. When it is not, the window is put back.
;  That is the whole rule, and it is deliberately blind to why: nothing
;  here reads a dpi, a monitor scale, or what the window had before it
;  was ever in a zone. Whatever the window was at the moment it went
;  down is what it is expected to come back to.
;
;  GuardLast is a mirror of where a window currently is, refreshed on
;  every sweep while it is not minimised, so it is observation rather
;  than policy. GuardBaseline is the one rectangle that carries meaning:
;  the geometry at the moment the window went down, held for the length
;  of that one minimise and restore and then discarded. There is
;  deliberately no hwnd keyed record of where a window ought to be,
;  because a window that has since been moved by hand would then be
;  dragged back to somewhere it was never asked to go.
;
;  Both ends of the cycle arrive as minimise events, 1:1 and on time,
;  so no sweep timing is involved. An earlier sweep based design was
;  removed after 21 consecutive real-world cycles never needed it.
; ============================================================

;  GuardBaseline is keyed on the window handle and holds the rectangle the
;  shell itself was holding when the window went down. It is captured at
;  EVENT_SYSTEM_MINIMIZESTART from WINDOWPLACEMENT.rcNormalPosition,
;  which keeps the restore rectangle whether the window is up or down,
;  and is dropped as soon as that window has been judged.
;
;  GuardLast is a light mirror of where a window has actually been, kept
;  only so a baseline can be sanity checked before anything is moved. A
;  baseline that disagrees with where the window was is not trusted, and
;  the cycle is abandoned rather than acted on.
;
;  There is deliberately no hwnd keyed record of where a window ought to
;  be. A window that has since been moved by hand would be dragged back
;  to somewhere it was never asked to go.
GuardBaseline   := Map()
GuardLast       := Map()
; proc|cls per window, cached by the sweep so the event path never has
; to ask the owning process anything from inside a callback.
GuardApp        := Map()
; A single extra attempt after a correction that did not take, used
; once and then dropped whatever happens. {want: rect-string, stuck:
; "w|h"}. It is honoured only when the window has not moved since the
; failure, so a resize by hand in between cancels it instead of being
; fought. Session scope only: memory, dies with the process, dropped
; with the window. No zone knowledge, no permanent cache: want is a
; size this window previously held while up, never a zone or a
; computed value.
GuardRetry      := Map()
; Whether IsWindowArranged exists on this build, resolved once at
; startup so no event path has to find out by throwing.
HasArranged     := false
; How close two rectangles have to be before they count as the same one.
; A window is not expected to land on precisely the same pixel, and a
; real move by the user is far larger than this.
GuardTolPx      := 2
; One correction per restore cycle. The correction is verified, and a
; failure is left alone rather than retried into a fight with the app.
GuardMaxTries   := 1
; How far a baseline may differ from where the window was actually seen
; before the baseline is treated as belonging to some other window. The
; check is on size only, because rcNormalPosition is expressed against
; the work area while a window rectangle is in screen coordinates, and
; those two agree on size even where they do not agree on origin.
GuardTrustPx    := 8

; ============================================================
;  Telling windows of the same program apart
;
;  A record used to be keyed on the program and the window class alone,
;  so two Explorer windows shared one key and the second one overwrote
;  the first one's place. Every window of a program was then pulled back
;  to that single place, and two windows ended up on top of each other.
;
;  The key is the slot number on its own. An earlier version also put the
;  window title in the key, on the grounds that two Explorer windows are
;  told apart by the folder they have open. That was wrong: a window's
;  title changes when it is navigated somewhere else, so every visit left
;  a second record behind under the same slot, and the manager would
;  find a record that belonged to a different window and pull this one
;  into it. The two windows then traded places, which is the same
;  symptom this was meant to fix.
;
;  The slot number is the whole of the identity, and it is handed out in
;  the order the manager first sees the windows of a program. The second
;  Explorer window becomes the second slot and keeps its own place, and
;  closing a window gives its slot back so that reopening it lands on
;  the same record.
; ============================================================

; hwnd -> the slot it was given while it was alive.
WindowSlot       := Map()
; proc|cls -> the next slot number to hand out for that pair.
WindowSlotNext   := Map()

EnumProcRef := 0
EnumResult  := []
BornAt      := Map()

; ============================================================
;  Init
;
;  Registration is deferred by a timer on purpose. OnMessage and
;  Callback need real function objects, and handing them a name that
;  is still further down the file fails with "Invalid callback
;  function". By the time this timer fires the whole script is loaded
;  and every function object exists.
; ============================================================

SetTimer(StartTick, -200)

; A failure inside Start leaves the script running with no hooks at all
; and nothing written anywhere, which looks exactly like "it started
; fine". The entry point is wrapped so that state is always reported.
StartTick() {
    ; Prove the log works before anything else runs: a silent log looks
    ; identical to a script that never started.
    LogLine("--- tick ---")
    try Start()
    catch as e
        LogBoth("!! Start failed: " e.Message " line " e.Line)
}

; Top level windows, including hidden ones.
;
; WinGetList only reports windows AHK considers top level, and
; DetectHiddenWindows does not exist in this build, so EnumWindows is
; used directly. The collected list is rebuilt on each call, which is
; fine for a sweep that runs a few times a second.
EnumTopWindows() {
    global EnumProcRef, EnumResult

    EnumResult := []
    if !EnumProcRef
        EnumProcRef := CallbackCreate(EnumCollect, "", 2)
    DllCall("EnumWindows", "Ptr", EnumProcRef, "Ptr", 0, "Ptr")
    return EnumResult
}

EnumCollect(hwnd, lParam) {
    global EnumResult
    EnumResult.Push(hwnd)
    return true
}


; ============================================================
;  Low level helpers
; ============================================================

Start() {
    global ShellMsg, ShellRegistered, DebugOn
    global hMoveStartHook, hMoveEndHook, hLocationHook, hDestroyHook, hShowHook
    global MoveStartProc, MoveEndProc, LocationProc, DestroyProc, ShowProc
    global hMinStartHook, hMinEndHook, MinStartProc, MinEndProc

    DpiOk := DpiInit()
    LogLine("DpiInit=" DpiOk)

    if DllCall("RegisterShellHookWindow", "Ptr", A_ScriptHwnd) {
        ShellRegistered := true
        ; The string is "SHELLHOOK" with two Os. RegisterWindowMessage is
        ; case-insensitive but the spelling has to be right or the shell
        ; never sends us anything.
        ShellMsg := DllCall("RegisterWindowMessage", "Str", "SHELLHOOK", "UInt")
        if ShellMsg {
            OnMessage(ShellMsg, ShellMessage, 1)
        } else {
            LogBoth("!! RegisterWindowMessage(SHELLHOOK) failed")
        }
    } else {
        LogBoth("!! RegisterShellHookWindow failed")
    }

    ; v2 spells the v1 Callback() as CallbackCreate()
    MoveStartProc := CallbackCreate(WinEventMoveStart, "", 7)
    MoveEndProc   := CallbackCreate(WinEventMoveEnd, "", 7)
    LocationProc  := CallbackCreate(WinEventLocation, "", 7)
    DestroyProc   := CallbackCreate(WinEventDestroy, "", 7)
    ShowProc      := CallbackCreate(WinEventShow, "", 7)

    hMoveStartHook := DllCall("SetWinEventHook", "UInt", 0x000A, "UInt", 0x000A,
        "Ptr", 0, "Ptr", MoveStartProc, "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")
    hMoveEndHook := DllCall("SetWinEventHook", "UInt", 0x000B, "UInt", 0x000B,
        "Ptr", 0, "Ptr", MoveEndProc, "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")
    hLocationHook := DllCall("SetWinEventHook", "UInt", 0x800B, "UInt", 0x800B,
        "Ptr", 0, "Ptr", LocationProc, "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")
    hDestroyHook := DllCall("SetWinEventHook", "UInt", 0x8001, "UInt", 0x8001,
        "Ptr", 0, "Ptr", DestroyProc, "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")
    hShowHook := DllCall("SetWinEventHook", "UInt", 0x8002, "UInt", 0x8002,
        "Ptr", 0, "Ptr", ShowProc, "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")
    ; The two ends of a minimise. The guardrail reads the rectangle the
    ; shell is holding at the going down, and compares it at the coming
    ; back, so the sweep's own 700ms timing is not in the path at all.
    ; One message per minimise, and both arrive on the thread the shell
    ; already delivers the other hooks on.
    MinStartProc := CallbackCreate(WinEventMinimizeStart, "", 7)
    MinEndProc   := CallbackCreate(WinEventMinimizeEnd, "", 7)
    ; Two separate hooks, one per event. A single range hook would send
    ; both events to the same callback and the restore would be judged
    ; as a minimise, which is exactly what happened once and cost a
    ; whole test matrix.
    hMinStartHook := DllCall("SetWinEventHook", "UInt", 0x0016, "UInt", 0x0016,
        "Ptr", 0, "Ptr", MinStartProc, "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")
    hMinEndHook := DllCall("SetWinEventHook", "UInt", 0x0017, "UInt", 0x0017,
        "Ptr", 0, "Ptr", MinEndProc, "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")
    if DebugOn
        LogLine("minimize hooks 0x16/0x17 -> " (hMinStartHook ? "ok" : "NULL")
            . "/" (hMinEndHook ? "ok" : "NULL"))

    OnExit(Cleanup)
    ; A window can appear without ever sending a LOCATION event, which
    ; is common for tool windows and anything created off-screen before
    ; it is shown. Sweeping the window list on a timer covers those, and
    ; picks up new windows that have a stored layout.
    SetTimer(SweepTick, 700)
    if DebugOn
        SetTimer(Diag, -900)

    CheckSnapFloorRisk()

    ; One probe so no event path ever has to discover a missing export
    ; by throwing inside a callback.
    global HasArranged
    try {
        DllCall("IsWindowArranged", "Ptr", 0)
        HasArranged := true
    } catch {
        HasArranged := false
    }

    if DebugOn
        LogLine("--- v6 start --- hooks " hMoveStartHook "/" hMoveEndHook
            "/" hLocationHook "/" hDestroyHook "/" hShowHook " shellMsg=" ShellMsg)
}

; Walk every visible window through the filter one stage at a time so a
; rejection can be attributed to a specific condition.
Diag() {
    global SkipClasses, SkipProcs, WidgetClasses

    total := 0, visible := 0, noCls := 0, widget := 0
    skipCls := 0, noProc := 0, skipProc := 0, exStyleFail := 0
    passed := 0
    for hwnd in EnumTopWindows() {
        total += 1
        if !DllCall("IsWindowVisible", "Ptr", hwnd)
            continue
        visible += 1

        cls := WinGetClassName(hwnd)
        if (cls = "") {
            noCls += 1
            continue
        }
        if RegExMatch(cls, WidgetClasses) {
            widget += 1
            continue
        }
        if RegExMatch(cls, SkipClasses) {
            skipCls += 1
            continue
        }
        proc := WinGetProcName(hwnd)
        if (proc = "") {
            noProc += 1
            if (noProc <= 3)
                LogLine("  diag: no procName for class=" cls " hwnd=" hwnd)
            continue
        }
        if RegExMatch(proc, SkipProcs) {
            skipProc += 1
            continue
        }
        ex := GetWindowLongPtrSafe(hwnd)
        if (ex & 0x00000080) || (ex & 0x00020000) {
            exStyleFail += 1
            continue
        }
        passed += 1
        r := GetWindowRect(hwnd)
        if (passed <= 12) {
            sz := "?"
            if IsObject(r)
                sz := r.w "x" r.h
            LogLine("  diag: ACCEPT " proc " | " cls "  ex=" ex "  size=" sz)
        }
    }
    LogLine("diag totals: total=" total " visible=" visible " noClass=" noCls
        " widget=" widget " skipClass=" skipCls " noProc=" noProc
        " skipProc=" skipProc " exStyleFail=" exStyleFail " passed=" passed)
}

; A persistent handle is kept open. Reopening the file on every line
; loses entries, and while the file is open for writing nothing else can
; read it, which makes diagnosing a live problem impossible.
; Each line is opened, written and closed again. A handle kept open for
; the lifetime of the script buffers the output, so a log that is being
; written to cannot be read and looks empty while a problem is live.
LogLine(msg) {
    global DebugOn, DebugPath

    if !DebugOn
        return

    line := A_Hour ":" A_Min ":" A_Sec " " msg "`n"
    try
        FileAppend(line, DebugPath, "UTF-8")
}

; The one log that writes in every build. Debug logging is verbose and
; correctly silent in release, which also makes a release failure
; invisible. Errors and correction failures go here as well as there,
; so a release can be asked what went wrong. Rotated when it grows past
; 128KB, because this file is allowed to exist for months.
LogAlways(msg) {
    global GuardLogPath, DebugOn

    line := A_Hour ":" A_Min ":" A_Sec " " msg "`n"
    try {
        if FileExist(GuardLogPath) && FileGetSize(GuardLogPath) > 131072 {
            try FileDelete(GuardLogPath . ".bak")
            try FileMove(GuardLogPath, GuardLogPath . ".bak", true)
        }
        FileAppend(line, GuardLogPath, "UTF-8")
    }
    if DebugOn
        LogLine(msg)
}

; A failure worth seeing in both logs with one call.
LogBoth(msg) {
    LogAlways(msg)
}

; Seeds a struct buffer with 32-bit integers.
;
; Win32 structs such as MONITORINFO, RECT and WINDOWPLACEMENT have to
; carry their own cbSize, and AHK v2 offers no way to write an integer
; into a Buffer: NumPut rejects a Buffer, and passing a variable
; address to DllCall turns every other variable in that same call into
; a VarRef, which then has no .Ptr.
;
; So the integers are laid out as a UTF-16 string, 2 chars per value,
; and a single RtlMoveMemory copies the whole thing. v2 strings are
; length-based, so the embedded NULs survive the trip.
PackInts(vals) {
    out := ""
    for v in vals
        out .= Chr(v & 0xFFFF) . Chr((v >> 16) & 0xFFFF)
    return out
}

; MONITORINFO is 40 bytes: cbSize, RECT rcMonitor, RECT rcWork, dwFlags.
; WINDOWPLACEMENT is 44 bytes: cbSize, flags, showCmd, 3 spare POINTs,
; then RECT rcNormalPosition at offset 28.
MONITORINFO_SIZE := 40
PLACEMENT_SIZE := 44

; This build of AHK v2 has no A_ScriptPID, and the id is needed to keep
; the manager from filtering out its own windows.
GetOwnPid() {
    global OwnPid
    if !OwnPid
        OwnPid := DllCall("GetCurrentProcessId", "UInt")
    return OwnPid
}

; Reads an extended window style. Only the "Ptr" return form is valid
; here: a "Long" return on this build raises "Invalid return type".
; True while this window is one we are actively placing, so the
; resulting events do not get mistaken for the user moving it. The
; window stays marked for a short while and the mark expires on its
; own, which keeps a missed clear from freezing the window forever.
IsMoving(hwnd) {
    global MovingWindows, MovingUntil

    if !MovingWindows.Has(hwnd)
        return false
    if !MovingUntil.Has(hwnd) {
        DropIfPresent(MovingWindows, hwnd)
        return false
    }
    if A_TickCount > MovingUntil[hwnd] {
        DropIfPresent(MovingWindows, hwnd)
        DropIfPresent(MovingUntil, hwnd)
        return false
    }
    return true
}

MarkMoving(hwnd) {
    global MovingWindows, MovingUntil
    MovingWindows[hwnd] := true
    MovingUntil[hwnd] := A_TickCount + 1200
}

; Map.Delete raises when the key is absent, which is easy to hit from a
; sweep that is working through windows another hook may have already
; cleaned up. DropIfPresent never throws.
DropIfPresent(m, key) {
    try {
        if m.Has(key)
            m.Delete(key)
    }
}

; Reads field n of an INI record as a number.
;
; The record mixes numbers with the "-" placeholder, so a blind
; conversion raises "Expected a Number but got a String" and takes the
; whole script down from inside a hook callback. Returns 0 when the
; field is missing or is not a number.
IniNum(p, n) {
    if (n > p.Length)
        return 0
    v := p[n]
    if !RegExMatch(v, "^-?\d+$")
        return 0
    return v + 0
}

; Reads the normal geometry from a stored record, if it has one.
; Returns "" when the record has no usable normal geometry.
;
; The record is exactly x|y|w|h|minmax|snap|nx|ny|nw|nh, so it has ten
; fields. Anything else is a record from an older layout and is not
; trusted: reading past the end would splice a snap name or a stray
; separator into the geometry.
ReadNormalGeom(p) {
    global MinSaveW, MinSaveH

    if (p.Length != 10)
        return ""
    nx := IniNum(p, 7), ny := IniNum(p, 8)
    nw := IniNum(p, 9), nh := IniNum(p, 10)
    if (nw < MinSaveW || nh < MinSaveH)
        return ""
    return nx "|" ny "|" nw "|" nh
}

GetWindowLongPtrSafe(hwnd, index := -20) {
    return DllCall("GetWindowLongPtrW", "Ptr", hwnd, "Int", index, "Ptr")
}

GetWindowRect(hwnd) {
    r := Buffer(16)
    if !DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", r.Ptr)
        return false
    x := NumGet(r, 0, "Int"), y := NumGet(r, 4, "Int")
    return {x: x, y: y, w: NumGet(r, 8, "Int") - x, h: NumGet(r, 12, "Int") - y}
}

; The pre-maximise geometry. The caller always keeps its own copy of
; the last known normal geometry, so a failure here only costs the
; first record for a window.
GetNormalRect(hwnd) {
    wp := Buffer(PLACEMENT_SIZE)
    DllCall("RtlMoveMemory", "Ptr", wp.Ptr, "Str", PackInts([PLACEMENT_SIZE]), "UPtr", 4)
    if !DllCall("GetWindowPlacement", "Ptr", hwnd, "Ptr", wp.Ptr)
        return false
    l := NumGet(wp, 28, "Int"), t := NumGet(wp, 32, "Int")
    r := NumGet(wp, 36, "Int"), b := NumGet(wp, 40, "Int")
    w := r - l, h := b - t
    if (w <= 0 || h <= 0)
        return false
    return {x: l, y: t, w: w, h: h}
}

; Writes the rectangle that SW_RESTORE will bring the window back to.
;
; A snapped window keeps a stale restore rectangle: the shell moved the
; window with SetWindowPos but never updated WINDOWPLACEMENT, so the
; pre-snap size is still there. Restoring a minimized snapped window
; with SW_RESTORE therefore comes back at the old size. Overwriting the
; placement with the geometry the window actually had makes the restore
; land where it should.
SetRestoreRect(hwnd, x, y, w, h) {
    wp := Buffer(PLACEMENT_SIZE)
    ; cbSize, flags, showCmd=SW_SHOWNORMAL(1), then the three spare
    ; POINTs, all zero.
    DllCall("RtlMoveMemory", "Ptr", wp.Ptr,
        "Str", PackInts([PLACEMENT_SIZE, 0, 1, 0, 0, 0, 0]), "UPtr", 28)
    ; rcNormalPosition lives at offset 28.
    DllCall("RtlMoveMemory", "Ptr", wp.Ptr + 28,
        "Str", PackInts([x, y, x + w, y + h]), "UPtr", 16)
    return DllCall("SetWindowPlacement", "Ptr", hwnd, "Ptr", wp.Ptr)
}

; -1 minimized, 1 maximized, 0 normal.
; IsIconic and IsZoomed answer this without any structure, which keeps
; the hot path free of the WINDOWPLACEMENT buffer entirely.
GetMinMax(hwnd) {
    if DllCall("IsIconic", "Ptr", hwnd)
        return -1
    if DllCall("IsZoomed", "Ptr", hwnd)
        return 1
    return 0
}

; MONITORINFO: cbSize(0) rcMonitor(4) rcWork(20) dwFlags(36)
GetWorkAreaForRect(x, y, w, h) {
    r := Buffer(16)
    DllCall("RtlMoveMemory", "Ptr", r.Ptr,
        "Str", PackInts([x, y, x + w, y + h]), "UPtr", 16)

    hMon := DllCall("MonitorFromRect", "Ptr", r.Ptr, "UInt", 2, "Ptr")
    if !hMon
        return false

    mi := Buffer(MONITORINFO_SIZE)
    DllCall("RtlMoveMemory", "Ptr", mi.Ptr,
        "Str", PackInts([MONITORINFO_SIZE]), "UPtr", 4)
    if !DllCall("GetMonitorInfoW", "Ptr", hMon, "Ptr", mi.Ptr)
        return false
    return {l: NumGet(mi, 20, "Int"), t: NumGet(mi, 24, "Int"),
            r: NumGet(mi, 28, "Int"), b: NumGet(mi, 32, "Int")}
}

AdjustRectToAvailableMonitors(&x, &y, &w, &h) {
    wa := GetWorkAreaForRect(x, y, w, h)
    if !IsObject(wa)
        return
    mw := wa.r - wa.l
    mh := wa.b - wa.t
    if (mw <= 0 || mh <= 0)
        return
    if (w > mw)
        w := mw
    if (h > mh)
        h := mh
    if (x < wa.l)
        x := wa.l
    if (y < wa.t)
        y := wa.t
    if (x + w > wa.r)
        x := wa.r - w
    if (y + h > wa.b)
        y := wa.b - h
}

; ============================================================
;  FancyZones
; ============================================================

; True when FancyZones has claimed this window for a zone.
;
; FancyZones records which zone each executable belongs to, keyed on the
; full image path, in app-zone-history.json. Windows snap and a FancyZones
; zone are different things: a window the user dragged into a zone is
; FancyZones business, and the manager must not pull it back to a
; remembered position or the two would fight over every placement.
;
; The history file is re-read when its timestamp changes, so a window
; zoned a moment ago is recognised without a restart.
IsFancyZoneWindow(hwnd) {
    global FZZoneApps, FZStamp, FZNextCheck, DebugOn

    if (FZStamp = "")
        FZNextCheck := 0

    ; The file is small and only changes when a window is zoned, so it is
    ; re-read on a slow cycle rather than for every window on every sweep.
    if (A_TickCount >= FZNextCheck) {
        FZNextCheck := A_TickCount + 5000
        ; PowerToys keeps this under the local profile, and this build has
        ; no A_LocalAppData, so it is reached from the roaming one.
        fz := A_AppData "\..\Local\Microsoft\PowerToys\FancyZones\app-zone-history.json"
        stamp := ReadZoneHistory(fz)
        if (stamp != FZStamp) {
            FZStamp := stamp
            if DebugOn
                LogLine("zone history stamp " stamp " with " FZZoneApps.Count " apps")
        }
    }

    if !FZZoneApps.Count
        return false

    owner := WinGetOwner(hwnd)
    return (owner.path != "" && FZZoneApps.Has(StrLower(owner.path)))
}

; Reads the zone history and returns a stamp that changes whenever the
; file does. The content itself is the stamp: this build has neither
; FormatFileTime nor a usable FileExist, and reading the file is what the
; code has to do anyway.
ReadZoneHistory(path) {
    global FZZoneApps

    FZZoneApps := Map()

    text := ""
    try {
        text := FileRead(path, "UTF-8")
    } catch {
        return "none"
    }

    ; The file is one long JSON object whose entries each carry an
    ; "app-path" field. Only the path matters here, so it is picked out
    ; textually rather than through a JSON parser the script does not have.
    pos := 1
    while RegExMatch(text, '"app-path"\s*:\s*"([^"]+)"', &m, pos) {
        p := StrReplace(m[1], "\\", "\")
        FZZoneApps[StrLower(p)] := true
        pos := m.Pos(0) + m.Len(0)
    }

    return StrLen(text) ":" FZZoneApps.Count
}

; ============================================================
;  Window identity
; ============================================================

WinGetClassName(hwnd) {
    c := Buffer(512)
    DllCall("GetClassNameW", "Ptr", hwnd, "Ptr", c.Ptr, "Int", 256)
    return StrGet(c)
}

; The owning process id, executable name and full image path for a window.
;
; Both DllCall routes failed here: DllCall with a "UInt*" output
; parameter left the value at 0 for every window, and
; QueryFullProcessImageNameW never ran because of it. AHK's own
; WinGet / ProcessGetName pair is used for the name, and the process id is
; taken through a Buffer so no DllCall output parameter is involved.
;
; The full path is needed to match the window against the FancyZones zone
; history, which keys on the image path rather than the file name.
;
; Returns {pid: n, name: s, path: s}. A missing process yields pid 0.
WinGetOwner(hwnd) {
    ; A fresh Buffer is already zeroed, which is exactly what
    ; GetWindowThreadProcessId needs for its output.
    pb := Buffer(4)
    DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt", pb.Ptr)
    pid := NumGet(pb, 0, "UInt")

    if !pid
        return {pid: 0, name: "", path: ""}

    name := ""
    path := ""
    try {
        name := ProcessGetName(pid)
        path := ProcessGetPath(pid)
    } catch {
        return {pid: pid, name: "", path: ""}
    }

    return {pid: pid, name: name, path: path}
}

WinGetProcName(hwnd) {
    return WinGetOwner(hwnd).name
}

GetWindowKey(hwnd) {
    global WindowSlot, WindowSlotNext

    proc := WinGetProcName(hwnd)
    cls  := WinGetClassName(hwnd)
    if (proc = "" || cls = "")
        return ""
    base := proc "|" cls

    ; A window keeps the slot it was first given for as long as it
    ; lives, so its record does not change underneath it because some
    ; other window of the same program opened or closed.
    if !WindowSlot.Has(hwnd) {
        n := WindowSlotNext.Has(base) ? WindowSlotNext[base] : 1
        WindowSlot[hwnd] := n
        WindowSlotNext[base] := n + 1
    }

    return base "|" WindowSlot[hwnd]
}

; Returns "" when the window is acceptable, otherwise a short reason.
; The reason is used for the debug log, so a window that is being
; skipped for a surprising reason can be identified.
WindowRejectReason(hwnd) {
    global SkipClasses, SkipProcs, WidgetClasses

    if !hwnd
        return "no hwnd"
    if !DllCall("IsWindow", "Ptr", hwnd)
        return "not a window"
    if !DllCall("IsWindowVisible", "Ptr", hwnd)
        return "hidden"

    cls := WinGetClassName(hwnd)
    if (cls = "")
        return "no class"
    if RegExMatch(cls, WidgetClasses)
        return "widget class"
    if RegExMatch(cls, SkipClasses)
        return "skip class"

    owner := WinGetOwner(hwnd)
    proc := owner.name
    if (proc = "")
        return "no process"
    if (proc = "explorer.exe" && cls != "CabinetWClass")
        return "explorer non-folder"
    ; Our own process must never be filtered out: the AutoHotkey
    ; pattern above is meant to skip other people's AHK scripts, but it
    ; would also match the manager itself. There is no A_ScriptPID in
    ; this build, so the id is read from the process itself.
    if (owner.pid != GetOwnPid() && RegExMatch(proc, SkipProcs))
        return "skip process"

    exStyle := GetWindowLongPtrSafe(hwnd)
    if exStyle & 0x00000080   ; WS_EX_TOOLWINDOW
        return "tool window"
    if exStyle & 0x00020000   ; WS_EX_NOREDIRECTIONBITMAP
        return "no redirection"
    return ""
}

IsUsableWindow(hwnd, idObject := 0, idChild := 0) {
    if (idObject != 0 || idChild != 0)
        return false
    return WindowRejectReason(hwnd) = ""
}

; ============================================================
;  INI helpers
; ============================================================

IniReadSafe(path, section, key) {
    try
        return IniRead(path, section, key)
    catch
        return ""
}

; ============================================================
;  Self-restoring app learning
; ============================================================

IsSelfRestoring(key) {
    global LearnPath
    return IniReadSafe(LearnPath, "Self", key) = "1"
}

MarkSelfRestoring(key) {
    global LearnPath
    try
        IniWrite(1, LearnPath, "Self", key)
}

UnmarkSelfRestoring(key) {
    global LearnPath
    try
        IniDelete(LearnPath, "Self", key)
}

ObserveSelfRestore(hwnd, key, placed) {
    global SeenAtCreate, PendingSelfCheck

    if !SeenAtCreate.Has(hwnd)
        return
    if IsSelfRestoring(key)
        return
    if (placed = "")
        return

    PendingSelfCheck := {hwnd: hwnd, key: key, placed: placed}
    SetTimer(CheckSelfRestore, -700)
}

CheckSelfRestore() {
    global SeenAtCreate, PendingSelfCheck

    if !IsObject(PendingSelfCheck)
        return
    req := PendingSelfCheck
    PendingSelfCheck := ""

    hwnd := req.hwnd
    key  := req.key

    if !DllCall("IsWindow", "Ptr", hwnd)
        return
    if !SeenAtCreate.Has(hwnd)
        return

    o := StrSplit(SeenAtCreate[hwnd], "|")
    p := StrSplit(req.placed, "|")
    if (o.Length < 4 || p.Length < 4)
        return

    ; The window has to actually be somewhere now for this to mean
    ; anything, and it must be back at where it was created even though
    ; it was just placed elsewhere. That is an app restoring its own
    ; geometry, and it will keep doing so.
    now := GetWindowRect(hwnd)
    if !IsObject(now)
        return
    if (GetMinMax(hwnd) != 0)
        return

    placedX := IniNum(p, 1), placedY := IniNum(p, 2)
    placedW := IniNum(p, 3), placedH := IniNum(p, 4)
    bornX   := IniNum(o, 1), bornY := IniNum(o, 2)

    weMovedIt := Abs(placedX - bornX) >= 4 || Abs(placedY - bornY) >= 4
    itWentHome := Abs(now.x - bornX) < 4 && Abs(now.y - bornY) < 4
        && Abs(now.w - IniNum(o, 3)) < 4 && Abs(now.h - IniNum(o, 4)) < 4

    if (weMovedIt && itWentHome) {
        MarkSelfRestoring(key)
        LogLine("self-restoring detected: " key " placed "
            placedX "," placedY " " placedW "x" placedH
            " but it returned to " now.x "," now.y)
    }
}

; Safety net for windows the event hooks never announce.
;
; A window is only interesting once: either it has a stored layout, in
; which case it is restored, or it does not, in which case there is
; nothing to do. Windows that are already tracked are skipped, so this
; stays cheap.
; An unhandled error inside a timer callback silently stops that timer
; in this build, so the sweep is wrapped and reports itself on every
; pass. Without this, a single failure looks exactly like "the feature
; never runs".
SweepTick() {
    global DebugOn, SettleUntil, BornAt
    try {
        Sweep()
        if DebugOn
            LogLine("sweep ok, tracked=" SeenAtCount()
                " settling=" SettleUntil.Count " new=" BornAt.Count)
    } catch as e {
        LogBoth("!! sweep failed: " e.Message " line " e.Line)
    }
}

SeenAtCount() {
    global SeenAtCreate
    return SeenAtCreate.Count
}

; The single place a window is walked.
;
; Minimise and restore, close and reopen, a monitor being unplugged and
; an app deciding on its own size all arrive here as the same thing: a
; window whose geometry no longer matches its record. There is one code
; path for all of them, and the record is the only thing that says what
; the geometry should be.
;
; Recording a new layout is deliberately not done here. That is the
; event hooks job, because only they can tell a deliberate move apart
; from a window being resized by something else. Saving here would let
; a transient size become the record, which is what makes the stored
; value drift.
Sweep() {
    global SeenAtCreate, DebugOn, MinSaveW, MinSaveH, BornAt, BornMs
    global GuardLast, GuardBaseline, GuardApp

    for hwnd in EnumTopWindows() {
        if !IsUsableWindow(hwnd)
            continue
        if IsMoving(hwnd)
            continue

        rect := GetWindowRect(hwnd)
        if !IsObject(rect)
            continue

        ; Keep the guardrail's record of where this window has actually
        ; been, so a baseline read from the shell can be sanity checked
        ; before anything is moved. A window that is down is not
        ; recorded, because its rectangle is the minimised stub, and a
        ; window with a baseline in hand is left alone until that
        ; baseline has been judged. The app key rides along so a cycle
        ; can be counted under its program without asking the owning
        ; process anything from inside an event.
        if GetMinMax(hwnd) != -1 && !GuardBaseline.Has(hwnd) {
            GuardLast[hwnd] := rect.x "|" rect.y "|" rect.w "|" rect.h
            GuardApp[hwnd] := WinGetProcName(hwnd) "|" WinGetClassName(hwnd)
        }

        ; The sweep feeds the mirror and nothing else. Judging was tried
        ; here and removed: 21 consecutive real-world cycles never needed
        ; it, and the minimise events carry every transition on time.

        ; A window is born at whatever default size it likes and reaches
        ; its real geometry a moment later. Until then there is nothing
        ; to record and nothing to compare.
        if !SeenAtCreate.Has(hwnd) {
            if (rect.w < MinSaveW || rect.h < MinSaveH)
                continue
            BornAt[hwnd] := A_TickCount
            SeenAtCreate[hwnd] := rect.x "|" rect.y "|" rect.w "|" rect.h
            if DebugOn
                LogLine("  seen hwnd=" hwnd " geom=" rect.x "," rect.y
                    " " rect.w "x" rect.h)
            continue
        }

        ; Give a window that has just started time to settle before its
        ; geometry is judged, so the default size is not mistaken for a
        ; position the user wants.
        if BornAt.Has(hwnd) {
            if (A_TickCount - BornAt[hwnd]) < BornMs
                continue
            DropIfPresent(BornAt, hwnd)
        }

        ; A window FancyZones has claimed is not ours to place. Its
        ; position is the zone, and it will be put back there itself.
        if IsFancyZoneWindow(hwnd) {
            if DebugOn
                LogLine("  zone-managed, leaving alone " hwnd)
            continue
        }

        Reconcile(hwnd, rect)
    }
}

; Brings one window back to its record, if it has drifted.
;
; Everything the window manager does to a window goes through here:
; the record is the intent, the current geometry is the reality, and a
; difference between them is corrected once and then left to settle.
Reconcile(hwnd, rect) {
    global IniPath, MinSaveW, MinSaveH, SettleUntil, SettleMs, DebugOn

    key := GetWindowKey(hwnd)
    if (key = "" || IsSelfRestoring(key))
        return false

    ; A window FancyZones has claimed belongs to a zone. Its position is
    ; the zone, not a remembered free position, so the manager leaves it
    ; entirely alone.
    if IsFancyZoneWindow(hwnd) {
        if DebugOn
            LogLine("  zone-managed, skipping " key)
        return false
    }

    value := IniReadSafe(IniPath, "Windows", key)
    if (value = "")
        return false
    p := StrSplit(value, "|")
    if (p.Length < 4)
        return false

    ; A minimised or maximised window is not ours to place: the shell and
    ; the app own its geometry until it comes back to normal.
    if GetMinMax(hwnd) != 0
        return false

    ; Still opening.
    if (rect.w < MinSaveW || rect.h < MinSaveH)
        return false

    tx := IniNum(p, 1), ty := IniNum(p, 2)
    tw := IniNum(p, 3), th := IniNum(p, 4)

    ; Where it already is.
    if Abs(rect.x - tx) <= 2 && Abs(rect.y - ty) <= 2
        && Abs(rect.w - tw) <= 2 && Abs(rect.h - th) <= 2 {
        DropIfPresent(SettleUntil, hwnd)
        return false
    }

    ; We corrected this one a moment ago and the app has not finished
    ; reacting. Going again now would just start the argument over.
    if SettleUntil.Has(hwnd) {
        if (A_TickCount - SettleUntil[hwnd]) < SettleMs
            return false
    }

    snap := (p.Length >= 6 && p[6] != "") ? p[6] : "-"
    ApplyPlacement(hwnd, key, tx, ty, tw, th, IniNum(p, 5), snap)
    SettleUntil[hwnd] := A_TickCount
    LogLine("reconciled " key " -> " tx "," ty " " tw "x" th
        " (was " rect.x "," rect.y " " rect.w "x" rect.h ")")
    return true
}

; The only code that moves a window.
;
; A snapped window also gets its restore rectangle rewritten, because
; SW_RESTORE otherwise hands it back the size it had before it was
; snapped, which is the whole reason a minimised snapped window comes
; back at the wrong size. The same rewrite is what stops a zone window
; drifting, so both callers come through here.
;
; observe is off for a zone window. An app putting its own size back
; after a zone correction is the thing being corrected, not an app
; restoring itself, and learning it as one would retire it from tracking.
ApplyPlacement(hwnd, key, tx, ty, tw, th, minMax, snap, observe := true) {
    global IniPath, LastSaved, DebugOn

    if minMax = 1 {
        ; Fields one to four are the maximised geometry, and the normal
        ; geometry is the four after the snap name, so the restore
        ; rectangle has to come from there before it is maximised.
        value := IniReadSafe(IniPath, "Windows", key)
        p := StrSplit(value, "|")
        if (p.Length >= 10) {
            SetRestoreRect(hwnd, IniNum(p,7), IniNum(p,8), IniNum(p,9), IniNum(p,10))
        } else {
            SetRestoreRect(hwnd, tx, ty, tw, th)
        }
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 3)   ; SW_MAXIMIZE
        return true
    }

    ; A window being corrected is minimised as often as not, and
    ; SetWindowPos on a minimised window is thrown away by the shell.
    if GetMinMax(hwnd) = -1
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)   ; SW_RESTORE

    MarkMoving(hwnd)
    ; SWP_NOZORDER(0x0004) | SWP_NOACTIVATE(0x0010)
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
        "Int", tx, "Int", ty, "Int", tw, "Int", th,
        "UInt", 0x0004 | 0x0010)
    SetRestoreRect(hwnd, tx, ty, tw, th)

    if minMax = -1 {
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 6)   ; SW_MINIMIZE
        return true
    }

    ; The record is not rewritten from what the window says afterwards.
    ; The app puts its own size straight back, and saving that would make
    ; the next cycle target the value the correction just removed, which
    ; is how a stored size ends up drifting.
    cur := GetWindowRect(hwnd)
    if IsObject(cur) && Abs(cur.w - tw) <= 2 && Abs(cur.h - th) <= 2 {
        keep := IniReadSafe(IniPath, "Windows", key)
        if (keep != "")
            LastSaved[key] := keep
    }

    if observe
        ObserveSelfRestore(hwnd, key, tx "|" ty "|" tw "|" th)

    if DebugOn
        LogLine("  placed " key " -> " tx "," ty " " tw "x" th)
    return true
}

; ============================================================
;  Mixed DPI risk
;
;  A Chromium window that comes back from minimise is sized by a
;  minimum track width that Chromium scales by the display scale it
;  works out from the window's position. A minimised window sits at
;  (-32000,-32000), which belongs to no display, so the scale is taken
;  from the display nearest that point, which is the leftmost one.
;
;  If that display is the higher scaled one, a window narrower than
;  500 * scale + 16 is pushed up to that floor on every restore, and a
;  window inside a zone sized below it is left wider than its zone.
;  Putting the lower scaled display leftmost makes the scale come out
;  right and the floor drop to the real minimum.
;
; This only reports. Nothing is corrected, because the fix belongs to
; the display arrangement rather than to a window manager.
;
; It warns once. The condition is about the display arrangement, not
; about any one window, and once the user has seen it the arrangement is
; usually already dealt with, so a warning on every single login is
; noise. Delete %APPDATA%\WpmSnapWarning.ack to see it again.
; ============================================================

CheckSnapFloorRisk() {
    global MonWins
    ack := A_AppData "\WpmSnapWarning.ack"
    if FileExist(ack)
        return
    try {
        ; Each monitor is measured through a window standing on it, which
        ; is the only route here that answers correctly. MonitorFromPoint
        ; comes back empty in this process, and both shcore dpi entry
        ; points report 96 for a 200% display, so neither is usable.
        MonWins := EnumTopWindows()

        leftDpi := 0, leftEdge := 0
        lowest := 0
        seen := Map()
        for h in MonWins {
            hMon := DllCall("MonitorFromWindow", "Ptr", h, "UInt", 2, "Ptr")
            if !hMon || seen.Has(hMon)
                continue
            seen[hMon] := true
            edge := MonitorLeftEdge(hMon)
            dpi := DllCall("GetDpiForWindow", "Ptr", h, "UInt")
            if !dpi
                continue
            if (!lowest || dpi < lowest)
                lowest := dpi
            if (!leftDpi || edge < leftEdge) {
                leftDpi := dpi
                leftEdge := edge
            }
        }
        if DebugOn
            LogLine("  snap floor check: " seen.Count " monitors, leftmost dpi="
                leftDpi " lowest dpi=" lowest)
        if (seen.Count < 2 || !leftDpi || !lowest)
            return
        if (leftDpi <= lowest)
            return

        TrayTip("Window Position Manager",
            "고배율 모니터가 가장 왼쪽입니다. 축소→복원 시 창이 zone 보다 커질 수 있습니다. 왼쪽 모니터를 100% 배율로 두거나, 해당 zone 폭을 1000px 이상으로 두면 해결됩니다.", 0)
        try
            FileAppend("", ack, "UTF-8")
    } catch as e {
        if DebugOn
            LogLine("  snap floor check failed: " e.Message " line " e.Line)
    }
}

MonWins := []

; Left edge of a monitor in virtual screen coordinates, which is what
; decides which display a minimised window at (-32000,-32000) is taken
; to belong to.
MonitorLeftEdge(hMon) {
    MI := Buffer(40)
    NumPut("Int", 40, MI, 0)
    if !DllCall("GetMonitorInfoW", "Ptr", hMon, "Ptr", MI.Ptr)
        return 0
    return NumGet(MI, 8, "Int")
}


ToggleFocusedApp() {
    hwnd := WinExist("A")
    if !hwnd
        return
    cls := WinGetClassName(hwnd)
    proc := WinGetProcName(hwnd)
    if (cls = "" || proc = "")
        return
    key := proc "|" cls
    if IsSelfRestoring(key) {
        UnmarkSelfRestoring(key)
        TrayTip("Window Position Manager", "추적 재개: " key, 1)
    } else {
        MarkSelfRestoring(key)
        TrayTip("Window Position Manager", "추적 제외: " key, 1)
    }
}

; ============================================================
;  Restore geometry guardrail
; ============================================================

; The geometry a window is currently at, as the string the ini uses.
GuardRectStr(rect) {
    return rect.x "|" rect.y "|" rect.w "|" rect.h
}

GuardParse(s) {
    p := StrSplit(s, "|")
    if (p.Length < 4)
        return false
    return {x: p[1], y: p[2], w: p[3], h: p[4]}
}

; All four coordinates. A window can come back the right width and the
; wrong height, or the right height and too wide, so none of them is
; optional.
GuardSame(a, b) {
    return Abs(a.x - b.x) <= GuardTolPx && Abs(a.y - b.y) <= GuardTolPx
        && Abs(a.w - b.w) <= GuardTolPx && Abs(a.h - b.h) <= GuardTolPx
}

; The rectangle the shell is holding for a window. This is not the
; window's own rectangle: a window that is minimised reports
; -32000,-32000 and a small stub, while this keeps the place it will
; come back to. cbSize has to be written into the structure or the call
; fills nothing at all and what comes back is whatever was in memory.
GetRestoreRect(hwnd) {
    global PLACEMENT_SIZE
    wp := Buffer(PLACEMENT_SIZE)
    NumPut("Int", PLACEMENT_SIZE, wp, 0)
    if !DllCall("GetWindowPlacement", "Ptr", hwnd, "Ptr", wp.Ptr)
        return false
    l := NumGet(wp, 28, "Int")
    t := NumGet(wp, 32, "Int")
    r := NumGet(wp, 36, "Int")
    b := NumGet(wp, 40, "Int")
    if (r <= l || b <= t)
        return false
    return {x: l, y: t, w: r - l, h: b - t}
}

; rcNormalPosition is written against the work area of the monitor the
; window was on, while a window rectangle is in screen coordinates. The
; two share an origin on an ordinary monitor with the taskbar along the
; bottom, and do not on one where it is at the top or the left, so the
; position is only used after being brought back to screen coordinates
; by the monitor's own origin.
BufferFromRect(r) {
    b := Buffer(16)
    NumPut("Int", r.x, b, 0)
    NumPut("Int", r.y, b, 4)
    NumPut("Int", r.x + r.w, b, 8)
    NumPut("Int", r.y + r.h, b, 12)
    return b
}

ScreenRectFromRestore(r) {
    global MONITORINFO_SIZE
    hMon := DllCall("MonitorFromRect", "Ptr", BufferFromRect(r).Ptr, "UInt", 2, "Ptr")
    if !hMon
        return r
    wa := GetWorkAreaForRect(r.x, r.y, r.w, r.h)
    if !IsObject(wa)
        return r
    mi := Buffer(MONITORINFO_SIZE)
    NumPut("Int", MONITORINFO_SIZE, mi, 0)
    if !DllCall("GetMonitorInfoW", "Ptr", hMon, "Ptr", mi.Ptr)
        return r
    ; The work area starts where the monitor does unless the taskbar is
    ; along the top or the left, in which case the work area is inset and
    ; that inset is what has to be added back.
    dx := NumGet(mi, 20, "Int") - wa.l
    dy := NumGet(mi, 24, "Int") - wa.t
    if (dx = 0 && dy = 0)
        return r
    return {x: r.x + dx, y: r.y + dy, w: r.w, h: r.h}
}

; The parts of IsUsableWindow that are safe to call from inside a
; window event. Everything here is a call on this handle alone: no
; owning process is looked up, and the class is read straight out of
; the window rather than through the shell.
GuardEventWindowUsable(hwnd, idObject, idChild) {
    global WidgetClasses, SkipClasses
    if (idObject != 0 || idChild != 0 || !hwnd)
        return false
    if !DllCall("IsWindow", "Ptr", hwnd)
        return false
    if !DllCall("IsWindowVisible", "Ptr", hwnd)
        return false

    sb := Buffer(256 * 2)
    if !DllCall("GetClassNameW", "Ptr", hwnd, "Ptr", sb.Ptr, "Int", 256)
        return false
    cls := StrGet(sb)
    if (cls = "" || RegExMatch(cls, WidgetClasses) || RegExMatch(cls, SkipClasses))
        return false

    return true
}

HandleMinimizeStart(hwnd, idObject, idChild) {
    global DebugOn
    if !GuardEventWindowUsable(hwnd, idObject, idChild)
        return
    if DebugOn
        LogLine("  MINSTART hwnd=" hwnd)
    GuardCapture(hwnd)
}

; EVENT_SYSTEM_MINIMIZEEND. The window is up by now, so this is the
; first moment its restored size can be read and judged.
HandleMinimizeEnd(hwnd, idObject, idChild) {
    global DebugOn
    if !GuardEventWindowUsable(hwnd, idObject, idChild)
        return
    if DebugOn
        LogLine("  MINEND hwnd=" hwnd)
    GuardRestore(hwnd)
}

GuardCapture(hwnd) {
    global GuardBaseline, GuardLast, GuardMaxTries, GuardTrustPx, GuardRetry
    global GuardApp, HasArranged, DebugOn

    base := GetRestoreRect(hwnd)
    if !base {
        if DebugOn
            LogLine("[Guardrail] no restore rectangle for hwnd=" hwnd)
        return false
    }
    base := ScreenRectFromRestore(base)
    plcSize := base.w "|" base.h

    ; The shell value is not always the truth. Minimising can make the
    ; app rewrite its own restore rectangle on the way down, so what is
    ; read here is where the app is about to claim it was rather than
    ; where it was seen. What was actually seen while the window was up
    ; wins over that whenever the two disagree on size.
    mirrorSize := "-"
    if GuardLast.Has(hwnd) {
        last := GuardParse(GuardLast[hwnd])
        if last {
            mirrorSize := last.w "|" last.h
            if (Abs(base.w - last.w) > GuardTrustPx || Abs(base.h - last.h) > GuardTrustPx) {
                if DebugOn
                    LogLine("[Guardrail] shell disagrees, trusting last seen hwnd=" hwnd
                        . " shell=" base.w "x" base.h
                        . " last=" last.w "x" last.h)
                base := {x: last.x, y: last.y, w: last.w, h: last.h}
            }
        }
    }

    ; A correction that did not take leaves one extra attempt behind.
    ; It is honoured only when the window has not moved since the
    ; failure: the shell and the mirror must both still read the size
    ; the window was stuck at. A resize by hand in between means one of
    ; them changed, and the flag is dropped instead of fought. Either
    ; way the flag is single use.
    if GuardRetry.Has(hwnd) {
        r := GuardRetry[hwnd]
        DropIfPresent(GuardRetry, hwnd)
        if (plcSize = r.stuck && mirrorSize != "-" && mirrorSize = r.stuck) {
            rb := GuardParse(r.want)
            if rb {
                base := rb
                if DebugOn
                    LogLine("[Guardrail] retrying last verified hwnd=" hwnd
                        . " rect=" GuardRectStr(base))
            }
        } else if DebugOn
            LogLine("[Guardrail] retry dropped, window moved hwnd=" hwnd
                . " stuck=" r.stuck . " plc=" plcSize . " mirror=" mirrorSize)
    }

    ; Stored as text: every reader below parses it back, and a string
    ; is the one form both the event path and the sweep path agree on.
    ; plc and mirror ride along so the restore can report the whole
    ; cycle on one line; app and arranged ride along so cycles can be
    ; counted per program and stratified without asking the owning
    ; process anything from inside an event.
    app := GuardApp.Has(hwnd) ? GuardApp[hwnd] : "?"
    app := StrReplace(app, "|", "/")
    arr := HasArranged ? (DllCall("IsWindowArranged", "Ptr", hwnd) ? 1 : 0) : -1
    GuardBaseline[hwnd] := {rect: GuardRectStr(base), tries: 0,
        plc: plcSize, mirror: mirrorSize, app: app, arr: arr}
    if DebugOn
        LogLine("[Guardrail] baseline captured hwnd=" hwnd
            . " rect=" GuardRectStr(base))
    return true
}

; One line per judged restore, carrying everything the real-world
; verdict needs: which program, whether it was arranged, what the shell
; said at the going down, what was last seen up, what actually came
; back, and what was decided. Entries made by the sweep path predate
; the extra fields, so each is read only when present.
GuardCycleLine(hwnd, entry, actual, decision) {
    global DebugOn
    ; Entries are plain objects, not Maps, so presence is asked with
    ; HasProp: .Has() does not exist on them.
    plc := HasProp(entry, "plc") ? entry.plc : "-"
    mirror := HasProp(entry, "mirror") ? entry.mirror : "-"
    app := HasProp(entry, "app") ? entry.app : "-"
    arr := HasProp(entry, "arr") ? entry.arr : -1
    if DebugOn
        LogLine("[Guardrail] cycle hwnd=" hwnd
            . " app=" app . " arr=" arr
            . " plc=" plc . " mirror=" mirror
            . " actual=" actual . " decision=" decision)
}

GuardRestore(hwnd) {
    global GuardBaseline, GuardLast, GuardMaxTries, GuardRetry, DebugOn

    if !GuardBaseline.Has(hwnd) {
        if DebugOn
            LogLine("[Guardrail] came back with no baseline hwnd=" hwnd)
        return false
    }

    ; Still down. A window can report the restore before the app has put
    ; it back, and moving a minimised window does nothing useful. The
    ; baseline is kept, because the restore has not happened yet.
    if GetMinMax(hwnd) = -1 {
        if DebugOn
            LogLine("[Guardrail] reported back but still minimised hwnd=" hwnd)
        return false
    }

    entry := GuardBaseline[hwnd]
    want := IsObject(entry.rect) ? entry.rect : GuardParse(entry.rect)
    if !want {
        DropIfPresent(GuardBaseline, hwnd)
        return false
    }
    if DebugOn
        LogLine("[Guardrail] restore detected hwnd=" hwnd)

    ; A window that was maximised while it was down has no size of its
    ; own to hold it to: the shell owns it while it is up.
    if (GetMinMax(hwnd) = 1) {
        DropIfPresent(GuardBaseline, hwnd)
        return false
    }

    rect := GetWindowRect(hwnd)
    if !IsObject(rect) {
        DropIfPresent(GuardBaseline, hwnd)
        return false
    }

    if GuardSame(rect, want) {
        if DebugOn
            LogLine("[Guardrail] geometry match hwnd=" hwnd
                . " rect=" GuardRectStr(rect))
        GuardCycleLine(hwnd, entry, GuardRectStr(rect), "match")
        DropIfPresent(GuardBaseline, hwnd)
        GuardLast[hwnd] := GuardRectStr(rect)
        return false
    }

    if (entry.tries >= GuardMaxTries) {
        LogBoth("[Guardrail] giving up hwnd=" hwnd
            . " baseline=" GuardRectStr(want)
            . " actual=" GuardRectStr(rect))
        GuardCycleLine(hwnd, entry, GuardRectStr(rect), "gave-up")
        DropIfPresent(GuardBaseline, hwnd)
        GuardLast[hwnd] := GuardRectStr(rect)
        return false
    }

    if DebugOn
        LogLine("[Guardrail] geometry mismatch hwnd=" hwnd
            . " baseline=" GuardRectStr(want)
            . " actual=" GuardRectStr(rect))

    ; The same placement path the rest of this uses, so the move, the
    ; restore rectangle and the suppression of our own events all behave
    ; the way they do everywhere else. observe is off: a window putting
    ; its own size back after this is the thing being corrected, not an
    ; app that restores itself, and learning it as one would retire it.
    ApplyPlacement(hwnd, GetWindowKey(hwnd), want.x, want.y, want.w, want.h,
        0, "-", false)
    entry.tries += 1

    ; A SetWindowPos that returns is not a correction that took. Read the
    ; rectangle again and only call it done if the window agrees. A
    ; correction that did not take leaves the mirror alone, so the next
    ; cycle compares against where the window really is rather than
    ; against where it was supposed to be.
    after := GetWindowRect(hwnd)
    if !IsObject(after) || !GuardSame(after, want) {
        ; The window did not take the correction. Leave one extra attempt
        ; behind, honoured only if the window is still sitting where the
        ; failure left it, and say so where the release build can hear it.
        GuardRetry[hwnd] := {want: GuardRectStr(want),
            stuck: IsObject(after) ? after.w "|" after.h : "?"}
        LogBoth("[Guardrail] correction NOT verified hwnd=" hwnd
            . " wanted=" GuardRectStr(want)
            . " got=" (IsObject(after) ? GuardRectStr(after) : "?"))
        GuardCycleLine(hwnd, entry,
            IsObject(after) ? GuardRectStr(after) : "?", "not-verified")
        DropIfPresent(GuardBaseline, hwnd)
        return false
    }

    ; No settling wait is done here. This runs inside a window event and
    ; sleeping would hold up the thread the shell delivers them on, which
    ; is the very restore being handled.
    if DebugOn
        LogLine("[Guardrail] correction verified hwnd=" hwnd
            . " rect=" GuardRectStr(after))
    ; The cycle reports what came back before the correction, not after:
    ; otherwise a fixed drift reads the same as no drift at all.
    GuardCycleLine(hwnd, entry, GuardRectStr(rect), "corrected")

    DropIfPresent(GuardBaseline, hwnd)
    GuardLast[hwnd] := GuardRectStr(after)
    return true
}



SnapNear(a, b, tol := 0.06) {
    return Abs(a - b) < tol
}

DetectSnap(rect, wa) {
    if !IsObject(rect) || !IsObject(wa)
        return ""
    ww := wa.r - wa.l
    wh := wa.b - wa.t
    if (ww <= 0 || wh <= 0)
        return ""

    fx := (rect.x - wa.l) / ww
    fy := (rect.y - wa.t) / wh
    fw := rect.w / ww
    fh := rect.h / wh
    tol := SnapTol

    if (SnapNear(fy, 0, tol) && SnapNear(fh, 1, tol)) {
        if (SnapNear(fx, 0, tol) && SnapNear(fw, 0.5, tol))
            return "L"
        if (SnapNear(fx, 0.5, tol) && SnapNear(fw, 0.5, tol))
            return "R"
    }
    if (SnapNear(fx, 0, tol) && SnapNear(fw, 1, tol)) {
        if (SnapNear(fy, 0, tol) && SnapNear(fh, 0.5, tol))
            return "T"
        if (SnapNear(fy, 0.5, tol) && SnapNear(fh, 0.5, tol))
            return "B"
    }

    if (SnapNear(fw, 0.5, tol) && SnapNear(fh, 0.5, tol)) {
        if (SnapNear(fx, 0, tol) && SnapNear(fy, 0, tol))
            return "Q:TL"
        if (SnapNear(fx, 0.5, tol) && SnapNear(fy, 0, tol))
            return "Q:TR"
        if (SnapNear(fx, 0, tol) && SnapNear(fy, 0.5, tol))
            return "Q:BL"
        if (SnapNear(fx, 0.5, tol) && SnapNear(fy, 0.5, tol))
            return "Q:BR"
    }

    g := 0.012
    if (SnapNear(fh, 1, tol)) {
        if (fx <= g && SnapNear(fw, 0.3333, tol))
            return "T3:L"
        if (SnapNear(fx, 0.3333, tol) && SnapNear(fw, 0.3333, tol))
            return "T3:C"
        if (SnapNear(fx, 0.6667, tol) && SnapNear(fw, 0.3333, tol))
            return "T3:R"
    }
    if (SnapNear(fw, 1, tol)) {
        if (fy <= g && SnapNear(fh, 0.3333, tol))
            return "T3:T"
        if (SnapNear(fy, 0.3333, tol) && SnapNear(fh, 0.3333, tol))
            return "T3:M"
        if (SnapNear(fy, 0.6667, tol) && SnapNear(fh, 0.3333, tol))
            return "T3:B"
    }
    return ""
}

ApplySnap(kind, wa) {
    ww := wa.r - wa.l
    wh := wa.b - wa.t
    hw := Round(ww * 0.5)
    hh := Round(wh * 0.5)
    x := wa.l, y := wa.t, w := ww, h := wh

    if (kind = "L") {
        w := hw
    } else if (kind = "R") {
        x := wa.l + hw
        w := ww - hw
    } else if (kind = "T") {
        h := hh
    } else if (kind = "B") {
        y := wa.t + hh
        h := wh - hh
    } else if (kind = "Q:TL") {
        w := hw, h := hh
    } else if (kind = "Q:TR") {
        x := wa.l + hw
        w := hw, h := hh
    } else if (kind = "Q:BL") {
        y := wa.t + hh
        w := hw, h := hh
    } else if (kind = "Q:BR") {
        x := wa.l + hw
        y := wa.t + hh
        w := hw, h := hh
    } else if (kind = "T3:L") {
        w := Round(ww / 3)
    } else if (kind = "T3:C") {
        w := Round(ww / 3)
        x := wa.l + w + Round(ww * 0.012)
    } else if (kind = "T3:R") {
        w := Round(ww / 3)
        x := wa.r - w
    } else if (kind = "T3:T") {
        h := Round(wh / 3)
    } else if (kind = "T3:M") {
        h := Round(wh / 3)
        y := wa.t + h + Round(wh * 0.012)
    } else if (kind = "T3:B") {
        h := Round(wh / 3)
        y := wa.b - h
    } else {
        return false
    }
    return {x: x, y: y, w: w, h: h}
}

; ============================================================
;  Save
; ============================================================

SaveWindowPos(hwnd) {
    global IniPath, LastSaved, MinSaveW, MinSaveH, DebugOn, BornAt, SeenAtCreate

    if DebugOn
        LogLine("  SaveWindowPos hwnd=" hwnd)

    ; A window that has not been seen by the sweep yet, or is still
    ; inside its opening grace period, is not being placed by anyone. It
    ; is arriving at whatever size and position the app decided on, and
    ; writing that down replaces the record before the restore has had a
    ; chance to use it, which is why a relaunch came back at the app
    ; default instead of where it was left.
    if !SeenAtCreate.Has(hwnd) || BornAt.Has(hwnd) {
        if DebugOn
            LogLine("    -> still opening, not recorded")
        return false
    }

    if !IsUsableWindow(hwnd) {
        if DebugOn
            LogLine("    -> rejected by IsUsableWindow: " WindowRejectReason(hwnd))
        return false
    }

    minMax := GetMinMax(hwnd)
    if (minMax = -1) {
        if DebugOn
            LogLine("    -> minimized")
        return false
    }

    key := GetWindowKey(hwnd)
    if (key = "") {
        if DebugOn
            LogLine("    -> empty key")
        return false
    }
    if IsSelfRestoring(key)
        return false

    ; A zoned window is not recorded either. Its geometry is the zone
    ; layout, and writing that into the record would make the manager try
    ; to restore the zone when FancyZones no longer has one.
    if IsFancyZoneWindow(hwnd) {
        if DebugOn
            LogLine("    -> zone-managed, not recorded: " key)
        return false
    }

    snap := "-"
    nx := "", ny := "", nw := "", nh := ""

    prevVal := LastSaved.Has(key) ? LastSaved[key]
                                      : IniReadSafe(IniPath, "Windows", key)

    ; The layout name that was already on record, so a snap that is being
    ; kept can be told apart from one that has just appeared.
    prevSnap := "-"
    pv := StrSplit(prevVal, "|")
    if (pv.Length >= 6 && pv[6] != "")
        prevSnap := pv[6]

    if (minMax = 1) {
        ; The record is x|y|w|h|minmax|snap|nx|ny|nw|nh, so the normal
        ; geometry is fields 7 to 10 and the snap name is field 6. Field
        ; 5 is the show state and field 6 may be "-", so neither can be
        ; read as a number.
        p := StrSplit(prevVal, "|")
        ; IniWrite drops an empty value, which would collapse the record
        ; and shift every later field, so a missing snap name is put
        ; back as the "-" placeholder.
        if (p.Length >= 6 && p[6] != "")
            snap := p[6]

        g := ReadNormalGeom(p)
        if (g != "") {
            q := StrSplit(g, "|")
            nx := q[1], ny := q[2], nw := q[3], nh := q[4]
        }

        if (nx = "") {
            nr := GetNormalRect(hwnd)
            if !IsObject(nr) || nr.w < MinSaveW || nr.h < MinSaveH
                return false
            nx := nr.x, ny := nr.y, nw := nr.w, nh := nr.h
        }
        state := nx "|" ny "|" nw "|" nh "|1|" snap "|" nx "|" ny "|" nw "|" nh
    } else {
        rect := GetWindowRect(hwnd)
        if !IsObject(rect) {
            if DebugOn
                LogLine("    -> GetWindowRect failed")
            return false
        }
        if (rect.w < MinSaveW || rect.h < MinSaveH) {
            if DebugOn
                LogLine("    -> too small " rect.w "x" rect.h)
            return false
        }

        wa := GetWorkAreaForRect(rect.x, rect.y, rect.w, rect.h)
        if IsObject(wa) {
            s := DetectSnap(rect, wa)
            if (s != "")
                snap := s
        }

        ; While a snap is held, the size comes from the snap rather than
        ; from what the app happens to be showing right now. An app that
        ; draws its own frame reports a slightly different size for the
        ; same layout on every minimize cycle, and letting that through
        ; turns a correction into a drift.
        ;
        ; A layout that has just appeared has nothing to inherit, so the
        ; geometry is taken as measured and stored. Only a snap that was
        ; already recorded keeps its size.
        if (snap != "-" && prevSnap = snap) {
            sp := StrSplit(prevVal, "|")
            g2 := ReadNormalGeom(sp)
            if (g2 != "") {
                q := StrSplit(g2, "|")
                if (Abs(q[3] - rect.w) <= 64 && Abs(q[4] - rect.h) <= 64) {
                    nx := q[1], ny := q[2], nw := q[3], nh := q[4]
                }
            }
        }

        if (nx = "")
            nx := rect.x, ny := rect.y, nw := rect.w, nh := rect.h

        sx := nw
        sy := nh
        state := rect.x "|" rect.y "|" sx "|" sy "|0|" snap "|" nx "|" ny "|" nw "|" nh
    }

    if (LastSaved.Has(key) && LastSaved[key] = state) {
        if DebugOn
            LogLine("    -> duplicate, not rewritten")
        return false
    }

    try
        IniWrite(state, IniPath, "Windows", key)
    catch as e {
        LogLine("write failed: " key " " e.Message)
        return false
    }
    LastSaved[key] := state
    LogLine("saved " key " = " state)
    return true
}

; ============================================================
;  Restore
; ============================================================

; Re-applies a placement once the app has finished reacting to it.
;
; After SW_RESTORE a snapped window comes back at its stale size and the
; app resizes itself again, which is what makes the size drift on every
; minimize cycle. Forcing the geometry a short time later stops that.
; If the window has since been minimised, maximised or moved by the user
; the correction is skipped, since then it is no longer ours to set.

; The snap engine sizes a window by its outer frame, while GetWindowRect
; also reports the outer frame. The two agree, but a window that reserves
; its own space (Chrome and most toolkits) is never the exact fraction
; DetectSnap looks for, so a layout gets detected from a near miss and
; then re-imposed at the exact fraction on every restore. That makes the
; window jump between two sizes forever.
;
; The fix is to trust the recorded geometry when the window is already at
; it. A frame-sized difference is not a user move, and re-imposing the
; stored number over it is what starts the fight with the app. Only a
; clearly larger difference counts as a real move.
SnapMatchesRecord(cur, tx, ty, tw, th) {
    return Abs(cur.w - tw) <= 2 && Abs(cur.h - th) <= 2
}


; Kept for the event hooks, which want to place a window the moment it
; shows up rather than waiting for the next sweep. The work is the same.
RestoreWindow(hwnd) {
    global IniPath, MinSaveW, MinSaveH

    if !IsUsableWindow(hwnd)
        return false

    ; A zoned window must never be restored from a record. The record
    ; would be a leftover from before the window was zoned, and putting
    ; it back would drag the window out of the zone.
    if IsFancyZoneWindow(hwnd)
        return false

    key := GetWindowKey(hwnd)
    if (key = "" || IsSelfRestoring(key))
        return false

    value := IniReadSafe(IniPath, "Windows", key)
    if (value = "")
        return false
    p := StrSplit(value, "|")
    if (p.Length < 4)
        return false

    if (IniNum(p, 3) < MinSaveW || IniNum(p, 4) < MinSaveH)
        return false

    snap := (p.Length >= 6 && p[6] != "") ? p[6] : "-"
    ApplyPlacement(hwnd, key, IniNum(p, 1), IniNum(p, 2),
        IniNum(p, 3), IniNum(p, 4), IniNum(p, 5), snap)
    return true
}

; ============================================================
;  Shell hook
; ============================================================

; AHK v2 always passes four arguments to an OnMessage callback:
; MsgNumber, WParam, LParam, MsgData. v1 used two, and v2 rejects that
; with "Invalid callback function".
ShellMessage(msg, wParam, lParam, msgData) {
    global SeenAtCreate, DebugOn

    if (wParam != 1)      ; HSHELL_WINDOWCREATED
        return
    hwnd := lParam
    if !hwnd
        return

    ; Recorded so the self restore learner has the geometry the window
    ; was born with. Placing it is the sweep job.
    if !SeenAtCreate.Has(hwnd) && IsUsableWindow(hwnd) {
        rect := GetWindowRect(hwnd)
        if IsObject(rect)
            SeenAtCreate[hwnd] := rect.x "|" rect.y "|" rect.w "|" rect.h
    }
}

; ============================================================
;  WinEvent callbacks
; ============================================================

WinEventMoveStart(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    ; Registered for completeness. A user drag is recognised by the
    ; absence of a settle window, not by this event, so nothing is
    ; marked here.
    return
}

; EVENT_OBJECT_MOVEEND is not delivered on this platform, verified with a
; standalone probe: a LOCATION hook sees hundreds of events during a drag
; while a MOVEEND hook on the same window sees none. The registration is
; kept in case a build does deliver it, and it only does work that
; HandleLocation would have done anyway.
; WinEvent LONGs arrive 64 bits wide with garbage above bit 32: a child
; of zero has been seen as 4294967296, which silently fails every
; idObject/idChild filter downstream. Shifting down through 32 bits
; drops the garbage while keeping the sign, so a negative LONG such as
; OBJID_CARET (-8) stays negative instead of becoming a large positive
; the way a plain mask would leave it. Verified against 0, 5, -8,
; 0xFFFFFFFF and 0x100000000.
NormWinEventId(v) {
    return (v << 32) >> 32
}

WinEventMoveEnd(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    idObject := NormWinEventId(idObject)
    idChild := NormWinEventId(idChild)
    if (idObject != 0 || idChild != 0 || !hwnd)
        return
    if !IsUsableWindow(hwnd, idObject, idChild)
        return
    HandleLocation(hwnd, idObject, idChild)
}

WinEventLocation(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    ; An error inside a hook callback kills the script, so the whole body
    ; is guarded and the failure is reported instead.
    idObject := NormWinEventId(idObject)
    idChild := NormWinEventId(idChild)
    try HandleLocation(hwnd, idObject, idChild)
    catch as e
        LogBoth("!! LOCATION hwnd=" hwnd " failed: " e.Message " line " e.Line)
}

HandleLocation(hwnd, idObject, idChild) {
    global EventCount, DebugOn, SettleUntil, SettleMs

    if (idObject != 0 || idChild != 0 || !hwnd)
        return

    ; the first few real events prove the hook is live
    if (DebugOn && EventCount < 6) {
        EventCount += 1
        LogLine("  evt #" EventCount " LOCATION hwnd=" hwnd
            " obj=" idObject " child=" idChild)
    }

    if !IsUsableWindow(hwnd, idObject, idChild) {
        if (DebugOn && !IsMoving(hwnd))
            LogLine("  LOCATION hwnd=" hwnd " rejected: "
                WindowRejectReason(hwnd) " cls=" WinGetClassName(hwnd))
        return
    }

    ; Placing a window raises location events of our own, and an app
    ; reacts to the placement by resizing itself, which raises more.
    ; Recording any of those would make a transient size the record,
    ; which is how the stored value drifts. A window we have just
    ; placed is therefore left alone until it has settled.
    if SettleUntil.Has(hwnd) {
        if (A_TickCount - SettleUntil[hwnd]) < SettleMs
            return
    }

    SaveWindowPos(hwnd)
}

; A window can raise LOCATION while it is still hidden and then never
; raise another one, which is how most apps come up. This is the event
; that actually means "now handle it", so the full check runs here.
WinEventShow(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    idObject := NormWinEventId(idObject)
    idChild := NormWinEventId(idChild)
    try HandleShow(hwnd, idObject, idChild)
    catch as e
        LogBoth("!! SHOW hwnd=" hwnd " failed: " e.Message " line " e.Line)
}

WinEventMinimizeStart(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    idObject := NormWinEventId(idObject)
    idChild := NormWinEventId(idChild)
    try HandleMinimizeStart(hwnd, idObject, idChild)
    catch as e
        LogBoth("!! MINSTART hwnd=" hwnd " failed: " e.Message " line " e.Line)
}

WinEventMinimizeEnd(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    idObject := NormWinEventId(idObject)
    idChild := NormWinEventId(idChild)
    try HandleMinimizeEnd(hwnd, idObject, idChild)
    catch as e
        LogBoth("!! MINEND hwnd=" hwnd " failed: " e.Message " line " e.Line)
}

HandleShow(hwnd, idObject, idChild) {
    ; A window is normally created at a small default size and reaches
    ; its real geometry a moment later, so there is nothing useful to do
    ; with this event other than let the sweep notice the window.
    return
}

WinEventDestroy(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    global MovingWindows, SeenAtCreate, MovingUntil, TinyAtCreate
    global SettleUntil, BornAt, GuardBaseline, GuardLast, WindowSlot
    global GuardRetry, GuardApp

    ; Without this a destroy carrying garbage above bit 32 skips the
    ; cleanup below, leaking the slot and letting a recycled handle
    ; inherit a stale baseline.
    idObject := NormWinEventId(idObject)
    idChild := NormWinEventId(idChild)
    if (idObject != 0 || idChild != 0)
        return
    DropIfPresent(MovingWindows, hwnd)
    DropIfPresent(MovingUntil, hwnd)
    DropIfPresent(TinyAtCreate, hwnd)
    DropIfPresent(SettleUntil, hwnd)
    DropIfPresent(BornAt, hwnd)
    DropIfPresent(SeenAtCreate, hwnd)
    ; A window that is gone has no restore cycle left to finish, and a
    ; recycled handle must not inherit a rectangle from whoever had it
    ; before.
    DropIfPresent(GuardBaseline, hwnd)
    DropIfPresent(GuardLast, hwnd)
    DropIfPresent(GuardRetry, hwnd)
    DropIfPresent(GuardApp, hwnd)
    ; The slot goes back so the next window of this program and class can
    ; take it. Without that, closing and reopening one Explorer window
    ; would hand out a new slot every time and the record would be left
    ; behind under a number nothing will ever look up again.
    DropIfPresent(WindowSlot, hwnd)
    ; The learned zone rectangles are keyed on the app, not on the
    ; window, so there is nothing per window to drop for them.
}

; ============================================================
;  DPI
; ============================================================

; The PerMonitorV2 manifest compiled into the exe does the real work.
; These calls only matter if that ever fails, and every entry point is
; resolved explicitly so a missing export cannot abort the script.
; There is no GetModuleHandle entry point in this build, so the module
; is fetched with GetModuleHandleW. Without this the process stays
; DPI-unaware and every physical coordinate it reads is scaled, which
; makes windows come out at twice the requested size.
DpiInit() {
    hUser32 := DllCall("GetModuleHandleW", "Str", "user32.dll", "Ptr")
    if !hUser32
        hUser32 := DllCall("LoadLibraryW", "Str", "user32.dll", "Ptr")
    if !hUser32
        return false

    p := DllCall("GetProcAddress", "Ptr", hUser32, "AStr", "SetProcessDpiAwarenessContext", "Ptr")
    if p {
        ; PER_MONITOR_AWARE_V2 is (DPI_AWARENESS_CONTEXT)(-4)
        if DllCall(p, "Ptr", -4)
            return true
    }

    hShcore := DllCall("LoadLibraryW", "Str", "Shcore.dll", "Ptr")
    if hShcore {
        fn := DllCall("GetProcAddress", "Ptr", hShcore, "AStr", "SetProcessDpiAwareness", "Ptr")
        if fn {
            hr := DllCall(fn, "Int", 2)   ; PROCESS_PER_MONITOR_DPI_AWARE
            if (hr = 0)
                return true
        }
    }

    p2 := DllCall("GetProcAddress", "Ptr", hUser32, "AStr", "SetProcessDPIAware", "Ptr")
    if p2
        return DllCall(p2)
    return false
}

; ============================================================
;  Cleanup
; ============================================================

Cleanup(exitReason := "", exitCode := 0) {
    global hMoveStartHook, hMoveEndHook, hLocationHook, hDestroyHook, hShowHook
    global MoveStartProc, MoveEndProc, LocationProc, DestroyProc, ShowProc
    global ShellRegistered, EnumProcRef

    if EnumProcRef {
        DllCall("GlobalFree", "Ptr", EnumProcRef)
        EnumProcRef := 0
    }
    if hMoveStartHook
        DllCall("UnhookWinEvent", "Ptr", hMoveStartHook)
    if hMoveEndHook
        DllCall("UnhookWinEvent", "Ptr", hMoveEndHook)
    if hLocationHook
        DllCall("UnhookWinEvent", "Ptr", hLocationHook)
    if hDestroyHook
        DllCall("UnhookWinEvent", "Ptr", hDestroyHook)
    if hShowHook
        DllCall("UnhookWinEvent", "Ptr", hShowHook)
    if hMinStartHook
        DllCall("UnhookWinEvent", "Ptr", hMinStartHook)
    if hMinEndHook
        DllCall("UnhookWinEvent", "Ptr", hMinEndHook)
    if ShellRegistered {
        DllCall("DeregisterShellHookWindow", "Ptr", A_ScriptHwnd)
        ShellRegistered := false
    }
    if MoveStartProc
        DllCall("GlobalFree", "Ptr", MoveStartProc)
    if MoveEndProc
        DllCall("GlobalFree", "Ptr", MoveEndProc)
    if LocationProc
        DllCall("GlobalFree", "Ptr", LocationProc)
    if DestroyProc
        DllCall("GlobalFree", "Ptr", DestroyProc)
    if ShowProc
        DllCall("GlobalFree", "Ptr", ShowProc)
    if MinStartProc
        DllCall("GlobalFree", "Ptr", MinStartProc)
    if MinEndProc
        DllCall("GlobalFree", "Ptr", MinEndProc)
}

; ============================================================
;  Hotkeys - after the auto-execute section on purpose.
;  Win+E is not defined here: "Open Downloads.ahk" already owns it.
; ============================================================

^!w::ToggleFocusedApp()
