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
## *Mocking.* None: a real installed-prefix layout; the shipped `bin/nim`
## and the pinned compiler are files the route never runs.

import std/[os, tempfiles, unittest]

import repro_cli_support/project_pins
import repro_core/installed_prefix_nim
import repro_tool_profiles

const ForkRev = "197089cda27f656f8010e2b31b40e0e12f3f209b"

suite "a project pin wins over the installed prefix's Nim":
  test "the pinned compiler is kept, and the prefix route is not recorded":
    let gcc = findExe("gcc")
    if gcc.len == 0:
      checkpoint("gcc is not on PATH; the bootstrap probes its C compiler")
      check getEnv("REPROBUILD_GATE_RUN") != "1"
    else:
      let root = createTempDir("prefix-nim-pin-", "")
      defer: removeDir(root)
      let prefix = root / "prefix"
      createDir(prefix / "bin")
      writeFile(prefix / "bin" / "reprobuild", "")
      createDir(prefix / "nim" / "bin")
      createDir(prefix / "nim" / "lib" / "system")
      writeFile(prefix / "nim" / "bin" / "nim", "")
      writeFile(prefix / "nim" / ".nim-fork-revision", ForkRev & "\n")
      writeFile(prefix / "nim" / "lib" / "system" / "compilation.nim",
        "const\n  NimMajor* {.intdefine.}: int = 2\n" &
        "  NimMinor* {.intdefine.}: int = 3\n" &
        "  NimPatch* {.intdefine.}: int = 1\n")
      createDir(prefix / "share" / "repro")
      writeFile(prefix / "share" / "repro" / "cross-build-info",
        "nim_fork=" & ForkRev & "\n")
      let pinned = root / "store" / "nim" / "bin" / "nim"
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
      delEnv(InstalledPrefixNimEnvVar)
      putEnv("REPRO_BOOTSTRAP_CC", gcc)
      putEnv("REPRO_PUBLIC_CLI_PATH", prefix / "bin" / "reprobuild")
      # Entry: the lock's pin is realized and published.
      publishPinnedProviderNim(pinned)
      # Later: the bootstrap before the interface extraction.
      ensureBootstrapToolchainEnv(tpmPathOnly, root / "tool-store")
      check getEnv("REPRO_NIM_COMPILER") == pinned
      check not existsEnv(InstalledPrefixNimEnvVar)
