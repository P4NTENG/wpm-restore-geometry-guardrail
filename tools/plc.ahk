#Requires AutoHotkey v2.0
#SingleInstance Force

LogPath := A_Temp "\plc.log"

; NumGet is the read path the manager itself uses; Buffer.ReadInt and
; DllCall("Number") are not available in this build.
; rcNormalPosition lives at offset 28 of WINDOWPLACEMENT.
NormalRect(hwnd) {
    buf := Buffer(44)
    if !DllCall("GetWindowPlacement", "Ptr", hwnd, "Ptr", buf.Ptr)
        return "FAIL"
    l := NumGet(buf, 28, "Int"), t := NumGet(buf, 32, "Int")
    r := NumGet(buf, 36, "Int"), b := NumGet(buf, 40, "Int")
    return l "," t " " (r - l) "x" (b - t)
}

WinRect(hwnd) {
    buf := Buffer(16)
    if !DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", buf.Ptr)
        return "FAIL"
    l := NumGet(buf, 0, "Int"), t := NumGet(buf, 4, "Int")
    r := NumGet(buf, 8, "Int"), b := NumGet(buf, 12, "Int")
    return l "," t " " (r - l) "x" (b - t)
}

Report(tag, hwnd) {
    global LogPath
    ic := DllCall("IsIconic", "Ptr", hwnd) ? "iconic" : "normal"
    FileAppend(A_TickCount " " tag "  " ic "  win=" WinRect(hwnd) "  normal=" NormalRect(hwnd) "`n", LogPath)
}

OnEvt(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    if (event = 0x16) {
        Report("MINSTART", hwnd)
    } else if (event = 0x17) {
        Report("MINEND  ", hwnd)
        SetTimer(() => Report("END+300", hwnd), -300)
        SetTimer(() => Report("END+800", hwnd), -800)
    }
}

cb := CallbackCreate(OnEvt, "", 7)
hk := DllCall("SetWinEventHook", "UInt", 0x16, "UInt", 0x17, "Ptr", 0, "Ptr", cb, "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")
FileAppend("=== up hook=" (hk ? "ok" : "NULL") " ===`n", LogPath)

Loop {
    Sleep 200
}
