#!/usr/bin/env python3
"""Every revision-pinned `flake.lock` node carries the fields nix derives.

Under test: ``scripts/check_flake_lock_derived_fields.py``. Two `github` nodes,
``reprobuild-ct-test-runner-src`` and ``reprobuild-test-adapters-src``, sat in
the committed lock for a month with a `rev` and nothing else, written by commits
that moved only the revision. Without a `narHash` an already-fetched store path
cannot satisfy the input, so the pre-commit hook's plain `nix develop` had to
download both from GitHub and failed wherever that was refused, with every
other input in the store.

No mocks. The rule-by-rule cases need locks that are wrong in exactly one way,
which the committed one is not, so they check minimal lock documents in nix's
format. The remaining cases run against the REAL committed `flake.lock`: it
passes (with a positive control that the check covered the nodes the defect
was in), and it is refused once either node's hash is taken out again.
"""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from check_flake_lock_derived_fields import check, check_lock  # noqa: E402

REV = 'a' * 40
HASH = 'sha256-' + 'A' * 43 + '='
# The two nodes the defect was observed in, at the revisions they must keep.
FORMERLY_HASHLESS = {
    'reprobuild-ct-test-runner-src': 'bb7a4b6ed4466f39292da4b819ed35a4ceb938ef',
    'reprobuild-test-adapters-src': 'b756151259068db452a85253141afad2b5840f64',
}


def lock_with(locked: dict) -> dict:
    """A one-input lock document whose only node is ``locked``."""
    return {'version': 7, 'root': 'root', 'nodes': {
        'root': {'inputs': {'dep': 'dep'}},
        'dep': {'flake': False, 'locked': locked, 'original': {'type': locked['type']}},
    }}


def forge(kind: str = 'github', **fields) -> dict:
    node = {'type': kind, 'owner': 'metacraft-labs', 'repo': 'dep', 'rev': REV,
            'narHash': HASH, 'lastModified': 1791376944}
    node.update(fields)
    return {key: value for key, value in node.items() if value is not None}


class DerivedFieldRules(unittest.TestCase):

    def test_a_complete_forge_node_passes(self):
        for kind in ('github', 'gitlab', 'sourcehut'):
            with self.subTest(kind=kind):
                self.assertEqual(check_lock(lock_with(forge(kind))), [])

    def test_a_rev_only_node_is_refused_naming_node_and_revision(self):
        errors = check_lock(lock_with(forge(narHash=None, lastModified=None)))
        self.assertEqual(len(errors), 1)
        self.assertIn('"dep"', errors[0])
        self.assertIn(REV, errors[0])
        self.assertIn('narHash or lastModified', errors[0])

    def test_each_missing_field_is_refused_on_its_own(self):
        for field in ('narHash', 'lastModified'):
            for kind in ('github', 'gitlab', 'sourcehut', 'git'):
                with self.subTest(field=field, kind=kind):
                    node = forge(kind, **{field: None})
                    if kind == 'git':
                        node.update(url='https://example.invalid/dep', revCount=7)
                    errors = check_lock(lock_with(node))
                    self.assertEqual(len(errors), 1, errors)
                    self.assertRegex(errors[0], rf'has no {field};')

    def test_a_git_node_needs_rev_count_unless_shallow(self):
        git = {'type': 'git', 'url': 'https://example.invalid/dep', 'rev': REV,
               'narHash': HASH, 'lastModified': 1791376944}
        self.assertRegex(check_lock(lock_with(git))[0], r'has no revCount;')
        self.assertEqual(check_lock(lock_with(dict(git, revCount=12))), [])
        self.assertEqual(check_lock(lock_with(dict(git, shallow=True))), [])

    def test_nodes_whose_rev_is_not_the_fetch_coordinate_are_not_judged(self):
        # A tarball's `rev`, a path node and a revisionless node carry no
        # content hash the rule could demand.
        for locked in ({'type': 'tarball', 'url': 'https://example.invalid/x.tar.gz', 'rev': REV},
                       {'type': 'path', 'path': '/nix/store/x'},
                       {'type': 'github', 'owner': 'o', 'repo': 'r'}):
            with self.subTest(locked=locked):
                self.assertEqual(check_lock(lock_with(locked)), [])

    def test_transitive_nodes_are_checked_too(self):
        data = lock_with(forge())
        data['nodes']['dep-of-dep'] = {'locked': forge(narHash=None)}
        errors = check_lock(data)
        self.assertEqual(len(errors), 1)
        self.assertIn('"dep-of-dep"', errors[0])

    def test_a_checkout_without_a_flake_lock_has_nothing_to_check(self):
        with tempfile.TemporaryDirectory() as temp:
            self.assertEqual(check(Path(temp)), [])


class CommittedFlakeLock(unittest.TestCase):

    def setUp(self):
        self.data = json.loads((ROOT / 'flake.lock').read_text())

    def test_the_committed_lock_passes(self):
        self.assertEqual(check(ROOT), [])

    def test_the_formerly_hashless_nodes_are_checked_and_kept_at_their_revisions(self):
        # Positive control: the clean result above is about these two nodes,
        # which must still be revision-addressed (or the check would skip
        # them) and must not have moved when their hashes were recorded.
        for node_id, rev in FORMERLY_HASHLESS.items():
            with self.subTest(node=node_id):
                locked = self.data['nodes'][node_id]['locked']
                self.assertEqual(locked['type'], 'github')
                self.assertEqual(locked['rev'], rev)
                self.assertRegex(locked['narHash'], r'^sha256-[A-Za-z0-9+/]{43}=$')

    def test_the_committed_lock_is_refused_with_either_hash_taken_out(self):
        for node_id, rev in FORMERLY_HASHLESS.items():
            with self.subTest(node=node_id):
                data = copy.deepcopy(self.data)
                del data['nodes'][node_id]['locked']['narHash']
                del data['nodes'][node_id]['locked']['lastModified']
                errors = check_lock(data)
                self.assertEqual(len(errors), 1, errors)
                self.assertIn(f'"{node_id}"', errors[0])
                self.assertIn(rev, errors[0])

    def test_lint_runs_the_gate_and_its_tests(self):
        workflows = (ROOT / 'scripts/check_workflows.sh').read_text()
        self.assertRegex(workflows, r'(?m)^python3 tests/unit/test_flake_lock_derived_fields\.py$')
        self.assertRegex(workflows, r'(?m)^python3 scripts/check_flake_lock_derived_fields\.py$')


if __name__ == '__main__':
    unittest.main()
