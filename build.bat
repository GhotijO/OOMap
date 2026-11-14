@echo off
setlocal
where odin >nul 2>nul
if errorlevel 1 (
    echo [build] 找不到 odin，请把 Odin 加入 PATH
    exit /b 1
)
if not exist bin mkdir bin
if not exist lib\libz3.dll echo [build] warning: lib\libz3.dll missing, run scripts\fetch_z3.ps1
odin build src -out:bin\OOMap.exe
if errorlevel 1 exit /b 1
if exist lib\*.dll copy /y lib\*.dll bin\ >nul
echo [build] 完成：bin\OOMap.exe
endlocal
