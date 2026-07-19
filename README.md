# Media Link Launcher

## Open web media links in VLC media player

Media Link Launcher 0.2.0 is an independent third-party Tampermonkey
userscript and Linux URL-protocol handler. It opens selected web media URLs
in VLC media player.

The userscript adds a clearly visible, bold **VLC** control beside links that
its local heuristics recognize as likely media. It does not change the
website's original link. Ordinary left-click behavior and Firefox's
**Save Link As...** action remain attached to the original link.

Clicking the added control sends the selected absolute URL to a separately
installed per-user handler. The handler validates the request and asks for
confirmation before starting VLC.

This is not a plugin loaded by VLC, an official VLC browser plugin, or a
Firefox extension produced by VLC. It has two independent components:

1. `media-link-launcher.user.js` is a Tampermonkey userscript that detects
   likely media links in the browser.

2. `media-link-launcher.py` and `media-link-launcher.desktop.in` implement a
   Linux handler for `media-link-launcher://` requests.

The project operates no server. It includes no analytics, telemetry,
tracking, remote code, or automatic package installation.

## Compatibility status

This release has been tested on a Debian desktop system with VLC 3.0.23,
Python 3, and freedesktop.org/XDG protocol tools. It may also work on Ubuntu
and other Linux desktops that support per-user XDG URL-protocol handlers,
but those environments have not been tested for this release.

Detection and playback are not guaranteed. Media Link Launcher uses
extension-, MIME-, attribute-, text-, query-parameter-, and protocol-based
heuristics. VLC support also varies by VLC version, build options,
destination server, credentials, and media format.

## Package files

- `README.md` contains installation, operation, security, privacy,
  migration, and legal documentation.

- `LICENSE.md` contains the complete, unmodified CC0 1.0 Universal legal
  code.

- `DISCLAIMER.md` is a separate additional warranty and liability notice.
  It is not part of, or a change to, CC0.

- `CHANGELOG.md` records version and compatibility changes.

- `install-media-link-launcher.sh` performs per-user installation and
  verified 0.1.0 migration.

- `uninstall-media-link-launcher.sh` safely invokes the uninstall operation.

- `media-link-launcher.user.js` is the Tampermonkey userscript.

- `media-link-launcher.py` is the reviewable handler source template.

- `media-link-launcher.desktop.in` is the desktop-entry template.

- `tests/` contains Python and Node tests. Tests are not installed.

- `build-release.py` creates the release ZIP. It is not installed.

The installer embeds absolute Python and VLC executable paths in the
installed handler. Keep the handler and desktop templates beside the
installer while installing.

## Prerequisites

- [Firefox web browser][firefox]

- [Tampermonkey for Firefox][tampermonkey]

- [VLC media player][vlc]

- [Python 3][python]

- `xdg-mime` from [xdg-utils][xdg-utils], or GLib's `gio`

- At least one confirmation tool: Zenity, KDialog, or Python Tkinter

Obtain prerequisites from their official project sites or your operating
system's trusted package repositories. The installer never downloads
software, installs packages, or invokes `sudo`.

## Installation

Do not run the installer with `sudo` or as root.

From the extracted `media-link-launcher-linux` directory, run:

```bash
bash install-media-link-launcher.sh
```

The installer performs command and ownership preflight checks before it
changes files. A normal installation uses only these per-user paths. XDG
environment variables are honored where applicable.

```text
~/.local/bin/media-link-launcher
${XDG_DATA_HOME:-~/.local/share}/applications/media-link-launcher.desktop
${XDG_CONFIG_HOME:-~/.config}/media-link-launcher/allowed-schemes
${XDG_CONFIG_HOME:-~/.config}/media-link-launcher/logging
${XDG_STATE_HOME:-~/.local/state}/media-link-launcher/
```

Existing project-owned operational files and relevant `mimeapps.list` files
are backed up before replacement. If an existing destination or protocol
association cannot be positively identified as this project's, installation
stops instead of overwriting it.

Next, install the userscript:

1. Install Tampermonkey from its official Firefox listing or website.

2. Open `media-link-launcher.user.js` in Firefox and let Tampermonkey install
   it.

3. If Firefox displays only source, open Tampermonkey's dashboard, choose
   **Create a new script**, replace the template with the complete file, and
   save it.

4. Remove or disable the old 0.1.0 userscript so two versions do not scan the
   same pages.

The userscript intentionally matches ordinary HTTP and HTTPS pages on all
sites. Disable it in Tampermonkey whenever you do not want its controls.

## First click and Firefox permission

