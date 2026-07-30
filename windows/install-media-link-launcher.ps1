[CmdletBinding()]
param(
    [string]$VlcPath,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProtocolScheme = 'media-link-launcher'
$script:Version = '0.2.0'

function Write-Utf8WithoutBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )
    [System.IO.File]::WriteAllText(
        $Path,
        $Value,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Protect-DirectoryForCurrentUser {
    param([Parameter(Mandatory = $true)][string]$Path)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = $identity.User
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $inheritance = (
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    )
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetOwner($userSid)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($userSid, $systemSid, $administratorsSid)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow
        )
        [void]$security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Confirm-SafeDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Create,
        [switch]$Protect
    )
    if (Test-ReparsePoint -Path $Path) {
        throw "Refusing to use a reparse-point directory: $Path"
    }
    $created = $false
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "The required directory path is occupied by a file: $Path"
        }
    }
    elseif ($Create) {
        [void](New-Item -ItemType Directory -Path $Path)
        $created = $true
    }
    else {
        throw "Required directory does not exist: $Path"
    }
    if ($Protect -and $created) {
        Protect-DirectoryForCurrentUser -Path $Path
    }
}

function Find-VlcExecutable {
    param([AllowNull()][string]$RequestedPath)
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates.Add($RequestedPath)
    }

    foreach ($registryPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe'
    )) {
        if (Test-Path -LiteralPath $registryPath) {
            $candidate = (Get-Item -LiteralPath $registryPath).GetValue('')
            if ($candidate) {
                $candidates.Add([string]$candidate)
            }
        }
    }

    foreach ($base in @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        (Join-Path $env:LOCALAPPDATA 'Programs')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($base)) {
            $candidates.Add((Join-Path $base 'VideoLAN\VLC\vlc.exe'))
        }
    }

    $command = Get-Command 'vlc.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        $candidates.Add($command.Source)
    }

    foreach ($candidate in $candidates) {
        try {
            $fullPath = [System.IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($candidate.Trim().Trim('"'))
            )
            if (
                [System.IO.Path]::GetExtension($fullPath) -ieq '.exe' -and
                (Test-Path -LiteralPath $fullPath -PathType Leaf)
            ) {
                return (Get-Item -LiteralPath $fullPath).FullName
            }
        }
        catch {
        }
    }
    throw 'VLC media player was not found. Install VLC first, or run the installer with -VlcPath "C:\path\to\vlc.exe".'
}

