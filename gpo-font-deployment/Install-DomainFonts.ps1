<#
.SYNOPSIS
    Installs fonts machine-wide (all users) on domain computers.

.DESCRIPTION
    Copies every font found in -SourcePath into %WINDIR%\Fonts and registers it
    under HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts, which is what
    makes a font visible to every user who logs on to the machine (Word, Excel,
    PowerPoint, Photoshop, browsers, ...).

    Designed to run as a Group Policy computer STARTUP script (runs as SYSTEM),
    but it is safe to run by hand from an elevated prompt. It is idempotent: on
    every boot it only copies a file whose hash differs from the installed copy,
    and it repairs a missing registry entry.

    The registry value name must match the font's internal name, so the script
    reads the font's "name" table out of the file itself instead of guessing
    from the file name.

.PARAMETER SourcePath
    Folder holding the .ttf/.ttc/.otf files. Defaults to the folder this script
    sits in (i.e. the GPO's own Startup folder in SYSVOL), then falls back to
    \\<dns-domain>\NETLOGON\Fonts.

.PARAMETER ReportOnly
    Installs nothing. Prints the exact registry value name and data for each
    font, for when you want to configure Group Policy Preferences by hand.
    Run this one on your admin workstation against the folder holding the fonts.

.EXAMPLE
    .\Install-DomainFonts.ps1 -SourcePath "I:\ad font" -ReportOnly

.EXAMPLE
    .\Install-DomainFonts.ps1 -SourcePath "\\corp.example.com\NETLOGON\Fonts"

.NOTES
    Exit code 0 = everything installed / already current, 1 = at least one font
    failed (see the log). Log defaults to %WINDIR%\Temp\Deploy-Fonts.log.
#>
#Requires -Version 3.0
[CmdletBinding()]
param(
    [string]   $SourcePath,
    [string[]] $Include  = @('*.ttf', '*.ttc', '*.otf'),
    [string]   $LogPath  = "$env:WINDIR\Temp\Deploy-Fonts.log",
    [switch]   $ReportOnly
)

$ErrorActionPreference = 'Stop'
$FontsRegKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$failures    = 0

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')

    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
    if ($LogPath) {
        try {
            $dir = Split-Path -Path $LogPath -Parent
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
        } catch {
            # Never let logging break the deployment.
        }
    }
}

#-------------------------------------------------------------------- font name
function Get-BEUInt16 {
    param([byte[]]$Bytes, [int]$Offset)
    return ([int]$Bytes[$Offset] -shl 8) -bor [int]$Bytes[$Offset + 1]
}

