#!/usr/bin/env python3
"""A pending source default of package.nix must mirror this tree's flake.lock.

Under test: ``scripts/check_package_nix_pending_sources.py``, from reprobuild-pm
issue
``2026-10-31-lock-update-does-not-move-the-package-default-or-the-ci-sibling-pin``.
package.nix's ``*Src`` defaults mirror the ``flake.lock`` of the commit its
``src`` names, except an input that commit's lock does not have yet (one added
after it): that default mirrors THIS tree's ``flake.lock`` until the next
release moves ``src``. ``repro lock update`` moved such an input
(``test-certificates-tools-src``) in both locks and left the default behind;
only ``nix flake check`` (``nixpkgs-package-src-sync``) would have said so, and
nothing runs it before a push. The script is the half of that check that
needs no evaluation, run by ``just lint``.

No mocks. The rule-by-rule cases build a real git repository whose one commit
is the ``src`` commit, with package.nix / nim-fork.nix / flake.lock files in
the real formats. The last cases run against the REAL committed files: the
tree passes, and the issue's situation rebuilt from them is refused.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))

# `just lint` runs this file from the pre-commit hook, and git exports
# GIT_INDEX_FILE to every hook (and GIT_DIR / GIT_WORK_TREE to a linked
# worktree's). Inherited, they point every `git -C <temp repo>` below -- this
# file's and the script's under test -- at the repository being committed to,
# so the fixture commits fail, or land in the wrong index. Scrubbed for the
# whole process, the way the suite's other git-fixture tests scrub them.
for _leaked in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
    os.environ.pop(_leaked, None)
from check_package_nix_pending_sources import (  # noqa: E402
    NIM_FORK_NIX, PACKAGE_NIX, TABLE, check, src_lock_text)

A1, A2 = 'a1' * 20, 'a2' * 20
B_OLD, B_NEW = 'b1' * 20, 'b2' * 20
X = 'c1' * 20
HB_OLD, HB_NEW = 'sha256-b-old=', 'sha256-b-new='


def git(root: Path, *args: str) -> str:
    return subprocess.run(['git', '-C', str(root), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def flake_lock(nodes: dict[str, dict]) -> str:
    """A flake.lock whose root inputs are ``nodes`` (input -> locked)."""
    doc = {'root': 'root', 'version': 7, 'nodes': {
        'root': {'inputs': {name: name for name in nodes}}}}
    for name, locked in nodes.items():
        doc['nodes'][name] = {'flake': False, 'locked': locked, 'original': {}}
    return json.dumps(doc, indent=2) + '\n'


def github(rev: str, nar_hash: str = '') -> dict:
    locked = {'owner': 'o', 'repo': 'r', 'rev': rev, 'type': 'github'}
    if nar_hash:
        locked['narHash'] = nar_hash
    return locked


def default(arg: str, rev: str, hash_: str) -> str:
    return (f'  {arg} ? fetchFromGitHub {{\n    owner = "o";\n    repo = "r";\n'
            f'    rev = "{rev}";\n    hash = "{hash_}";\n  }},\n')


class PendingSourceFixtures(unittest.TestCase):
    """aSrc is in the `src` commit's lock (not this check's); bSrc postdates it."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        git(self.root, 'init', '-q')
        git(self.root, 'config', 'user.email', 't@example.invalid')
        git(self.root, 'config', 'user.name', 'Tester')
        git(self.root, 'config', 'commit.gpgsign', 'false')
        (self.root / 'flake.lock').write_text(flake_lock({
            'a-src': github(A1, 'sha256-a1='), 'x-src': github(X, 'sha256-x=')}))
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-q', '-m', 'the src commit')
        self.src = git(self.root, 'rev-parse', 'HEAD')
        (self.root / TABLE).parent.mkdir(parents=True, exist_ok=True)
        (self.root / TABLE).write_text(json.dumps({
            'package.nix': {'aSrc': 'a-src', 'bSrc': 'b-src'},
            'nim-fork.nix': {'xSrc': 'x-src'}}))
        (self.root / NIM_FORK_NIX).parent.mkdir(parents=True, exist_ok=True)
        (self.root / NIM_FORK_NIX).write_text(
            '{\n  fetchFromGitHub,\n' + default('xSrc', X, 'sha256-x=') + '}:\n{ }\n')
        # This tree's lock: a-src moved (the `src` lock still governs it),
        # b-src added after the `src` commit and moved to B_NEW.
        (self.root / 'flake.lock').write_text(flake_lock({
            'a-src': github(A2, 'sha256-a2='), 'b-src': github(B_NEW, HB_NEW),
            'x-src': github(X, 'sha256-x=')}))

    def tearDown(self):
        self.temp.cleanup()

    def write_package(self, b_rev: str, b_hash: str, *, with_b: bool = True) -> None:
        text = ('{\n  fetchFromGitHub,\n' + default('aSrc', A1, 'sha256-a1=')
                + (default('bSrc', b_rev, b_hash) if with_b else '')
                + '}:\nlet\n  src = fetchFromGitHub {\n    owner = "metacraft-labs";\n'
                + f'    repo = "reprobuild";\n    rev = "{self.src}";\n'
                + '    hash = "sha256-src=";\n  };\nin\n{ }\n')
        (self.root / PACKAGE_NIX).write_text(text)

    def test_a_pending_default_left_behind_is_refused_naming_the_move(self):
        self.write_package(B_OLD, HB_OLD)
        errors, pending = check(self.root)
        self.assertEqual(pending, ['b-src'])
        self.assertEqual(len(errors), 1, errors)
        error = errors[0]
        self.assertIn(f'{PACKAGE_NIX}:', error)
        self.assertIn('`bSrc`', error)
        self.assertIn(B_OLD, error)
        self.assertIn(B_NEW, error)
        self.assertIn(HB_NEW, error)
        self.assertIn(self.src, error)
        # aSrc differs from this tree's lock too, but the `src` commit's lock
        # pins its input: that is `nixpkgs-package-src-sync`'s to judge.
        self.assertNotIn('aSrc', error)

    def test_a_pending_default_that_follows_the_tree_lock_passes(self):
        self.write_package(B_NEW, HB_NEW)
        self.assertEqual(check(self.root), ([], ['b-src']))

    def test_a_stale_hash_alone_is_refused(self):
        self.write_package(B_NEW, HB_OLD)
        errors, _ = check(self.root)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn(HB_OLD, errors[0])
        self.assertIn(HB_NEW, errors[0])

    def test_a_missing_default_is_an_error_not_a_pass(self):
        self.write_package(B_NEW, HB_NEW, with_b=False)
        errors, _ = check(self.root)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn('`bSrc`', errors[0])

    def test_an_input_in_neither_lock_is_an_error(self):
        self.write_package(B_NEW, HB_NEW)
        lock = json.loads((self.root / 'flake.lock').read_text())
        del lock['nodes']['root']['inputs']['b-src']
        (self.root / 'flake.lock').write_text(json.dumps(lock))
        errors, _ = check(self.root)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn('b-src', errors[0])

    def test_an_unreadable_src_commit_is_an_error_not_a_pass(self):
        self.write_package(B_NEW, HB_NEW)
        package = (self.root / PACKAGE_NIX).read_text().replace(self.src, 'd' * 40)
        (self.root / PACKAGE_NIX).write_text(package)
        errors, pending = check(self.root)
        self.assertEqual(pending, [])
        self.assertEqual(len(errors), 1, errors)
        self.assertIn('d' * 40, errors[0])


