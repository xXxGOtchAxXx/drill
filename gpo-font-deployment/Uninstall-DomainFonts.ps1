<#
.SYNOPSIS
    Removes machine-wide fonts previously installed by Install-DomainFonts.ps1.

.DESCRIPTION
    Deletes the HKLM font registration and the file in %WINDIR%\Fonts for each
    file name listed in -FontFileName. Deploy it the same way as the install
    script (GPO computer startup script) when you need to pull the fonts back,
    then unlink the deployment GPO once the fleet has rebooted twice.

    A font file that is currently loaded cannot be deleted; the registry entry is
    removed first, so the font disappears for users at the next boot either way.

.EXAMPLE
    .\Uninstall-DomainFonts.ps1 -FontFileName al-mohanad.ttf,al-mohanad-bold.ttf
#>
#Requires -Version 3.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $FontFileName,
    [string]   $LogPath = "$env:WINDIR\Temp\Deploy-Fonts.log"
)

$ErrorActionPreference = 'Stop'
$FontsRegKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

Write-Log ('=' * 72)
Write-Log ("Font removal started on {0}" -f $env:COMPUTERNAME)

$baseKey  = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
$fontsKey = $baseKey.OpenSubKey($FontsRegKey, $true)
if (-not $fontsKey) {
    Write-Log "Cannot open HKLM\$FontsRegKey for writing. Are you elevated / SYSTEM?" 'ERROR'
    exit 1
}

$fontDir = Join-Path $env:WINDIR 'Fonts'
foreach ($name in $FontFileName) {
    $leaf = Split-Path -Path $name -Leaf

    foreach ($valueName in @($fontsKey.GetValueNames())) {
        $data = $fontsKey.GetValue($valueName, '')
        if ("$data" -ieq $leaf) {
            $fontsKey.DeleteValue($valueName, $false)
            Write-Log ("Removed registry value '{0}'" -f $valueName)
        }
    }

    $path = Join-Path $fontDir $leaf
    if (Test-Path -LiteralPath $path) {
        try {
            Remove-Item -LiteralPath $path -Force
            Write-Log ("Deleted {0}" -f $path)
        } catch {
            Write-Log ("{0} is in use, it will be gone after the next reboot: {1}" -f $path, $_.Exception.Message) 'WARN'
        }
    } else {
        Write-Log ("{0} not present, nothing to delete" -f $path)
    }
}

$fontsKey.Close()
$baseKey.Close()
Write-Log 'Font removal finished.'
exit 0
