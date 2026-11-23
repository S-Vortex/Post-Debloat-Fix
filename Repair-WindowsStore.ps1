#Requires -Version 5.1
<#
.SYNOPSIS
    Repairs Windows component-store corruption (DISM RestoreHealth and SFC).

.DESCRIPTION
    Runs DISM /Online /Cleanup-Image /RestoreHealth using Windows Update as the
    first source. If DISM fails with 0x800f081f (source files not found), the
    script reads CBS.log, lists the missing or corrupt payloads, and can retry
    from a Windows ISO or a folder / .cab / .msu you supply.

    This script never reboots the computer, never installs updates, and never
    changes Windows Update settings. A .msu or .cab you pass with -SourcePath
    is expanded and used only as a DISM source; it is not installed.

.PARAMETER CheckOnly
    No administrator prompt. Prints OS information, summarizes any recent
    component-store corruption from CBS.log, and exits.

.PARAMETER ScanOnly
    Runs DISM /ScanHealth only (no repair, no SFC). Requires administrator.

.PARAMETER IsoPath
    Path to a Windows 10 or 11 ISO. Used as a repair source if Windows Update
    cannot supply the missing files.

.PARAMETER SourcePath
    Path to a folder, .cab, .msu, .wim, or .esd to use as a DISM source if
    Windows Update cannot supply the missing files. .msu and .cab files are
    expanded to a temporary directory and are not installed.

.PARAMETER SkipSfc
    Skip sfc /scannow after DISM.

.PARAMETER OpenCatalog
    Opens a Microsoft Update Catalog search in your default browser. Useful
    when the missing file is from a .NET Framework cumulative update.

.PARAMETER NoPause
    Do not wait for a key press at the end (for automation).

.EXAMPLE
    .\Repair-WindowsStore.ps1 -CheckOnly

.EXAMPLE
    .\Repair-WindowsStore.ps1

.EXAMPLE
    .\Repair-WindowsStore.ps1 -IsoPath 'D:\Windows10.iso'

.EXAMPLE
    .\Repair-WindowsStore.ps1 -SourcePath 'C:\Packages\windows10.0-kbXXXXXXXX-x64-ndp48.msu'

.NOTES
    Version 1.0.1
    Requires PowerShell 5.1 or later and Windows 10 or 11.
    License: MIT
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$CheckOnly,
    [switch]$ScanOnly,
    [string]$IsoPath,
    [string]$SourcePath,
    [switch]$SkipSfc,
    [switch]$OpenCatalog,
    [switch]$NoPause,
    [switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'
$script:Version = '1.0.1'
$script:LogPath = $null
$script:WorkDir = $null
$script:MountedIso = $null
$script:ExitCode = 0

# 0 = success
# 1 = unexpected error
# 2 = DISM source missing (0x800f081f) and repair incomplete
# 3 = elevation failed or declined
# 4 = invalid input
# 5 = DISM failed for another reason
# 6 = SFC reported unrepaired files

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}


function Get-NativeSystem32 {
    # When a 32-bit PowerShell host runs on 64-bit Windows, System32 is redirected.
    if ($env:PROCESSOR_ARCHITEW6432) {
        return (Join-Path $env:SystemRoot 'Sysnative')
    }
    return (Join-Path $env:SystemRoot 'System32')
}

function Test-IsSourceMissingExitCode {
    param([int64]$Code)
    $unsigned = $Code -band 0xFFFFFFFF
    return ($unsigned -eq 0x800F081F)
}

function Test-LogContainsSourceMissing {
    if (-not $script:LogPath -or -not (Test-Path -LiteralPath $script:LogPath)) { return $false }
    $hit = Select-String -LiteralPath $script:LogPath -Pattern '0x800f081f|CBS_E_SOURCE_MISSING|source files could not be found' -Quiet -ErrorAction SilentlyContinue
    return [bool]$hit
}

function Get-ScriptRoot {
    if ($PSCommandPath) { return Split-Path -Parent $PSCommandPath }
    if ($MyInvocation.MyCommand.Path) { return Split-Path -Parent $MyInvocation.MyCommand.Path }
    return (Get-Location).Path
}