class SrcCommitFetch(unittest.TestCase):
    """A clone that lacks the `src` commit fetches it without becoming shallow."""

    def test_a_full_clone_fetches_the_missing_src_commit_and_stays_full(self):
        with tempfile.TemporaryDirectory() as temp:
            origin, clone = Path(temp) / 'origin', Path(temp) / 'clone'
            origin.mkdir()
            git(origin, 'init', '-q', '-b', 'main')
            git(origin, 'config', 'user.email', 't@example.invalid')
            git(origin, 'config', 'user.name', 'Tester')
            git(origin, 'config', 'commit.gpgsign', 'false')
            (origin / 'flake.lock').write_text(flake_lock({'a-src': github(A1, 'sha256-a1=')}))
            git(origin, 'add', '.')
            git(origin, 'commit', '-q', '-m', 'main')
            # The `src` commit is reachable only from a ref a clone does not fetch.
            git(origin, 'checkout', '-q', '-b', 'release')
            (origin / 'flake.lock').write_text(flake_lock({'a-src': github(A2, 'sha256-a2=')}))
            git(origin, 'commit', '-q', '-am', 'the src commit')
            src = git(origin, 'rev-parse', 'HEAD')
            git(origin, 'update-ref', 'refs/keep/src', src)
            git(origin, 'checkout', '-q', 'main')
            git(origin, 'branch', '-q', '-D', 'release')
            subprocess.run(['git', 'clone', '-q', '--no-local', origin.as_uri(), str(clone)],
                           check=True)
            self.assertNotEqual(subprocess.run(['git', '-C', str(clone), 'cat-file', '-e',
                                                f'{src}^{{commit}}']).returncode, 0)
            text, why = src_lock_text(clone, src, 'git')
            self.assertEqual(why, '')
            self.assertIn(A2, text)
            self.assertEqual(git(clone, 'rev-parse', '--is-shallow-repository'), 'false')


