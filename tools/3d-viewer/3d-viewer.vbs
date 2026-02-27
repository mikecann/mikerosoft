Dim sFile, sDir, oShell

sFile = WScript.Arguments(0)
sDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\") - 1)

Set oShell = CreateObject("WScript.Shell")
oShell.Environment("Process")("GLB_FILE") = sFile
oShell.CurrentDirectory = sDir

oShell.Run "bun start", 0, False
