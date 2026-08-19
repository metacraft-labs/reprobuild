#!/usr/bin/env python3
"""The package-root anchor must keep two same-named test files distinguishable.

WHAT THIS PROTECTS
------------------
Every reprobuild test binary answers ``--list-json`` with a catalog whose
``bodyHash`` field identifies a test body. The incremental runner deselects a
case when its ``bodyHash`` is unchanged, so a hash that stops discriminating
does not fail anything — it silently runs fewer tests.

``check`` / ``require`` / ``expect`` / ``assert`` plant their source location
into the expanded body as a string literal, and the compiler's
``sighashes.hashBodyTree`` hashes string literals verbatim. The location is
therefore *inside* the hash, and how it renders decides two properties at once:

* an ABSOLUTE path makes the hash track the checkout directory, so two hosts
  building the same commit disagree about every case; and
* a BARE BASENAME makes two same-named test files in different directories
  hash identically, so one of them can mask the other.

The Nim fork renders that literal with ``ipCanonical``, which is anchored on
the PACKAGE ROOT. ``canonicalImportAux`` finds that root by trying, in order,
the stdlib directories, the ``--path:`` search roots, and the nearest enclosing
``.nimble`` file — and if none of them matches it falls back to ``projectPath``,
which is the directory of the main module. Every reprobuild test is compiled as
its own main module, so that fallback renders a bare basename.

That is the failure mode this file exists to catch, and it is invisible from
the outside: hashes stay stable, nothing errors, and the suite keeps passing
while ``tests/a/t.nim`` and ``tests/b/t.nim`` become the same test.

reprobuild supplies the anchor twice over, and either one alone is sufficient:

* ``reprobuild.nimble`` at the repository root, and
* ``switch("path", ".")`` in the root ``config.nims``.

MEASUREMENT, NOT ASSERTION
--------------------------
Two byte-identical fixtures with the same basename live in sibling directories
under ``tests/fixtures/package-anchor/``. Compiled inside this repository they
must hash DIFFERENTLY; the same two files copied outside the repository — where
no ``.nimble`` and no ``--path:`` root covers them — must hash IDENTICALLY.
The second half is the built-in mutation control: without it, an assertion that
two hashes differ could be satisfied by any incidental difference, and would go
on passing after the anchor was removed.

NO MOCKS
--------
Real ``nim`` invocations against real directories, with the same argv shape
``buildNimUnittest`` emits for every suite test, and the real ``--list-json``
catalog read back out of the produced binaries. The property under test is
precisely what the compiler writes into the tree, so there is nothing here that
could be stubbed without deleting the measurement.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = ROOT / "tests" / "fixtures" / "package-anchor"
FIXTURE_LEAVES = ("a", "b")
FIXTURE_NAME = "t_anchor_probe.nim"

# The two cases the fixture declares that this guard reasons about.
LOCATION_BEARING = "package anchor probe::location-bearing body"
NO_LOCATION = "package anchor probe::no location literal"
FAILING = "package anchor probe::failing check"


def nim_binary() -> str:
    found = shutil.which("nim")
    if found is None:
        raise AssertionError(
            "no `nim` on PATH. This guard measures what the compiler writes "
            "into the tree and cannot be skipped into a pass; run it inside "
            "the dev shell (`nix develop`), the way `just test` does."
        )
    return found


def compile_fixture(source: Path, workdir: Path, tag: str) -> Path:
    """Compile `source` as its own main module, `buildNimUnittest`'s argv shape.

    The flags mirror ``BuildNimUnittest.build``'s defaults (``--threads:on
    --hints:off --warnings:off --out:<binary> <source>``) so this measures the
    configuration the suite actually ships, not a convenient variation of it.
    """
    binary = workdir / ("anchor_probe_" + tag)
    command = [
        nim_binary(),
        "c",
        "--threads:on",
        "--hints:off",
        "--warnings:off",
        "--nimcache:" + str(workdir / ("nimcache_" + tag)),
        "--out:" + str(binary),
        str(source),
    ]
    completed = subprocess.run(
        command, cwd=str(ROOT), capture_output=True, text=True
    )
    assert completed.returncode == 0, (
        "fixture did not compile: "
        + " ".join(command)
        + "\n"
        + completed.stdout
        + completed.stderr
    )
    assert binary.is_file(), "compiler produced no binary at " + str(binary)
    return binary


def catalog(binary: Path) -> dict:
    """`name -> entry` from the binary's own `--list-json` protocol output."""
    completed = subprocess.run(
        [str(binary), "--list-json"], capture_output=True, text=True
    )
    assert completed.returncode == 0, completed.stdout + completed.stderr
    document = json.loads(completed.stdout)
    return {entry["name"]: entry for entry in document["tests"]}


