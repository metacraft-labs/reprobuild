#!/usr/bin/env python3
"""Refuse a committed `flake.lock` whose revision-pinned node lacks its hashes.

A `locked` node for a forge or git input names a revision (`rev`) and carries
the fields nix derives from that revision's content: `narHash` and
`lastModified`, plus `revCount` for a `git` input that is not shallow. These
are what `nix flake lock` writes, and what makes the pin verifiable:

  * without `narHash`, nix cannot check a fetched tree against the lock, and a
    store path already holding that tree cannot satisfy the input, so every
    evaluation has to fetch the input from its forge again. Where the forge is
    unreachable (offline, or a private repository without credentials) the dev
    shell cannot be entered at all, even with every other input cached;
  * nix treats a `rev`-only node as fully locked and never adds the missing
    fields on a later evaluation, so such a node stays weak until someone
    rewrites it. Nothing at evaluation time reports it.

So the gap is caught here, at lint time. Every node in the graph is checked,
not only the root's direct inputs: the dev shell fetches transitive inputs too.

Tarball and path nodes are out of scope: their `rev`, when present, is not the
fetch coordinate, and nix decides per fetcher which derived fields it records.

The values to record are the ones nix computes for the node's own revision;
see https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-flake#lock-files
for the lock-file format.
"""
import argparse
import json
from pathlib import Path
import sys

# Fetchers whose `rev` IS the fetch coordinate, so its content hash is defined.
REVISION_ADDRESSED_TYPES = ('github', 'gitlab', 'sourcehut', 'git')
REQUIRED_FIELDS = ('narHash', 'lastModified')


def check_lock(data: dict) -> list[str]:
    """Return one named error per missing derived field, in node order."""
    errors = []
    for node_id, node in data.get('nodes', {}).items():
        locked = node.get('locked')
        if not isinstance(locked, dict) or not locked.get('rev'):
            continue
        kind = locked.get('type')
        if kind not in REVISION_ADDRESSED_TYPES:
            continue
        required = list(REQUIRED_FIELDS)
        # nix records `revCount` for a git input unless it fetched a shallow
        # clone, where the count is unknowable.
        if kind == 'git' and not locked.get('shallow'):
            required.append('revCount')
        missing = [field for field in required if field not in locked]
        if missing:
            errors.append(
                f'flake.lock: node "{node_id}" ({kind}, rev {locked["rev"]}) has no '
                f'{" or ".join(missing)}; record the values nix computes for that '
                f'revision (`nix flake lock` / `nix flake prefetch`) without moving it')
    return errors


def check(root: Path) -> list[str]:
    """Check `<root>/flake.lock`; a repository without one has nothing to check."""
    lock = root / 'flake.lock'
    if not lock.exists():
        return []
    return check_lock(json.loads(lock.read_text()))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('root', nargs='?', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        errors = check(args.root)
    except (OSError, ValueError) as error:
        print(f'FAIL: cannot read {args.root / "flake.lock"}: {error}', file=sys.stderr)
        return 1
    if errors:
        print('FAIL: flake.lock has revision-pinned nodes without their derived fields:',
              file=sys.stderr)
        for error in errors:
            print(f'  {error}', file=sys.stderr)
        return 1
    print('OK: every revision-pinned flake.lock node carries its derived fields')
    return 0


if __name__ == '__main__':
    sys.exit(main())
