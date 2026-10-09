import copy
import base64
import importlib.util
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from sparkle_updates import REPOSITORY, SPARKLE_NS, SPARKLE_VERSION, validate_appcast

# Public RFC 8032 test vector, used only for deterministic test signatures.
TEST_SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
TEST_PUBLIC_KEY = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()


def sign_test_file(filename):
    with tempfile.TemporaryDirectory() as temporary:
        private = pathlib.Path(temporary) / "test-key.der"
        private.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + TEST_SEED)
        result = subprocess.run([os.environ.get("ANDRILOFT_OPENSSL", "openssl"), "pkeyutl", "-sign", "-inkey", str(private),
                                 "-keyform", "DER", "-rawin", "-in", str(filename)],
                                check=True, capture_output=True)
        return base64.b64encode(result.stdout).decode()


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "publish-release.py"
SPEC = importlib.util.spec_from_file_location("publish_release", SCRIPT)
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


class FakeGitHub:
    repository = REPOSITORY

    def __init__(self, releases=(), tag_sha=None, comparison="identical"):
        self.existing_releases = copy.deepcopy(list(releases))
        self.sha = tag_sha
        self.comparison = comparison
        self.events = []
        self.remote_error = None
        self.release = None

    def releases(self):
        self.events.append(("releases",))
        return copy.deepcopy(self.existing_releases)

    def tag_sha(self, tag):
        self.events.append(("tag_sha", tag))
        return self.sha

    def api(self, endpoint, payload=None, method=None):
        self.events.append(("api", endpoint, method, copy.deepcopy(payload)))
        if endpoint.startswith("compare/"):
            return {"status": self.comparison}
        if endpoint == "git/refs":
            self.sha = payload["sha"]
            return {"ref": payload["ref"]}
        if endpoint == "releases" or endpoint.startswith("releases/"):
            if payload.get("draft") is True:
                self.release = {**payload, "id": 99, "html_url": "https://github.com/example/Andriloft/releases/tag/" + payload["tag_name"]}
            else:
                self.release = {**self.release, **payload}
            return copy.deepcopy(self.release)
        raise AssertionError("Unexpected endpoint: " + endpoint)

    def verify_remote(self, release, directory, names):
        self.events.append(("verify_remote", release["draft"], tuple(names)))
        if self.remote_error:
            raise self.remote_error

    def mutations(self):
        return [event for event in self.events if event[0] == "upload" or
                (event[0] == "api" and event[2] in ("POST", "PATCH", "DELETE", "PUT"))]