class PackageRootAnchorTests(unittest.TestCase):
    maxDiff = None

    def test_fixtures_are_byte_identical_and_share_a_basename(self):
        """The premise of every other assertion in this file.

        If the two fixtures ever diverge, their bodies differ for an ordinary
        reason and the distinctness assertion below stops measuring the anchor
        while still passing.
        """
        contents = {
            leaf: (FIXTURE_DIR / leaf / FIXTURE_NAME).read_bytes()
            for leaf in FIXTURE_LEAVES
        }
        self.assertEqual(
            contents["a"],
            contents["b"],
            "tests/fixtures/package-anchor/{a,b}/"
            + FIXTURE_NAME
            + " must stay byte-identical; they are the same source in two "
            "directories, which is the whole experiment",
        )
        self.assertEqual(
            len({(FIXTURE_DIR / leaf / FIXTURE_NAME).name for leaf in FIXTURE_LEAVES}),
            1,
            "the two fixtures must share a basename",
        )

    def test_repository_declares_a_package_root_anchor_deliberately(self):
        """Both anchors are declared on purpose, not left to chance.

        This is the cheap, fast half of the guard: it names the two artefacts
        a future cleanup would have to delete, so deleting one is a decision
        rather than an accident. The expensive half below proves they work.
        """
        self.assertTrue(
            (ROOT / "reprobuild.nimble").is_file(),
            "reprobuild.nimble is one of the two package-root anchors that "
            "keep `check`/`assert` locations resolvable; removing it degrades "
            "every test binary's catalog to bare basenames without any error",
        )
        config_nims = (ROOT / "config.nims").read_text()
        self.assertIn(
            'switch("path", ".")',
            config_nims,
            'the root config.nims `switch("path", ".")` is the second '
            "package-root anchor; see the comment beside it",
        )

    def test_same_named_sources_in_different_directories_stay_distinct(self):
        """The measurement, with its own anchor-loss control.

        Inside the repository the two fixtures are covered by a package root,
        so their location-bearing bodies must hash differently. Copied outside
        it they are covered by nothing, so they must collide — which is what
        proves the first half is reading the anchor and not an artefact.
        """
        with tempfile.TemporaryDirectory(prefix="package-anchor-") as tmp:
            workdir = Path(tmp) / "build"
            workdir.mkdir()

            anchored = {
                leaf: catalog(
                    compile_fixture(
                        FIXTURE_DIR / leaf / FIXTURE_NAME, workdir, "in_" + leaf
                    )
                )
                for leaf in FIXTURE_LEAVES
            }

            # Sanity: the fixture registered what this test reasons about.
            for leaf, entries in anchored.items():
                for name in (LOCATION_BEARING, NO_LOCATION, FAILING):
                    self.assertIn(name, entries, "fixture " + leaf)
                    self.assertTrue(entries[name]["bodyHash"])

            # (1) CONTROL: a body with no location literal carries nothing that
            #     could differ, so it MUST be identical in both directories. If
            #     this fails, the fixtures have drifted and (2) proves nothing.
            self.assertEqual(
                anchored["a"][NO_LOCATION]["bodyHash"],
                anchored["b"][NO_LOCATION]["bodyHash"],
                "a body with no location literal hashed differently in the two "
                "directories, so the fixtures are no longer the same source "
                "and the distinctness check below is meaningless",
            )

            # (2) THE PROPERTY: with a package root above them, two same-named
            #     files in different directories are distinguishable.
            self.assertNotEqual(
                anchored["a"][LOCATION_BEARING]["bodyHash"],
                anchored["b"][LOCATION_BEARING]["bodyHash"],
                "tests/fixtures/package-anchor/a/"
                + FIXTURE_NAME
                + " and .../b/"
                + FIXTURE_NAME
                + " now share a bodyHash. The package-root anchor has been "
                "lost, so every test location renders as a bare basename: "
                "hashes are still stable, nothing errors, and two same-named "
                "test files in different directories have become one. Restore "
                "reprobuild.nimble at the repo root or `switch(\"path\", "
                '".")` in config.nims.',
            )

            # (3) MUTATION CONTROL: the same two files, outside any package
            #     root, must collide. This is the removed-anchor state, so it
            #     demonstrates that (2) fails when the anchor goes away rather
            #     than passing for some incidental reason.
            unanchored_root = Path(tmp) / "no-package-root"
            for leaf in FIXTURE_LEAVES:
                leaf_dir = unanchored_root / "tests" / leaf
                leaf_dir.mkdir(parents=True)
                shutil.copyfile(
                    FIXTURE_DIR / leaf / FIXTURE_NAME, leaf_dir / FIXTURE_NAME
                )
            unanchored = {
                leaf: catalog(
                    compile_fixture(
                        unanchored_root / "tests" / leaf / FIXTURE_NAME,
                        workdir,
                        "out_" + leaf,
                    )
                )
                for leaf in FIXTURE_LEAVES
            }
            self.assertEqual(
                unanchored["a"][LOCATION_BEARING]["bodyHash"],
                unanchored["b"][LOCATION_BEARING]["bodyHash"],
                "the two fixtures were expected to COLLIDE outside any package "
                "root — that collision is what this guard exists to prevent "
                "inside the repository. They did not, so either the compiler "
                "now anchors on something else or this control has stopped "
                "reproducing the unanchored state, and the assertion above is "
                "no longer known to have teeth",
            )
            self.assertNotEqual(
                anchored["a"][LOCATION_BEARING]["bodyHash"],
                unanchored["a"][LOCATION_BEARING]["bodyHash"],
                "anchored and unanchored builds of the same file hashed the "
                "same, so the anchor is not reaching the hash at all",
            )

            # (4) The rendering a human reads keeps the directory too, and does
            #     not embed the checkout root.
            failure = subprocess.run(
                [str(workdir / "anchor_probe_in_a"), FAILING],
                capture_output=True,
                text=True,
            ).stdout
            expected = os.path.join(
                "tests", "fixtures", "package-anchor", "a", FIXTURE_NAME
            )
            self.assertIn(
                expected + "(",
                failure,
                "the failure message lost its directory, leaving a name that "
                "cannot be resolved back to a file:\n" + failure,
            )
            self.assertNotIn(
                str(ROOT),
                failure,
                "the failure message embeds the checkout root, so it is not "
                "reproducible across machines:\n" + failure,
            )

            # (5) The catalog's `file` field is NOT part of the guarantee
            #     above, and saying so here is deliberate. It is rendered by
            #     `unittest.protocolRelativeFile` against `projectPath` — the
            #     main module's own directory — so for a test compiled as its
            #     own main module it is always the bare basename, in both
            #     directories, anchor or no anchor. `bodyHash` is the only
            #     field that distinguishes them today. If this equality ever
            #     starts failing, `file` has become directory-bearing: that is
            #     an improvement, and the right response is to extend the
            #     distinctness assertion in (2) to cover `file` and delete this.
            self.assertEqual(
                anchored["a"][LOCATION_BEARING]["file"],
                anchored["b"][LOCATION_BEARING]["file"],
                "`file` has started carrying its directory — tighten (2) to "
                "assert on it as well, and remove this assertion",
            )
            self.assertEqual(anchored["a"][LOCATION_BEARING]["file"], FIXTURE_NAME)


if __name__ == "__main__":
    unittest.main()
