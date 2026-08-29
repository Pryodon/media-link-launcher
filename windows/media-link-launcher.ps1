[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string]$InvocationUri,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Version = '0.2.1'
$script:ProjectId = 'MediaLinkLauncher'
$script:ProtocolScheme = 'media-link-launcher'
$script:ProtocolAction = 'open'
$script:SupportedSchemes = @(
    'http', 'https', 'ftp', 'ftps', 'sftp', 'smb', 'rtsp', 'rtsps',
    'rtmp', 'rtmps', 'mms', 'mmsh', 'mmst', 'rtp', 'udp'
)
$script:DefaultAllowedSchemes = @('http', 'https')
$script:MaximumInvocationLength = 32768
$script:MaximumTargetLength = 16384
$script:MinimumPromptIntervalSeconds = 3.0
$script:PromptTimeoutSeconds = 120
$script:LocalHostSuffixes = @('.localhost', '.local', '.lan', '.home', '.internal')

$script:ApplicationDirectory = Split-Path -Parent $PSCommandPath
$script:BaseDirectory = Split-Path -Parent $script:ApplicationDirectory
$script:ConfigDirectory = Join-Path $script:BaseDirectory 'Config'
$script:StateDirectory = Join-Path $script:BaseDirectory 'State'

function New-HandlerException {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Category,
        [switch]$Quiet
    )

    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['MediaLinkLauncherCategory'] = $Category
    $exception.Data['MediaLinkLauncherQuiet'] = [bool]$Quiet
    return $exception
}

function Throw-HandlerError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Category,
        [switch]$Quiet
    )
    throw (New-HandlerException -Message $Message -Category $Category -Quiet:$Quiet)
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Confirm-SafeDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Create
    )

    if (Test-ReparsePoint -Path $Path) {
        Throw-HandlerError 'A Media Link Launcher directory must not be a reparse point.' 'unsafe_state'
    }
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Throw-HandlerError 'A Media Link Launcher directory path is not a directory.' 'unsafe_state'
        }
        return
    }
    if ($Create) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
    }
}

function Read-SmallRegularFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int64]$MaximumBytes,
        [switch]$Optional
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Optional) {
            return $null
        }
        Throw-HandlerError 'A required Media Link Launcher file is missing.' 'missing_file'
    }
    if (Test-ReparsePoint -Path $Path) {
        Throw-HandlerError 'A Media Link Launcher file must not be a reparse point.' 'unsafe_config'
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or $item.Length -gt $MaximumBytes) {
        Throw-HandlerError 'A Media Link Launcher file is invalid or too large.' 'invalid_config'
    }
    return [System.IO.File]::ReadAllText($item.FullName, [System.Text.Encoding]::UTF8)
}

function Get-AllowedSchemes {
    $path = Join-Path $script:ConfigDirectory 'allowed-schemes'
    $text = Read-SmallRegularFile -Path $path -MaximumBytes 4096 -Optional
    if ($null -eq $text) {
        return $script:DefaultAllowedSchemes
    }

    $configured = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in ($text -split "`r?`n")) {
        $value = $line.Split('#', 2)[0].Trim().ToLowerInvariant()
        if ($value.Length -eq 0) {
            continue
        }
        if ($script:SupportedSchemes -notcontains $value) {
            Throw-HandlerError 'The allowed-schemes configuration contains an unsupported value.' 'invalid_config'
        }
        [void]$configured.Add($value)
    }
    if ($configured.Count -eq 0) {
        Throw-HandlerError 'The allowed-schemes configuration is empty.' 'invalid_config'
    }
    return @($configured)
}

