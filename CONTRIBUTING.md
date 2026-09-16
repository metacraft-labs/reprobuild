# Contributing to Reprobuild

This repository is the public `metacraft-labs/reprobuild` product repository.
The architecture is specified in a separate, non-public specification
repository (`reprobuild-specs`); when a change alters behavior described
there, update the spec together with the code. If you do not have access to
it, describe the behavior change in your pull request and a maintainer will
carry it into the spec — the public counterpart of those documents is
[`docs/`](./docs), which should be updated in the same change whenever it
covers the behavior you touched.

## Local Tooling

- `just build` compiles all app entry points listed in `apps/entrypoints.txt`.
- `just test` runs the local Nim test suite.
- `just lint` runs repository requirement and Nim source checks.

## Windows HCR Test Environment

Enable the same pinned Python runtime and LLVM compilers used by the Windows
HCR CI job:

```powershell
$env:WINDOWS_DIY_HCR_TESTS = "1"
. ./env.ps1
./scripts/check_windows_python_provisioning.ps1
./scripts/check_windows_llvm_provisioning.ps1
python tests/windows/hx_w0_windows_publication_decision_is_recorded_and_measured.py
```

The opt-in uses the version and archive checksum in
`windows/toolchain-versions.env`, installs only under `WINDOWS_DIY_INSTALL_ROOT`,
and updates only the calling process's environment. It does not install pip,
require administrator access, or change PowerShell execution policies. Without
the opt-in, compiler-only bootstrap is unchanged. LLVM uses the upstream archive
and Windows' built-in `tar.exe`, not a machine-wide installer.

Install Visual Studio's x64 C++ build tools and the Windows SDK's x64 Debugging
Tools for Windows (`cdb.exe`) separately. The opt-in checks those prerequisites
using the HCR drivers' own discovery rules and fails before reporting the
environment ready if any required tool is missing. It does not install MSVC or
the debugger, or convert missing prerequisites into skipped tests. Recheck with
`python scripts/check_windows_hcr_environment.py` after changing installed tools.

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

## Adding a test file in a new place

The two refreshes above both answer "has the checked-in description of the
suite gone stale?", and both derive the set they compare from
`repro_tests.nim`. That file is written by `scripts/generate_test_edges.nim`
from a filesystem walk. A test file the walk does not pick up is therefore
outside both of them **by construction** — it is not reported as missing, it
is not reported at all — and because nothing gives it a build edge, nothing
compiles it and nothing runs it either. A green `just lint` says nothing
whatsoever about it.

Two files sat in exactly that state: `apps/repro-harvest-apt/tests/
t_c2_signature.nim` (6 cases) and `recipes/sandbox-tools/
test_sandbox_tools.nim` (12 cases). Both pass. Neither had ever been run by
the suite, because `apps` was not a walked root and the `recipes` rule
accepted only `recipes/packages/source/<pkg>/`.

`scripts/check_suite_case_counts.sh` now also runs

```bash
python3 scripts/reprobuild_suite_inventory.py --check-declared-sources
```

which walks the **tree** rather than `repro_tests.nim`, and fails when a
test-shaped source is in no build edge. Its rule is deliberately wider than
the generator's: a `.nim` file whose stem starts with `t_` or `test_`, living
inside a directory named `tests` (or anywhere under `recipes/`), is a test.
A copy of the generator's own accept predicates could only ever have agreed
with the generator's blind spots.

So when you add a test **in a directory that has never held one**, regenerate
the edge table and commit `repro_tests.nim` with the change:

```bash
nim r scripts/generate_test_edges.nim
```

If the generator runs and still does not pick your file up, the accept
predicates in `scripts/generate_test_edges.nim` are what need widening. That
is the defect — do not work around it by renaming the file out of the gate's
view. A test that needs its own `--path` or `-d:` flag carries it in a
sibling `<test>.nim.cfg`; `TestSpec` has no field for either, and every build
route honours the `.cfg`.

## Why these refreshes are enforced

Forgetting either refresh used to be somebody else's problem: `just lint` went
red for everyone, and the next branch had to carry the regeneration in order
to land. `scripts/check_suite_case_counts.sh` runs all three checks at four
points, so it cannot get that far:

- as a **pre-push hook** installed by the Nix dev shell (`flake.nix`,
  `pre-commit-check`), which refuses the push and prints the commands above;
- as its own hosted workflow, `.github/workflows/suite-case-counts.yml`, which
  has no concurrency cancellation and so reaches a verdict on every commit;
- as an early step of the CI lint job, ahead of the whole-tree compile;
- inside `just lint`, where the case-count half always ran.

All three are source scans — no compiler, no built binaries, a couple of
minutes on the full tree against the hours a build costs — which is what
makes them affordable at every push.

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
