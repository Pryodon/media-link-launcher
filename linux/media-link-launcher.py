#!/usr/bin/env python3
"""Validated, user-confirmed media-link-launcher protocol handler."""

from __future__ import annotations

import contextlib
import datetime
import fcntl
import html
import ipaddress
import os
import re
import socket
import stat
import subprocess
import sys
import time
import urllib.parse
from dataclasses import dataclass
from pathlib import Path


VERSION = "0.2.1"
PROJECT_ID = "media-link-launcher"
PROTOCOL_SCHEME = "media-link-launcher"
PROTOCOL_ACTION = "open"
VLC_EXECUTABLE = "__VLC_EXECUTABLE__"

SUPPORTED_SCHEMES = frozenset(
    {
        "http",
        "https",
        "ftp",
        "ftps",
        "sftp",
        "smb",
        "rtsp",
        "rtsps",
        "rtmp",
        "rtmps",
        "mms",
        "mmsh",
        "mmst",
        "rtp",
        "udp",
    }
)
DEFAULT_ALLOWED_SCHEMES = frozenset({"http", "https"})
MAX_INVOCATION_LENGTH = 32768
MAX_TARGET_LENGTH = 16384
MIN_PROMPT_INTERVAL_SECONDS = 3.0
PROMPT_TIMEOUT_SECONDS = 120

CONTROL_CHARACTER_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")
INVALID_PERCENT_ESCAPE_RE = re.compile(r"%(?![0-9a-fA-F]{2})")
SAFE_LOG_VALUE_RE = re.compile(r"[^a-zA-Z0-9_-]")
LOCAL_HOST_SUFFIXES = (".localhost", ".local", ".lan", ".home", ".internal")


class HandlerError(Exception):
    """An expected handler failure whose message contains no destination data."""

    def __init__(self, message: str, category: str = "request_rejected") -> None:
        super().__init__(message)
        self.category = category


class QuietRejection(HandlerError):
    """A throttled request that must not create notification or log spam."""


@dataclass(frozen=True)
class Target:
    raw: str
    scheme: str
    hostname: str
    port: int | None
    has_username: bool
    has_password: bool
    has_path: bool
    has_query: bool
    has_fragment: bool


def xdg_directory(environment_name: str, fallback: Path) -> Path:
    value = os.environ.get(environment_name)
    if value:
        path = Path(value).expanduser()
        if not path.is_absolute():
            raise HandlerError(
                f"{environment_name} must be an absolute path.",
                "invalid_environment",
            )
        return path
    return fallback


def state_directory() -> Path:
    base = xdg_directory("XDG_STATE_HOME", Path.home() / ".local" / "state")
    return base / PROJECT_ID


def config_directory() -> Path:
    base = xdg_directory("XDG_CONFIG_HOME", Path.home() / ".config")
    return base / PROJECT_ID


def schemes_config_file() -> Path:
    return config_directory() / "allowed-schemes"


def logging_config_file() -> Path:
    return config_directory() / "logging"


def ensure_private_directory(path: Path) -> None:
    if path.is_symlink():
        raise HandlerError(
            "The handler state directory must not be a symbolic link.",
            "unsafe_state",
        )
    if path.exists() and not path.is_dir():
        raise HandlerError("The handler state path is not a directory.", "unsafe_state")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def open_private_regular_file(path: Path, flags: int, mode: int = 0o600) -> int:
    if path.exists() or path.is_symlink():
        existing = path.lstat()
        if not stat.S_ISREG(existing.st_mode):
            raise HandlerError(
                f"Refusing non-regular state file: {path.name}",
                "unsafe_state",
            )

    safe_flags = flags | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(path, safe_flags, mode)
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode):
        os.close(fd)
        raise HandlerError(
            f"Refusing non-regular state file: {path.name}",
            "unsafe_state",
        )
    os.fchmod(fd, mode)
    return fd


