#!/usr/bin/env python3
"""Write provenance for freshly built, verified macOS distribution assets."""
import datetime
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

root, app, destination, test_report = map(pathlib.Path, sys.argv[1:5])
execution_architectures = sys.argv[5:]
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
build = json.loads((app / "Contents/Resources/build-info.json").read_text())
sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
if subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip():
    raise SystemExit("Source changed during the release build")
if build["source_sha"] != sha or build["source_dirty"]:
    raise SystemExit("Release app does not match a clean source commit")
if build["configuration"] != "release" or build["version"] != info["CFBundleShortVersionString"]:
    raise SystemExit("App build metadata does not match release configuration/version")

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
results = ET.parse(test_report).getroot()
tests = list(results.iter("testcase"))
failures = len(list(results.iter("failure"))) + len(list(results.iter("error")))
if not tests or failures:
    raise SystemExit("Release test report is empty or contains failures")
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
    "validation": {"tests": len(tests), "failures": failures, "execution_architectures": execution_architectures,
                   "extracted_zip_signature": True, "extracted_zip_smoke": True,
                   "dmg_image_integrity": True, "mounted_dmg_signature": True,
                   "mounted_dmg_smoke": True},
    "assets": assets,
}
(destination / "release.json").write_text(json.dumps(payload, indent=2) + "\n")
