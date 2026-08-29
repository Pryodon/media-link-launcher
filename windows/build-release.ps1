[CmdletBinding()]
param(
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$version = '0.2.1'
$topLevel = 'media-link-launcher-windows'
$sourceDirectory = Split-Path -Parent $PSCommandPath
$repositoryRoot = Split-Path -Parent $sourceDirectory
$repositoryUserscriptDirectory = Join-Path $repositoryRoot 'userscript'
$repositoryUserscript = Join-Path $repositoryUserscriptDirectory 'media-link-launcher.user.js'
$repositoryLayout = ((Split-Path -Leaf $sourceDirectory) -eq 'windows') -and (Test-Path -LiteralPath $repositoryUserscript -PathType Leaf)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repositoryRoot ("media-link-launcher-windows-{0}.zip" -f $version)
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

$releaseFiles = @(
    'README.md',
    'LICENSE.md',
    'DISCLAIMER.md',
    'CHANGELOG.md',
    'install-media-link-launcher.cmd',
    'install-media-link-launcher.ps1',
    'uninstall-media-link-launcher.cmd',
    'uninstall-media-link-launcher.ps1',
    'media-link-launcher.user.js',
    'media-link-launcher.ps1',
    'USERSCRIPT-SHA256.txt',
    'build-release.ps1',
    'tests\test-media-link-launcher.ps1'
)

function Get-ReleaseSourcePath {
    param([string]$RelativePath)

    if (-not $repositoryLayout) {
        return Join-Path $sourceDirectory $RelativePath
    }

    if ($RelativePath -eq 'LICENSE.md' -or $RelativePath -eq 'DISCLAIMER.md') {
        return Join-Path $repositoryRoot $RelativePath
    }
    if ($RelativePath -eq 'media-link-launcher.user.js') {
        return $repositoryUserscript
    }
    if ($RelativePath -eq 'USERSCRIPT-SHA256.txt') {
        return Join-Path $repositoryUserscriptDirectory $RelativePath
    }
    return Join-Path $sourceDirectory $RelativePath
}

$expectedUserscriptHashPath = Get-ReleaseSourcePath 'USERSCRIPT-SHA256.txt'
$expectedUserscriptHashLine = ([System.IO.File]::ReadAllText($expectedUserscriptHashPath)).Trim()
if ($expectedUserscriptHashLine -notmatch '^([0-9A-Fa-f]{64})  media-link-launcher\.user\.js$') {
    throw 'The shared userscript checksum is malformed.'
}
$expectedUserscriptHash = $Matches[1].ToUpperInvariant()
$actualUserscriptHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Get-ReleaseSourcePath 'media-link-launcher.user.js')).Hash
if ($actualUserscriptHash -ne $expectedUserscriptHash) {
    throw 'The shared userscript checksum is stale; the release was not built.'
}

foreach ($relativePath in $releaseFiles) {
    if ([System.IO.Path]::IsPathRooted($relativePath) -or $relativePath.Contains('..')) {
        throw "Unsafe release path: $relativePath"
    }
    $sourcePath = Get-ReleaseSourcePath $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Missing release file: $relativePath ($sourcePath)"
    }
    $item = Get-Item -LiteralPath $sourcePath -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Release files must not be reparse points: $relativePath"
    }
}

$destinationDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $destinationDirectory)
}
$tempPath = Join-Path $destinationDirectory (([System.IO.Path]::GetFileName($OutputPath)) + '.new-' + [Guid]::NewGuid().ToString('N'))

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$timestamp = New-Object DateTimeOffset(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

try {
    $fileStream = New-Object System.IO.FileStream(
        $tempPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $archive = New-Object System.IO.Compression.ZipArchive(
            $fileStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $true
        )
        try {
            foreach ($relativePath in ($releaseFiles | Sort-Object)) {
                $sourcePath = Get-ReleaseSourcePath $relativePath
                $entryPath = ($topLevel + '/' + $relativePath.Replace('\', '/'))
                $entry = $archive.CreateEntry($entryPath, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $timestamp
                $entryStream = $entry.Open()
                try {
                    $inputStream = [System.IO.File]::OpenRead($sourcePath)
                    try {
                        $inputStream.CopyTo($entryStream)
                    }
                    finally {
                        $inputStream.Dispose()
                    }
                }
                finally {
                    $entryStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }

    Move-Item -LiteralPath $tempPath -Destination $OutputPath -Force
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }
}

$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath).Hash.ToLowerInvariant()
Write-Host ('Created: ' + $OutputPath) -ForegroundColor Green
Write-Host ('SHA-256: ' + $zipHash)
