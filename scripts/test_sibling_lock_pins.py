#!/usr/bin/env python3
"""Exercise real lock files and temporary TOML/JSON fixtures; no mocked tools."""
import json
from pathlib import Path
import tempfile
import unittest
from check_sibling_lock_pins import check

ROOT = Path(__file__).resolve().parents[1]


class SiblingLockPins(unittest.TestCase):
    def test_lock_consistency_fixtures(self):
        old, current = '7' * 40, 'b' * 40
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / '.github').mkdir()
            repro = root / 'repro.lock'
            flake = root / 'flake.lock'
            siblings = root / '.github/sibling-repos'
            repro.write_text('[lock]\ndeps = [{name = "adapter", coord_kind = "vcs", revision = "' + current + '"}]\n')
            flake.write_text(json.dumps({'root': 'root', 'nodes': {
                'root': {'inputs': {'adapter-src': 'adapter-node'}},
                'adapter-node': {'locked': {'type': 'github', 'owner': 'metacraft-labs',
                                             'repo': 'adapter', 'rev': current}},
                'transitive': {'locked': {'type': 'github', 'owner': 'metacraft-labs',
                                          'repo': 'adapter', 'rev': old}}}}))
            for operator in ('=', '!='):
                with self.subTest(operator=operator):
                    siblings.write_text(f'  adapter{operator}{old} # drift\n')
                    errors = check(root)
                    self.assertEqual(len(errors), 2)
                    self.assertIn('repro.lock', errors[0])
                    self.assertIn('flake.lock', errors[1])
                    self.assertIn(old, errors[0])
                    self.assertIn(current, errors[0])
                    siblings.write_text(f'adapter{operator}{current.upper()}\n')
                    self.assertEqual(check(root), [])
            for entry in ('adapter', 'adapter=agents', 'unlocked=' + old):
                siblings.write_text(entry + '\n')
                self.assertEqual(check(root), [])
            # Each lock independently detects drift when the other is absent.
            siblings.write_text('adapter=' + old + '\n')
            repro.unlink()
            self.assertEqual(len(check(root)), 1)
            self.assertIn('flake.lock', check(root)[0])
            flake.write_text('{bad json')
            with self.assertRaises(ValueError):
                check(root)

    def test_release_adapter_pin_matches_committed_lock(self):
        import tomllib
        deps = tomllib.loads((ROOT / 'repro.lock').read_text())['lock']['deps']
        expected = next(d['revision'] for d in deps if d['name'] == 'reprobuild-test-adapters')
        entry = next(line for line in (ROOT / '.github/sibling-repos').read_text().splitlines()
                     if line.startswith('reprobuild-test-adapters='))
        self.assertEqual(entry.split('=', 1)[1], expected)


if __name__ == '__main__':
    unittest.main()
