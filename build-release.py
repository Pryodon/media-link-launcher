#!/usr/bin/env python3
"""Build a deterministic Media Link Launcher release archive."""

from __future__ import annotations

import hashlib
import os
import stat
import tempfile
import zipfile
from pathlib import Path


VERSION = "0.2.0"
TOP_LEVEL = "media-link-launcher-linux"
PACKAGE_DIR = Path(__file__).resolve().parent
OUTPUT = PACKAGE_DIR.parent / f"{TOP_LEVEL}-{VERSION}.zip"

RELEASE_FILES = (
    "README.md",
    "LICENSE.md",
    "DISCLAIMER.md",
    "CHANGELOG.md",
    "install-media-link-launcher.sh",
    "uninstall-media-link-launcher.sh",
    "media-link-launcher.user.js",
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


def validated_source(relative_name: str) -> Path:
    source = PACKAGE_DIR / relative_name
    if source.is_symlink() or not source.is_file():
        raise SystemExit(f"Missing, symbolic, or non-regular release file: {relative_name}")
    return source


def build() -> tuple[Path, str]:
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
