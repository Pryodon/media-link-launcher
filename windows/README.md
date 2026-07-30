# Media Link Launcher for Windows

## Open web media links in VLC media player

Media Link Launcher 0.2.0 is an independent Tampermonkey userscript and
per-user Windows URL-protocol handler. It adds a bold **VLC** control beside
web links that appear to point to media. Clicking the control sends the
selected URL to a local handler, which validates the request, displays a
redacted confirmation, and starts VLC only after approval.

The package operates no server and includes no analytics, telemetry, tracking,
remote code, automatic downloads, or automatic package installation.

## One shared userscript

`media-link-launcher.user.js` is byte-for-byte identical to the file in
`media-link-launcher-linux-0.2.0.zip`. Its SHA-256 value is recorded in
`USERSCRIPT-SHA256.txt`:

```text
5f250f81e4ad6f72d1241b6e21565e5595cbb9a6186f8f6f3914e9f149faf0c6
```

The operating-system handler and installer differ by platform; the
Tampermonkey code does not.

Windows 0.2.0 accepts the single root slash that Windows URI canonicalization
inserts between `open` and `?url=`. This is a Windows-handler correction only
and does not require a userscript update.

## Compatibility

This package is designed for Windows 10 and Windows 11. It uses Windows
PowerShell 5.1 and .NET Framework components included with those versions of
Windows. It installs only for the current Windows account and does not require
administrator rights.

Detection and playback are not guaranteed. Compatibility also depends on the
browser, Tampermonkey, VLC version and build, media server, credentials,
codecs, and format.

## Prerequisites

Install these separately from their official sources:

