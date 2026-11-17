## A compile whose output depends on an environment variable the compiler
## reads is keyed on that variable, so a second checkout whose environment
## differs misses instead of being served the first checkout's object.
##
## The case a make depfile cannot see. `mathlib/src/add.c` asks
## `__has_include("rbc_feature.h")`; the header exists only in a directory
## that `CPATH` names. The first checkout builds with no `CPATH`, so the
## test is false and nothing about it reaches a depfile (a depfile lists the
## headers that were read, not the ones that were looked for and not found,
## nor the variables that decided where to look). The second checkout's
## build sets `CPATH` to a directory inside it holding the header, so its
## compile includes it and its object differs. Keyed on a depfile, the
## second checkout would find the first's record by its portable key (the
## depfile's path set reads the same there) and take it: a wrong hit. The
## compile edge's evidence is the automatic monitor instead, which records
## that the compiler read `CPATH` (unset in the first build), so the keys
## differ.
##
## Both builds use the engine's default portable configuration (no
## `REPRO_PORTABLE_CACHE`): same-host sharing for content-checked edges, and
## the action environment layered over the invoking one, so `CPATH` reaches
## the compiler. The toolchain is the one the engine realizes into the store
## root (`--tool-provisioning=tarball`).
##
## What it requires: the first build's compile edge is monitored and stores
## its output; the second checkout's compile edge resolves no record
## (`portable-resolved` absent), executes, and produces a different object.
##
## Vacuity guard: the two objects differ (the variable really changed the
## output), and a control case builds the second checkout WITHOUT `CPATH`
## and requires the compile edge to resolve the first checkout's record and
## not execute, so the absence of a resolution above is the key at work, not
## a lookup that never resolves.
##
## Falsifying mutation (run by hand, recorded in the plan): leaving the
## compile edge on its depfile (the lowering's switch to the monitor
## disabled) makes the second checkout resolve the first checkout's record,
## and the main case fails.
##
## No mocks: the built `repro`, the realized compiler and `ar`, real Git
## checkouts, the real monitor and action cache.

import std/[os, strutils, tables, unittest]

import repro_test_support
import library_cache_sharing_fixture

const
  CompileEdge = "ccpp-direct-compile-mathlib-add.c"
  ObjectPath = ".repro/build/mathlib/obj/add.o"
  FeatureSource = "#include \"mathlib/add.h\"\n" &
    "#if __has_include(\"rbc_feature.h\")\n" &
    "#include \"rbc_feature.h\"\n" &
    "#else\n" &
    "#define RBC_FEATURE 0\n" &
    "#endif\n\n" &
    "int add(int a, int b) {\n    return a + b + RBC_FEATURE;\n}\n"

proc exampleSource(): string =
  result = workspaceRootForRepo(ReprobuildRoot) / "reprobuild-examples" /
    "c-cpp-mode3" / "binary-with-library"
  if not fileExists(result / "repro.nim"):
    raise newException(IOError, "the c-cpp-mode3/binary-with-library " &
      "example is not at " & result & "; this test builds it from the " &
      "reprobuild-examples checkout beside this repository")

proc featureCheckout(dest: string) =
  ## The example with the `__has_include` source, and a directory inside
  ## the checkout that holds the header a `CPATH` may name.
  copyCheckout(exampleSource(), dest)
  writeFile(dest / "mathlib" / "src" / "add.c", FeatureSource)
  createDir(dest / "extra" / "include")
  writeFile(dest / "extra" / "include" / "rbc_feature.h",
    "#define RBC_FEATURE 7\n")
  commitCheckout(dest)

proc events(run: BuildRun; id, event: string): seq[string] =
  if id in run.edges:
    for item in run.edges[id].trace:
      if item.event == event:
        result.add(item.detail)

proc firstBuild(host: var SharedHost; first: string): BuildRun =
  # No CPATH, whatever the invoking shell sets (an EMPTY CPATH is not the
  # same: gcc reads an empty element as the working directory).
  result = host.build(first, portable = false, provisioning = "tarball",
    dropEnv = ["CPATH"])
  checkpoint("first build (" & first & "), exit " & $result.code & ":\n" &
    result.output & "\nengine reasons:\n" & engineReasons(result, CompileEdge))
  require result.code == 0
  require result.launched(CompileEdge)
  # The compile edge's evidence is the monitor, and its record stored its
  # output for another checkout.
  check result.edges[CompileEdge].dependencyPolicyKind == "dgAutomaticMonitor"
  check result.events(CompileEdge, "portable-outputs-stored").len == 1

suite "a compiler environment difference is a miss, not a wrong hit":
  test "a checkout whose CPATH reveals a header gets its own compile":
    var host = newSharedHost("repro-env-miss-")
    defer: cleanup(host)
    let first = host.scratch / "first" / "binary-with-library"
    let second = host.scratch / "second" / "elsewhere" / "binary-with-library"
    featureCheckout(first)
    featureCheckout(second)
    discard host.firstBuild(first)

    let two = host.build(second, portable = false, provisioning = "tarball",
      dropEnv = ["CPATH"],
      extraEnv = [("CPATH", second / "extra" / "include")])
    checkpoint("second build (" & second & "), exit " & $two.code & ":\n" &
      two.output & "\nengine reasons:\n" & engineReasons(two, CompileEdge))
    require two.code == 0
    require two.hasEdge(CompileEdge)
    check two.events(CompileEdge, "portable-resolved").len == 0
    check two.launched(CompileEdge)
    # Vacuity guard: the variable changed the object.
    check nonEmptyFile(second / ObjectPath)
    check not sameBytes(first / ObjectPath, second / ObjectPath)

  test "the same checkout without CPATH resolves the first checkout's compile":
    var host = newSharedHost("repro-env-miss-control-")
    defer: cleanup(host)
    let first = host.scratch / "first" / "binary-with-library"
    let second = host.scratch / "second" / "elsewhere" / "binary-with-library"
    featureCheckout(first)
    featureCheckout(second)
    discard host.firstBuild(first)

    let two = host.build(second, portable = false, provisioning = "tarball",
      dropEnv = ["CPATH"])
    checkpoint("second build, exit " & $two.code & ":\n" & two.output &
      "\nengine reasons:\n" & engineReasons(two, CompileEdge))
    require two.code == 0
    require two.hasEdge(CompileEdge)
    check two.events(CompileEdge, "portable-resolved").len == 1
    check not two.launched(CompileEdge)
