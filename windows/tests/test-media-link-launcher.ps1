Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$packageDirectory = Split-Path -Parent $PSScriptRoot
$handlerPath = Join-Path $packageDirectory 'media-link-launcher.ps1'
. $handlerPath

$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
    $script:Passed++
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
    $script:Passed++
}

function Assert-Rejected {
    param([string]$Invocation, [string]$ExpectedCategory)
    try {
        [void](Decode-Invocation -Value $Invocation)
    }
    catch {
        $category = $_.Exception.Data['MediaLinkLauncherCategory']
        if ($category -eq $ExpectedCategory) {
            $script:Passed++
            return
        }
        throw "Unexpected rejection category. Expected=[$ExpectedCategory] Actual=[$category]"
    }
    throw "Invocation was accepted unexpectedly: $Invocation"
}

$targetText = 'https://user:pass@example.com:8443/media/file.mp4?token=a%2Bb&x=1#part'
$invocation = 'media-link-launcher://open?url=' + [Uri]::EscapeDataString($targetText)
$decoded = Decode-Invocation -Value $invocation
Assert-Equal $targetText $decoded 'Complex target did not round-trip.'
$windowsCanonicalInvocation = 'media-link-launcher://open/?url=' + [Uri]::EscapeDataString($targetText)
$windowsCanonicalDecoded = Decode-Invocation -Value $windowsCanonicalInvocation
Assert-Equal $targetText $windowsCanonicalDecoded 'Windows-canonical target did not round-trip.'

$parsed = ConvertTo-ValidatedTarget -Value $decoded -AllowedSchemes @('http', 'https')
Assert-Equal 'https' $parsed.Scheme 'Scheme mismatch.'
Assert-Equal 'example.com' $parsed.Hostname 'Hostname mismatch.'
Assert-Equal 8443 $parsed.Port 'Port mismatch.'
Assert-True $parsed.HasUsername 'Username presence was not detected.'
Assert-True $parsed.HasPassword 'Password presence was not detected.'
Assert-True $parsed.HasPath 'Path presence was not detected.'
Assert-True $parsed.HasQuery 'Query presence was not detected.'
Assert-True $parsed.HasFragment 'Fragment presence was not detected.'

Assert-Rejected 'vlc://open?url=https%3A%2F%2Fexample.com%2Fa.mp4' 'wrong_protocol'
Assert-Rejected 'media-link-launcher://OPEN?url=https%3A%2F%2Fexample.com%2Fa.mp4' 'wrong_protocol'
Assert-Rejected 'media-link-launcher://open//?url=https%3A%2F%2Fexample.com%2Fa.mp4' 'wrong_protocol'
Assert-Rejected 'media-link-launcher://open/path?url=https%3A%2F%2Fexample.com%2Fa.mp4' 'wrong_protocol'
Assert-Rejected 'media-link-launcher://open?url=' 'ambiguous_invocation'
Assert-Rejected 'media-link-launcher://open?url=https%3A%2F%2Fexample.com%2Fa.mp4&extra=1' 'ambiguous_invocation'
Assert-Rejected 'media-link-launcher://open?url=https%3A%2F%2Fexample.com%2Fa.mp4#outer' 'ambiguous_invocation'
Assert-Rejected 'media-link-launcher://open?url=https%3A%2F%2Fexample.com%2Fbad%ZZ' 'malformed_invocation'
Assert-Rejected 'media-link-launcher://open?url=https%3A%2F%2Fexample.com%2Fbad%FF' 'malformed_invocation'
Assert-Rejected 'media-link-launcher://open?url=https%3A%2F%2Fexample.com%2Fline%250A' 'invalid_target'

try {
    [void](ConvertTo-ValidatedTarget -Value 'file:///C:/secret.mp4' -AllowedSchemes @('http', 'https'))
    throw 'file: target was accepted unexpectedly.'
}
catch {
    Assert-Equal 'unsupported_scheme' $_.Exception.Data['MediaLinkLauncherCategory'] 'Wrong file: rejection.'
}

try {
    [void](ConvertTo-ValidatedTarget -Value 'https://example.com\@evil.test/a.mp4' -AllowedSchemes @('http', 'https'))
    throw 'Backslash authority was accepted unexpectedly.'
}
catch {
    Assert-Equal 'invalid_target' $_.Exception.Data['MediaLinkLauncherCategory'] 'Wrong backslash rejection.'
}

Assert-True (Test-NonGlobalAddress -Address ([System.Net.IPAddress]::Parse('127.0.0.1'))) 'Loopback should be non-global.'
Assert-True (Test-NonGlobalAddress -Address ([System.Net.IPAddress]::Parse('192.168.1.1'))) 'Private IPv4 should be non-global.'
Assert-True (-not (Test-NonGlobalAddress -Address ([System.Net.IPAddress]::Parse('8.8.8.8')))) 'Public IPv4 should be global.'

$quoted = ConvertTo-WindowsCommandLineArgument 'https://example.com/a"b\'
Assert-True ($quoted.StartsWith('"') -and $quoted.EndsWith('"')) 'Command-line argument was not quoted.'

$expectedHashPath = Join-Path $packageDirectory 'USERSCRIPT-SHA256.txt'
if (Test-Path -LiteralPath $expectedHashPath) {
    $expectedHash = ([System.IO.File]::ReadAllText($expectedHashPath)).Trim().Split(' ')[0].ToUpperInvariant()
    $userscriptPath = Join-Path $packageDirectory 'media-link-launcher.user.js'
    if (-not (Test-Path -LiteralPath $userscriptPath -PathType Leaf)) {
        $repositoryRoot = Split-Path -Parent $packageDirectory
        $userscriptPath = Join-Path (Join-Path $repositoryRoot 'userscript') 'media-link-launcher.user.js'
    }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $userscriptPath).Hash
    Assert-Equal $expectedHash $actualHash 'Userscript hash mismatch.'
}

Write-Host ("Passed {0} Windows handler checks." -f $script:Passed) -ForegroundColor Green
