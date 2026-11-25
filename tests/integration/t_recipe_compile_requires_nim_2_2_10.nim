## A recipe compile refuses a compiler older than Nim 2.2.10 and says so.
##
## Operator decision of 2026-11-24 (reprobuild-pm
## `issues/2026-10-20-interface-extraction-nimcache-name-exceeds-name-max-for-deep-recipe-paths.md`):
## recipe compilation requires Nim 2.2.10. An explicit `REPRO_NIM_COMPILER`
## naming an older release must stop the command with an error that names the
## requirement, the release found and the way out, and must not be followed by
## a compile that dies later with `cannot open`.
##
## MOCK POLICY. The test runs the real `build/bin/repro` as a subprocess. The
## only substitution is the COMPILER BINARY the environment names: a shell
## script that answers `--version` the way Nim 2.2.4 does. It is justified
## because the behaviour under test is the refusal that reads that answer, and
## no Nim 2.2.4 is available to every host that runs this suite (the engine's
## own bootstrap no longer provisions one). Nothing downstream of the refusal
## is faked: a second case names the real compiler of the run's `nim` on PATH
## and expects the same command to get past the check.
##
## POSIX only: the stub is a `sh` script.

import std/[os, osproc, strtabs, strutils, unittest]

const Recipe = """
import repro_project_dsl

package olderguard:
  build:
    discard
"""

proc reproBinary(repoRoot: string): string =
  repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc runList(reproBin, recipe: string; compiler: string): tuple[output: string,
    exitCode: int] =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["REPRO_NIM_COMPILER"] = compiler
  # `--no-runquota`: the refusal under test happens before any action runs,
  # and a RunQuota daemon that cannot start in a sandbox would fail the
  # command first for a reason that has nothing to do with the compiler.
  execCmdEx(quoteShellCommand([reproBin, "build", "--list-targets",
    "--no-runquota", "--daemon=off", "--tool-provisioning=path", recipe]),
    env = env)

when defined(windows):
  suite "recipe compile requires Nim 2.2.10":
    test "posix only":
      skip()
else:
  suite "recipe compile requires Nim 2.2.10":
    test "Nim 2.2.4 is refused with the requirement named":
      let repoRoot = getCurrentDir()
      let reproBin = reproBinary(repoRoot)
      if not fileExists(reproBin):
        checkpoint("missing " & reproBin & "; run `just build` first")
        fail()
      else:
        let root = getTempDir() / ("rb-nim224-" & $getCurrentProcessId())
        removeDir(root)
        defer: removeDir(root)
        createDir(root / "ws")
        writeFile(root / "ws" / "repro.nim", Recipe)
        let stub = root / "nim"
        writeFile(stub, "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n" &
          "  echo 'Nim Compiler Version 2.2.4 [Linux: amd64]'\n  exit 0\nfi\n" &
          "echo 'the stub compiler does not compile' >&2\nexit 1\n")
        setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec})
        let res = runList(reproBin, root / "ws" / "repro.nim", stub)
        checkpoint(res.output)
        check res.exitCode != 0
        check "requires Nim 2.2.10 or newer" in res.output
        check "Nim 2.2.4" in res.output
        check "operator decision of 2026-11-24" in res.output
        check "REPRO_NIM_COMPILER" in res.output
        # Refused up front, not after a compile that failed on a file name.
        check "cannot open" notin res.output

    test "a compiler that answers 2.2.10 is not refused by the check":
      let repoRoot = getCurrentDir()
      let reproBin = reproBinary(repoRoot)
      if not fileExists(reproBin):
        checkpoint("missing " & reproBin & "; run `just build` first")
        fail()
      else:
        let root = getTempDir() / ("rb-nim2210-" & $getCurrentProcessId())
        removeDir(root)
        defer: removeDir(root)
        createDir(root / "ws")
        writeFile(root / "ws" / "repro.nim", Recipe)
        let stub = root / "nim"
        # Answers 2.2.10 and then fails the compile on its own terms: the
        # point is only that the floor does not stop it first.
        writeFile(stub, "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n" &
          "  echo 'Nim Compiler Version 2.2.10 [Linux: amd64]'\n  exit 0\nfi\n" &
          "echo 'the stub compiler does not compile' >&2\nexit 1\n")
        setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec})
        let res = runList(reproBin, root / "ws" / "repro.nim", stub)
        checkpoint(res.output)
        check "requires Nim 2.2.10 or newer" notin res.output