function Initialize-Log {
    $root = Get-ScriptRoot
    $logDir = Join-Path $root 'logs'
    try {
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false -Confirm:$false | Out-Null
        }
        $testFile = Join-Path $logDir '.write-test'
        [System.IO.File]::WriteAllText($testFile, 'ok')
        Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
    } catch {
        $logDir = Join-Path $env:ProgramData 'Repair-WindowsStore\logs'
        New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false -Confirm:$false | Out-Null
    }
    $name = 'Repair-WindowsStore-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)
    $script:LogPath = Join-Path $logDir $name
    $header = @(
        "===== Repair-WindowsStore $($script:Version) started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====="
        "Host: $env:COMPUTERNAME"
        "User: $env:USERDOMAIN\$env:USERNAME"
        "Elevated: $(Test-IsAdministrator)"
        "PowerShell: $($PSVersionTable.PSVersion)"
        "Arguments: $($PSBoundParameters.Keys -join ', ')"
        ''
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $script:LogPath -Value $header -Encoding UTF8 -WhatIf:$false -Confirm:$false
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('White', 'Gray', 'Cyan', 'Green', 'Yellow', 'Red', 'DarkGray')]
        [string]$Color = 'White'
    )
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    if ($script:LogPath) {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -WhatIf:$false -Confirm:$false
    }
    Write-Host $line -ForegroundColor $Color
}

function Write-Banner {
    Write-Host ''
    Write-Host "Repair-WindowsStore v$($script:Version)" -ForegroundColor Cyan
    Write-Host 'Repairs the Windows component store (DISM) and system files (SFC).' -ForegroundColor Gray
    Write-Host 'Never reboots, never installs updates, never changes Windows Update settings.' -ForegroundColor Gray
    Write-Host ''
}

function Get-OsInfo {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq 'AMD64') { $archLabel = 'x64' }
    elseif ($arch -eq 'ARM64') { $archLabel = 'ARM64' }
    else { $archLabel = 'x86' }

    $display = $null
    if ($cv.PSObject.Properties['DisplayVersion'] -and $cv.DisplayVersion) {
        $display = [string]$cv.DisplayVersion
    } elseif ($cv.PSObject.Properties['ReleaseId'] -and $cv.ReleaseId) {
        $display = [string]$cv.ReleaseId
    }

    $ubr = $null
    if ($cv.PSObject.Properties['UBR']) { $ubr = [string]$cv.UBR }

    return [pscustomobject]@{
        ProductName   = [string]$cv.ProductName
        EditionId     = [string]$cv.EditionID
        CurrentBuild  = [int]$cv.CurrentBuildNumber
        Ubr           = $ubr
        BuildString   = if ($ubr) { '{0}.{1}' -f $cv.CurrentBuildNumber, $ubr } else { [string]$cv.CurrentBuildNumber }
        DisplayVersion = $display
        Architecture  = $arch
        ArchitectureLabel = $archLabel
        InstallationType = [string]$cv.InstallationType
    }
}

function Write-OsInfo {
    param($Info)
    Write-Log ("OS: {0} ({1}), version {2}, build {3}, {4}" -f `
        $Info.ProductName, $Info.EditionId, $(if ($Info.DisplayVersion) { $Info.DisplayVersion } else { 'n/a' }), `
        $Info.BuildString, $Info.ArchitectureLabel)
}