function Get-LoggingEnabled {
    $path = Join-Path $script:ConfigDirectory 'logging'
    $text = Read-SmallRegularFile -Path $path -MaximumBytes 128 -Optional
    if ($null -eq $text) {
        return $false
    }
    $values = @()
    foreach ($line in ($text -split "`r?`n")) {
        $value = $line.Split('#', 2)[0].Trim().ToLowerInvariant()
        if ($value.Length -gt 0) {
            $values += $value
        }
    }
    if ($values.Count -eq 1 -and $values[0] -eq 'enabled') {
        return $true
    }
    if ($values.Count -eq 1 -and $values[0] -eq 'disabled') {
        return $false
    }
    Throw-HandlerError 'The logging configuration must contain either enabled or disabled.' 'invalid_config'
}

function ConvertTo-SafeLogValue {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) {
        return ''
    }
    $safe = [System.Text.RegularExpressions.Regex]::Replace($Value, '[^a-zA-Z0-9_-]', '_')
    if ($safe.Length -gt 64) {
        return $safe.Substring(0, 64)
    }
    return $safe
}

function Write-RedactedEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [AllowNull()][string]$Scheme,
        [AllowNull()][string]$Category
    )
    if (-not $Enabled) {
        return
    }
    try {
        Confirm-SafeDirectory -Path $script:StateDirectory -Create
        $logPath = Join-Path $script:StateDirectory 'events.log'
        if (Test-ReparsePoint -Path $logPath) {
            return
        }
        $fields = @(
            [DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz'),
            ('event=' + (ConvertTo-SafeLogValue $Event))
        )
        if ($Scheme) {
            $fields += ('scheme=' + (ConvertTo-SafeLogValue $Scheme))
        }
        if ($Category) {
            $fields += ('category=' + (ConvertTo-SafeLogValue $Category))
        }
        [System.IO.File]::AppendAllText(
            $logPath,
            (($fields -join ' ') + [Environment]::NewLine),
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    catch {
        # Logging never changes fail-closed behavior and never contains a URL.
    }
}

function Show-HandlerNotification {
    param([Parameter(Mandatory = $true)][string]$Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            $Message,
            'Media Link Launcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }
    catch {
        # A missing notification facility does not make a rejected request succeed.
    }
}

function Test-HexPair {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [System.Text.RegularExpressions.Regex]::IsMatch($Value, '\A[0-9a-fA-F]{2}\z')
}

function Confirm-InvocationCharacters {
    param([Parameter(Mandatory = $true)][string]$Value)
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $number = [int][char]$Value[$index]
        if ($number -gt 0x7f) {
            Throw-HandlerError 'The protocol request must use ASCII percent encoding.' 'malformed_invocation'
        }
        if ($number -lt 0x20 -or $number -eq 0x7f -or [char]::IsWhiteSpace($Value[$index])) {
            Throw-HandlerError 'The protocol request contains a control character or whitespace.' 'malformed_invocation'
        }
        if ($Value[$index] -eq '%') {
            if ($index + 2 -ge $Value.Length -or -not (Test-HexPair $Value.Substring($index + 1, 2))) {
                Throw-HandlerError 'The protocol request contains malformed percent encoding.' 'malformed_invocation'
            }
            $index += 2
        }
    }
}

function ConvertFrom-FormUrlEncodedUtf8 {
    param([Parameter(Mandatory = $true)][string]$Value)
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -eq '%') {
            $bytes.Add([Convert]::ToByte($Value.Substring($index + 1, 2), 16))
            $index += 2
        }
        elseif ($character -eq '+') {
            $bytes.Add(0x20)
        }
        else {
            $bytes.Add([byte][char]$character)
        }
    }
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        return $strictUtf8.GetString($bytes.ToArray())
    }
    catch {
        Throw-HandlerError 'The protocol request has an invalid query.' 'malformed_invocation'
    }
}

