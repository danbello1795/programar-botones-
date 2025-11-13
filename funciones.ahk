; Para AutoHotkey v2
holdTime := 200 ; milisegundos

XButton1::{
    start := A_TickCount
    while GetKeyState("XButton1", "P")
        Sleep(10)
    duration := A_TickCount - start
    if (duration >= holdTime) {
        Send('!{Left}')   ; Alt + Left (Regresar página)
    } else {
        Send('^c')        ; Ctrl + C
    }
}

XButton2::{
    start := A_TickCount
    while GetKeyState("XButton2", "P")
        Sleep(10)
    duration := A_TickCount - start
    if (duration >= holdTime) {
        Send('!{Right}')   ; Alt + Right (Avanzar página)
    } else {
        Send('^v')         ; Ctrl + V
    }
}
