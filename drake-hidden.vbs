' Runs drake.ps1 with no window. Put a shortcut to this file in shell:startup to auto-start at login.
CreateObject("WScript.Shell").Run "powershell -NoProfile -ExecutionPolicy Bypass -File """ & CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\drake.ps1""", 0, False
