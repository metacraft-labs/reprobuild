## A compile for another machine (`-d:reproZigTarget=<triple>`, as `nim.c`
## passes it under a zig target) uses the vendored blake3 and xxhash whatever
## the build shell asks for (reprobuild-pm Distribution-And-Packaging.md
## §5.3, decision B: the prefix images depend on nothing of the build host).
##
## The dev shell exports REPROBUILD_USE_SYSTEM_HASH_LIBS=1, and under it the
## armv7 providers linked `libblake3.so.0` and `libxxhash.so.0`, which the
## prefix does not ship (measured 2026-11-03).
##
## The define has to be on the command line, as `nim.c` puts it: this
## repository's `config.nims` runs before a test's own `.nim.cfg`, so a
## `.nim.cfg` define is invisible to it. Each case therefore runs `nim check`
## on a probe under this repository, which reads `config.nims` as an image's
## compile does, and the probe reports the define at compile time. Nothing
## is mocked.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir

proc vendoredHashUnder(args: openArray[string]): string =
  ## "vendored=true|false" as the probe saw it, or the compiler's output.
  createDir(RepoRoot / "build")
  let dir = createTempDir("zig-target-hash-", "", RepoRoot / "build")
  defer: removeDir(dir)
  let probe = dir / "probe.nim"
  writeFile(probe,
    "static: echo \"vendored=\", defined(reproVendoredHash)\n")
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  env["REPROBUILD_USE_SYSTEM_HASH_LIBS"] = "1"
  let r = execCmdEx(findExe("nim") & " check --hints:off --warnings:off " &
    args.join(" ") & " " & quoteShell(probe), env = env, workingDir = RepoRoot)
  for line in r.output.splitLines:
    if line.startsWith("vendored="): return line
  r.output

suite "a zig-target image links the vendored hash libraries":
  test "a native compile in a system-hash shell takes the system libraries":
    # The control: the variable does select system-hash mode.
    check vendoredHashUnder([]) == "vendored=false"

  test "a zig-target compile in that shell takes the vendored ones":
    check vendoredHashUnder(
      ["-d:reproZigTarget=armv7-unknown-linux-gnueabihf"]) == "vendored=true"
