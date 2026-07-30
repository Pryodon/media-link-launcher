# Changelog

All notable changes to Media Link Launcher are documented here.

## 0.2.0 — 2026-07-18

### Changed

- Renamed the project from **VLC media links for Firefox on Debian and Ubuntu**
  to **Media Link Launcher**, with the descriptive subtitle “Open web media
  links in VLC media player.”
- Replaced the project-owned `vlc://` operating-system protocol with
  `media-link-launcher://open?url=...` and
  `x-scheme-handler/media-link-launcher`. Version 0.2.0 is therefore not
  protocol-compatible with the 0.1.0 userscript or handler.
- Renamed operational files, installed paths, desktop identifiers,
  configuration paths, state paths, and userscript metadata to neutral
  project-owned identifiers.
- Changed persistent event logging from enabled to disabled by default.
  Opt-in logs omit hosts, credentials, paths, queries, fragments, and
  destination URLs.
- Changed visible-text detection so text ending in a media extension is only
  a supporting heuristic when the anchor also has an explicit `download`
  attribute. This reduces false positives such as linked conversation titles
  ending in `.mp4`.
- Changed compatibility wording to distinguish tested Debian desktop behavior
  from untested XDG-compatible Linux environments.

### Security

- Added exact custom-protocol scheme, action, path, fragment, parameter-count,
  percent-encoding, UTF-8, length, control-character, hostname, port, and
  target-scheme checks.
- Retained HTTP and HTTPS as the only default target protocols. FTP, FTPS,
  SFTP, SMB, RTSP, RTSPS, RTMP, RTMPS, MMS, MMSH, MMST, RTP, and UDP require
  explicit configuration.
- Retained trusted-click enforcement, per-request desktop confirmation, prompt
  locking and throttling, local/private-address warnings, fixed executable
  paths, shell-free argument-list launching, and the VLC `--` option
  separator.
- Hid credential, path, query, and fragment values from confirmation dialogs
  and removed destination data from error notifications.
- Added manifest hashes and ownership checks so reinstall and uninstall do not
  overwrite or delete unrelated or modified files.
- Switched the userscript to `@grant none` and Tampermonkey’s DOM-only sandbox
  mode.

### Migration and installation

- Added idempotent per-user installation under XDG/freedesktop user
  directories without `sudo`.
- Added automatic 0.1.0 migration that requires both a normalized
  known-handler hash and an exact known desktop entry before backing up and
  removing old operational files.
- The old protocol default is changed only when it currently points to the
  verified project-owned 0.1.0 desktop entry. A safely recorded earlier
  handler is restored when available.
- Ambiguous, modified, incomplete, or unrelated old handlers and associations
  are retained unchanged.
- Legacy 0.1.0 configuration, logs, state, and backups are retained for manual
  review.
- Added a separate safe uninstaller, desktop template, deterministic release
  builder, timestamped backups, registration verification, and
  temporary-`HOME` installation tests.

### Documentation and legal notices

- Moved the unmodified CC0 1.0 Universal legal code to `LICENSE.md` and added
  a separate non-license `DISCLAIMER.md`.
- Added independent-project, trademark, affiliation, privacy, security,
  media-use, and website-terms notices.
- Clarified that this project is a userscript plus operating-system protocol
  handler, not a VLC plugin or Firefox extension produced by VLC.
- Documented configuration, logging controls, deletion of optional logs,
  migration, rollback, verification with both `gio mime` and `xdg-mime`,
  limitations, and protocol risks.
