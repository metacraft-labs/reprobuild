## Materializing launchers into a generation that already exists replaces
## each entry atomically; it never writes the old file in place.
##
## Generation ids are content-addressed, so re-applying an earlier profile
## (A, then B, then A) or re-applying the active one after drift materializes
## launchers into a directory that is already committed. Partial-apply
## recovery keeps such a generation even when the apply dies, because its old
## `pointer.bin` still validates. If step 9 truncated a launcher and wrote it
## again in place, a kill between the two left the kept generation with a
## torn launcher, which a later rollback activates (or which is already on
## PATH, when the generation is the active one).
##
## The test plants an older launcher in the bin dir and keeps a second hard
## link to it, the "witness". An in-place write (`writeFile`: truncate, then
## write) changes the inode both names share, so the witness changes. A
## replacement by rename installs a new inode and leaves the witness holding
## the old bytes: that is exactly the property that a kill at any instant
## leaves either the old launcher or the new one. On Windows the planted
## entry is the launcher's `.repro-launch` sidecar, which the old code also
## wrote in place.
##
## `materializeLaunchers` is the production function step 9 calls. No mocks;
## the store is a real scratch store.

import std/[os, strutils, tempfiles, times, unittest]

import repro_local_store
import repro_home_apply/[materialize_launchers, plan, realize]

const OldLauncher = "launcher bytes written by an earlier apply\n"

proc realized(pkg, prefix, exe: string): RealizedRecord =
  result.packageId = pkg
  result.prefixAbsolutePath = prefix
  result.resolvedExecutablePath = exe

proc tmpEntries(dir: string): seq[string] =
  for kind, path in walkDir(dir):
    let leaf = extractFilename(path)
    if leaf.startsWith(".") and leaf.endsWith(".tmp"):
      result.add(leaf)

suite "re-materializing a committed generation's launchers":

  test "an existing launcher entry is replaced by rename, not rewritten":
    let root = createTempDir("repro-launcher-replace-", "")
    defer: removeDir(root)
    var store = openStore(root / "store")
    let binDir = root / "generations" / "g" / "bin"
    createDir(binDir)
    when defined(windows):
      let launcherBinary = root / "repro-launcher.exe"
      writeFile(launcherBinary, "the launcher binary of this apply")
      putEnv(LauncherBinaryEnvVar, launcherBinary)
      defer: delEnv(LauncherBinaryEnvVar)
      let exe = root / "prefix" / "bin" / "tool.exe"
      let planted = binDir / "tool.exe.repro-launch"
    else:
      let exe = root / "prefix" / "bin" / "tool"
      let planted = binDir / "tool"
    writeFile(planted, OldLauncher)
    let witness = root / "witness"
    createHardlink(planted, witness)

    let mats = materializeLaunchers(store, binDir,
      @[realized("tool", root / "prefix", exe)],
      @[PlannedLauncher(commandName: "tool", fromPackageId: "tool")])

    check mats.len == 1
    # The new launcher is in place...
    check readFile(planted) != OldLauncher
    # ...and the file it replaced was never opened for writing.
    check readFile(witness) == OldLauncher
    when not defined(windows):
      check readFile(planted).contains(exe)
      check fpUserExec in getFilePermissions(planted)
      check fpOthersExec in getFilePermissions(planted)
    check tmpEntries(binDir).len == 0

  test "a new launcher entry is created executable, with no temporary left":
    let root = createTempDir("repro-launcher-create-", "")
    defer: removeDir(root)
    var store = openStore(root / "store")
    let binDir = root / "generations" / "g" / "bin"
    when defined(windows):
      let launcherBinary = root / "repro-launcher.exe"
      writeFile(launcherBinary, "the launcher binary of this apply")
      putEnv(LauncherBinaryEnvVar, launcherBinary)
      defer: delEnv(LauncherBinaryEnvVar)
      let exe = root / "prefix" / "bin" / "tool.exe"
    else:
      let exe = root / "prefix" / "bin" / "tool"
    discard materializeLaunchers(store, binDir,
      @[realized("tool", root / "prefix", exe)],
      @[PlannedLauncher(commandName: "tool", fromPackageId: "tool")])
    when defined(windows):
      check fileExists(binDir / "tool.exe")
      check readFile(binDir / "tool.exe") == "the launcher binary of this apply"
      check fileExists(binDir / "tool.exe.repro-launch")
    else:
      check fileExists(binDir / "tool")
      check fpUserExec in getFilePermissions(binDir / "tool")
    check tmpEntries(binDir).len == 0

  test "a stale temporary from a killed apply is swept, a fresh one kept":
    let root = createTempDir("repro-launcher-sweep-", "")
    defer: removeDir(root)
    var store = openStore(root / "store")
    let binDir = root / "generations" / "g" / "bin"
    createDir(binDir)
    when defined(windows):
      let launcherBinary = root / "repro-launcher.exe"
      writeFile(launcherBinary, "the launcher binary of this apply")
      putEnv(LauncherBinaryEnvVar, launcherBinary)
      defer: delEnv(LauncherBinaryEnvVar)
      let exe = root / "prefix" / "bin" / "tool.exe"
      let leaf = "tool.exe"
    else:
      let exe = root / "prefix" / "bin" / "tool"
      let leaf = "tool"
    let stale = binDir / ("." & leaf & ".4242-1-1.tmp")
    let fresh = binDir / ("." & leaf & ".4243-1-2.tmp")
    writeFile(stale, "half a launcher")
    writeFile(fresh, "half a launcher")
    setLastModificationTime(stale, getTime() - initDuration(hours = 2))
    discard materializeLaunchers(store, binDir,
      @[realized("tool", root / "prefix", exe)],
      @[PlannedLauncher(commandName: "tool", fromPackageId: "tool")])
    check not fileExists(stale)
    check fileExists(fresh)

  test "the shared writer rollback and remote activation use replaces by rename":
    # Rollback re-materializes a missing script into the committed target
    # generation, and remote activation writes into a generation whose
    # content-addressed id may already exist. Both go through
    # `replaceLauncherFile`.
    let root = createTempDir("repro-launcher-shared-", "")
    defer: removeDir(root)
    let entry = root / "tool"
    writeFile(entry, OldLauncher)
    let witness = root / "witness"
    createHardlink(entry, witness)
    replaceLauncherFile(entry, "#!/bin/sh\nexec true\n", LauncherScriptMode)
    check readFile(entry) == "#!/bin/sh\nexec true\n"
    check readFile(witness) == OldLauncher
    when not defined(windows):
      check getFilePermissions(entry) == LauncherScriptMode
    check tmpEntries(root).len == 0
