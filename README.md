# Media Link Launcher

Open recognized web media links in VLC media player on Linux or Windows.

Media Link Launcher is an independent third-party project with two components:

1. A shared Tampermonkey userscript adds a **VLC** control beside links that
   appear to point to media.
2. A per-user operating-system handler validates the selected URL, asks for
   confirmation, and starts VLC without passing the destination through a
   command shell.

The project operates no server and includes no analytics, telemetry, tracking,
remote code, or automatic package installation.

## Installation

Install both the userscript and the handler for your operating system from the
same release:

- **Linux:** Python 3 and XDG desktop integration. See the
  [Linux installation and documentation](linux/README.md).

- **Windows:** Windows PowerShell 5.1 and current-user protocol registration.
  See the [Windows installation and documentation](windows/README.md).

Ready-to-use packages are available from
[GitHub Releases](https://github.com/Pryodon/media-link-launcher/releases).
Each release package contains the shared userscript, the selected platform
handler, its installer and uninstaller, tests, legal notices, and detailed
documentation.

Version 0.2.0 and later use the project-owned request form:

```text
media-link-launcher://open?url=<percent-encoded-media-url>
```

The Linux and Windows handlers implement the same protocol. Windows also
accepts the equivalent single-root-slash form produced by Windows URI
canonicalization.

## Repository layout

```text
.
├── README.md
├── LICENSE.md
├── DISCLAIMER.md
├── userscript/
│   ├── media-link-launcher.user.js
│   ├── USERSCRIPT-SHA256.txt
│   └── tests/
├── linux/
│   ├── README.md
│   ├── CHANGELOG.md
│   ├── build-release.py
│   └── tests/
└── windows/
    ├── README.md
    ├── CHANGELOG.md
    ├── build-release.ps1
    └── tests/
```

`userscript/media-link-launcher.user.js` is the single canonical userscript
source, and `userscript/USERSCRIPT-SHA256.txt` records its SHA-256 value. Both
release builders validate and copy those files into their standalone package.
Platform-specific handlers, installers, tests, documentation, and changelogs
remain under their platform directories.

## Development checks

Run Linux and shared-userscript checks from the repository root:

```bash
bash -n linux/install-media-link-launcher.sh
bash -n linux/uninstall-media-link-launcher.sh
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s linux/tests -p 'test_*.py' -v
node --test userscript/tests/test_userscript.js
python3 linux/build-release.py
```

Run Windows checks from a Windows PowerShell prompt at the repository root:

```powershell
$test = '.\windows\tests\test-media-link-launcher.ps1'
$builder = '.\windows\build-release.ps1'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $test
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $builder
```

The builders create deterministic, self-contained platform ZIPs at the
repository root. Generated archives are not tracked.

## Security and privacy

The userscript performs link detection locally in the browser. It does not
fetch media or send detected links to a project server. The operating-system
handler strictly validates the custom-protocol request, permits only configured
target schemes, presents a redacted confirmation, and launches VLC with a
fixed executable path and argument list.

Opening a link causes VLC to contact a page-supplied destination. Keep the
browser, userscript manager, VLC, and operating system updated, and open only
destinations you trust. Refer to the platform documentation for the complete
security model, configuration details, limitations, rollback instructions, and
privacy considerations.

## License and disclaimer

The project's own source and documentation are dedicated to the public domain
under [CC0 1.0 Universal](LICENSE.md). [DISCLAIMER.md](DISCLAIMER.md) contains
separate additional warranty and liability language.

Media Link Launcher is not produced, sponsored, endorsed, approved, or
supported by VideoLAN, Microsoft, Mozilla, the developers of Tampermonkey, or
any Linux distribution. Third-party names identify compatible software only.