function ConvertTo-PercentDecodedTargetBytes {
    param([Parameter(Mandatory = $true)][string]$Value)
    $output = New-Object System.IO.MemoryStream
    $literal = New-Object System.Text.StringBuilder
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)

    $flushLiteral = {
        if ($literal.Length -gt 0) {
            $chunk = $utf8.GetBytes($literal.ToString())
            $output.Write($chunk, 0, $chunk.Length)
            [void]$literal.Clear()
        }
    }

    for ($index = 0; $index -lt $Value.Length; $index++) {
        if (
            $Value[$index] -eq '%' -and
            $index + 2 -lt $Value.Length -and
            (Test-HexPair $Value.Substring($index + 1, 2))
        ) {
            & $flushLiteral
            $output.WriteByte([Convert]::ToByte($Value.Substring($index + 1, 2), 16))
            $index += 2
        }
        else {
            [void]$literal.Append($Value[$index])
        }
    }
    & $flushLiteral
    return $output.ToArray()
}

function Confirm-TargetCharacters {
    param([Parameter(Mandatory = $true)][string]$Value)
    foreach ($character in $Value.ToCharArray()) {
        $number = [int][char]$character
        if (
            $number -lt 0x20 -or
            ($number -ge 0x7f -and $number -le 0x9f) -or
            [char]::IsWhiteSpace($character)
        ) {
            Throw-HandlerError 'The media URL contains a control character or unencoded whitespace.' 'invalid_target'
        }
    }

    try {
        $decodedBytes = ConvertTo-PercentDecodedTargetBytes -Value $Value
        foreach ($byte in $decodedBytes) {
            if ($byte -lt 0x20 -or $byte -eq 0x7f) {
                Throw-HandlerError 'The media URL contains an encoded control character.' 'invalid_target'
            }
        }
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $decodedText = $strictUtf8.GetString($decodedBytes)
        foreach ($character in $decodedText.ToCharArray()) {
            $number = [int][char]$character
            if ($number -ge 0x7f -and $number -le 0x9f) {
                Throw-HandlerError 'The media URL contains an encoded control character.' 'invalid_target'
            }
        }
    }
    catch {
        if ($_.Exception.Data['MediaLinkLauncherCategory']) {
            throw
        }
        # Invalid UTF-8 inside the target's own percent escapes is left for VLC,
        # matching the Linux handler. Encoded byte controls were already rejected.
    }
}

function Decode-Invocation {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.Length -gt $script:MaximumInvocationLength) {
        Throw-HandlerError 'The protocol request is too long.' 'oversized_invocation'
    }
    Confirm-InvocationCharacters -Value $Value

    $directPrefix = $script:ProtocolScheme + '://' + $script:ProtocolAction + '?url='
    $windowsCanonicalPrefix = $script:ProtocolScheme + '://' + $script:ProtocolAction + '/?url='
    $prefix = $null
    if ($Value.StartsWith($directPrefix, [System.StringComparison]::Ordinal)) {
        $prefix = $directPrefix
    }
    elseif ($Value.StartsWith($windowsCanonicalPrefix, [System.StringComparison]::Ordinal)) {
        # Windows URI canonicalization inserts this single root slash when an
        # authority is present but the original URI has an empty path.
        $prefix = $windowsCanonicalPrefix
    }
    else {
        Throw-HandlerError 'The protocol request has an invalid scheme, action, path, or query.' 'wrong_protocol'
    }
    if ($Value.IndexOf('#') -ge 0) {
        Throw-HandlerError 'The protocol request must not contain an outer fragment.' 'ambiguous_invocation'
    }

    $encodedTarget = $Value.Substring($prefix.Length)
    if ($encodedTarget.Length -eq 0 -or $encodedTarget.IndexOf('&') -ge 0) {
        Throw-HandlerError 'The protocol request must contain exactly one named media URL.' 'ambiguous_invocation'
    }
    $target = ConvertFrom-FormUrlEncodedUtf8 -Value $encodedTarget
    if ($target.Length -eq 0 -or $target.Length -gt $script:MaximumTargetLength) {
        Throw-HandlerError 'The media URL has an invalid length.' 'oversized_target'
    }
    Confirm-TargetCharacters -Value $target
    return $target
}

