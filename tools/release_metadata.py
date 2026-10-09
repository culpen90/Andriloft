"""Shared version and embedded provenance checks for macOS releases."""

import json
import os
import pathlib
import plistlib
import re


SEMVER = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z", re.ASCII)
BUILD_NUMBER = re.compile(r"[1-9][0-9]*\Z", re.ASCII)


def validate_versions(version, build_number):
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        raise ValueError("Release version must be X.Y.Z with no leading zeros")
    if not isinstance(build_number, str) or not BUILD_NUMBER.fullmatch(build_number):
        raise ValueError("Build number must be a positive integer with no leading zeros")
    return version, build_number


def resolve_versions(info_path, environment=None):
    environment = os.environ if environment is None else environment
    info = plistlib.loads(pathlib.Path(info_path).read_bytes())
    return validate_versions(
        environment.get("ANDRILOFT_VERSION", info.get("CFBundleShortVersionString")),
        environment.get("ANDRILOFT_BUILD_NUMBER", info.get("CFBundleVersion")),
    )


def stamp_versions(info_path, version, build_number):
    validate_versions(version, build_number)
    path = pathlib.Path(info_path)
    info = plistlib.loads(path.read_bytes())
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = build_number
    path.write_bytes(plistlib.dumps(info, sort_keys=False))


def validate_app(app, version, build_number, source_sha):
    """Require the downloaded app to match the exact release being built."""
    validate_versions(version, build_number)
    app = pathlib.Path(app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    build = json.loads((app / "Contents/Resources/build-info.json").read_text())
    if info.get("CFBundleShortVersionString") != version or info.get("CFBundleVersion") != build_number:
        raise ValueError("Embedded app version/build does not match the expected release")
    if build.get("version") != version or build.get("build") != build_number:
        raise ValueError("Embedded build metadata version/build does not match the expected release")
    if build.get("source_sha") != source_sha or build.get("source_dirty") is not False:
        raise ValueError("Release app does not match the expected clean source commit")
    if build.get("configuration") != "release":
        raise ValueError("App build metadata does not match release configuration")
    if build.get("signing") != "ad-hoc" or build.get("notarized") is not False:
        raise ValueError("App build metadata does not match ad-hoc, unnotarized signing")
    return info, build
