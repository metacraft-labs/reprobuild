## The fixture package of `test_cs_m14_shim_answers_tests_entry`.
##
## Four test binaries, each collected through `runPerTest`:
##
## * `shim_suite`: `suite` / `test` of `ct_test_unittest_parallel`, nothing
##   else. The shim answers nim-entrypoints' `tests` entry itself.
## * `shim_entry_suite`: the same tests in a `tests:` block of a program built
##   with nim-entrypoints (a `testCase` and a `main:` besides), which answers
##   the entry, with the shim as the block's framework.
## * `plain_suite`: the same tests over `std/unittest` alone, whose
##   `std/unittest` (the pinned codetracer Nim fork's) answers the entry.
## * `no_entry_suite`: the same tests in a program without the entry, which
##   reads every argument as a test filter, as a `std/unittest` that does not
##   know the entry does. It is run as a whole.
##
## The test copies this package to a scratch directory and fills in the
## placeholders before building it:
##
## * `__SHIM_SRC__`: `ct_test_unittest_parallel`'s `src/` in this checkout;
## * `__ENTRYPOINTS_SRC__`: nim-entrypoints' `src/` directory, as this
##   repository's `config.nims` finds it;
## * `__NATIVE_BACKEND__`: the C compiler Nim calls (`gcc`, or `clang` on
##   macOS), which the compile edges name as a tool they use.

import repro_project_dsl
import ct_test_nim_unittest

const
  ShimSrc = "__SHIM_SRC__"
  EntrypointsSrc = "__ENTRYPOINTS_SRC__"

package cs_m14_shim_tests_entry:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "__NATIVE_BACKEND__"

  build:
    let shim = buildNimUnittest.build(
      source = "src/shim_suite.nim",
      binary = "build/test-bin/shim_suite",
      paths = @[ShimSrc],
      actionId = "cs_m14_shim.compile.shim")
    let entry = buildNimUnittest.build(
      source = "src/shim_entry_suite.nim",
      binary = "build/test-bin/shim_entry_suite",
      paths = @[ShimSrc, EntrypointsSrc],
      actionId = "cs_m14_shim.compile.entry")
    let plain = buildNimUnittest.build(
      source = "src/plain_suite.nim",
      binary = "build/test-bin/plain_suite",
      actionId = "cs_m14_shim.compile.plain")
    let noEntry = buildNimUnittest.build(
      source = "src/no_entry_suite.nim",
      binary = "build/test-bin/no_entry_suite",
      actionId = "cs_m14_shim.compile.noentry")
    discard collect("test", [
      shim.testBinary.runPerTest(actionId = "cs_m14_shim.tests.shim"),
      entry.testBinary.runPerTest(actionId = "cs_m14_shim.tests.entry"),
      plain.testBinary.runPerTest(actionId = "cs_m14_shim.tests.plain"),
      noEntry.testBinary.runPerTest(actionId = "cs_m14_shim.tests.noentry")])
