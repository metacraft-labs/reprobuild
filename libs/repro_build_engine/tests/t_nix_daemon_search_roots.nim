## The engine must find its own `reprobuild-nix-daemon` from BOTH layouts.
##
## Distribution-And-Packaging M1's N28 (and the real cause of N24).
## `bakForeignProvision` derived its search root as
##
##   getAppFilename().parentDir.parentDir
##
## and built two candidates from it: `<root>/tools/reprobuild-nix-daemon/
## reprobuild-nix-daemon` and `<root>/build/reprobuild-nix-daemon`.
##
## For an INSTALLED `<prefix>/bin/repro` that root is `<prefix>` -- and the
## installed helper is at `<prefix>/libexec/reprobuild-nix-daemon` (flake) or
## `<prefix>/libexec/<dist>/reprobuild-nix-daemon` (package), so neither
## candidate matched. For the DEV TREE's `build/bin/repro` that root is
## `<repo>/build` -- and the helper is at `<repo>/tools/...`, so
## `<repo>/build/tools/...` and `<repo>/build/build/...` were both nothing.
## Both layouts fell through to a bare `reprobuild-nix-daemon` on `PATH`, and
## the Linux dogfood build died with
##
##   daemon-hosted build failed: No such file or directory
##   Additional info: reprobuild-nix-daemon
##
## which cost this campaign a whole pass and a wrong diagnosis (staleness).
##
## AND THE EXECUTABLE IS NOT A RELIABLE ANCHOR AT ALL -- which the first
## attempt at this fix got wrong, and a measurement rather than a reading
## caught. A dev-tree build is DAEMON-HOSTED, and the user daemon runs a
## STAGED COPY of the tree's binary under
## `~/.local/state/repro/daemon/dev-bin/dev-start-<generation>/repro-daemon`,
## so inside the engine `getAppFilename()` answers a path in the state
## directory whose ancestors hold no checkout. With the exe anchors in place
## and no cwd walk, the Linux dogfood build failed IDENTICALLY. The primary
## anchor is therefore `action.cwd` AND ITS ANCESTORS.
##
## THESE CASES PIN BOTH LAYOUTS, and they pin them on a REAL FILESYSTEM
## rather than on the candidate list alone -- a list containing the right
## string is not the same claim as a resolver returning it. The list-shape
## cases are here too, because the ORDER is a contract: an explicit
## `REPROBUILD_NIX_DAEMON_BIN` beats everything, `action.cwd` beats the
## exe-derived roots, and a filesystem root is never an anchor.

import std/[os, sets, strutils, unittest]

import repro_build_engine

proc scratch(name: string): string =
  result = getTempDir() / "repro-n28-daemon-roots" / name
  removeDir(result)
  createDir(result)

proc placeDaemon(path: string) =
  createDir(path.parentDir)
  writeFile(path, "#!/bin/sh\nexit 0\n")
  when defined(posix):
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc paths(cands: seq[NixDaemonCandidate]): seq[string] =
  for c in cands: result.add(c.path)

