Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = scriptDir & "\color-picker.ps1"

args = ""
waitForExit = False
For Each arg In WScript.Arguments
    args = args & " " & QuoteArg(arg)
    If LCase(arg) = "-selftest" Or LCase(arg) = "-smoketest" Then
        waitForExit = True
    End If
Next

command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """" & args
exitCode = shell.Run(command, 0, waitForExit)

If waitForExit Then
    WScript.Quit exitCode
End If

Function QuoteArg(value)
    QuoteArg = """" & Replace(value, """", """""") & """"
End Function
