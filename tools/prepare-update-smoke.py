#!/usr/bin/env python3
"""Prepare an isolated signed old-to-new updater fixture without launching it.

The fixture copies a packaged app, preserves Sparkle's framework and helpers,
and uses a throwaway signing key held only in this process's memory. Neither
the production release key nor the user's Andriloft library is used.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import socket
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def clean_environment():
    environment = os.environ.copy()
    environment.pop("SPARKLE_PRIVATE_KEY", None)
    environment.pop("SPARKLE_KEYCHAIN_ACCOUNT", None)
    return environment


def run(*arguments, input_text=None, signing=False):
    result = subprocess.run(
        [str(argument) for argument in arguments],
        input=input_text,
        env=clean_environment(),
        text=True,
        capture_output=True,
    )
    if result.returncode:
        # Tools that consume a private key may include it in malformed-key errors.
        details = "" if signing else result.stderr.strip()
        raise ValueError(f"{Path(str(arguments[0])).name} failed" + (f": {details}" if details else ""))
    return result.stdout


def framework_digest(framework):
    digest = hashlib.sha256()
    for path in sorted(framework.rglob("*")):
        digest.update(str(path.relative_to(framework)).encode())
        if path.is_symlink():
            digest.update(b"symlink\0" + os.readlink(path).encode())
        elif path.is_file():
            digest.update(path.read_bytes())
    return digest.hexdigest()


def verify_app(app):
    run("codesign", "--verify", "--deep", "--strict", "--all-architectures", app)
    framework = app / "Contents/Frameworks/Sparkle.framework"
    if not framework.is_dir():
        raise ValueError("Packaged app does not contain Sparkle.framework")
    for architecture in run("lipo", "-archs", app / "Contents/MacOS/Andriloft").split():
        entitlements = run("codesign", "--display", "--arch", architecture, "--entitlements", ":-", app).strip()
        if entitlements and plistlib.loads(entitlements.encode()):
            raise ValueError("Fixture requires a packaged app with no outer entitlements")
    if (app / "Contents/PlugIns").exists():
        raise ValueError("Fixture requires an app without test plug-ins")


def unused_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def prepare(app, output, tools, port):
    app = app.resolve()
    tools = tools.resolve()
    if not (app / "Contents/MacOS/Andriloft").is_file():
        raise ValueError("--app must be a packaged Andriloft.app")
    for name in ("generate_appcast", "sign_update"):
        if not os.access(tools / name, os.X_OK):
            raise ValueError(f"Pinned Sparkle tool is missing: {name}")
    if not 1024 <= port <= 65535:
        raise ValueError("--port must be between 1024 and 65535")
    verify_app(app)
    original_framework = framework_digest(app / "Contents/Frameworks/Sparkle.framework")
    if output is None:
        fixture = Path(tempfile.mkdtemp(prefix="andriloft-update-smoke-", dir="/tmp")).resolve()
    else:
        fixture = output.resolve()
        fixture.mkdir(mode=0o700, parents=True, exist_ok=False)
    fixture.chmod(0o700)
    for name in ("installed", "next", "feed", "evidence"):
        (fixture / name).mkdir(mode=0o700)

    identity = uuid.uuid4().hex
    bundle_id = f"dev.andriloft.update-smoke.{identity}"
    display_name = f"Andriloft Update Smoke {identity[:12]}"
    library = Path.home() / "Library/Application Support" / display_name
    base_url = f"http://127.0.0.1:{port}/"
    # Sparkle 2.10 expects a 32-byte seed (or its legacy 96-byte key format).
    # CryptoKit returns the same Ed25519 raw seed. It never enters Keychain or a file.
    key_result = run("xcrun", "swift", "-", input_text="""import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
let payload = ["private": key.rawRepresentation.base64EncodedString(),
               "public": key.publicKey.rawRepresentation.base64EncodedString()]