function Get-BEUInt32 {
    param([byte[]]$Bytes, [int]$Offset)
    return ([int]$Bytes[$Offset]     -shl 24) -bor ([int]$Bytes[$Offset + 1] -shl 16) -bor `
           ([int]$Bytes[$Offset + 2] -shl  8) -bor  [int]$Bytes[$Offset + 3]
}

function Get-FontDisplayName {
    <#
        Returns the human-readable font name from the OpenType/TrueType 'name'
        table: name ID 4 (full name) when present, otherwise family (1) plus
        subfamily (2). English (0x0409) records win over localized ones, so an
        Arabic font still gets its Latin name in the registry, which is what
        Windows itself writes.
    #>
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 12) { return $null }

    $base = 0
    $tag  = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    if ($tag -eq 'ttcf') {
        # TrueType collection: use the first font in the collection.
        $base = Get-BEUInt32 $bytes 12
    }

    $numTables = Get-BEUInt16 $bytes ($base + 4)
    $nameOff   = 0
    for ($i = 0; $i -lt $numTables; $i++) {
        $rec = $base + 12 + ($i * 16)
        if ($rec + 16 -gt $bytes.Length) { break }
        if ([System.Text.Encoding]::ASCII.GetString($bytes, $rec, 4) -eq 'name') {
            $nameOff = Get-BEUInt32 $bytes ($rec + 8)
            break
        }
    }
    if ($nameOff -le 0 -or $nameOff + 6 -gt $bytes.Length) { return $null }

    $count      = Get-BEUInt16 $bytes ($nameOff + 2)
    $stringBase = $nameOff + (Get-BEUInt16 $bytes ($nameOff + 4))

    $best = @{}   # nameID -> @{ Score; Value }
    for ($i = 0; $i -lt $count; $i++) {
        $rec = $nameOff + 6 + ($i * 12)
        if ($rec + 12 -gt $bytes.Length) { break }

        $platform = Get-BEUInt16 $bytes  $rec
        $language = Get-BEUInt16 $bytes ($rec + 4)
        $nameId   = Get-BEUInt16 $bytes ($rec + 6)
        $length   = Get-BEUInt16 $bytes ($rec + 8)
        $offset   = Get-BEUInt16 $bytes ($rec + 10)

        if ($nameId -ne 1 -and $nameId -ne 2 -and $nameId -ne 4) { continue }
        $start = $stringBase + $offset
        if ($length -le 0 -or $start + $length -gt $bytes.Length) { continue }

        $encoding = switch ($platform) {
            3       { [System.Text.Encoding]::BigEndianUnicode }
            0       { [System.Text.Encoding]::BigEndianUnicode }
            1       { [System.Text.Encoding]::ASCII }
            default { $null }
        }
        if (-not $encoding) { continue }

        $value = $encoding.GetString($bytes, $start, $length).Trim(@([char]0, [char]32, [char]9, [char]10, [char]13))
        if (-not $value) { continue }

        $score = switch ($platform) { 3 { 40 } 0 { 20 } 1 { 10 } default { 0 } }
        if ($language -eq 0x0409 -or $language -eq 0) { $score += 5 }

        if (-not $best.ContainsKey($nameId) -or $score -gt $best[$nameId].Score) {
            $best[$nameId] = @{ Score = $score; Value = $value }
        }
    }

    if ($best.ContainsKey(4)) { return $best[4].Value }
    if ($best.ContainsKey(1)) {
        $family = $best[1].Value
        if ($best.ContainsKey(2) -and $best[2].Value -and $best[2].Value -ne 'Regular') {
            return ('{0} {1}' -f $family, $best[2].Value)
        }
        return $family
    }
    return $null
}

function Get-FontRegistrySuffix {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.otf'  { '(OpenType)' }
        default { '(TrueType)' }
    }
}

#------------------------------------------------------------------- native API
function Register-FontWithSession {
    param([string]$Path)

    if (-not ('FontDeploy.Native' -as [type])) {
        Add-Type -Namespace FontDeploy -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("gdi32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern int AddFontResourceW(string fileName);

[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam, uint flags, uint timeout, out System.IntPtr result);
'@
    }

    [void][FontDeploy.Native]::AddFontResourceW($Path)

    $HWND_BROADCAST = [System.IntPtr]0xFFFF
    $WM_FONTCHANGE  = 0x001D
    $SMTO_ABORTIFHUNG = 0x0002
    $out = [System.IntPtr]::Zero
    [void][FontDeploy.Native]::SendMessageTimeout($HWND_BROADCAST, $WM_FONTCHANGE,
        [System.IntPtr]::Zero, [System.IntPtr]::Zero, $SMTO_ABORTIFHUNG, 2000, [ref]$out)
}

#-------------------------------------------------------------------- resolving
function Resolve-SourcePath {
    param([string]$Requested, [string[]]$Patterns)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Requested) {
        $candidates.Add($Requested)
    } else {
        if ($PSScriptRoot) { $candidates.Add($PSScriptRoot) }
        $domain = $env:USERDNSDOMAIN
        if (-not $domain) {
            try {
                $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
                if ($cs.PartOfDomain) { $domain = $cs.Domain }
            } catch { }
        }
        if ($domain) { $candidates.Add("\\$domain\NETLOGON\Fonts") }
    }

    foreach ($candidate in $candidates) {
        $trimmed = $candidate.TrimEnd('\')
        if (-not $trimmed) { continue }
        if (-not (Test-Path -LiteralPath $trimmed)) {
            Write-Log "Source not reachable, skipping: $trimmed" 'WARN'
            continue
        }
        $found = @(Get-ChildItem -LiteralPath $trimmed -File -Include $Patterns -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) {
            # -Include needs a wildcard path on some versions; retry the safe way.
            $found = @(Get-ChildItem -LiteralPath $trimmed -File -ErrorAction SilentlyContinue |
                       Where-Object { $ext = $_.Extension.ToLowerInvariant(); $ext -in @('.ttf', '.ttc', '.otf') })
        }
        if ($found.Count -gt 0) { return [pscustomobject]@{ Path = $trimmed; Fonts = $found } }
        Write-Log "No font files in: $trimmed" 'WARN'
    }
    return $null
}

#------------------------------------------------------------------------- main
Write-Log ('=' * 72)
Write-Log ("Font deployment started on {0} (user: {1}\{2}, 64-bit process: {3})" -f `
    $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME, [Environment]::Is64BitProcess)

