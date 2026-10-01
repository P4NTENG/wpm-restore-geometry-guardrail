#Requires AutoHotkey v2.0
#SingleInstance Force

; Diagnostic only. Logs every system minimise event with no filtering, so
; a missing MINIMIZESTART cannot be blamed on anything in the manager.
;
; The loop at the end is what keeps the process alive. Without something
; pending, this script finishes and takes the hook down with it, and the
; events then have nowhere to go.

LogPath := A_Temp "\evtdiag.log"

OnEvt(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    global LogPath
    name := event = 0x16 ? "MINSTART" : (event = 0x17 ? "MINEND" : Format("0x{:X}", event))
    FileAppend(A_TickCount " " name " hwnd=" hwnd " obj=" idObject " child=" idChild "`n", LogPath)
}

cb := CallbackCreate(OnEvt, "", 7)
hk := DllCall("SetWinEventHook", "UInt", 0x16, "UInt", 0x17,
    "Ptr", 0, "Ptr", cb, "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")

FileAppend("=== up, hook=" (hk ? "ok" : "NULL") " ===`n", LogPath)

Loop {
    Sleep 250
}
