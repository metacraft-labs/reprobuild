"""`repro-publish-repos.sh` addresses seven surfaces, five of them buckets.

WHY THIS FILE EXISTS

`infra`'s `terraform/cloudflare/reprobuild-prod` provisions five R2 buckets --
`reprobuild-{deb,rpm,arch,downloads,keys}-prod` -- each bound by an R2 custom
domain to one hostname and therefore served at the ROOT of it:
`deb.reprobuild.com/dists/stable/InRelease` needs a bucket whose key
`dists/stable/InRelease` is at its root. The publisher took ONE `--target` and
wrote six prefixes under it, which addresses none of the five.

The mismatch was sharper than a count. `scoop` had a prefix and no bucket;
`downloads` had a bucket and no prefix, and both of those were wrong in
opposite directions:

  * a Scoop bucket is a GIT REPOSITORY -- `scoop bucket add` clones it -- so an
    R2 prefix full of `bucket/reprobuild.json` is a tree no client can consume,
    and terraform is right to provision no bucket for it. The same is true of a
    Homebrew tap.
  * `repro-install.sh --method tarball` fetches
    `$REPRO_DOWNLOADS_URL/v<version>/{<asset>,SHA256SUMS,SHA256SUMS.asc}` and
    terraform provisions `downloads.reprobuild.com` for exactly that. Nothing
    wrote it, so that hostname would have resolved, served, and held nothing.

NON-VACUITY

Every case below drives the REAL script and reads its exit code back rather
than asserting on a string alone. `assertNotIn` is the one shape that can pass
because nothing happened, so every case that uses it also asserts something
positive about the SAME captured stream -- a negative claim about an empty file
proves nothing. `_assert_absent` enforces that pairing rather than trusting it.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PUBLISH = REPO_ROOT / "scripts" / "release" / "repro-publish-repos.sh"
VERSION = "9.9.9"


class Run:
    """One invocation, with its streams and its exit code captured."""

    def __init__(self, rc: int, out: str, err: str):
        self.rc = rc
        self.out = out
        self.err = err


class PublishSurfaceRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sh = shutil.which("sh") or shutil.which("bash")
        if cls.sh is None:
            # Not a skip. The artefact under test IS a `sh` script; a host that
            # cannot run it cannot run the release either, and a green result
            # here would be a green off a test that never ran.
            raise AssertionError(
                "no sh/bash on PATH; repro-publish-repos.sh cannot be exercised"
            )
        cls.assertTrue(PUBLISH.is_file(), f"{PUBLISH} not found")

    @classmethod
    def assertTrue(cls, value, msg):  # used before an instance exists
        if not value:
            raise AssertionError(msg)

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="publish-routing-"))
        self.addCleanup(shutil.rmtree, self.work, ignore_errors=True)
        self.packages = self.work / "pkgs"
        self.archives = self.work / "archives"
        self.packages.mkdir()
        self.archives.mkdir()
        (self.packages / f"reprobuild-{VERSION}-windows-x86_64.zip").write_text(
            "zip payload\n", encoding="utf-8"
        )
        (self.packages / f"reprobuild-{VERSION}-darwin-aarch64.tar.gz").write_text(
            "tarball payload\n", encoding="utf-8"
        )
        asset = f"reprobuild-{VERSION}-linux-x86_64.tar.gz"
        (self.archives / asset).write_text("archive payload\n", encoding="utf-8")
        (self.archives / "SHA256SUMS").write_text(f"deadbeef  {asset}\n", encoding="utf-8")
        (self.archives / "SHA256SUMS.asc").write_text("signature\n", encoding="utf-8")

    def publish(self, *args: str) -> Run:
        proc = subprocess.run(
            [self.sh, str(PUBLISH), *args],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
        )
        return Run(proc.returncode, proc.stdout, proc.stderr)

    def _assert_absent(self, needle: str, haystack: str, anchor: str):
        """`needle` is not in `haystack`, and `haystack` is really the stream.

        A bare "not in" over a stream that happens to be empty is the classic
        vacuous pass, so the caller names an `anchor` that MUST be present.
        """
        self.assertIn(anchor, haystack, "the stream under test is not the stream")
        self.assertNotIn(needle, haystack)

    # ------------------------------------------------------------------ scoop
    def test_the_gates_local_scoop_invocation_is_unchanged(self):
        """Regression: `--target local:<dir>` still writes `<dir>/scoop/...`.

        `tools/multi-distro-harness/tests/m3_install_scoop.ps1` publishes with
        exactly this shape and then `git init`s the published directory -- a
        local directory tree IS a legitimate Scoop bucket source. The
        per-surface routing must not have moved it.
        """
        www = self.work / "www"
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "scoop",
            "--repo-root", str(self.work / "repo"),
            "--target", f"local:{www.as_posix()}",
            "--scoop-downloads-base", "http://localhost:9/downloads",
        )
        self.assertEqual(run.rc, 0, run.err)
        manifest = www / "scoop" / "bucket" / "reprobuild.json"
        self.assertTrue(manifest.is_file(), f"no manifest at {manifest}\n{run.err}")
        self.assertIn(f'"version": "{VERSION}"', manifest.read_text(encoding="utf-8"))

    def test_an_object_store_target_for_scoop_is_refused_before_anything_runs(self):
        """A Scoop bucket in R2 is a tree no `scoop bucket add` can clone.

        Refused at target-resolution time, which is BEFORE any signing or any
        generation -- the script's existing rule, because discovering a bad
        target afterwards leaves a signed tree nobody fetched.
        """
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "scoop",
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
            "--target-scoop", "r2:reprobuild-scoop-prod",
        )
        self.assertEqual(run.rc, 1)
        self.assertIn("is a GIT", run.err)
        self._assert_absent("scoop manifest: version", run.err, "is a GIT")

    def test_a_git_target_for_an_object_store_surface_is_refused(self):
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
            "--target-deb", "git:https://example.invalid/x",
        )
        self.assertEqual(run.rc, 1)
        self.assertIn("not a git remote", run.err)

    # ------------------------------------------------------------- five roots
    def test_each_bucket_is_addressed_at_its_own_root(self):
        """The five per-surface targets, resolved and logged before any work."""
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
            "--target-deb", "r2:reprobuild-deb-prod",
            "--target-rpm", "r2:reprobuild-rpm-prod",
            "--target-arch", "r2:reprobuild-arch-prod",
            "--target-downloads", "r2:reprobuild-downloads-prod",
            "--target-keys", "r2:reprobuild-keys-prod",
        )
        self.assertEqual(run.rc, 0, run.err)
        for surface in ("deb", "rpm", "arch", "downloads", "keys"):
            self.assertIn(f"surface {surface} -> r2:reprobuild-{surface}-prod", run.err)

    def test_a_generic_target_still_derives_prefixes_for_object_stores(self):
        """The old behaviour, byte for byte, and the gate depends on it."""
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--repo-root", str(self.work / "repo"),
            "--target", "r2:bucket/pfx",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertIn("surface deb -> r2:bucket/pfx/deb", run.err)
        self.assertIn("surface keys -> r2:bucket/pfx/keys", run.err)

    def test_a_generic_object_store_target_never_reaches_a_git_surface(self):
        """The rule that makes the scoop-prefix defect unrepeatable.

        A generic `--target r2:...` fans out to the five object-store surfaces
        and to NEITHER git-backed one, because appending `/scoop` to a bucket
        produces exactly the tree that looks published and cannot be cloned.
        """
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--repo-root", str(self.work / "repo"),
            "--target", "r2:bucket/pfx",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertIn("surface scoop -> none", run.err)
        self.assertIn("surface homebrew -> none", run.err)
        self._assert_absent("surface scoop -> r2:", run.err, "surface scoop -> none")

    # -------------------------------------------------------------- downloads
    def test_the_release_archives_reach_the_downloads_surface(self):
        """The bucket that had no prefix, at the paths the installer fetches."""
        www = self.work / "www"
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--archives", str(self.archives),
            "--repo-root", str(self.work / "repo"),
            "--target", f"local:{www.as_posix()}",
        )
        self.assertEqual(run.rc, 0, run.err)
        published = www / "downloads" / f"v{VERSION}"
        for name in (
            f"reprobuild-{VERSION}-linux-x86_64.tar.gz",
            "SHA256SUMS",
            "SHA256SUMS.asc",
        ):
            self.assertTrue((published / name).is_file(), f"{name} not published")

    def test_downloads_without_archives_is_a_skip_that_says_why(self):
        """Not a failure: the M3 gate and the pre-change release step pass no
        `--archives`, and dying there would block the trust anchor on an
        unrelated flag."""
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertIn("no --archives given", run.err)

    def test_downloads_refuses_an_archive_set_with_no_manifest(self):
        """`--method tarball` fetches SHA256SUMS by name and fails closed."""
        bare = self.work / "bare"
        bare.mkdir()
        (bare / "thing.tar.gz").write_text("x\n", encoding="utf-8")
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--archives", str(bare),
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
        )
        self.assertEqual(run.rc, 1)
        self.assertIn("has no SHA256SUMS", run.err)

    # ----------------------------------------------------- the prerequisites
    def test_an_unpublished_git_surface_names_the_repo_that_must_exist(self):
        """How a human learns the repository has to be created.

        The gap used to live only in `infra`'s `git_backed_surfaces` terraform
        output, which renders under `tofu output` -- needing credentials that
        root will not have until it is applied. So it is stated on every run,
        in the release log, and written into the staged tree so it travels
        with the artifact.
        """
        repo_root = self.work / "repo"
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "scoop",
            "--repo-root", str(repo_root),
            "--target", "none",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertIn("PREREQUISITE:", run.err)
        self.assertIn("metacraft-labs/scoop-reprobuild", run.err)
        self.assertIn("DOES NOT EXIST YET", run.err)
        # The machine-readable line release.yml turns into a ::warning::.
        self.assertIn("REPRO_PUBLISH_PREREQUISITE", run.out)
        note = repo_root / "scoop" / "PUBLISH-THIS-SURFACE.md"
        self.assertTrue(note.is_file(), "the staged tree carries no note")
        self.assertIn("--target-scoop git:", note.read_text(encoding="utf-8"))

    def test_release_yml_turns_the_prerequisite_into_a_warning(self):
        """Wiring, asserted at the call site. A notice nothing surfaces is a
        notice in a log file nobody opens."""
        text = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("REPRO_PUBLISH_PREREQUISITE", text)
        self.assertIn("--archives staging", text)
        for surface in ("DEB", "RPM", "ARCH", "DOWNLOADS", "KEYS"):
            self.assertIn(f"REPRO_PUBLISH_TARGET_{surface}", text)

    # --------------------------------------------------------------- homebrew
    def test_a_homebrew_formula_is_generated_with_a_real_digest(self):
        import hashlib

        tarball = self.packages / f"reprobuild-{VERSION}-darwin-aarch64.tar.gz"
        digest = hashlib.sha256(tarball.read_bytes()).hexdigest()
        repo_root = self.work / "repo"
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "homebrew",
            "--repo-root", str(repo_root),
            "--target", "none",
            "--scoop-downloads-base", "https://downloads.example",
        )
        self.assertEqual(run.rc, 0, run.err)
        formula = repo_root / "homebrew" / "Formula" / "reprobuild.rb"
        self.assertTrue(formula.is_file(), "no formula generated")
        body = formula.read_text(encoding="utf-8")
        self.assertIn(f'sha256 "{digest}"', body)
        self.assertIn(f"https://downloads.example/v{VERSION}/", body)
        self.assertIn("metacraft-labs/homebrew-reprobuild", run.err)

    def test_homebrew_asked_for_explicitly_fails_when_it_can_publish_nothing(self):
        """Under `--ecosystem all` a release with no macOS archive is a real
        and supported shape, so it skips. Asked for by name, publishing nothing
        is the wrong answer."""
        only_windows = self.work / "win-only"
        only_windows.mkdir()
        shutil.copy(
            self.packages / f"reprobuild-{VERSION}-windows-x86_64.zip", only_windows
        )
        run = self.publish(
            "--version", VERSION,
            "--packages", str(only_windows),
            "--ecosystem", "homebrew",
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
        )
        self.assertEqual(run.rc, 1)
        self.assertIn("cannot write a Homebrew formula", run.err)

    # ------------------------------------------------------------ git publish
    def test_a_git_target_clones_commits_and_pushes(self):
        """The publisher's half of the git-backed channels, end to end.

        Against a real local bare repository, because the assertion that
        matters is that a CLIENT could clone what was pushed -- not that a
        command was spelled correctly.
        """
        git = shutil.which("git")
        self.assertIsNotNone(git, "git is required to publish a git-backed surface")
        remote = self.work / "scoop-remote.git"
        subprocess.run([git, "init", "-q", "--bare", str(remote)], check=True)
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "scoop",
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
            "--target-scoop", f"git:{remote.as_posix()}",
            "--scoop-downloads-base", "http://localhost:9/downloads",
        )
        self.assertEqual(run.rc, 0, run.err)
        log = subprocess.run(
            [git, "--git-dir", str(remote), "log", "--oneline"],
            capture_output=True, text=True, check=True,
        ).stdout
        self.assertIn(f"reprobuild {VERSION}", log)
        tree = subprocess.run(
            [git, "--git-dir", str(remote), "ls-tree", "-r", "--name-only", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout
        self.assertIn("bucket/reprobuild.json", tree)
        # The prerequisite note is a message to a human about an unpublished
        # tree; pushing it into a published bucket would be nonsense.
        self._assert_absent(
            "PUBLISH-THIS-SURFACE.md", tree, "bucket/reprobuild.json"
        )


if __name__ == "__main__":
    unittest.main()
