@echo off
setlocal enabledelayedexpansion

rem ---------------------------------------------------------------------------
rem Normalise the border lot rects in the WorldEd project.
rem
rem RUN THIS BETWEEN SAVING IN WORLDED AND EXPORTING THE LOTS. WorldEd rewrites
rem every border lot rect to the building plus one each time it saves a cell,
rem and that extra square blanks the neighbouring cell's first fence wall --
rem one new gap per cell you touched. `map.cmd` runs the same script, but only
rem after the export, where it can repair the project for next time and tell
rem you the lotpacks it just copied are stale.
rem
rem   tighten.cmd                  the project beside %PI_MAPSRC%
rem   tighten.cmd <dir or .pzw>    a different project
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
    echo [tighten] *** perl not found -- nothing done ***
    echo [tighten] looked on PATH and in Git's usr\bin under Program Files
    popd & exit /b 1
)

"!PERL!" scripts\tighten.pl %*
set RC=%errorlevel%
popd
exit /b %RC%
