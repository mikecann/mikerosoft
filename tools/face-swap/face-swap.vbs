Dim sPath, sDir, oShell, fso
Dim repoRoot, envFilePath, envStream, envLine, eqPos, envKey, envVal

' Accept optional image or folder path
If WScript.Arguments.Count > 0 Then
    sPath = WScript.Arguments(0)
Else
    sPath = ""
End If

sDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\") - 1)

Set oShell = CreateObject("WScript.Shell")
Set fso    = CreateObject("Scripting.FileSystemObject")

' Repo root is two levels up from tools\face-swap\
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

' Determine whether the argument is an image file or a folder
If sPath <> "" Then
    If fso.FileExists(sPath) Then
        oShell.Environment("Process")("TARGET_IMAGE") = sPath
        oShell.Environment("Process")("FOLDER_PATH") = fso.GetParentFolderName(sPath)
    ElseIf fso.FolderExists(sPath) Then
        oShell.Environment("Process")("FOLDER_PATH") = sPath
    End If
End If

oShell.Environment("Process")("TOOL_DIR") = sDir
oShell.CurrentDirectory = sDir

' On first run (no build output yet) do a full build first, then launch.
' On subsequent runs skip the build so the window opens immediately.
Dim buildDir
buildDir = sDir & "\build"
If Not fso.FolderExists(buildDir) Then
    oShell.Run "cmd /c cd /d """ & sDir & """ && bun run build:dev", 1, True
End If
oShell.Run "bun run dev", 0, False
