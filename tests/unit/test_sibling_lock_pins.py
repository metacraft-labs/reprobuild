#!/usr/bin/env python3
"""`.github/sibling-repos` pins must agree with `repro.lock` and `flake.lock`.

Under test: ``scripts/check_sibling_lock_pins.py``, the gate for reprobuild-pm
issue
``2026-10-21-release-ci-clones-reprobuild-test-adapters-at-a-revision-repro-lock-refuses``.
``.github/sibling-repos`` cloned ``reprobuild-test-adapters`` at 72962c60
while both locks pinned b0fc1bcb; the engine refused the clone with
``cross-repo producer "reprobuild-test-adapters" source revision mismatch`` and
the v0.2.13 release (run 39574741678) failed before compiling anything.

No mocks. The rule-by-rule cases need lock files that are wrong in exactly one
way, which the real ones are not, so they write minimal ``repro.lock`` /
``flake.lock`` / ``sibling-repos`` files in the real formats to a temporary
directory. The remaining cases run against the REAL committed files: the tree
agrees (with a positive control that the comparison is not vacuous), and the
tree with the 72962c60 line put back is refused, naming both revisions.
"""
import json
from pathlib import Path
import re
import sys
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from check_sibling_lock_pins import check  # noqa: E402

ADAPTERS = 'reprobuild-test-adapters'
STALE_ADAPTERS_PIN = '72962c60f12426ba00b621fda5ab76b0f89ba912'


def write_tree(root: Path, siblings: str, repro_lock: str, flake_lock: str) -> None:
    """A minimal checkout: the three files the gate reads."""
    (root / '.github').mkdir(exist_ok=True)
    (root / '.github/sibling-repos').write_text(siblings)
    (root / 'repro.lock').write_text(repro_lock)
    (root / 'flake.lock').write_text(flake_lock)


class SiblingLockPinFixtures(unittest.TestCase):
    old, current = '7' * 40, 'b' * 40

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repro = ('[lock]\ndeps = [{name = "adapter", coord_kind = "vcs", revision = "'
                      + self.current + '"}]\n')
        self.flake = json.dumps({'root': 'root', 'nodes': {
            'root': {'inputs': {'adapter-src': 'adapter-node', 'queue-src': 'queue-node',
                                'nixpkgs': ['other', 'nixpkgs']}},
            'adapter-node': {'locked': {'type': 'github', 'owner': 'metacraft-labs',
                                        'repo': 'adapter', 'rev': self.current}},
            'queue-node': {'locked': {'type': 'github', 'owner': 'metacraft-labs',
                                      'repo': 'queue', 'rev': self.current}},
            # A transitive input may carry another version; only direct root
            # inputs describe what this project consumes.
            'transitive': {'locked': {'type': 'github', 'owner': 'metacraft-labs',
                                      'repo': 'adapter', 'rev': self.old}}}})

    def tearDown(self):
        self.temp.cleanup()

    def errors_for(self, siblings: str) -> list[str]:
        write_tree(self.root, siblings, self.repro, self.flake)
        return check(self.root)

    def test_stale_sha_is_refused_against_each_lock_in_both_forms(self):
        for operator in ('=', '!='):
            with self.subTest(operator=operator):
                errors = self.errors_for(f'  adapter{operator}{self.old} # drift\n')
                self.assertEqual(len(errors), 2, errors)
                self.assertIn('repro.lock', errors[0])
                self.assertIn('flake.lock', errors[1])
                for error in errors:
                    self.assertIn('adapter', error)
                    self.assertIn(self.old, error)
                    self.assertIn(self.current, error)
                    self.assertIn('.github/sibling-repos:1', error)

    def test_matching_sha_passes_in_any_case(self):
        for operator in ('=', '!='):
            with self.subTest(operator=operator):
                self.assertEqual(self.errors_for(f'adapter{operator}{self.current.upper()}\n'), [])

    def test_branch_ref_of_a_repro_lock_pinned_repo_is_refused(self):
        # The engine refuses any commit but the locked one, so a branch clone
        # breaks CI as soon as the branch moves past the lock.
        for entry in ('adapter=agents', 'adapter!=dev', ' adapter = agents  # why'):
            with self.subTest(entry=entry):
                errors = self.errors_for(entry + '\n')
                self.assertEqual(len(errors), 1, errors)
                self.assertIn('adapter=agents' if 'agents' in entry else 'adapter=dev', errors[0])
                self.assertIn(f'repro.lock pins adapter at revision {self.current}', errors[0])

    def test_branch_ref_of_a_flake_only_repo_is_allowed(self):
        self.assertEqual(self.errors_for('queue=dev\n'), [])
        errors = self.errors_for(f'queue={self.old}\n')
        self.assertEqual(len(errors), 1, errors)
        self.assertIn('flake.lock', errors[0])

    def test_bare_and_unlocked_entries_are_not_checked(self):
        self.assertEqual(self.errors_for(f'adapter\nunlocked={self.old}\nunlocked2=dev\n'), [])

    def test_each_lock_detects_drift_alone(self):
        write_tree(self.root, f'adapter={self.old}\n', self.repro, self.flake)
        (self.root / 'repro.lock').unlink()
        errors = check(self.root)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn('flake.lock', errors[0])
        write_tree(self.root, f'adapter={self.old}\n', self.repro, self.flake)
        (self.root / 'flake.lock').unlink()
        errors = check(self.root)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn('repro.lock', errors[0])

    def test_unreadable_lock_is_an_error_not_a_pass(self):
        write_tree(self.root, f'adapter={self.old}\n', self.repro, '{bad json')
        with self.assertRaises(ValueError):
            check(self.root)