function ConvertTo-ValidatedTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string[]]$AllowedSchemes
    )
    if ($Value.Length -eq 0 -or $Value.Length -gt $script:MaximumTargetLength) {
        Throw-HandlerError 'The media URL has an invalid length.' 'invalid_target'
    }
    Confirm-TargetCharacters -Value $Value

    $schemeMatch = [System.Text.RegularExpressions.Regex]::Match(
        $Value,
        '\A([A-Za-z][A-Za-z0-9+.-]*):\/\/'
    )
    if (-not $schemeMatch.Success) {
        Throw-HandlerError 'The media URL is malformed.' 'invalid_target'
    }
    $scheme = $schemeMatch.Groups[1].Value.ToLowerInvariant()
    if ($AllowedSchemes -notcontains $scheme) {
        Throw-HandlerError 'The target protocol is not enabled.' 'unsupported_scheme'
    }

    $authorityStart = $schemeMatch.Length
    $authorityEnd = $Value.Length
    foreach ($delimiter in @('/', '?', '#')) {
        $candidate = $Value.IndexOf($delimiter, $authorityStart)
        if ($candidate -ge 0 -and $candidate -lt $authorityEnd) {
            $authorityEnd = $candidate
        }
    }
    $authority = $Value.Substring($authorityStart, $authorityEnd - $authorityStart)
    if ($authority.Length -eq 0 -or $authority.IndexOf('\') -ge 0) {
        Throw-HandlerError 'The media URL has an invalid authority.' 'invalid_target'
    }

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        Throw-HandlerError 'The media URL is malformed.' 'invalid_target'
    }
    if ($uri.Scheme.ToLowerInvariant() -ne $scheme -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        Throw-HandlerError 'The media URL must contain a hostname.' 'invalid_target'
    }
    if (-not $uri.IsDefaultPort -and $uri.Port -eq 0) {
        Throw-HandlerError 'Port zero is not allowed.' 'invalid_target'
    }

    $userInfo = $uri.UserInfo
    $hasUsername = $false
    $hasPassword = $false
    if ($userInfo.Length -gt 0) {
        $separator = $userInfo.IndexOf(':')
        if ($separator -eq 0) {
            Throw-HandlerError 'A password requires a username.' 'invalid_target'
        }
        $hasUsername = $true
        $hasPassword = $separator -gt 0
    }

    $hostname = $uri.DnsSafeHost.TrimEnd('.').ToLowerInvariant()
    if ($hostname.Length -eq 0 -or $hostname.IndexOf('%') -ge 0 -or $hostname.Length -gt 253) {
        Throw-HandlerError 'The media URL has an invalid hostname.' 'invalid_target'
    }
    if ($hostname.IndexOf(':') -lt 0) {
        foreach ($label in $hostname.Split('.')) {
            if ($label.Length -eq 0 -or $label.Length -gt 63) {
                Throw-HandlerError 'The media URL has an invalid hostname.' 'invalid_target'
            }
        }
    }

    $port = $null
    if (-not $uri.IsDefaultPort) {
        $port = $uri.Port
    }
    return [pscustomobject]@{
        Raw = $Value
        Scheme = $scheme
        Hostname = $hostname
        Port = $port
        HasUsername = $hasUsername
        HasPassword = $hasPassword
        HasPath = ($uri.AbsolutePath.Length -gt 0 -and $uri.AbsolutePath -ne '/')
        HasQuery = ($uri.Query.Length -gt 0)
        HasFragment = ($uri.Fragment.Length -gt 0)
    }
}