class PendingSourcesRealTree(unittest.TestCase):
    FILES = (PACKAGE_NIX, NIM_FORK_NIX, TABLE, 'flake.lock')

    def test_committed_tree_passes(self):
        errors, _ = check(ROOT)
        self.assertEqual(errors, [])

    def test_the_issues_situation_rebuilt_from_the_real_files_is_refused(self):
        # test-certificates-tools-src postdates the `src` commit, and this
        # tree's lock moved it while the default stayed put.
        tree_lock = json.loads((ROOT / 'flake.lock').read_text())
        # The revision the refusal must quote is the default package.nix
        # carries, not this tree's flake.lock: the two differ legitimately
        # whenever the tree's pin has moved past the one the `src` commit
        # already has (the input is then not pending, and the default keeps
        # mirroring the `src` commit's lock).
        defaults = re.findall(
            r'\n  testCertificatesToolsSrc \? fetchFromGitHub \{[^}]*?'
            r'rev = "([0-9a-f]{40})"',
            (ROOT / PACKAGE_NIX).read_text())
        self.assertEqual(len(defaults), 1, defaults)
        old_rev = defaults[0]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for rel in self.FILES:
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / rel, root / rel)
            git(root, 'init', '-q')
            git(root, 'config', 'user.email', 't@example.invalid')
            git(root, 'config', 'user.name', 'Tester')
            git(root, 'config', 'commit.gpgsign', 'false')
            src_lock = json.loads(json.dumps(tree_lock))
            del src_lock['nodes'][src_lock['root']]['inputs']['test-certificates-tools-src']
            (root / 'flake.lock').write_text(json.dumps(src_lock))
            git(root, 'add', 'flake.lock')
            git(root, 'commit', '-q', '-m', 'the src commit, before the input existed')
            src = git(root, 'rev-parse', 'HEAD')
            package = (root / PACKAGE_NIX).read_text()
            package, count = re.subn(
                r'(\n  src = fetchFromGitHub \{[^}]*?rev = ")[0-9a-f]{40}(")',
                rf'\g<1>{src}\g<2>', package)
            self.assertEqual(count, 1)
            (root / PACKAGE_NIX).write_text(package)
            moved = json.loads(json.dumps(tree_lock))
            moved_node = moved['nodes'][moved['nodes'][moved['root']]['inputs'][
                'test-certificates-tools-src']]['locked']
            moved_node['rev'] = 'e' * 40
            moved_node['narHash'] = 'sha256-moved='
            (root / 'flake.lock').write_text(json.dumps(moved))
            errors, pending = check(root)
        self.assertEqual(pending, ['test-certificates-tools-src'])
        self.assertEqual(len(errors), 1, errors)
        self.assertIn('`testCertificatesToolsSrc`', errors[0])
        self.assertIn(old_rev, errors[0])
        self.assertIn('e' * 40, errors[0])
        self.assertIn('sha256-moved=', errors[0])

    def test_lint_runs_the_check_and_this_test(self):
        justfile = (ROOT / 'Justfile').read_text()
        self.assertRegex(justfile, r'(?m)^\s+python3 \./tests/unit/test_package_nix_pending_sources\.py\b')
        self.assertRegex(justfile, r'(?m)^\s+python3 \./scripts/check_package_nix_pending_sources\.py\b')


if __name__ == '__main__':
    unittest.main()
