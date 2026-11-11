#!/usr/bin/env python3
"""A pending source default of package.nix must mirror this tree's flake.lock.

package.nix's `*Src` defaults (and nim-fork.nix's) are one snapshot of a
published reprobuild commit: the one its `src` names. Each mirrors that
commit's `flake.lock`, not this tree's, so a sibling pin refresh here moves no
default. The exception is an input that commit's lock does not have yet,
because this tree gained it afterwards: its default mirrors THIS tree's
`flake.lock` until the next release moves `src` past it. The flake check
`nixpkgs-package-src-sync` (flake.nix) enforces both halves, but it evaluates
the flake and fetches the `src` tree, and nothing runs it before a push.

This script is the pending half, which needs neither: it reads the `src`
commit's `flake.lock` from git (fetching that one commit when the clone lacks
it), and for every argument whose input that lock does not have, requires the
default's `rev` and hash to equal this tree's lock node (`rev`, `narHash`).
`repro lock update` moves both locks and no package default, so this is where
a pending default left behind is reported.

The argument -> input table is nix/package-source-inputs.json, which the flake
check reads too. Matching is counted: an argument with no
`<arg> ? fetchFromGitHub { ... }` default is an error, not a pass.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

PACKAGE_NIX = 'nix/pkgs/by-name/re/reprobuild/package.nix'
NIM_FORK_NIX = 'nix/pkgs/by-name/re/reprobuild/nim-fork.nix'
TABLE = 'nix/package-source-inputs.json'
FILES = {'package.nix': PACKAGE_NIX, 'nim-fork.nix': NIM_FORK_NIX}


def literal(block: str, name: str) -> str:
    """The plain string literal `name = "...";` of a fetchFromGitHub block."""
    found = re.findall(rf'(?m)^\s*{name}\s*=\s*"([^"$\\]*)"\s*;', block)
    return found[0] if len(found) == 1 else ''


def fetch_block(text: str, head: str) -> tuple[str, int] | None:
    """The body of the `<head> fetchFromGitHub { ... }` call, and its line."""
    match = re.search(rf'(?m)^\s*{head}\s*fetchFromGitHub\s*\{{', text)
    if not match:
        return None
    close = text.find('}', match.end())
    if close < 0:
        return None
    return text[match.end():close], text.count('\n', 0, match.start()) + 1


def root_inputs(lock: dict) -> dict:
    return lock['nodes'][lock['root']].get('inputs', {})


def src_lock_text(root: Path, rev: str, git: str) -> tuple[str, str]:
    """The `src` commit's flake.lock, or "" and git's reason."""
    def show() -> subprocess.CompletedProcess:
        return subprocess.run([git, '-C', str(root), 'show', f'{rev}:flake.lock'],
                              capture_output=True, text=True)
    shown = show()
    if shown.returncode != 0:
        subprocess.run([git, '-C', str(root), 'fetch', '--quiet', '--depth', '1',
                        'origin', rev], capture_output=True, text=True)
        shown = show()
    if shown.returncode != 0:
        return '', (shown.stderr.strip().splitlines() or ['git show failed'])[-1]
    return shown.stdout, ''


def check(root: Path, git: str = 'git') -> tuple[list[str], list[str]]:
    """The errors, and the pending inputs that were checked."""
    package_text = (root / PACKAGE_NIX).read_text()
    src = fetch_block(package_text, 'src =')
    src_rev = literal(src[0], 'rev') if src else ''
    if not re.fullmatch(r'[0-9a-f]{40}', src_rev):
        return [f'{PACKAGE_NIX}: no `src = fetchFromGitHub {{ ... }}` with a literal '
                f'commit id as its rev'], []
    text, why = src_lock_text(root, src_rev, git)
    if not text:
        return [f'{PACKAGE_NIX}: cannot read flake.lock of the `src` commit {src_rev} '
                f'({why}); fetch it with `git fetch origin {src_rev}`'], []
    src_inputs = root_inputs(json.loads(text))
    tree = json.loads((root / 'flake.lock').read_text())
    tree_inputs = root_inputs(tree)
    table = json.loads((root / TABLE).read_text())
    errors, pending = [], []
    for file, args in table.items():
        rel = FILES[file]
        file_text = (root / rel).read_text()
        for arg, input_ in args.items():
            found = fetch_block(file_text, rf'{re.escape(arg)}\s*\?')
            if found is None:
                errors.append(f'{rel}: `{arg}` has no `? fetchFromGitHub {{ ... }}` default '
                              f'(the table {TABLE} names it for `{input_}`)')
                continue
            if input_ in src_inputs:
                continue  # the `src` commit's lock governs it (nixpkgs-package-src-sync)
            block, line = found
            node_id = tree_inputs.get(input_)
            if not isinstance(node_id, str):
                errors.append(f'{rel}:{line}: `{arg}`: neither the `src` commit\'s '
                              f'flake.lock nor this tree\'s has an input `{input_}`')
                continue
            if input_ not in pending:
                pending.append(input_)
            locked = tree['nodes'][node_id].get('locked', {})
            want_rev, want_hash = locked.get('rev', ''), locked.get('narHash', '')
            rev = literal(block, 'rev')
            hash_name = 'hash' if literal(block, 'hash') else 'sha256'
            hash_ = literal(block, hash_name)
            if rev != want_rev or (want_hash and hash_ != want_hash):
                errors.append(
                    f'{rel}:{line}: `{arg}` defaults to rev {rev or "(none)"}, {hash_name} '
                    f'{hash_ or "(none)"}; `{input_}` postdates the `src` commit {src_rev}, '
                    f'so the default mirrors this tree\'s flake.lock, which pins it at '
                    f'{want_rev}' + (f' with narHash {want_hash}' if want_hash else '')
                    + f': set rev = "{want_rev}";'
                    + (f' and {hash_name} = "{want_hash}";' if want_hash else ''))
    return errors, pending


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        errors, pending = check(args.root)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'FAIL: cannot check the pending package.nix source defaults: {error}',
              file=sys.stderr)
        return 1
    if errors:
        print('\n'.join(f'FAIL: {error}' for error in errors), file=sys.stderr)
        return 1
    print(f'ok: {len(pending)} pending package.nix source default(s) mirror this tree\'s '
          f'flake.lock' + (f' ({", ".join(pending)})' if pending else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
