@echo off
setlocal enabledelayedexpansion

rem === Build + run pipeline for the moving-screen example =====================
rem   1) Export the authoring scene (project_script_example) to JSON
rem   2) Export the engine project (project_engine) to a Windows .exe
rem   3) Launch the .exe with --script pointing at the JSON from step 1
rem
rem Godot 4.7 must be on PATH as `godot`. For step 2 you also need Windows
rem export templates installed (Godot editor > Editor > Manage Export
rem Templates > Download for the matching version).

set REPO=%~dp0
if "%REPO:~-1%"=="\" set REPO=%REPO:~0,-1%

set ENGINE_PROJECT=%REPO%\project_engine
set TEMPLATE_PROJECT=%REPO%\project_script_example
set SCRIPT_OUT=%REPO%\scripts\moving_screen\video.json
set BUILD_DIR=%REPO%\build
set BINARY=%BUILD_DIR%\VRmviewer.exe
set PRESET=Windows Desktop

where godot >nul 2>&1
if errorlevel 1 (
    echo [error] `godot` not found on PATH. Install Godot 4.7 or add it to PATH.
    exit /b 1
)

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

echo.
echo === [1/3] Export authoring scene to %SCRIPT_OUT% ===
godot --headless --path "%TEMPLATE_PROJECT%" --script res://tools/run_export.gd
if errorlevel 1 (
    echo [error] Scene export failed.
    exit /b 1
)
if not exist "%SCRIPT_OUT%" (
    echo [error] Exporter reported success but %SCRIPT_OUT% is missing.
    exit /b 1
)

echo.
echo === [2/3] Compile engine binary to %BINARY% ===
godot --headless --path "%ENGINE_PROJECT%" --export-release "%PRESET%" "%BINARY%"
if errorlevel 1 (
    echo [error] Engine export failed. Common causes:
    echo   - Windows export templates not installed for this Godot version.
    echo     Fix: open Godot, Editor menu ^> Manage Export Templates ^> Download.
    echo   - Preset "%PRESET%" missing from %ENGINE_PROJECT%\export_presets.cfg.
    exit /b 1
)
if not exist "%BINARY%" (
    echo [error] Godot returned success but %BINARY% is missing.
    exit /b 1
)

echo.
echo === [3/3] Run %BINARY% with --script %SCRIPT_OUT% ===
"%BINARY%" -- --script "%SCRIPT_OUT%"
exit /b %ERRORLEVEL%
