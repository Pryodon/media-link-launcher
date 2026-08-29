#!/usr/bin/env python3
"""Build a deterministic Media Link Launcher release archive."""

from __future__ import annotations

import hashlib
import os
import stat
import tempfile
import zipfile
from pathlib import Path


VERSION = "0.2.1"
TOP_LEVEL = "media-link-launcher-linux"
PACKAGE_DIR = Path(__file__).resolve().parent
REPOSITORY_ROOT = PACKAGE_DIR.parent
REPOSITORY_LAYOUT = PACKAGE_DIR.name == "linux" and (
    REPOSITORY_ROOT / "userscript" / "media-link-launcher.user.js"
).is_file()
OUTPUT = REPOSITORY_ROOT / f"{TOP_LEVEL}-{VERSION}.zip"

RELEASE_FILES = (
    "README.md",
    "LICENSE.md",
    "DISCLAIMER.md",
    "CHANGELOG.md",
    "install-media-link-launcher.sh",
    "uninstall-media-link-launcher.sh",
    "media-link-launcher.user.js",
    "USERSCRIPT-SHA256.txt",
    "media-link-launcher.py",
    "media-link-launcher.desktop.in",
    "build-release.py",
    "tests/test_security.py",
    "tests/test_installer.py",
    "tests/test_userscript.js",
)

EXECUTABLE_FILES = {
    "install-media-link-launcher.sh",
    "uninstall-media-link-launcher.sh",
    "build-release.py",
}


def archive_info(name: str, mode: int, *, directory: bool = False) -> zipfile.ZipInfo:
    if directory and not name.endswith("/"):
        name += "/"
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    file_type = stat.S_IFDIR if directory else stat.S_IFREG
    info.external_attr = (file_type | mode) << 16
    if directory:
        info.external_attr |= 0x10
    return info


def source_path(relative_name: str) -> Path:
    if not REPOSITORY_LAYOUT:
        return PACKAGE_DIR / relative_name
    if relative_name in {"LICENSE.md", "DISCLAIMER.md"}:
        return REPOSITORY_ROOT / relative_name
    if relative_name in {"media-link-launcher.user.js", "USERSCRIPT-SHA256.txt"}:
        return REPOSITORY_ROOT / "userscript" / relative_name
    if relative_name == "tests/test_userscript.js":
        return REPOSITORY_ROOT / "userscript" / "tests" / "test_userscript.js"
    return PACKAGE_DIR / relative_name


def validated_source(relative_name: str) -> Path:
    source = source_path(relative_name)
    if source.is_symlink() or not source.is_file():
        raise SystemExit(
            f"Missing, symbolic, or non-regular release file: "
            f"{relative_name} ({source})"
        )
    return source


def validate_userscript_checksum() -> None:
    userscript = validated_source("media-link-launcher.user.js")
    checksum_file = validated_source("USERSCRIPT-SHA256.txt")
    expected = (
        f"{hashlib.sha256(userscript.read_bytes()).hexdigest()}  "
        "media-link-launcher.user.js\n"
    )
    try:
        actual = checksum_file.read_text(encoding="ascii")
    except UnicodeDecodeError as error:
        raise SystemExit("The shared userscript checksum is not ASCII.") from error
    if actual != expected:
        raise SystemExit("The shared userscript checksum is stale or malformed.")


def build() -> tuple[Path, str]:
    validate_userscript_checksum()
    sources = [(name, validated_source(name)) for name in RELEASE_FILES]
    temporary_fd, temporary_name = tempfile.mkstemp(
        prefix=f".{OUTPUT.name}.",
        suffix=".tmp",
        dir=OUTPUT.parent,
    )
    os.close(temporary_fd)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(
            temporary,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as archive:
            archive.writestr(
                archive_info(TOP_LEVEL, 0o755, directory=True),
                b"",
            )
            archive.writestr(
                archive_info(f"{TOP_LEVEL}/tests", 0o755, directory=True),
                b"",
            )
            for relative_name, source in sources:
                mode = 0o755 if relative_name in EXECUTABLE_FILES else 0o644
                destination = f"{TOP_LEVEL}/{relative_name}"
                archive.writestr(
                    archive_info(destination, mode),
                    source.read_bytes(),
                )

        with zipfile.ZipFile(temporary) as archive:
            names = archive.namelist()
            expected = [f"{TOP_LEVEL}/", f"{TOP_LEVEL}/tests/"]
            expected.extend(f"{TOP_LEVEL}/{name}" for name in RELEASE_FILES)
            if names != expected:
                raise SystemExit("Archive content verification failed.")
            bad_name = next(
                (
                    name
                    for name in names
                    if name.startswith("/")
                    or ".." in Path(name).parts
                    or not name.startswith(f"{TOP_LEVEL}/")
                ),
                None,
            )
            if bad_name:
                raise SystemExit(f"Unsafe archive member: {bad_name}")
            if archive.testzip() is not None:
                raise SystemExit("Archive CRC verification failed.")

        os.replace(temporary, OUTPUT)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass

    digest = hashlib.sha256(OUTPUT.read_bytes()).hexdigest()
    return OUTPUT, digest


if __name__ == "__main__":
    output, checksum = build()
    print(f"Built: {output}")
    print(f"SHA-256: {checksum}")
