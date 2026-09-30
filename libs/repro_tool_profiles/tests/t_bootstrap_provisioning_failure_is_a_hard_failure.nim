## A bootstrap provisioning failure stops the command. It is never a silent
## fallback to the `nim` / `gcc` on `PATH`.
##
## ## The defect this pins
##
## `ensureBootstrapToolchainEnv` wrapped the Nim half of the bootstrap in
## `except CatchableError: discard`, and the Linux C-compiler half likewise.
## A provisioning that failed (offline, a bad digest, a store it could not
## write) left `REPRO_NIM_COMPILER` / `REPRO_BOOTSTRAP_CC` unset, and the
## recipe compile then took whatever `nim` and `gcc` `PATH` offered, without a
## word -- exactly what reprobuild-specs Distribution-And-Packaging.milestones.org,
## M5, rule 2 rules out ("It does not search PATH"). The user's decision
## (2026-09-30): a bootstrap provisioning failure is a hard failure, with a
## diagnostic that says what was being provisioned, by which route, why it
## failed and what to do.
##
## Put the `except CatchableError: discard` back around the Nim provisioning
## and the first case fails in every mode: the call returns, and
## `REPRO_NIM_COMPILER` is still unset. Swallow the C-compiler failure and the
## second fails; stop probing a caller's `REPRO_BOOTSTRAP_CC` off Windows and
## the third fails there.
##
## How the failure is provoked: the tool store is a regular FILE, so every
## route fails at its first write into the store (the archive and source
## routes before they download anything, the Nix route when it registers its
## pointer). That is a real filesystem failure on the real code path, not a
## mock. The one prerequisite the first case needs is a C compiler that works,
## because the C compiler is resolved first; it gets it the way every
## activation does, from the host's own route into the user's tool store.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_local_store
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

const toolchainNames = ["CC", "REPRO_BOOTSTRAP_CC", "REPRO_NIM_COMPILER",
  "REPRO_BOOTSTRAP_SDKROOT"]

proc brokenStore(dir: string): string =
  ## A tool-store path that is a regular file: nothing can be created in it.
  result = dir / "tool-store-is-a-file"
  writeFile(result, "not a directory\n")

suite "a bootstrap provisioning failure is a hard failure":

  test "a Nim provisioning failure stops the bootstrap, in every mode":
    withEnv(toolchainNames):
      delEnv("REPRO_BOOTSTRAP_CC")
      delEnv("REPRO_BOOTSTRAP_SDKROOT")
      let working = provisionBootstrapCCompiler(
        resolveStoreRoot() / "tool-store")
      check working.path.len > 0
      let dir = createTempDir("repro-bootstrap-nim-fails-", "")
      defer: removeDir(dir)
      let store = brokenStore(dir)
      for mode in ToolProvisioningMode:
        checkpoint $mode
        delEnv("REPRO_NIM_COMPILER")
        putEnv("REPRO_BOOTSTRAP_CC", working.path)
        if working.sdkRoot.len > 0:
          putEnv("REPRO_BOOTSTRAP_SDKROOT", working.sdkRoot)
        var raised = false
        try:
          ensureBootstrapToolchainEnv(mode, store)
        except BootstrapNimError as err:
          raised = true
          checkpoint err.msg
          check "could not provision the Nim compiler" in err.msg
          check ("route: " & describeBootstrapNimRoute(bootstrapNimRoute())) in
            err.msg
          check ("tool store: " & store) in err.msg
          check "failure: " in err.msg
          check "remedy: Set REPRO_NIM_COMPILER" in err.msg
        check raised
        # And nothing was published in its place for the compile to use.
        check not existsEnv("REPRO_NIM_COMPILER")

  test "a C compiler provisioning failure stops the bootstrap":
    let dir = createTempDir("repro-bootstrap-cc-fails-", "")
    defer: removeDir(dir)
    let missing = dir / "no-such-compiler"
    var raised = false
    try:
      discard provisionBootstrapCCompiler(dir / "store", bcrSystem, @[missing])
    except BootstrapToolchainError as err:
      raised = true
      checkpoint err.msg
      check "could not provision the C compiler" in err.msg
      check missing in err.msg
      check "remedy: " in err.msg
    check raised
    # The pinned-archive route, against a store it cannot write (or, off
    # Windows, a host with no such archive): refused the same way.
    raised = false
    try:
      discard provisionBootstrapCCompiler(brokenStore(dir), bcrArchive)
    except BootstrapToolchainError as err:
      raised = true
      checkpoint err.msg
      check "route: " in err.msg
    check raised

  test "an unusable REPRO_BOOTSTRAP_CC is refused on every host":
    withEnv(toolchainNames):
      putEnv("REPRO_NIM_COMPILER", "nim")
      let dir = createTempDir("repro-bootstrap-cc-override-", "")
      defer: removeDir(dir)
      let fake = dir / addFileExt("gcc", ExeExt)
      writeFile(fake, "this is not a compiler\n")
      setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})
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
