@echo off
setlocal
rem ---------------------------------------------------------------------------
rem  Super Mario Bros. for the Atari Lynx - one-click Windows build.
rem
rem  1. Install Docker Desktop (https://www.docker.com/products/docker-desktop/)
rem  2. Put this .bat file and your SMB .nes ROM in the same folder.
rem  3. Double-click this file. The finished smb.lnx appears in that folder.
rem
rem  Build options can be passed on the command line, e.g.
rem    build-windows.bat TILE_MODE=5x4
rem ---------------------------------------------------------------------------

set "REPO_ZIP=https://github.com/pwsqrd/lynx_smb/archive/refs/heads/main.zip"
set "IMAGE=lynx_smb_builder"
set "HERE=%~dp0"
set "WORK=%HERE%lynx_smb_build"

cd /d "%HERE%"

echo.
echo === Super Mario Bros. Lynx builder ===
echo.

rem --- The ROM must be next to this file ------------------------------------
if exist "*.nes" goto :rom_found
echo ERROR: No .nes ROM found in this folder:
echo   %HERE%
echo Put your Super Mario Bros. ROM next to this .bat file and run it again.
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

rem --- Fresh work folder with the latest source --------------------------------
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%\rom"
mkdir "%WORK%\out"

echo.
echo Downloading the latest source...
curl.exe -fsSL -o "%WORK%\source.zip" "%REPO_ZIP%"
if errorlevel 1 (
    echo ERROR: Download failed. Check your internet connection.
    goto :fail
)
tar.exe -xf "%WORK%\source.zip" -C "%WORK%"
if errorlevel 1 (
    echo ERROR: Could not unpack the source.
    goto :fail
)

copy /y "*.nes" "%WORK%\rom\" >nul

rem --- Build ------------------------------------------------------------------
echo.
echo Building the build environment (about 5 minutes the first time)...
docker build -t %IMAGE% "%WORK%\lynx_smb-main"
if errorlevel 1 (
    echo ERROR: Building the Docker image failed - see the messages above.
    goto :fail
)

echo.
echo Building the game...
if "%~1"=="" (
    docker run --rm -v "%WORK%\rom:/build/rom" -v "%WORK%\out:/build/out" %IMAGE%
) else (
    docker run --rm -v "%WORK%\rom:/build/rom" -v "%WORK%\out:/build/out" %IMAGE% make %*
)
if errorlevel 1 (
    echo ERROR: The game build failed - see the messages above.
    echo If it says the ROM was not found, your .nes file is not the version this
    echo port needs: Super Mario Bros ^(JU^) ^(PRG 0^), 40976 bytes.
    goto :fail
)

copy /y "%WORK%\out\*.lnx" "%HERE%" >nul
rmdir /s /q "%WORK%"

echo.
echo === Done! ===
echo Your game is in: %HERE%
dir /b "%HERE%*.lnx"
echo Open the .lnx file in a Lynx emulator such as GearLynx or Felix.
echo.
pause
exit /b 0

:fail
echo.
pause
exit /b 1
