## A packaged `repro` does not hand the projects it builds its own source trees.
##
## WHY. The Nix wrapper used to `--set-default` `CODETRACER_TRACE_FORMAT_NIM_SRC`,
## `IO_MON_SRC`, `SHM_GSET_SRC`, `SHM_QUEUE_SRC` and
## `TEST_CERTIFICATES_TOOLS_SRC` to the copies reprobuild was built against.
## Those are also project variables: codetracer's `config.nims` takes each of
## them, when set, ahead of the workspace sibling. A `repro build`'s actions
## inherit the wrapper's environment, so a caller that left one unset got
## reprobuild's snapshot. Measured 2026-11-25 with repro 0.2.31: codetracer's
## `ct-binary` compiled `print_trace.nim` against reprobuild's trace-format
## copy and failed on a routine the pinned sibling had (reprobuild-specs issue
## 2026-11-25-a-daemon-hosted-codetracer-build-compiles-print-trace-against-a-
## trace-format-copy-without-formarkerevent).
##
## WHAT IS PINNED HERE.
##
## * No wrapper reprobuild ships sets a project-visible name: not the Nix
##   derivation's `--set-default` list, not the native packages' wrapper
##   values, not the runtime contract's variable list. Each sets the private
##   `REPRO_ENGINE_` spelling instead.
## * The engine turns a private name back into the public one by SEEDING it
##   (`engineSourceRootSeeds` then `seedSourcePackageEnvironment`), so the
##   value is recorded as the engine's own and a caller's value still wins.
## * The build engine withholds every seeded root from the actions it
##   launches (`withheldSeededSourceRoots`), and never a caller's.

import std/[os, strutils, unittest]

import repro_build_engine
import repro_project_dsl
import repro_dsl_stdlib/packaging
import repro_interface_artifacts
import ./packaging_test_support

proc restoreEnv(name, value: string; present: bool) =
  if present: putEnv(name, value) else: delEnv(name)

suite "a packaged repro keeps project-visible source roots private":
  test "the Nix wrapper sets none of the project names, and each private one":
    let names = packageNixWrapperVariables()
    checkpoint("wrapper variables: " & names.join(" "))
    # Positive control: the extractor read the real list.
    check "REPROBUILD_SOURCE_ROOT" in names
    for public in ProjectVisibleSourceRootNames:
      check public notin names
      check engineSourceRootName(public) in names

  test "the native packages and the runtime contract agree":
    var nativeNames: seq[string]
    let dist = newReprobuildDistribution("0.1.3", toLinux, prefix = "/usr")
    for (name, _) in reprobuildToolWrapperValues(dist):
      nativeNames.add(name)
    check "REPROBUILD_SOURCE_ROOT" in nativeNames
    for public in ProjectVisibleSourceRootNames:
      check public notin nativeNames
      check engineSourceRootName(public) in nativeNames
      check public notin ReprobuildWrapperVariables
      check engineSourceRootName(public) in ReprobuildWrapperVariables

  test "the engine seeds the public name, and the build withholds it":
    let root = getTempDir() / ("repro-engine-root-" & $getCurrentProcessId())
    createDir(root)
    defer: removeDir(root)
    let private = engineSourceRootName("IO_MON_SRC")
    var saved: seq[(string, string, bool)]
    for name in ["IO_MON_SRC", private, "SHM_QUEUE_SRC",
                 engineSourceRootName("SHM_QUEUE_SRC"),
                 SeededSourceEnvironmentVar]:
      saved.add((name, getEnv(name), existsEnv(name)))
    defer:
      for (name, value, present) in saved:
        restoreEnv(name, value, present)
    for (name, _, _) in saved:
      delEnv(name)

    # The wrapper supplied IO_MON_SRC privately; the caller set SHM_QUEUE_SRC
    # itself, and the wrapper's private copy of it must not displace that.
    putEnv(private, root)
    putEnv("SHM_QUEUE_SRC", "/caller/shm-queue")
    putEnv(engineSourceRootName("SHM_QUEUE_SRC"), root)
    seedSourcePackageEnvironment(engineSourceRootSeeds())

    check getEnv("IO_MON_SRC") == root
    check getEnv("SHM_QUEUE_SRC") == "/caller/shm-queue"
    check "IO_MON_SRC" in seededSourcePackageEnvironmentNames()
    check "SHM_QUEUE_SRC" notin seededSourcePackageEnvironmentNames()

    let withheld = withheldSeededSourceRoots()
    checkpoint("withheld: " & withheld.join(" "))
    check "IO_MON_SRC=" in withheld
    check "SHM_QUEUE_SRC=" notin withheld
    for entry in withheld:
      check entry.endsWith("=")

    # An inner repro, started by an action with the root blanked, seeds its
    # own again: empty counts as unset.
    putEnv("IO_MON_SRC", "")
    delEnv(SeededSourceEnvironmentVar)
    seedSourcePackageEnvironment(engineSourceRootSeeds())
    check getEnv("IO_MON_SRC") == root
