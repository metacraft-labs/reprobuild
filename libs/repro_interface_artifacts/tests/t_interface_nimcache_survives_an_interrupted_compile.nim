## A nimcache that a compile was interrupted in is never reused as it was
## left.
##
## A host crash while `repro interface extract` was compiling left five
## zero-byte `.o` files in a slot of the shared interface-extraction
## nimcache. Their C sources had not changed, so Nim's staleness check kept
## the objects and linked them -- `undefined reference to 'main'` -- and
## every later extraction through that slot failed, for every agent on the
## host, until the files were deleted by hand.
##
## The rule is Tool-Owned-Caches.md §"Interrupted Use": the engine marks the
## directory in use before the tool starts, clears the mark only after a use
## that ended in order, and discards on entry a marked directory or one
## holding a zero-byte object. The cases below pin each
## half, through `runProviderCompilerCommand` and through the proc it
## reaches, `runNimcacheCompilerCommandHeld`, which the extraction calls
## directly for a compile into a slot of its pool:
##
##   * THE CALLER DIES MID-USE. A child process runs a guarded compile whose
##     "compiler" truncates objects to zero bytes, as an interrupted `cc`
##     leaves them, and then SIGKILLs that child -- the engine dies exactly
##     as it did in the host crash. A later real `nim c` into the same
##     nimcache must succeed and its binary must run.
##   * THE SAME, BUT CUT SHORT RATHER THAN EMPTIED. Objects truncated to a
##     non-empty prefix carry no zero-byte evidence, so only the mark can
##     catch them.
##   * A STORE LEFT BY AN OLDER ENGINE. Zero-byte objects with no mark must
##     be discarded too.
##   * AN ORDINARY FAILURE IS NOT A CRASH. A compile error clears the mark and
##     keeps the nimcache, so an error in a recipe costs no cold rebuild.
##
## MOCK POLICY - one stand-in, justified. The two real compiles in every case
## are a real `nim c` of a real program into a real nimcache, linked and run.
## The interrupted use is a shell script in the compiler's position: what
## the case needs is a use that dies after writing truncated objects and
## takes its caller with it, and the interruption it reproduces (a host
## crash, an OOM kill of the engine) cannot be made to happen at a chosen
## instant inside a real `nim c`. The script does to the nimcache exactly
## what the crash left -- objects of the right names, zero bytes long -- and
## the caller it kills is the production code path, not a model of it.

import std/[os, osproc, strtabs, strutils, tempfiles, times, unittest]

import repro_interface_artifacts

const ChildEnv = "REPRO_TEST_INTERRUPTED_COMPILE_CHILD"

when defined(posix):
  # Child mode: run one guarded "compile" whose compiler truncates objects
  # and then kills this process. Reaching the `quit` below means the kill did
  # not happen, which the parent reports.
  if getEnv(ChildEnv).len > 0:
    let parts = getEnv(ChildEnv).split('\t')
    doAssert parts.len == 3, getEnv(ChildEnv)
    let (script, nimcache, workDir) = (parts[0], parts[1], parts[2])
    discard runProviderCompilerCommand(
      @[script, "c", "--nimcache:" & nimcache, "prog.nim"], cwd = workDir)
    quit(3)

const ProgramSource = """
import std/strutils
echo "interrupted-compile-ok ", "x".repeat(3)
"""

proc nimExe(): string =
  result = findExe("nim")
  doAssert result.len > 0, "this test needs `nim` on PATH (run it in the dev shell)"

proc compileCommand(dir, nimcache, mainModule: string): seq[string] =
  ## The same argv each time, so the second compile finds every C source of
  ## the first unchanged -- the condition under which Nim reuses an object.
  @[nimExe(), "c", "--hints:off", "--skipParentCfg", "--parallelBuild:1",
    "--nimcache:" & nimcache, "--out:" & (dir / "prog"), dir / mainModule]

proc runProgram(dir: string): string =
  execProcess(dir / "prog", options = {}).strip()

proc objects(nimcache: string): seq[string] =
  for kind, path in walkDir(nimcache):
    if kind == pcFile and path.endsWith(".o"):
      result.add(path)

proc fileIdentity(path: string): (int64, int64) =
  let info = getFileInfo(path, followSymlink = false)
  (int64(info.id.file), info.lastWriteTime.toUnix * 1_000_000_000 +
    int64(info.lastWriteTime.nanosecond))

proc warmCompile(dir, nimcache: string) =
  writeFile(dir / "prog.nim", ProgramSource)
  discard runProviderCompilerCommand(compileCommand(dir, nimcache,
    "prog.nim"), cwd = dir)
  doAssert runProgram(dir) == "interrupted-compile-ok xxx"
  doAssert objects(nimcache).len >= 2, $objects(nimcache)
  removeFile(dir / "prog")

proc recompileAndRun(dir, nimcache: string; held = false): string =
  ## The later use: the same compile again. Returns "" on success (and the
  ## program ran) or the failure, so the case can print it. `held` launches
  ## it the way the interface extraction launches a compile into a slot it
  ## already holds (`runNimcacheCompilerCommandHeld`, no lock of its own);
  ## otherwise it goes through the provider compile's entry point, which
  ## takes the directory's lock and then reaches the same proc.
  let command = compileCommand(dir, nimcache, "prog.nim")
  try:
    if held:
      discard runNimcacheCompilerCommandHeld(command, cwd = dir)
    else:
      discard runProviderCompilerCommand(command, cwd = dir)
  except OSError as err:
    return err.msg
  let output = runProgram(dir)
  if output != "interrupted-compile-ok xxx":
    return "the program ran but printed: " & output
  ""

