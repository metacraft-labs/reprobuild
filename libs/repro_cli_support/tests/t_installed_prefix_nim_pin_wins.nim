## A project's pinned provider compiler wins over the installed prefix's Nim
## (reprobuild-pm Distribution-And-Packaging.md §5.3, amendment N3, approved
## by Zahary Karadjov, 2026-11-04: "A project pin (rule 1) still wins").
##
## The pin is applied at the engine's entry, before any dispatch
## (`project_pins.applyProjectPinsAtEntry`), by `publishPinnedProviderNim`;
## the bootstrap runs later, before the interface extraction. This drives
## that order with the pin's own publisher rather than by setting the
## variable by hand, so a bootstrap that overwrote a published pin with the
## prefix's compiler fails here (checked by mutation: replacing the
## bootstrap's "only when unset" guard with an unconditional prefix route
## turns the case red).
##
## The variable the prefix route sets, `REPRO_INSTALLED_PREFIX_NIM`, is the
## evidence a later `uses: nim` check reads. A process can inherit it from
## an engine that DID take the prefix route; once the pin is published it
## would then judge the recipe against a compiler that is not the one in
## use, so publishing the pin clears it (A15 round-3 verification,
## 2026-11-06; checked by removing the clear).
##
## A missing gcc fails a gate run (`REPROBUILD_GATE_RUN=1`) and is reported
## SKIPPED elsewhere.
##
## *Mocking.* None: a real installed-prefix layout; the shipped `bin/nim`
## and the pinned compiler are files the route never runs.

import std/[os, tempfiles, unittest]

import repro_cli_support/project_pins
import repro_core/installed_prefix_nim
import repro_test_support/reasoned_skip
import repro_interface_artifacts
import repro_tool_profiles

const ForkRev = "197089cda27f656f8010e2b31b40e0e12f3f209b"

template withGcc(gcc: untyped; body: untyped) =
  let gcc = findExe("gcc")
  if gcc.len == 0:
    if getEnv("REPROBUILD_GATE_RUN") == "1":
      checkpoint("gcc is not on PATH in a gate run; the bootstrap probes " &
        "its C compiler")
      check false
    else:
      skip("gcc is not on PATH; the bootstrap probes its C compiler")
  else:
    body

proc installedPrefix(root: string): string =
  ## An installed prefix shipping the recorded fork, at `root/prefix`.
  result = root / "prefix"
  createDir(result / "bin")
  writeFile(result / "bin" / "reprobuild", "")
  createDir(result / "nim" / "bin")
  createDir(result / "nim" / "lib" / "system")
  writeFile(result / "nim" / "bin" / "nim", "")
  writeFile(result / "nim" / ".nim-fork-revision", ForkRev & "\n")
  writeFile(result / "nim" / "lib" / "system" / "compilation.nim",
    "const\n  NimMajor* {.intdefine.}: int = 2\n" &
    "  NimMinor* {.intdefine.}: int = 3\n" &
    "  NimPatch* {.intdefine.}: int = 1\n")
  createDir(result / "share" / "repro")
  writeFile(result / "share" / "repro" / "cross-build-info",
    "nim_fork=" & ForkRev & "\n")

template withPinScenario(inherited: string; body: untyped) =
  ## A prefix, a pinned compiler, and the environment the entry and the
  ## bootstrap read, restored afterwards. `inherited` is the
  ## `REPRO_INSTALLED_PREFIX_NIM` the process starts with ("" for none).
  withGcc(gcc):
    let root {.inject.} = createTempDir("prefix-nim-pin-", "")
    defer: removeDir(root)
    let prefix = installedPrefix(root)
    let pinned {.inject.} = root / "store" / "nim" / "bin" / "nim"
    createDir(pinned.parentDir)
    writeFile(pinned, "")
    let names = ["REPRO_NIM_COMPILER", "REPRO_BOOTSTRAP_CC",
      "REPRO_PUBLIC_CLI_PATH", InstalledPrefixNimEnvVar]
    var saved: seq[(string, bool, string)]
    for n in names: saved.add((n, existsEnv(n), getEnv(n)))
    defer:
      for (n, present, value) in saved:
        if present: putEnv(n, value) else: delEnv(n)
    delEnv("REPRO_NIM_COMPILER")
    if inherited.len > 0: putEnv(InstalledPrefixNimEnvVar, inherited)
    else: delEnv(InstalledPrefixNimEnvVar)
    putEnv("REPRO_BOOTSTRAP_CC", gcc)
    putEnv("REPRO_PUBLIC_CLI_PATH", prefix / "bin" / "reprobuild")
    body

suite "a project pin wins over the installed prefix's Nim":
  test "the pinned compiler is kept, and the prefix route is not recorded":
    withPinScenario(""):
      # Entry: the lock's pin is realized and published.
      publishPinnedProviderNim(pinned)
      # Later: the bootstrap before the interface extraction.
      ensureBootstrapToolchainEnv(tpmPathOnly, root / "tool-store")
      check getEnv("REPRO_NIM_COMPILER") == pinned
      check not existsEnv(InstalledPrefixNimEnvVar)

  test "an inherited prefix-route record is cleared when the pin is published":
    withPinScenario("2.3.1"):
      publishPinnedProviderNim(pinned)
      ensureBootstrapToolchainEnv(tpmPathOnly, root / "tool-store")
      check getEnv("REPRO_NIM_COMPILER") == pinned
      check not existsEnv(InstalledPrefixNimEnvVar)
      # So a recipe whose range excludes the prefix's release is not refused
      # on behalf of a compiler that is not the one compiling it.
      requireProjectNimAdmitsInstalledPrefixNim(@[InterfaceToolUse(
        rawConstraint: "nim ==2.2.10", packageSelector: "nim",
        executableName: "nim")])
