## A dev daemon's startup sweep keeps its own staged image and nothing else.
##
## WHY THE SWEEP EXISTS. Every dev-mode daemon start stages a copy of its
## engine image under `<state>/dev-bin/<generation>/` (`stageDevDaemonBinary`)
## and runs from the copy. Before the sweep, only a dev SELF-restart removed
## its predecessor's copy; a daemon replaced by a client's staleness restart,
## by `daemon stop`, or by a crash left its copy for good. reprobuild-pm issue
## 2026-09-30 counted 260 of them on one workstation, one engine image each.
## The daemon that wins the state directory's lock now removes every
## generation but its own (`sweepStaleDevStagedGenerations`).
##
## WHAT THIS PINS, because a deletion pass is only acceptable if its reach is
## exact:
##
##   * its OWN generation survives, including when it is spelled differently
##     from the directory listing (a trailing separator, a `..` segment);
##   * every OTHER generation directory is removed;
##   * nothing OUTSIDE `dev-bin` is touched -- not a sibling of `dev-bin` whose
##     name shares its prefix, not the target of a symlink placed inside
##     `dev-bin`, not the target of a symlink placed inside a generation;
##   * a NON-dev daemon removes nothing, and neither does one with no state
##     directory (whose `dev-bin` would otherwise resolve against the working
##     directory).
##
## Removing the sweep, or keeping no generation, reddens the first two. A
## sweep that also removed symlinked children of `dev-bin` (accepting
## `pcLinkToDir` beside `pcDir`) deletes the file OUTSIDE the state directory
## through the link and reddens the third -- verified, not assumed. The
## `dev-bin-other` lookalike guards a future rewrite that scans the state
## directory by name prefix instead of listing `dev-bin`.
##
## MOCK POLICY: no mocks, and none may be added. The subject is which real
## directories a real recursive removal deletes, so the tree is built on the
## real filesystem; a fake filesystem would decide the question by fiat.

import std/[os, tempfiles, unittest]

import repro_daemon_core

proc devConfig(root: string): UserDaemonConfig =
  result = defaultUserDaemonConfig(devMode = true)
  result.stateDir = root / "state"
  result.logPath = root / "state" / "logs" / "repro-daemon.log"
  result.endpoint = root / "daemon.sock"

proc stageGeneration(devBin, name: string): string =
  ## A generation as `stageDevDaemonBinary` leaves one: a directory holding
  ## the copied image.
  result = devBin / name
  createDir(result)
  writeFile(result / "repro-daemon", "image " & name & "\n")

