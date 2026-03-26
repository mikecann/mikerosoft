Dim sFolder, sDir, oShell, fso
Dim repoRoot, envFilePath, envStream, envLine, eqPos, envKey, envVal

sFolder = WScript.Arguments(0)
sDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\") - 1)

Set oShell = CreateObject("WScript.Shell")
Set fso    = CreateObject("Scripting.FileSystemObject")

' Repo root is two levels up from tools\img-gen\
repoRoot = Left(sDir, InStrRev(sDir, "\") - 1)  ' -> tools\
repoRoot = Left(repoRoot, InStrRev(repoRoot, "\") - 1)  ' -> repo root

' Load every key=value from .env into the process environment
envFilePath = repoRoot & "\.env"
If fso.FileExists(envFilePath) Then
    Set envStream = fso.OpenTextFile(envFilePath, 1)
    Do While Not envStream.AtEndOfStream
        envLine = Trim(envStream.ReadLine())
        If Len(envLine) > 0 And Left(envLine, 1) <> "#" Then
            eqPos = InStr(envLine, "=")
            If eqPos > 0 Then
                envKey = Trim(Left(envLine, eqPos - 1))
                envVal = Trim(Mid(envLine, eqPos + 1))
                If (Left(envVal, 1) = """" And Right(envVal, 1) = """") Or _
                   (Left(envVal, 1) = "'" And Right(envVal, 1) = "'") Then
                    envVal = Mid(envVal, 2, Len(envVal) - 2)
                End If
                oShell.Environment("Process")(envKey) = envVal
            End If
        End If
    Loop
    envStream.Close
End If

oShell.Environment("Process")("FOLDER_PATH") = sFolder
oShell.CurrentDirectory = sDir

oShell.Run "bun start", 0, False
