# ct_test_nim_unittest

Nim `std/unittest` adapter for the codetracer test framework.

Exposes:

- `NimUnittestBinary` — the typed handle reprobuild binds to a build edge
  via `outputs testBinary is NimUnittestBinary, binary`.
- `buildNimUnittest` — a reprobuild DSL `executable` that builds a Nim
  unittest test binary from a `.nim` source file.
- UFCS dispatch procs: `run(self: NimUnittestBinary; …)`,
  `list(self: NimUnittestBinary; …)`, `runTest(self: NimUnittestBinary; …)`,
  `runPerTest(self: NimUnittestBinary; …)`.

## Running a binary's tests one by one

A test binary built with
[nim-entrypoints](https://github.com/metacraft-labs/nim-entrypoints)
(`import entrypoints/tests`, `testCase`s and a `main:`) answers its `tests`
entry: `--entrypoint=tests --list` names its tests and
`--entrypoint=tests --run-exact=<name>` runs one of them. `runPerTest` turns
that into the build graph:

```nim
let edge = buildNimUnittest.build(
  source = "tests/suite.nim",
  binary = "build/test-bin/suite",
  paths = @["<nim-entrypoints>/src"])
discard collect("test", [edge.testBinary.runPerTest(actionId = "suite")])
```

A listing edge (`suite.list`) runs `repro-tests-fragment`, which lists the
binary's tests and writes a dynamic graph fragment with one action per test
(`suite.test.<name>`). The returned collector (`suite`) creates those actions
when it is about to run and waits for every one. Each test is monitored,
cached and reported on its own, keyed on the binary and what it read, and a
failing test fails only its own action. A binary that lists no tests, or a
name twice, fails the listing edge. `libs/ct_test_nim_unittest/src/
ct_test_nim_unittest/tests_fragment.nim` describes the records.

## Usage from a reprobuild package

```nim
# In a reprobuild package's repro.nim (or generated repro.tests.nim):
import ct_test_nim_unittest

package myProject:
  uses:
    "nim >=2.2 <3.0"
    "ct-test-nim-unittest"

  build:
    let edge = buildNimUnittest(
      source = "tests/foo.nim",
      binary = "build/test-bin/foo")
    # `edge.testBinary` is statically typed `NimUnittestBinary`.
    # The path is populated at action emission.

    edge.testBinary.run()           # emits the execution edge
```

## Standalone usage (no reprobuild)

The library compiles and the dispatch procs work the same way when called
without going through reprobuild's typed-output machinery. A user can
build a unittest binary by any conventional means and wrap it manually:

```nim
let bin = NimUnittestBinary(path: "build/test-bin/foo")
discard bin.run()      # invokes the binary, returns a TestResultsHandle
```

In standalone use the dispatch procs invoke the binary directly via
`osproc`; in reprobuild mode they emit ordinary typed-tool edges.

## Implementation notes

The `buildNimUnittest` typed-tool's `cli:` block declares `output binary`
and an `outputs testBinary is NimUnittestBinary, binary` typed output.
The `build:` body lowers to a `nim_module.nim.c(...)` call with the
codetracer per-test conventions (`threadsOn`, `hintsOff`, `warningsOff`).

The UFCS dispatch procs (`run`, `list`, `runTest`) are currently
hand-authored — see the ~25-line boilerplate pattern documented in the
Typed-Outputs M1 milestone outcome notes. A follow-on milestone in
reprobuild will auto-generate this boilerplate from a CLI-only
`executable NimUnittestBinary` declaration; today the manual shape is
the canonical form.
