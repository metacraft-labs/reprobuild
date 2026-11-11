## The profile compile runs `nim` in a directory private to the compile, so
## two profile compiles at once cannot share Nim's linker response file, and
## the compile writes no scratch file into the reprobuild source root.
##
## The failure this pins down
## --------------------------
## When the link command is long, Nim writes `<project>_linkerArgs.txt` into
## its CURRENT DIRECTORY, links with `@<that file>` and deletes it. The profile
## compile used to run every `nim` with the reprobuild source root as its
## working directory, and every profile is named `home` (or `system`), so two
## profile compiles in flight at once shared one response file. Parallel
## gate runs on Windows showed all three outcomes: `ld` could not find the
## file (the other compile had deleted it), `ld` read a mix of both compiles'
## arguments, and a compile exited 0 having linked the other one's binary
## (reprobuild-pm issue
## 2026-10-20-concurrent-profile-compiles-race-on-the-nim-linker-response-file-in-the-source-root).
##
## How the test makes the collision deterministic
## ----------------------------------------------
## A race is not a test. The losing side of it is: the response file's path
## is occupied by something that is not this compile's file. Each case puts
## a DIRECTORY at `<dir>/home_linkerArgs.txt`, where Nim's `writeFile` of the
## response file fails whatever the process's privileges (the suite runs as
## root in some containers, where a read-only directory would not stop it):
##
##   1. the occupied path is in the source root the compile is handed. The
##      compile must still link: it must not be writing there at all. Before
##      the fix this failed with Nim's "cannot open: home_linkerArgs.txt".
##   2. the occupied path is in the compile's own nimcache. The compile must
##      FAIL, naming the response file. This is the vacuity guard for case 1:
##      it proves the link really went through a response file, and that the
##      file is written in the compile's own directory. Without it, a link
##      command short enough for Nim to pass on the command line would let
##      case 1 pass on the unfixed code.
##
## The source root is a fresh directory of symbolic links to this checkout's
## top-level entries, so the occupied path never touches the checkout other
## tests read. The nimcache path is made long enough that the link command
## exceeds Nim's command-line limit on Linux (32 000 characters), the
## threshold above which it uses a response file.
##
## Linux only. On macOS Nim's limit is 260 000 characters, more than a
## profile's few dozen object paths can carry within PATH_MAX, so case 2
## cannot hold and case 1 would prove nothing. On Windows, where the failure
## was observed, creating the symbolic links needs a privilege the runners
## do not grant. The fix is the same code on every platform.
##
## Falsifying mutation (performed while writing the test, 2026-11-05):
## passing the source root as `startProfileNim`'s working directory in
## `compileProfileExecutable` again makes case 1 fail with
## `cannot open: home_linkerArgs.txt` and case 2 succeed.
##
## The third case pins the compiler path to an absolute one: with `nim`
## running in the nimcache, a relative path would no longer resolve against
## the caller's directory.
##
## Mocks: none. The real `nim` and C toolchain of the dev shell compile a real
## profile against reprobuild's real sources.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
from repro_core/paths import extendedPath

import repro_profile_compile

const ProfileBody = """
import repro_profile

profile "linksInItsOwnDirectory":
  resources:
    fsUserFile(hostFile = "~/links-in-its-own-directory.txt",
      content = "planned only")
"""

const ResponseFileName = "home_linkerArgs.txt"
  ## What Nim names the response file for a project called `home`
  ## (`compiler/extccomp.nim`, `linkViaResponseFile`).

template withEnv(name, value: string; body: untyped) =
  let hadOld = existsEnv(name)
  let old = getEnv(name)
  if value.len > 0: putEnv(name, value) else: delEnv(name)
  try:
    body
  finally:
    if hadOld: putEnv(name, old) else: delEnv(name)

