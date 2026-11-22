# Repair-WindowsStore

Repair a damaged Windows component store (`DISM /RestoreHealth`) and then
verify system files (`sfc /scannow`) on Windows 10 or Windows 11.

Debloat scripts and interrupted updates sometimes leave the component store
unable to repair itself. DISM then fails with **0x800f081f**
(`CBS_E_SOURCE_MISSING`): "The source files could not be found." This project
runs the official Microsoft repair tools, explains what is missing, and lets
you point DISM at a matching ISO or a cumulative-update package.

This project is **not affiliated with Microsoft** and **not affiliated with
Raphire** or any Windows "debloater" project.

**Suggested GitHub repository name:** `repair-windows-component-store`

## What it does

1. Records the edition, build, and architecture of the PC.
2. Runs `DISM /Online /Cleanup-Image /RestoreHealth` and lets Windows Update
   supply files when it can.
3. If that fails with `0x800f081f`, reads `C:\Windows\Logs\CBS\CBS.log`,
   lists `CSI Payload Corrupt` / missing payloads, and (if you provided one)
   retries with a local source:
   - **`-IsoPath`** — mounts a Windows ISO, picks the image index that matches
     this edition (`EditionID`), warns if the ISO build differs, and uses a
     `wim:` or `esd:` source.
   - **`-SourcePath`** — a folder, `.cab`, `.msu`, `.wim`, or `.esd`. `.msu`
     and `.cab` files are expanded with `expand.exe` into a temporary
     directory. They are **not installed**.
   - **.NET Framework (NetFx4) payloads** — a Windows ISO often does not
     contain later .NET cumulative-update files. The script tells you how to
     find the matching package in the [Microsoft Update Catalog](https://www.catalog.update.microsoft.com/)
     and pass the downloaded `.msu` to `-SourcePath`. `-OpenCatalog` opens a
     suggested search in your browser.
4. Runs `sfc /scannow` (unless you pass `-SkipSfc`).

The script **never reboots**, **never installs updates**, and **never changes
Windows Update settings**.

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 (the version included with Windows 10) or later
- Administrator approval for an actual scan or repair (`-CheckOnly` does not
  need it)

## Warnings

- Use this at your own risk. Repairing the component store is usually safe,
  but you should back up important data first.
- A current Microsoft ISO may not match an older Windows build, and it often
  will not contain later .NET Framework quality updates.
- Do not copy Microsoft `.msu`, `.cab`, or ISO files into a public repository.
  This repo is set up to ignore them.

## Usage

From the project folder:

```bat
Run-Repair.bat
```

Or in PowerShell:

```powershell
Set-Location path\to\repair-windows-component-store
powershell -NoProfile -ExecutionPolicy Bypass -File .\Repair-WindowsStore.ps1
```

`Run-Repair.bat` only bypasses the execution policy for that one process. It
does not change the system policy. Extra arguments are passed through to the
script.

### Inspect only (no administrator prompt)

```powershell
.\Repair-WindowsStore.ps1 -CheckOnly
```

Prints the OS edition and build, summarizes recent corruption in `CBS.log` if
the log is readable, and prints next-step commands.

### Show the plan without changing anything

```powershell
.\Repair-WindowsStore.ps1 -WhatIf -NoPause
```

### Scan only

```powershell
.\Repair-WindowsStore.ps1 -ScanOnly
```

Runs `DISM /ScanHealth` and does not repair or run SFC.

### Repair, using Windows Update first

```powershell
.\Repair-WindowsStore.ps1
```

Double-clicking `Run-Repair.bat` does the same thing. Approve the User Account
Control prompt when it appears.

### Repair from a Windows ISO (if Windows Update cannot supply the files)

```powershell
.\Repair-WindowsStore.ps1 -IsoPath 'D:\Windows10.iso'
```

The script still tries Windows Update first, then remounts the ISO only if
DISM reports that the source is missing.

### Repair from a downloaded update package

```powershell
.\Repair-WindowsStore.ps1 -SourcePath 'C:\Packages\windows10.0-kbXXXXXXXX-x64-ndp48.msu'
```

Use this when `CBS.log` shows a **NetFx4** / `.NET` payload, or any file that
came from a later cumulative update rather than the original ISO.

### Other useful switches

| Switch | Meaning |
| --- | --- |
| `-SkipSfc` | Do not run `sfc /scannow` after DISM |
| `-OpenCatalog` | Open a Microsoft Update Catalog search in your browser |
| `-NoPause` | Do not wait for Enter at the end (for automation) |

## How to find the right ISO

1. On the affected PC, run `winver` or `Repair-WindowsStore.ps1 -CheckOnly`
   and note the edition (for example Windows 10 Pro) and the build
   (for example 19041.1415).
2. For a **current** Windows 10 or 11 image, use Microsoft's official media:
   - [Windows 10](https://www.microsoft.com/software-download/windows10) (Media Creation Tool, then "ISO file")
   - [Windows 11](https://www.microsoft.com/software-download/windows11)
3. For an **older exact build**, Microsoft's current ISO will usually not
   match. [UUP dump](https://uupdump.net/) can build an ISO for a specific
   version. The closer the ISO build is to the installed build, the more
   likely DISM is to find the files it needs.
4. Pass the ISO to `-IsoPath` as shown above.

## How to find a .NET Framework cumulative update

If the script (or `CBS.log`) reports a missing payload whose name contains
`netfx4` or `NetFx`, that file almost certainly came from a later
**.NET Framework cumulative update**, not from a Windows ISO.

1. Open the [Microsoft Update Catalog](https://www.catalog.update.microsoft.com/).
   You can also run `Repair-WindowsStore.ps1 -CheckOnly -OpenCatalog`.
2. Search for something like:
   `Cumulative Update for .NET Framework Windows 10 21H2 x64`
   (use your own Windows version, edition family, and architecture).
3. Download the `.msu` that matches this PC (same architecture, same Windows
   10/11 version family). Prefer a package whose file versions match the
   component version in `CBS.log` when the catalog or KB article lists them.
4. Re-run the script with `-SourcePath` pointing at the `.msu`. The script
   will expand it and use it as a DISM source. It will not install the update
   and will not reboot.

## Logs

- A timestamped log is written to `logs\` next to the script (or to
  `%ProgramData%\Repair-WindowsStore\logs` if that folder is not writable).
  `logs\` is gitignored.
- Official logs remain at:
  - `C:\Windows\Logs\DISM\dism.log`
  - `C:\Windows\Logs\CBS\CBS.log`

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, or a completed `-CheckOnly` / `-WhatIf` run |
| 1 | Unexpected error |
| 2 | DISM source missing (`0x800f081f`) and the repair is incomplete |
| 3 | Administrator approval was declined or failed |
| 4 | Invalid input (ISO or source path not found) |
| 5 | DISM failed for another reason |
| 6 | SFC finished with a non-zero exit code |

## Troubleshooting

- **"The source files could not be found" after using an ISO.** The ISO build
  or edition does not contain the missing file. Check the payload names in
  the log. If they include `netfx4`, use a .NET cumulative update `.msu`
  instead of (or in addition to) an ISO.
- **UAC prompt, then nothing.** Windows may have blocked the script. Right-click
  `Run-Repair.bat` and choose "Run as administrator", or run the
  `powershell -ExecutionPolicy Bypass -File ...` command from an elevated
  PowerShell window.
- **`CBS.log` access denied in `-CheckOnly`.** That is normal on some PCs
  without elevation. The repair path runs elevated and can read the log.
- **SFC says it repaired files after DISM succeeded.** That is expected. DISM
  repairs the component store; SFC then restores the working copies of those
  files (and may also fix unrelated shortcuts or files).
- **Do not** use this script to install Windows feature updates, and **do not**
  add Microsoft packages to a public fork of this repository.

## License

[MIT](LICENSE) © 2026 Sam Mills.
