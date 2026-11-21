## The fixture package of `test_cs_m14_repro_collects_tests_per_entry`.
##
## One test binary, built with nim-entrypoints from
## `src/per_entry_suite.nim` (the `testCase`s `alpha`, `beta` and `gamma`,
## and a `main:`), whose tests reach the `test` collection through
## `runPerTest`: `repro test` lists them through the binary's `tests` entry
## and runs each as an action of its own.
##
## The test copies this package to a scratch directory and fills in the
## three placeholders before building it:
##
## * `__ENTRYPOINTS_SRC__`: nim-entrypoints' `src/` directory, as this
##   repository's `config.nims` finds it;
## * `__NATIVE_BACKEND__`: the C compiler Nim calls (`gcc`, or `clang` on
##   macOS), which the compile edge names as a tool it uses;
## * `__TESTS_FRAGMENT_PRODUCER__`: empty, so the listing edge runs the
##   `repro-tests-fragment` beside the engine, or another producer.

import repro_project_dsl
import ct_test_nim_unittest

const
  EntrypointsSrc = "__ENTRYPOINTS_SRC__"
  TestsFragmentProducer = "__TESTS_FRAGMENT_PRODUCER__"

package cs_m14_tests_per_entry:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "__NATIVE_BACKEND__"

  build:
    let suite = buildNimUnittest.build(
      source = "src/per_entry_suite.nim",
      binary = "build/test-bin/per_entry_suite",
      paths = @[EntrypointsSrc],
      actionId = "cs_m14.compile")
    let perTest = suite.testBinary.runPerTest(
      actionId = "cs_m14.tests",
      producer = TestsFragmentProducer)
    discard collect("test", [perTest])