def validate_private_config_file(path: Path, maximum_size: int = 4096) -> bool:
    if not path.exists() and not path.is_symlink():
        return False

    parent = path.parent
    if parent.is_symlink() or not parent.is_dir():
        raise HandlerError("The configuration directory is unsafe.", "unsafe_config")
    parent_metadata = parent.stat()
    if parent_metadata.st_uid != os.getuid() or parent_metadata.st_mode & 0o077:
        raise HandlerError(
            "The configuration directory must be owned by you and mode 0700.",
            "unsafe_config",
        )

    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise HandlerError("A configuration file is not regular.", "unsafe_config")
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise HandlerError(
            "Configuration files must be owned by you and mode 0600.",
            "unsafe_config",
        )
    if metadata.st_size > maximum_size:
        raise HandlerError("A configuration file is too large.", "invalid_config")
    return True


def load_allowed_schemes(path: Path | None = None) -> frozenset[str]:
    path = path or schemes_config_file()
    if not validate_private_config_file(path):
        return DEFAULT_ALLOWED_SCHEMES

    configured: set[str] = set()
    try:
        with path.open("r", encoding="utf-8", errors="strict") as handle:
            for line in handle:
                value = line.partition("#")[0].strip().lower()
                if not value:
                    continue
                if value not in SUPPORTED_SCHEMES:
                    raise HandlerError(
                        "The allowed-schemes configuration contains an unsupported value.",
                        "invalid_config",
                    )
                configured.add(value)
    except UnicodeError as exc:
        raise HandlerError(
            "The allowed-schemes configuration is not valid UTF-8.",
            "invalid_config",
        ) from exc

    if not configured:
        raise HandlerError(
            "The allowed-schemes configuration is empty.",
            "invalid_config",
        )
    return frozenset(configured)


def load_logging_enabled(path: Path | None = None) -> bool:
    path = path or logging_config_file()
    if not validate_private_config_file(path, maximum_size=128):
        return False

    try:
        values = [
            line.partition("#")[0].strip().lower()
            for line in path.read_text(encoding="utf-8", errors="strict").splitlines()
            if line.partition("#")[0].strip()
        ]
    except UnicodeError as exc:
        raise HandlerError(
            "The logging configuration is not valid UTF-8.",
            "invalid_config",
        ) from exc

    if values == ["enabled"]:
        return True
    if values == ["disabled"]:
        return False
    raise HandlerError(
        "The logging configuration must contain either enabled or disabled.",
        "invalid_config",
    )


def safe_log_value(value: str) -> str:
    return SAFE_LOG_VALUE_RE.sub("_", value)[:64]


def log_event(
    event: str,
    *,
    enabled: bool,
    scheme: str | None = None,
    category: str | None = None,
) -> None:
    if not enabled:
        return
    try:
        directory = state_directory()
        ensure_private_directory(directory)
        log_path = directory / "events.log"
        fd = open_private_regular_file(
            log_path,
            os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NONBLOCK", 0),
        )
        timestamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        fields = [timestamp, f"event={safe_log_value(event)}"]
        if scheme:
            fields.append(f"scheme={safe_log_value(scheme)}")
        if category:
            fields.append(f"category={safe_log_value(category)}")
        with os.fdopen(fd, "a", encoding="utf-8") as handle:
            handle.write(" ".join(fields) + "\n")
    except Exception:
        # Logging must never expose destination data or change fail-closed behavior.
        pass


