@echo off
setlocal
rem Installs Blimp's 3ds Max tools for every 3ds Max version this Windows user has run: a small loader script in
rem each version's user startup folder (%LOCALAPPDATA%\Autodesk\3dsMax\<version>\<language>\scripts\startup)
rem that fileIns blimp_clips.ms from this folder. No admin rights needed, and edits to the script apply on the next
rem Max start without installing again. Run it again only if the project moves.

set "SCRIPT=%~dp0blimp_clips.ms"
set "FOUND="

for /d %%V in ("%LOCALAPPDATA%\Autodesk\3dsMax\*") do (
    for /d %%L in ("%%V\*") do (
        if exist "%%L\scripts" (
            if not exist "%%L\scripts\startup" mkdir "%%L\scripts\startup"
            > "%%L\scripts\startup\blimp_tools.ms" (
                echo -- Written by Blimp's tools\max\install.bat: loads the Blimp tools from the project.
                echo global BlimpClips_FromStartup = true
                echo fileIn @"%SCRIPT%"
            )
            echo Installed: %%L\scripts\startup\blimp_tools.ms
            set "FOUND=1"
        )
    )
)

if not defined FOUND (
    echo No 3ds Max user folder found under %LOCALAPPDATA%\Autodesk\3dsMax.
    echo Start 3ds Max once so it creates it, then run this again.
    goto :done
)

rem An older copy in an install's own startup folder would load as well; remove it.
for /d %%M in ("%ProgramFiles%\Autodesk\3ds Max *") do (
    if exist "%%M\scripts\startup\blimp_clips.ms" (
        del "%%M\scripts\startup\blimp_clips.ms" 2>nul
        if exist "%%M\scripts\startup\blimp_clips.ms" (
            echo Old copy left in %%M\scripts\startup: delete blimp_clips.ms there by hand, or run this as administrator.
        ) else (
            echo Removed the old copy from %%M\scripts\startup.
        )
    )
)

echo Restart 3ds Max: the Blimp menu has Blimp Clips.

:done
pause