class SiblingLockPinsRealTree(unittest.TestCase):
    def setUp(self):
        self.siblings = (ROOT / '.github/sibling-repos').read_text()
        self.repro = (ROOT / 'repro.lock').read_text()
        self.flake = (ROOT / 'flake.lock').read_text()
        deps = tomllib.loads(self.repro)['lock']['deps']
        self.locked_adapters = next(d['revision'] for d in deps if d['name'] == ADAPTERS)

    def test_committed_tree_agrees_and_the_comparison_is_not_vacuous(self):
        self.assertEqual(check(ROOT), [])
        # Positive control: the entry that broke v0.2.13 is present as an
        # explicit SHA, and both locks pin that repo, so "no errors" above
        # came from a real comparison.
        entry = re.search(rf'^{re.escape(ADAPTERS)}=(\S+)', self.siblings, re.M)
        self.assertIsNotNone(entry)
        self.assertEqual(entry.group(1), self.locked_adapters)
        self.assertIn(f'"repo": "{ADAPTERS}"', self.flake)

    def test_committed_tree_with_the_v0_2_13_defect_put_back_is_refused(self):
        self.assertNotEqual(self.locked_adapters, STALE_ADAPTERS_PIN)
        stale, count = re.subn(rf'^{re.escape(ADAPTERS)}=\S+',
                               f'{ADAPTERS}={STALE_ADAPTERS_PIN}', self.siblings, flags=re.M)
        self.assertEqual(count, 1)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_tree(root, stale, self.repro, self.flake)
            errors = check(root)
        self.assertEqual(len(errors), 2, errors)
        self.assertTrue(any('repro.lock' in e for e in errors))
        self.assertTrue(any('flake.lock' in e for e in errors))
        for error in errors:
            self.assertIn(ADAPTERS, error)
            self.assertIn(STALE_ADAPTERS_PIN, error)
            self.assertIn(self.locked_adapters, error)

    def test_lint_runs_the_gate_and_this_test(self):
        workflows = (ROOT / 'scripts/check_workflows.sh').read_text()
        self.assertRegex(workflows, r'(?m)^python3 tests/unit/test_sibling_lock_pins\.py$')
        self.assertRegex(workflows, r'(?m)^python3 scripts/check_sibling_lock_pins\.py$')


if __name__ == '__main__':
    unittest.main()
