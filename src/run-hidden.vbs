' Launch a wallpaper-skin script with no console window at all.
'
' Why this exists: starting the skin with
'   powershell.exe -WindowStyle Hidden -File ensure.ps1
' from Task Scheduler or from the Startup shortcut makes Windows create the console
' window FIRST and hide it afterwards, so a terminal window flashes on screen every
' two minutes (task) and once per logon (shortcut). wscript.exe is a GUI-subsystem host
' with no console of its own, and Run(..., 0, ...) puts SW_HIDE into the child's
' STARTUPINFO, so a console is never shown in the first place.
'
' Usage:  wscript.exe //nologo run-hidden.vbs [script.ps1] [-ExtraArgs...] [-Wait]
'         Default script is ensure.ps1 next to this file.
'         -Wait runs it synchronously (the caller waits, still hidden).
'
' Kept ASCII on purpose: Windows Script Host reads .vbs with the ANSI code page unless
' the file carries a Unicode BOM.
Option Explicit
Dim sh, fso, scriptPath, extra, i, wait, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If WScript.Arguments.Count > 0 Then
  scriptPath = WScript.Arguments(0)
Else
  scriptPath = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\ChatGptWallpaperSkin\ensure.ps1"
End If

extra = ""
wait = False
For i = 1 To WScript.Arguments.Count - 1
  If LCase(WScript.Arguments(i)) = "-wait" Then
    wait = True
  Else
    extra = extra & " " & WScript.Arguments(i)
  End If
Next

If Not fso.FileExists(scriptPath) Then
  WScript.Quit 2
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """" & extra
sh.Run cmd, 0, wait
