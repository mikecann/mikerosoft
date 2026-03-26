Dim sFolder, sDir, oShell

sFolder = WScript.Arguments(0)
sDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\") - 1)

Set oShell = CreateObject("WScript.Shell")
oShell.Environment("Process")("FOLDER_PATH") = sFolder
oShell.CurrentDirectory = sDir

oShell.Run "bun start", 0, False
