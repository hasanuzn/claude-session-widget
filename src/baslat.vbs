' Claude Oturum Widget'ini konsol penceresi acmadan baslatir.
' Verilen bagimsiz degiskenler (or. -OpenSettings) betige aktarilir.
Dim fso, dir, args, i
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
args = ""
For i = 0 To WScript.Arguments.Count - 1
  args = args & " " & WScript.Arguments(i)
Next
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & dir & "\oturum-widget.ps1""" & args, 0, False
