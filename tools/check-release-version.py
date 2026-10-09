#!/usr/bin/env python3
"""Resolve, stamp, or verify release versions without changing source files."""

import argparse
import sys

from release_metadata import resolve_versions, stamp_versions, validate_app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    resolve = commands.add_parser("resolve")
    resolve.add_argument("info_plist")
    stamp = commands.add_parser("stamp")
    stamp.add_argument("info_plist")
    stamp.add_argument("version")
    stamp.add_argument("build_number")
    verify = commands.add_parser("verify")
    verify.add_argument("app")
    verify.add_argument("version")
    verify.add_argument("build_number")
    verify.add_argument("source_sha")
    args = parser.parse_args()
    try:
        if args.command == "resolve":
            print(*resolve_versions(args.info_plist))
        elif args.command == "stamp":
            stamp_versions(args.info_plist, args.version, args.build_number)
        else:
            validate_app(args.app, args.version, args.build_number, args.source_sha)
    except (OSError, ValueError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
