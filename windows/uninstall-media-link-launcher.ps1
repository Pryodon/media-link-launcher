[CmdletBinding()]
param(
    [switch]$RemoveSettings
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Confirm-NoReparsePointsBelow {
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to remove a directory containing a reparse point: $($item.FullName)"
        }
    }
}

function Invoke-Uninstallation {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable.'
    }
    $baseDirectory = Join-Path $env:LOCALAPPDATA 'MediaLinkLauncher'
    $applicationDirectory = Join-Path $baseDirectory 'App'
    $protocolKey = 'HKCU:\Software\Classes\media-link-launcher'

    if (Test-Path -LiteralPath $protocolKey) {
        $marker = (Get-Item -LiteralPath $protocolKey).GetValue('MediaLinkLauncherInstallPath')
        if ($marker -eq $applicationDirectory) {
            Remove-Item -LiteralPath $protocolKey -Recurse -Force
            Write-Host 'Removed the per-user media-link-launcher protocol registration.'
        }
        else {
            Write-Host 'The protocol registration is not owned by this installation and was left unchanged.'
        }
    }
    else {
        Write-Host 'The protocol registration was already absent.'
    }

    if (Test-Path -LiteralPath $applicationDirectory) {
        if (Test-ReparsePoint -Path $applicationDirectory) {
            throw 'Refusing to remove a reparse-point application directory.'
        }
        $expectedApplicationDirectory = Join-Path $env:LOCALAPPDATA 'MediaLinkLauncher\App'
        if ([System.IO.Path]::GetFullPath($applicationDirectory) -ne [System.IO.Path]::GetFullPath($expectedApplicationDirectory)) {
            throw 'The application directory did not match the expected path.'
        }
        Confirm-NoReparsePointsBelow -Path $applicationDirectory
        Remove-Item -LiteralPath $applicationDirectory -Recurse -Force
        Write-Host 'Removed the installed handler.'
    }

    if ($RemoveSettings -and (Test-Path -LiteralPath $baseDirectory)) {
        if (Test-ReparsePoint -Path $baseDirectory) {
            throw 'Refusing to remove a reparse-point settings directory.'
        }
        $expectedBaseDirectory = Join-Path $env:LOCALAPPDATA 'MediaLinkLauncher'
        if ([System.IO.Path]::GetFullPath($baseDirectory) -ne [System.IO.Path]::GetFullPath($expectedBaseDirectory)) {
            throw 'The settings directory did not match the expected path.'
        }
        Confirm-NoReparsePointsBelow -Path $baseDirectory
        Remove-Item -LiteralPath $baseDirectory -Recurse -Force
        Write-Host 'Removed configuration, state, and optional logs.'
    }
    elseif (Test-Path -LiteralPath $baseDirectory) {
        Write-Host ('Retained configuration and state in: ' + $baseDirectory)
    }

    Write-Host 'Remove or disable the Tampermonkey userscript separately.'
}

try {
    Invoke-Uninstallation
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'Uninstallation stopped safely.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}