proc symlinkedSourceRoot(dir: string): string =
  ## A directory whose entries are symbolic links to this checkout's
  ## top-level entries: a reprobuild source root the test may write into.
  result = dir / "source-root"
  createDir(result)
  for _, path in walkDir(CompiledRepoRoot):
    let name = path.extractFilename
    if name notin [".git", "build", "test-logs"]:
      createSymlink(path, result / name)

proc longNimcache(dir: string): string =
  ## A nimcache path of about 1 500 characters. Every object file on the
  ## link line carries it, so even a few dozen objects put the link command
  ## over Nim's response-file threshold.
  result = dir
  for i in 0 ..< 6:
    result = result / ("nimcache-segment-" & $i & "-" & repeat('n', 220))

proc occupy(dir: string) =
  ## Put a directory where Nim writes its response file in `dir`.
  createDir(extendedPath(dir / ResponseFileName))

when not defined(linux):
  suite "the profile compile links in its own directory":
    test "Linux only":
      # See the header: macOS's limit is out of reach of the link line, and
      # the symlinked source root needs a privilege on Windows.
      skip("Linux only: see the header of this file")
else:
  suite "the profile compile links in its own directory":
    test "an occupied response-file path in the source root does not " &
        "stop the link":
      let dir = createTempDir("repro-profile-own-cwd-", "")
      defer: removeDir(dir)
      let root = symlinkedSourceRoot(dir)
      occupy(root)
      let profile = dir / "profile" / "home.nim"
      createDir(profile.parentDir)
      writeFile(profile, ProfileBody)
      let binary = dir / "out" / addFileExt("profile-build", ExeExt)
      try:
        discard compileProfileExecutable(profile, longNimcache(dir), binary,
          root)
      except CompileFailure as err:
        checkpoint(err.msg & "\n" & err.stderrText)
        check false
      check fileExists(extendedPath(binary))
      # The occupant is untouched: nothing was written over or beside it.
      check dirExists(extendedPath(root / ResponseFileName))

    test "the response file is written in the compile's own nimcache":
      let dir = createTempDir("repro-profile-own-cwd-guard-", "")
      defer: removeDir(dir)
      let profile = dir / "profile" / "home.nim"
      createDir(profile.parentDir)
      writeFile(profile, ProfileBody)
      let nimcache = longNimcache(dir)
      createDir(extendedPath(nimcache))
      occupy(nimcache)
      let binary = dir / "out" / addFileExt("profile-build", ExeExt)
      var failure = ""
      try:
        discard compileProfileExecutable(profile, nimcache, binary,
          symlinkedSourceRoot(dir))
      except CompileFailure as err:
        failure = err.stderrText
      checkpoint(failure)
      check ResponseFileName in failure
      check not fileExists(extendedPath(binary))

    test "a nim found through a relative PATH entry is named absolutely":
      # `nim` runs in the nimcache, so a compiler path relative to the
      # caller's directory would name nothing there. `findExe` returns one
      # for a relative `PATH` entry.
      let dir = createTempDir("repro-profile-relative-nim-", "")
      let here = getCurrentDir()
      defer:
        setCurrentDir(here)
        removeDir(dir)
      createDir(dir / "relbin")
      writeFile(dir / "relbin" / "nim", "#!/bin/sh\n")
      setFilePermissions(dir / "relbin" / "nim",
        {fpUserRead, fpUserWrite, fpUserExec})
      setCurrentDir(dir)
      # An installed prefix would answer before PATH is searched.
      withEnv("REPRO_PUBLIC_CLI_PATH", ""):
        withEnv("PATH", "relbin"):
          # Both lookups through PATH: the default one, and a bare
          # command name in `$REPRO_NIM_COMPILER`.
          for explicit in ["", "nim"]:
            withEnv(ProfileNimCompilerEnvVar, explicit):
              let chosen = resolveProfileNimCompiler()
              checkpoint("REPRO_NIM_COMPILER=" & explicit & " chose " & chosen)
              check chosen.isAbsolute
              # `sameFile`, not a string comparison: the temporary
              # directory may be reached through a symbolic link.
              check sameFile(chosen, dir / "relbin" / "nim")
