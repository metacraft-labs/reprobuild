## `repro build --tool-provisioning=tarball` on Linux refuses to fall through
## to a C toolchain source recipe, and builds nothing.
##
## reprobuild-pm Dependency-Provisioning-In-Build-Graph.md §4.3, "Not the
## Linux C toolchain" (decided by the operator, Zahary Karadjov,
## 2026-10-31): `gcc`, `make` and `binutils` come from the host on Linux,
## because their source recipes need each other and no catalogued tarball
## breaks the cycle. `repro build` refuses where it decides the
## fall-through, naming the rule and the remedy, BEFORE its auto-recurse
## pass builds the recipe.
##
## Black-box, modelled on `t_tarball_mode_builds_a_fall_through_source_
## recipe`: this checkout's real `repro` builds a consumer whose `make`
## dependency is a stub with no realization, so tarball mode has no tarball
## for the host and would fall through to the catalog's `make` recipe, which
## `REPRO_FROM_SOURCE_ROOT` selects. That recipe is a one-file builtin copy,
## so had the fall-through been taken it would have been built -- the
## missing artifact is what tells the refusal apart from a later failure.
## Both recipes use only builtin actions; nothing is mocked.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

const reproBinary = "build" / "bin" / addFileExt("repro", ExeExt)

const makeRecipe = """
import repro_project_dsl

package makeSource:
  build:
    let materialize = fs.copyFile(source = "make.txt",
      output = ".repro/output/install/usr/bin/make",
      actionId = "make.materialize")
    defaultBuildAction(materialize)
"""

const consumerRecipe = """
import repro_project_dsl

package consumer:
  usesImportPath "stubs"
  nativeBuildDeps:
    "make"
  build:
    let copy = buildAction(id = "consumer.copy",
      call = publicCliCall("reprobuild.builtin", "fs", "copyFile",
        "reprobuild.builtin.fs.copyFile", @[
          inputArg("source", "input.txt"),
          outputArg("output", "build/result.txt")]),
      inputs = @["input.txt"],
      outputs = @["build/result.txt"], toolIdentityRefs = @["make"])
    defaultBuildAction(copy)
"""

suite "tarball mode refuses the Linux C toolchain":
  test "a make with no Linux tarball is refused by the scope rule, unbuilt":
    if hostOS != "linux":
      skip("the Linux C toolchain scope rule applies to Linux hosts only")
    else:
      let binary = absolutePath(reproBinary)
      require fileExists(binary)
      let root = createTempDir("tarball-scope-", "")
      defer: removeDir(root)
      createDir(root / "catalog/make")
      createDir(root / "consumer/stubs")
      writeFile(root / "catalog/make/repro.nim", makeRecipe)
      writeFile(root / "catalog/make/make.txt", "not a make\n")
      writeFile(root / "consumer/repro.nim", consumerRecipe)
      writeFile(root / "consumer/input.txt", "x\n")
      writeFile(root / "consumer/stubs/make.nim",
        "import repro_project_dsl\npackage make:\n  discard\n")
      let artifact = root / "catalog/make/.repro/output/install/usr/bin/make"

      var env = newStringTable(modeCaseSensitive)
      for key, value in envPairs(): env[key] = value
      env["REPRO_FROM_SOURCE_ROOT"] = root / "catalog"
      env["REPROBUILD_WORK_ROOT"] = root / "work"
      env["REPROBUILD_ACTION_CACHE_ROOT"] = root / "action-cache"
      env["REPRO_LOCAL_STORE"] = root / "store"
      env["REPRO_CACHE_DISABLE"] = "1"
      env["REPROBUILD_NO_RUNQUOTA"] = "1"
      env["REPRO_INTERFACE_COMPILE_TIMEOUT_SECONDS"] = "7200"
      let res = execCmdEx(quoteShellCommand([binary, "build", "--daemon=off",
        "--tool-provisioning=tarball", "--progress=quiet", "--log=actions"]),
        env = env, workingDir = root / "consumer")
      checkpoint(res.output)
      check res.exitCode != 0
      check "does not realize the C toolchain on a Linux host" in res.output
      check "Not the Linux C toolchain" in res.output
      check "--tool-provisioning=path" in res.output
      # Refused when the fall-through was decided: the recipe it would have
      # fallen through to was never built.
      check not fileExists(artifact)
      check not fileExists(root / "consumer/build/result.txt")
