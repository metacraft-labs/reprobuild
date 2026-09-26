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

`$REPRO_PUBLISH_SCRIPT` exists for one purpose: aiming these same assertions at
an OLDER copy of the publisher, to show that each one fails on the shape it was
written for. A check that has never been observed to fail is not evidence. It
defaults to the script in this checkout and nothing in the suite sets it.

WHAT IS STUBBED, AND WHY

Two cases need `--ecosystem all`, because that is the only selection under
which `publish_homebrew` can reach its skip branch -- asked for by name it
fails instead, deliberately. `--ecosystem all` also publishes deb/rpm/arch,
which calls M2's three signing scripts, which need dpkg-scanpackages,
createrepo_c, repo-add and a real gpg key. Those three scripts are stubbed via
`$REPRO_SIGN_DIR` (a hook the publisher already exposes) and NOTHING ELSE is:
the surface routing, the skip, the announcements, the tally and the uploads are
all the real code. Signing has its own tests; what is under test here is what
the publisher does around it, and a host that cannot run createrepo_c must
still be able to prove that a skipped surface still announces.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PUBLISH = Path(
    os.environ.get(
        "REPRO_PUBLISH_SCRIPT",
        str(REPO_ROOT / "scripts" / "release" / "repro-publish-repos.sh"),
    )
)
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

    def publish(self, *args: str, env: dict | None = None) -> Run:
        run_env = None
        if env is not None:
            run_env = dict(os.environ)
            run_env.update(env)
        proc = subprocess.run(
            [self.sh, str(PUBLISH), *args],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            env=run_env,
        )
        return Run(proc.returncode, proc.stdout, proc.stderr)

    def _assert_absent(self, needle: str, haystack: str, anchor: str):
        """`needle` is not in `haystack`, and `haystack` is really the stream.

        A bare "not in" over a stream that happens to be empty is the classic
        vacuous pass, so the caller names an `anchor` that MUST be present.
        """
        self.assertIn(anchor, haystack, "the stream under test is not the stream")
        self.assertNotIn(needle, haystack)

    def _count(self, needle: str, haystack: str) -> int:
        """Occurrences, not presence. A control that asserts "at least one"
        cannot tell one announcement from four, and the defect these cases
        were written against was a count of zero where four were claimed."""
        return haystack.count(needle)

    # ------------------------------------------------------- `--ecosystem all`
    def _sign_stubs(self) -> Path:
        """M2's three signing scripts, stubbed. See WHAT IS STUBBED above.

        They produce exactly the artifacts the publisher ASSERTS ON after
        calling them -- a Packages index carrying the release's `Version:`
        stanza, a signed repomd.xml -- so the publisher's own post-conditions
        still run for real against them.
        """
        d = self.work / "sign-stubs"
        d.mkdir(exist_ok=True)
        (d / "repro-sign-apt-repo.sh").write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "root=''; suite=stable; component=main; arch=amd64\n"
            "while [ $# -gt 0 ]; do\n"
            "  case \"$1\" in\n"
            "    --root) root=\"$2\"; shift 2 ;;\n"
            "    --suite) suite=\"$2\"; shift 2 ;;\n"
            "    --component) component=\"$2\"; shift 2 ;;\n"
            "    --arch) arch=\"$2\"; shift 2 ;;\n"
            "    *) shift ;;\n"
            "  esac\n"
            "done\n"
            'd="$root/dists/$suite/$component/binary-$arch"\n'
            'mkdir -p "$d"\n'
            ': > "$d/Packages"\n'
            'for f in "$root/pool/$component"/*.deb; do\n'
            '  [ -f "$f" ] || continue\n'
            "  printf 'Package: reprobuild\\nVersion: %s\\nFilename: pool/%s/%s\\n\\n'"
            f' "{VERSION}" "$component" "$(basename "$f")" >> "$d/Packages"\n'
            "done\n",
            encoding="utf-8",
        )
        (d / "repro-sign-rpm-repo.sh").write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "root=''\n"
            "while [ $# -gt 0 ]; do\n"
            '  case "$1" in --root) root="$2"; shift 2 ;; *) shift ;; esac\n'
            "done\n"
            'mkdir -p "$root/repodata"\n'
            "printf '<repomd/>\\n' > \"$root/repodata/repomd.xml\"\n"
            "printf 'signature\\n' > \"$root/repodata/repomd.xml.asc\"\n"
            f"printf 'reprobuild {VERSION}\\n' > \"$root/repodata/primary.xml\"\n",
            encoding="utf-8",
        )
        (d / "repro-sign-pacman-repo.sh").write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "root=''; db=reprobuild\n"
            "while [ $# -gt 0 ]; do\n"
            '  case "$1" in\n'
            '    --root) root="$2"; shift 2 ;;\n'
            '    --db) db="$2"; shift 2 ;;\n'
            "    *) shift ;;\n"
            "  esac\n"
            "done\n"
            'printf \'db\\n\' > "$root/$db.db.tar.gz"\n',
            encoding="utf-8",
        )
        return d

    def _all_ecosystem_packages(self, *, with_macos: bool) -> Path:
        """One artifact of every kind `--ecosystem all` looks for."""
        d = self.work / ("pkgs-all-macos" if with_macos else "pkgs-all-no-macos")
        d.mkdir()
        (d / f"reprobuild_{VERSION}_amd64.deb").write_text("deb\n", encoding="utf-8")
        (d / f"reprobuild-{VERSION}.x86_64.rpm").write_text("rpm\n", encoding="utf-8")
        (d / f"reprobuild-{VERSION}-x86_64.pkg.tar.zst").write_text(
            "pkg\n", encoding="utf-8"
        )
        (d / f"reprobuild-{VERSION}-windows-x86_64.zip").write_text(
            "zip\n", encoding="utf-8"
        )
        if with_macos:
            (d / f"reprobuild-{VERSION}-darwin-aarch64.tar.gz").write_text(
                "macos\n", encoding="utf-8"
            )
        return d

    def publish_all(self, *args: str) -> Run:
        """`--ecosystem all` with the three signing scripts stubbed."""
        return self.publish(
            "--version", VERSION,
            "--key", "TESTKEY",
            "--ecosystem", "all",
            *args,
            env={
                "REPRO_SIGN_DIR": str(self._sign_stubs()),
                "GNUPGHOME": str(self.work / "gnupg"),
            },
        )

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
        """The DERIVED SPEC for each object-store surface, as it is logged.

        This pins the spec string and nothing else. What a spec string is
        worth depends on the command it becomes, so
        `test_a_generic_r2_target_issues_the_same_rclone_argv` and its `aws`
        twin below compare the actual argv under stubbed uploaders; the
        docstring here used to claim "byte for byte", which is what those two
        measure and this one does not.
        """
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
        # The machine-readable line a caller can turn into a warning.
        self.assertIn("REPRO_PUBLISH_PREREQUISITE", run.out)
        note = repo_root / "scoop" / "PUBLISH-THIS-SURFACE.md"
        self.assertTrue(note.is_file(), "the staged tree carries no note")
        self.assertIn("--target-scoop git:", note.read_text(encoding="utf-8"))

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


    # --------------------------------------------- the skip that went silent
    def test_a_skipped_homebrew_still_announces_the_missing_tap(self):
        """The skip must not take the announcement with it.

        `upload_tree` is the ONLY caller of
        `announce_git_surface_prerequisite`, and the no-macOS-archive skip
        returned before it. That branch fires on every release shipped so far
        -- v0.1.2 and v0.1.3 both carried no macOS archive -- so homebrew
        emitted no `PREREQUISITE:` line, no marker, and therefore no
        `::warning::` on precisely the runs where the announcement was the
        only output the surface had.

        Counts, not presence: the defect was a count of ZERO against a
        four-line block, and "at least one" cannot see that.
        """
        repo_root = self.work / "repo"
        run = self.publish_all(
            "--packages", str(self._all_ecosystem_packages(with_macos=False)),
            "--repo-root", str(repo_root),
            "--target", "none",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertEqual(
            self._count("PREREQUISITE:   needs https://github.com/metacraft-labs/homebrew-reprobuild", run.err),
            1,
        )
        self.assertEqual(self._count("--target-homebrew git:", run.err), 1)
        self.assertEqual(
            self._count("REPRO_PUBLISH_PREREQUISITE\thomebrew\t", run.out), 1
        )
        # The staged note travels with the artifact even on a skip.
        note = repo_root / "homebrew" / "PUBLISH-THIS-SURFACE.md"
        self.assertTrue(note.is_file(), f"no note staged\n{run.err}")

    def test_a_skip_and_a_missing_repository_are_two_different_announcements(self):
        """Different facts, different owners, different remedies.

        "this release carries no macOS archive" is fixed by the release;
        "metacraft-labs/homebrew-reprobuild does not exist" is fixed once, by
        somebody with organisation rights. A release can have both -- every
        release so far did -- so both are emitted, under separate markers, and
        neither is the other's text reused.
        """
        run = self.publish_all(
            "--packages", str(self._all_ecosystem_packages(with_macos=False)),
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertEqual(self._count("REPRO_PUBLISH_SKIPPED\thomebrew\t", run.out), 1)
        self.assertEqual(
            self._count("REPRO_PUBLISH_PREREQUISITE\thomebrew\t", run.out), 1
        )
        skipped = [
            line for line in run.out.splitlines()
            if line.startswith("REPRO_PUBLISH_SKIPPED\thomebrew\t")
        ]
        self.assertIn("no macOS archive", skipped[0])
        # And the two texts are not the same text: the skip line says nothing
        # about a repository, which is what makes it distinguishable at all.
        self._assert_absent(
            "does not exist yet", skipped[0], "no macOS archive"
        )

    def test_a_published_homebrew_emits_no_skip_marker(self):
        """The control that keeps the two cases above from being unfalsifiable:
        with a macOS archive present, the skip markers are absent from a stream
        that is demonstrably the same stream."""
        run = self.publish_all(
            "--packages", str(self._all_ecosystem_packages(with_macos=True)),
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
            "--scoop-downloads-base", "https://downloads.example",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertEqual(self._count("REPRO_PUBLISH_SKIPPED\thomebrew\t", run.out), 0)
        self._assert_absent(
            "REPRO_PUBLISH_SKIPPED\thomebrew",
            run.out,
            "REPRO_PUBLISH_PREREQUISITE\thomebrew",
        )
        self.assertIn("homebrew formula: version=", run.err)

    # ------------------------------------------- the four names, not the one
    def test_downloads_refuses_a_manifest_naming_an_asset_it_does_not_publish(self):
        """`repro-install.sh` fetches `<asset>` by the name SHA256SUMS gives.

        All four fetches in `install_tarball` are fail-closed -- its `fetch`
        helper dies on a non-2xx and again on an empty body -- so a manifest
        published without the assets it names is a broken install, not a
        partial one, and it breaks in the user's hands minutes after the
        pipeline reported green.
        """
        half = self.work / "half"
        half.mkdir()
        present = f"reprobuild-{VERSION}-linux-x86_64.tar.gz"
        missing = f"reprobuild-{VERSION}-darwin-aarch64.tar.gz"
        (half / present).write_text("payload\n", encoding="utf-8")
        (half / "SHA256SUMS").write_text(
            f"aa  {present}\nbb  {missing}\n", encoding="utf-8"
        )
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--archives", str(half),
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
        )
        self.assertEqual(run.rc, 1, run.err)
        self.assertIn("names asset(s) that are not being published", run.err)
        self.assertIn(missing, run.err)
        # Not a blanket refusal: the asset that IS there is not reported.
        self.assertEqual(
            self._count(f"published: {present}", run.err), 0
        )

    def test_downloads_accepts_a_manifest_whose_assets_are_all_present(self):
        """The falsifier for the case above: the same check passes when the
        tree carries what the manifest names, so the refusal is about the
        missing asset and not about having a manifest at all."""
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--archives", str(self.archives),
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
        )
        self.assertEqual(run.rc, 0, run.err)
        self._assert_absent(
            "names asset(s) that are not being published",
            run.err,
            "downloads: staged",
        )

    def test_a_missing_manifest_signature_says_installs_fail_not_degrade(self):
        """There is no same-origin fallback, and the message used to promise one.

        `install_tarball` fetches SHA256SUMS.asc unconditionally, dies on a
        404, and runs M2's verifier before unpacking with no rescue branch.
        "Installs fall back to same-origin integrity only" described a code
        path that does not exist -- it told the operator the release was
        degraded when it was broken.
        """
        unsigned = self.work / "unsigned"
        unsigned.mkdir()
        asset = f"reprobuild-{VERSION}-linux-x86_64.tar.gz"
        (unsigned / asset).write_text("payload\n", encoding="utf-8")
        (unsigned / "SHA256SUMS").write_text(f"aa  {asset}\n", encoding="utf-8")
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--archives", str(unsigned),
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertIn("no SHA256SUMS.asc", run.err)
        self.assertIn("will FAIL, not", run.err)
        self._assert_absent("same-origin integrity only", run.err, "will FAIL, not")
        # The per-asset signature is fetched by name too, and was never checked.
        self.assertIn("no detached signature for:", run.err)
        self.assertIn(asset, run.err)

    # --------------------------------------------- one version segment, once
    def test_the_downloads_base_is_a_root_and_the_version_is_appended_once(self):
        """The URL a client actually requests, proved against both readers.

        `repro-install.sh --method tarball` fetches
        `$REPRO_DOWNLOADS_URL/v<version>/<asset>`, and a GitHub release asset
        lives at `.../releases/download/<tag>/<asset>` where `<tag>` is
        `v<version>`. Passing the ROOT satisfies both: the one appended
        `v<version>` IS the tag.
        """
        repo_root = self.work / "repo"
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "scoop",
            "--repo-root", str(repo_root),
            "--target", "none",
            "--scoop-downloads-base",
            "https://github.com/metacraft-labs/reprobuild/releases/download",
        )
        self.assertEqual(run.rc, 0, run.err)
        manifest = (repo_root / "scoop" / "bucket" / "reprobuild.json").read_text(
            encoding="utf-8"
        )
        expected = (
            "https://github.com/metacraft-labs/reprobuild/releases/download/"
            f"v{VERSION}/reprobuild-{VERSION}-windows-x86_64.zip"
        )
        self.assertIn(f'"url": "{expected}"', manifest)
        self.assertEqual(self._count(f"/v{VERSION}/v{VERSION}/", manifest), 0)

    def test_a_downloads_base_that_already_carries_the_version_is_refused(self):
        """The doubled segment, refused rather than published.

        release.yml passed `.../releases/download/${tag}` while the script
        appends `/v<version>/`, so every Scoop manifest ever generated carried
        `.../download/v0.1.3/v0.1.3/<asset>` -- a URL shaped like a URL that
        404s -- and the Homebrew formula inherited the same base the moment it
        started using it. Refusing here is what stops it regressing from the
        other end.
        """
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "scoop",
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
            "--scoop-downloads-base",
            f"https://github.com/metacraft-labs/reprobuild/releases/download/v{VERSION}",
        )
        self.assertEqual(run.rc, 1, run.err)
        self.assertIn("already ends in the version segment", run.err)
        self._assert_absent(
            "scoop manifest url:", run.err, "already ends in the version segment"
        )

    def test_the_homebrew_formula_uses_the_same_single_version_segment(self):
        """The channel that newly inherited the defect."""
        repo_root = self.work / "repo"
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "homebrew",
            "--repo-root", str(repo_root),
            "--target", "none",
            "--scoop-downloads-base", "https://downloads.reprobuild.com",
        )
        self.assertEqual(run.rc, 0, run.err)
        body = (repo_root / "homebrew" / "Formula" / "reprobuild.rb").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            f'url "https://downloads.reprobuild.com/v{VERSION}/'
            f'reprobuild-{VERSION}-darwin-aarch64.tar.gz"',
            body,
        )
        self.assertEqual(self._count(f"/v{VERSION}/v{VERSION}/", body), 0)

    # ------------------------------------------------------- a git identity
    def test_a_git_publish_commits_on_a_host_with_no_configured_identity(self):
        """A CI runner has no `user.name`/`user.email`.

        `git commit` there does not merely fail, it fails with an identity
        diagnostic -- "Please tell me who you are", "unable to auto-detect
        email address", "empty ident name (for <>) not allowed" -- which
        reached the operator as "publishing scoop to <url> failed", i.e. the
        wrong cause. The first real `git:` publish would have been diagnosed
        as a broken remote or a credentials problem, anything but the one-line
        configuration it actually is.

        The identity is stripped with `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM`
        rather than by hoping the host has none, so this case means the same
        thing on a developer machine as on a runner.
        """
        git = shutil.which("git")
        self.assertIsNotNone(git, "git is required to publish a git-backed surface")
        remote = self.work / "scoop-remote.git"
        subprocess.run([git, "init", "-q", "--bare", str(remote)], check=True)
        empty = self.work / "no-identity-home"
        empty.mkdir()
        bare_env = {
            "HOME": str(empty),
            "USERPROFILE": str(empty),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "EMAIL": "",
            "GIT_AUTHOR_EMAIL": "",
            "GIT_COMMITTER_EMAIL": "",
            "GIT_AUTHOR_NAME": "",
            "GIT_COMMITTER_NAME": "",
        }
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "scoop",
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
            "--target-scoop", f"git:{remote.as_posix()}",
            "--scoop-downloads-base", "http://localhost:9/downloads",
            env=bare_env,
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertIn("no git identity is configured on this host", run.err)
        # The commit exists and carries the identity that was announced, so
        # the publish is attributed rather than merely unblocked.
        author = subprocess.run(
            [git, "--git-dir", str(remote), "log", "-1", "--format=%an <%ae>"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        self.assertEqual(author, "reprobuild release automation <releases@reprobuild.com>")

    def test_a_configured_identity_is_preferred_over_the_bot(self):
        """The falsifier: the fix is a fallback, not an override. A human
        publishing by hand must still be attributed to themselves."""
        git = shutil.which("git")
        self.assertIsNotNone(git, "git is required to publish a git-backed surface")
        remote = self.work / "scoop-remote-2.git"
        subprocess.run([git, "init", "-q", "--bare", str(remote)], check=True)
        home = self.work / "configured-home"
        home.mkdir()
        gitconfig = home / "gitconfig"
        gitconfig.write_text(
            "[user]\n\tname = A Human\n\temail = human@example.invalid\n",
            encoding="utf-8",
        )
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "scoop",
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
            "--target-scoop", f"git:{remote.as_posix()}",
            "--scoop-downloads-base", "http://localhost:9/downloads",
            env={
                "HOME": str(home),
                "USERPROFILE": str(home),
                "GIT_CONFIG_GLOBAL": str(gitconfig),
                "GIT_CONFIG_SYSTEM": os.devnull,
                "GIT_CONFIG_NOSYSTEM": "1",
            },
        )
        self.assertEqual(run.rc, 0, run.err)
        self._assert_absent(
            "no git identity is configured", run.err, "publishing scoop -> "
        )
        author = subprocess.run(
            [git, "--git-dir", str(remote), "log", "-1", "--format=%an <%ae>"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        self.assertEqual(author, "A Human <human@example.invalid>")

    # ------------------------------------------------------------- the tally
    def test_the_tally_counts_only_the_surfaces_that_published(self):
        """`published N ecosystem(s)` counted surfaces that moved no bytes.

        Under `--target local:` with no macOS archive, five of the six
        selected surfaces publish and homebrew does not. The old line said
        six. The no-op is not merely uncounted: it is printed, with its
        reason, because a channel that published nothing is the thing an
        operator most needs to see.
        """
        www = self.work / "www"
        run = self.publish_all(
            "--packages", str(self._all_ecosystem_packages(with_macos=False)),
            "--archives", str(self.archives),
            "--repo-root", str(self.work / "repo"),
            "--target", f"local:{www.as_posix()}",
            "--scoop-downloads-base", "https://downloads.example",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertEqual(
            self._count(f"published 5 of 6 selected ecosystem(s) for version {VERSION}", run.err),
            1,
        )
        self.assertEqual(self._count("1 selected ecosystem(s) published nothing:", run.err), 1)
        self.assertIn("homebrew: no macOS archive in this release", run.err)
        self._assert_absent(
            f"published 6 ecosystem(s) for version {VERSION}",
            run.err,
            "published 5 of 6 selected",
        )

    def test_every_surface_publishing_is_counted_as_every_surface(self):
        """The falsifier for the tally: with a macOS archive present the same
        run reports six of six, so the count tracks the outcome rather than
        being a smaller constant."""
        www = self.work / "www"
        run = self.publish_all(
            "--packages", str(self._all_ecosystem_packages(with_macos=True)),
            "--archives", str(self.archives),
            "--repo-root", str(self.work / "repo"),
            "--target", f"local:{www.as_posix()}",
            "--scoop-downloads-base", "https://downloads.example",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertEqual(
            self._count("published 6 of 6 selected ecosystem(s)", run.err), 1
        )
        self._assert_absent(
            "published nothing:", run.err, "published 6 of 6 selected"
        )

    def test_a_run_that_publishes_nothing_is_still_not_an_error(self):
        """The guard the tally must not have broken. `--ecosystem downloads`
        with no `--archives` legitimately publishes nothing and exits 0; only
        selecting NO surface is an error."""
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--repo-root", str(self.work / "repo"),
            "--target", "none",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertIn("published 0 of 1 selected ecosystem(s)", run.err)
        self.assertIn("downloads: no --archives given", run.err)

    # ------------------------------------------------- the pointless fetch
    def test_fetch_existing_does_not_pull_past_releases_into_downloads(self):
        """`downloads` is versioned; nothing rewrites a previous release.

        Every key it writes is under `v<version>/`, and neither uploader
        passes a delete flag (`aws s3 sync` without `--delete`, `rclone copy`
        rather than `sync`). So fetching the existing tree downloads every
        archive of every past release -- the largest objects this pipeline
        publishes, growing without bound -- to write none of them back.
        """
        www = self.work / "www"
        old = www / "downloads" / "v1.2.3"
        old.mkdir(parents=True)
        (old / "reprobuild-1.2.3-linux-x86_64.tar.gz").write_text(
            "an old release\n", encoding="utf-8"
        )
        repo_root = self.work / "repo"
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--archives", str(self.archives),
            "--repo-root", str(repo_root),
            "--target", f"local:{www.as_posix()}",
            "--fetch-existing",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertIn("downloads: --fetch-existing ignored", run.err)
        self._assert_absent(
            "fetching existing downloads tree",
            run.err,
            "downloads: --fetch-existing ignored",
        )
        # Not fetched...
        self.assertFalse(
            (repo_root / "downloads" / "v1.2.3").exists(),
            "the past release was pulled into the staging tree for nothing",
        )
        # ...and, the reason this is safe, still published.
        self.assertTrue(
            (old / "reprobuild-1.2.3-linux-x86_64.tar.gz").is_file(),
            "the past release was removed by a publish that did not fetch it",
        )
        self.assertTrue(
            (www / "downloads" / f"v{VERSION}" / "SHA256SUMS").is_file(),
            f"this version was not published\n{run.err}",
        )

    def test_fetch_existing_still_pulls_the_stateful_apt_pool(self):
        """The falsifier: `--fetch-existing` is not a no-op everywhere. `deb`
        regenerates ONE index over a pool that must still contain every older
        package, so that surface must still fetch."""
        www = self.work / "www"
        pool = www / "deb" / "pool" / "main"
        pool.mkdir(parents=True)
        (pool / "reprobuild_1.2.3_amd64.deb").write_text("old\n", encoding="utf-8")
        repo_root = self.work / "repo"
        run = self.publish_all(
            "--packages", str(self._all_ecosystem_packages(with_macos=True)),
            "--archives", str(self.archives),
            "--repo-root", str(repo_root),
            "--target", f"local:{www.as_posix()}",
            "--scoop-downloads-base", "https://downloads.example",
            "--fetch-existing",
        )
        self.assertEqual(run.rc, 0, run.err)
        self.assertIn("fetching existing deb tree", run.err)
        self.assertTrue(
            (repo_root / "deb" / "pool" / "main" / "reprobuild_1.2.3_amd64.deb").is_file(),
            "the existing apt pool was not fetched; publishing would delete it",
        )

    # ------------------------------------------------------ argv, not a spec
    def _uploader_stub(self, name: str, log: Path) -> Path:
        """A recorder standing in for `aws`/`rclone`.

        The only mock in this file's upload paths, and it exists because the
        claim under test is about the ARGV the publisher builds -- which is
        the thing a real uploader would consume and the thing a spec string
        only implies. It records and succeeds; it performs no transfer.
        """
        binroot = self.work / f"stub-{name}"
        binroot.mkdir(exist_ok=True)
        stub = binroot / name
        stub.write_text(
            "#!/bin/sh\n"
            'for a in "$@"; do printf \'%s\\n\' "$a" >> "$REPRO_STUB_ARGV_LOG"; done\n'
            "printf -- '--\\n' >> \"$REPRO_STUB_ARGV_LOG\"\n"
            "exit 0\n",
            encoding="utf-8",
        )
        stub.chmod(0o755)
        return binroot

    def _path_tail(self, path_str: str, n: int = 3) -> tuple:
        """The last `n` segments of a path, separator-agnostic.

        The publisher normalises `--repo-root` through `cd`+`pwd`, so the
        source directory in the recorded argv is spelled by the host's `sh`
        (`/tmp/x/repo/downloads`) while Python spells the same directory
        `C:\\Users\\...\\Temp\\x\\repo\\downloads`. The claim is which
        directory was handed to the uploader, not how the shell writes it.
        """
        return tuple(path_str.replace("\\", "/").rstrip("/").split("/")[-n:])

    def _recorded_argv(self, log: Path) -> list[list[str]]:
        if not log.is_file():
            return []
        calls: list[list[str]] = []
        current: list[str] = []
        for line in log.read_text(encoding="utf-8").splitlines():
            if line == "--":
                calls.append(current)
                current = []
            else:
                current.append(line)
        return calls

    def test_a_generic_r2_target_issues_the_same_rclone_argv(self):
        """"Byte for byte" measured where it means something.

        The derivation rule is only as good as the command it produces, so
        this compares the WHOLE argv `rclone` is invoked with -- verb, source
        and destination -- against the invocation the pre-per-surface script
        made for a generic `--target`. A spec string can be right while the
        call built from it is not.
        """
        log = self.work / "rclone-argv.log"
        binroot = self._uploader_stub("rclone", log)
        repo_root = self.work / "repo"
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--archives", str(self.archives),
            "--repo-root", str(repo_root),
            "--target", "r2:bucket/pfx",
            env={
                "PATH": f"{binroot}{os.pathsep}{os.environ['PATH']}",
                "REPRO_STUB_ARGV_LOG": str(log),
            },
        )
        self.assertEqual(run.rc, 0, run.err)
        calls = self._recorded_argv(log)
        self.assertEqual(len(calls), 1, f"expected one rclone invocation: {calls}")
        argv = calls[0]
        self.assertEqual(len(argv), 3, argv)
        self.assertEqual(argv[0], "copy")
        self.assertEqual(
            self._path_tail(argv[1]), self._path_tail(str(repo_root / "downloads"))
        )
        self.assertEqual(argv[2], "r2:bucket/pfx/downloads")

    def test_a_generic_s3_target_issues_the_same_aws_argv(self):
        """The same claim for the `s3://` scheme, where the derived spec is
        the destination itself rather than a `r2:` remote."""
        log = self.work / "aws-argv.log"
        binroot = self._uploader_stub("aws", log)
        repo_root = self.work / "repo"
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--archives", str(self.archives),
            "--repo-root", str(repo_root),
            "--target", "s3://bucket/pfx",
            env={
                "PATH": f"{binroot}{os.pathsep}{os.environ['PATH']}",
                "REPRO_STUB_ARGV_LOG": str(log),
            },
        )
        self.assertEqual(run.rc, 0, run.err)
        calls = self._recorded_argv(log)
        self.assertEqual(len(calls), 1, f"expected one aws invocation: {calls}")
        argv = calls[0]
        self.assertEqual(len(argv), 4, argv)
        self.assertEqual(argv[0:2], ["s3", "sync"])
        self.assertEqual(
            self._path_tail(argv[2]), self._path_tail(str(repo_root / "downloads"))
        )
        self.assertEqual(argv[3], "s3://bucket/pfx/downloads")

    def test_the_upload_argv_never_carries_a_delete_flag(self):
        """What the argv comparison buys that a spec string cannot say at all.

        `--delete` would remove older pool packages the moment a publish ran
        from a tree that had not fetched them, breaking every pinned install.
        Its absence is a property of the ARGV, and nothing about the derived
        destination string expresses it.
        """
        log = self.work / "rclone-argv-2.log"
        binroot = self._uploader_stub("rclone", log)
        run = self.publish(
            "--version", VERSION,
            "--packages", str(self.packages),
            "--ecosystem", "downloads",
            "--archives", str(self.archives),
            "--repo-root", str(self.work / "repo"),
            "--target", "r2:bucket/pfx",
            env={
                "PATH": f"{binroot}{os.pathsep}{os.environ['PATH']}",
                "REPRO_STUB_ARGV_LOG": str(log),
            },
        )
        self.assertEqual(run.rc, 0, run.err)
        calls = self._recorded_argv(log)
        self.assertEqual(len(calls), 1)
        self.assertNotIn("--delete", calls[0])
        self.assertNotIn("sync", calls[0])


if __name__ == "__main__":
    unittest.main()
