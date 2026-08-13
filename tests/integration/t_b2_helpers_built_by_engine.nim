## Bootstrap-And-Self-Build B2: ``repro build .#test-helpers``
## materialises the three test-helper binaries through the engine.
##
## The B2 milestone declares ``executable liveEndpointHelper`` /
## ``fakeProtocolDaemonHelper`` / ``harnessApplyLockHolder`` in
## ``repro.nim`` and adds per-helper typed ``nim.c(...)`` edges +
## a ``test-helpers`` build graph collection. This test drives the
## engine end-to-end against the collection and asserts each helper
## binary lands at ``build/test-bin/<name>`` with non-empty content.
##
## We invoke each helper with no arguments (or an obviously invalid
## one) and accept any exit code as long as the binary loaded and
## produced some text — every one of the three prints a usage banner
## on stderr when given too few args. That's enough to prove the
## binary is the right helper and not a zero-byte stub or wrong-arch
## artifact.
##
## Skip-when-absent: same pattern as the B0 / B1 tests. If
## ``./build/bin/repro`` is missing (no prior ``just build``) or the
## sibling ``runquotad`` isn't on PATH, we skip cleanly rather than
## fail — those are genuine environment gates, checked BEFORE the build.
##
## No failure classifier. This case used to run its non-zero exit past a
## ``looksLike…(output)`` predicate that matched the engine's own diagnostic
## against a needle list and reclassified the failure as a skip on a match.
## The list covered ordinary engine failures — tool resolution, provisioning,
## the CLI usage dump — so any NEW failure phrased in those terms disappeared
## silently, which is a way of manufacturing green rather than a record of an
## environment limitation. The genuine environment gates (is the sibling
## checkout present, is ``./build/bin/repro`` built) are unchanged: they are
## checked BEFORE the work and they still skip. What the engine does once the
## work starts is now simply asserted.

import std/[os, osproc, strtabs, strutils, unittest]

const RepoMarker = "repro.nim"

const HelperNames = [
  "live_endpoint_helper",
  "fake_protocol_daemon_helper",
  "harness_apply_lock_holder",
]

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc runWithRunquotaOnPath(cmd, repoRoot: string): tuple[output: string;
    exitCode: int] =
  let runquotaBin = repoRoot.parentDir / "runquota" / "build" / "bin"
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let oldPath = env.getOrDefault("PATH")
  env["PATH"] = runquotaBin & $PathSep & oldPath
  execCmdEx(cmd, env = env, workingDir = repoRoot)

suite "Bootstrap-And-Self-Build B2: test-helpers built by engine":

  test "engine materialises every test-helper binary via .#test-helpers":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = repoRoot.parentDir / "runquota" / "build" / "bin" /
      addFileExt("runquotad", ExeExt)

    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    elif not fileExists(runquotad):
      checkpoint("skipped — " & runquotad &
        " is missing; build runquota first " &
        "(``cd ../runquota && just build``)")
      skip()
    else:
      # Remove the three helper binaries first so we know the engine
      # produced them on this run (not residual artifacts from an
      # earlier ``scripts/run_tests.sh`` invocation).
      for name in HelperNames:
        let helper = repoRoot / "build" / "test-bin" /
          addFileExt(name, ExeExt)
        if fileExists(helper):
          try: removeFile(helper) except OSError: discard

      # The collection name is ``test-helpers`` but the path-vs-name
      # classifier would otherwise try to resolve it against the
      # on-disk tree. The ``.#test-helpers`` fragment form forces
      # name-resolution per Named-Targets M3 / CLI's build-target
      # selection rules — same convention as ``.#apps`` from B1.
      let args = @[
        reproBin.quoteShell,
        "build",
        ".#test-helpers",
        "--tool-provisioning=path",
        "--daemon=off",
        "--log=quiet",
        "--progress=quiet",
        "--measure=none",
      ]
      let cmd = args.join(" ")
      checkpoint("running: " & cmd)
      let (output, exitCode) = runWithRunquotaOnPath(cmd, repoRoot)
      checkpoint("exit=" & $exitCode)

      if exitCode != 0:
        checkpoint(output)
        check exitCode == 0
      else:
        # Engine returned 0 — every helper binary must now exist.
        for name in HelperNames:
          let helper = repoRoot / "build" / "test-bin" /
            addFileExt(name, ExeExt)
          check fileExists(helper)
          if fileExists(helper):
            let info = getFileInfo(helper)
            checkpoint(name & " size=" & $info.size)
            check info.size > 0

  test "each helper binary loads and prints a usage banner":
    ## Smoke check: each helper invoked with no args prints its usage
    ## banner on stderr and exits non-zero (exit 2 by convention).
    ## This proves the binary is the right helper and not a zero-byte
    ## stub. We don't require a specific exit code or specific text —
    ## the contract is just "loads and produces output."
    let repoRoot = findRepoRoot()
    var missing: seq[string] = @[]
    for name in HelperNames:
      let helper = repoRoot / "build" / "test-bin" /
        addFileExt(name, ExeExt)
      if not fileExists(helper):
        missing.add(name)
    if missing.len > 0:
      checkpoint("missing helpers: " & missing.join(", "))
      checkpoint("skipped — at least one helper binary is missing; " &
        "the previous subtest's build phase may have skipped.")
      skip()
    else:
      for name in HelperNames:
        let helper = repoRoot / "build" / "test-bin" /
          addFileExt(name, ExeExt)
        let cmd = helper.quoteShell
        let (output, exitCode) = execCmdEx(cmd,
          options = {poUsePath, poStdErrToStdOut})
        checkpoint(name & " (no-args) exit=" & $exitCode &
          " out-bytes=" & $output.len)
        # Helpers exit non-zero on missing args, but they must produce
        # SOME output (the usage banner). exitCode >= 0 catches the
        # OSError-from-execCmdEx case where the binary couldn't even
        # be spawned.
        check exitCode >= 0
        check output.len > 0