function Copy-FileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $temporary = $Destination + '.new-' + [Guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Invoke-Installation {
    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'Media Link Launcher for Windows requires Windows 10 or Windows 11.'
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable.'
    }

    $sourceDirectory = Split-Path -Parent $PSCommandPath
    $handlerSource = Join-Path $sourceDirectory 'media-link-launcher.ps1'
    foreach ($required in @(
        $handlerSource,
        (Join-Path $sourceDirectory 'LICENSE.md'),
        (Join-Path $sourceDirectory 'DISCLAIMER.md')
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "A required package file is missing: $required"
        }
        if (Test-ReparsePoint -Path $required) {
            throw "A required package file must not be a reparse point: $required"
        }
    }

    $resolvedVlcPath = Find-VlcExecutable -RequestedPath $VlcPath
    $baseDirectory = Join-Path $env:LOCALAPPDATA 'MediaLinkLauncher'
    $applicationDirectory = Join-Path $baseDirectory 'App'
    $configDirectory = Join-Path $baseDirectory 'Config'
    $stateDirectory = Join-Path $baseDirectory 'State'

    Confirm-SafeDirectory -Path $baseDirectory -Create -Protect
    Confirm-SafeDirectory -Path $applicationDirectory -Create
    Confirm-SafeDirectory -Path $configDirectory -Create
    Confirm-SafeDirectory -Path $stateDirectory -Create

    $protocolKey = 'HKCU:\Software\Classes\' + $script:ProtocolScheme
    if (Test-Path -LiteralPath $protocolKey) {
        $existingMarker = (Get-Item -LiteralPath $protocolKey).GetValue('MediaLinkLauncherInstallPath')
        if (
            -not $Force -and
            (-not $existingMarker -or $existingMarker -ne $applicationDirectory)
        ) {
            throw 'Another application already owns the media-link-launcher protocol. Nothing was overwritten. Review it and rerun with -Force only if replacement is intentional.'
        }
    }

    $installedHandler = Join-Path $applicationDirectory 'media-link-launcher.ps1'
    Copy-FileAtomically -Source $handlerSource -Destination $installedHandler
    Copy-FileAtomically -Source (Join-Path $sourceDirectory 'LICENSE.md') -Destination (Join-Path $applicationDirectory 'LICENSE.md')
    Copy-FileAtomically -Source (Join-Path $sourceDirectory 'DISCLAIMER.md') -Destination (Join-Path $applicationDirectory 'DISCLAIMER.md')
    Write-Utf8WithoutBom -Path (Join-Path $applicationDirectory 'vlc-path.txt') -Value ($resolvedVlcPath + [Environment]::NewLine)
    Write-Utf8WithoutBom -Path (Join-Path $applicationDirectory 'version.txt') -Value ($script:Version + [Environment]::NewLine)

    $allowedSchemesPath = Join-Path $configDirectory 'allowed-schemes'
    if (-not (Test-Path -LiteralPath $allowedSchemesPath)) {
        Write-Utf8WithoutBom -Path $allowedSchemesPath -Value (
            '# One target protocol per line. Optional protocols require explicit review.' +
            [Environment]::NewLine + 'http' + [Environment]::NewLine + 'https' +
            [Environment]::NewLine
        )
    }
    $loggingPath = Join-Path $configDirectory 'logging'
    if (-not (Test-Path -LiteralPath $loggingPath)) {
        Write-Utf8WithoutBom -Path $loggingPath -Value (
            '# Persistent redacted event logging is disabled by default.' +
            [Environment]::NewLine + 'disabled' + [Environment]::NewLine
        )
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 was not found.'
    }
    $command = (
        '"' + $windowsPowerShell +
        '" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
        $installedHandler + '" "%1"'
    )

    [void](New-Item -Path $protocolKey -Force)
    Set-Item -LiteralPath $protocolKey -Value 'URL:Media Link Launcher Protocol'
    [void](New-ItemProperty -LiteralPath $protocolKey -Name 'URL Protocol' -Value '' -PropertyType String -Force)
    [void](New-ItemProperty -LiteralPath $protocolKey -Name 'MediaLinkLauncherInstallPath' -Value $applicationDirectory -PropertyType String -Force)
    [void](New-ItemProperty -LiteralPath $protocolKey -Name 'MediaLinkLauncherVersion' -Value $script:Version -PropertyType String -Force)

    $iconKey = Join-Path $protocolKey 'DefaultIcon'
    [void](New-Item -Path $iconKey -Force)
    Set-Item -LiteralPath $iconKey -Value ($resolvedVlcPath + ',0')

    $commandKey = Join-Path $protocolKey 'shell\open\command'
    [void](New-Item -Path $commandKey -Force)
    Set-Item -LiteralPath $commandKey -Value $command

    $recordedCommand = (Get-Item -LiteralPath $commandKey).GetValue('')
    if ($recordedCommand -ne $command) {
        throw 'Protocol registration verification failed.'
    }

    Write-Host ''
    Write-Host 'Media Link Launcher was installed for this Windows account.' -ForegroundColor Green
    Write-Host ('VLC: ' + $resolvedVlcPath)
    Write-Host ('Handler: ' + $installedHandler)
    Write-Host ''
    Write-Host 'Next: install media-link-launcher.user.js in Tampermonkey.'
    Write-Host 'The same userscript file is used on Linux and Windows.'
}

try {
    Invoke-Installation
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'Installation stopped safely.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}