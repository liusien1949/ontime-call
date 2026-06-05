Dim fso, baseDir, ps1Path

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = fso.BuildPath(baseDir, "meal-reminder.ps1")

If Not fso.FileExists(ps1Path) Then
	MsgBox "找不到启动脚本：" & vbCrLf & ps1Path & vbCrLf & vbCrLf & "请确认文件未被移动或删除。", vbCritical, "饭点提醒"
	WScript.Quit 1
End If

shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & ps1Path & """", 0, False
