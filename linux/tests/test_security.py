from __future__ import annotations

import hashlib
import importlib.util
import os
import pathlib
import stat
import sys
import tempfile
import unittest
import urllib.parse
from unittest import mock


PACKAGE_DIR = pathlib.Path(__file__).resolve().parents[1]
HANDLER_PATH = PACKAGE_DIR / "media-link-launcher.py"
USERSCRIPT_PATH = PACKAGE_DIR / "media-link-launcher.user.js"
if not USERSCRIPT_PATH.is_file():
    USERSCRIPT_PATH = (
        PACKAGE_DIR.parent / "userscript" / "media-link-launcher.user.js"
    )
USERSCRIPT_CHECKSUM_PATH = PACKAGE_DIR / "USERSCRIPT-SHA256.txt"
if not USERSCRIPT_CHECKSUM_PATH.is_file():
    USERSCRIPT_CHECKSUM_PATH = (
        PACKAGE_DIR.parent / "userscript" / "USERSCRIPT-SHA256.txt"
    )
INSTALLER_PATH = PACKAGE_DIR / "install-media-link-launcher.sh"

SPEC = importlib.util.spec_from_file_location(
    "media_link_launcher_under_test", HANDLER_PATH
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Unable to load the handler module for testing.")
handler = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = handler
SPEC.loader.exec_module(handler)


def invocation_for(target: str) -> str:
    encoded = urllib.parse.quote(target, safe="")
    return f"media-link-launcher://open?url={encoded}"


class InvocationAndTargetTests(unittest.TestCase):
    def test_complex_url_round_trips_exactly(self) -> None:
        target = (
            "https://alice:s3cret@example.com:8443/folder/a%20café%25.mp4"
            "?token=a%26b&expires=123#chapter-2"
        )
        decoded = handler.decode_invocation(invocation_for(target))
        parsed = handler.parse_target(decoded, frozenset({"http", "https"}))

        self.assertEqual(decoded, target)
        self.assertEqual(parsed.raw, target)
        self.assertEqual(parsed.hostname, "example.com")
        self.assertEqual(parsed.port, 8443)
        self.assertTrue(parsed.has_username)
        self.assertTrue(parsed.has_password)
        self.assertTrue(parsed.has_query)
        self.assertTrue(parsed.has_fragment)

    def test_literal_percent_and_plus_are_preserved(self) -> None:
        target = "https://example.com/100%.mp4?token=a+b%25"
        self.assertEqual(handler.decode_invocation(invocation_for(target)), target)

    def test_signed_url_query_is_one_target_not_outer_parameters(self) -> None:
        target = "https://cdn.example/video.m3u8?Policy=abc&Signature=x%2By&Key-Pair-Id=7"
        self.assertEqual(handler.decode_invocation(invocation_for(target)), target)

    def test_encoded_space_is_allowed_but_literal_space_is_rejected(self) -> None:
        target = "https://example.com/a%20file.mp4"
        parsed = handler.parse_target(
            handler.decode_invocation(invocation_for(target)), frozenset({"https"})
        )
        self.assertEqual(parsed.raw, target)
        with self.assertRaises(handler.HandlerError):
            handler.decode_invocation(
                "media-link-launcher://open?url=https://example.com/a file.mp4"
            )

    def test_path_component_beginning_with_dash_is_preserved(self) -> None:
        target = "https://example.com/-dangerous-looking.mp4"
        parsed = handler.parse_target(target, frozenset({"https"}))
        self.assertEqual(parsed.raw, target)

    def test_wrong_protocol_and_action_are_rejected(self) -> None:
        target = urllib.parse.quote("https://example.com/video.mp4", safe="")
        invalid = (
            f"vlc:/{'/'}open?url={target}",
            f"media-link-launcher://OPEN?url={target}",
            f"media-link-launcher://open/?url={target}",
            f"media-link-launcher:open?url={target}",
        )
        for invocation in invalid:
            with self.subTest(invocation=invocation):
                with self.assertRaises(handler.HandlerError):
                    handler.decode_invocation(invocation)

    def test_missing_duplicate_extra_and_blank_values_are_rejected(self) -> None:
        target = urllib.parse.quote("https://example.com/video.mp4", safe="")
        invalid = (
            "media-link-launcher://open",
            "media-link-launcher://open?url=",
            f"media-link-launcher://open?target={target}",
            f"media-link-launcher://open?url={target}&url={target}",
            f"media-link-launcher://open?url={target}&extra=1",
            f"media-link-launcher://open?url={target}#outer",
        )
        for invocation in invalid:
            with self.subTest(invocation=invocation):
                with self.assertRaises(handler.HandlerError):
                    handler.decode_invocation(invocation)

    def test_malformed_percent_and_invalid_utf8_are_rejected(self) -> None:
        invalid = (
            "media-link-launcher://open?url=https%3A%2F%2Fexample.com%2Fbad%ZZ",
            "media-link-launcher://open?url=https%3A%2F%2Fexample.com%2Fbad%FF",
        )
        for invocation in invalid:
            with self.subTest(invocation=invocation):
                with self.assertRaises(handler.HandlerError):
                    handler.decode_invocation(invocation)

    def test_literal_and_encoded_controls_are_rejected(self) -> None:
        targets = (
            "https://example.com/a\x00b.mp4",
            "https://example.com/a\nb.mp4",
            "https://example.com/a%00b.mp4",
            "https://example.com/a%0Ab.mp4",
            "https://example.com/a%C2%85b.mp4",
        )
        for target in targets:
            with self.subTest(target=target):
                with self.assertRaises(handler.HandlerError):
                    handler.decode_invocation(invocation_for(target))

    def test_oversized_values_are_rejected(self) -> None:
        with self.assertRaises(handler.HandlerError):
            handler.decode_invocation("x" * (handler.MAX_INVOCATION_LENGTH + 1))
        target = "https://example.com/" + "a" * handler.MAX_TARGET_LENGTH
        with self.assertRaises(handler.HandlerError):
            handler.decode_invocation(invocation_for(target))

    def test_dangerous_and_unknown_target_schemes_are_rejected(self) -> None:
        targets = (
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/plain,hello",
            "shell://example.com/command",
            "unknown://example.com/video.mp4",
            "//example.com/video.mp4",
        )
        for target in targets:
            with self.subTest(target=target):
                with self.assertRaises(handler.HandlerError):
                    handler.parse_target(target, handler.SUPPORTED_SCHEMES)

    def test_optional_protocol_requires_explicit_enablement(self) -> None:
        with self.assertRaises(handler.HandlerError):
            handler.parse_target(
                "smb://server/share/video.mkv", handler.DEFAULT_ALLOWED_SCHEMES
            )
        parsed = handler.parse_target(
            "smb://server/share/video.mkv", frozenset({"smb"})
        )
        self.assertEqual(parsed.scheme, "smb")

    def test_missing_host_bad_port_and_backslash_authority_are_rejected(self) -> None:
        targets = (
            "https:///video.mp4",
            "https://example.com:not-a-port/video.mp4",
            "https://example.com:0/video.mp4",
            "https://example.com\\attacker.test/video.mp4",
            "https://:secret@example.com/video.mp4",
        )
        for target in targets:
            with self.subTest(target=target):
                with self.assertRaises(handler.HandlerError):
                    handler.parse_target(target, frozenset({"https"}))

    def test_private_addresses_are_labeled(self) -> None:
        self.assertIsNotNone(handler.host_scope_warning("127.0.0.1"))
        self.assertIsNotNone(handler.host_scope_warning("192.168.50.1"))
        self.assertIsNotNone(handler.host_scope_warning("router.local"))
        self.assertIsNone(handler.host_scope_warning("1.1.1.1"))


class ConfigurationLoggingAndPromptTests(unittest.TestCase):
    def private_file(self, directory: pathlib.Path, name: str, content: str) -> pathlib.Path:
        path = directory / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o600)
        return path

    def test_missing_configuration_uses_http_https_and_no_logging(self) -> None:
        with tempfile.TemporaryDirectory() as directory_name:
            directory = pathlib.Path(directory_name)
            self.assertEqual(
                handler.load_allowed_schemes(directory / "missing-schemes"),
                frozenset({"http", "https"}),
            )
            self.assertFalse(handler.load_logging_enabled(directory / "missing-logging"))

    def test_private_configuration_enables_only_selected_protocols(self) -> None:
        with tempfile.TemporaryDirectory() as directory_name:
            directory = pathlib.Path(directory_name)
            schemes = self.private_file(directory, "allowed-schemes", "http\nhttps\nrtsp\n")
            logging = self.private_file(directory, "logging", "enabled\n")
            self.assertEqual(
                handler.load_allowed_schemes(schemes),
                frozenset({"http", "https", "rtsp"}),
            )
            self.assertTrue(handler.load_logging_enabled(logging))

    def test_permissive_or_invalid_configuration_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory_name:
            directory = pathlib.Path(directory_name)
            schemes = self.private_file(directory, "allowed-schemes", "http\n")
            schemes.chmod(0o644)
            with self.assertRaises(handler.HandlerError):
                handler.load_allowed_schemes(schemes)
            schemes.chmod(0o600)
            schemes.write_text("file\n", encoding="utf-8")
            with self.assertRaises(handler.HandlerError):
                handler.load_allowed_schemes(schemes)

    def test_logging_disabled_creates_no_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory_name:
            state_dir = pathlib.Path(directory_name) / "state"
            with mock.patch.object(handler, "state_directory", return_value=state_dir):
                handler.log_event("launched", enabled=False, scheme="https")
            self.assertFalse(state_dir.exists())

    def test_enabled_log_is_private_and_contains_only_redacted_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory_name:
            state_dir = pathlib.Path(directory_name) / "state"
            with mock.patch.object(handler, "state_directory", return_value=state_dir):
                handler.log_event(
                    "rejected",
                    enabled=True,
                    scheme="https",
                    category="unsupported_scheme",
                )
            log_path = state_dir / "events.log"
            content = log_path.read_text(encoding="utf-8")
            self.assertEqual(stat.S_IMODE(state_dir.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(log_path.stat().st_mode), 0o600)
            self.assertIn("event=rejected", content)
            self.assertIn("scheme=https", content)
            self.assertIn("category=unsupported_scheme", content)
            for secret in ("alice", "password", "private/path", "token", "fragment"):
                self.assertNotIn(secret, content)

    def test_confirmation_hides_credentials_path_query_and_fragment_values(self) -> None:
        target = "https://alice:s3cret@example.com/private/media.mp4?token=value#chapter"
        parsed = handler.parse_target(target, frozenset({"https"}))
        message = handler.confirmation_text(parsed)
        self.assertIn("Host: example.com", message)
        self.assertIn("Credentials present: yes", message)
        for secret in ("alice", "s3cret", "private/media", "token=value", "chapter"):
            self.assertNotIn(secret, message)

    def test_prompt_rate_limit_rejects_immediate_second_request(self) -> None:
        with tempfile.TemporaryDirectory() as directory_name:
            directory = pathlib.Path(directory_name)
            handler.enforce_prompt_interval(directory)
            with self.assertRaises(handler.QuietRejection):
                handler.enforce_prompt_interval(directory)


class LaunchBoundaryTests(unittest.TestCase):
    def test_launch_uses_fixed_executable_argument_array_separator_and_no_shell(self) -> None:
        target = handler.parse_target(
            "https://example.com/-media.mp4?token=private", frozenset({"https"})
        )
        with tempfile.TemporaryDirectory() as directory_name:
            executable = pathlib.Path(directory_name) / "vlc"
            executable.write_text("placeholder", encoding="utf-8")
            executable.chmod(0o700)
            with (
                mock.patch.object(handler, "VLC_EXECUTABLE", str(executable)),
                mock.patch.object(handler.subprocess, "Popen") as popen,
            ):
                handler.launch_vlc(target)

        self.assertEqual(popen.call_args.args[0], [str(executable), "--", target.raw])
        self.assertNotIn("shell", popen.call_args.kwargs)

    def test_cancelled_confirmation_never_launches(self) -> None:
        target = "https://example.com/media.mp4"
        with tempfile.TemporaryDirectory() as directory_name:
            state_dir = pathlib.Path(directory_name) / "state"
            with (
                mock.patch.object(
                    sys,
                    "argv",
                    ["media-link-launcher", invocation_for(target)],
                ),
                mock.patch.object(handler, "state_directory", return_value=state_dir),
                mock.patch.object(
                    handler, "load_allowed_schemes", return_value=frozenset({"https"})
                ),
                mock.patch.object(handler, "load_logging_enabled", return_value=False),
                mock.patch.object(handler, "confirm_target", return_value=False),
                mock.patch.object(handler, "launch_vlc") as launch,
            ):
                result = handler.main()
        self.assertEqual(result, 1)
        launch.assert_not_called()

    def test_operational_sources_contain_no_shell_execution_primitives(self) -> None:
        sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (HANDLER_PATH, INSTALLER_PATH, USERSCRIPT_PATH)
        )
        forbidden = ("os.system(", "shell=True", "subprocess.call(", "eval(", "sh -c", "bash -c")
        for value in forbidden:
            self.assertNotIn(value, sources)


class UserscriptStaticBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = USERSCRIPT_PATH.read_text(encoding="utf-8")

    def test_metadata_is_neutral_versioned_unprivileged_and_sandboxed(self) -> None:
        self.assertIn("// @name         Media Link Launcher", self.source)
        self.assertIn("// @version      0.2.1", self.source)
        self.assertIn("// @match        *://*/*", self.source)
        self.assertIn("// @sandbox      DOM", self.source)
        self.assertIn("// @grant        none", self.source)
        self.assertNotIn("GM_", self.source)

    def test_userscript_requires_trusted_left_click(self) -> None:
        self.assertIn("event.isTrusted", self.source)
        self.assertIn("event.button !== 0", self.source)

    def test_full_media_url_is_not_stored_in_page_dom(self) -> None:
        self.assertNotIn("dataset.mediaUrl", self.source)
        self.assertNotIn("control.href", self.source)
        self.assertNotIn("setAttribute('href'", self.source)

    def test_userscript_has_no_network_request_api(self) -> None:
        for value in ("fetch(", "XMLHttpRequest", "GM_xmlhttpRequest", "WebSocket("):
            self.assertNotIn(value, self.source)

    def test_userscript_checksum_matches_canonical_source(self) -> None:
        checksum_line = USERSCRIPT_CHECKSUM_PATH.read_text(encoding="ascii")
        expected = (
            f"{hashlib.sha256(USERSCRIPT_PATH.read_bytes()).hexdigest()}  "
            "media-link-launcher.user.js\n"
        )
        self.assertEqual(checksum_line, expected)

    def test_active_sources_do_not_contain_old_uri_literal(self) -> None:
        for path in (HANDLER_PATH, INSTALLER_PATH, USERSCRIPT_PATH):
            self.assertNotIn("vlc" + "://", path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
