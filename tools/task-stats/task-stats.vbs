Set objShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
exePath = objShell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\task-stats\task-stats.exe"

If Not fso.FileExists(exePath) Then
    MsgBox "task-stats has not been built yet." & vbCrLf & vbCrLf & _
           "Please run build.bat first:" & vbCrLf & vbCrLf & _
           "  " & scriptDir & "\build.bat", vbExclamation, "task-stats -- not built"
    WScript.Quit 1
End If

objShell.Run """" & exePath & """ """ & scriptDir & """", 0, False
