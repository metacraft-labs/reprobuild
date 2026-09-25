## The recipe-compile toolchain: an explicit override is honoured, a broken one
## is refused by name, and none of it leaks into the user's command.
##
## ## The defects this pins
##
## 1. **The documented override did not work on Windows.** On the host where
##    every `repro exec` failed with `stddef.h: No such file or directory`
##    (FPC's gcc 2.95 first on the Machine PATH, 2026-09-23), exporting
##    `REPRO_BOOTSTRAP_CC=<a real MinGW gcc>` was the workaround -- and it only
##    worked because the `repro exec` path never called
##    `ensureBootstrapToolchainEnv`. Once it did, the Windows branch of that
##    proc OVERWROTE any `REPRO_BOOTSTRAP_CC` with the tool-store compiler
##    (only the Linux branch honoured an existing one).
## 2. **A broken choice was silent.** A `REPRO_BOOTSTRAP_CC` that could not
##    compile anything surfaced, if at all, as a failure inside one of
##    reprobuild's own C files. It is now probed where it is published, and
##    refused with its path and the remedy.
## 3. **The toolchain leaked into the user's command.** The bootstrap
##    publishes `CC`, `REPRO_BOOTSTRAP_CC` and `REPRO_NIM_COMPILER` into the
##    process environment so the provider-compile action inherits them -- and
##    `repro exec -- cargo build` inherited them too, running cc-rs with
##    `CC=<tool-store MinGW gcc>` for an MSVC target. The activation surfaces
##    now snapshot the three on entry and restore them before starting the
##    command; the snapshot/restore pair is pinned here, the wiring
##    end to end in `tests/e2e/dev-env/t_e2e_repro_exec_recipe_compiler.nim`.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_tool_profiles

template withEnv(names: openArray[string]; body: untyped) =
  var saved: seq[tuple[name: string; present: bool; value: string]]
  for name in names:
    saved.add((name: name, present: existsEnv(name), value: getEnv(name)))
  try:
    body
  finally:
    for entry in saved:
      if entry.present: putEnv(entry.name, entry.value)
      else: delEnv(entry.name)

const toolchainNames = ["CC", "REPRO_BOOTSTRAP_CC", "REPRO_NIM_COMPILER"]

suite "the bootstrap toolchain environment is scoped to reprobuild":

  test "restore puts back exactly what was there, set or unset":
    withEnv(toolchainNames):
      putEnv("CC", "the-callers-cc")
      delEnv("REPRO_BOOTSTRAP_CC")
      delEnv("REPRO_NIM_COMPILER")
      let snapshot = snapshotBootstrapToolchainEnv()
      # What the bootstrap does on Windows: publish the compiler, and CC only
      # when it was empty -- here also the case where it overwrites nothing.
      publishBootstrapCompilerEnv(getTempDir() / "tool-store-gcc.exe", true)
      putEnv("REPRO_NIM_COMPILER", getTempDir() / "tool-store-nim.exe")
      putEnv("CC", "clobbered")
      restoreBootstrapToolchainEnv(snapshot)
      check getEnv("CC") == "the-callers-cc"
      check not existsEnv("REPRO_BOOTSTRAP_CC")
      check not existsEnv("REPRO_NIM_COMPILER")

  test "a CC the bootstrap invented does not survive the restore":
    withEnv(toolchainNames):
      delEnv("CC")
      delEnv("REPRO_BOOTSTRAP_CC")
      let snapshot = snapshotBootstrapToolchainEnv()
      publishBootstrapCompilerEnv(getTempDir() / "tool-store-gcc.exe", true)
      check existsEnv("CC")   # the leak this guards against, before the fix
      restoreBootstrapToolchainEnv(snapshot)
      check not existsEnv("CC")
      check not existsEnv("REPRO_BOOTSTRAP_CC")

when defined(windows):
  import repro_local_store

  suite "an explicit REPRO_BOOTSTRAP_CC on Windows":

    test "a usable override is kept, not replaced by the tool-store compiler":
      withEnv(toolchainNames):
        # REPRO_NIM_COMPILER set so the Nim half of the bootstrap does not
        # reach for the tool store: this case is about the C compiler.
        putEnv("REPRO_NIM_COMPILER", "nim")
        # A compiler that certainly works: the pinned one, realised into the
        # user's tool store exactly as every Windows activation does.
        delEnv("REPRO_BOOTSTRAP_CC")
        ensureBootstrapToolchainEnv(tpmPathOnly,
          resolveStoreRoot() / "tool-store")
        let override = getEnv("REPRO_BOOTSTRAP_CC")
        check override.len > 0
        # Now hand it back as an explicit choice, against an EMPTY store. A
        # bootstrap that replaced it would realise the pinned compiler into
        # that store and publish a path inside it; one that keeps it touches
        # nothing there but the probe cache.
        let store = createTempDir("repro-bootstrap-override-", "")
        defer: removeDir(store)
        putEnv("REPRO_BOOTSTRAP_CC", override)
        ensureBootstrapToolchainEnv(tpmPathOnly, store)
        check getEnv("REPRO_BOOTSTRAP_CC") == override
        check not dirExists(store / "prefixes")

    test "an unusable override is refused with its path and the remedy":
      withEnv(toolchainNames):
        putEnv("REPRO_NIM_COMPILER", "nim")
        let dir = createTempDir("repro-bootstrap-override-", "")
        defer: removeDir(dir)
        let fake = dir / "gcc.exe"
        writeFile(fake, "this is not a compiler\n")
        putEnv("REPRO_BOOTSTRAP_CC", fake)
        var raised = false
        try:
          ensureBootstrapToolchainEnv(tpmPathOnly, dir / "store")
        except CCompilerUnusableError as err:
          raised = true
          check fake in err.msg
          check "REPRO_BOOTSTRAP_CC (set in the environment)" in err.msg
          check "remedy:" in err.msg
        check raised
        # Refused BEFORE anything was fetched in its place.
        check not dirExists(dir / "store" / "prefixes")

    test "a REPRO_BOOTSTRAP_CC that names no file is refused":
      withEnv(toolchainNames):
        putEnv("REPRO_NIM_COMPILER", "nim")
        putEnv("REPRO_BOOTSTRAP_CC", "gcc")
        var raised = false
        try:
          ensureBootstrapToolchainEnv(tpmPathOnly, getTempDir() / "unused")
        except CCompilerUnusableError as err:
          raised = true
          check "REPRO_BOOTSTRAP_CC=gcc" in err.msg
        check raised
