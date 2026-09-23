@echo off
rem Bake the agent-worker launcher + scheduled task + firewall rule into a fresh
rem Windows guest. Dropped into the installer's /oem folder (dockur runs
rem C:\OEM\install.bat during setup).
setlocal
set "W=C:\Users\Docker"
set "LOG=C:\OEM\install.log"
echo === agent-worker bake %DATE% %TIME% === > "%LOG%"

rem Wait for the Docker profile to exist.
for /l %%i in (1,1,60) do if exist "%W%" goto have
ping -n 3 127.0.0.1 >nul
:have
if not exist "%W%\ws" mkdir "%W%\ws"

copy /y "C:\OEM\worker-launch.cmd" "%W%\worker-launch.cmd" >> "%LOG%" 2>&1
copy /y "C:\OEM\ewelevate.cmd"     "%W%\ewelevate.cmd"     >> "%LOG%" 2>&1
copy /y "C:\OEM\agent-worker.exe"  "%W%\agent-worker.exe"  >> "%LOG%" 2>&1

rem Pre-authorize the worker in Windows Firewall (no allow-dialog at first run).
netsh advfirewall firewall delete rule name="AgentWorker" >> "%LOG%" 2>&1
netsh advfirewall firewall add rule name="AgentWorker" dir=in action=allow program="%W%\agent-worker.exe" protocol=tcp localport=48080 >> "%LOG%" 2>&1

rem Register the AgentWorker task: Docker user, HIGHEST, interactive, at logon.
schtasks /delete /tn AgentWorker /f >> "%LOG%" 2>&1
schtasks /create /tn AgentWorker /tr "cmd /c %W%\worker-launch.cmd" /sc onlogon /ru Docker /rp admin /rl HIGHEST /it /f >> "%LOG%" 2>&1

echo === done %DATE% %TIME% === >> "%LOG%"
endlocal