function Get-CbsCorruptionReport {
    $path = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
    $report = [ordered]@{
        LogPath          = $path
        Available        = $false
        AccessDenied     = $false
        SourceMissing    = $false
        Payloads         = @()
        CorruptionCount  = $null
        RepairedCount    = $null
        LooksLikeNetFx   = $false
        RepairedPayloads = @()
    }

    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]$report
    }

    try {
        $hits = @(Select-String -LiteralPath $path -Pattern 'CSI Payload Corrupt|Add missing payload:|CBS_E_SOURCE_MISSING|Total Repaired Corruption:|CSI Payload Corruption:|CSI Payload Repaired:|CheckSur:|Session:.*finalized|session\(Corruption Repairing\)' -ErrorAction Stop)
    } catch {
        $msg = [string]$_
        if ($msg -match 'denied|UnauthorizedAccess|Unauthorized') {
            $report.AccessDenied = $true
        }
        return [pscustomobject]$report
    }

    $report.Available = $true
    if ($hits.Count -eq 0) {
        return [pscustomobject]$report
    }

    # Typical line: amd64_netfx4-name_b03f5f7f11d50a3a_4.0.15805.390_none_acb860dffa1b6609\File.dll
    $compFile = [regex]'(?i)((?:amd64|x86|wow64|msil)_[A-Za-z0-9.\-]+_[0-9a-f]{16}_[0-9.]+_[A-Za-z0-9\-]+_[0-9a-f]+(?:\\[\w.\-]+)?)'

    # Use only the newest component-store repair session, not earlier failures
    # still sitting in CBS.log. Session ends are "finalized", CheckSur, or
    # "Total Repaired Corruption".
    $endIdx = $hits.Count - 1
    for ($i = $hits.Count - 1; $i -ge 0; $i--) {
        if ($hits[$i].Line -match 'Total Repaired Corruption:|CheckSur:|Session:.*finalized|Exec: Processing complete, session\(Corruption Repairing\)') {
            $endIdx = $i
            break
        }
    }
    $startIdx = 0
    for ($i = $endIdx - 1; $i -ge 0; $i--) {
        if ($hits[$i].Line -match 'Session:.*finalized|Exec: Processing complete, session\(Corruption Repairing\)|CheckSur:') {
            $startIdx = $i + 1
            break
        }
    }
    $window = $hits[$startIdx..$endIdx]

    $payloads = New-Object System.Collections.Generic.List[string]
    $repairedPayloads = New-Object System.Collections.Generic.List[string]
    foreach ($hit in $window) {
        $line = $hit.Line
        if ($line -match 'CBS_E_SOURCE_MISSING') { $report.SourceMissing = $true }
        if ($line -match 'CSI Payload Corruption:\s+(\d+)') {
            $report.CorruptionCount = [int]$Matches[1]
        }
        if ($line -match 'Total Repaired Corruption:\s+(\d+)') {
            $report.RepairedCount = [int]$Matches[1]
        }
        if ($line -match 'HRESULT = 0x00000000' -or $line -match 'The restore operation completed successfully') {
            $report.SourceMissing = $false
        }
        if ($line -match 'CSI Payload Corrupt' -or $line -match 'Add missing payload:') {
            $m = $compFile.Match($line)
            if ($m.Success) {
                $name = $m.Groups[1].Value.Trim()
                $isFixed = ($line -match '\(Fixed\)' -or $line -match 'CSI Payload Repaired')
                if ($isFixed) {
                    if (-not $repairedPayloads.Contains($name)) { [void]$repairedPayloads.Add($name) }
                    if ($payloads.Contains($name)) { [void]$payloads.Remove($name) }
                } elseif (-not $payloads.Contains($name) -and -not $repairedPayloads.Contains($name)) {
                    [void]$payloads.Add($name)
                }
            }
        }
    }

    # If the newest session reported a full repair, do not keep those payloads
    # as still missing, and do not carry a source-missing flag forward.
    if ($null -ne $report.RepairedCount -and $null -ne $report.CorruptionCount -and $report.RepairedCount -ge $report.CorruptionCount -and $report.CorruptionCount -ge 0) {
        $report.SourceMissing = $false
        foreach ($n in @($payloads)) {
            if (-not $repairedPayloads.Contains($n)) { [void]$repairedPayloads.Add($n) }
            [void]$payloads.Remove($n)
        }
    }

    $report.Payloads = @($payloads)
    $report.RepairedPayloads = @($repairedPayloads)
    foreach ($p in $report.Payloads) {
        if ($p -match '(?i)netfx|ndp\d|NetFx4') { $report.LooksLikeNetFx = $true }
    }

    return [pscustomobject]$report
}

function Write-CbsReport {
    param($Report)
    if ($Report.AccessDenied) {
        Write-Log "CBS.log could not be read (access denied): $($Report.LogPath)" 'Yellow'
        Write-Log 'Re-run from an elevated prompt to parse the official component-store log.' 'Yellow'
        return
    }
    if (-not $Report.Available) {
        Write-Log "No CBS log found at $($Report.LogPath)" 'Yellow'
        return
    }

    Write-Log "CBS log: $($Report.LogPath) (newest repair session only)" 'Gray'
    if ($null -ne $Report.CorruptionCount) {
        Write-Log ("CSI payload corruption count (newest session): {0}" -f $Report.CorruptionCount)
    }
    if ($null -ne $Report.RepairedCount) {
        Write-Log ("Total repaired corruption (newest session): {0}" -f $Report.RepairedCount)
    }
    if ($Report.PSObject.Properties['RepairedPayloads'] -and $Report.RepairedPayloads -and $Report.RepairedPayloads.Count -gt 0) {
        Write-Log 'Payloads repaired in the newest session:' 'Green'
        foreach ($p in $Report.RepairedPayloads) {
            Write-Log ("  - {0}" -f $p) 'Green'
        }
    }
    if ($Report.SourceMissing) {
        Write-Log 'The newest session reported CBS_E_SOURCE_MISSING (0x800f081f): a required source file was not found.' 'Yellow'
    }
    if ($Report.Payloads -and $Report.Payloads.Count -gt 0) {
        Write-Log 'Missing or still-corrupt payloads in the newest session:' 'Cyan'
        foreach ($p in $Report.Payloads) {
            Write-Log ("  - {0}" -f $p) 'Yellow'
        }
    } elseif (-not $Report.SourceMissing) {
        if ($null -ne $Report.RepairedCount -and $Report.RepairedCount -gt 0) {
            Write-Log 'The newest component-store session completed and has no remaining listed payload corruption.' 'Green'
        } else {
            Write-Log 'No CSI payload-corruption entries were found in the newest CBS repair session.'
        }
    }
}

