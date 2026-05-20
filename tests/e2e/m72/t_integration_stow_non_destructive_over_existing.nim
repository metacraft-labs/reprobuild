## M72 gate 3: `integration_stow_non_destructive_over_existing`.
##
## Exercises the M72 Deliverable 3 non-destructive stow materializer
## against GENUINELY pre-existing targets — the case the sandboxed
## M63/M70 gates never hit because their `$HOME` is always empty.
##
## Three sub-cases, each with a stow target that pre-exists on disk
## BEFORE `repro home apply` runs:
##
##   1. Target already exists as the CORRECT symlink to the stow
##      source → materialized as a no-op CACHE-HIT. The gate proves
##      the existing link was NOT deleted-and-recreated by checking
##      the link's filesystem creation timestamp is unchanged across
##      the apply (a delete + recreate resets it).
##
##   2. Target pre-exists as a REGULAR FILE → apply reports drift,
##      the file is left BYTE-IDENTICAL (not clobbered). A second
##      apply with `--reconcile-drift` then replaces it AND records
##      the prior content (so rollback could restore it).
##
##   3. Target pre-exists as a symlink to a DIFFERENT source → apply
##      reports drift; the link is NOT silently replaced.

import std/[os, osproc, streams, strtabs, strutils, tempfiles,
  times, unittest]

import repro_home_generations
import repro_local_store

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir()
  .parentDir() / "fixtures" / "m72" / "stow_non_destructive"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc copyTree(src, dst: string) =
  createDir(dst)
  for kind, entry in walkDir(src, relative = true):
    let from0 = src / entry
    let to0 = dst / entry
    case kind
    of pcFile:
      createDir(parentDir(to0))
      copyFile(from0, to0)
    of pcDir:
      copyTree(from0, to0)
    else: discard

proc runRepro(envOverrides: openArray[tuple[k, v: string]];
              args: openArray[string]):
    tuple[exitCode: int; output: string] =
  var processEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    processEnv[k] = v
  for kv in envOverrides:
    processEnv[kv.k] = kv.v
  let p = startProcess(reproBinary(), args = @args, env = processEnv,
    options = {poUsePath, poStdErrToStdOut})
  let stream = p.outputStream()
  var combined = ""
  while not stream.atEnd():
    let chunk = stream.readAll()
    if chunk.len == 0: break
    combined.add chunk
  let code = p.waitForExit()
  p.close()
  result = (exitCode: code, output: combined)

proc setup(tempRoot: string): tuple[stateDir, storeRoot, homeDir,
    profileDir, stowSource: string; baseEnv: seq[tuple[k, v: string]]] =
  result.stateDir = tempRoot / "state"
  result.storeRoot = tempRoot / "store"
  result.homeDir = tempRoot / "home"
  result.profileDir = tempRoot / "profile"
  createDir(result.stateDir)
  createDir(result.storeRoot)
  createDir(result.homeDir)
  copyTree(FixtureSrc, result.profileDir)
  # M73: the fixture's `stow/` follows the GNU `stow` package
  # convention — the source lives inside package directory `m72pkg/`
  # and materializes at `$HOME/.m72stowrc` (package level stripped).
  result.stowSource = result.profileDir / "stow" / "m72pkg" / ".m72stowrc"
  result.baseEnv = @[
    (k: "REPRO_HOME_PROFILE_DIR", v: result.profileDir),
    (k: "REPRO_HOME_STATE_DIR", v: result.stateDir),
    (k: "REPRO_STORE_ROOT", v: result.storeRoot),
    (k: "HOME", v: result.homeDir),
    (k: "USERPROFILE", v: result.homeDir),
    (k: "REPRO_HOST", v: "m72-gate3-host"),
    (k: "REPRO_HOME_PACKAGE_CATALOG", v: "")]

proc stowOwnership(stateDir, storeRoot, targetPath: string):
    GeneratedFileOwnership =
  ## Read the active generation's manifest and return the ownership
  ## policy recorded for `targetPath`.
  let activeId = readCurrentGenerationId(stateDir)
  let env = readPointerFile(pointerPath(stateDir, activeId))
  var store = openStore(storeRoot)
  defer: store.close()
  var key: PrefixIdBytes
  for i in 0 ..< 32:
    key[i] = env.activationManifestDigest[i]
  let manifest = decodeManifestBytes(readCasBlob(store, key))
  for gf in manifest.generatedFiles:
    if gf.absoluteOutputPath == targetPath:
      return gf.ownershipPolicy
  doAssert false, "no manifest record for stow target " & targetPath

when not defined(windows):
  suite "M72 gate 3: integration_stow_non_destructive_over_existing":
    test "platform N/A":
      echo "[platform N/A] t_integration_stow_non_destructive_over_existing: currently exercises the Windows stow gate"
      check true
