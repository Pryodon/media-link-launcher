# Changelog

## Windows 0.2.1 — 2026-08-28

### Fixed

- Added VLC controls to recognized media anchors in XHTML documents served as
  XML, including Icecast-style `.m3u` and `.xspf` playlist links.
- Created injected style and control elements in the XHTML namespace and made
  anchor recognition safe across HTML and XML/XHTML DOM implementations.

### Packaging

- Moved the canonical shared-userscript checksum beside the userscript and
  retained the checksum at package root in both release ZIPs.
- Added XML/XHTML regression coverage and bumped all Windows package version
  metadata to 0.2.1.

## Windows 0.2.0 — 2026-07-24

### Fixed

- Accepted the single root slash that Windows URI canonicalization inserts
  when a custom URI has an authority and an empty path:
  `media-link-launcher://open/?url=...`.
- Continued accepting the userscript's original
  `media-link-launcher://open?url=...` form and rejecting every other action
  or path.
- Preserved the already-secured per-user installation directory during
  upgrades instead of reapplying ownership metadata that Windows may reject
  without a security privilege.

### Added

- Added a Windows 10 and Windows 11 package using Windows PowerShell 5.1
  components already included with Windows.
- Added a current-user installer and uninstaller with no administrator
  requirement.
- Added current-user `media-link-launcher` URL-protocol registration.
- Added strict invocation and target validation, redacted confirmations,
  prompt serialization, rate limiting, local/private-address warnings, DNS
  scope checks, optional redacted logging, and fixed-path VLC launching.
- Added non-destructive Windows security and parsing tests.
- Added deterministic Windows release ZIP creation.

### Compatibility

- Kept `media-link-launcher.user.js` byte-for-byte identical to Linux 0.2.0.
- Kept the `media-link-launcher://open?url=...` protocol compatible with
  Linux 0.2.0.
- Removed the Windows need for Python; Python remains part of the separate
  Linux implementation.

### Packaging and licensing

- Included only project-owned CC0 source, tests, scripts, and documentation.
- Did not bundle VLC, Firefox, Tampermonkey, Python, PowerShell, .NET
  Framework, or another third-party source or binary.