function Get-CatalogSearchUrl {
    param($OsInfo, $Report)
    $parts = @('Cumulative Update for .NET Framework')
    if ($OsInfo.ProductName -match 'Windows 11') { $parts += 'Windows 11' }
    else { $parts += 'Windows 10' }
    if ($OsInfo.DisplayVersion) { $parts += $OsInfo.DisplayVersion }
    $parts += $OsInfo.ArchitectureLabel
    $query = ($parts -join ' ')
    return 'https://www.catalog.update.microsoft.com/Search.aspx?q={0}' -f [uri]::EscapeDataString($query)
}

function Write-SourceGuidance {
    param($OsInfo, $Report)
    Write-Host ''
    Write-Log 'DISM could not find a matching source (0x800f081f). A Windows install ISO often is not enough if the missing file came from a later quality or .NET update.' 'Yellow'
    Write-Host ''
    Write-Host 'Ways to supply a source and re-run this script:' -ForegroundColor Cyan
    Write-Host '  1. A Windows ISO that matches this edition and build as closely as possible:'
    Write-Host ("     .\Repair-WindowsStore.ps1 -IsoPath 'D:\Windows.iso'")
    Write-Host '     Current Microsoft ISOs: https://www.microsoft.com/software-download/windows10'
    Write-Host '     or https://www.microsoft.com/software-download/windows11'
    Write-Host '     For an older exact build, use UUP dump: https://uupdump.net/'
    Write-Host ("     This PC is {0}, EditionID {1}, build {2}." -f $OsInfo.ProductName, $OsInfo.EditionId, $OsInfo.BuildString)
    Write-Host ''
    Write-Host '  2. A folder, .cab, or .msu that contains the missing component:'
    Write-Host ("     .\Repair-WindowsStore.ps1 -SourcePath 'C:\Path\to\package.msu'")
    Write-Host '     The script expands .msu/.cab files and uses them as a DISM source; it does not install them.'

    if ($Report -and $Report.LooksLikeNetFx) {
        $url = Get-CatalogSearchUrl -OsInfo $OsInfo -Report $Report
        Write-Host ''
        Write-Log 'At least one missing payload looks like a .NET Framework (NetFx4) component.' 'Cyan'
        Write-Host '  Download the Cumulative Update for .NET Framework that matches this Windows'
        Write-Host ("  version ({0} {1}, {2}) from the Microsoft Update Catalog, then pass the .msu to -SourcePath." -f $(if ($OsInfo.ProductName -match 'Windows 11') { 'Windows 11' } else { 'Windows 10' }), $OsInfo.DisplayVersion, $OsInfo.ArchitectureLabel)
        Write-Host '  Catalog: https://www.catalog.update.microsoft.com/'
        Write-Host ("  Suggested search: {0}" -f $url)
        Write-Host '  You can also re-run with -OpenCatalog to open that search in your browser.'
        Write-Host '  Pick the package for this architecture and Windows version. Do not install it'
        Write-Host '  unless you intend to; this script only needs the file as a repair source.'
    }
    Write-Host ''
}

