## A managed hook resolves the ``repro`` that INSTALLED it before whatever is
## on ``PATH``; ``PATH`` is the fallback for when that build is gone, and an
## explicit ``REPROBUILD_REPRO`` still outranks both.
##
## Recorded in reprobuild-pm
## ``issues/2026-11-12-ambient-hooks-ensure-is-declared-safe-even-though-it-is-the-documented-self-concealing.md``;
## the contract is reprobuild-pm ``spec/CLI/hooks.md`` §"Contract Handshake
## And Stand-Down", bullet "Per-install resolution".
##
## Why it matters. A body used to resolve ``$REPROBUILD_REPRO`` else the first
## ``repro`` on ``PATH``, so which build serviced a hook was a property of the
## shell ``git`` ran in: one shell's dev environment dispatched, another's
## refused, and a stale shell running ``hooks ensure`` re-authored the hooks to
## its own build. Baking the installing build's path into the body (as
## pre-commit's generated shim bakes ``INSTALL_PYTHON``) makes it a property of
## the install.
##
## Arms:
##
##   (A) The body carries ``REPRO_INSTALLING_BUILD=<the installing engine>``.
##   (B) With a refusing ``repro`` FIRST on ``PATH``, a ``git commit`` fires
##       ``post-commit`` and the stub is never asked: the installed build
##       serviced the hook.
##   (C) Make the installed build refuse (the body's token changed to one no
##       build generates) and fire again: the refusal names the installing
##       build and ``resolved from installing-build``, not the stub. This is
##       the arm that reads the resolution out of the hook's own words.
##   (D) ``REPROBUILD_REPRO`` still outranks the baked path.
##   (E) Delete the installing build and fire again: the hook falls back to
##       ``PATH`` and the stub is resolved, ``resolved from PATH``.
##
## The installing build is a COPY of the real build (``repro`` and its engine
## ``reprobuild``, siblings as installed), so that (E) can delete it without
## touching the tree under test. The ``repro`` first on ``PATH`` is a STUB,
## justified as in the PG-14 suites: it stands for a different build on the
## operator's ``PATH``, which cannot be produced hermetically. It answers the
## handshake with exit 3 ("I generate a different body"), exactly as a real
## sibling build does, and logs that it was asked. Git, the hooks and the build
## that installs them are real.
##
## Hermetic: one ``createTempDir``, local bare repositories only, no network.
## Skip rule: ``git`` missing on PATH.

from repro_core/process_streams import drainStream
import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import repro_core/process_env

import repro_core/cli_images
import repro_test_support
import repro_test_support/process_fixtures
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShellPosix(value)

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc engineBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / reprobuildEngineExeName(),
    "reprobuild.apps.repro")

const contractFlag = "--hook-contract="

proc pathWithoutAnyRepro(): string =
  ## The inherited PATH with every ``repro`` and ``reprobuild`` taken out of
  ## it, and nothing else. A directory that supplies one (a Nix profile's
  ## ``bin`` typically also supplies ``git`` and ``sh``) is replaced by a
  ## fixture-local SHADOW of it: a directory of symlinks to every other entry.
  ## Dropping such a directory whole would also drop the tools the hooks need.
  var kept: seq[string]
  var shadowIndex = 0
  for dir in getEnv("PATH").split(PathSep):
    if dir.len == 0 or not dirExists(dir):
      continue
    if not (fileExists(dir / addFileExt("repro", ExeExt)) or
        fileExists(dir / addFileExt("reprobuild", ExeExt))):
      kept.add(dir)
      continue
    let shadow = getTempDir() / ("repro-path-shadow-" & $getCurrentProcessId() &
      "-" & $shadowIndex)
    inc shadowIndex
    if not dirExists(shadow):
      # Released by the process that made it, whichever case that was.
      releaseDirAtProcessExit(shadow)
      createDir(shadow)
      for kind, entry in walkDir(dir):
        let name = extractFilename(entry)
        if name.startsWith("repro") or name.startsWith(".repro"):
          continue
        try:
          createSymlink(entry, shadow / name)
        except OSError:
          discard
    kept.add(shadow)
  kept.join($PathSep)

proc run(args: openArray[string]; pathHead: string;
         reproOverride = ""; cwd = getCurrentDir()): CmdResult =
  var env = inheritedEnvTable()
  for key in ["REPROBUILD_REPRO", "REPRO_PUBLIC_CLI_PATH", "REPRO_FULL_CLI",
      "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"]:
    env.del(key)
  if reproOverride.len > 0:
    env["REPROBUILD_REPRO"] = reproOverride
  env["PATH"] = pathHead & $PathSep & pathWithoutAnyRepro()
  let process = startProcess(args[0], workingDir = cwd, args = args[1 .. ^1],
    env = env, options = {poStdErrToStdOut, poUsePath})
  defer: process.close()
  let output = drainStream(process.outputStream)
  (code: process.waitForExit(), output: output)

