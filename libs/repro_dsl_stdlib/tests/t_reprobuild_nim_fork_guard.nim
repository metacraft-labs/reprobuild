## The `.#prefix` guard on the Nim compiler (reprobuild-pm
## Distribution-And-Packaging.md §5.3, decision N, as amended on
## 2026-11-03 by Zahary Karadjov's decision: guard, not a new realization).
##
## The prefix ships the catalog's `nim-fork` under `nim/`, and an installed
## reprobuild compiles with the compiler it was built by, so the images'
## compiler must BE that fork. Path mode takes whatever `nim` PATH offers and
## falls back to the stock tarball Nim 2.2.10 when PATH has none (measured
## 2026-11-03: an armv7 `.#release` run outside the dev shell generated C
## "by Nim Compiler v2.2.10"). The guard refuses then, naming the compiler.
##
## What it compares, and why: the fork binary records no revision, so the
## guard checks (1) the catalog fork's recorded revision against
## `flake.lock`'s `nim-fork-src` -- the fork the dev shell builds -- and (2)
## that the `nim` on the edge's PATH resolves to an installation whose
## `lib/` is the fork's `lib/`, byte for byte. Stock Nim's standard library
## differs from the fork's, so (2) cannot pass for it.
##
## NO MOCKS of the guard: its own shell program runs. The "compilers" are
## real directories with a `bin/nim` script that answers `--version`, as an
## installation does; only the compiler binary is a stand-in, because the
## guard never runs it beyond `--version`.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packaging/reprobuild_dist

const
  ForkRev = "9a49ee3ca32c9cd2fe467806e61d47c3a6a7ccc1"
  FlakeLock = """{
  "nodes": {
    "nim-csources-src": {
      "locked": {
        "rev": "eeab3ac46e93f10efda8e58c4db02b9438319d71",
        "type": "github"
      }
    },
    "nim-fork-src": {
      "flake": false,
      "locked": {
        "lastModified": 1793432134,
        "ref": "codetracer",
        "rev": "9a49ee3ca32c9cd2fe467806e61d47c3a6a7ccc1",
        "type": "git"
      }
    }
  }
}
"""

proc installation(dir, version, libText: string) =
  ## A Nim installation: `bin/nim` answering `--version`, and `lib/`.
  createDir(dir / "bin")
  createDir(dir / "lib" / "system")
  writeFile(dir / "lib" / "system.nim", libText)
  writeFile(dir / "lib" / "system" / "fatal.nim", "# fatal\n")
  writeFile(dir / "bin" / "nim", "#!/bin/sh\necho 'Nim Compiler Version " &
    version & " [Linux: amd64]'\n")
  setFilePermissions(dir / "bin" / "nim", {fpUserRead, fpUserWrite, fpUserExec})

proc forkMirror(dir, rev: string) =
  ## The catalog's `nim-fork` built for the target: `nim/` with the fork's
  ## `lib/` and the revision it was built from.
  installation(dir / "nim", "2.3.1", "# the fork's system\n")
  writeFile(dir / "nim" / ".nim-fork-revision", rev & "\n")

proc guard(root, compiler: string): tuple[output: string, code: int] =
  let script = nimForkGuardScript(root / "mirror" / "nim", root / "flake.lock")
  let r = execCmdEx("sh -c " & quoteShell(script), workingDir = root,
    env = newStringTable({"PATH": compiler / "bin" & ":" & getEnv("PATH")},
      modeCaseSensitive))
  (r.output, r.exitCode)

suite "the prefix's Nim is the fork its images were compiled with":

  test "the fork at the pinned revision passes":
    let root = createTempDir("nim-guard-ok-", "")
    defer: removeDir(root)
    writeFile(root / "flake.lock", FlakeLock)
    forkMirror(root / "mirror", ForkRev)
    installation(root / "host", "2.3.1", "# the fork's system\n")
    let r = guard(root, root / "host")
    checkpoint(r.output)
    check r.code == 0

  test "the stock tarball Nim is refused, naming it":
    let root = createTempDir("nim-guard-stock-", "")
    defer: removeDir(root)
    writeFile(root / "flake.lock", FlakeLock)
    forkMirror(root / "mirror", ForkRev)
    installation(root / "stock", "2.2.10", "# stock system\n")
    let r = guard(root, root / "stock")
    checkpoint(r.output)
    check r.code != 0
    check (root / "stock" / "bin" / "nim") in r.output
    check "Nim Compiler Version 2.2.10" in r.output
    check "not the fork" in r.output

  test "a fork whose standard library differs is refused":
    let root = createTempDir("nim-guard-lib-", "")
    defer: removeDir(root)
    writeFile(root / "flake.lock", FlakeLock)
    forkMirror(root / "mirror", ForkRev)
    installation(root / "other", "2.3.1", "# another revision's system\n")
    let r = guard(root, root / "other")
    checkpoint(r.output)
    check r.code != 0
    check "lib/system.nim" in r.output

  test "a catalog fork at another revision than flake.lock is refused":
    let root = createTempDir("nim-guard-rev-", "")
    defer: removeDir(root)
    writeFile(root / "flake.lock", FlakeLock)
    forkMirror(root / "mirror", repeat('b', 40))
    installation(root / "host", "2.3.1", "# the fork's system\n")
    let r = guard(root, root / "host")
    checkpoint(r.output)
    check r.code != 0
    check ForkRev in r.output
    check repeat('b', 40) in r.output

  test "no nim on PATH is refused by name":
    let root = createTempDir("nim-guard-none-", "")
    defer: removeDir(root)
    writeFile(root / "flake.lock", FlakeLock)
    forkMirror(root / "mirror", ForkRev)
    let script = nimForkGuardScript(root / "mirror" / "nim", root / "flake.lock")
    # A PATH of the guard's own tools and nothing else: no nim.
    var dirs: seq[string]
    for tool in @NimForkGuardTools & @["sh"]:
      let dir = findExe(tool).parentDir
      if dir notin dirs: dirs.add(dir)
    for dir in dirs:
      require not fileExists(dir / "nim")
    let r = execCmdEx("sh -c " & quoteShell(script), workingDir = root,
      env = newStringTable({"PATH": dirs.join(":")}, modeCaseSensitive))
    checkpoint(r.output)
    check r.exitCode != 0
    check "no nim" in r.output