function Request-Elevation {
    $argList = New-Object System.Collections.Generic.List[string]
    [void]$argList.Add('-NoProfile')
    [void]$argList.Add('-ExecutionPolicy')
    [void]$argList.Add('Bypass')
    [void]$argList.Add('-File')
    [void]$argList.Add($PSCommandPath)

    foreach ($key in $PSBoundParameters.Keys) {
        $val = $PSBoundParameters[$key]
        if ($val -is [switch]) {
            if ($val.IsPresent) { [void]$argList.Add("-$key") }
        } else {
            if ($null -ne $val -and [string]$val -ne '') {
                [void]$argList.Add("-$key")
                [void]$argList.Add([string]$val)
            }
        }
    }
    if ($WhatIfPreference) {
        if (-not $argList.Contains('-WhatIf')) { [void]$argList.Add('-WhatIf') }
    }

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList.ToArray() | Out-Null
        return $true
    } catch {
        Write-Host "Could not elevate (UAC was declined or failed): $_" -ForegroundColor Red
        return $false
    }
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [ValidateSet('OEM', 'Unicode', 'UTF8')]
        [string]$OutputEncodingName = 'OEM'
    )
    # Start the tool directly. Do not wrap it in "Start-Process cmd.exe /c ..." —
    # PowerShell's Start-Process re-quotes an already-quoted command line, so
    # cmd.exe never launches DISM or SFC and returns exit code 1 immediately.
    Write-Log ("Running: {0} {1}" -f $FilePath, $Arguments) 'Cyan'
    if ($OutputEncodingName) { } # kept for callers; output goes to this console
    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Log "Executable not found: $FilePath" 'Red'
        return 1
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $false
    $dir = Split-Path -Parent $FilePath
    if ($dir) { $psi.WorkingDirectory = $dir }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $proc.WaitForExit()
        $code = [int]$proc.ExitCode
        Write-Log ("Exit code: {0}" -f $code)
        return $code
    } catch {
        Write-Log "Failed to start ${FilePath}: $_" 'Red'
        return 1
    } finally {
        $proc.Dispose()
    }
}

function Get-IsoRepairSource {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $OsInfo
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "ISO not found: $Path"
    }
    Write-Log "Mounting ISO: $Path"
    $disk = Mount-DiskImage -ImagePath $Path -PassThru
    $script:MountedIso = $Path
    Start-Sleep -Seconds 2
    $vol = $disk | Get-Volume
    if (-not $vol -or -not $vol.DriveLetter) {
        throw "The ISO mounted but no drive letter was assigned."
    }
    $drive = '{0}:' -f $vol.DriveLetter
    Write-Log "ISO mounted at $drive"

    $img = Join-Path $drive 'sources\install.wim'
    $type = 'wim'
    if (-not (Test-Path -LiteralPath $img)) {
        $img = Join-Path $drive 'sources\install.esd'
        $type = 'esd'
    }
    if (-not (Test-Path -LiteralPath $img)) {
        throw "No install.wim or install.esd in $drive\sources"
    }

    $index = $null
    $isoBuild = $null
    $images = @(Get-WindowsImage -ImagePath $img)
    foreach ($i in $images) {
        $d = Get-WindowsImage -ImagePath $img -Index $i.ImageIndex
        if ($d.EditionId -eq $OsInfo.EditionId) {
            $index = [int]$i.ImageIndex
            $isoBuild = [string]$d.Version
            break
        }
    }
    if (-not $index) {
        Write-Log "Could not automatically match EditionID '$($OsInfo.EditionId)'. Images in this ISO:" 'Yellow'
        $images | Format-Table ImageIndex, ImageName | Out-String | Write-Host
        if ($CheckOnly -or $WhatIfPreference) {
            throw "Could not match EditionID '$($OsInfo.EditionId)' in the ISO."
        }
        $raw = Read-Host "Type the image index to use"
        $index = [int]$raw
        $d = Get-WindowsImage -ImagePath $img -Index $index
        $isoBuild = [string]$d.Version
    } else {
        Write-Log "Using ISO image index $index ($($OsInfo.EditionId)), image version $isoBuild"
    }
    if ($isoBuild) {
        try {
            $isoBuildNum = ([version]$isoBuild).Build
            if ($isoBuildNum -ne $OsInfo.CurrentBuild) {
                Write-Log "WARNING: ISO build $isoBuildNum differs from this PC's build $($OsInfo.CurrentBuild). Repair may fail if the missing files are not in this image." 'Yellow'
            }
        } catch { }
    }
    return '{0}:{1}:{2}' -f $type, $img, $index
}