else:
  suite "M72 gate 3: integration_stow_non_destructive_over_existing":

    test "pre-existing correct symlink is a no-op cache-hit (not recreated)":
      when not defined(windows):
        checkpoint "platform-skip: M72 stow gate is Windows-specific"
        check true
        return
      let tempRoot = createTempDir("repro-m72-stow-cachehit-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let f = setup(tempRoot)
      let target = f.homeDir / ".m72stowrc"

      # Pre-create the target as the CORRECT symlink to the stow source.
      var symlinkOk = true
      try:
        createSymlink(f.stowSource, target)
      except OSError:
        symlinkOk = false
      if not symlinkOk:
        checkpoint "platform-skip: host cannot create symlinks " &
          "(developer mode off); the cache-hit assertion needs a symlink"
        check true
      else:
        check symlinkExists(target)
        # Record the link's creation time. A delete + recreate would
        # reset it; a true no-op cache-hit leaves it untouched.
        let creationBefore = getCreationTime(target)
        let resolvedBefore = expandSymlink(target)

        let res = runRepro(f.baseEnv, ["home", "apply"])
        check res.exitCode == 0
        check res.output.contains("applied generation ")

        # The link still exists and still points at the stow source.
        check symlinkExists(target)
        check expandSymlink(target) == resolvedBefore
        # The link was NOT deleted-and-recreated: creation time unchanged.
        check getCreationTime(target) == creationBefore
        # The manifest records it as a stow link (cache-hit
        # materialization records the same ownership policy).
        check stowOwnership(f.stateDir, f.storeRoot, target) == gfoStowSymlink

    test "pre-existing regular file is NOT clobbered; --reconcile-drift " &
         "replaces it and records prior content":
      when not defined(windows):
        check true
        return
      let tempRoot = createTempDir("repro-m72-stow-regfile-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let f = setup(tempRoot)
      let target = f.homeDir / ".m72stowrc"

      # Pre-create the target as a REGULAR FILE with distinct content.
      let preExistingContent = "user's own pre-existing .m72stowrc\n" &
        "value = \"hand-written-not-from-stow\"\n"
      writeFile(target, preExistingContent)
      check fileExists(target)
      check not symlinkExists(target)

      # Apply must report drift and NOT clobber the file.
      let res = runRepro(f.baseEnv, ["home", "apply"])
      check res.exitCode != 0
      check (res.output.contains("drift") or
             res.output.contains("conflict"))
      check res.output.contains(".m72stowrc")
      # The file is BYTE-IDENTICAL — the materializer did not overwrite.
      check fileExists(target)
      check readFile(target) == preExistingContent
      # No generation was committed (the apply failed closed).
      check readCurrentGenerationId(f.stateDir).len == 0

      # `--reconcile-drift` replaces the conflicting file.
      let recon = runRepro(f.baseEnv,
        ["home", "apply", "--reconcile-drift"])
      check recon.exitCode == 0
      check recon.output.contains("applied generation ")
      # The target now carries the stow source content.
      let stowContent = readFile(f.stowSource)
      # The materialized target is either a link resolving to the source
      # or a copy with the source content.
      let liveContent =
        if symlinkExists(target): readFile(expandSymlink(target))
        else: readFile(target)
      check liveContent == stowContent
      # The prior (user) content was recorded: the manifest's stow
      # record carries a pre-write digest, and the bytes are sealed in
      # CAS so `repro home rollback` could restore them.
      block:
        let activeId = readCurrentGenerationId(f.stateDir)
        let env = readPointerFile(pointerPath(f.stateDir, activeId))
        var store = openStore(f.storeRoot)
        defer: store.close()
        var mkey: PrefixIdBytes
        for i in 0 ..< 32:
          mkey[i] = env.activationManifestDigest[i]
        let manifest = decodeManifestBytes(readCasBlob(store, mkey))
        var sawStow = false
        for gf in manifest.generatedFiles:
          if gf.absoluteOutputPath == target:
            sawStow = true
            # The reconciled record carries the prior content's digest.
            check gf.hasPreWriteDigest
        check sawStow

    test "pre-existing symlink to a DIFFERENT source is reported as drift":
      when not defined(windows):
        check true
        return
      let tempRoot = createTempDir("repro-m72-stow-wronglink-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let f = setup(tempRoot)
      let target = f.homeDir / ".m72stowrc"

      # An unrelated file the wrong-source symlink will point at.
      let otherSource = tempRoot / "some-other-source.txt"
      writeFile(otherSource, "content of a DIFFERENT source\n")
      var symlinkOk = true
      try:
        createSymlink(otherSource, target)
      except OSError:
        symlinkOk = false
      if not symlinkOk:
        checkpoint "platform-skip: host cannot create symlinks"
        check true
      else:
        check symlinkExists(target)
        let resolvedBefore = expandSymlink(target)

        # Apply must report drift; the wrong-source link is NOT silently
        # replaced.
        let res = runRepro(f.baseEnv, ["home", "apply"])
        check res.exitCode != 0
        check (res.output.contains("drift") or
               res.output.contains("conflict"))
        check res.output.contains(".m72stowrc")
        # The link is untouched — still pointing at the different source.
        check symlinkExists(target)
        check expandSymlink(target) == resolvedBefore
        check readFile(expandSymlink(target)) ==
          "content of a DIFFERENT source\n"
        check readCurrentGenerationId(f.stateDir).len == 0
