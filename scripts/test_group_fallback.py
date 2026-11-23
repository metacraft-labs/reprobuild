#!/usr/bin/env python3
"""Compile the members of every group test binary that failed to build, singly.

usage: test_group_fallback.py --repro <repro> [--root .] [--bin-dir build/test-bin]
                              [--timeout-seconds N] [--dry-run]

WHY THIS EXISTS
---------------
Test-Binary-Grouping M2 (reprobuild-specs ``spec/Test-Binary-Grouping.md``)
compiles up to fifty test sources into one ``build/test-bin/t_group_*``
binary. One member that does not compile then fails the whole group's
compile, and without a fallback the other 49 members' cases would silently
not run. The owner approved G = 50 on the condition that this costs TIME, not
COVERAGE.

So the recipe registers every grouped member's own compile edge as well, in a
collection named ``test-group-fallback-<group>``. ``scripts/run_tests.sh``
runs this script after ``.#test-builds`` and after
``drop_failed_test_binaries.py`` has removed the binaries of failed actions:
for every group whose binary is absent, it builds that group's fallback
collection, so each member gets its own binary at ``spec.binary`` exactly as
before grouping existed. A member whose single compile fails is reported by
NAME -- the failure is attributed to the file that broke the group, not to the
group -- and every other member runs.

``scripts/prune_undeclared_test_binaries.py`` declares a grouped member's own
binary only while its group binary is absent, so these fallback binaries are
kept, and per-file binaries left by an earlier revision beside a group binary
are not.

Exit 0 when every group either built or fell back without a member failing;
1 when some member could not be built singly either (each named on stderr with
``::error::``); 2 on a usage or environment error. ``run_tests.sh`` carries a
non-zero status to the end of the run, like the build phase's own.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import pathlib
import subprocess
import sys

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
INVENTORY = SCRIPT_DIR / "reprobuild_suite_inventory.py"

_spec = importlib.util.spec_from_file_location("reprobuild_suite_inventory", INVENTORY)
assert _spec is not None and _spec.loader is not None
inventory = importlib.util.module_from_spec(_spec)
sys.modules["reprobuild_suite_inventory"] = inventory
_spec.loader.exec_module(inventory)

FALLBACK_COLLECTION_PREFIX = "test-group-fallback-"


def exe(path: pathlib.Path) -> pathlib.Path:
    return path.with_name(path.name + ".exe") if os.name == "nt" else path


def groups_of(root: pathlib.Path) -> dict[str, list[tuple[str, str]]]:
    """group stem -> [(source, own binary)] in source order."""
    nim_specs, _ = inventory.parse_repro_tests(root)
    groups: dict[str, list[tuple[str, str]]] = {}
    for spec in nim_specs:
        if spec.group:
            groups.setdefault(spec.group, []).append((spec.source, spec.binary))
    return groups


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".")
    parser.add_argument("--bin-dir", default="build/test-bin")
    parser.add_argument("--repro", required=True,
                        help="the repro executable that builds the collections")
    parser.add_argument("--timeout-seconds", type=int, default=0,
                        help="bound on each fallback build; 0 = none")
    parser.add_argument("--only", action="append", default=[], metavar="GROUP",
                        help="consider only these group stems (repeatable)")
    parser.add_argument("--dry-run", action="store_true",
                        help="name the groups that would fall back; build nothing")
    args = parser.parse_args(argv)

    root = pathlib.Path(args.root).resolve()
    bin_dir = pathlib.Path(args.bin_dir)
    if not bin_dir.is_absolute():
        bin_dir = root / bin_dir

    groups = groups_of(root)
    if args.only:
        unknown = sorted(set(args.only) - set(groups))
        if unknown:
            print(f"test_group_fallback: not a declared group: {', '.join(unknown)}",
                  file=sys.stderr)
            return 2
        groups = {g: groups[g] for g in args.only}
    failed_groups = [g for g in sorted(groups) if not exe(bin_dir / g).exists()]
    print(f"test_group_fallback: {len(groups)} group binaries declared, "
          f"{len(failed_groups)} absent", file=sys.stderr)
    status = 0
    for group in failed_groups:
        members = groups[group]
        collection = FALLBACK_COLLECTION_PREFIX + group
        print(f"::error:: group test binary NOT BUILT: {group}; compiling its "
              f"{len(members)} member(s) singly (.#{collection})", file=sys.stderr)
        if args.dry_run:
            continue
        # A member binary already on disk was not built by THIS build: it is
        # either a per-file binary from an earlier revision or a stale
        # fallback. Remove it so that what exists afterwards is this build's.
        for _, binary in members:
            stale = exe(root / binary)
            if stale.exists() or stale.is_symlink():
                stale.unlink()
        cmd = [args.repro, "build", "--tool-provisioning=path", "--daemon=off",
               "--no-runquota", f".#{collection}"]
        try:
            completed = subprocess.run(
                cmd, cwd=str(root),
                timeout=args.timeout_seconds if args.timeout_seconds > 0 else None)
            build_status = completed.returncode
        except subprocess.TimeoutExpired:
            build_status = 124
        except OSError as err:
            print(f"test_group_fallback: cannot run {args.repro}: {err}",
                  file=sys.stderr)
            return 2
        broken = [source for source, binary in members
                  if not exe(root / binary).exists()]
        for source in broken:
            # The failure belongs to the member: this is the file whose
            # compile broke its group (or one of them).
            print(f"::error:: test source does not compile on its own: {source} "
                  f"(member of {group}; its cases do not run)", file=sys.stderr)
        built = len(members) - len(broken)
        print(f"test_group_fallback: {group}: {built}/{len(members)} member(s) "
              f"built singly (repro exit {build_status})", file=sys.stderr)
        if broken or build_status != 0:
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
