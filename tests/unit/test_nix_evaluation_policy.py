"""Keep the helper's local-source policy aligned with the Nim cache layers.

Both language implementations consume this same classification corpus,
``tests/fixtures/nix-evaluation-policy.json``. Each case is
``{"selector", "local", "workspaceEntries"?}``: the selector is classified
against a FRESH, otherwise empty workspace root holding exactly the listed
entries, each ``{"path", "kind"}`` relative to that root, where ``kind`` is
``dir``, ``file``, ``symlink`` (to an existing directory outside the
workspace) or ``dangling-symlink``. A case without entries is classified
against an empty workspace. The entries model the path Nix falls back to
when it rejects a selector it parsed as a URL (its URL parser rejects
``https://h:0/x#…``; Nix 2.34's fetcher also rejects ``github:o#…``): the
text before the first ``?`` or ``#``, read relative to the workspace, and,
for a selector containing ``/``, the whole selector, which ``nix build``
follows as a symlink before it parses a flake reference.

No Nix or process behavior is mocked; the workspaces are real directories.
"""
import errno
import json
import os
from pathlib import Path
import runpy
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def populate_workspace(root: Path, outside: Path, entries: list[dict]) -> None:
    """Create ``entries`` (the corpus's ``workspaceEntries``) under ``root``.

    ``outside`` is a directory beside the workspace that symlinks point at.
    """
    for entry in entries:
        path = root / entry["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        kind = entry["kind"]
        if kind == "dir":
            path.mkdir(parents=True, exist_ok=True)
        elif kind == "file":
            path.write_text("entry\n")
        elif kind == "symlink":
            target = outside / "target"
            target.mkdir(exist_ok=True)
            path.symlink_to(target, target_is_directory=True)
        elif kind == "dangling-symlink":
            path.symlink_to(outside / "absent")
        else:
            raise ValueError(f"unknown workspace entry kind: {kind!r}")


class NixEvaluationPolicy(unittest.TestCase):
    def setUp(self):
        helper = runpy.run_path(str(ROOT / "tools/reprobuild-nix-daemon/reprobuild-nix-daemon"))
        self.classify = helper["is_mutable_local_nix_selector"]

    def test_helper_matches_the_shared_classification_corpus(self):
        cases = json.loads((ROOT / "tests/fixtures/nix-evaluation-policy.json").read_text())
        with_entries = 0
        for case in cases:
            entries = case.get("workspaceEntries", [])
            if entries and os.name != "posix":
                # Entry names such as ``github:o`` cannot exist on Windows,
                # where the helper never serves.
                continue
            with_entries += bool(entries)
            with self.subTest(selector=case["selector"], entries=entries):
                with tempfile.TemporaryDirectory(prefix="rnp-") as directory:
                    root = Path(directory) / "workspace"
                    root.mkdir()
                    outside = Path(directory) / "outside"
                    outside.mkdir()
                    populate_workspace(root, outside, entries)
                    self.assertEqual(self.classify(case["selector"], root), case["local"])
        if os.name == "posix":
            self.assertGreater(with_entries, 0, "the corpus lost its filesystem half")

    @unittest.skipUnless(os.name == "posix", "POSIX path semantics")
    def test_an_entry_that_cannot_be_examined_is_local(self):
        # FAIL SAFE: only ENOENT / ENOTDIR prove that Nix's fallback path is
        # absent. A path that cannot be examined must not be cached.
        with tempfile.TemporaryDirectory(prefix="rnp-") as directory:
            root = Path(directory)
            # ENAMETOOLONG: one component longer than any filesystem allows.
            long_name = "github:" + "o" * 300
            with self.assertRaises(OSError) as raised:
                os.lstat(root / long_name)
            self.assertEqual(raised.exception.errno, errno.ENAMETOOLONG)
            self.assertTrue(self.classify(long_name + "#x", root))
            # Control: the same shape, short enough to be examined, is remote.
            self.assertFalse(self.classify("github:o#x", root))

            # EACCES: a parent directory without search permission. Root
            # bypasses permissions, so this half needs an ordinary user.
            # Every candidate of ``https://h:0/x#x`` (``https://h:0/x`` and
            # the whole selector) lies UNDER ``https:``, and ``https:`` itself
            # is not a candidate, so only the unexaminable entries can make
            # the answer local.
            if os.geteuid() != 0:
                selector = "https://h:0/x#x"
                locked = root / "https:"
                locked.mkdir()
                # Control: searchable and empty, every candidate is absent.
                self.assertFalse(self.classify(selector, root))
                locked.chmod(0)
                try:
                    with self.assertRaises(PermissionError):
                        os.lstat(locked / "h:0")
                    self.assertTrue(self.classify(selector, root))
                finally:
                    locked.chmod(0o700)


if __name__ == "__main__":
    unittest.main()