function Test-NonGlobalAddress {
    param([Parameter(Mandatory = $true)][System.Net.IPAddress]$Address)
    if ([System.Net.IPAddress]::IsLoopback($Address)) {
        return $true
    }

    $bytes = $Address.GetAddressBytes()
    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $first = [int]$bytes[0]
        $second = [int]$bytes[1]
        if ($first -eq 0 -or $first -eq 10 -or $first -eq 127 -or $first -ge 224) { return $true }
        if ($first -eq 100 -and $second -ge 64 -and $second -le 127) { return $true }
        if ($first -eq 169 -and $second -eq 254) { return $true }
        if ($first -eq 172 -and $second -ge 16 -and $second -le 31) { return $true }
        if ($first -eq 192 -and $second -eq 168) { return $true }
        if ($first -eq 192 -and $second -eq 0) { return $true }
        if ($first -eq 192 -and $second -eq 2) { return $true }
        if ($first -eq 198 -and ($second -eq 18 -or $second -eq 19)) { return $true }
        if ($first -eq 198 -and $second -eq 51 -and $bytes[2] -eq 100) { return $true }
        if ($first -eq 203 -and $second -eq 0 -and $bytes[2] -eq 113) { return $true }
        return $false
    }

    if ($Address.IsIPv4MappedToIPv6) {
        return Test-NonGlobalAddress -Address $Address.MapToIPv4()
    }
    if (($bytes[0] -band 0xfe) -eq 0xfc) { return $true }
    if ($bytes[0] -eq 0xfe -and ($bytes[1] -band 0xc0) -eq 0x80) { return $true }
    if ($bytes[0] -eq 0xff) { return $true }
    if (
        $bytes[0] -eq 0x20 -and $bytes[1] -eq 0x01 -and
        $bytes[2] -eq 0x0d -and $bytes[3] -eq 0xb8
    ) { return $true }
    return $false
}

function Get-HostScopeWarning {
    param([Parameter(Mandatory = $true)][string]$Hostname)
    $normalized = $Hostname.TrimEnd('.').ToLowerInvariant()
    if ($normalized -eq 'localhost') {
        return 'WARNING: This destination appears to be on your local network.'
    }
    foreach ($suffix in $script:LocalHostSuffixes) {
        if ($normalized.EndsWith($suffix, [System.StringComparison]::Ordinal)) {
            return 'WARNING: This destination appears to be on your local network.'
        }
    }
    $address = $null
    if ([System.Net.IPAddress]::TryParse($normalized, [ref]$address)) {
        if (Test-NonGlobalAddress -Address $address) {
            return 'WARNING: This is a local, private, link-local, or reserved IP address.'
        }
    }
    return $null
}

function Get-ResolvedScopeWarning {
    param([Parameter(Mandatory = $true)][string]$Hostname)
    try {
        foreach ($address in [System.Net.Dns]::GetHostAddresses($Hostname)) {
            if (Test-NonGlobalAddress -Address $address) {
                return 'WARNING: This hostname resolves to a local, private, link-local, or reserved address.'
            }
        }
    }
    catch {
        return $null
    }
    return $null
}

function Get-ConfirmationText {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [AllowNull()][string]$Warning
    )
    $portText = 'default'
    if ($null -ne $Target.Port) {
        $portText = [string]$Target.Port
    }
    $credentials = 'no'
    if ($Target.HasUsername -or $Target.HasPassword) {
        $credentials = 'yes'
    }
    $lines = @(
        'A website requested that VLC media player open a network destination:',
        '',
        ('Protocol: ' + $Target.Scheme.ToUpperInvariant()),
        ('Host: ' + $Target.Hostname),
        ('Port: ' + $portText),
        ('Credentials present: ' + $credentials),
        ('Path present: ' + $(if ($Target.HasPath) { 'yes' } else { 'no' })),
        ('Query present: ' + $(if ($Target.HasQuery) { 'yes' } else { 'no' })),
        ('Fragment present: ' + $(if ($Target.HasFragment) { 'yes' } else { 'no' })),
        '',
        'Credentials, path, query, and fragment values are hidden because any of them may contain sensitive data.'
    )
    if ($Warning) {
        $lines += ''
        $lines += $Warning
    }
    $lines += ''
    $lines += 'Open this destination in VLC media player?'
    return ($lines -join [Environment]::NewLine)
}