def notify(message: str) -> None:
    notifier = Path("/usr/bin/notify-send")
    if not notifier.is_file() or not os.access(notifier, os.X_OK):
        return
    try:
        subprocess.run(
            [str(notifier), "Media Link Launcher", message],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def reject_invocation_characters(value: str) -> None:
    if not value.isascii():
        raise HandlerError(
            "The protocol request must use ASCII percent encoding.",
            "malformed_invocation",
        )
    if CONTROL_CHARACTER_RE.search(value) or any(character.isspace() for character in value):
        raise HandlerError(
            "The protocol request contains a control character or whitespace.",
            "malformed_invocation",
        )
    if INVALID_PERCENT_ESCAPE_RE.search(value):
        raise HandlerError(
            "The protocol request contains malformed percent encoding.",
            "malformed_invocation",
        )


def reject_target_characters(value: str) -> None:
    if CONTROL_CHARACTER_RE.search(value) or any(character.isspace() for character in value):
        raise HandlerError(
            "The media URL contains a control character or unencoded whitespace.",
            "invalid_target",
        )

    decoded_bytes = urllib.parse.unquote_to_bytes(value)
    if any(byte < 0x20 or byte == 0x7F for byte in decoded_bytes):
        raise HandlerError(
            "The media URL contains an encoded control character.",
            "invalid_target",
        )
    try:
        decoded_text = decoded_bytes.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return
    if CONTROL_CHARACTER_RE.search(decoded_text):
        raise HandlerError(
            "The media URL contains an encoded control character.",
            "invalid_target",
        )


def decode_invocation(invocation_uri: str) -> str:
    if len(invocation_uri) > MAX_INVOCATION_LENGTH:
        raise HandlerError("The protocol request is too long.", "oversized_invocation")
    reject_invocation_characters(invocation_uri)

    try:
        parsed = urllib.parse.urlsplit(invocation_uri)
    except ValueError as exc:
        raise HandlerError(
            "The protocol request is malformed.",
            "malformed_invocation",
        ) from exc

    if parsed.scheme != PROTOCOL_SCHEME:
        raise HandlerError(
            "The invocation did not use the expected protocol.",
            "wrong_protocol",
        )
    if parsed.netloc != PROTOCOL_ACTION or parsed.path != "":
        raise HandlerError("The protocol request has an invalid action.", "wrong_action")
    if parsed.fragment:
        raise HandlerError(
            "The protocol request must not contain an outer fragment.",
            "ambiguous_invocation",
        )

    try:
        values = urllib.parse.parse_qsl(
            parsed.query,
            keep_blank_values=True,
            strict_parsing=True,
            encoding="utf-8",
            errors="strict",
            max_num_fields=2,
        )
    except (UnicodeError, ValueError) as exc:
        raise HandlerError(
            "The protocol request has an invalid query.",
            "malformed_invocation",
        ) from exc

    if len(values) != 1 or values[0][0] != "url" or not values[0][1]:
        raise HandlerError(
            "The protocol request must contain exactly one named media URL.",
            "ambiguous_invocation",
        )

    target = values[0][1]
    if len(target) > MAX_TARGET_LENGTH:
        raise HandlerError("The media URL is too long.", "oversized_target")
    reject_target_characters(target)
    return target


def normalize_hostname(hostname: str) -> str:
    candidate = hostname.rstrip(".")
    if not candidate or "%" in candidate:
        raise HandlerError("The media URL has an invalid hostname.", "invalid_target")
    try:
        return str(ipaddress.ip_address(candidate))
    except ValueError:
        pass

    try:
        normalized = candidate.encode("idna").decode("ascii").lower()
    except UnicodeError as exc:
        raise HandlerError("The media URL has an invalid hostname.", "invalid_target") from exc
    if len(normalized) > 253 or any(not label or len(label) > 63 for label in normalized.split(".")):
        raise HandlerError("The media URL has an invalid hostname.", "invalid_target")
    return normalized


def parse_target(target: str, allowed_schemes: frozenset[str]) -> Target:
    if not target or len(target) > MAX_TARGET_LENGTH:
        raise HandlerError("The media URL has an invalid length.", "invalid_target")
    reject_target_characters(target)
    try:
        parsed = urllib.parse.urlsplit(target)
    except ValueError as exc:
        raise HandlerError("The media URL is malformed.", "invalid_target") from exc

    scheme = parsed.scheme.lower()
    if scheme not in allowed_schemes:
        raise HandlerError("The target protocol is not enabled.", "unsupported_scheme")
    if "\\" in parsed.netloc:
        raise HandlerError(
            "Backslashes are not allowed in the URL authority.",
            "invalid_target",
        )

    try:
        hostname = parsed.hostname
        port = parsed.port
        username = parsed.username
        password = parsed.password
    except ValueError as exc:
        raise HandlerError(
            "The media URL has an invalid hostname or port.",
            "invalid_target",
        ) from exc

    if not hostname:
        raise HandlerError("The media URL must contain a hostname.", "invalid_target")
    if port == 0:
        raise HandlerError("Port zero is not allowed.", "invalid_target")
    if password is not None and not username:
        raise HandlerError("A password requires a username.", "invalid_target")

    return Target(
        raw=target,
        scheme=scheme,
        hostname=normalize_hostname(hostname),
        port=port,
        has_username=username is not None,
        has_password=password is not None,
        has_path=bool(parsed.path and parsed.path != "/"),
        has_query=bool(parsed.query),
        has_fragment=bool(parsed.fragment),
    )


def host_scope_warning(hostname: str) -> str | None:
    normalized = hostname.rstrip(".").lower()
    if normalized == "localhost" or normalized.endswith(LOCAL_HOST_SUFFIXES):
        return "WARNING: This destination appears to be on your local network."

    try:
        address = ipaddress.ip_address(normalized)
    except ValueError:
        return None
    if not address.is_global:
        return "WARNING: This is a local, private, link-local, or reserved IP address."
    return None


def resolved_scope_warning(hostname: str, port: int | None) -> str | None:
    try:
        results = socket.getaddrinfo(hostname, port or 0)
    except OSError:
        return None

    for result in results:
        address_text = result[4][0]
        try:
            address = ipaddress.ip_address(address_text)
        except ValueError:
            continue
        if not address.is_global:
            return (
                "WARNING: This hostname resolves to a local, private, "
                "link-local, or reserved address."
            )
    return None


def confirmation_text(target: Target, warning: str | None = None) -> str:
    port = str(target.port) if target.port is not None else "default"
    lines = [
        "A website requested that VLC media player open a network destination:",
        "",
        f"Protocol: {target.scheme.upper()}",
        f"Host: {target.hostname}",
        f"Port: {port}",
        f"Credentials present: {'yes' if target.has_username or target.has_password else 'no'}",
        f"Path present: {'yes' if target.has_path else 'no'}",
        f"Query present: {'yes' if target.has_query else 'no'}",
        f"Fragment present: {'yes' if target.has_fragment else 'no'}",
        "",
        "Credentials, path, query, and fragment values are hidden because any of them may contain sensitive data.",
    ]
    if warning:
        lines.extend(("", warning))
    lines.extend(("", "Open this destination in VLC media player?"))
    return "\n".join(lines)


def confirm_with_zenity(message: str) -> bool | None:
    executable = Path("/usr/bin/zenity")
    if not executable.is_file() or not os.access(executable, os.X_OK):
        return None
    try:
        result = subprocess.run(
            [
                str(executable),
                "--question",
                "--title=Media Link Launcher",
                f"--text={html.escape(message)}",
                "--ok-label=Open in VLC",
                "--cancel-label=Cancel",
                "--width=600",
                f"--timeout={PROMPT_TIMEOUT_SECONDS}",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=PROMPT_TIMEOUT_SECONDS + 5,
        )
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def confirm_with_kdialog(message: str) -> bool | None:
    executable = Path("/usr/bin/kdialog")
    if not executable.is_file() or not os.access(executable, os.X_OK):
        return None
    try:
        result = subprocess.run(
            [
                str(executable),
                "--warningyesno",
                message,
                "--title",
                "Media Link Launcher",
                "--yes-label",
                "Open in VLC",
                "--no-label",
                "Cancel",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=PROMPT_TIMEOUT_SECONDS + 5,
        )
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def confirm_with_tkinter(message: str) -> bool | None:
    try:
        import tkinter
        from tkinter import messagebox

        root = tkinter.Tk()
        root.withdraw()
        root.attributes("-topmost", True)
        root.after(PROMPT_TIMEOUT_SECONDS * 1000, root.destroy)
        try:
            return bool(messagebox.askokcancel("Media Link Launcher", message, parent=root))
        finally:
            try:
                root.destroy()
            except tkinter.TclError:
                pass
    except Exception:
        return None


def confirm_target(target: Target, warning: str | None = None) -> bool:
    message = confirmation_text(target, warning)
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").lower()
    confirmers = (
        (confirm_with_kdialog, confirm_with_zenity, confirm_with_tkinter)
        if "kde" in desktop
        else (confirm_with_zenity, confirm_with_kdialog, confirm_with_tkinter)
    )
    for confirmer in confirmers:
        result = confirmer(message)
        if result is not None:
            return result
    raise HandlerError(
        "No supported desktop confirmation dialog is available.",
        "confirmation_unavailable",
    )


@contextlib.contextmanager
def exclusive_handler_lock(directory: Path):
    lock_path = directory / "handler.lock"
    fd = open_private_regular_file(
        lock_path,
        os.O_RDWR | os.O_CREAT | getattr(os, "O_NONBLOCK", 0),
    )
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise QuietRejection(
                "Another confirmation is already open.",
                "prompt_busy",
            ) from exc
        yield
    finally:
        os.close(fd)


def enforce_prompt_interval(directory: Path) -> None:
    timestamp_path = directory / "last-prompt"
    previous = 0.0
    if timestamp_path.exists() or timestamp_path.is_symlink():
        metadata = timestamp_path.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            raise HandlerError(
                "The prompt timestamp must be a regular file.",
                "unsafe_state",
            )
        try:
            previous = float(timestamp_path.read_text(encoding="ascii").strip())
        except (OSError, UnicodeError, ValueError):
            previous = 0.0

    now = time.time()
    if previous > 0 and now - previous < MIN_PROMPT_INTERVAL_SECONDS:
        raise QuietRejection("Requests are arriving too quickly.", "prompt_throttled")

    fd = open_private_regular_file(
        timestamp_path,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NONBLOCK", 0),
    )
    with os.fdopen(fd, "w", encoding="ascii") as handle:
        handle.write(f"{now:.6f}\n")


def launch_vlc(target: Target) -> None:
    executable = Path(VLC_EXECUTABLE)
    if (
        not executable.is_absolute()
        or not executable.is_file()
        or not os.access(executable, os.X_OK)
    ):
        raise HandlerError(
            "The VLC executable recorded during installation is unavailable.",
            "vlc_unavailable",
        )

    subprocess.Popen(
        [str(executable), "--", target.raw],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )


def main() -> int:
    target: Target | None = None
    logging_enabled = False
    previous_umask = os.umask(0o077)
    try:
        if len(sys.argv) != 2:
            raise HandlerError(
                "Expected exactly one protocol request.",
                "wrong_argument_count",
            )

        allowed_schemes = load_allowed_schemes()
        logging_enabled = load_logging_enabled()
        raw_target = decode_invocation(sys.argv[1])
        target = parse_target(raw_target, allowed_schemes)

        directory = state_directory()
        ensure_private_directory(directory)
        with exclusive_handler_lock(directory):
            enforce_prompt_interval(directory)
            warning = host_scope_warning(target.hostname)
            if not confirm_target(target, warning):
                log_event(
                    "cancelled",
                    enabled=logging_enabled,
                    scheme=target.scheme,
                    category="user_cancelled",
                )
                return 1

            resolved_warning = resolved_scope_warning(target.hostname, target.port)
            if resolved_warning and not warning:
                if not confirm_target(target, resolved_warning):
                    log_event(
                        "cancelled",
                        enabled=logging_enabled,
                        scheme=target.scheme,
                        category="private_destination_cancelled",
                    )
                    return 1

            launch_vlc(target)
            log_event("launched", enabled=logging_enabled, scheme=target.scheme)
            return 0
    except QuietRejection:
        return 1
    except HandlerError as exc:
        log_event(
            "rejected",
            enabled=logging_enabled,
            scheme=target.scheme if target else None,
            category=exc.category,
        )
        notify(str(exc))
        return 1
    except Exception:
        log_event(
            "failed",
            enabled=logging_enabled,
            scheme=target.scheme if target else None,
            category="internal_error",
        )
        notify("The media request failed safely.")
        return 1
    finally:
        os.umask(previous_umask)


if __name__ == "__main__":
    raise SystemExit(main())
