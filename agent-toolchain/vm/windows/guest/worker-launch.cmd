@echo off
rem =====================================================================
rem AgentWorker Windows guest launcher
rem
rem Started by the `AgentWorker` scheduled task, which runs as `Docker` in
rem the interactive session (UAC is disabled in this image and Docker is an
rem Administrator, so this process already holds a full High-IL admin token
rem - jobs therefore need no UAC/elevation dance at all).
rem
rem Responsibilities:
rem   1. fetch the pod-provided WORKER_TOKEN from http://host.lan:8090/token
rem   2. fetch the current agent-worker.exe from http://host.lan:8090/worker
rem      (boot-fetch: a worker upgrade is an image change, not a golden change),
rem      falling back to the copy baked into the guest disk
rem   3. start agent-worker.exe as the current (docker) user
rem =====================================================================
setlocal enabledelayedexpansion

set "WROOT=C:\Users\Docker"
set "BIN=%WROOT%\agent-worker.exe"
set "DL=%WROOT%\agent-worker.dl.exe"
set "WS=%WROOT%\ws"
set "LOG=%WS%\agent-worker.log"

if not exist "%WS%" mkdir "%WS%"

rem --- 1. token (pre-authorization). Empty -> normal claim flow. --------
set "WORKER_TOKEN="
set /a N=0
:try
for /f "usebackq delims=" %%i in (`curl.exe -s -m 2 http://host.lan:8090/token 2^>nul`) do set "WORKER_TOKEN=%%i"
if defined WORKER_TOKEN goto have
set /a N+=1
if !N! lss 10 (ping -n 2 127.0.0.1 >nul & goto try)

:have
rem --- 2. boot-fetch the worker binary (best effort; keep the disk copy) --
>>"%LOG%" echo [%DATE% %TIME%] launcher: fetching worker from host.lan:8090/worker
del "%DL%" >nul 2>&1
curl.exe -s -m 30 -o "%DL%" http://host.lan:8090/worker 2>>"%LOG%"
for %%A in ("%DL%") do set "DLSZ=%%~zA"
if defined DLSZ if !DLSZ! GTR 1000000 (
  rem Replace the baked binary; if it is locked, run the download instead.
  move /y "%DL%" "%BIN%" >nul 2>&1 && (echo [%DATE% %TIME%] launcher: worker refreshed >nul) || set "BIN=%DL%"
)

rem --- 3. run the worker in this (docker) session -----------------------
>>"%LOG%" echo [%DATE% %TIME%] launcher: starting worker as %USERNAME% (%BIN%)
"%BIN%" -addr 0.0.0.0:48080 -workspace "%WS%" -db "%WS%\jobs.db" >>"%LOG%" 2>&1

endlocal
