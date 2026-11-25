#!/usr/bin/env python3
"""Check the sibling clone list against both committed lock formats.

No network is needed: a commit's sibling bill of materials must be consistent
before any clone or build starts. Acknowledging an override with != does not
make a checkout usable by a consumer whose lock requires another revision.

Rules, for every entry with a ref (`name=ref` or `name!=ref`):

  * a sibling repro.lock pins is refused whatever the ref: it is listed as the
    bare `name`. `clone-siblings` resolves a bare name from the committed
    repro.lock, which is the source of truth for that revision, so a ref here
    is a second record of it -- one that `repro lock update` does not move and
    that therefore drifts. A branch or tag is wrong for another reason too: the
    engine refuses a cross-repo producer at any commit but the locked one, so
    such a clone works only while the branch happens to sit on the lock;
  * a 40-hex `ref` for a sibling only flake.lock pins (direct root inputs
    only) must equal that lock's revision;
  * a branch or tag of a sibling only flake.lock names may follow a branch:
    several entries do so on purpose, and their comments say why;
  * a sibling the flake DERIVES rather than locks by name -- CodeTracer, read
    from the organisation's pin (pins/codetracer.json in
    metacraft-github-actions), and codetracer-trace-format-nim, the revision
    that CodeTracer revision's repro.lock names (nix/codetracer-pin.nix) --
    must be listed exactly once, as `name=<that revision>`. clone-siblings
    cannot read the pin, so the revision is written out, and this rule is
    what moves the entry when `nix flake update metacraft-github-actions`
    moves the pin. The revisions come from evaluating the flake
    (`flake_derived`), the same evaluation the build uses; the flake check
    `ct-trace-format-pin-coherence` asks the same question in CI's Nix Build
    job.

A bare `name` entry carries no ref and is resolved by the clone action, so it
is not checked here.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib

SHA = re.compile(r'[0-9a-fA-F]{40}')

# The siblings the flake derives from the CodeTracer pin, and the attribute of
# `packages.<system>.default.sources` that carries each one's revision.
DERIVED_SOURCES = {
    'codetracer': 'codetracerSrc',
    'codetracer-trace-format-nim': 'ctTraceFormatSrc',
}


def parse_derived(text: str) -> dict[str, str]:
    """Validate `nix eval --json` output: every derived sibling, a 40-hex rev."""
    data = json.loads(text)
    if not isinstance(data, dict) or set(data) != set(DERIVED_SOURCES):
        raise ValueError(f'the flake evaluation names {sorted(data) if isinstance(data, dict) else data!r}, '
                         f'expected exactly {sorted(DERIVED_SOURCES)}')
    for name, rev in data.items():
        if not isinstance(rev, str) or not SHA.fullmatch(rev):
            raise ValueError(f'the flake evaluation gives {name} the revision {rev!r}, not a 40-hex commit')
    return data


def flake_derived(root: Path, nix: str = 'nix') -> dict[str, str]:
    """The revisions the flake derives for DERIVED_SOURCES, as its lock stands.

    No `--override-input`: an override is a developer's working tree, while
    `.github/sibling-repos` must name what the committed lock resolves to.
    """
    def run(*args: str) -> str:
        return subprocess.run([nix, *args], cwd=root, check=True, text=True,
                              stdout=subprocess.PIPE).stdout
    system = run('eval', '--impure', '--raw', '--expr', 'builtins.currentSystem')
    fields = ' '.join(f'"{name}" = s.{attr}.rev;' for name, attr in DERIVED_SOURCES.items())
    return parse_derived(run('eval', '--json', '--no-update-lock-file',
                             f'.#packages.{system}.default.sources',
                             '--apply', f's: {{ {fields} }}'))


def check(root: Path, derived: dict[str, str] | None = None) -> list[str]:
    """Return named mismatches for every explicit SHA and every matching lock.

    `derived` maps each sibling the flake derives (rather than locks by name)
    to its revision; see `flake_derived`.
    """
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
    derived = derived or {}
    listed = {name: [] for name in derived}
    for number, raw in enumerate((root / '.github/sibling-repos').read_text().splitlines(), 1):
        entry = raw.split('#', 1)[0].strip()
        if not entry:
            continue
        name, _, revision = entry.partition('=')
        name = name.strip().removesuffix('!').strip()
        revision = revision.strip()
        if name in derived:
            listed[name].append((number, revision))
        if '=' not in entry:
            continue
        pinned = [expected for source, expected in locked.get(name, []) if source == 'repro.lock']
        if pinned:
            errors.append(f'.github/sibling-repos:{number}: {name}={revision}: repro.lock pins '
                          f'{name} at revision {pinned[0]}, and clone-siblings resolves a bare '
                          f'name from repro.lock, so list it as the bare name `{name}`')
            continue
        if not SHA.fullmatch(revision):
            continue
        for source, expected in locked.get(name, []):
            if revision.lower() != expected.lower():
                errors.append(f'.github/sibling-repos:{number}: {name}={revision} conflicts with '
                              f'{source} revision {expected}')
    for name, expected in derived.items():
        found = listed[name]
        if len(found) != 1:
            errors.append(f'.github/sibling-repos lists {name} {len(found)} times; list it exactly '
                          f'once, as `{name}={expected}` (the revision the flake derives from the '
                          f'CodeTracer pin)')
        elif found[0][1].lower() != expected.lower():
            number, revision = found[0]
            errors.append(f'.github/sibling-repos:{number}: {name}={revision or "<bare>"}, but the '
                          f'flake derives {name} at {expected} from the CodeTracer pin '
                          f'(pins/codetracer.json in metacraft-github-actions); set `{name}={expected}`')
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        derived = flake_derived(args.root)
        errors = check(args.root, derived)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f'FAIL: cannot validate sibling lock pins: {error}', file=sys.stderr)
        return 1
    if errors:
        print('\n'.join(f'FAIL: {error}' for error in errors), file=sys.stderr)
        return 1
    print('ok: repro.lock siblings are listed bare, explicit commit pins match flake.lock, and '
          + ', '.join(f'{name}={rev[:12]}' for name, rev in sorted(derived.items()))
          + ' match the CodeTracer pin')
    return 0


if __name__ == '__main__':
    sys.exit(main())
