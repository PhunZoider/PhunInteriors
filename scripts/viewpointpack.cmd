@echo off
setlocal enabledelayedexpansion

rem ---------------------------------------------------------------------------
rem Rebuild the Project Viewpoint model pack in media\viewpoint\.
rem
rem   viewpointpack.cmd            shell walls 3 levels tall, black
rem   viewpointpack.cmd 1          or as many levels as you like
rem   viewpointpack.cmd --debug    floor red, walls green. Never ship it.
rem
rem perl ships with Git but only Git Bash puts it on PATH; a VS Code task or a
rem shortcut gets the Windows one, which is why this wrapper exists at all --
rem calling `perl` straight from a task fails with "not recognized".
rem ---------------------------------------------------------------------------

rem This file lives in scripts\; the perl below runs from the repo root.
pushd "%~dp0.."

set PERL=
for /f "delims=" %%P in ('where perl 2^>nul') do if not defined PERL set PERL=%%P
if not defined PERL if exist "%ProgramFiles%\Git\usr\bin\perl.exe" set PERL=%ProgramFiles%\Git\usr\bin\perl.exe
if not defined PERL if exist "%ProgramFiles(x86)%\Git\usr\bin\perl.exe" set PERL=%ProgramFiles(x86)%\Git\usr\bin\perl.exe
if not defined PERL if exist "%LOCALAPPDATA%\Programs\Git\usr\bin\perl.exe" set PERL=%LOCALAPPDATA%\Programs\Git\usr\bin\perl.exe

if not defined PERL (
    echo [viewpointpack] *** perl not found -- nothing done ***
    echo [viewpointpack] looked on PATH and in Git's usr\bin under Program Files
    popd & exit /b 1
)

"!PERL!" scripts\viewpointpack.pl %*
set RC=%errorlevel%
popd
exit /b %RC%