$resolved = Resolve-SourcePath -Requested $SourcePath -Patterns $Include
if (-not $resolved) {
    Write-Log 'No usable font source found. Nothing to do.' 'ERROR'
    exit 1
}
Write-Log ("Source: {0} ({1} font file(s))" -f $resolved.Path, $resolved.Fonts.Count)

if ($ReportOnly) {
    Write-Log 'ReportOnly: listing registry entries that WOULD be created.'
    $report = foreach ($font in $resolved.Fonts) {
        $display = $null
        try { $display = Get-FontDisplayName -Path $font.FullName }
        catch { Write-Log ("Could not read name table of {0}: {1}" -f $font.Name, $_.Exception.Message) 'WARN' }
        if (-not $display) { $display = [System.IO.Path]::GetFileNameWithoutExtension($font.Name) }

        [pscustomobject]@{
            File          = $font.Name
            FontName      = $display
            RegistryValue = ('{0} {1}' -f $display, (Get-FontRegistrySuffix $font.FullName))
            RegistryData  = $font.Name
        }
    }
    $report | Format-List | Out-String -Width 200 | Write-Host
    Write-Log ('Registry key: HKEY_LOCAL_MACHINE\{0}' -f $FontsRegKey)
    exit 0
}

# Always write to the 64-bit view so a 32-bit host does not land in WOW6432Node.
$baseKey  = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
$fontsKey = $baseKey.OpenSubKey($FontsRegKey, $true)
if (-not $fontsKey) {
    Write-Log "Cannot open HKLM\$FontsRegKey for writing. Are you elevated / SYSTEM?" 'ERROR'
    exit 1
}

$fontDir = Join-Path $env:WINDIR 'Fonts'

foreach ($font in $resolved.Fonts) {
    try {
        $destination = Join-Path $fontDir $font.Name

        $needCopy = $true
        if (Test-Path -LiteralPath $destination) {
            $sourceHash = (Get-FileHash -LiteralPath $font.FullName  -Algorithm SHA256).Hash
            $destHash   = (Get-FileHash -LiteralPath $destination    -Algorithm SHA256).Hash
            if ($sourceHash -eq $destHash) {
                $needCopy = $false
                Write-Log ("{0}: already up to date in {1}" -f $font.Name, $fontDir)
            } else {
                Write-Log ("{0}: installed copy differs, replacing" -f $font.Name)
            }
        }

        if ($needCopy) {
            try {
                Copy-Item -LiteralPath $font.FullName -Destination $destination -Force
                Write-Log ("{0}: copied to {1}" -f $font.Name, $destination)
            } catch {
                # A font already loaded by a running session cannot be overwritten;
                # the next boot (before user sessions exist) will succeed.
                if (Test-Path -LiteralPath $destination) {
                    Write-Log ("{0}: file is in use, keeping existing copy ({1})" -f $font.Name, $_.Exception.Message) 'WARN'
                } else {
                    throw
                }
            }
        }

        $display = $null
        try { $display = Get-FontDisplayName -Path $destination }
        catch { Write-Log ("{0}: could not read name table ({1})" -f $font.Name, $_.Exception.Message) 'WARN' }
        if (-not $display) {
            $display = [System.IO.Path]::GetFileNameWithoutExtension($font.Name)
            Write-Log ("{0}: falling back to file name as font name" -f $font.Name) 'WARN'
        }

        $valueName = '{0} {1}' -f $display, (Get-FontRegistrySuffix $destination)
        $current   = $fontsKey.GetValue($valueName, $null)
        if ($current -ne $font.Name) {
            $fontsKey.SetValue($valueName, $font.Name, [Microsoft.Win32.RegistryValueKind]::String)
            Write-Log ("{0}: registered as '{1}' = '{2}'" -f $font.Name, $valueName, $font.Name)
        } else {
            Write-Log ("{0}: registry entry '{1}' already correct" -f $font.Name, $valueName)
        }

        Register-FontWithSession -Path $destination
        Write-Log ("{0}: available to all users (font name: {1})" -f $font.Name, $display)
    } catch {
        $failures++
        Write-Log ("{0}: FAILED - {1}" -f $font.Name, $_.Exception.Message) 'ERROR'
    }
}

$fontsKey.Close()
$baseKey.Close()

if ($failures -gt 0) {
    Write-Log ("Finished with {0} failure(s)." -f $failures) 'ERROR'
    exit 1
}
Write-Log 'Finished successfully.'
exit 0
