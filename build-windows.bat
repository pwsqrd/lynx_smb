@echo off
setlocal
rem ---------------------------------------------------------------------------
rem  Super Mario Bros. for the Atari Lynx - one-click Windows build.
rem
rem  1. Install Docker Desktop (https://www.docker.com/products/docker-desktop/)
rem  2. Download this repo (Code -> Download ZIP) and extract it.
rem  3. Put your SMB .nes ROM in the rom folder.
rem  4. Double-click this file. The finished smb.lnx appears in this folder.
rem
rem  Build options can be passed on the command line, e.g.
rem    build-windows.bat TILE_MODE=5x4
rem ---------------------------------------------------------------------------

set "IMAGE=lynx_smb_builder"
set "HERE=%~dp0"

cd /d "%HERE%"

echo.
echo === Super Mario Bros. Lynx builder ===
echo.

rem --- This file must be run from inside the repo ----------------------------
if exist "Dockerfile" goto :repo_found
echo ERROR: This file must be inside the lynx_smb folder.
echo Download the repo from GitHub (Code, then Download ZIP), extract it,
echo and run build-windows.bat from the extracted folder.
goto :fail
:repo_found

rem --- The ROM goes in the rom folder ---------------------------------------------
if exist "rom\*.nes" goto :rom_found
echo ERROR: No .nes ROM found. Put your Super Mario Bros. ROM in this folder:
echo   %HERE%rom
echo and run this file again.
goto :fail
:rom_found

rem --- Docker Desktop must be installed and running --------------------------
where docker >nul 2>&1
if errorlevel 1 (
    echo ERROR: Docker is not installed.
    echo Install Docker Desktop from https://www.docker.com/products/docker-desktop/
    echo then restart your PC and run this file again.
    goto :fail
)

docker info >nul 2>&1
if not errorlevel 1 goto :docker_ready

echo Docker Desktop is not running, starting it...
if exist "%ProgramFiles%\Docker\Docker\Docker Desktop.exe" (
    start "" "%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
) else (
    echo Please start Docker Desktop from the Start menu.
)
echo Waiting for Docker to be ready, this can take a minute...
set /a TRIES=0
:wait_docker
timeout /t 5 /nobreak >nul
docker info >nul 2>&1
if not errorlevel 1 goto :docker_ready
set /a TRIES+=1
if %TRIES% lss 36 goto :wait_docker
echo ERROR: Docker did not start after 3 minutes.
echo Open Docker Desktop, wait for "Engine running", then run this file again.
goto :fail

:docker_ready
echo Docker is running.

rem --- Build ------------------------------------------------------------------
echo.
echo Building the build environment (about 5 minutes the first time)...
docker build -t %IMAGE% .
if errorlevel 1 (
    echo ERROR: Building the Docker image failed - see the messages above.
    goto :fail
)

if not exist "out" mkdir "out"

echo.
echo Building the game...
if "%~1"=="" (
    docker run --rm -v "%HERE%rom:/build/rom" -v "%HERE%out:/build/out" %IMAGE%
) else (
    docker run --rm -v "%HERE%rom:/build/rom" -v "%HERE%out:/build/out" %IMAGE% make %*
)
if errorlevel 1 (
    echo ERROR: The game build failed - see the messages above.
    echo If it says the ROM was not found, your .nes file is not the version this
    echo port needs: Super Mario Bros ^(JU^) ^(PRG 0^), 40976 bytes.
    goto :fail
)

copy /y "out\*.lnx" "%HERE%" >nul

echo.
echo === Done! ===
echo Your game is in: %HERE%
dir /b "*.lnx"
echo Open the .lnx file in a Lynx emulator such as GearLynx or Felix.
echo.
pause
exit /b 0

:fail
echo.
pause
exit /b 1
