@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>nul

rem This launcher runs the POSIX script with Git for Windows' bash.exe.
rem Keep both files in the same folder.

set "HERE=%~dp0"
set "SCRIPT=%HERE%setup-portable.sh"

if not exist "%SCRIPT%" (
    echo [error] setup-portable.sh was not found next to this .bat file.
    pause
    exit /b 1
)

set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"

if not exist "%BASH%" (
    for /f "delims=" %%I in ('where bash 2^>nul') do (
        set "BASH=%%I"
        goto :found
    )
)

:found
if not exist "%BASH%" (
    echo [error] Git Bash was not found.
    echo Install Git for Windows: https://git-scm.com/download/win
    pause
    exit /b 1
)

pushd "%HERE%"
"%BASH%" "./setup-portable.sh" %*
set "RC=%ERRORLEVEL%"
popd

if not "%RC%"=="0" pause
exit /b %RC%
