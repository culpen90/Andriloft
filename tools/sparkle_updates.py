"""Validate signed Sparkle feeds and archives against the shipped public key."""

import base64
import binascii
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET


SPARKLE_VERSION = "2.10.0"
REPOSITORY = "culpen90/Andriloft"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEED_SIGNATURE_PREFIX = b"<!-- sparkle-signatures:\n"


def validate_framework_info(info):
    if info.get("CFBundleIdentifier") != "org.sparkle-project.Sparkle" or info.get("CFBundleShortVersionString") != SPARKLE_VERSION:
        raise ValueError(f"The updater and signing tools must use pinned Sparkle {SPARKLE_VERSION}")


def decode_base64(value, length, label):
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError, TypeError):
        raise ValueError(f"Invalid Sparkle {label}") from None
    if len(decoded) != length:
        raise ValueError(f"Invalid Sparkle {label} length")
    return decoded


def validate_updater_info(info, repository=REPOSITORY):
    feed_url = f"https://github.com/{repository}/releases/latest/download/appcast.xml"
    if info.get("SUFeedURL") != feed_url:
        raise ValueError("App Sparkle feed URL does not match the release repository")
    decode_base64(info.get("SUPublicEDKey"), 32, "public key")
    if info.get("SURequireSignedFeed") is not True or info.get("SUVerifyUpdateBeforeExtraction") is not True:
        raise ValueError("App must require signed Sparkle feeds and archive verification before extraction")
    if info.get("SUSignedFeedFailureExpirationInterval") != 0 or isinstance(info.get("SUSignedFeedFailureExpirationInterval"), bool):
        raise ValueError("App must keep signed-feed verification strict without an expiration fallback")
    return feed_url, info["SUPublicEDKey"]


def verify_ed25519(filename, signature, public_key):
    """Use OpenSSL's Ed25519 implementation; keep Python free of crypto dependencies."""
    public_key = decode_base64(public_key, 32, "public key")
    signature = decode_base64(signature, 64, "signature")
    # RFC 8410 SubjectPublicKeyInfo with id-Ed25519 and a 32-byte public key.
    public_der = bytes.fromhex("302a300506032b6570032100") + public_key
    with tempfile.TemporaryDirectory(prefix="andriloft-update-verify-") as temporary:
        directory = Path(temporary)
        (directory / "public.der").write_bytes(public_der)
        (directory / "signature").write_bytes(signature)
        result = subprocess.run(
            [os.environ.get("ANDRILOFT_OPENSSL", "openssl"), "pkeyutl", "-verify", "-pubin",
             "-inkey", str(directory / "public.der"), "-keyform", "DER", "-rawin",
             "-in", str(filename), "-sigfile", str(directory / "signature")],
            capture_output=True, text=True,
            env={key: value for key, value in os.environ.items() if key != "SPARKLE_PRIVATE_KEY"},
        )
        if result.returncode:
            raise ValueError("Sparkle Ed25519 signature verification failed (OpenSSL 3 is required)")


def signed_feed_content(data):
    """Extract exactly the bytes verified by Sparkle's SPUExtractAppcastContent."""
    offset = data.rfind(FEED_SIGNATURE_PREFIX)
    if offset < 0 or data.count(FEED_SIGNATURE_PREFIX) != 1:
        raise ValueError("Appcast must contain exactly one Sparkle feed signature")
    match = re.fullmatch(
        rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]+={0,2})\nlength: ([1-9][0-9]*)\n-->\n?",
        data[offset:],
    )
    if not match or int(match[2]) != offset:
        raise ValueError("Invalid Sparkle feed signature block or signed content length")
    return data[:offset], match[1].decode("ascii")


def validate_appcast(filename, archive, info, version, build_number, repository=REPOSITORY):
    feed_url, public_key = validate_updater_info(info, repository)
    content, feed_signature = signed_feed_content(Path(filename).read_bytes())
    with tempfile.TemporaryDirectory(prefix="andriloft-feed-verify-") as temporary:
        content_file = Path(temporary) / "feed.xml"
        content_file.write_bytes(content)
        verify_ed25519(content_file, feed_signature, public_key)
    try:
        root = ET.fromstring(content)
    except ET.ParseError:
        raise ValueError("Invalid appcast XML") from None
    items = root.findall("./channel/item")
    if root.tag != "rss" or len(root.findall("channel")) != 1 or len(items) != 1:
        raise ValueError("Appcast must contain exactly one release item")
    item = items[0]
    for name, value in (("version", str(build_number)), ("shortVersionString", version),
                        ("minimumSystemVersion", info["LSMinimumSystemVersion"])):
        elements = item.findall(f"{{{SPARKLE_NS}}}{name}")
        if len(elements) != 1 or elements[0].text != value:
            raise ValueError(f"Appcast {name} does not match the embedded app")
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        raise ValueError("Appcast must contain one update archive enclosure")
    enclosure = enclosures[0]
    expected_url = f"https://github.com/{repository}/releases/download/v{version}/{Path(archive).name}"
    if enclosure.get("url") != expected_url or enclosure.get("type") != "application/octet-stream":
        raise ValueError("Appcast archive URL/type does not match the immutable release ZIP")
    if enclosure.get("length") != str(Path(archive).stat().st_size):
        raise ValueError("Appcast archive length does not match the ZIP")
    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature")
    verify_ed25519(archive, signature, public_key)
    return {"framework": "Sparkle", "version": SPARKLE_VERSION, "feed_url": feed_url,
            "public_key": public_key, "archive": Path(archive).name, "archive_signature": signature,
            "appcast_sha256": hashlib.sha256(Path(filename).read_bytes()).hexdigest()}
