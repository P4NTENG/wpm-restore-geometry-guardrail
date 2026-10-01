#Requires AutoHotkey v2.0
#SingleInstance Force

; Raw log for the minimise/restore of one window, one line per moment.
;
; Three mistakes from the earlier attempts are corrected here:
;   - WINDOWPLACEMENT needs its own size in the first field, so the
;     buffer is written before the call. A zero filled buffer left the
;     call filling nothing, and the numbers that came back were read out
;     of memory rather than out of the window.
;   - Values are bracketed before being joined to text. A constant
;     written straight onto a call is parsed as part of the argument
;     list and the script dies on the spot.
;   - Every piece of state a callback and a timer share is declared
;     global, so an assignment in one is visible to the other.

P := A_Temp "\raw3.log"
try FileDelete(P)

; ---------------------------------------------------------------- reads

ReadField(buf, index) {
    return (NumGet(buf, index * 4, "Int"))
}

; WINDOWPLACEMENT: cbSize 0, flags 1, showCmd 2, ptMinPosition 3,
; ptMaxPosition 5, rcNormalPosition 7.
Placement(hwnd) {
    buf := Buffer(44)
    NumPut("Int", 44, buf, 0)
    if !DllCall("GetWindowPlacement", "Ptr", hwnd, "Ptr", buf.Ptr)
        return "FAIL"
    return "show=" (ReadField(buf, 2))
        . " minPos=" (ReadField(buf, 3)) "," (ReadField(buf, 4))
        . " norm=" (ReadField(buf, 7)) "," (ReadField(buf, 8))
        . " " (ReadField(buf, 9) - ReadField(buf, 7)) "x" (ReadField(buf, 10) - ReadField(buf, 8))
}

WinRect(hwnd) {
    buf := Buffer(16)
    if !DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", buf.Ptr)
        return "FAIL"
    l := (NumGet(buf, 0, "Int"))
    t := (NumGet(buf, 4, "Int"))
    r := (NumGet(buf, 8, "Int"))
    b := (NumGet(buf, 12, "Int"))
    return l "," t " " (r - l) "x" (b - t)
}

State(hwnd) {
    ic := (DllCall("IsIconic", "Ptr", hwnd) ? "1" : "0")
    zm := (DllCall("IsZoomed", "Ptr", hwnd) ? "1" : "0")
    at := (DllCall("IsWindowArranged", "Ptr", hwnd) ? "1" : "0")
    return "iconic=" ic " zoom=" zm " arranged=" at
}

Line(tag, hwnd, evTime) {
    global P
    FileAppend((A_TickCount) " | " (tag)
        . " | ev=" (evTime)
        . " | " (State(hwnd))
        . " | win=" (WinRect(hwnd))
        . " | " (Placement(hwnd))
        . "`n", P)
}

; ---------------------------------------------------------------- watch

; Started at MINIMIZEEND and sampled until the window is up and has
; stopped moving. A MINIMIZESTART cancels it, so a fast round trip
; cannot leave a watch running against a window on its way down.
gHwnd    := 0
gUpAt    := 0
gRect    := ""
gStable  := 0
gElapsed := 0
gSamples := 0

gWatch(*) {
    global gHwnd, gUpAt, gRect, gStable, gElapsed, gSamples, P
    hwnd := gHwnd
    if !hwnd || !DllCall("IsWindow", "Ptr", hwnd)
        return SetTimer(gWatch, 0)

    gElapsed := gElapsed + 25
    gSamples := gSamples + 1

    if DllCall("IsIconic", "Ptr", hwnd) {
        if gElapsed >= 500
            SetTimer(gWatch, 0)
        return
    }

    rect := WinRect(hwnd)
    if !gUpAt {
        gUpAt := A_TickCount
        gRect := rect
        gStable := A_TickCount
        return
    }
    if rect != gRect {
        gRect := rect
        gStable := A_TickCount
    }
    if (A_TickCount - gStable) >= 100 || gElapsed >= 500 {
        FileAppend((A_TickCount) " | SETTLED"
            . " | upAfterMs=" (gUpAt - gHwndUp)
            . " | stableMs=" (A_TickCount - gStable)
            . " | samples=" (gSamples)
            . " | win=" (gRect)
            . "`n", P)
        SetTimer(gWatch, 0)
    }
}

; Kept separately so the report can say how long the window was down.
gHwndUp := 0

; ---------------------------------------------------------------- events

OnEvt(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    global gHwnd, gUpAt, gRect, gStable, gElapsed, gSamples, gHwndUp
    if (event = 0x16) {
        Line("MINSTART", hwnd, dwmsEventTime)
        ; Cancel any watch still going from the previous cycle, and take
        ; the restore rectangle the shell is holding for this window.
        ; It is read here because at this moment the window is already
        ; down and its own rectangle is the minimised stub.
        SetTimer(gWatch, 0)
        gHwnd := hwnd
        gHwndUp := A_TickCount
    } else if (event = 0x17) {
        Line("MINEND  ", hwnd, dwmsEventTime)
        gUpAt := 0
        gRect := ""
        gStable := 0
        gElapsed := 0
        gSamples := 0
        SetTimer(gWatch, -25)
    }
}

cb := CallbackCreate(OnEvt, "", 7)
hk := DllCall("SetWinEventHook", "UInt", 0x16, "UInt", 0x17,
    "Ptr", 0, "Ptr", cb, "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")
FileAppend("=== raw3 up, hook=" (hk ? "ok" : "NULL") " ===`n", P)

while true
    Sleep 200