function Confirm-Target {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [AllowNull()][string]$Warning
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Media Link Launcher'
    $form.Width = 640
    $form.Height = 480
    $form.MinimumSize = New-Object System.Drawing.Size(520, 400)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.Tag = $false

    $text = New-Object System.Windows.Forms.TextBox
    $text.Multiline = $true
    $text.ReadOnly = $true
    $text.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $text.WordWrap = $true
    $text.BackColor = [System.Drawing.SystemColors]::Window
    $text.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $text.Text = Get-ConfirmationText -Target $Target -Warning $Warning
    $text.SetBounds(16, 16, 590, 350)
    $text.Anchor = (
        [System.Windows.Forms.AnchorStyles]::Top -bor
        [System.Windows.Forms.AnchorStyles]::Bottom -bor
        [System.Windows.Forms.AnchorStyles]::Left -bor
        [System.Windows.Forms.AnchorStyles]::Right
    )

    $openButton = New-Object System.Windows.Forms.Button
    $openButton.Text = 'Open in VLC'
    $openButton.Width = 120
    $openButton.Height = 32
    $openButton.Left = 358
    $openButton.Top = 384
    $openButton.Anchor = (
        [System.Windows.Forms.AnchorStyles]::Bottom -bor
        [System.Windows.Forms.AnchorStyles]::Right
    )

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Width = 120
    $cancelButton.Height = 32
    $cancelButton.Left = 486
    $cancelButton.Top = 384
    $cancelButton.Anchor = (
        [System.Windows.Forms.AnchorStyles]::Bottom -bor
        [System.Windows.Forms.AnchorStyles]::Right
    )

    $form.Controls.Add($text)
    $form.Controls.Add($openButton)
    $form.Controls.Add($cancelButton)
    $form.AcceptButton = $openButton
    $form.CancelButton = $cancelButton

    $openButton.Add_Click({
        $form.Tag = $true
        $form.Close()
    })
    $cancelButton.Add_Click({
        $form.Tag = $false
        $form.Close()
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $script:PromptTimeoutSeconds * 1000
    $timer.Add_Tick({
        $form.Tag = $false
        $timer.Stop()
        $form.Close()
    })
    $timer.Start()
    try {
        [void]$form.ShowDialog()
        return [bool]$form.Tag
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
        $form.Dispose()
    }
}

function Enter-PromptMutex {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User.Value.Replace('-', '_')
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, ('Local\MediaLinkLauncher_Prompt_' + $sid), [ref]$createdNew)
    try {
        if (-not $mutex.WaitOne(0, $false)) {
            $mutex.Dispose()
            Throw-HandlerError 'Another confirmation is already open.' 'prompt_busy' -Quiet
        }
    }
    catch [System.Threading.AbandonedMutexException] {
        # Ownership is granted when an abandoned mutex is observed.
    }
    return $mutex
}

function Confirm-PromptInterval {
    Confirm-SafeDirectory -Path $script:StateDirectory -Create
    $path = Join-Path $script:StateDirectory 'last-prompt'
    if (Test-ReparsePoint -Path $path) {
        Throw-HandlerError 'The prompt timestamp must not be a reparse point.' 'unsafe_state'
    }
    $previous = [DateTime]::MinValue
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $text = Read-SmallRegularFile -Path $path -MaximumBytes 128
        [void][DateTime]::TryParseExact(
            $text.Trim(),
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$previous
        )
    }
    $now = [DateTime]::UtcNow
    if (
        $previous -ne [DateTime]::MinValue -and
        ($now - $previous.ToUniversalTime()).TotalSeconds -lt $script:MinimumPromptIntervalSeconds
    ) {
        Throw-HandlerError 'Requests are arriving too quickly.' 'prompt_throttled' -Quiet
    }
    [System.IO.File]::WriteAllText(
        $path,
        $now.ToString('o', [Globalization.CultureInfo]::InvariantCulture),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function ConvertTo-WindowsCommandLineArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Start-Vlc {
    param([Parameter(Mandatory = $true)]$Target)
    $pathFile = Join-Path $script:ApplicationDirectory 'vlc-path.txt'
    $vlcPath = (Read-SmallRegularFile -Path $pathFile -MaximumBytes 4096).Trim()
    if (
        -not [System.IO.Path]::IsPathRooted($vlcPath) -or
        -not (Test-Path -LiteralPath $vlcPath -PathType Leaf)
    ) {
        Throw-HandlerError 'The VLC executable recorded during installation is unavailable.' 'vlc_unavailable'
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $vlcPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.Arguments = (
        (ConvertTo-WindowsCommandLineArgument '--') + ' ' +
        (ConvertTo-WindowsCommandLineArgument $Target.Raw)
    )
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        Throw-HandlerError 'VLC could not be started.' 'vlc_unavailable'
    }
}

function Get-ExceptionCategory {
    param([Parameter(Mandatory = $true)][Exception]$Exception)
    $category = $Exception.Data['MediaLinkLauncherCategory']
    if ($category) {
        return [string]$category
    }
    return 'internal_error'
}

function Test-QuietException {
    param([Parameter(Mandatory = $true)][Exception]$Exception)
    return [bool]$Exception.Data['MediaLinkLauncherQuiet']
}

function Invoke-MediaLinkLauncher {
    param(
        [AllowEmptyString()][string]$Value,
        [int]$AdditionalArgumentCount = 0
    )
    $target = $null
    $loggingEnabled = $false
    $mutex = $null
    try {
        if ([string]::IsNullOrEmpty($Value) -or $AdditionalArgumentCount -ne 0) {
            Throw-HandlerError 'Expected exactly one protocol request.' 'wrong_argument_count'
        }
        Confirm-SafeDirectory -Path $script:ApplicationDirectory
        Confirm-SafeDirectory -Path $script:ConfigDirectory -Create
        $allowedSchemes = Get-AllowedSchemes
        $loggingEnabled = Get-LoggingEnabled
        $rawTarget = Decode-Invocation -Value $Value
        $target = ConvertTo-ValidatedTarget -Value $rawTarget -AllowedSchemes $allowedSchemes

        $mutex = Enter-PromptMutex
        Confirm-PromptInterval
        $warning = Get-HostScopeWarning -Hostname $target.Hostname
        if (-not (Confirm-Target -Target $target -Warning $warning)) {
            Write-RedactedEvent -Event 'cancelled' -Enabled $loggingEnabled -Scheme $target.Scheme -Category 'user_cancelled'
            return 1
        }

        $resolvedWarning = Get-ResolvedScopeWarning -Hostname $target.Hostname
        if ($resolvedWarning -and -not $warning) {
            if (-not (Confirm-Target -Target $target -Warning $resolvedWarning)) {
                Write-RedactedEvent -Event 'cancelled' -Enabled $loggingEnabled -Scheme $target.Scheme -Category 'private_destination_cancelled'
                return 1
            }
        }

        Start-Vlc -Target $target
        Write-RedactedEvent -Event 'launched' -Enabled $loggingEnabled -Scheme $target.Scheme -Category $null
        return 0
    }
    catch {
        $category = Get-ExceptionCategory -Exception $_.Exception
        $scheme = $null
        if ($null -ne $target) {
            $scheme = $target.Scheme
        }
        Write-RedactedEvent -Event 'rejected' -Enabled $loggingEnabled -Scheme $scheme -Category $category
        if (-not (Test-QuietException -Exception $_.Exception)) {
            $message = 'The media request failed safely.'
            if ($_.Exception.Data['MediaLinkLauncherCategory']) {
                $message = $_.Exception.Message
            }
            Show-HandlerNotification -Message $message
        }
        return 1
    }
    finally {
        if ($null -ne $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch {
            }
            $mutex.Dispose()
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $additionalCount = 0
    if ($null -ne $RemainingArguments) {
        $additionalCount = $RemainingArguments.Count
    }
    exit (Invoke-MediaLinkLauncher -Value $InvocationUri -AdditionalArgumentCount $additionalCount)
}