Click a bold **VLC** control beside a recognized link. Firefox may ask whether
a `media-link-launcher` request may be opened with **Media Link Launcher**.
Review the application name before allowing the request.

Firefox may or may not offer to remember this choice. That varies by Firefox
version and configuration. The added control is a button that constructs the
request only after a trusted click. It is not a native page link containing
the destination request in an `href`.

The separate desktop handler asks for confirmation for every accepted request,
even if Firefox remembers its own external-protocol permission.

## Verify protocol registration

Either command can verify installation. The expected desktop identifier is
`media-link-launcher.desktop`.

```bash
gio mime x-scheme-handler/media-link-launcher
```

```bash
xdg-mime query default x-scheme-handler/media-link-launcher
```

The desktop entry registers exactly:

```text
x-scheme-handler/media-link-launcher
```

The userscript generates requests in this form:

```text
media-link-launcher://open?url=<percent-encoded-media-url>
```

## Link-detection behavior

Detection happens locally in the browser and makes no network request. A link
can be recognized by one or more of these heuristics:

- a common video, audio, playlist, manifest, or streaming extension in the
  URL path;

- an `audio/*`, `video/*`, or selected manifest MIME type in the anchor's
  `type` attribute;

- a recognized filename in the anchor's `download` attribute;

- recognized visible filename text only when the link also has an explicit
  `download` attribute;

- a recognized media filename inside a query-parameter value; or

- a supported direct-stream protocol such as RTSP, RTP, or UDP.

The visible-text rule deliberately requires corroboration. An ordinary linked
title that merely ends in `.mp4`, such as a ChatGPT conversation title, is not
treated as media unless that anchor also declares itself as a download.

Relative links are resolved against the document base URL. The resulting
absolute URL is passed as one value. Browser URL serialization preserves the
functional path, query, fragment, Unicode, spaces, ampersands, percent signs,
and signed parameters through standard URL percent encoding. The original
anchor and its `href` remain unchanged.

A `MutationObserver` scans links inserted or changed after page load. A
per-anchor weak map prevents duplicate controls. It also removes a control if
the anchor stops matching.

## Allowed target protocols and configuration

Only HTTP and HTTPS are enabled by default:

```text
http
https
```

The private configuration file is:

```text
${XDG_CONFIG_HOME:-~/.config}/media-link-launcher/allowed-schemes
```

Its project directory must be owned by the current user and mode `0700`. The
file must be owned by that user and mode `0600`. It contains one lowercase
protocol per line. The complete handler-supported set is:

```text
http https ftp ftps sftp smb rtsp rtsps rtmp rtmps mms mmsh mmst rtp udp
```

To enable an optional protocol, add only the needed name on its own line and
preserve mode `0600`. The handler reads the file on every request, so a
configuration-only change needs no service restart or reinstall.

Enable only protocols you understand and use. Support depends on the installed
VLC build. Being accepted by this handler does not guarantee playback. SMB,
SFTP, FTP, RTP, UDP, RTSP, and related protocols may contact local or private
systems. Authenticated protocols may invoke VLC's own credential handling.

No optional protocol, including SMB, is enabled by default. The userscript
cannot read this private configuration, so it may display a control for a
direct protocol that the handler then rejects as disabled.

The handler never allows `file`, `javascript`, `data`, `shell`, empty,
command-execution, or arbitrary unknown schemes.

## Protocol-handler security model

The handler:

- accepts exactly one invocation argument;

- uses Python's standard URL parser;

- requires the exact `media-link-launcher` scheme, `open` action, empty outer
  path, no outer fragment, and one nonempty parameter named `url`;

- rejects malformed percent encoding, invalid outer UTF-8, ambiguous or extra
  parameters, excessive lengths, NUL bytes, control characters, and unencoded
  whitespace;

- validates the target hostname and port and requires an explicitly configured
  target protocol;

- uses fixed Python and VLC paths selected from an administrator-controlled
  system `PATH` during installation;

- starts VLC with an argument list equivalent to
  `vlc -- <complete-target-url>`;

- never uses `eval`, `os.system`, a command shell, command interpolation, or
  `subprocess` with `shell=True`;

- passes the complete destination as one argument after VLC's `--` separator;

- requires a separate desktop confirmation for every accepted request;

- allows one confirmation at a time and rate-limits prompts;

- warns when the hostname is visibly local, private, or reserved; and

- after the first confirmation, performs a DNS lookup and requires a second
  confirmation if a public-looking host resolves to a non-global address.