function Get-PackageRepairSources {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Source path not found: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    $sources = New-Object System.Collections.Generic.List[string]

    if ($item.PSIsContainer) {
        [void]$sources.Add($item.FullName)
        $cabs = @(Get-ChildItem -LiteralPath $item.FullName -Filter '*.cab' -ErrorAction SilentlyContinue)
        foreach ($c in $cabs) { [void]$sources.Add($c.FullName) }
        return @($sources)
    }

    $ext = $item.Extension.ToLowerInvariant()
    if ($ext -eq '.wim' -or $ext -eq '.esd') {
        Write-Log "Source is a $($ext.Trim('.')) image. The edition index will be selected like an ISO."
        return @($item.FullName)
    }
    if ($ext -eq '.cab') {
        [void]$sources.Add($item.FullName)
        return @($sources)
    }
    if ($ext -ne '.msu') {
        throw "Unsupported source type '$ext'. Use a folder, .cab, .msu, .wim, .esd, or an ISO with -IsoPath."
    }

    $script:WorkDir = Join-Path $env:TEMP ('Repair-WindowsStore-{0}' -f [guid]::NewGuid().ToString('N'))
    $msuOut = Join-Path $script:WorkDir 'msu'
    $extracted = Join-Path $script:WorkDir 'extracted'
    New-Item -ItemType Directory -Path $msuOut, $extracted -Force | Out-Null
    Write-Log "Expanding MSU to $msuOut (not installing)..."
    $exp1 = Invoke-LoggedCommand -FilePath 'expand.exe' -Arguments ('-F:* "{0}" "{1}"' -f $item.FullName, $msuOut)
    if ($exp1 -ne 0) { throw "expand.exe failed on the .msu (exit $exp1)." }

    $cabs = @(Get-ChildItem -LiteralPath $msuOut -Filter '*.cab' | Where-Object { $_.Name -notmatch '^WSUSSCAN' })
    if ($cabs.Count -eq 0) { throw "No payload .cab was found inside the .msu." }
    foreach ($cab in $cabs) {
        Write-Log "Expanding $($cab.Name) to $extracted"
        $exp2 = Invoke-LoggedCommand -FilePath 'expand.exe' -Arguments ('-F:* "{0}" "{1}"' -f $cab.FullName, $extracted)
        if ($exp2 -ne 0) {
            Write-Log "expand.exe returned $exp2 for $($cab.Name). The .cab itself can still be used as a DISM source." 'Yellow'
        }
        [void]$sources.Add($cab.FullName)
    }
    if (Test-Path -LiteralPath $extracted) { [void]$sources.Add($extracted) }
    return @($sources)
}

function Invoke-DismRestoreHealth {
    param(
        [string[]]$SourceSpecs,
        [switch]$LimitAccess
    )
    $args = '/Online /Cleanup-Image /RestoreHealth'
    if ($SourceSpecs) {
        foreach ($s in $SourceSpecs) {
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            $args += ' /Source:"{0}"' -f $s
        }
    }
    if ($LimitAccess) { $args += ' /LimitAccess' }
    return Invoke-LoggedCommand -FilePath (Join-Path (Get-NativeSystem32) 'dism.exe') -Arguments $args -OutputEncodingName OEM
}

function Invoke-DismScanHealth {
    $args = '/Online /Cleanup-Image /ScanHealth'
    return Invoke-LoggedCommand -FilePath (Join-Path (Get-NativeSystem32) 'dism.exe') -Arguments $args -OutputEncodingName OEM
}

function Invoke-SystemFileChecker {
    # sfc.exe lives in System32; don't rely on PATH.
    return Invoke-LoggedCommand -FilePath (Join-Path (Get-NativeSystem32) 'sfc.exe') -Arguments '/scannow' -OutputEncodingName Unicode
}

function Clear-WorkState {
    if ($script:MountedIso) {
        try {
            Dismount-DiskImage -ImagePath $script:MountedIso | Out-Null
            Write-Log "ISO unmounted: $($script:MountedIso)"
        } catch {
            Write-Log "ISO unmount skipped or failed: $_" 'Yellow'
        }
        $script:MountedIso = $null
    }
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        try {
            Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction Stop
            Write-Log "Removed temporary work directory."
        } catch {
            Write-Log "Could not remove temporary work directory $($script:WorkDir): $_" 'Yellow'
        }
    }
}

function Show-HelpAndExit {
    $path = $PSCommandPath
    if ($path) {
        try { Get-Help $path -Full | Out-Host } catch { Get-Help $path | Out-Host }
    } else {
        Write-Host 'Repair-WindowsStore.ps1  -CheckOnly | -ScanOnly | -IsoPath <iso> | -SourcePath <path>'
    }
    exit 0
}

