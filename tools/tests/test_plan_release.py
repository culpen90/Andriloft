"""Exercise SemVer planning against real temporary Git repositories."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "plan-release.py"
SPEC = importlib.util.spec_from_file_location("plan_release", SCRIPT)
PLANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLANNER)
TEST_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull}


def release(tag, **extra):
    return {"tag_name": tag, "draft": False, "prerelease": False, **extra}


class GitRepository(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name) / "repo"
        self.repo.mkdir()
        self.run_git("init", "-q", "-b", "main")
        self.run_git("config", "user.name", "Release Test")
        self.run_git("config", "user.email", "release-test@example.invalid")

    def run_git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True, env=TEST_ENV).strip()

    def commit(self, message):
        self.run_git("commit", "--allow-empty", "-q", "-m", message)
        return self.run_git("rev-parse", "HEAD")

    def baseline(self):
        sha = self.commit("feat: introduce the app")
        self.run_git("tag", "v0.1.0")
        return sha

    def plan(self, releases=None, **kwargs):
        return PLANNER.plan_release(self.repo, releases if releases is not None else [release("v0.1.0")], **kwargs)

    def test_first_release_uses_initial_version_and_positive_build(self):
        sha = self.commit("feat!: initial prototype")
        plan = self.plan([])
        self.assertEqual((plan["version"], plan["tag"], plan["build"]), ("0.1.0", "v0.1.0", "1"))
        self.assertEqual(plan["source_sha"], sha)
        self.assertEqual(plan["bump"], "initial")
        self.assertFalse(plan["skip"])

    def test_patch_for_any_new_commit_and_increasing_build(self):
        self.baseline()
        sha = self.commit("Update installation guide")
        plan = self.plan()
        self.assertEqual((plan["version"], plan["build"]), ("0.1.1", "2"))
        self.assertEqual([commit["sha"] for commit in plan["commits"]], [sha])

    def test_feature_selects_minor_from_all_new_commits(self):
        self.baseline()
        feature = self.commit("feat(runtime): add activity state")
        fix = self.commit("fix: handle missing input")
        plan = self.plan()
        self.assertEqual(plan["version"], "0.2.0")
        self.assertEqual([commit["sha"] for commit in plan["commits"]], [feature, fix])

    def test_breaking_footer_uses_full_message_and_selects_major(self):
        self.baseline()
        self.commit("feat: add activity state")
        self.commit("fix: change import handling\n\nDetails about the change.\n\nBREAKING CHANGE: remove the old import format")
        self.assertEqual(self.plan()["version"], "1.0.0")

    def test_same_source_skips_including_manual_bump(self):
        sha = self.baseline()
        for bump in ("auto", "patch", "minor", "major"):
            with self.subTest(bump=bump):
                plan = self.plan(bump=bump)
                self.assertTrue(plan["skip"])
                self.assertEqual(plan["source_sha"], sha)
                self.assertEqual(plan["version"], "0.1.0")
                self.assertEqual(plan["commits"], [])

    def test_delayed_older_source_skips(self):
        older = self.commit("feat: introduce app")
        self.commit("fix: improve input")
        self.run_git("tag", "v0.1.0")
        plan = self.plan(source=older)
        self.assertTrue(plan["skip"])
        self.assertEqual(plan["source_sha"], older)

    def test_divergent_history_stops_release(self):
        older = self.commit("feat: introduce app")
        self.commit("fix: released improvement")
        self.run_git("tag", "v0.1.0")
        self.run_git("checkout", "-q", "-b", "other", older)
        self.commit("fix: different improvement")
        with self.assertRaisesRegex(PLANNER.PlanningError, "diverges"):
            self.plan()

    def test_numeric_largest_published_version_wins(self):
        self.commit("feat: introduce app")
        self.run_git("tag", "v1.9.9")
        self.commit("fix: released improvement")
        self.run_git("tag", "v1.10.0")
        self.commit("fix: new improvement")
        plan = self.plan([release("v1.10.0"), release("v1.9.9")])
        self.assertEqual((plan["previous_tag"], plan["version"]), ("v1.10.0", "1.10.1"))

    def test_ignore_drafts_prereleases_and_noncanonical_tags(self):
        self.baseline()
        self.commit("fix: improve imports")
        ignored = [release("v9.0.0", draft=True), release("v8.0.0", prerelease=True),
                   release("v7.0.0-beta.1"), release("v06.0.0"), release("v5.00.0"),
                   release("v4.0.00"), release("3.0.0"), release("v2.0.0+build.1"),
                   release("v1.0.0\n")]
        plan = self.plan([release("v0.1.0"), *ignored])
        self.assertEqual(plan["version"], "0.1.1")

    def test_annotated_release_tag_resolves_to_commit(self):
        self.commit("feat: introduce app")
        self.run_git("tag", "-a", "v0.1.0", "-m", "Release v0.1.0")
        self.commit("fix: improve input")
        self.assertEqual(self.plan()["version"], "0.1.1")

    def test_published_tag_missing_locally_stops_release(self):
        self.commit("feat: introduce app")
        with self.assertRaisesRegex(PLANNER.PlanningError, "unavailable locally"):
            self.plan()

    def test_candidate_tag_at_different_commit_stops_release(self):
        base = self.baseline()
        self.run_git("tag", "v0.1.1", base)
        self.commit("fix: improve input")
        with self.assertRaisesRegex(PLANNER.PlanningError, "different source commit"):
            self.plan()

    def test_unpublished_same_source_tag_allows_draft_retry(self):
        self.baseline()
        sha = self.commit("fix: improve input")
        self.run_git("tag", "v0.1.1", sha)
        plan = self.plan([release("v0.1.0"), release("v0.1.1", draft=True)])
        self.assertEqual(plan["tag"], "v0.1.1")
        self.assertFalse(plan["skip"])

    def test_published_same_source_candidate_skips(self):
        self.baseline()
        self.commit("fix: improve input")
        self.run_git("tag", "v0.1.1")
        plan = self.plan([release("v0.1.0"), release("v0.1.1")])
        self.assertTrue(plan["skip"])
        self.assertEqual(plan["tag"], "v0.1.1")

    def test_published_prerelease_cannot_be_reused_as_a_stable_release(self):
        self.baseline()
        self.commit("fix: improve input")
        self.run_git("tag", "v0.1.1")
        with self.assertRaisesRegex(PLANNER.PlanningError, "already published"):
            self.plan([release("v0.1.0"), release("v0.1.1", prerelease=True)])

    def test_manual_bump_overrides_inferred_level(self):
        self.baseline()
        self.commit("feat!: replace import format")
        for bump, version in (("patch", "0.1.1"), ("minor", "0.2.0"), ("major", "1.0.0")):
            with self.subTest(bump=bump):
                self.assertEqual(self.plan(bump=bump)["version"], version)

    def test_source_is_frozen_when_head_moves(self):
        self.baseline()
        source = self.commit("fix: queued release")
        self.commit("feat!: change made after the queue")
        plan = self.plan(source=source)
        self.assertEqual(plan["source_sha"], source)
        self.assertEqual(plan["version"], "0.1.1")
        self.assertEqual(plan["build"], "2")

    def test_shallow_checkout_stops_release(self):
        self.baseline()
        self.commit("fix: improve input")
        shallow = Path(self.directory.name) / "shallow"
        subprocess.run(["git", "clone", "-q", "--depth=1", self.repo.as_uri(), str(shallow)], check=True, env=TEST_ENV)
        with self.assertRaisesRegex(PLANNER.PlanningError, "full Git history"):
            PLANNER.plan_release(shallow, [])

    def test_merge_history_includes_branch_commits(self):
        self.baseline()
        self.run_git("checkout", "-q", "-b", "feature")
        feature = self.commit("feat: add framework support")
        self.run_git("checkout", "-q", "main")
        self.commit("fix: improve app launch")
        self.run_git("merge", "--no-ff", "-q", "feature", "-m", "Merge framework support")
        plan = self.plan()
        self.assertEqual(plan["version"], "0.2.0")
        self.assertIn(feature, [commit["sha"] for commit in plan["commits"]])
        self.assertEqual(plan["build"], "4")

    def test_cli_writes_plan_notes_and_github_outputs(self):
        self.baseline()
        sha = self.commit("fix: render <script> and [links] safely")
        releases = Path(self.directory.name) / "releases.json"
        releases.write_text(json.dumps([release("v0.1.0")]))
        output = Path(self.directory.name) / "output/plan.json"
        notes = Path(self.directory.name) / "output/notes.md"
        github_output = Path(self.directory.name) / "github-output"
        environment = {**TEST_ENV, "GH_REPO": "example/Andriloft"}
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(self.repo), "--releases", str(releases),
             "--output", str(output), "--notes", str(notes), "--github-output", str(github_output)],
            check=True, capture_output=True, text=True, env=environment,
        )
        plan = json.loads(output.read_text())
        self.assertEqual(json.loads(result.stdout), plan)
        self.assertEqual(plan["source_sha"], sha)
        self.assertEqual(plan["notes_path"], str(notes))
        self.assertIn("skip=false\n", github_output.read_text())
        self.assertIn("https://github.com/example/Andriloft/commit/" + sha, notes.read_text())
        self.assertIn("\\<script\\>", notes.read_text())
        self.assertIn("\\[links\\]", notes.read_text())
        self.assertNotIn("release-test@example.invalid", notes.read_text())
        self.assertIn("No paid Apple Developer account", notes.read_text())
        self.assertIn("`SHA256SUMS.txt`", notes.read_text())


class ClassificationTests(unittest.TestCase):
    def test_valid_conventional_commit_markers(self):
        cases = {
            "fix: handle bad archives": "patch",
            "chore: update documentation": "patch",
            "feat: support more framework calls": "minor",
            "feat(runtime): support more framework calls": "minor",
            "fix!: replace state format": "major",
            "feat(runtime)!: replace state format": "major",
            "fix: change state\n\nBREAKING CHANGE: replace state format": "major",
            "fix: change state\n\nBREAKING-CHANGE: replace state format": "major",
            "fix: change state\n\nRefs: #2\nBREAKING CHANGE: replace state format": "major",
        }
        for message, expected in cases.items():
            with self.subTest(message=message):
                self.assertEqual(PLANNER.commit_bump(message), expected)

    def test_malformed_or_incidental_markers_do_not_trigger_bumps(self):
        cases = ["feature: support imports", "feat:", "feat: ", "feat:no space", "feat(): bad scope",
                 "feat(scope)! missing colon", "Feat: uppercase type", "fix: mention BREAKING CHANGE: in prose",
                 "fix: update parser\n\nThe phrase BREAKING CHANGE: appears in a test.",
                 "fix: update parser\nBREAKING CHANGE: no paragraph separator",
                 "fix: update parser\n\nBREAKING CHANGE:", "fix: update parser\n\nBREAKING CHANGE: ",
                 "update parser\n\nBREAKING CHANGE: no Conventional Commit header"]
        for message in cases:
            with self.subTest(message=message):
                self.assertEqual(PLANNER.commit_bump(message), "patch")

    def test_invalid_release_json_stops_planning(self):
        for releases in ({}, ["v0.1.0"], [{}], [release("v0.1.0", draft="false")]):
            with self.subTest(releases=releases):
                with self.assertRaises(PLANNER.PlanningError):
                    PLANNER.stable_releases(releases)

    def test_initial_version_rejects_noncanonical_values(self):
        for version in ("v0.1.0", "01.0.0", "0.01.0", "0.1.00", "0.1.0-beta.1"):
            with self.subTest(version=version):
                with self.assertRaisesRegex(PLANNER.PlanningError, "Initial version"):
                    PLANNER.plan_release(Path("unused"), [], initial_version=version)


if __name__ == "__main__":
    unittest.main()