If VLC or every supported confirmation tool is unavailable, the handler fails
closed. Error notifications contain fixed general messages and never contain
the destination URL.

The full media URL necessarily appears as the installed handler's process
argument and then as VLC's process argument. Other software already running as
the same user may be able to observe process arguments. A custom URL protocol
cannot provide the confidentiality of authenticated browser native messaging.

## Migration from 0.1.0

Version 0.2.0 is a compatibility-breaking update. The old userscript generates
the former `vlc://` request. The new handler accepts only
`media-link-launcher://`, so update both components together.

Normal 0.2.0 installation checks the fixed 0.1.0 operational paths. Migration
proceeds only when both checks pass:

1. After normalizing only the installer-substituted shebang and VLC path, the
   installed old handler has the exact known 0.1.0 source hash.

2. The old desktop file exactly matches the known 0.1.0 desktop entry for that
   handler path.

When both match, the installer:

1. creates a unique timestamped backup of the old handler, desktop file, and
   relevant association files;

2. checks the current old-scheme default;

3. removes the old default only if it currently points to the verified
   project-owned `vlc-url-handler.desktop`;

4. restores a safely recorded pre-0.1.0 default when one exists;

5. removes only the verified old handler and desktop file;

6. retains old configuration, state, logs, and backups for review; and

7. installs and verifies the new handler and association.

If either old operational file is missing, modified, symbolic, ambiguous, or
unrelated, the old files and old association are retained unchanged. If another
application currently owns the old scheme, its association is never changed.
Running the installer again is safe and creates a new backup directory.

After migration, remove or disable **Bold VLC links beside media links** in
Tampermonkey and install **Media Link Launcher**.

## Backups and rollback

Backups are stored outside active application and configuration-loader
directories:

```text
${XDG_STATE_HOME:-~/.local/state}/media-link-launcher/backups/
```

Each operation creates a child directory containing its operation, timestamp,
and a unique suffix. The directory is mode `0700`. Files are copied without
overwriting earlier backups. Ownership, modes, timestamps, ACLs, and extended
attributes are preserved where the filesystem and `cp` support them.

For rollback, note the backup path printed by the installer. Run the
uninstaller, inspect that backup, and restore only specific original files to
their original paths while preserving metadata. Do not put backup desktop
files under alternate names in an active `applications` directory. Verify both
MIME queries after rollback.

## Uninstall

Run either command from the extracted package directory:

```bash
bash uninstall-media-link-launcher.sh
```

```bash
bash install-media-link-launcher.sh --uninstall
```

The uninstaller backs up files before removal. Installed handler and desktop
files are removed only when their hashes match the private install manifest.
If the manifest is absent, strict project markers are required. Modified,
unverified, unrelated, non-regular, or symbolic files are retained and
reported.

The new default association is removed only when it currently points to this
project and ownership evidence is valid. A safely recorded earlier association
is restored. A different current association is left unchanged. Uninstall is
safe to run more than once.

Configuration, optional logs, migration evidence, state, and backups are
retained. Remove or disable **Media Link Launcher** separately in Tampermonkey.
Old 0.1.0 files are removed automatically only by the verified migration.
Ambiguous old files require manual inspection instead of automatic deletion.

## Logging and private state

Persistent event logging is disabled by default. Its setting is:

```text
${XDG_CONFIG_HOME:-~/.config}/media-link-launcher/logging
```

The only accepted non-comment value is `disabled` or `enabled`. Preserve the
project directory at mode `0700` and this file at mode `0600`. Set it to
`enabled` only while persistent diagnostics are genuinely needed. Set it back
to `disabled` when finished.

When enabled, the log is:

```text
${XDG_STATE_HOME:-~/.local/state}/media-link-launcher/events.log
```

The state directory is forced to mode `0700` and the log to mode `0600`.
Entries contain only a timestamp, fixed outcome, validated target protocol,
and fixed general error category. They omit hostname, username, password,
path, query, fragment, cookies, headers, and the complete URL.

Omitting query strings alone would not be enough. Credentials, path segments,
fragments, and even hostnames can also carry secrets.

Disable logging before deleting the current log. With the normal XDG state
location, use:

```bash
rm -- "${XDG_STATE_HOME:-$HOME/.local/state}/media-link-launcher/events.log"
```

The handler does not rotate logs. Leave logging disabled unless it is needed
briefly.

## Privacy

- Link detection occurs locally in the Tampermonkey userscript.

- The userscript makes no `fetch`, XMLHttpRequest, WebSocket, analytics,
  telemetry, or project-server request.

- The project operates no server and does not send browsing history or
  detected links to the project author.

