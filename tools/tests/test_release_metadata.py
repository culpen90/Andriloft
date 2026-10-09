import json
import pathlib
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from release_metadata import resolve_versions, stamp_versions, validate_app, validate_versions


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.app = pathlib.Path(self.workspace.name) / "Andriloft.app"
        (self.app / "Contents/Resources").mkdir(parents=True)
        self.info_path = self.app / "Contents/Info.plist"
        self.info = {"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "7"}
        self.metadata = {
            "version": "1.2.3", "build": "7", "source_sha": "a" * 40,
            "source_dirty": False, "configuration": "release", "signing": "ad-hoc",
            "notarized": False,
        }
        self.write_metadata()

    def write_metadata(self):
        self.info_path.write_bytes(plistlib.dumps(self.info))
        (self.app / "Contents/Resources/build-info.json").write_text(json.dumps(self.metadata))

    def test_numeric_semver_and_positive_build(self):
        for version in ("0.0.0", "0.1.0", "10.20.30"):
            self.assertEqual(validate_versions(version, "1"), (version, "1"))
        for version in ("01.2.3", "1.02.3", "1.2.03", "v1.2.3", "1.2", "1.2.3-beta.1", "1.2.3+build", "1.2.3\n", "１.2.3", ""):
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate_versions(version, "1")
        for build in ("0", "01", "-1", "1.0", "1\n", "１", "", 1):
            with self.subTest(build=build), self.assertRaises(ValueError):
                validate_versions("1.2.3", build)

    def test_defaults_and_environment_overrides(self):
        self.assertEqual(resolve_versions(self.info_path, {}), ("1.2.3", "7"))
        self.assertEqual(resolve_versions(self.info_path, {"ANDRILOFT_VERSION": "2.0.0", "ANDRILOFT_BUILD_NUMBER": "8"}), ("2.0.0", "8"))
        with self.assertRaises(ValueError):
            resolve_versions(self.info_path, {"ANDRILOFT_VERSION": ""})

    def test_stamping_only_changes_the_packaged_copy(self):
        source = pathlib.Path(self.workspace.name) / "source.plist"
        source.write_bytes(self.info_path.read_bytes())
        original = source.read_bytes()
        stamp_versions(self.info_path, "2.0.0", "8")
        self.assertEqual(source.read_bytes(), original)
        stamped = plistlib.loads(self.info_path.read_bytes())
        self.assertEqual(stamped["CFBundleShortVersionString"], "2.0.0")
        self.assertEqual(stamped["CFBundleVersion"], "8")

    def test_exact_embedded_versions_and_provenance(self):
        validate_app(self.app, "1.2.3", "7", "a" * 40)
        for container, key, value in (
            (self.info, "CFBundleShortVersionString", "1.2.4"),
            (self.info, "CFBundleVersion", "8"),
            (self.metadata, "version", "1.2.4"),
            (self.metadata, "build", "8"),
            (self.metadata, "source_sha", "b" * 40),
            (self.metadata, "source_dirty", True),
            (self.metadata, "source_dirty", 0),
            (self.metadata, "configuration", "debug"),
            (self.metadata, "signing", "developer-id"),
            (self.metadata, "notarized", True),
        ):
            with self.subTest(key=key, value=value):
                previous = container[key]
                container[key] = value
                self.write_metadata()
                with self.assertRaises(ValueError):
                    validate_app(self.app, "1.2.3", "7", "a" * 40)
                container[key] = previous
        self.write_metadata()
        validate_app(self.app, "1.2.3", "7", "a" * 40)


if __name__ == "__main__":
    unittest.main()