let data = try JSONSerialization.data(withJSONObject: payload)
FileHandle.standardOutput.write(data)
""", signing=True)
    keys = json.loads(key_result)
    private_key, public_key = keys["private"], keys["public"]

    def make_app(destination, version, build):
        run("ditto", "--norsrc", "--noextattr", "--noqtn", app, destination)
        info_path = destination / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info.update({
            "CFBundleIdentifier": bundle_id,
            "CFBundleName": display_name,
            "CFBundleDisplayName": display_name,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "SUDefaultsDomain": bundle_id + ".updates",
            "SUFeedURL": base_url + "appcast.xml",
            "SUPublicEDKey": public_key,
            "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True,
            "SUSignedFeedFailureExpirationInterval": 0,
            "SUEnableAutomaticChecks": False,
            "SUAllowsAutomaticUpdates": False,
            "SUAutomaticallyUpdate": False,
            "SUEnableSystemProfiling": False,
        })
        # This exception exists only in temporary copies, and is limited to loopback.
        info.setdefault("NSAppTransportSecurity", {}).setdefault("NSExceptionDomains", {})["127.0.0.1"] = {
            "NSExceptionAllowsInsecureHTTPLoads": True,
        }
        info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
        build_info = destination / "Contents/Resources/build-info.json"
        if build_info.is_file():
            payload = json.loads(build_info.read_text())
            payload.update({"version": version, "build": build, "update_smoke_fixture": identity})
            build_info.write_text(json.dumps(payload, indent=2) + "\n")
        run("xattr", "-cr", destination)
        # Never use --deep while signing: Sparkle's nested helpers stay byte-for-byte.
        run("codesign", "--force", "--sign", "-", "--timestamp=none", destination)
        verify_app(destination)
        if framework_digest(destination / "Contents/Frameworks/Sparkle.framework") != original_framework:
            raise ValueError("Fixture preparation changed Sparkle's framework or helper signatures")

    installed = fixture / "installed/Andriloft.app"
    next_app = fixture / "next/Andriloft.app"
    make_app(installed, "0.0.1", "1")
    make_app(next_app, "0.0.2", "2")
    archive = fixture / "feed/Andriloft-Smoke-0.0.2.zip"
    run("ditto", "-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", next_app, archive)
    (fixture / "feed/Andriloft-Smoke-0.0.2.html").write_text(
        "<h2>Local update smoke test</h2><p>Install Update downloads, verifies, installs, and restarts this isolated test app.</p>"
    )
    appcast = fixture / "feed/appcast.xml"
    run(tools / "generate_appcast", "--ed-key-file", "-", "--maximum-deltas", "0", "--maximum-versions", "1",
        "--download-url-prefix", base_url, "--embed-release-notes", "-o", appcast, fixture / "feed",
        input_text=private_key + "\n", signing=True)
    run(tools / "sign_update", "--ed-key-file", "-", "--verify", appcast,
        input_text=private_key + "\n", signing=True)
    import xml.etree.ElementTree as ET
    enclosure = ET.fromstring(appcast.read_bytes()).find("./channel/item/enclosure")
    if enclosure is None or enclosure.get("url") != base_url + archive.name:
        raise ValueError("Fixture feed does not point to its loopback update archive")
    signature = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
    if not signature:
        raise ValueError("Fixture archive is missing its Sparkle signature")
    run(tools / "sign_update", "--ed-key-file", "-", "--verify", archive, signature,
        input_text=private_key + "\n", signing=True)

    manifest = {
        "fixture": str(fixture), "installed_app": str(installed), "new_app_source": str(next_app),
        "bundle_identifier": bundle_id, "updater_defaults_domain": bundle_id + ".updates",
        "display_name": display_name, "library": str(library), "feed_directory": str(fixture / "feed"),
        "feed_url": base_url + "appcast.xml", "port": port,
        "expected_version": "0.0.2", "expected_build": "2", "public_key": public_key,
        "source_app": str(app), "source_executable_sha256": hashlib.sha256((app / "Contents/MacOS/Andriloft").read_bytes()).hexdigest(),
        "sparkle_framework_sha256": original_framework,
        "prepared_signature_checks": "old app, new app, update archive, signed feed verified",
        "ui_update_performed": False,
    }
    (fixture / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    serve = shlex.join(["python3", "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", str(fixture / "feed")])
    launch = shlex.join(["open", "-n", str(installed)])
    (fixture / "REPRO.txt").write_text(
        "This script prepared the fixture only. No application or server has been launched.\n"
        "The packaged app must select its library folder using CFBundleName.\n"
        "The old and new app have the same unique name and use this isolated library:\n" + str(library) + "\n\n"
        "Start the loopback-only server in a separate terminal:\n" + serve + "\n\n"
        "Launch the OLD installed app only:\n" + launch + "\n\n"
        "1. Add Example App. Verify library.json and its APK use the isolated library above.\n"
        "2. Record the installed app's PID, version/build (0.0.1/1), and library/APK hashes.\n"
        "3. Click Check for Updates. Confirm new version 0.0.2 is offered.\n"
        "4. Click Install Update once. Observe download, verification, installation, and automatic restart.\n"
        "5. Verify the old PID exited; the new PID runs the same installed/Andriloft.app path.\n"
        "6. Confirm installed/Andriloft.app/Contents/Info.plist is version 0.0.2/build 2.\n"
        "7. Confirm the example library entry/APK hashes survived and the example still runs.\n"
        "8. Check again and observe the up-to-date dialog. Save screenshots/logs in evidence/.\n"
        "9. Quit the fixture app and stop the server. Do not launch next/Andriloft.app.\n\n"
        "Post-update verification command:\n"
        + shlex.join(["codesign", "--verify", "--deep", "--strict", "--all-architectures", str(installed)]) + "\n\n"
        "All fixture apps, archive, feed, synthetic data, and evidence are local.\n"
        "The throwaway private key was never saved or shown, and has been discarded.\n"
        "The production release key, production feed, and normal user library are not used.\n"
        "The synthetic library uses a unique Application Support folder shown above.\n"
        "macOS may create defaults/caches for the unique bundle ID in manifest.json.\n"
    )
    return fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Packaged app containing the updater")
    parser.add_argument("--output", type=Path, help="New fixture directory (default: a fresh directory under /tmp)")
    parser.add_argument("--tools", type=Path, default=ROOT / ".build/artifacts/sparkle/Sparkle/bin")
    parser.add_argument("--port", type=int, help="Loopback port (default: an available port selected during preparation)")
    args = parser.parse_args()
    fixture = prepare(args.app, args.output, args.tools, args.port if args.port is not None else unused_port())
    print(f"Prepared signed update smoke fixture: {fixture}")
    print(f"Instructions: {fixture / 'REPRO.txt'}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"Update smoke preparation failed: {error}")
