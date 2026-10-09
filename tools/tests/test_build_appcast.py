import base64
import importlib.util
import os
import pathlib
import plistlib
import shutil
import subprocess
import unittest
from unittest import mock

from test_publish_release import ReleaseFixture, TEST_SEED, sign_test_file
from sparkle_updates import signed_feed_content, validate_appcast


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "build-appcast.py"
SPEC = importlib.util.spec_from_file_location("build_appcast", SCRIPT)
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class BuildAppcastTests(ReleaseFixture):
    def setUp(self):
        super().setUp()
        self.app = pathlib.Path(self.workspace.name) / "Andriloft.app"
        self.tools = pathlib.Path(self.workspace.name) / "Sparkle/bin"
        self.tools.mkdir(parents=True)
        for tool in ("generate_appcast", "sign_update"):
            (self.tools / tool).touch(mode=0o755)
        framework = "Sparkle.framework/Versions/B/Resources/Info.plist"
        for info_path in (self.app / "Contents/Info.plist", self.app / "Contents/Frameworks" / framework,
                          self.tools.parent / framework):
            info_path.parent.mkdir(parents=True, exist_ok=True)
            info_path.write_bytes(plistlib.dumps(self.info if info_path.name == "Info.plist" and
                                                 info_path.parent.name == "Contents" else
                                                 {"CFBundleIdentifier": "org.sparkle-project.Sparkle",
                                                  "CFBundleShortVersionString": "2.10.0"}))
        self.archive = self.directory / (self.prefix + ".zip")
        self.output = pathlib.Path(self.workspace.name) / "result-appcast.xml"

    def test_modern_32_byte_seed_is_passed_only_on_stdin_and_feed_is_resigned(self):
        key = base64.b64encode(TEST_SEED).decode()
        real_run = subprocess.run
        signing_calls = []

        def sparkle_run(command, **kwargs):
            if command[0] not in (str(self.tools / "generate_appcast"), str(self.tools / "sign_update")):
                return real_run(command, **kwargs)
            signing_calls.append((command, kwargs))
            self.assertEqual(kwargs["input"], key + "\n")
            self.assertNotIn("SPARKLE_PRIVATE_KEY", kwargs["env"])
            self.assertNotIn(key, command)
            if command[0].endswith("generate_appcast"):
                shutil.copyfile(self.directory / "appcast.xml", command[command.index("-o") + 1])
            elif "--verify" not in command:
                feed = pathlib.Path(command[-1])
                content = feed.read_bytes()
                signature = sign_test_file(feed)
                feed.write_bytes(content + (f"<!-- sparkle-signatures:\nedSignature: {signature}\n"
                                            f"length: {len(content)}\n-->\n").encode())
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.dict(os.environ, {"SPARKLE_PRIVATE_KEY": key}), \
                mock.patch.object(builder.subprocess, "run", side_effect=sparkle_run):
            builder.generate(self.app, self.archive, self.output, self.tools)
        self.assertEqual(len(signing_calls), 4)
        content, _ = signed_feed_content(self.output.read_bytes())
        self.assertIn(b"Install Update", content)
        self.assertIn(b"Open Android windows will close", content)
        validate_appcast(self.output, self.archive, self.info, "1.2.3", "7")

    def test_invalid_key_is_rejected_without_key_disclosing_tool_diagnostics(self):
        for key in ("invalid-sensitive-value", base64.b64encode(bytes(64)).decode(), ""):
            with self.subTest(key_length=len(key)), mock.patch.dict(os.environ, {"SPARKLE_PRIVATE_KEY": key}), \
                    mock.patch.object(builder.subprocess, "run") as process:
                with self.assertRaisesRegex(ValueError, "must be an exported") as caught:
                    builder.generate(self.app, self.archive, self.output, self.tools)
                process.assert_not_called()
                if key:
                    self.assertNotIn(key, str(caught.exception))

    def test_mismatched_tool_distribution_is_rejected(self):
        tool_info = self.tools.parent / "Sparkle.framework/Versions/B/Resources/Info.plist"
        tool_info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.sparkle-project.Sparkle",
                                             "CFBundleShortVersionString": "2.9.3"}))
        with self.assertRaisesRegex(ValueError, "pinned Sparkle 2.10.0"):
            builder.generate(self.app, self.archive, self.output, self.tools)


if __name__ == "__main__":
    unittest.main()