- [Firefox](https://www.mozilla.org/firefox/new/) or another
  Tampermonkey-compatible browser
- [Tampermonkey](https://www.tampermonkey.net/)
- [VLC media player](https://www.videolan.org/vlc/)

The ZIP does not contain or redistribute Firefox, Tampermonkey, VLC, Python,
a PowerShell runtime, package-manager code, or any other third-party source or
binary. Python is not required on Windows.

## Package files

- `install-media-link-launcher.cmd` is the normal double-click installer.
- `install-media-link-launcher.ps1` is the reviewable installer source.
- `uninstall-media-link-launcher.cmd` is the normal double-click uninstaller.
- `uninstall-media-link-launcher.ps1` is the reviewable uninstaller source.
- `media-link-launcher.user.js` is the shared Tampermonkey userscript.
- `media-link-launcher.ps1` is the Windows protocol-handler source.
- `USERSCRIPT-SHA256.txt` records the shared userscript hash.
- `LICENSE.md` contains the unmodified CC0 1.0 Universal legal code.
- `DISCLAIMER.md` is a separate additional warranty and liability notice.
- `CHANGELOG.md` records Windows package changes.
- `tests/` contains non-destructive handler tests; tests are not installed.
- `build-release.ps1` creates a reproducible release ZIP; it is not installed.

## Installation

1. Install VLC and Tampermonkey first.
2. Right-click the downloaded ZIP, choose **Properties**, and select
   **Unblock** if Windows displays that option.
3. Choose **Extract All**. Do not run the installer from inside the ZIP preview.
4. Double-click `install-media-link-launcher.cmd` in the extracted folder.
5. Confirm that the installer reports the VLC and handler paths.
6. Open `media-link-launcher.user.js` in the browser and let Tampermonkey
   install it.
7. If the browser displays only source, open Tampermonkey's dashboard, choose
   **Create a new script**, replace the template with the complete contents of
   `media-link-launcher.user.js`, and save it.
8. Remove or disable any old 0.1.0 userscript so two versions do not scan the
   same pages.

The installer locates VLC in its standard installation locations, its Windows
App Paths registration, or `PATH`. For a nonstandard location, open Windows
PowerShell in the extracted package folder and run:

```powershell
$installer = '.\install-media-link-launcher.ps1'
$vlc = 'C:\full\path\to\vlc.exe'
$common = '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File'
powershell.exe $common $installer -VlcPath $vlc
```

The installer refuses to replace an unrelated owner of the
`media-link-launcher` protocol. `-Force` exists for an intentional, reviewed
replacement; normal users should not need it.

## What installation changes

The installer creates these current-user files:

```text
%LOCALAPPDATA%\MediaLinkLauncher\App\
%LOCALAPPDATA%\MediaLinkLauncher\Config\
%LOCALAPPDATA%\MediaLinkLauncher\State\
```

It also creates this current-user protocol registration:

```text
HKEY_CURRENT_USER\Software\Classes\media-link-launcher
```

It does not write to system-wide application directories or the system-wide
registry, invoke an administrator prompt, download software, or change the
shared userscript.

## First click and browser permission

Click a bold **VLC** control beside a recognized media link. The browser may
ask whether a `media-link-launcher` request may be opened with **Media Link
Launcher**. Review the application name before allowing it.

The separate Windows handler asks for confirmation for every accepted request,
even if the browser remembers its external-protocol permission. The
confirmation hides credential, path, query, and fragment values because they
may contain sensitive data.

## Allowed media protocols

Only HTTP and HTTPS are enabled by default. The per-user configuration is:

```text
%LOCALAPPDATA%\MediaLinkLauncher\Config\allowed-schemes
```

Supported optional values are:

```text
ftp
ftps
sftp
smb
rtsp
rtsps
rtmp
rtmps
mms
mmsh
mmst
rtp
udp
```

Use one value per line. Lines may contain comments beginning with `#`. Enable
optional protocols only after reviewing their security and privacy
implications. `file`, `javascript`, `data`, `shell`, empty, command-execution,
and unknown schemes are never supported.

## Security model

The Windows handler:

- accepts exactly one protocol argument;
- accepts the direct `media-link-launcher://open?url=...` form and the
  single-root-slash form that Windows canonicalization produces, while
  rejecting every other action and path;
- rejects malformed percent encoding, ambiguous parameters, outer fragments,
  controls, whitespace, invalid UTF-8, oversized values, and invalid target
  authorities;
- requires a configured target scheme, hostname, and valid port;
- never sends the destination through `cmd.exe`, PowerShell expression
  evaluation, `Invoke-Expression`, or shell interpolation;
- starts the fixed VLC executable selected during installation and passes the
  complete destination as one quoted argument after VLC's `--` separator;
- permits one confirmation at a time and rate-limits prompts;
- warns for visibly local, private, link-local, or reserved destinations;
- performs a DNS lookup after the first confirmation and requests a second
  confirmation when a public-looking name resolves to a non-global address;
  and
- fails closed when validation, confirmation, configuration, or VLC launching
  fails.

A custom URL protocol necessarily exposes its argument to the browser, the
operating-system process launch, this handler, and VLC. Other software already
running as the same Windows user may be able to inspect process arguments.
Browser native messaging would be required for a stronger confidentiality
boundary.

The handler cannot make a page-supplied destination safe. Keep Windows, the
browser, Tampermonkey, and VLC updated. Open destinations only from sources you
trust.

## Logging and privacy

Persistent event logging is disabled by default. Its setting is:

```text
%LOCALAPPDATA%\MediaLinkLauncher\Config\logging
```

The only accepted non-comment value is `disabled` or `enabled`. When enabled,
redacted events are written to:

```text
%LOCALAPPDATA%\MediaLinkLauncher\State\events.log
```

The log records timestamps, event categories, and target protocol names. It
does not record hostnames, ports, credentials, paths, queries, fragments, or
complete URLs.

Link detection occurs locally in Tampermonkey. The userscript makes no
project-server request. After confirmation, VLC contacts the selected
destination. The project does not transfer browser cookies, login sessions,
authorization headers, DRM information, or browser storage to VLC.

## Uninstallation

Double-click `uninstall-media-link-launcher.cmd`. It removes only a protocol
registration marked as owned by this installation and removes the installed
handler. Configuration and state are retained by default.

To remove configuration, state, and optional logs too, run from the extracted
package folder:

```powershell
$uninstaller = '.\uninstall-media-link-launcher.ps1'
$common = '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File'
powershell.exe $common $uninstaller -RemoveSettings
```

Remove or disable **Media Link Launcher** separately in Tampermonkey.

## Known limitations

Media Link Launcher may not work with DRM, `blob:` URLs, Media Source
Extensions without a direct URL, browser-only authorization, cookies, referer
restrictions, expiring links, signed URLs that have expired, unsupported
codecs, or VLC builds lacking a required access module.

Heuristics may produce false positives or false negatives. The handler
validates and launches; it cannot make an inaccessible or unsupported resource
playable.

## Development checks

Run the non-destructive Windows tests from the extracted package folder:

```powershell
$test = '.\tests\test-media-link-launcher.ps1'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $test
```

Build the release archive with:

```powershell
$builder = '.\build-release.ps1'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $builder
```

The tests do not register the protocol, display confirmation dialogs, or
launch VLC.

## Licence and package scope

To the greatest extent permitted by law, this project's own source and
documentation are dedicated to the public domain under **CC0 1.0 Universal**.
CC0 supplies a public-licence fallback where a complete waiver is not legally
effective. The complete unmodified legal code is in `LICENSE.md`.

Source inspection found no vendored third-party source or redistributed
third-party binary in this Windows ZIP. The package uses standard Windows,
browser, and VLC interfaces without bundling those programs. CC0 applies only
to this project's own source, tests, scripts, and documentation. It does not
grant rights to Windows, PowerShell, .NET Framework, VLC, Firefox,
Tampermonkey, accessed media, websites, or other third-party software or
content.

`DISCLAIMER.md` supplies separate additional warranty and liability language
without modifying CC0 or imposing a licence condition. These files are general
project documentation, not legal advice.

This is an independent project. It is not produced, sponsored, endorsed,
approved, or supported by Microsoft, VideoLAN, Mozilla, or the developers of
Tampermonkey. Trademark names identify compatible third-party software only.