suite "dev-bin retention":
  test "keeps its own generation and removes every other one":
    let root = createTempDir("repro-devbin-keep", "")
    defer: removeDir(root)
    var config = devConfig(root)
    let devBin = config.stateDir / "dev-bin"
    let own = stageGeneration(devBin, "dev-start-3-own")
    let older = stageGeneration(devBin, "dev-start-1-older")
    let previous = stageGeneration(devBin, "dev-start-2-previous")
    config.stagedGenerationDir = own
    # The self-restart hand-off is subsumed: the predecessor named here is
    # removed by the same pass as every other stale generation.
    config.previousStagedGenerationDir = previous

    let sweep = sweepStaleDevStagedGenerationsForTest(config)
    checkpoint("removed: " & $sweep.removed & " failed: " & $sweep.failed)
    check dirExists(own)
    check fileExists(own / "repro-daemon")
    check not dirExists(older)
    check not dirExists(previous)
    check sweep.removed.len == 2
    check sweep.failed.len == 0
    check sweep.kept == own

    # Idempotent: a second pass finds nothing to do.
    let again = sweepStaleDevStagedGenerationsForTest(config)
    check again.removed.len == 0
    check dirExists(own)

  test "recognises its own generation under another spelling":
    let root = createTempDir("repro-devbin-spelling", "")
    defer: removeDir(root)
    var config = devConfig(root)
    let devBin = config.stateDir / "dev-bin"
    let own = stageGeneration(devBin, "dev-start-own")
    let other = stageGeneration(devBin, "dev-start-other")
    # Reached through a `..` segment and with a trailing separator. Built by
    # concatenation, not `/`: `joinPath` would normalize the `..` away.
    config.stagedGenerationDir = devBin & DirSep & "dev-start-other" & DirSep &
      ".." & DirSep & "dev-start-own" & DirSep
    discard sweepStaleDevStagedGenerationsForTest(config)
    check dirExists(own)
    check not dirExists(other)

  test "never reaches outside dev-bin":
    let root = createTempDir("repro-devbin-contain", "")
    defer: removeDir(root)
    var config = devConfig(root)
    let devBin = config.stateDir / "dev-bin"
    let own = stageGeneration(devBin, "dev-start-own")
    let stale = stageGeneration(devBin, "dev-start-stale")

    # A sibling of `dev-bin` whose name extends it: a string-prefix
    # containment check would accept it.
    let lookalike = config.stateDir / "dev-bin-other"
    createDir(lookalike)
    writeFile(lookalike / "keep", "keep\n")
    # State the daemon keeps beside `dev-bin`.
    writeFile(config.stateDir / "status-file", "keep\n")
    # A directory OUTSIDE the state directory, reachable from inside dev-bin
    # by two symlinks: one as a direct child of dev-bin, one inside a stale
    # generation that IS removed.
    let outside = root / "outside"
    createDir(outside)
    writeFile(outside / "precious", "keep\n")
    # A plain file directly in dev-bin is not a generation either.
    writeFile(devBin / "stray-file", "keep\n")
    when defined(posix):
      createSymlink(outside, devBin / "link-to-outside")
      createSymlink(outside, stale / "link-to-outside")

    config.stagedGenerationDir = own
    let sweep = sweepStaleDevStagedGenerationsForTest(config)
    checkpoint("removed: " & $sweep.removed)
    check dirExists(own)
    check not dirExists(stale)
    check sweep.removed == @[stale]
    check fileExists(lookalike / "keep")
    check fileExists(config.stateDir / "status-file")
    check fileExists(outside / "precious")
    check fileExists(devBin / "stray-file")
    when defined(posix):
      check symlinkExists(devBin / "link-to-outside")

  test "a daemon running from its source image keeps nothing staged":
    # A dev daemon started by hand runs from its source image and has no
    # staged generation of its own, so every generation is stale.
    let root = createTempDir("repro-devbin-none", "")
    defer: removeDir(root)
    var config = devConfig(root)
    let devBin = config.stateDir / "dev-bin"
    let a = stageGeneration(devBin, "dev-start-a")
    let b = stageGeneration(devBin, "dev-start-b")
    config.stagedGenerationDir = ""
    let sweep = sweepStaleDevStagedGenerationsForTest(config)
    check not dirExists(a)
    check not dirExists(b)
    check sweep.removed.len == 2
    check sweep.kept == ""
    check dirExists(devBin)

  test "a non-dev daemon removes nothing":
    let root = createTempDir("repro-devbin-frozen", "")
    defer: removeDir(root)
    var config = devConfig(root)
    config.devMode = false
    let devBin = config.stateDir / "dev-bin"
    let a = stageGeneration(devBin, "dev-start-a")
    let sweep = sweepStaleDevStagedGenerationsForTest(config)
    check dirExists(a)
    check sweep.removed.len == 0

  test "a missing dev-bin is not an error":
    let root = createTempDir("repro-devbin-missing", "")
    defer: removeDir(root)
    let sweep = sweepStaleDevStagedGenerationsForTest(devConfig(root))
    check sweep.removed.len == 0
    check sweep.failed.len == 0

  test "an empty state directory sweeps nothing relative to the working directory":
    # `devBinRoot` of an empty state directory is the RELATIVE "dev-bin".
    # Anchored to the working directory it would name a directory the daemon
    # does not own, so a generation-shaped directory there must survive.
    let root = createTempDir("repro-devbin-nostate", "")
    let saved = getCurrentDir()
    defer:
      setCurrentDir(saved)
      removeDir(root)
    let cwdDevBin = root / "dev-bin"
    let bystander = stageGeneration(cwdDevBin, "dev-start-not-ours")
    setCurrentDir(root)
    var config = devConfig(root)
    config.stateDir = ""
    let sweep = sweepStaleDevStagedGenerationsForTest(config)
    check dirExists(bystander)
    check fileExists(bystander / "repro-daemon")
    check sweep.removed.len == 0
