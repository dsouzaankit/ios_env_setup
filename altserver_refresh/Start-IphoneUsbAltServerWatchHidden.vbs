' Launch Watch-IphoneUsbAltServer.ps1 with no console and wait so the
' scheduled task stays Running until the watcher exits.
' Task Scheduler Interactive + pwsh.exe always creates a window; WMI Create
' with ShowWindow=0 does not. WScript.Shell Run wait can return while pwsh lives.
' Args: <pwsh.exe> <Watch-IphoneUsbAltServer.ps1> [extra Watch args...]
Option Explicit
Const SW_HIDE = 0

If WScript.Arguments.Count < 2 Then
  WScript.Quit 1
End If

Dim pwsh, script, extra, i, cmd, work, slash, wmi, startup, proc, pid, errCode, running
pwsh = WScript.Arguments(0)
script = WScript.Arguments(1)
extra = ""
For i = 2 To WScript.Arguments.Count - 1
  extra = extra & " " & WScript.Arguments(i)
Next
cmd = """" & pwsh & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """" & extra
slash = InStrRev(script, "\")
If slash > 0 Then
  work = Left(script, slash - 1)
Else
  work = "."
End If

Set wmi = GetObject("winmgmts:\\.\root\cimv2")
Set startup = wmi.Get("Win32_ProcessStartup").SpawnInstance_
startup.ShowWindow = SW_HIDE
Set proc = wmi.Get("Win32_Process")
pid = 0
errCode = proc.Create(cmd, work, startup, pid)
If errCode <> 0 Or pid = 0 Then
  WScript.Quit 1
End If

Do
  WScript.Sleep 1000
  Set running = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE ProcessId=" & pid)
  If running.Count = 0 Then Exit Do
Loop
