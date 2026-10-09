#!/usr/bin/env python3
"""Plan a SemVer release from published GitHub releases and complete Git history.

This deliberately performs no network calls or repository mutations. The caller
must supply a JSON array from GitHub's releases API and fetch complete history
and tags before invoking it.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
HEADER = re.compile(
    r"(?P<type>[a-z][a-z0-9-]*)(?:\([^()\r\n]+\))?(?P<breaking>!)?: (?P<description>\S.*)\Z"
)
BREAKING_FOOTER = re.compile(r"BREAKING(?: CHANGE|-CHANGE): \S.*\Z")
FOOTER = re.compile(r"(?:[A-Za-z][A-Za-z0-9-]*: |[A-Za-z][A-Za-z0-9-]* #)\S.*\Z")


class PlanningError(Exception):
    """An invalid release state that must stop publication."""


def git(repo, *args):
    result = subprocess.run(
        ["git", "-C", str(repo), *args], text=True, capture_output=True, check=False
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise PlanningError(f"git {' '.join(args)} failed: {detail}")
    return result.stdout.strip()


def commit_sha(repo, ref):
    return git(repo, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}")


def is_ancestor(repo, older, newer):
    result = subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", older, newer],
        text=True, capture_output=True, check=False,
    )
    if result.returncode not in (0, 1):
        raise PlanningError(result.stderr.strip() or "Could not compare release history")
    return result.returncode == 0


def stable_releases(releases):
    if not isinstance(releases, list):
        raise PlanningError("Releases JSON must be an array of GitHub release objects")
    stable = []
    for release in releases:
        if not isinstance(release, dict) or not isinstance(release.get("tag_name"), str):
            raise PlanningError("Every release must contain a string tag_name")
        for key in ("draft", "prerelease"):
            if key in release and not isinstance(release[key], bool):
                raise PlanningError(f"Release {release['tag_name']} has a non-boolean {key}")
        if release.get("draft", False) or release.get("prerelease", False):
            continue
        tag = release["tag_name"]
        match = VERSION.fullmatch(tag[1:]) if tag.startswith("v") else None
        if match:
            stable.append((tuple(map(int, match.groups())), tag))
    return stable


def commit_bump(message):
    """Classify a valid Conventional Commit; every other change is a patch.

    A breaking footer must start its own paragraph, or follow another footer.
    Mentioning the words in prose, using a malformed header, or omitting its
    description does not accidentally request a major release.
    """
    lines = message.splitlines()
    header = HEADER.fullmatch(lines[0]) if lines else None
    if not header:
        return "patch"
    if header.group("breaking"):
        return "major"
    in_footers = False
    for index, line in enumerate(lines[1:], 1):
        boundary = index > 1 and not lines[index - 1].strip()
        if BREAKING_FOOTER.fullmatch(line) and (boundary or in_footers):
            return "major"
        if line.strip():
            in_footers = bool(FOOTER.fullmatch(line)) and (boundary or in_footers)
        else:
            in_footers = False
    return "minor" if header.group("type") == "feat" else "patch"


def increment(version, bump):
    major, minor, patch = version
    if bump == "major":
        return major + 1, 0, 0
    if bump == "minor":
        return major, minor + 1, 0
    return major, minor, patch + 1


def plan_release(repo, releases, source="HEAD", bump="auto", initial_version="0.1.0"):
    initial = VERSION.fullmatch(initial_version)
    if not initial:
        raise PlanningError("Initial version must be strict X.Y.Z without leading zeroes")
    if bump not in ("auto", "patch", "minor", "major"):
        raise PlanningError("Bump must be auto, patch, minor, or major")
    if git(repo, "rev-parse", "--is-shallow-repository") == "true":
        raise PlanningError("Release planning requires full Git history; unshallow the checkout first")
    sha = commit_sha(repo, source)
    build = git(repo, "rev-list", "--count", sha)
    if not build.isdecimal() or int(build) <= 0:
        raise PlanningError("Source must have a positive Git commit count")
    published = stable_releases(releases)
    previous = max(published, default=None)
    previous_tag = previous[1] if previous else ""
    base = ""
    if previous:
        try:
            base = commit_sha(repo, "refs/tags/" + previous_tag)
        except PlanningError as error:
            raise PlanningError(
                f"Published release tag {previous_tag} is unavailable locally; fetch full history and tags"
            ) from error
        if is_ancestor(repo, sha, base):
            return {
                "version": ".".join(map(str, previous[0])), "tag": previous_tag,
                "build": build, "source_sha": sha, "skip": True,
                "previous_tag": previous_tag, "bump": "none", "commits": [],
            }
        if not is_ancestor(repo, base, sha):
            raise PlanningError(
                f"Source {sha} diverges from published release {previous_tag}; refusing to reuse release history"
            )
    revision_range = base + ".." + sha if base else sha
    commits = []
    for commit in git(repo, "rev-list", "--reverse", revision_range).splitlines():
        message = git(repo, "show", "-s", "--format=%B", commit)
        commits.append({"sha": commit, "subject": message.splitlines()[0] if message else "(empty commit message)",
                        "bump": commit_bump(message)})
    if not commits:
        raise PlanningError("Source contains no commits to release")
    levels = {"patch": 0, "minor": 1, "major": 2}
    inferred = max((commit["bump"] for commit in commits), key=levels.get)
    selected = inferred if bump == "auto" else bump
    version = increment(previous[0], selected) if previous else tuple(map(int, initial.groups()))
    version_text = ".".join(map(str, version))
    tag = "v" + version_text
    if any(release["tag_name"] == tag and not release.get("draft", False) for release in releases):
        raise PlanningError(f"Candidate release {tag} is already published")
    existing_tags = set(git(repo, "tag", "--list").splitlines())
    if tag in existing_tags and commit_sha(repo, "refs/tags/" + tag) != sha:
        raise PlanningError(f"Candidate tag {tag} already points to a different source commit")
    return {
        "version": version_text, "tag": tag, "build": build, "source_sha": sha,
        "skip": False, "previous_tag": previous_tag,
        "bump": selected if previous else "initial", "commits": commits,
    }


def markdown_text(value):
    value = " ".join(value.split())
    return re.sub(r"([\\`*_{}\[\]()<>#!])", r"\\\1", value)


def release_notes(plan, repository=""):
    if repository and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise PlanningError("GH_REPO must be an owner/repository name")
    url = "https://github.com/" + repository if repository else ""
    version = plan["version"]
    lines = [f"# Andriloft {version}", "", f"Source: `{plan['source_sha']}` · App build: `{plan['build']}`", ""]
    if plan["skip"]:
        return "\n".join(lines + ["This source is already covered by the latest published release.", ""])
    lines += ["## Download and install", "",
              "Download the universal macOS DMG or ZIP from this release. Open the DMG and drag **Andriloft.app** into **Applications**, or extract the ZIP and move the app there.", "",
              "The app is ad hoc signed and is not notarized. No paid Apple Developer account is required to build or use this distribution. If macOS blocks the first launch, use the per-app **System Settings → Privacy & Security → Open Anyway** flow.", ""]
    if url:
        lines += [f"See the [installation guide]({url}/blob/{plan['source_sha']}/docs/INSTALL.md).", ""]
    lines += ["Checksums are included in `SHA256SUMS.txt`; `release.json` records the version, source commit, asset hashes, and build validation.", "",
              "Andriloft remains an experimental Android compatibility layer; most Android apps require APIs that are not implemented yet.", "",
              "## Changes", ""]
    for commit in plan["commits"]:
        short = commit["sha"][:7]
        reference = f"[{short}]({url}/commit/{commit['sha']})" if url else f"`{short}`"
        lines.append(f"- {markdown_text(commit['subject'])} ({reference})")
    if url and plan["previous_tag"]:
        lines += ["", f"[Full diff]({url}/compare/{plan['previous_tag']}...{plan['tag']})"]
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", type=Path)
    parser.add_argument("--releases", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--notes", required=True, type=Path)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--source", default="HEAD")
    parser.add_argument("--bump", choices=("auto", "patch", "minor", "major"), default="auto")
    parser.add_argument("--initial-version", default="0.1.0")
    args = parser.parse_args(argv)
    try:
        releases = json.loads(args.releases.read_text())
        plan = plan_release(args.repo, releases, args.source, args.bump, args.initial_version)
        plan["notes_path"] = str(args.notes)
        if "\n" in plan["notes_path"] or "\r" in plan["notes_path"]:
            raise PlanningError("Notes path cannot contain a newline")
        notes = release_notes(plan, os.environ.get("GH_REPO", ""))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.notes.parent.mkdir(parents=True, exist_ok=True)
        args.notes.write_text(notes)
        encoded = json.dumps(plan, indent=2) + "\n"
        args.output.write_text(encoded)
        if args.github_output:
            output = "".join(f"{key}={str(plan[key]).lower() if isinstance(plan[key], bool) else plan[key]}\n"
                             for key in ("version", "tag", "build", "source_sha", "skip", "previous_tag", "bump", "notes_path"))
            with args.github_output.open("a") as destination:
                destination.write(output)
        print(encoded, end="")
    except (PlanningError, OSError, json.JSONDecodeError) as error:
        print(f"Release planning failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