class ReleaseFixture(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.directory = pathlib.Path(self.workspace.name) / "release"
        self.directory.mkdir()
        self.notes = pathlib.Path(self.workspace.name) / "notes.md"
        self.notes.write_text("A fresh downloadable app.\n")
        self.plan = {"version": "1.2.3", "tag": "v1.2.3", "build": 7,
                     "source_sha": "a" * 40, "skip": False}
        self.prefix = "Andriloft-1.2.3-macOS-universal"
        self.info = {"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "7",
                     "LSMinimumSystemVersion": "13.0", "SUPublicEDKey": TEST_PUBLIC_KEY,
                     "SUFeedURL": f"https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml",
                     "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
                     "SUSignedFeedFailureExpirationInterval": 0}
        source_info = pathlib.Path(self.workspace.name) / "trusted-info.plist"
        source_info.write_bytes(plistlib.dumps(self.info))
        self.source_info_patch = mock.patch.object(publisher, "SOURCE_INFO", source_info)
        self.source_info_patch.start()
        self.addCleanup(self.source_info_patch.stop)
        self.build = {"version": "1.2.3", "build": "7", "source_sha": "a" * 40,
                      "source_dirty": False, "configuration": "release", "signing": "ad-hoc", "notarized": False}
        self.manifest = {"version": "1.2.3", "tag": "v1.2.3", "bundle_version": "7",
                         "source_sha": "a" * 40, "configuration": "release", "signing": "ad-hoc",
                         "notarized": False, "requires_paid_developer_account": False,
                         "architectures": ["arm64", "x86_64"], "validation": {
                             "tests": 25, "failures": 0, "extracted_zip_signature": True,
                             "extracted_zip_smoke": True, "extracted_zip_version_provenance": True,
                             "dmg_image_integrity": True, "mounted_dmg_signature": True,
                             "mounted_dmg_smoke": True, "mounted_dmg_version_provenance": True,
                             "sparkle_archive_signature": True, "sparkle_feed_signature": True}}
        self.write_archives()
        self.refresh_manifest()

    def write_archives(self):
        with zipfile.ZipFile(self.directory / (self.prefix + ".zip"), "w") as archive:
            archive.writestr("Andriloft.app/Contents/Info.plist", plistlib.dumps(self.info))
            archive.writestr("Andriloft.app/Contents/Resources/build-info.json", json.dumps(self.build))
            archive.writestr("Andriloft.app/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist",
                             plistlib.dumps({"CFBundleIdentifier": "org.sparkle-project.Sparkle",
                                              "CFBundleShortVersionString": SPARKLE_VERSION}))
        (self.directory / (self.prefix + ".dmg")).write_bytes(b"verified DMG fixture")

    def write_appcast(self):
        archive = self.directory / (self.prefix + ".zip")
        signature = sign_test_file(archive)
        appcast = self.directory / "appcast.xml"
        content = (f'<?xml version="1.0" encoding="utf-8"?>\n'
                   f'<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}"><channel><title>Andriloft</title><item>'
                   f'<sparkle:version>7</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>'
                   f'<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>'
                   f'<enclosure url="https://github.com/{REPOSITORY}/releases/download/v1.2.3/{archive.name}" '
                   f'sparkle:edSignature="{signature}" length="{archive.stat().st_size}" '
                   f'type="application/octet-stream"/></item></channel></rss>\n').encode()
        appcast.write_bytes(content)
        feed_signature = sign_test_file(appcast)
        appcast.write_bytes(content + (f'<!-- sparkle-signatures:\nedSignature: {feed_signature}\n'
                                      f'length: {len(content)}\n-->\n').encode())
        self.manifest["updater"] = {"framework": "Sparkle", "version": SPARKLE_VERSION,
                                    "feed_url": self.info["SUFeedURL"], "public_key": self.info["SUPublicEDKey"],
                                    "archive": archive.name, "archive_signature": signature,
                                    "appcast_sha256": publisher.digest(appcast)}

    def refresh_manifest(self, rebuild_appcast=True):
        if rebuild_appcast:
            self.write_appcast()
        self.manifest["assets"] = [{"name": path.name, "size": path.stat().st_size,
                                    "sha256": publisher.digest(path)}
                                   for path in sorted(self.directory.iterdir())
                                   if path.suffix in (".zip", ".dmg")]
        (self.directory / "release.json").write_text(json.dumps(self.manifest))
        self.refresh_checksums()

    def refresh_checksums(self):
        names = [self.prefix + ".zip", self.prefix + ".dmg", "appcast.xml", "release.json"]
        (self.directory / "SHA256SUMS.txt").write_text("".join(
            publisher.digest(self.directory / name) + "  " + name + "\n" for name in names))

    def release(self, draft=False, version="1.2.3", source_sha=None):
        return {"id": 99, "tag_name": "v" + version, "draft": draft, "prerelease": False,
                "target_commitish": source_sha or self.plan["source_sha"],
                "html_url": "https://github.com/example/Andriloft/releases/tag/v" + version}

    def publish(self, github):
        real_run = subprocess.run

        def upload(command, **kwargs):
            if command[0] != "gh":
                return real_run(command, **kwargs)
            self.assertEqual(command[:3], ["gh", "release", "upload"])
            self.assertTrue(kwargs["check"])
            github.events.append(("upload", tuple(command)))
            return mock.Mock(returncode=0)

        with mock.patch.object(publisher.subprocess, "run", side_effect=upload):
            return publisher.publish(github, self.plan, self.directory, self.notes)


class ValidateAssetsTests(ReleaseFixture):
    def test_complete_release_passes(self):
        self.assertEqual(publisher.validate_assets(self.directory, self.plan), sorted(
            [self.prefix + ".zip", self.prefix + ".dmg", "appcast.xml", "release.json", "SHA256SUMS.txt"]))

    def test_altered_archive_fails(self):
        with (self.directory / (self.prefix + ".dmg")).open("ab") as archive:
            archive.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            publisher.validate_assets(self.directory, self.plan)

    def test_missing_file_fails(self):
        (self.directory / (self.prefix + ".dmg")).unlink()
        with self.assertRaisesRegex(ValueError, "Expected exactly"):
            publisher.validate_assets(self.directory, self.plan)

    def test_manifest_metadata_mismatch_fails_after_valid_checksums(self):
        self.manifest["bundle_version"] = "8"
        self.refresh_manifest()
        with self.assertRaisesRegex(ValueError, "manifest does not match"):
            publisher.validate_assets(self.directory, self.plan)

    def test_zip_metadata_mismatch_fails_after_valid_checksums(self):
        self.info["CFBundleShortVersionString"] = "1.2.4"
        self.write_archives()
        self.refresh_manifest()
        with self.assertRaisesRegex(ValueError, "embedded app version/build mismatch"):
            publisher.validate_assets(self.directory, self.plan)

    def test_zip_source_drift_fails_after_valid_checksums(self):
        self.build["source_sha"] = "b" * 40
        self.write_archives()
        self.refresh_manifest()
        with self.assertRaisesRegex(ValueError, "embedded app provenance mismatch"):
            publisher.validate_assets(self.directory, self.plan)

    def test_dirty_zip_source_fails(self):
        self.build["source_dirty"] = True
        self.write_archives()
        self.refresh_manifest()
        with self.assertRaisesRegex(ValueError, "embedded app provenance mismatch"):
            publisher.validate_assets(self.directory, self.plan)

    def test_signature_evidence_is_required(self):
        for flag in ("extracted_zip_signature", "mounted_dmg_signature"):
            with self.subTest(flag=flag):
                self.manifest["validation"][flag] = False
                self.refresh_manifest()
                with self.assertRaisesRegex(ValueError, flag):
                    publisher.validate_assets(self.directory, self.plan)
                self.manifest["validation"][flag] = True

    def test_archive_version_provenance_is_required(self):
        for flag in ("extracted_zip_version_provenance", "mounted_dmg_version_provenance"):
            with self.subTest(flag=flag):
                del self.manifest["validation"][flag]
                self.refresh_manifest()
                with self.assertRaisesRegex(ValueError, flag):
                    publisher.validate_assets(self.directory, self.plan)
                self.manifest["validation"][flag] = True

    def test_feed_tampering_fails_even_with_refreshed_manifest_and_checksums(self):
        appcast = self.directory / "appcast.xml"
        appcast.write_bytes(appcast.read_bytes().replace(b"Andriloft</title>", b"Other App</title>"))
        self.manifest["updater"]["appcast_sha256"] = publisher.digest(appcast)
        self.refresh_manifest(rebuild_appcast=False)
        with self.assertRaisesRegex(ValueError, "signature verification failed"):
            publisher.validate_assets(self.directory, self.plan)

    def test_archive_tampering_fails_even_with_refreshed_checksums(self):
        archive = self.directory / (self.prefix + ".zip")
        data = bytearray(archive.read_bytes())
        # ZIP permits trailing bytes, so embedded plist and provenance stay valid.
        archive.write_bytes(data + b"X")
        self.refresh_manifest(rebuild_appcast=False)
        with self.assertRaisesRegex(ValueError, "archive length"):
            publisher.validate_assets(self.directory, self.plan)

    def test_unchanged_length_archive_tampering_fails_signature_verification(self):
        archive = self.directory / (self.prefix + ".zip")
        # Change the ZIP's unused comment-length field after metadata is read.
        data = archive.read_bytes()
        archive.write_bytes(data[:-2] + b"\x01\x00")
        self.refresh_manifest(rebuild_appcast=False)
        with self.assertRaisesRegex(ValueError, "signature verification failed"):
            publisher.validate_assets(self.directory, self.plan)

    def test_embedded_public_key_cannot_replace_the_trusted_key(self):
        self.info["SUPublicEDKey"] = base64.b64encode(bytes(32)).decode()
        self.write_archives()
        self.refresh_manifest()
        with self.assertRaisesRegex(ValueError, "trusted release source"):
            publisher.validate_assets(self.directory, self.plan)

    def test_signed_feed_policy_is_required(self):
        self.info["SURequireSignedFeed"] = False
        self.write_archives()
        self.refresh_manifest()
        with self.assertRaisesRegex(ValueError, "must require signed"):
            publisher.validate_assets(self.directory, self.plan)

    def test_feed_rejects_another_archive_location_even_when_signed(self):
        appcast = self.directory / "appcast.xml"
        content = appcast.read_bytes().split(b"<!-- sparkle-signatures:")[0]
        content = content.replace(b"/releases/download/v1.2.3/", b"/releases/latest/download/")
        appcast.write_bytes(content)
        signature = sign_test_file(appcast)
        appcast.write_bytes(content + (f'<!-- sparkle-signatures:\nedSignature: {signature}\n'
                                      f'length: {len(content)}\n-->\n').encode())
        self.manifest["updater"]["appcast_sha256"] = publisher.digest(appcast)
        self.refresh_manifest(rebuild_appcast=False)
        with self.assertRaisesRegex(ValueError, "immutable release ZIP"):
            publisher.validate_assets(self.directory, self.plan)


class PublishTests(ReleaseFixture):
    def test_upload_and_remote_verification_precede_publication(self):
        github = FakeGitHub()
        self.assertEqual(self.publish(github), self.release()["html_url"])
        draft = next(i for i, event in enumerate(github.events)
                     if event[0] == "api" and event[1] == "releases" and event[3]["draft"] is True)
        upload = next(i for i, event in enumerate(github.events) if event[0] == "upload")
        verify = next(i for i, event in enumerate(github.events) if event[0] == "verify_remote")
        public = next(i for i, event in enumerate(github.events)
                      if event[0] == "api" and event[3] and event[3].get("draft") is False)
        self.assertLess(draft, upload)
        self.assertLess(upload, verify)
        self.assertLess(verify, public)
        self.assertTrue(github.events[verify][1])
        self.assertEqual(set(github.events[verify][2]), set(publisher.validate_assets(self.directory, self.plan)))

    def test_invalid_planned_tag_fails_before_any_github_call(self):
        github = FakeGitHub()
        self.plan["tag"] = "v1.2.4"
        with self.assertRaisesRegex(ValueError, "planned tag/source"):
            self.publish(github)
        self.assertEqual(github.events, [])

    def test_conflicting_tag_fails_before_mutation(self):
        github = FakeGitHub(tag_sha="b" * 40)
        with self.assertRaisesRegex(ValueError, "tag points to another"):
            self.publish(github)
        self.assertEqual(github.mutations(), [])

    def test_newer_public_release_fails_before_mutation(self):
        github = FakeGitHub(releases=[self.release(version="2.0.0")])
        with self.assertRaisesRegex(ValueError, "newer version"):
            self.publish(github)
        self.assertEqual(github.mutations(), [])

    def test_existing_public_release_is_only_verified(self):
        github = FakeGitHub(releases=[self.release()], tag_sha=self.plan["source_sha"])
        self.assertEqual(self.publish(github), self.release()["html_url"])
        self.assertEqual(github.mutations(), [])
        self.assertEqual(len([event for event in github.events if event[0] == "verify_remote"]), 1)

    def test_existing_public_release_with_corrupt_assets_is_never_overwritten(self):
        github = FakeGitHub(releases=[self.release()], tag_sha=self.plan["source_sha"])
        github.remote_error = ValueError("Downloaded GitHub asset does not match")
        with self.assertRaisesRegex(ValueError, "Downloaded GitHub asset"):
            self.publish(github)
        self.assertEqual(github.mutations(), [])

    def test_draft_retry_reuses_draft_and_tag(self):
        github = FakeGitHub(releases=[self.release(draft=True)], tag_sha=self.plan["source_sha"])
        self.assertEqual(self.publish(github), self.release()["html_url"])
        self.assertFalse(any(event[0] == "api" and event[2] == "POST" for event in github.events))
        edits = [event for event in github.mutations() if event[0] == "api"]
        self.assertEqual([event[3]["draft"] for event in edits], [True, False])

    def test_conflicting_draft_with_missing_tag_fails_before_mutation(self):
        github = FakeGitHub(releases=[self.release(draft=True, source_sha="b" * 40)])
        with self.assertRaisesRegex(ValueError, "draft belongs to another"):
            self.publish(github)
        self.assertEqual(github.mutations(), [])

    def test_remote_verification_failure_keeps_release_draft(self):
        github = FakeGitHub()
        github.remote_error = ValueError("Downloaded GitHub asset does not match")
        with self.assertRaisesRegex(ValueError, "Downloaded GitHub asset"):
            self.publish(github)
        self.assertTrue(github.release["draft"])
        self.assertFalse(any(event[0] == "api" and event[3] and event[3].get("draft") is False
                             for event in github.events))

    def test_newer_release_during_upload_never_makes_draft_public(self):
        github = FakeGitHub()
        verify = github.verify_remote

        def another_release_appears(release, directory, names):
            verify(release, directory, names)
            github.existing_releases.append(self.release(version="2.0.0"))

        with mock.patch.object(github, "verify_remote", side_effect=another_release_appears):
            with self.assertRaisesRegex(ValueError, "newer version appeared during upload"):
                self.publish(github)
        self.assertTrue(github.release["draft"])
        self.assertTrue(any(event[0] == "upload" for event in github.events))
        self.assertFalse(any(event[0] == "api" and event[3] and event[3].get("draft") is False
                             for event in github.events))

    def test_source_no_longer_in_main_fails_before_mutation(self):
        github = FakeGitHub(comparison="diverged")
        with self.assertRaisesRegex(ValueError, "no longer in main"):
            self.publish(github)
        self.assertEqual(github.mutations(), [])


class VerifyRemoteTests(ReleaseFixture):
    def test_actual_downloaded_bytes_are_checked(self):
        github = publisher.GitHub(REPOSITORY)
        names = publisher.validate_assets(self.directory, self.plan)
        assets = [{"name": name, "state": "uploaded", "size": (self.directory / name).stat().st_size,
                   "digest": "sha256:" + publisher.digest(self.directory / name)} for name in names]

        def download(command, **kwargs):
            self.assertEqual(command[:3], ["gh", "release", "download"])
            self.assertTrue(kwargs["check"])
            target = pathlib.Path(command[command.index("--dir") + 1])
            for name in names:
                (target / name).write_bytes((self.directory / name).read_bytes())

        with mock.patch.object(github, "api", return_value=[assets]), \
                mock.patch.object(publisher.subprocess, "run", side_effect=download) as process:
            github.verify_remote(self.release(draft=True), self.directory, names)
        process.assert_called_once()

    def test_download_corruption_fails_even_if_remote_metadata_matches(self):
        github = publisher.GitHub(REPOSITORY)
        names = publisher.validate_assets(self.directory, self.plan)
        assets = [{"name": name, "state": "uploaded", "size": (self.directory / name).stat().st_size,
                   "digest": "sha256:" + publisher.digest(self.directory / name)} for name in names]

        def download(command, **kwargs):
            target = pathlib.Path(command[command.index("--dir") + 1])
            for name in names:
                (target / name).write_bytes(b"corrupt download")

        with mock.patch.object(github, "api", return_value=[assets]), \
                mock.patch.object(publisher.subprocess, "run", side_effect=download):
            with self.assertRaisesRegex(ValueError, "Downloaded GitHub asset"):
                github.verify_remote(self.release(draft=True), self.directory, names)

    def test_incomplete_remote_upload_fails_before_download(self):
        github = publisher.GitHub(REPOSITORY)
        names = publisher.validate_assets(self.directory, self.plan)
        assets = [{"name": name, "state": "uploaded", "size": (self.directory / name).stat().st_size}
                  for name in names]
        assets[0]["state"] = "new"
        with mock.patch.object(github, "api", return_value=[assets]), \
                mock.patch.object(publisher.subprocess, "run") as process:
            with self.assertRaisesRegex(ValueError, "not uploaded completely"):
                github.verify_remote(self.release(draft=True), self.directory, names)
        process.assert_not_called()


if __name__ == "__main__":
    unittest.main()
