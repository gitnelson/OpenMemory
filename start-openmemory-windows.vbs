' Starts native-Windows OpenMemory (127.0.0.1:8081) with no console window.
' Registered as the "OpenMemory" at-logon task (Task Scheduler). Config: C:\Users\corey\OpenMemory\.env
' Log: C:\Users\corey\OpenMemory\data\server.log
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "C:\Users\corey\OpenMemory\backend"
' Outer quotes around the whole command: cmd /c strips the first and last quote when a line has several quoted parts.
sh.Run "cmd /c """"C:\Program Files\nodejs\node.exe"" dist\server\index.js >> ""C:\Users\corey\OpenMemory\data\server.log"" 2>&1""", 0, False
