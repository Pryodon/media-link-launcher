from __future__ import annotations

import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile


PACKAGE_DIR = pathlib.Path(__file__).resolve().parents[1]
PROJECT_ROOT = PACKAGE_DIR.parent
INSTALLER = PACKAGE_DIR / "install-media-link-launcher.sh"
UNINSTALLER = PACKAGE_DIR / "uninstall-media-link-launcher.sh"
OLD_ARCHIVE = PROJECT_ROOT / "auto-open-media-links-in-vlc-debian-ubuntu-linux-0.1.0.zip"


class InstallerIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.home = self.root / "Home With Space"
        self.home.mkdir(mode=0o700)
        self.data = self.home / "xdg data"
        self.config = self.home / "xdg config"
        self.state = self.home / "xdg state"
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "HOME": str(self.home),
                "XDG_DATA_HOME": str(self.data),
                "XDG_CONFIG_HOME": str(self.config),
                "XDG_STATE_HOME": str(self.state),
                "LC_ALL": "C",
                "PYTHONDONTWRITEBYTECODE": "1",
            }
        )

    @property
    def handler(self) -> pathlib.Path:
        return self.home / ".local" / "bin" / "media-link-launcher"

    @property
    def desktop(self) -> pathlib.Path:
        return self.data / "applications" / "media-link-launcher.desktop"

    @property
    def state_dir(self) -> pathlib.Path:
        return self.state / "media-link-launcher"

    @property
    def config_dir(self) -> pathlib.Path:
        return self.config / "media-link-launcher"

    def run_script(
        self,
        script: pathlib.Path = INSTALLER,
        *arguments: str,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["bash", str(script), *arguments],
            env=self.environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            timeout=30,
        )
        if check and result.returncode != 0:
            self.fail(
                f"Command failed with exit {result.returncode}:\n{result.stdout}"
            )
        return result

    def query_default(self, mime_type: str) -> str:
        result = subprocess.run(
            ["xdg-mime", "query", "default", mime_type],
            env=self.environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            timeout=10,
        )
        return result.stdout.strip()

    def set_default(self, desktop_id: str, mime_type: str) -> None:
        result = subprocess.run(
            ["xdg-mime", "default", desktop_id, mime_type],
            env=self.environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            timeout=10,
        )
        if result.returncode != 0:
            self.fail(f"Unable to prepare test MIME association:\n{result.stdout}")

    def test_install_is_idempotent_private_and_uninstalls_safely(self) -> None:
        first = self.run_script()
        self.assertIn("Installed Media Link Launcher 0.2.0", first.stdout)
        self.assertEqual(
            self.query_default("x-scheme-handler/media-link-launcher"),
            "media-link-launcher.desktop",
        )
        self.assertTrue(self.handler.is_file())
        self.assertTrue(self.desktop.is_file())
        self.assertEqual(stat.S_IMODE(self.handler.stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(self.desktop.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(self.config_dir.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.state_dir.stat().st_mode), 0o700)
        self.assertEqual(
            stat.S_IMODE((self.config_dir / "allowed-schemes").stat().st_mode),
            0o600,
        )
        self.assertEqual(
            stat.S_IMODE((self.config_dir / "logging").stat().st_mode), 0o600
        )
        self.assertEqual(
            (self.config_dir / "allowed-schemes").read_text(encoding="utf-8")
            .splitlines()[-2:],
            ["http", "https"],
        )
        self.assertEqual(
            (self.config_dir / "logging").read_text(encoding="utf-8")
            .splitlines()[-1],
            "disabled",
        )
        self.assertIn(
            "MimeType=x-scheme-handler/media-link-launcher;",
            self.desktop.read_text(encoding="utf-8"),
        )
        self.assertIn(
            'PROTOCOL_SCHEME = "media-link-launcher"',
            self.handler.read_text(encoding="utf-8"),
        )

        second = self.run_script()
        self.assertIn("Installed Media Link Launcher 0.2.0", second.stdout)
        backup_directories = list((self.state_dir / "backups").iterdir())
        self.assertGreaterEqual(len(backup_directories), 2)

        uninstall = self.run_script(UNINSTALLER)
        self.assertIn("Uninstall backup:", uninstall.stdout)
        self.assertFalse(self.handler.exists())
        self.assertFalse(self.desktop.exists())
        self.assertNotEqual(
            self.query_default("x-scheme-handler/media-link-launcher"),
            "media-link-launcher.desktop",
        )
        self.assertTrue(self.config_dir.is_dir())
        self.assertTrue((self.state_dir / "backups").is_dir())

        repeated = self.run_script(UNINSTALLER)
        self.assertIn("already absent", repeated.stdout)

    def test_unrelated_new_destination_causes_refusal_before_changes(self) -> None:
        self.handler.parent.mkdir(parents=True, mode=0o755)
        self.handler.write_text("unrelated program\n", encoding="utf-8")
        self.handler.chmod(0o755)

        result = self.run_script(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to overwrite an unrelated handler", result.stdout)
        self.assertEqual(
            self.handler.read_text(encoding="utf-8"), "unrelated program\n"
        )
        self.assertFalse(self.config_dir.exists())

    def test_modified_installed_handler_is_retained_by_uninstaller(self) -> None:
        self.run_script()
        self.handler.write_text("user-modified file\n", encoding="utf-8")
        self.handler.chmod(0o755)

        result = self.run_script(UNINSTALLER)
        self.assertIn("retained unverified or modified handler", result.stdout)
        self.assertTrue(self.handler.exists())
        self.assertEqual(
            self.handler.read_text(encoding="utf-8"), "user-modified file\n"
        )
        self.assertFalse(self.desktop.exists())
        self.assertNotEqual(
            self.query_default("x-scheme-handler/media-link-launcher"),
            "media-link-launcher.desktop",
        )

    def create_unrelated_old_installation(self) -> tuple[pathlib.Path, pathlib.Path]:
        old_handler = self.home / ".local" / "bin" / "vlc-url-handler"
        old_desktop = self.data / "applications" / "vlc-url-handler.desktop"
        old_handler.parent.mkdir(parents=True, mode=0o755)
        old_desktop.parent.mkdir(parents=True, mode=0o755)
        old_handler.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        old_handler.chmod(0o755)
        old_desktop.write_text(
            "\n".join(
                (
                    "[Desktop Entry]",
                    "Type=Application",
                    "Name=Unrelated handler",
                    f"Exec={old_handler} %u",
                    "MimeType=x-scheme-handler/vlc;",
                    "",
                )
            ),
            encoding="utf-8",
        )
        old_desktop.chmod(0o644)
        self.set_default("vlc-url-handler.desktop", "x-scheme-handler/vlc")
        return old_handler, old_desktop

    def test_migration_does_not_remove_unrelated_old_handler(self) -> None:
        old_handler, old_desktop = self.create_unrelated_old_installation()
        old_handler_content = old_handler.read_bytes()
        old_desktop_content = old_desktop.read_bytes()

        result = self.run_script()
        self.assertIn("did not exactly match", result.stdout)
        self.assertEqual(old_handler.read_bytes(), old_handler_content)
        self.assertEqual(old_desktop.read_bytes(), old_desktop_content)
        self.assertEqual(
            self.query_default("x-scheme-handler/vlc"), "vlc-url-handler.desktop"
        )
        self.assertEqual(
            self.query_default("x-scheme-handler/media-link-launcher"),
            "media-link-launcher.desktop",
        )

    @unittest.skipUnless(OLD_ARCHIVE.is_file(), "historical 0.1.0 archive unavailable")
    def test_verified_v010_installation_is_backed_up_and_migrated(self) -> None:
        old_handler = self.home / ".local" / "bin" / "vlc-url-handler"
        old_desktop = self.data / "applications" / "vlc-url-handler.desktop"
        old_handler.parent.mkdir(parents=True, mode=0o755)
        old_desktop.parent.mkdir(parents=True, mode=0o755)

        with zipfile.ZipFile(OLD_ARCHIVE) as archive:
            source = archive.read(
                "auto-open-media-links-in-vlc-debian-ubuntu-linux/vlc-url-handler.py"
            ).decode("utf-8")
        python_path = shutil.which("python3")
        vlc_path = shutil.which("vlc")
        self.assertIsNotNone(python_path)
        self.assertIsNotNone(vlc_path)
        source = source.replace("#!/usr/bin/env python3", f"#!{python_path}", 1)
        source = source.replace('"__VLC_EXECUTABLE__"', repr(vlc_path), 1)
        old_handler.write_text(source, encoding="utf-8")
        old_handler.chmod(0o755)

        escaped = (
            str(old_handler)
            .replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace('`', '\\`')
            .replace('$', '\\$')
        )
        old_desktop.write_text(
            "\n".join(
                (
                    "[Desktop Entry]",
                    "Type=Application",
                    "Name=VLC URL Handler",
                    "Comment=Confirm and open validated web media URLs in VLC",
                    f'Exec="{escaped}" %u',
                    "Terminal=false",
                    "NoDisplay=true",
                    "MimeType=x-scheme-handler/vlc;",
                    "Categories=AudioVideo;Player;",
                    "",
                )
            ),
            encoding="utf-8",
        )
        old_desktop.chmod(0o644)

        old_state = self.state / "vlc-url-handler"
        old_state.mkdir(parents=True, mode=0o700)
        previous = old_state / "previous-handler"
        previous.write_text("NONE\n", encoding="utf-8")
        previous.chmod(0o600)
        self.set_default("vlc-url-handler.desktop", "x-scheme-handler/vlc")

        result = self.run_script()
        self.assertIn("backed up and removed the verified 0.1.0", result.stdout)
        self.assertFalse(old_handler.exists())
        self.assertFalse(old_desktop.exists())
        self.assertNotEqual(
            self.query_default("x-scheme-handler/vlc"), "vlc-url-handler.desktop"
        )
        migration_backups = list((self.state_dir / "backups").glob("install-*"))
        self.assertTrue(migration_backups)
        names = {item.name for item in migration_backups[-1].iterdir()}
        self.assertIn("v0.1.0-vlc-url-handler", names)
        self.assertIn("v0.1.0-vlc-url-handler.desktop", names)
        self.assertTrue(old_state.exists())


if __name__ == "__main__":
    unittest.main()