# --- main ---
try {
    if ($Help) { Show-HelpAndExit }

    Write-Banner

    $os = Get-OsInfo
    $isAdmin = Test-IsAdministrator
    $needsAdmin = -not $CheckOnly -and -not $WhatIfPreference

    if ($needsAdmin -and -not $isAdmin) {
        Write-Host 'Administrator approval is required for DISM and SFC. A UAC prompt will appear.' -ForegroundColor Yellow
        if (Request-Elevation) { exit 0 }
        $script:ExitCode = 3
        if (-not $NoPause) { Write-Host 'Press Enter to close...'; [void][Console]::ReadLine() }
        exit 3
    }

    Initialize-Log
    Write-OsInfo -Info $os
    Write-Log ("Log file: {0}" -f $script:LogPath) 'Gray'

    if ($IsoPath) {
        if (-not (Test-Path -LiteralPath $IsoPath)) {
            Write-Log "ISO not found: $IsoPath" 'Red'
            $script:ExitCode = 4
            exit 4
        }
    }
    if ($SourcePath) {
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            Write-Log "Source path not found: $SourcePath" 'Red'
            $script:ExitCode = 4
            exit 4
        }
    }

    $cbs = Get-CbsCorruptionReport
    if ($CheckOnly -or $WhatIfPreference) {
        Write-CbsReport -Report $cbs
        if ($cbs.LooksLikeNetFx -or $OpenCatalog) {
            $url = Get-CatalogSearchUrl -OsInfo $os -Report $cbs
            Write-Log "Suggested Microsoft Update Catalog search:" 'Cyan'
            Write-Log "  $url"
        }
        if ($OpenCatalog) {
            $url = Get-CatalogSearchUrl -OsInfo $os -Report $cbs
            Write-Log "Opening catalog search in your default browser..."
            Start-Process $url | Out-Null
        }
        if ($WhatIfPreference) {
            Write-Host ''
            Write-Log 'WhatIf: planned actions (nothing will be changed):' 'Cyan'
            if ($ScanOnly) {
                Write-Log '  - DISM /Online /Cleanup-Image /ScanHealth'
            } else {
                Write-Log '  - DISM /Online /Cleanup-Image /RestoreHealth  (Windows Update as the source)'
                Write-Log '  - If that fails with 0x800f081f, parse CBS.log and retry with -IsoPath / -SourcePath if provided'
                if ($IsoPath) { Write-Log "  - ISO source: $IsoPath" }
                if ($SourcePath) { Write-Log "  - Package/folder source: $SourcePath (expand .msu/.cab if needed; do not install)" }
                if (-not $SkipSfc) { Write-Log '  - sfc /scannow' }
            }
            Write-Log '  - Never reboot, never install updates, never change Windows Update settings'
        } else {
            Write-Host ''
            Write-Log 'CheckOnly: no repair was started and no administrator prompt was used.' 'Green'
            Write-Log 'To scan:  .\Repair-WindowsStore.ps1 -ScanOnly'
            Write-Log 'To repair from Windows Update:  .\Repair-WindowsStore.ps1'
            Write-Log "To repair from an ISO:  .\Repair-WindowsStore.ps1 -IsoPath 'D:\Windows.iso'"
            Write-Log "To repair from a .msu/.cab/folder:  .\Repair-WindowsStore.ps1 -SourcePath 'C:\Path\package.msu'"
        }
        $script:ExitCode = 0
        exit 0
    }

    if ($OpenCatalog) {
        $url = Get-CatalogSearchUrl -OsInfo $os -Report $cbs
        Write-Log "Opening catalog search: $url"
        Start-Process $url | Out-Null
    }

    if ($ScanOnly) {
        if ($PSCmdlet.ShouldProcess('this computer', 'DISM /Online /Cleanup-Image /ScanHealth')) {
            $code = Invoke-DismScanHealth
            if ($code -eq 0) {
                Write-Log 'DISM ScanHealth completed successfully. No component-store repair was requested.' 'Green'
            } else {
                Write-Log "DISM ScanHealth ended with code $code. Review the log and, if appropriate, re-run without -ScanOnly." 'Yellow'
                Write-CbsReport -Report (Get-CbsCorruptionReport)
                $script:ExitCode = 5
            }
        }
        exit $script:ExitCode
    }

    $dismCode = 0
    if ($PSCmdlet.ShouldProcess('this computer', 'DISM /Online /Cleanup-Image /RestoreHealth (Windows Update source)')) {
        Write-Log 'Starting DISM RestoreHealth using Windows Update as the source. This can take 15-30 minutes or longer...'
        $dismCode = Invoke-DismRestoreHealth
    }

    $sourceMissing = (Test-IsSourceMissingExitCode -Code $dismCode) -or (Test-LogContainsSourceMissing)
    if ($dismCode -eq 0) {
        Write-Log 'DISM RestoreHealth completed successfully.' 'Green'
    } elseif ($sourceMissing) {
        Write-Log 'DISM RestoreHealth failed with 0x800f081f (source files not found).' 'Yellow'
        $cbs = Get-CbsCorruptionReport
        Write-CbsReport -Report $cbs

        $retrySources = @()
        try {
            if ($IsoPath) {
                if ($PSCmdlet.ShouldProcess($IsoPath, 'Mount ISO and use it as a DISM source')) {
                    $spec = Get-IsoRepairSource -Path $IsoPath -OsInfo $os
                    $retrySources += $spec
                }
            }
            if ($SourcePath) {
                if ($PSCmdlet.ShouldProcess($SourcePath, 'Use as a DISM source (expand if .msu/.cab, do not install)')) {
                    $item = Get-Item -LiteralPath $SourcePath
                    $ext = $item.Extension.ToLowerInvariant()
                    if (-not $item.PSIsContainer -and ($ext -eq '.wim' -or $ext -eq '.esd')) {
                        # Treat like an ISO image file: pick edition index.
                        $img = $item.FullName
                        $type = $ext.Trim('.')
                        $index = $null
                        foreach ($i in @(Get-WindowsImage -ImagePath $img)) {
                            $d = Get-WindowsImage -ImagePath $img -Index $i.ImageIndex
                            if ($d.EditionId -eq $os.EditionId) { $index = [int]$i.ImageIndex; break }
                        }
                        if (-not $index) { throw "Could not match EditionID '$($os.EditionId)' in $img" }
                        $retrySources += ('{0}:{1}:{2}' -f $type, $img, $index)
                    } else {
                        $retrySources += @(Get-PackageRepairSources -Path $SourcePath)
                    }
                }
            }
        } catch {
            Write-Log "Failed to prepare a local source: $_" 'Red'
        }

        if ($retrySources.Count -gt 0) {
            Write-Log ('Retrying DISM RestoreHealth with a local source ({0})...' -f ($retrySources -join ', '))
            if ($PSCmdlet.ShouldProcess('this computer', 'DISM RestoreHealth /Source /LimitAccess')) {
                $dismCode = Invoke-DismRestoreHealth -SourceSpecs $retrySources -LimitAccess
                if ($dismCode -eq 0) {
                    $sourceMissing = $false
                    Write-Log 'DISM RestoreHealth completed successfully using the local source.' 'Green'
                } else {
                    Write-Log "DISM RestoreHealth with a local source ended with code $dismCode." 'Red'
                    $cbs = Get-CbsCorruptionReport
                    Write-CbsReport -Report $cbs
                }
            }
        } else {
            Write-SourceGuidance -OsInfo $os -Report $cbs
        }
    } else {
        Write-Log "DISM RestoreHealth ended with code $dismCode. See $script:LogPath and $env:SystemRoot\Logs\DISM\dism.log" 'Red'
        $cbs = Get-CbsCorruptionReport
        Write-CbsReport -Report $cbs
        $script:ExitCode = 5
    }

    if ($dismCode -ne 0 -and $sourceMissing) {
        $script:ExitCode = 2
    } elseif ($dismCode -ne 0 -and $script:ExitCode -eq 0) {
        $script:ExitCode = 5
    }

    if (-not $SkipSfc) {
        if ($PSCmdlet.ShouldProcess('this computer', 'sfc /scannow')) {
            Write-Log 'Running sfc /scannow. This can take 10-20 minutes...'
            $sfcCode = Invoke-SystemFileChecker
            # SFC: 0 = no integrity issues, or often 0 after a successful repair as well.
            # A non-zero code is treated as a warning unless the output already said it failed.
            if ($sfcCode -eq 0) {
                Write-Log 'SFC finished (exit code 0).' 'Green'
            } else {
                Write-Log "SFC finished with exit code $sfcCode. Read the SFC section of the log and $env:SystemRoot\Logs\CBS\CBS.log" 'Yellow'
                if ($script:ExitCode -eq 0) { $script:ExitCode = 6 }
            }
        }
    } else {
        Write-Log 'Skipping sfc /scannow because -SkipSfc was specified.'
    }

    if ($script:ExitCode -eq 0) {
        Write-Log 'Done. No reboot was requested.' 'Green'
    } else {
        Write-Log "Finished with exit code $($script:ExitCode). No reboot was requested." 'Yellow'
    }
    Write-Log "Log: $script:LogPath" 'Gray'
    exit $script:ExitCode
}
catch {
    Write-Log "Unexpected error: $_" 'Red'
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace 'DarkGray' }
    $script:ExitCode = 1
    exit 1
}
finally {
    Clear-WorkState
    if (-not $NoPause -and -not $CheckOnly) {
        if (-not $Help) {
            Write-Host ''
            Write-Host 'Press Enter to close...'
            try { [void][Console]::ReadLine() } catch { }
        }
    }
}
