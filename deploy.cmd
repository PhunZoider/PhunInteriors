@echo off
setlocal enabledelayedexpansion

rem ---------------------------------------------------------------------------
rem PhunInteriors deploy.
rem
rem v1 spelled every copy step out inline in .vscode/settings.json. With six
rem mods that would be sixty-odd entries, so the whole pipeline lives here and
rem settings.json just calls this on save.
rem
rem Deploys to:
rem   %USERPROFILE%\Zomboid\mods\<Mod>              - playable
rem   %USERPROFILE%\Zomboid\mods\<Mod>Test          - test-id variant
rem   %USERPROFILE%\Zomboid\Workshop\PhunInteriors     - upload staging
rem   %USERPROFILE%\Zomboid\Workshop\PhunInteriorsTest - test upload staging
rem ---------------------------------------------------------------------------

set MODS=PhunInteriors

set SRC=%~dp0
set MODDIR=%USERPROFILE%\Zomboid\mods
set WS=%USERPROFILE%\Zomboid\Workshop\PhunInteriors
set WSTEST=%USERPROFILE%\Zomboid\Workshop\PhunInteriorsTest

echo [PhunInteriors] Deploying to %MODDIR%

rem --- Live mods -------------------------------------------------------------
rem xclude applies HERE, and this is the only line where it can. The Workshop
rem staging copies below pass it too, but they then throw their Contents folder
rem away and take it from %MODDIR%, so a file not filtered on this line ships
rem in all four trees. That is how phuninteriors.tiles.txt kept arriving after
rem being added to the list.
rem
rem xcopy matches each entry as a SUBSTRING of the whole source path, so keep
rem them specific: "phuninteriors.tiles.txt" is safe, and a bare
rem "phuninteriors.tiles" would take the real tiledefs with it.
for %%M in (%MODS%) do (
    rmdir /S /Q "%MODDIR%\%%M" 2>nul
    xcopy "%SRC%Contents\mods\%%M" "%MODDIR%\%%M" /Y /I /E /F /Q /EXCLUDE:%SRC%xclude >nul
    if errorlevel 1 echo [PhunInteriors] FAILED copying %%M
)

rem --- Test-id variants ------------------------------------------------------
rem Copy the live mod, then overlay Tests\root\<Mod> which swaps in a mod.info
rem carrying the *test ids. Lets both versions sit side by side in one install.
rem
rem Neither copy here takes /EXCLUDE. The first does not need it, because
rem %MODDIR%\<Mod> was already filtered above. The second must not have it: its
rem source path contains "Tests", which is an xclude entry, so the substring
rem match would hit every file and the overlay would copy nothing at all.
for %%M in (%MODS%) do (
    rmdir /S /Q "%MODDIR%\%%MTest" 2>nul
    xcopy "%MODDIR%\%%M" "%MODDIR%\%%MTest" /Y /I /E /F /Q >nul
    if exist "%SRC%Tests\root\%%M" (
        xcopy "%SRC%Tests\root\%%M" "%MODDIR%\%%MTest" /Y /I /E /F /Q >nul
    )
)

rem --- Workshop staging, live ------------------------------------------------
rem media\maps ships. It used to be stripped from both staging trees
rem because the lotpacks were the reference mod's map and could not be
rem redistributed. Cells 87,46 and 88,46 are ours now, and the rooms do not
rem exist without them, so a Workshop build that drops them has no rooms.
rmdir /S /Q "%WS%" 2>nul
xcopy "%SRC%" "%WS%" /Y /I /E /F /Q /EXCLUDE:%SRC%xclude >nul
rmdir /S /Q "%WS%\Tests" 2>nul
rmdir /S /Q "%WS%\Contents" 2>nul
for %%M in (%MODS%) do (
    xcopy "%MODDIR%\%%M" "%WS%\Contents\mods\%%M" /Y /I /E /F /Q >nul
)

rem --- Workshop staging, test ------------------------------------------------
rem Same mod folder names as live, but each carries the test mod.info, and the
rem workshop.txt / preview.png come from Tests\.
rmdir /S /Q "%WSTEST%" 2>nul
xcopy "%SRC%" "%WSTEST%" /Y /I /E /F /Q /EXCLUDE:%SRC%xclude >nul
rmdir /S /Q "%WSTEST%\Tests" 2>nul
rmdir /S /Q "%WSTEST%\Contents" 2>nul
for %%M in (%MODS%) do (
    xcopy "%MODDIR%\%%MTest" "%WSTEST%\Contents\mods\%%M" /Y /I /E /F /Q >nul
)
copy /Y "%SRC%Tests\workshop.txt" "%WSTEST%\workshop.txt" >nul
if exist "%SRC%Tests\preview.png" copy /Y "%SRC%Tests\preview.png" "%WSTEST%\preview.png" >nul

echo [PhunInteriors] Done.
endlocal
