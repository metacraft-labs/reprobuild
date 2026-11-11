#!/usr/bin/env python3
"""`.github/sibling-repos` must not pin what `repro.lock` pins, and must agree
with `flake.lock`.

Under test: ``scripts/check_sibling_lock_pins.py``, the gate for reprobuild-pm
issue
``2026-10-21-release-ci-clones-reprobuild-test-adapters-at-a-revision-repro-lock-refuses``.
``.github/sibling-repos`` cloned ``reprobuild-test-adapters`` at 72962c60
while both locks pinned b0fc1bcb; the engine refused the clone with
``cross-repo producer "reprobuild-test-adapters" source revision mismatch`` and
the v0.2.13 release (run 39574741678) failed before compiling anything.

A sibling `repro.lock` pins is listed as a bare `name`: `clone-siblings`
resolves it from the committed `repro.lock`, so an explicit ref is a second
source of truth, the one that drifted in reprobuild-pm issue
``2026-10-31-lock-update-does-not-move-the-package-default-or-the-ci-sibling-pin``
(`repro lock update` moved both locks and left the clone pin behind). A ref
for a sibling only `flake.lock` pins must equal that lock's revision.

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

    def test_any_ref_of_a_repro_lock_pinned_repo_is_refused_naming_the_bare_form(self):
        # A stale commit, the locked commit itself, and a branch (which the
        # engine refuses as soon as it moves past the lock) are all a second
        # source of truth for a revision repro.lock already records.
        for entry, ref in ((f'  adapter={self.old} # drift', self.old),
                           (f'adapter!={self.old}', self.old),
                           (f'adapter={self.current.upper()}', self.current.upper()),
                           (f'adapter!={self.current}', self.current),
                           ('adapter=agents', 'agents'),
                           (' adapter != dev  # why', 'dev')):
            with self.subTest(entry=entry):
                errors = self.errors_for(entry + '\n')
                self.assertEqual(len(errors), 1, errors)
                self.assertIn('.github/sibling-repos:1', errors[0])
                self.assertIn(f'adapter={ref}', errors[0])
                self.assertIn(f'repro.lock pins adapter at revision {self.current}', errors[0])
                self.assertIn('list it as the bare name `adapter`', errors[0])

    def test_sha_of_a_flake_only_repo_must_match_in_both_forms(self):
        for operator in ('=', '!='):
            with self.subTest(operator=operator):
                self.assertEqual(self.errors_for(f'queue{operator}{self.current.upper()}\n'), [])
                errors = self.errors_for(f'queue{operator}{self.old}\n')
                self.assertEqual(len(errors), 1, errors)
                self.assertIn('flake.lock', errors[0])
                self.assertIn(self.old, errors[0])
                self.assertIn(self.current, errors[0])

    def test_branch_ref_of_a_flake_only_repo_is_allowed(self):
        self.assertEqual(self.errors_for('queue=dev\n'), [])
        errors = self.errors_for(f'queue={self.old}\n')
        self.assertEqual(len(errors), 1, errors)
        self.assertIn('flake.lock', errors[0])

    def test_bare_and_unlocked_entries_are_not_checked(self):
        self.assertEqual(self.errors_for(f'adapter\nunlocked={self.old}\nunlocked2=dev\n'), [])

    def test_each_lock_is_read_alone(self):
        # Without repro.lock the sibling is flake-only: its ref is compared.
        write_tree(self.root, f'adapter={self.old}\n', self.repro, self.flake)
        (self.root / 'repro.lock').unlink()
        errors = check(self.root)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn('flake.lock', errors[0])
        # Without flake.lock repro.lock alone makes any ref redundant.
        write_tree(self.root, f'adapter={self.current}\n', self.repro, self.flake)
        (self.root / 'flake.lock').unlink()
        errors = check(self.root)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn('repro.lock pins adapter', errors[0])

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
        self.locked = {d['name']: d['revision'] for d in deps
                       if d.get('coord_kind') == 'vcs' and d.get('self') != 'true'}
        self.locked_adapters = self.locked[ADAPTERS]

    def entries(self) -> dict[str, str]:
        """Each listed sibling and its ref ('' for a bare name)."""
        result = {}
        for raw in self.siblings.splitlines():
            entry = raw.split('#', 1)[0].strip()
            if entry:
                name, _, ref = entry.partition('=')
                result[name.strip().removesuffix('!')] = ref.strip()
        return result

    def test_committed_tree_lists_every_repro_lock_sibling_bare(self):
        self.assertEqual(check(ROOT), [])
        # Positive control: repro.lock pins siblings that CI clones, so "no
        # errors" above came from a real comparison, not an empty one.
        listed = self.entries()
        cloned = sorted(name for name in self.locked if name in listed)
        self.assertGreaterEqual(len(cloned), 5, cloned)
        for name in cloned:
            self.assertEqual(listed[name], '', f'{name} carries a ref: {listed[name]}')

    def test_committed_tree_with_the_v0_2_13_defect_put_back_is_refused(self):
        self.assertNotEqual(self.locked_adapters, STALE_ADAPTERS_PIN)
        stale, count = re.subn(rf'^{re.escape(ADAPTERS)}[ \t]*$',
                               f'{ADAPTERS}={STALE_ADAPTERS_PIN}', self.siblings, flags=re.M)
        self.assertEqual(count, 1)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_tree(root, stale, self.repro, self.flake)
            errors = check(root)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn(f'{ADAPTERS}={STALE_ADAPTERS_PIN}', errors[0])
        self.assertIn(f'repro.lock pins {ADAPTERS} at revision {self.locked_adapters}', errors[0])

    def test_lint_runs_the_gate_and_this_test(self):
        workflows = (ROOT / 'scripts/check_workflows.sh').read_text()
        self.assertRegex(workflows, r'(?m)^python3 tests/unit/test_sibling_lock_pins\.py$')
        self.assertRegex(workflows, r'(?m)^python3 scripts/check_sibling_lock_pins\.py$')


if __name__ == '__main__':
    unittest.main()
