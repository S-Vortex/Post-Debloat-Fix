# Changelog

All notable changes to this project are documented in this file.

## 1.0.0 — 2026-11-22

- First public release.
- `Repair-WindowsStore.ps1` repairs the Windows 10 or 11 component store with
  DISM RestoreHealth, using Windows Update first.
- If DISM fails with `0x800f081f` (source files not found), the script reads
  `CBS.log`, lists missing or corrupt payloads, and can retry from a Windows
  ISO (`-IsoPath`) or a folder / `.cab` / `.msu` (`-SourcePath`).
- `.msu` and `.cab` files are expanded with `expand.exe` and used only as a
  DISM source; they are not installed.
- If a missing payload looks like a .NET Framework (NetFx4) component, the
  script explains how to find the matching cumulative update in the Microsoft
  Update Catalog (`-OpenCatalog` opens a suggested search).
- Runs `sfc /scannow` after DISM unless `-SkipSfc` is set.
- `-CheckOnly` inspects the PC and recent CBS entries without elevation.
- `-WhatIf` prints the planned actions without changing anything.
- `-ScanOnly` runs DISM ScanHealth only.
- Never reboots, never installs updates, and never changes Windows Update
  settings.
- `Run-Repair.bat` launches the script with `-ExecutionPolicy Bypass` for that
  process only.
