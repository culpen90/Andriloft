#!/usr/bin/env python3
"""Generate and verify the release appcast with the pinned Sparkle distribution."""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from release_metadata import validate_versions
from sparkle_updates import SPARKLE_NS, signed_feed_content, validate_appcast, validate_framework_info, validate_updater_info


def generate(app, archive, destination, tools):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version, build_number = validate_versions(info["CFBundleShortVersionString"], info["CFBundleVersion"])
    validate_updater_info(info)
    framework_info = app / "Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
    validate_framework_info(plistlib.loads(framework_info.read_bytes()))
    distribution_plists = [
        tools.parent / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Resources/Info.plist",
        tools.parent / "Sparkle.framework/Versions/B/Resources/Info.plist",
    ]
    distribution_info = next((path for path in distribution_plists if path.is_file()), None)
    if distribution_info is None:
        raise ValueError("Cannot validate the pinned Sparkle signing tools distribution")
    validate_framework_info(plistlib.loads(distribution_info.read_bytes()))
    private_key = os.environ.get("SPARKLE_PRIVATE_KEY", "").strip()
    # Validate before invoking Sparkle: its malformed-key diagnostics can echo input.
    try:
        import base64
        decoded = base64.b64decode(private_key, validate=True)
    except (ValueError, TypeError):
        raise ValueError("SPARKLE_PRIVATE_KEY must be an exported Sparkle Ed25519 key") from None
    if len(decoded) not in (32, 96):
        raise ValueError("SPARKLE_PRIVATE_KEY must be an exported Sparkle Ed25519 key")
    environment = {key: value for key, value in os.environ.items() if key != "SPARKLE_PRIVATE_KEY"}
    for tool in ("generate_appcast", "sign_update"):
        if not (tools / tool).is_file() or not os.access(tools / tool, os.X_OK):
            raise ValueError(f"Missing pinned Sparkle tool: {tool}")

    def run(tool, *arguments):
        result = subprocess.run([str(tools / tool), "--ed-key-file", "-", *map(str, arguments)],
                                input=private_key + "\n", text=True, capture_output=True, env=environment)
        if result.returncode:
            # Do not print tool diagnostics from a process that consumed a private key.
            raise ValueError(f"Sparkle {tool} failed; verify the key, app bundle, and tools")

    with tempfile.TemporaryDirectory(prefix="andriloft-appcast-") as temporary:
        updates = Path(temporary)
        shutil.copyfile(archive, updates / archive.name)
        run("generate_appcast", "--download-url-prefix",
            f"https://github.com/culpen90/Andriloft/releases/download/v{version}/",
            "--maximum-deltas", "0", "--maximum-versions", "1", "-o", updates / "appcast.xml", updates)
        # Keep the install/restart notice inside the signed feed; no remote notes are needed.
        content, _ = signed_feed_content((updates / "appcast.xml").read_bytes())
        ET.register_namespace("sparkle", SPARKLE_NS)
        feed = ET.fromstring(content)
        items = feed.findall("./channel/item")
        if len(items) != 1:
            raise ValueError("Sparkle did not generate exactly one release item")
        description = ET.SubElement(items[0], "description")
        description.text = ("Choose Install Update to download, verify, install, and restart Andriloft automatically. "
                            "Open Android windows will close. Your imported APK library will be kept.")
        (updates / "appcast.xml").write_bytes(ET.tostring(feed, encoding="utf-8", xml_declaration=True) + b"\n")
        run("sign_update", updates / "appcast.xml")
        # Verify both with Sparkle itself and independently against the shipped public key.
        updater = validate_appcast(updates / "appcast.xml", archive, info, version, build_number)
        run("sign_update", "--verify", archive, updater["archive_signature"])
        run("sign_update", "--verify", updates / "appcast.xml")
        shutil.copyfile(updates / "appcast.xml", destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tools", type=Path, required=True)
    args = parser.parse_args()
    generate(args.app, args.archive, args.output, args.tools)
    print("Verified Sparkle archive and signed appcast")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Appcast generation failed: {error}")