suite "the engine resolves reprobuild-nix-daemon from both layouts":

  test "dev tree: build/bin/repro finds the repo's tools/ helper":
    let repo = scratch("devtree")
    let exe = repo / "build" / "bin" / "repro"
    placeDaemon(exe)
    let helper = repo / "tools" / "reprobuild-nix-daemon" /
      "reprobuild-nix-daemon"
    placeDaemon(helper)
    let resolved = resolveNixDaemonExecutable(
      cwd = repo / "tests" / "fixtures" / "packaging" / "reprobuild-dist",
      exePath = exe, envSourceRoot = "", envBin = "")
    # The OLD anchor produced `<repo>/build/tools/...` and
    # `<repo>/build/build/...`; had it still been in force this would be the
    # bare name.
    doAssert resolved == helper,
      "dev tree did not resolve its own helper, got: " & resolved

  test "dev tree: build/reprobuild-nix-daemon is found from a foreign cwd":
    let repo = scratch("devtree-built")
    let exe = repo / "build" / "bin" / "repro"
    placeDaemon(exe)
    let built = repo / "build" / "reprobuild-nix-daemon"
    placeDaemon(built)
    let resolved = resolveNixDaemonExecutable(
      cwd = getTempDir() / "repro-n28-daemon-roots" / "some-foreign-repo",
      exePath = exe, envSourceRoot = "", envBin = "")
    doAssert resolved == built,
      "dev tree did not resolve its BUILT helper, got: " & resolved

  test "installed: <prefix>/bin/repro finds <prefix>/libexec/":
    let prefix = scratch("installed")
    let exe = prefix / "bin" / "repro"
    placeDaemon(exe)
    let helper = prefix / "libexec" / "reprobuild-nix-daemon"
    placeDaemon(helper)
    let resolved = resolveNixDaemonExecutable(
      cwd = getTempDir(), exePath = exe, envSourceRoot = "", envBin = "")
    doAssert resolved == helper,
      "installed prefix did not resolve libexec/, got: " & resolved

  test "packaged: <prefix>/libexec/reprobuild/ is found too":
    let prefix = scratch("packaged")
    let exe = prefix / "bin" / "repro"
    placeDaemon(exe)
    let helper = prefix / "libexec" / "reprobuild" / "reprobuild-nix-daemon"
    placeDaemon(helper)
    let resolved = resolveNixDaemonExecutable(
      cwd = getTempDir(), exePath = exe, envSourceRoot = "", envBin = "")
    doAssert resolved == helper,
      "packaged prefix did not resolve libexec/<dist>/, got: " & resolved

  test "nothing on disk still answers the bare name for poUsePath":
    let repo = scratch("empty")
    let exe = repo / "build" / "bin" / "repro"
    placeDaemon(exe)
    doAssert resolveNixDaemonExecutable(cwd = repo, exePath = exe,
      envSourceRoot = "", envBin = "") == "reprobuild-nix-daemon"

  test "REPROBUILD_NIX_DAEMON_BIN wins, and refuses when it is a lie":
    let repo = scratch("override")
    let exe = repo / "build" / "bin" / "repro"
    placeDaemon(exe)
    let helper = repo / "tools" / "reprobuild-nix-daemon" /
      "reprobuild-nix-daemon"
    placeDaemon(helper)
    let override = repo / "elsewhere" / "reprobuild-nix-daemon"
    placeDaemon(override)
    doAssert resolveNixDaemonExecutable(cwd = repo, exePath = exe,
      envSourceRoot = "", envBin = override) == override
    var refused = false
    try:
      discard resolveNixDaemonExecutable(cwd = repo, exePath = exe,
        envSourceRoot = "", envBin = repo / "not-there")
    except CatchableError as e:
      refused = "REPROBUILD_NIX_DAEMON_BIN does not exist" in e.msg
    doAssert refused,
      "an override naming nothing must be a hard error, not a fallback"

  test "REPROBUILD_SOURCE_ROOT is first but no longer suppresses the rest":
    let repo = scratch("srcroot")
    let exe = repo / "build" / "bin" / "repro"
    placeDaemon(exe)
    let helper = repo / "tools" / "reprobuild-nix-daemon" /
      "reprobuild-nix-daemon"
    placeDaemon(helper)
    let hinted = scratch("srcroot-hint")
    let hintedHelper = hinted / "build" / "reprobuild-nix-daemon"
    placeDaemon(hintedHelper)
    # Set and correct: it wins.
    doAssert resolveNixDaemonExecutable(cwd = getTempDir(), exePath = exe,
      envSourceRoot = hinted, envBin = "") == hintedHelper
    # Set and WRONG: the exe-derived roots still answer. The previous code
    # returned "" for the root in this case and searched nothing.
    doAssert resolveNixDaemonExecutable(cwd = getTempDir(), exePath = exe,
      envSourceRoot = repo / "no-such-root", envBin = "") == helper

  test "the candidate ORDER is the contract":
    let cands = paths(nixDaemonCandidates(
      cwd = "/w/proj", exePath = "/opt/rb/bin/repro", envSourceRoot = "/src"))
    doAssert cands[0] == "/w/proj" / "build" / "reprobuild-nix-daemon"
    doAssert cands[1] == "/w/proj" / "tools" / "reprobuild-nix-daemon" /
      "reprobuild-nix-daemon"
    doAssert cands[2] == "/w" / "reprobuild-nix-daemon" / "build" /
      "reprobuild-nix-daemon"
    # `/src` (the explicit hint) before the cwd ancestors before `/opt/rb`
    # (the install prefix) before `/opt` (the repository root a dev tree
    # would have). The cwd ancestors outrank the exe anchors deliberately:
    # a daemon-hosted build's executable is a staged copy in a state
    # directory and its ancestors are not a checkout.
    let srcAt = cands.find("/src" / "tools" / "reprobuild-nix-daemon" /
      "reprobuild-nix-daemon")
    let cwdAncestorAt = cands.find("/w" / "build" / "reprobuild-nix-daemon")
    let prefixAt = cands.find("/opt/rb" / "libexec" / "reprobuild-nix-daemon")
    let rootAt = cands.find("/opt" / "build" / "reprobuild-nix-daemon")
    doAssert srcAt >= 3, $srcAt
    doAssert cwdAncestorAt > srcAt, $cwdAncestorAt & " vs " & $srcAt
    doAssert prefixAt > cwdAncestorAt, $prefixAt & " vs " & $cwdAncestorAt
    doAssert rootAt > prefixAt, $rootAt & " vs " & $prefixAt

  test "both exe-derived anchors are present, which is the whole fix":
    let cands = paths(nixDaemonCandidates(
      cwd = "", exePath = "/repo/build/bin/repro", envSourceRoot = ""))
    # The dev tree's repository root.
    doAssert ("/repo" / "tools" / "reprobuild-nix-daemon" /
      "reprobuild-nix-daemon") in cands
    doAssert ("/repo" / "build" / "reprobuild-nix-daemon") in cands
    # The grandparent anchor the old code had, kept rather than replaced.
    doAssert ("/repo/build" / "tools" / "reprobuild-nix-daemon" /
      "reprobuild-nix-daemon") in cands

  test "daemon-hosted: a staged image in a state dir still finds the tree":
    # THE CASE THE FIRST ATTEMPT AT THIS FIX WOULD HAVE FAILED. The user
    # daemon runs a COPY of `build/bin/repro` staged under
    # `~/.local/state/repro/daemon/dev-bin/dev-start-<gen>/repro-daemon`, so
    # the engine's `getAppFilename()` names the state directory and every
    # exe-derived anchor points somewhere with no checkout in it. What is
    # still true is that `action.cwd` is inside the tree.
    let repo = scratch("daemon-hosted")
    let helper = repo / "tools" / "reprobuild-nix-daemon" /
      "reprobuild-nix-daemon"
    placeDaemon(helper)
    let state = scratch("daemon-state")
    let stagedImage = state / "daemon" / "dev-bin" / "dev-start-1-2-3" /
      "repro-daemon"
    placeDaemon(stagedImage)
    let resolved = resolveNixDaemonExecutable(
      cwd = repo / "tests" / "fixtures" / "packaging" / "reprobuild-dist",
      exePath = stagedImage, envSourceRoot = "", envBin = "")
    doAssert resolved == helper,
      "a daemon-hosted build did not find its own tree's helper, got: " &
        resolved

  test "the cwd walk stops, and a foreign repo resolves nothing":
    # The walk must not climb out of the world: a build run in a repository
    # that is NOT reprobuild has to fall through to the bare name rather
    # than find some unrelated `tools/reprobuild-nix-daemon` above it.
    let foreign = scratch("foreign")
    createDir(foreign / "a" / "b" / "c")
    let state = scratch("foreign-state")
    let stagedImage = state / "dev-bin" / "gen" / "repro-daemon"
    placeDaemon(stagedImage)
    doAssert resolveNixDaemonExecutable(cwd = foreign / "a" / "b" / "c",
      exePath = stagedImage, envSourceRoot = "", envBin = "") ==
      "reprobuild-nix-daemon"

  test "a filesystem root is never an anchor, and nothing repeats":
    let roots = nixDaemonSearchRoots("", "/usr/bin/repro", "")
    for entry in roots:
      doAssert not isRootDir(entry.root),
        "anchored on a filesystem root: " & entry.root
    # One root, and it is the install prefix: the great-grandparent of
    # `/usr/bin/repro` is the filesystem root and is dropped. Compared by
    # its LAST COMPONENT because `parentDir` normalises the separator to
    # the host's, so the literal `/usr` comes back backslash-rooted on
    # Windows.
    doAssert roots.len == 1, $roots
    doAssert roots[0].root.lastPathPart == "usr", roots[0].root
    doAssert roots[0].label == "app-prefix", roots[0].label
    let cands = paths(nixDaemonCandidates(cwd = "/usr",
      exePath = "/usr/bin/repro", envSourceRoot = "/usr"))
    var seen = initHashSet[string]()
    for c in cands:
      doAssert not seen.containsOrIncl(c), "duplicate candidate: " & c

  test "a #! interpreter that is not on this host is REFUSED, not spawned":
    # M1's N33, from the engine's side. Every Linux package shipped
    # `libexec/reprobuild/reprobuild-nix-daemon` with
    # `#!/nix/store/<hash>-python3-3.13.12/bin/python3` on line 1, and
    # this resolver ACCEPTED it: the file exists and the file is 0755,
    # so the override was honoured and the process died inside `execve`
    # with ENOENT -- surfacing as "Failed to connect or spawn
    # reprobuild-nix-daemon at <socket>", the exact opaque failure
    # `flake.nix`'s comment says the interpreter substitution was added
    # to fix. ENOENT for a missing INTERPRETER is indistinguishable from
    # ENOENT for a missing IMAGE unless something reads line 1.
    #
    # THE PARSER FIRST, with no filesystem in it at all, so this half of
    # the case says the same thing on every host.
    doAssert shebangInterpreter("#!/usr/bin/python3") == "/usr/bin/python3"
    doAssert shebangInterpreter("#!/usr/bin/env python3") == "/usr/bin/env"
    doAssert shebangInterpreter("#! /bin/sh -e") == "/bin/sh"
    doAssert shebangInterpreter("#!/nix/store/pz-python3-3.13.12/bin/python3") ==
      "/nix/store/pz-python3-3.13.12/bin/python3"
    doAssert shebangInterpreter("import sys") == ""
    # A RELATIVE shebang is not this predicate's business: what the
    # kernel execs there is whatever PATH resolves, and answering a bare
    # name would make the caller check the wrong thing.
    doAssert shebangInterpreter("#!python3") == ""

    let repo = scratch("shebang")
    let exe = repo / "build" / "bin" / "repro"
    placeDaemon(exe)
    # NOT A SCRIPT AT ALL, and not refused: the check must not turn
    # every ELF helper into a build failure by misreading its first
    # bytes as a shebang.
    let elfish = repo / "elsewhere" / "binary-helper"
    createDir(elfish.parentDir)
    # Written from `chr` values rather than from escapes: the first
    # bytes of an ELF image are not text, and a source line that
    # spells them as escapes is a line every transport in this
    # campaign has mangled at least once.
    writeFile(elfish, $chr(0x7F) & "ELF" & $chr(2) & $chr(1) &
      $chr(1) & $chr(0) & "padding")
    doAssert unresolvableScriptInterpreter(elfish) == ""
    # A path that is not there at all is likewise not a shebang problem.
    doAssert unresolvableScriptInterpreter(repo / "nothing-here") == ""

    # THE SHIPPED SHAPE. POSIX only, and deliberately: Windows' loader
    # does not read the first line of a file, so a `#!` there is a
    # comment and `unresolvableScriptInterpreter` answers "" by
    # construction. Asserting a refusal on a platform with no mechanism
    # would be asserting the check's own stub.
    when defined(posix):
      let bad = repo / "elsewhere" / "reprobuild-nix-daemon"
      writeFile(bad,
        "#!/no-such-python-dir-for-n33/bin/python3" & "\n" & "exit 0" & "\n")
      setFilePermissions(bad, {fpUserRead, fpUserWrite, fpUserExec})
      doAssert unresolvableScriptInterpreter(bad) ==
        "/no-such-python-dir-for-n33/bin/python3"
      var refused = false
      var msg = ""
      try:
        discard resolveNixDaemonExecutable(cwd = repo, exePath = exe,
          envSourceRoot = "", envBin = bad)
      except CatchableError as e:
        refused = true
        msg = e.msg
      doAssert refused,
        "a helper whose interpreter is absent was accepted, and would " &
        "have died inside execve with nothing to read"
      doAssert "no-such-python-dir-for-n33" in msg, msg
      # AND IT DOES NOT REFUSE EVERYTHING, which is what makes the arm
      # above mean something: the `#!/bin/sh` helper `placeDaemon`
      # writes names an interpreter every POSIX host has, and it still
      # resolves.
      let good = repo / "tools" / "reprobuild-nix-daemon" /
        "reprobuild-nix-daemon"
      placeDaemon(good)
      doAssert unresolvableScriptInterpreter(good) == ""
      doAssert resolveNixDaemonExecutable(cwd = repo, exePath = exe,
        envSourceRoot = "", envBin = good) == good
