@echo off
setlocal
title Repair Windows Component Store
cd /d "%~dp0"

echo Repair-WindowsStore
echo This will request Administrator approval, then run DISM RestoreHealth
echo (Windows Update first) and sfc /scannow. It can take 15-40 minutes.
echo The script never reboots and never installs updates.
echo A log is written to the logs folder next to this file.
echo.
echo Usage tips:
echo   Run-Repair.bat -CheckOnly     inspect only, no administrator prompt
echo   Run-Repair.bat -ScanOnly      DISM ScanHealth only
echo   Run-Repair.bat -IsoPath "D:\Windows.iso"
echo   Run-Repair.bat -SourcePath "C:\Path\package.msu"
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-WindowsStore.ps1" %*
set ERR=%ERRORLEVEL%
echo.
echo Finished with exit code %ERR%.
endlocal & exit /b %ERR%
