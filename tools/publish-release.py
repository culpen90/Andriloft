#!/usr/bin/env python3
"""Publish only complete, verified app releases using the workflow's GitHub token."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile

from sparkle_updates import REPOSITORY, validate_appcast, validate_framework_info, validate_updater_info


SOURCE_INFO = Path(__file__).resolve().parents[1] / "Assets/Info.plist"


def digest(filename):
    result = hashlib.sha256()
    with filename.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def validate_assets(directory, plan, repository=REPOSITORY):
    version = plan["version"]
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("Invalid planned version")
    if plan["tag"] != "v" + version or not re.fullmatch(r"[0-9a-f]{40}", plan["source_sha"]):
        raise ValueError("Invalid planned tag/source SHA")
    if not re.fullmatch(r"[1-9][0-9]*", str(plan["build"])) or plan.get("skip") is not False:
        raise ValueError("Invalid planned build or skipped release")
    prefix = f"Andriloft-{version}-macOS-universal"
    archive_names = {prefix + ".zip", prefix + ".dmg"}
    expected_names = archive_names | {"appcast.xml", "release.json", "SHA256SUMS.txt"}
    if {item.name for item in directory.iterdir()} != expected_names:
        raise ValueError("Expected exactly the versioned ZIP, DMG, signed appcast, manifest, and checksums")
    if any(not (directory / name).is_file() or (directory / name).is_symlink() for name in expected_names):
        raise ValueError("Release assets must be regular files")
    checksums = {}
    for line in (directory / "SHA256SUMS.txt").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match[2] in checksums:
            raise ValueError("Invalid or duplicate checksum line")
        checksums[match[2]] = match[1]
    if set(checksums) != archive_names | {"appcast.xml", "release.json"}:
        raise ValueError("Checksums do not cover the complete release")
    if any(digest(directory / name) != checksum for name, checksum in checksums.items()):
        raise ValueError("Release checksum mismatch")
    manifest = json.loads((directory / "release.json").read_text())
    required = {"version": version, "tag": plan["tag"], "bundle_version": str(plan["build"]),
                "source_sha": plan["source_sha"], "configuration": "release", "signing": "ad-hoc",
                "notarized": False, "requires_paid_developer_account": False,
                "architectures": ["arm64", "x86_64"]}
    if any(manifest.get(key) != value for key, value in required.items()):
        raise ValueError("Release manifest does not match the planned app")
    validation = manifest.get("validation", {})
    if not isinstance(validation.get("tests"), int) or validation["tests"] <= 0 or validation.get("failures") != 0:
        raise ValueError("Release manifest has no passing test evidence")
    for check in ("extracted_zip_signature", "extracted_zip_smoke", "extracted_zip_version_provenance",
                  "dmg_image_integrity", "mounted_dmg_signature", "mounted_dmg_smoke", "mounted_dmg_version_provenance",
                  "sparkle_archive_signature", "sparkle_feed_signature"):
        if validation.get(check) is not True:
            raise ValueError(f"Release validation missing: {check}")
    assets = manifest.get("assets", [])
    if len(assets) != 2 or {asset["name"] for asset in assets} != archive_names:
        raise ValueError("Manifest does not describe both archives")
    for asset in assets:
        filename = directory / asset["name"]
        if asset["sha256"] != checksums[asset["name"]] or asset["size"] != filename.stat().st_size:
            raise ValueError("Manifest asset digest/size mismatch")
    with zipfile.ZipFile(directory / (prefix + ".zip")) as archive:
        info_name = "Andriloft.app/Contents/Info.plist"
        build_name = "Andriloft.app/Contents/Resources/build-info.json"
        framework_info_name = "Andriloft.app/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
        if any(archive.namelist().count(name) != 1 for name in (info_name, build_name, framework_info_name)):
            raise ValueError("ZIP app version/provenance is missing or duplicated")
        info = plistlib.loads(archive.read(info_name))
        build = json.loads(archive.read(build_name))
        validate_framework_info(plistlib.loads(archive.read(framework_info_name)))
        if info.get("CFBundleShortVersionString") != version or info.get("CFBundleVersion") != str(plan["build"]):
            raise ValueError("ZIP embedded app version/build mismatch")
        expected_build = {"version": version, "build": str(plan["build"]), "source_sha": plan["source_sha"],
                          "source_dirty": False, "configuration": "release", "signing": "ad-hoc", "notarized": False}
        if any(build.get(key) != value for key, value in expected_build.items()):
            raise ValueError("ZIP embedded app provenance mismatch")
        source_info = plistlib.loads(SOURCE_INFO.read_bytes())
        trusted_feed, trusted_key = validate_updater_info(source_info, repository)
        if info.get("SUFeedURL") != trusted_feed or info.get("SUPublicEDKey") != trusted_key:
            raise ValueError("ZIP Sparkle configuration does not match the trusted release source")
        updater = validate_appcast(directory / "appcast.xml", directory / (prefix + ".zip"), info,
                                   version, plan["build"], repository)
        if manifest.get("updater") != updater:
            raise ValueError("Release manifest does not match the verified Sparkle updater")
    return sorted(expected_names)


class GitHub:
    def __init__(self, repository):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("Set GH_REPO to owner/repository")
        self.repository = repository

    def api(self, endpoint, payload=None, method=None, paginate=False):
        command = ["gh", "api", f"repos/{self.repository}/{endpoint}"]
        if paginate:
            command += ["--paginate", "--slurp"]
        if method:
            command += ["--method", method]
        if payload is not None:
            command += ["--input", "-"]
        result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                                text=True, capture_output=True, check=True)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def releases(self):
        return [release for page in self.api("releases?per_page=100", paginate=True) for release in page]

    def tag_sha(self, tag):
        refs = self.api(f"git/matching-refs/tags/{tag}")
        matches = [ref for ref in refs if ref["ref"] == f"refs/tags/{tag}"]
        if not matches:
            return None
        target = matches[0]["object"]
        for _ in range(8):
            if target["type"] == "commit":
                return target["sha"]
            if target["type"] != "tag":
                break
            target = self.api(f"git/tags/{target['sha']}")["object"]
        raise ValueError("Release tag does not resolve to a commit")

    def verify_remote(self, release, directory, names):
        remote_assets = self.api(f"releases/{release['id']}/assets?per_page=100", paginate=True)
        remote_assets = [asset for page in remote_assets for asset in page]
        if len(remote_assets) != len(names) or {asset["name"] for asset in remote_assets} != set(names):
            raise ValueError("GitHub release does not have exactly the complete asset set")
        for asset in remote_assets:
            filename = directory / asset["name"]
            if asset["state"] != "uploaded" or asset["size"] != filename.stat().st_size:
                raise ValueError("GitHub asset was not uploaded completely")
            if asset.get("digest") and asset["digest"] != "sha256:" + digest(filename):
                raise ValueError("GitHub asset digest mismatch")
        # Re-download the actual uploaded bytes before making the draft public.
        with tempfile.TemporaryDirectory(prefix="andriloft-upload-check-") as temporary:
            command = ["gh", "release", "download", release["tag_name"], "--repo", self.repository,
                       "--dir", temporary]
            for name in names:
                command += ["--pattern", name]
            subprocess.run(command, check=True)
            for name in names:
                if digest(Path(temporary) / name) != digest(directory / name):
                    raise ValueError("Downloaded GitHub asset does not match the verified build")


def publish(github, plan, directory, notes):
    names = validate_assets(directory, plan, github.repository)
    tag, source_sha = plan["tag"], plan["source_sha"]
    releases = github.releases()
    matches = [release for release in releases if release["tag_name"] == tag]
    if len(matches) > 1:
        raise ValueError("Multiple releases use the planned tag")
    release = matches[0] if matches else None
    existing_sha = github.tag_sha(tag)
    if existing_sha is not None and existing_sha != source_sha:
        raise ValueError("Existing release tag points to another source commit")
    if release and not release["draft"]:
        if existing_sha != source_sha or release["prerelease"]:
            raise ValueError("Published release does not match the planned source")
        github.verify_remote(release, directory, names)
        return release["html_url"]
    if release and release["target_commitish"] != source_sha:
        raise ValueError("Existing draft belongs to another source commit")
    planned_version = tuple(map(int, plan["version"].split(".")))
    for published in releases:
        match = re.fullmatch(r"v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))", published["tag_name"])
        if match and not published["draft"] and not published["prerelease"]:
            if tuple(map(int, match[1].split("."))) >= planned_version:
                raise ValueError("A newer version has already been published; plan again")
    comparison = github.api(f"compare/{source_sha}...main")
    if comparison["status"] not in ("identical", "ahead"):
        raise ValueError("Release source is no longer in main's history")
    if existing_sha is None:
        github.api("git/refs", {"ref": f"refs/tags/{tag}", "sha": source_sha}, method="POST")
    payload = {"tag_name": tag, "target_commitish": source_sha, "name": f"Andriloft {plan['version']}",
               "body": notes.read_text(), "draft": True, "prerelease": False}
    if release:
        release = github.api(f"releases/{release['id']}", payload, method="PATCH")
    else:
        release = github.api("releases", payload, method="POST")
    subprocess.run(["gh", "release", "upload", tag, "--repo", github.repository, "--clobber",
                    *(str(directory / name) for name in names)], check=True)
    github.verify_remote(release, directory, names)
    if github.tag_sha(tag) != source_sha:
        raise ValueError("Release tag changed while uploading")
    # The workflow lock covers other bot runs; also reject an external release
    # published while these files were uploading so Latest never moves backward.
    for published in github.releases():
        match = re.fullmatch(r"v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))", published["tag_name"])
        if match and not published["draft"] and not published["prerelease"]:
            if tuple(map(int, match[1].split("."))) >= planned_version:
                raise ValueError("A newer version appeared during upload; leaving this release as a draft")
    release = github.api(f"releases/{release['id']}", {"draft": False, "make_latest": "true"}, method="PATCH")
    if release["draft"] or release["prerelease"]:
        raise ValueError("GitHub did not publish a stable release")
    return release["html_url"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--verify-only", action="store_true", help="Validate locally without contacting GitHub")
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    if args.verify_only:
        validate_assets(args.assets, plan)
        print(f"Verified release assets for {plan['tag']}")
    else:
        print(publish(GitHub(os.environ.get("GH_REPO", "")), plan, args.assets, args.notes))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise SystemExit(f"Release publication failed: {detail}")
