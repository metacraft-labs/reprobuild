## M76 gate: `integration_stow_byte_identical_target_is_cache_hit`.
##
## Verifies the M76 fix: the stow materializer's apply path agrees
## with the plan path on what counts as a cache-hit. Before M76,
## `tryCreateSymlink` unconditionally raised `EStowConflict` for a
## stow target that pre-existed as a regular file (or a link to a
## different source) — even when the existing content was
## BYTE-IDENTICAL to the stow source. `previewStowItem` (the plan)
## already classified the same target as a cache-hit, so a plan that
## previewed a clean cache-hit then FAILED at apply. M76 makes the
## byte-identical case a no-op cache-hit on both paths; only a target
## whose content GENUINELY DIFFERS is still an `EStowConflict`.
##
## Sub-tests (each against a sandboxed `$HOME` for the test):
##
##   1. Byte-identical regular file. The stow target pre-exists as a
##      regular file whose bytes equal the stow source's. `apply`
##      succeeds (exit 0); the file is left UNTOUCHED — same content
##      AND same modification time (a delete+recreate would reset
##      mtime); and `apply --plan` previews the SAME item as a
##      cache-hit, so plan and apply agree.
##
##   2. Wrong-source link, byte-identical resolved content. The stow
##      target pre-exists as a symlink to a DIFFERENT source file
##      whose content nonetheless equals the desired stow source's.
##      That is a cache-hit — apply succeeds, the link is not raised
##      as a conflict.
##
##   3. Genuinely-differing regular file. The stow target pre-exists
##      as a regular file whose content DIFFERS from the source.
##      `apply` fails closed (the M72 non-destructive contract):
##      the file is left byte-identical, no generation is committed,
##      and `EStowConflict` is the surfaced error. `--reconcile-drift`
##      is required to replace it. This sub-test guards against the
##      M76 fix over-correcting into "all pre-existing targets are
##      cache-hits".
##
##   4. Parent directory junction into the stow tree (the
##      `~/.ssh/config.d` real-host case). `$HOME/.ssh/config.d` is a
##      directory junction pointing into the fixture's stow package,
##      so the stow target `$HOME/.ssh/config.d/metacraft-runners`
##      resolves THROUGH the junction to the stow source itself and is
##      trivially byte-identical. Apply must materialize it cleanly as
##      a cache-hit, not raise `EStowConflict`.

when not defined(windows):
  {.warning[UnreachableCode]: off.}
  echo "[platform N/A] t_integration_stow_byte_identical_target_is_cache_hit: " &
    "requires Windows stow junction fixtures"
  quit(0)
