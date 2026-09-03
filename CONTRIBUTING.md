# Contributing to Reprobuild

This repository is the public `metacraft-labs/reprobuild` product repository.
The architecture is specified in
[metacraft-labs/reprobuild-specs](https://github.com/metacraft-labs/reprobuild-specs);
when a change alters behavior described there, update the spec together with
the code.

## Local Tooling

- `just build` compiles all app entry points listed in `apps/entrypoints.txt`.
- `just test` runs the local Nim test suite.
- `just lint` runs repository requirement and Nim source checks.

## Adding or removing test cases

`scripts/reprobuild-suite-static-case-counts.tsv` records how many test cases
each declared test source contains. When you add or remove a `test "…":`
declaration — or add or remove a test source — refresh it and commit the diff
alongside the change:

```bash
python3 scripts/reprobuild_suite_inventory.py --write-static-case-counts
```

It needs no built binaries and takes well under a minute. Review what it
writes: a row that **decreases or disappears** means test cases left the
suite, which is the event this file exists to make visible. The check runs in
`tests/unit/test_reprobuild_suite_inventory.py` and names the source and both
numbers when it fails, so there is never a total to reconcile by hand.

## Adding or removing test sources

Enrolling a new test source in `repro_tests.nim` — or renaming or withdrawing
one — also moves
`benchmarks/reports/reprobuild-suite-m0-inventory-sources.json`, the tracked
record of the suite's entry set. Refresh it the same way, and commit the diff
with the change:

```bash
python3 scripts/reprobuild_suite_inventory.py --write-inventory-sources
```

It records, per source: language, owner, output binary, class, classification
reason, static case count, dependency shape and whether the test body reaches
a compiler. Like the case-count baseline, it is a pure source scan — no
compiler, no built binaries, no nix.

It exists as a separate file because the full M0 inventory beside it,
`benchmarks/reports/reprobuild-suite-m0-inventory.json`, cannot be
regenerated without building every test binary: its case counts come from
each built binary's own `--list-json`. That artifact went stale six times, and
every one of the six was an entry-set change — visible to a source scan, but
fixable only by a four-hour build, so nothing gated it. Splitting the document
along that line is what lets the entry set be gated at every push while the
catalog-derived half stays an output of the job that already builds
everything. **Do not regenerate the full inventory by hand**; `just test`
produces it.

## Why these two refreshes are enforced

Forgetting either refresh used to be somebody else's problem: `just lint` went
red for everyone, and the next branch had to carry the regeneration in order
to land. `scripts/check_suite_case_counts.sh` runs both checks at four points,
so it cannot get that far:

- as a **pre-push hook** installed by the Nix dev shell (`flake.nix`,
  `pre-commit-check`), which refuses the push and prints the commands above;
- as its own hosted workflow, `.github/workflows/suite-case-counts.yml`, which
  has no concurrency cancellation and so reaches a verdict on every commit;
- as an early step of the CI lint job, ahead of the whole-tree compile;
- inside `just lint`, where the case-count half always ran.

Both are source scans — no compiler, no built binaries, a couple of minutes on
the full tree against the hours a build costs — which is what makes them
affordable at every push.

## Nix Dev Shell

`nix develop` activates the compiler and library toolchain. To handle private
dependency overrides on development hosts, `scripts/dev-shell.sh` auto-detects
sibling checkouts:

```bash
# Clone the sibling native recorder (if developer credentials are configured):
gh repo clone metacraft-labs/codetracer-native-recorder ../codetracer-native-recorder

# Enter the dev shell:
bash scripts/dev-shell.sh
```

The build needs this shell:

- Run the build **from inside** the dev shell. `just build` / `just bootstrap`
  invoked outside it fail early on a vendored header the shell puts on the
  include path (e.g. `cannot open file: bearssl/rand`). When your shell is not
  already activated, use `nix develop --command just build`.
- The **resulting binary does not**. `./build/bin/repro` `dlopen`s `libclingo`
  (the concretizer) at startup and `libzstd` (the binary-cache client) on
  demand, both by bare soname, but `scripts/build_apps.sh` threads their
  directories into the binary's own RPATH at link time, so a bootstrapped
  `repro` runs from any shell — including the far side of an SSH transport,
  where `sshd` does not propagate `LD_LIBRARY_PATH`. If you ever see
  `could not load: libclingo.so`, do **not** paper over it by exporting the
  dev shell's `LD_LIBRARY_PATH`: the binary was linked without that RPATH, and
  `tests/integration/t_repro_runtime_dlopen_without_library_path.nim` is the
  gate that should have caught it.
- The Nix-installed `repro` on `PATH` can lag your checkout. When behavior
  disagrees with the specs, check `repro --version` and prefer `./build/bin/repro`.
