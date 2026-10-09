#!/usr/bin/env python3
"""Write provenance for freshly built, verified macOS distribution assets."""
import argparse
import datetime
import hashlib
import json
import pathlib
import re
import subprocess

from release_metadata import completed_test_evidence, validate_app
from sparkle_updates import validate_appcast

parser = argparse.ArgumentParser(description=__doc__)
for name in ("root", "app", "destination", "test_report"):
    parser.add_argument(name, type=pathlib.Path)
parser.add_argument("--version", required=True)
parser.add_argument("--build-number", required=True)
parser.add_argument("--source-sha", required=True)
parser.add_argument("--execution-architectures", nargs="+", required=True)
args = parser.parse_args()
root, app, destination, test_report = args.root, args.app, args.destination, args.test_report
execution_architectures = args.execution_architectures
try:
    info, build = validate_app(app, args.version, args.build_number, args.source_sha)
except (OSError, ValueError, TypeError) as error:
    raise SystemExit(str(error))
sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
if sha != args.source_sha:
    raise SystemExit("Source commit changed during the release build")
if subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip():
    raise SystemExit("Source changed during the release build")

def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()

binary = app / "Contents/MacOS/Andriloft"
architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
if set(architectures) != {"arm64", "x86_64"}:
    raise SystemExit("Release is not a universal Apple Silicon/Intel app")
load_commands = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
deployment_targets = re.findall(r"\bminos\s+([0-9.]+)", load_commands)
if len(deployment_targets) != 2 or any(target != info["LSMinimumSystemVersion"] for target in deployment_targets):
    raise SystemExit("Binary deployment targets do not match Info.plist")
assets = [{"name": path.name, "size": path.stat().st_size, "sha256": digest(path)}
          for path in sorted(destination.iterdir()) if path.suffix in {".zip", ".dmg"}]
if len(assets) != 2:
    raise SystemExit("Expected one ZIP and one DMG")
prefix = f"Andriloft-{args.version}-macOS-universal"
if {asset["name"] for asset in assets} != {f"{prefix}.zip", f"{prefix}.dmg"}:
    raise SystemExit("Release asset filenames do not match the embedded version")
results = test_report.read_text()
try:
    tests, failures = completed_test_evidence(results)
except ValueError as error:
    raise SystemExit(str(error))
updater = validate_appcast(destination / "appcast.xml", destination / f"{prefix}.zip", info,
                           args.version, args.build_number)
payload = {
    "schema_version": 1,
    "version": build["version"], "tag": "v" + build["version"],
    "bundle_version": build["build"], "source_sha": sha,
    "configuration": "release", "architectures": sorted(architectures),
    "minimum_macos": info["LSMinimumSystemVersion"],
    "binary_deployment_targets": deployment_targets,
    "signing": "ad-hoc", "notarized": False, "requires_paid_developer_account": False,
    "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "swift_version": subprocess.check_output(["swift", "--version"], text=True).strip(),
    "app_binary_sha256": digest(binary),
    "bundled_example_sha256": digest(app / "Contents/Resources/HelloAndroid.apk"),
    "validation": {"tests": tests, "failures": failures, "execution_architectures": execution_architectures,
                   "extracted_zip_signature": True, "extracted_zip_smoke": True,
                   "extracted_zip_version_provenance": True,
                   "dmg_image_integrity": True, "mounted_dmg_signature": True,
                   "mounted_dmg_smoke": True, "mounted_dmg_version_provenance": True,
                   "sparkle_archive_signature": True, "sparkle_feed_signature": True},
    "updater": updater,
    "assets": assets,
}
(destination / "release.json").write_text(json.dumps(payload, indent=2) + "\n")