- The full destination is not stored in the added control's `href`, title,
  `data-*` attributes, or other page DOM. The original page already controls
  and can observe its own links.

- Clicking the added control intentionally passes the selected URL to the
  local protocol handler.

- The handler shows a redacted confirmation. After the first confirmation it
  may perform a DNS lookup only to warn about non-global addresses.

- After final confirmation, the handler passes the complete URL to VLC. VLC
  then contacts the destination server.

- The project does not automatically transfer Firefox cookies, login
  sessions, authorization headers, referrer state, DRM information, or browser
  storage to VLC. Authenticated media may therefore fail.

- A URL can contain a username, password, sensitive path, or temporary signed
  token. Do not log, share, or leave such URLs in screenshots.

- The project cannot control VLC's connections, credential handling, update
  checks, logging, telemetry, privacy, or security behavior.

- Tampermonkey and Firefox have their own update, synchronization, logging,
  and privacy behavior outside this project's control.

## Security notice

Clicking an added control causes VLC to make a network request to a
page-supplied destination after confirmation. Open destinations only from
sources you trust.

The handler validates syntax and protocol and never sends the URL through a
shell. Destination content is still processed by VLC and its media libraries.
Keep VLC, Firefox, Tampermonkey, Python, and the operating system updated. The
project does not guarantee that a detected link is safe, playable, authorized,
private, or free from malicious content.

SMB, SFTP, FTP, RTP, UDP, RTSP, and similar protocols may connect to local or
private systems. They may also involve credentials or device discovery.
Local/private warnings are advisory. DNS rebinding, resolver changes, proxies,
and differences between Python's and VLC's URL parsing cannot be eliminated.

A hostile page controls its links, layout, styles, text, and event handlers. It
may hide, cover, imitate, move, or remove the added control. It may also create
heavy DOM mutation activity. Treat the separate desktop confirmation, not the
page's visible **VLC** label, as the trusted decision point.

Untrusted synthetic click events are ignored, but no browser userscript can
make a hostile page trustworthy.

## Media, copyright, and website terms

This software does not grant permission to access, stream, copy, record, or
download media. Users are responsible for ensuring that their use of media
URLs and content complies with copyright law, website terms, contracts,
access restrictions, other applicable laws, and third-party rights.

The software is not designed to bypass digital rights management, paywalls,
authentication systems, or other access controls. Opening a URL in VLC does
not make access, streaming, copying, or downloading legally permitted.

## Known limitations

Media Link Launcher may not work with:

- DRM-protected streams or Encrypted Media Extensions;

- browser `blob:` URLs;

- Media Source Extensions when no direct network URL is exposed;

- sites requiring Firefox cookies or browser login sessions;

- sites requiring browser-only authorization headers;

- referer-restricted URLs;

- rapidly expiring signed URLs;

- JavaScript players that hide or construct stream addresses internally;

- extensionless links with no useful MIME, download, query, or HTML metadata;

- media loaded inside inaccessible cross-origin frames;

- websites whose scripts, Content Security Policy, DOM replacement, or layout
  interferes with injected controls;

- VLC builds lacking a needed protocol access module or codec;

- malformed URLs containing literal whitespace or control characters; or

- destinations that reject VLC's headers, TLS behavior, authentication, or
  user agent.

Heuristics can produce false positives and false negatives. Playback is never
guaranteed. Not every resource supported by VLC can be discovered from an
HTML anchor.

## Troubleshooting

### No bold VLC control appears

- Confirm that **Media Link Launcher** is enabled in Tampermonkey for the
  current site.

- Confirm that the page exposes an actual anchor (`a[href]`) with a direct
  URL.

- Check for a recognized path extension, MIME type, download filename,
  media-like query value, or direct-stream protocol.

- Expect no control for plain title text ending in `.mp4` unless its anchor
  also has a `download` attribute.

- Expect no control for `blob:`, `data:`, `file:`, or hidden player state.

### Firefox does not open the handler

- Run both protocol verification commands above.

- Confirm that they report `media-link-launcher.desktop`.

- Confirm that the installed desktop file is under the active XDG data home.

- Re-run the installer without `sudo`. It is idempotent and backs up verified
  project files before replacement.

- Review Firefox's external-protocol prompt and application choice.

### The desktop handler rejects a link

- Confirm that the target protocol appears in `allowed-schemes`.

- Confirm that the project configuration directory is mode `0700` and both
  configuration files are mode `0600` and owned by your user.

- Confirm that the request is not a local file or another prohibited scheme.