else:
  import std/[os, osproc, streams, strtabs, strutils, tempfiles,
    times, unittest]

  import repro_home_generations
  import repro_local_store
  import repro_home_apply

  const ProjectRoot = currentSourcePath().parentDir().parentDir()
    .parentDir().parentDir()
  const FixtureSrc = currentSourcePath().parentDir().parentDir()
    .parentDir() / "fixtures" / "m76" / "stow_byte_identical"

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
      profileDir, simpleSource, sshSource: string;
      baseEnv: seq[tuple[k, v: string]]] =
    result.stateDir = tempRoot / "state"
    result.storeRoot = tempRoot / "store"
    result.homeDir = tempRoot / "home"
    result.profileDir = tempRoot / "profile"
    createDir(result.stateDir)
    createDir(result.storeRoot)
    createDir(result.homeDir)
    copyTree(FixtureSrc, result.profileDir)
    # GNU `stow` package layout: the package level is STRIPPED.
    #   stow/m76pkg/.m76stowrc                  -> $HOME/.m76stowrc
    #   stow/sshpkg/.ssh/config.d/metacraft-runners
    #                                           -> $HOME/.ssh/config.d/
    #                                              metacraft-runners
    result.simpleSource = result.profileDir / "stow" / "m76pkg" / ".m76stowrc"
    result.sshSource = result.profileDir / "stow" / "sshpkg" / ".ssh" /
      "config.d" / "metacraft-runners"
    result.baseEnv = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: result.profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: result.stateDir),
      (k: "REPRO_STORE_ROOT", v: result.storeRoot),
      (k: "HOME", v: result.homeDir),
      (k: "USERPROFILE", v: result.homeDir),
      (k: "REPRO_HOST", v: "m76-gate-host"),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "")]

  proc createDirectoryJunction(link, target: string): bool =
    ## Create an NTFS directory junction `link` -> `target` via
    ## `mklink /J`, mirroring `tryCreateJunctionAtAncestor`. A junction
    ## needs no special privilege, so this is reliable on the CI host.
    let cmd = "cmd /c mklink /J " & quoteShell(link) & " " &
      quoteShell(target)
    execShellCmd(cmd) == 0

  suite "M76 gate: integration_stow_byte_identical_target_is_cache_hit":

    test "byte-identical regular-file target is a no-op cache-hit; " &
         "apply succeeds, file untouched, plan and apply agree":
      when not defined(windows):
        checkpoint "platform-skip: M76 stow gate is Windows-specific"
        check true
        return
      let tempRoot = createTempDir("repro-m76-byteident-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let f = setup(tempRoot)
      let target = f.homeDir / ".m76stowrc"

      # Pre-create the target as a REGULAR FILE byte-identical to the
      # stow source — exactly the same bytes, written out-of-band.
      let sourceBytes = readFile(f.simpleSource)
      writeFile(target, sourceBytes)
      check fileExists(target)
      check not symlinkExists(target)
      let mtimeBefore = getLastModificationTime(target)
      let contentBefore = readFile(target)

      # The plan path must preview this as a cache-hit (no drift).
      let plan = runRepro(f.baseEnv, ["home", "apply", "--plan"])
      check plan.exitCode == 0
      check plan.output.contains("[stow]")
      check plan.output.contains("cache-hit")
      check plan.output.contains(".m76stowrc")
      check plan.output.contains("0 drift(s)")
      # The plan path's detail line for the byte-identical regular file.
      check plan.output.contains("byte-identical")

      # The apply path must AGREE: succeed, no EStowConflict.
      let res = runRepro(f.baseEnv, ["home", "apply"])
      check res.exitCode == 0
      check res.output.contains("applied generation ")
      check not res.output.contains("EStowConflict")
      check not res.output.contains("conflict")

      # The file was left EXACTLY as is — no delete, no recreate:
      # identical content AND identical modification time.
      check fileExists(target)
      check readFile(target) == contentBefore
      check getLastModificationTime(target) == mtimeBefore
      # A generation WAS committed (apply ran to completion).
      check readCurrentGenerationId(f.stateDir).len > 0

    test "wrong-source link whose resolved content is byte-identical " &
         "to the stow source is a cache-hit":
      when not defined(windows):
        check true
        return
      let tempRoot = createTempDir("repro-m76-wronglink-ident-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let f = setup(tempRoot)
      let target = f.homeDir / ".m76stowrc"

      # A DIFFERENT source file — a distinct path — but with content
      # byte-identical to the desired stow source.
      let otherSource = tempRoot / "byte-identical-but-different-path.txt"
      writeFile(otherSource, readFile(f.simpleSource))
      var symlinkOk = true
      try:
        createSymlink(otherSource, target)
      except OSError:
        symlinkOk = false
      if not symlinkOk:
        checkpoint "platform-skip: host cannot create symlinks " &
          "(developer mode off); the wrong-link cache-hit case needs one"
        check true
      else:
        check symlinkExists(target)
        # The link points at a DIFFERENT path than the stow source...
        check expandSymlink(target) != f.simpleSource
        # ...but its resolved content is byte-identical.
        check readFile(target) == readFile(f.simpleSource)

        # Plan previews a cache-hit (resolved content byte-identical).
        let plan = runRepro(f.baseEnv, ["home", "apply", "--plan"])
        check plan.exitCode == 0
        check plan.output.contains("cache-hit")
        check plan.output.contains("0 drift(s)")

        # Apply agrees: succeeds, no EStowConflict.
        let res = runRepro(f.baseEnv, ["home", "apply"])
        check res.exitCode == 0
        check res.output.contains("applied generation ")
        check not res.output.contains("conflict")
        check readCurrentGenerationId(f.stateDir).len > 0

    test "genuinely-differing regular-file target still raises " &
         "EStowConflict; --reconcile-drift required (M72 contract)":
      when not defined(windows):
        check true
        return
      let tempRoot = createTempDir("repro-m76-differs-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let f = setup(tempRoot)
      let target = f.homeDir / ".m76stowrc"

      # Pre-create the target as a regular file whose content GENUINELY
      # DIFFERS from the stow source — this is a real conflict.
      let driftedContent = "value = \"hand-edited-DIFFERENT-from-stow\"\n"
      check driftedContent != readFile(f.simpleSource)
      writeFile(target, driftedContent)

      # The plan path reports drift (non-zero exit without --allow-drift).
      let plan = runRepro(f.baseEnv, ["home", "apply", "--plan"])
      check plan.exitCode != 0
      check plan.output.contains("conflict-drift")
      check plan.output.contains(".m76stowrc")

      # The apply path fails closed: EStowConflict, file NOT clobbered.
      let res = runRepro(f.baseEnv, ["home", "apply"])
      check res.exitCode != 0
      check (res.output.contains("drift") or res.output.contains("conflict"))
      check res.output.contains(".m76stowrc")
      check fileExists(target)
      check readFile(target) == driftedContent
      check readCurrentGenerationId(f.stateDir).len == 0

      # In-process: the surfaced exception is specifically EStowConflict.
      block:
        var opts: ApplyOptions
        opts.profileDir = f.profileDir
        opts.stateDir = f.stateDir
        opts.storeRoot = f.storeRoot
        opts.homeDir = f.homeDir
        opts.host = "m76-gate-host"
        var raisedKind = ""
        try:
          discard runApply(opts)
        except EStowConflict as e:
          raisedKind = "EStowConflict"
          check e.targetPath == target
          check e.existingKind == "regular-file"
          check e.desiredSource == f.simpleSource
        except EHomeApply:
          raisedKind = "EHomeApply-other"
        except CatchableError:
          raisedKind = "other"
        check raisedKind == "EStowConflict"

      # `--reconcile-drift` is what replaces a genuinely-drifted target.
      let recon = runRepro(f.baseEnv, ["home", "apply", "--reconcile-drift"])
      check recon.exitCode == 0
      check recon.output.contains("applied generation ")
      let stowContent = readFile(f.simpleSource)
      let liveContent =
        if symlinkExists(target): readFile(expandSymlink(target))
        else: readFile(target)
      check liveContent == stowContent
      check readCurrentGenerationId(f.stateDir).len > 0

    test "stow target reached through a parent directory junction into " &
         "the stow tree materializes cleanly as a cache-hit":
      when not defined(windows):
        check true
        return
      let tempRoot = createTempDir("repro-m76-parentjunction-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let f = setup(tempRoot)

      # Replicate the `~/.ssh/config.d` real-host layout: `$HOME/.ssh`
      # exists as an ordinary directory, and `$HOME/.ssh/config.d` is a
      # directory JUNCTION pointing into the fixture's stow package
      # directory `stow/sshpkg/.ssh/config.d`. The stow target
      # `$HOME/.ssh/config.d/metacraft-runners` therefore resolves
      # THROUGH the junction back to the stow source itself, so it is
      # trivially byte-identical to it.
      createDir(f.homeDir / ".ssh")
      let stowConfigD = f.profileDir / "stow" / "sshpkg" / ".ssh" / "config.d"
      let junctionPath = f.homeDir / ".ssh" / "config.d"
      check dirExists(stowConfigD)
      let junctionOk = createDirectoryJunction(junctionPath, stowConfigD)
      check junctionOk
      let target = junctionPath / "metacraft-runners"
      # The target resolves through the junction to the stow source's
      # bytes — they are the same underlying file.
      check fileExists(target)
      check readFile(target) == readFile(f.sshSource)

      # Plan previews this stow item as a cache-hit, not drift.
      let plan = runRepro(f.baseEnv, ["home", "apply", "--plan"])
      check plan.exitCode == 0
      check plan.output.contains("cache-hit")
      check plan.output.contains("metacraft-runners")
      check plan.output.contains("0 drift(s)")

      # Apply must agree: succeed, materialize as a clean cache-hit,
      # and NOT raise EStowConflict on the junction-reached target.
      let res = runRepro(f.baseEnv, ["home", "apply"])
      check res.exitCode == 0
      check res.output.contains("applied generation ")
      check not res.output.contains("conflict")
      check readCurrentGenerationId(f.stateDir).len > 0
      # The junction and the file inside it are untouched.
      check fileExists(target)
      check readFile(target) == readFile(f.sshSource)
