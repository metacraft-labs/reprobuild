#!/usr/bin/env python3
"""Check explicit sibling commit pins against both committed lock formats.

No network is needed: a commit's sibling bill of materials must be consistent
before any clone or build starts. Acknowledging an override with != does not
make a checkout usable by a consumer whose lock requires another revision.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import tomllib

SHA = re.compile(r'[0-9a-fA-F]{40}')


def check(root: Path) -> list[str]:
    """Return named mismatches for every explicit SHA and every matching lock."""
    locked = {}
    repro = root / 'repro.lock'
    if repro.exists():
        data = tomllib.loads(repro.read_text())
        for dep in data.get('lock', {}).get('deps', []):
            if dep.get('coord_kind') == 'vcs' and dep.get('revision'):
                locked.setdefault(dep['name'], []).append(('repro.lock', dep['revision']))
    flake = root / 'flake.lock'
    if flake.exists():
        data = json.loads(flake.read_text())
        # Use the repository coordinate, not the input alias (often *-src).
        # Transitive inputs can carry other versions of a repo: only direct
        # root inputs describe the source this project's dev shell consumes.
        nodes = data['nodes']
        for node_id in nodes[data['root']].get('inputs', {}).values():
            if not isinstance(node_id, str):
                continue  # follows input; it is not an independent source pin
            pin = nodes[node_id].get('locked', {})
            if pin.get('type') == 'github' and pin.get('owner') == 'metacraft-labs' and pin.get('rev'):
                locked.setdefault(pin['repo'], []).append(('flake.lock', pin['rev']))
    errors = []
    for number, raw in enumerate((root / '.github/sibling-repos').read_text().splitlines(), 1):
        entry = raw.split('#', 1)[0].strip()
        if '=' not in entry:
            continue
        name, revision = entry.split('=', 1)
        name = name.removesuffix('!')
        if not SHA.fullmatch(revision):
            continue
        for source, expected in locked.get(name, []):
            if revision.lower() != expected.lower():
                errors.append(f'.github/sibling-repos:{number}: {name}={revision} conflicts with '
                              f'{source} revision {expected}')
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        errors = check(args.root)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'FAIL: cannot validate sibling lock pins: {error}', file=sys.stderr)
        return 1
    if errors:
        print('\n'.join(f'FAIL: {error}' for error in errors), file=sys.stderr)
        return 1
    print('ok: explicit sibling commit pins match repro.lock and flake.lock')
    return 0


if __name__ == '__main__':
    sys.exit(main())