- Confirm that the URL has a host, a valid nonzero port if specified, no
  control characters, and no malformed outer encoding.

### No confirmation dialog appears

Install or enable Zenity, KDialog, or Python Tkinter. The handler fails closed
when none works. A rapid second request may also be quietly rate-limited while
another prompt is open.

### VLC opens but playback fails

The link may depend on cookies, browser headers, referrer checks, DRM, an
expired token, a missing VLC module, or an unavailable codec. The handler
validates and launches. It cannot make an inaccessible resource playable.

## Development checks

Run these from the package directory:

```bash
bash -n install-media-link-launcher.sh
```

```bash
bash -n uninstall-media-link-launcher.sh
```

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile media-link-launcher.py
```

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile tests/test_security.py
```

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile tests/test_installer.py
```

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile build-release.py
```

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
```

```bash
node --test tests/test_userscript.js
```

```bash
python3 build-release.py
```

Installer tests use temporary home and XDG directories, invoke the local
`xdg-mime`, and never launch VLC. Handler process launching is mocked in unit
tests.

## Licence and project-file scope

To the greatest extent permitted by law, this project's own source and
documentation are dedicated to the public domain under **CC0 1.0 Universal**.
CC0 supplies a public-licence fallback where a complete waiver is not legally
effective. The complete unmodified legal code is in
[LICENSE.md](LICENSE.md).

No personal legal name or copyright-holder notice has been added. CC0 calls
the person associating it with the work the "Affirmer." Applying CC0 is
intended to be irrevocable. A person should distribute the project under CC0
only to the extent they own or control the relevant rights.

Source inspection found no vendored third-party source or redistributed
third-party binary in this package. The project uses standard operating-system,
Python, browser, and VLC interfaces without bundling those programs.

The dedication and fallback licence apply only to this project's own source,
tests, templates, scripts, and documentation. They do not grant rights to VLC
media player, Firefox, Tampermonkey, Debian, Ubuntu, accessed media, websites,
or other third-party software or content. CC0 does not waive third-party rights
or grant trademark or patent rights.

[DISCLAIMER.md](DISCLAIMER.md) supplies separate additional warranty and
liability language without modifying CC0 or imposing a licence condition. In
summary, the software is provided "as is," without warranties or guarantees,
to the maximum extent permitted by law. Nothing excludes or limits liability
that cannot lawfully be excluded or limited. These files are general project
documentation, not legal advice.

## Legal, trademark, and affiliation notice

This is an independent, third-party public-domain/open-source project. It is
not produced, sponsored, endorsed, approved, or supported by VideoLAN, the
Mozilla Foundation, Canonical Ltd., Software in the Public Interest, Inc., the
Debian Project, or the developers of Tampermonkey.

This project does not include or redistribute VLC media player, Firefox,
Ubuntu, Debian, or Tampermonkey. Users must obtain those programs from their
official sources and comply with their applicable licences and terms.

VideoLAN, VLC, and VLC media player are trademarks internationally registered
by the VideoLAN non-profit organization.

Firefox is a trademark of the Mozilla Foundation in the United States and
other countries.

Ubuntu and Canonical are registered trademarks of Canonical Ltd.

Debian is a registered trademark owned by Software in the Public Interest,
Inc. and managed by the Debian Project.

All other trademarks belong to their respective owners. Trademark names are
used only to identify compatible third-party software. They do not imply
affiliation, sponsorship, endorsement, approval, or support.

The project uses no organization logo and does not use the VLC traffic-cone
logo. The wording and neutral naming were reviewed in good faith on
July 18, 2026, against [VideoLAN's notice][videolan-legal], the
[Mozilla Trademark Guidelines][mozilla-trademarks],
[Canonical's Intellectual Property Rights Policy][canonical-ip], and the
[Debian Trademark Policy][debian-trademarks]. Those policies can change. This
review is not legal approval or legal advice. Professional legal review is
advisable before wide or commercial distribution.

[firefox]: https://www.mozilla.org/firefox/new/
[tampermonkey]: https://www.tampermonkey.net/index.php?browser=firefox&locale=en
[vlc]: https://www.videolan.org/vlc/
[python]: https://www.python.org/downloads/
[xdg-utils]: https://www.freedesktop.org/wiki/Software/xdg-utils/
[videolan-legal]: https://www.videolan.org/legal.html
[mozilla-trademarks]: https://www.mozilla.org/foundation/trademarks/policy/
[canonical-ip]: https://canonical.com/legal/intellectual-property-policy
[debian-trademarks]: https://www.debian.org/trademark
