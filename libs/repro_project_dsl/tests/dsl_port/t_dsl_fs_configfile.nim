## DSL-port M8 acceptance — ``fs.configFile`` records a declaration in
## the runtime sidecar without touching the filesystem.
##
## Pins:
##
##   1. A bare ``fs.configFile(path, content, packageName)`` call from
##      module top level appends one row to the per-package registry
##      with the verbatim path + content + a 16-char cache-key hash.
##      No filesystem effect — symmetric with M4's ``output(path)``
##      "declaration records only, apply phase acts" split.
##
##   2. Calling ``fs.configFile`` from inside a ``build:`` block with
##      ``packageName == ""`` auto-fills the package name from the M7
##      ``currentBuildPackage()`` accessor. This is the ergonomic path
##      the spec'd NDE recipes will use most often (the recipe author
##      doesn't repeat the package name inside every fs.* call).
##
## NOTE: the ``package`` macro emits ``export`` statements + other
## top-level-only Nim, so ``package <name>:`` must sit at module top
## level — not inside a ``test`` body. The M8 auto-fill test follows the
## same captured-state shape M7's ``t_dsl_helper_proc_reads_build_context``
## uses: register the declaration at module-init time, then assert on
## the registry from inside the ``suite``.

import std/[unittest]

import repro_project_dsl
import repro_project_dsl/fs as fs

# Package whose ``build:`` body registers a configFile WITHOUT supplying
# packageName — the M7 ``currentBuildPackage()`` accessor must populate
# the empty field.
package autoFillPkg:
  build:
    fs.configFile(
      path = "/etc/auto.conf",
      content = "x = 1\n"
    )

suite "DSL-port M8 — fs.configFile":

  test "configFile auto-fills packageName from active build context":
    # The ``autoFillPkg`` package declared above ran its ``build:`` body
    # at module-init time INSIDE the M4-emitted
    # ``beginBuildContext("autoFillPkg", "") / try / finally
    # endBuildContext()`` pair. The fs.configFile call there passed an
    # empty packageName, so the auto-fill resolved to ``"autoFillPkg"``.
    #
    # We do NOT call ``resetDslPortFsState`` because the M4 registration
    # happened at module-init time and the test runner cannot re-run it
    # from inside the ``test`` block. This test runs FIRST so subsequent
    # tests that DO reset the state don't wipe the module-init capture.
    let files = registeredConfigFiles("autoFillPkg")
    check files.len == 1
    check files[0].path == "/etc/auto.conf"
    check files[0].content == "x = 1\n"
    check files[0].packageName == "autoFillPkg"

  test "configFile records declaration":
    resetDslPortFsState()

    fs.configFile(
      path = "/etc/myapp.conf",
      content = "key = value\n",
      packageName = "test-pkg",
      artifactName = ""
    )

    let files = registeredConfigFiles("test-pkg")
    check files.len == 1
    check files[0].path == "/etc/myapp.conf"
    check files[0].content == "key = value\n"
    check files[0].packageName == "test-pkg"
    # 16-character content-address hash. ``stableHashHex`` always emits
    # exactly 16 lower-case hex digits.
    check files[0].hashHex.len == 16