proc requireOk(args: openArray[string]; pathHead: string): string =
  let res = run(args, pathHead)
  if res.code != 0:
    checkpoint("command failed: " & args.join(" ") & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc writeLoggingStub(path, log: string) =
  ## A ``repro`` that generates a different body than anything installed
  ## here: it answers every handshake with 3 and records that it was asked.
  writeFile(path,
    "#!/bin/sh\n" &
    "printf '%s\\n' \"$*\" >> " & q(log) & "\n" &
    "if [ \"${1:-}\" = hooks ] && [ \"${2:-}\" = protocol ]; then\n" &
    "  echo 'stub: this build generates a different body' >&2\n" &
    "  exit 3\n" &
    "fi\n" &
    "if [ \"${1:-}\" = --version ]; then echo 'repro 0.0.0-stub'; fi\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

proc readOrEmpty(path: string): string =
  if fileExists(path): readFile(path) else: ""

suite "a managed hook resolves the build that installed it":

  test "the installing build outranks PATH, REPROBUILD_REPRO outranks both, PATH is the fallback":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the case fires real git hooks")
    else:
      let scratch = createTempDir("repro-installing-build-", "")
      defer: removeDir(scratch)

      # The installing build: a copy of the real build, laid out as installed.
      # Its directory name carries a space and a single quote, so (A) and (C)
      # also pin that the baked assignment is quoted for the shell and read
      # back intact: an unquoted or wrongly escaped path would either fail to
      # parse (the hook would not run at all) or resolve a different file.
      let installRoot = scratch / "installing build's copy"
      let copyDir = installRoot / "bin"
      createDir(copyDir)
      let copyRepro = copyDir / addFileExt("repro", ExeExt)
      let copyEngine = copyDir / reprobuildEngineExeName()
      copyFileWithPermissions(reproBinary(), copyRepro)
      copyFileWithPermissions(engineBinary(), copyEngine)

      # The other build, first on PATH for every command below.
      let stubDir = scratch / "path-bin"
      createDir(stubDir)
      let stub = stubDir / "repro"
      let stubLog = scratch / "path-stub.log"
      writeLoggingStub(stub, stubLog)
      let explicitStub = scratch / "explicit-repro"
      let explicitLog = scratch / "explicit-stub.log"
      writeLoggingStub(explicitStub, explicitLog)

      let origin = scratch / "origin.git"
      discard requireOk([gitBin, "init", "--bare", "-b", "main", origin],
        stubDir)
      let repo = scratch / "repo"
      discard requireOk([gitBin, "clone", fileUrl(origin), repo], stubDir)
      discard requireOk([gitBin, "-C", repo, "config", "user.email",
        "tester@example.invalid"], stubDir)
      discard requireOk([gitBin, "-C", repo, "config", "user.name", "Tester"],
        stubDir)

      # Installed by the copy, from a shell whose PATH resolves the stub.
      let installed = run([copyRepro, "hooks", "ensure", "--vcs", repo],
        stubDir)
      checkpoint("install with the copy:\n" & installed.output)
      check installed.code == 0
      let managed = repo / ".git" / "hooks" / "post-commit.repro-managed"
      let canonical = readFile(managed)

      # ---- (A) ------------------------------------------------------------
      check ("REPRO_INSTALLING_BUILD=" & q(copyEngine)) in canonical.splitLines()

      # ---- (B) ------------------------------------------------------------
      let serviced = run([gitBin, "-C", repo, "commit", "--allow-empty", "-m",
        "serviced by the installing build"], stubDir)
      checkpoint("(B) commit:\n" & serviced.output)
      check serviced.code == 0
      check "could not be evaluated" notin serviced.output
      check readOrEmpty(stubLog) == ""

      # ---- (C) ------------------------------------------------------------
      let at = canonical.find(contractFlag) + contractFlag.len
      let token = canonical[at ..< canonical.find(' ', at)]
      let refusedBody = canonical.replace(token,
        token[0 .. token.rfind('.')] & "ffffffffffffffff")
      writeFile(managed, refusedBody)
      let viaInstaller = run([gitBin, "-C", repo, "commit", "--allow-empty",
        "-m", "refused by the installing build"], stubDir)
      checkpoint("(C) commit:\n" & viaInstaller.output)
      check viaInstaller.code == 0
      check ("resolved binary: " & copyEngine &
        " (resolved from installing-build)") in viaInstaller.output
      check readOrEmpty(stubLog) == ""

      # ---- (D) ------------------------------------------------------------
      let viaExplicit = run([gitBin, "-C", repo, "commit", "--allow-empty",
        "-m", "explicit override"], stubDir, reproOverride = explicitStub)
      checkpoint("(D) commit with REPROBUILD_REPRO:\n" & viaExplicit.output)
      check viaExplicit.code == 0
      check ("resolved binary: " & explicitStub &
        " (resolved from REPROBUILD_REPRO)") in viaExplicit.output
      check "hooks protocol" in readOrEmpty(explicitLog)
      check readOrEmpty(stubLog) == ""

      # ---- (E) ------------------------------------------------------------
      removeDir(installRoot)
      let viaPath = run([gitBin, "-C", repo, "commit", "--allow-empty", "-m",
        "installing build is gone"], stubDir)
      checkpoint("(E) commit after deleting the installing build:\n" &
        viaPath.output)
      check viaPath.code == 0
      check ("resolved binary: " & stub & " (resolved from PATH)") in
        viaPath.output
      check "hooks protocol" in readOrEmpty(stubLog)