when defined(posix):
  suite "a nimcache a compile was interrupted in is not reused as it was left":

    proc killCallerMidUse(dir, nimcache, cut: string): int =
      ## Run a guarded "compile" in a child process whose compiler applies
      ## `cut` (a shell command over `$f`) to the main module's object (it
      ## defines `main`) and the system module's (it defines `=destroy` and
      ## the rest), as an interrupted `cc` leaves them, and then kills the
      ## child -- the engine that launched the compile. Returns the child's
      ## exit status.
      let script = dir / "interrupted-compiler.sh"
      writeFile(script, "#!/bin/sh\n" &
        "for f in \"" & nimcache & "\"/@mprog.nim.c.o \"" & nimcache &
          "\"/@psystem.nim.c.o; do " & cut & "; done\n" &
        "kill -KILL $PPID\n" &
        "sleep 5\n")
      setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
      var childEnv = newStringTable()
      for k, v in envPairs(): childEnv[k] = v
      childEnv[ChildEnv] = script & "\t" & nimcache & "\t" & dir
      let child = startProcess(getAppFilename(), workingDir = dir,
        env = childEnv, options = {poStdErrToStdOut, poParentStreams})
      result = child.waitForExit()
      child.close()

    test "the caller dies mid-use after objects were truncated":
      let dir = createTempDir("repro-interrupted-nimcache-", "")
      defer: removeDir(dir)
      let nimcache = dir / "nimcache"
      warmCompile(dir, nimcache)
      let childStatus = killCallerMidUse(dir, nimcache, ": > \"$f\"")
      checkpoint("child exit status: " & $childStatus)
      check childStatus == 128 + 9
      check getFileSize(nimcache / "@mprog.nim.c.o") == 0
      check getFileSize(nimcache / "@psystem.nim.c.o") == 0
      # The use did not end in order, so its mark is still there.
      check fileExists(nimcacheInUseMarkerPath(nimcache))
      let failure = recompileAndRun(dir, nimcache)
      checkpoint("second compile: " & failure)
      check failure == ""
      check not fileExists(nimcacheInUseMarkerPath(nimcache))
      for obj in objects(nimcache):
        check getFileSize(obj) > 0

    test "objects cut short but not emptied are caught by the mark alone":
      # No zero-byte file is left, so only the mark can tell this directory
      # from a good one: an interrupted write usually stops part way.
      let dir = createTempDir("repro-interrupted-nimcache-", "")
      defer: removeDir(dir)
      let nimcache = dir / "nimcache"
      warmCompile(dir, nimcache)
      let warmSize = getFileSize(nimcache / "@psystem.nim.c.o")
      let childStatus = killCallerMidUse(dir, nimcache,
        "head -c 64 \"$f\" > \"$f.cut\" && cat \"$f.cut\" > \"$f\" && " &
        "rm \"$f.cut\"")
      checkpoint("child exit status: " & $childStatus)
      check childStatus == 128 + 9
      check getFileSize(nimcache / "@mprog.nim.c.o") == 64
      check getFileSize(nimcache / "@psystem.nim.c.o") == 64
      check warmSize > 64
      check fileExists(nimcacheInUseMarkerPath(nimcache))
      let failure = recompileAndRun(dir, nimcache)
      checkpoint("second compile: " & failure)
      check failure == ""
      check not fileExists(nimcacheInUseMarkerPath(nimcache))
      check getFileSize(nimcache / "@psystem.nim.c.o") == warmSize

    test "zero-byte objects an older engine left without a mark are discarded":
      let dir = createTempDir("repro-interrupted-nimcache-", "")
      defer: removeDir(dir)
      let nimcache = dir / "nimcache"
      warmCompile(dir, nimcache)
      check not fileExists(nimcacheInUseMarkerPath(nimcache))
      writeFile(nimcache / "@mprog.nim.c.o", "")
      writeFile(nimcache / "@psystem.nim.c.o", "")
      # Launched as the extraction launches a compile into its slot.
      let failure = recompileAndRun(dir, nimcache, held = true)
      checkpoint("second compile: " & failure)
      check failure == ""
      for obj in objects(nimcache):
        check getFileSize(obj) > 0

    test "an ordinary compile error clears the mark and keeps the nimcache":
      let dir = createTempDir("repro-interrupted-nimcache-", "")
      defer: removeDir(dir)
      let nimcache = dir / "nimcache"
      warmCompile(dir, nimcache)
      let systemObject = nimcache / "@psystem.nim.c.o"
      # The directory's inode only: its mtime moves whenever Nim rewrites a
      # file in it, which an ordinary compile does.
      let warmDir = fileIdentity(nimcache)[0]
      let warmObject = fileIdentity(systemObject)
      writeFile(dir / "broken.nim", "proc broken( =\n")
      var message = ""
      try:
        discard runProviderCompilerCommand(compileCommand(dir, nimcache,
          "broken.nim"), cwd = dir)
      except OSError as err:
        message = err.msg
      checkpoint(message)
      check "command failed (1)" in message
      check not fileExists(nimcacheInUseMarkerPath(nimcache))
      # The same directory and the same object: nothing was discarded.
      check fileIdentity(nimcache)[0] == warmDir
      check fileIdentity(systemObject) == warmObject
      # And the warm cache still builds.
      check recompileAndRun(dir, nimcache) == ""
      check fileIdentity(systemObject) == warmObject
