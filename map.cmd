@echo off
setlocal enabledelayedexpansion

rem ---------------------------------------------------------------------------
rem PhunInteriors map iteration: export -> repo -> check -> deploy -> reset.
rem   setx PI_TESTSAVE "Sandbox\2026-09-21_05-51-06"
rem   map.cmd                      sync, check, deploy, reset %PI_TESTSAVE%
rem   map.cmd Sandbox\maptest      same, resetting that save instead
rem   map.cmd -                    sync, check, deploy; reset nothing
rem
rem   PI_MAPSRC    the editor's lots folder, e.g. D:\pz-dev\maps\pi5\lots
rem   PI_TESTSAVE  a save under %USERPROFILE%\Zomboid\Saves, e.g.
rem                Sandbox\maptest, or an absolute path to one
rem
rem Quit the world to the main menu first. #The game writes every loaded chunk
rem back to the save on the way out, so a reset done mid-game is overwritten.
rem The game itself can stay running: lotpacks load lazily per cell, and only
rem a rebuilt .pack needs a restart.
rem
rem RUN `perl Docs\tighten.pl` BEFORE EXPORTING, after any WorldEd session.
rem WorldEd rewrites each border lot rect to the building plus one every time it
rem saves a cell, and that extra square blanks the neighbouring cell's first
rem fence wall -- one new gap per cell you touched. This script runs tighten
rem too, but by then the lotpacks are already written, so it can only repair
rem the project for the next export and tell you this one is stale.
rem ---------------------------------------------------------------------------

set SRC=%~dp0
set MAPS=%SRC%Contents\mods\PhunInteriors\common\media\maps\phuninteriors
pushd "%SRC%"

rem --- Sync ------------------------------------------------------------------
rem Copy, never mirror. map.info lives only in the repo -- the editor does not
rem export one, and a map without it never loads -- so /MIR would delete it.
rem The flip side: a cell dropped from the export stays here until removed.
if not defined PI_MAPSRC (
    echo [map] PI_MAPSRC not set, skipping sync
) else if not exist "%PI_MAPSRC%\*.lotheader" (
    echo [map] no lotheaders in %PI_MAPSRC%, skipping sync
) else (
    robocopy "%PI_MAPSRC%" "%MAPS%" /XF map.info /NJH /NJS /NDL /NP
    if errorlevel 8 (
        echo [map] FAILED copying from %PI_MAPSRC%
        popd & exit /b 1
    )
)

rem --- Check -----------------------------------------------------------------
rem A mismatch warns rather than stops: mid-rework the map legitimately moves
rem ahead of defaults.lua, and seeing it in game is the point of deploying.
rem perl ships with Git but only Git Bash puts it on PATH; a VS Code task or a
rem shortcut gets the Windows one.
set PERL=
for /f "delims=" %%P in ('where perl 2^>nul') do if not defined PERL set PERL=%%P
if not defined PERL if exist "%ProgramFiles%\Git\usr\bin\perl.exe" set PERL=%ProgramFiles%\Git\usr\bin\perl.exe
if not defined HOME set HOME=%USERPROFILE%
if not defined PERL (
    echo [map] *** perl not found, roomcheck NOT run ***
) else (
    "!PERL!" Docs\roomcheck.pl
    if errorlevel 1 echo [map] *** roomcheck FAILED -- the registry does not match this map ***

    rem The border fence, read out of the lotpacks that just landed. A gap here
    rem is a hole a zombie walks through, and it is invisible from the editor.
    "!PERL!" Docs\fencecheck.pl >nul 2>&1
    if errorlevel 1 (
        echo [map] *** fencecheck FAILED -- gaps in the border fence ***
        "!PERL!" Docs\fencecheck.pl 2>nul | findstr /C:"gaps" /C:"cell " /C:"WallNW"
    )

    rem WorldEd rewrites every border lot rect to the building PLUS ONE on save,
    rem and that extra square blanks the neighbouring cell's first wall. Nothing
    rem in the buildings can cover it, so the rect has to be normalised.
    rem
    rem This runs AFTER the export, so it cannot save the one you just made --
    rem it repairs the project for the NEXT export, and a non-zero exit is the
    rem news that the lotpacks just copied were built from spilled rects.
    rem Re-export and run map.cmd again when it fires.
    "!PERL!" Docs\tighten.pl --detect
    if errorlevel 2 echo [map] *** lot rects were spilled -- THIS export is stale, re-export and re-run ***
)

rem --- Deploy ----------------------------------------------------------------
call "%SRC%deploy.cmd"

rem --- Reset -----------------------------------------------------------------
set SAVE=%~1
if not defined SAVE set SAVE=%PI_TESTSAVE%
if "%SAVE%"=="-" set SAVE=
if not defined SAVE (
    echo [map] no test save named, skipping reset
    popd & exit /b 0
)
if not exist "%SAVE%\map_ver.bin" set SAVE=%USERPROFILE%\Zomboid\Saves\%SAVE%
if not exist "%SAVE%\map_ver.bin" (
    echo [map] %SAVE% is not a save, refusing to delete anything in it
    popd & exit /b 1
)

rem Cells come from the lotheaders, so a cell added to the map is reset too.
for %%H in ("%MAPS%\*.lotheader") do set CELL_%%~nH=1

set N=0
for %%H in ("%MAPS%\*.lotheader") do (
    for %%F in (
        "%SAVE%\chunkdata\chunkdata_%%~nH.bin"
        "%SAVE%\metagrid\metacell_%%~nH.bin"
        "%SAVE%\apop\apop_%%~nH.bin"
        "%SAVE%\zpop\zpop_%%~nH.bin"
    ) do if exist %%F del /Q %%F & set /a N+=1
)

rem map\<chunkX>\<chunkY>.bin. A cell is 32 chunks (256 squares of 8).
if exist "%SAVE%\map" for /D %%D in ("%SAVE%\map\*") do (
    set /a CX=%%~nxD / 32
    for %%F in ("%%D\*.bin") do (
        set /a CY=%%~nF / 32
        if defined CELL_!CX!_!CY! del /Q "%%F" & set /a N+=1
    )
)

rem isoregiondata\datachunk_<chunkX>_<chunkY>.bin, the same chunk space as
rem map\ but flat rather than a directory per column. Left behind, the engine
rem keeps the room and region data it derived from the OLD chunk, so a room
rem whose shape changed in the editor comes back with its old regions -- which
rem reads as the export not having worked rather than as stale save data.
if exist "%SAVE%\isoregiondata" for %%F in ("%SAVE%\isoregiondata\datachunk_*.bin") do (
    for /f "tokens=2,3 delims=_" %%A in ("%%~nF") do (
        set /a CX=%%A / 32
        set /a CY=%%B / 32
        if defined CELL_!CX!_!CY! del /Q "%%F" & set /a N+=1
    )
)

rem Per-slot decor captures live here. Kept, the first scrub restores every
rem room to the decor it had BEFORE the export -- which looks exactly like the
rem export not having worked. This is a test save, so every mod's goes.
if exist "%SAVE%\global_mod_data.bin" del /Q "%SAVE%\global_mod_data.bin" & set /a N+=1

echo [map] reset %SAVE%: deleted !N! files
popd
endlocal
