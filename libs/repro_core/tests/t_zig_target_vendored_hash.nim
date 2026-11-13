## A compile for another machine (`-d:reproZigTarget=<triple>`, as `nim.c`
## passes it under a zig target) takes nothing from the build shell: it uses
## the vendored blake3 and xxhash whatever the shell asks for, and links no
## ambient OpenSSL (reprobuild-pm Distribution-And-Packaging.md §5.3,
## decision B, amendment B3: the prefix images depend on nothing of the
## build host).
##
## The dev shell exports REPROBUILD_USE_SYSTEM_HASH_LIBS=1, and under it the
## armv7 providers linked `libblake3.so.0` and `libxxhash.so.0`, which the
## prefix does not ship, and the DSL runtime, which is not a `-d:ssl` edge,
## carried the shell's OpenSSL directory as an rpath (measured 2026-11-03).
##
## The define has to be on the command line, as `nim.c` puts it: this
## repository's `config.nims` runs before a test's own `.nim.cfg`, so a
## `.nim.cfg` define is invisible to it. Each case therefore runs `nim check`
## on a probe under this repository, which reads `config.nims` as an image's
## compile does, and the probe reports the define at compile time. Nothing
## is mocked.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir

proc linkCommandUnder(args: openArray[string]; sslDir: string): string =
  ## The link command `config.nims` produces for a probe, read from the
  ## script `--genScript` writes, with OPENSSL_LIBDIR naming `sslDir`.
  createDir(RepoRoot / "build")
  let dir = createTempDir("zig-target-ssl-", "", RepoRoot / "build")
  defer: removeDir(dir)
  let probe = dir / "probe.nim"
  writeFile(probe, "echo 1\n")
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  env["OPENSSL_LIBDIR"] = sslDir
  env.del("DEP_OPENSSL_PREFIX")
  let r = execCmdEx(findExe("nim") & " c --hints:off --warnings:off " &
    "--compileOnly --genScript:on --nimcache:" & quoteShell(dir / "cache") &
    " " & args.join(" ") & " " & quoteShell(probe), env = env,
    workingDir = RepoRoot)
  let script = dir / "cache" / "compile_probe.sh"
  doAssert fileExists(script), r.output
  readFile(script)

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

suite "a zig-target image links no ambient OpenSSL":
  # A directory that holds a libssl, as OPENSSL_LIBDIR names one in a shell.
  let sslDir = createTempDir("zig-target-libssl-", "")
  writeFile(sslDir / "libssl.so", "")

  test "a native compile takes the shell's OpenSSL, with its rpath":
    # The control: the directory is one config.nims would use.
    let link = linkCommandUnder([], sslDir)
    checkpoint(link)
    check ("-Wl,-rpath," & sslDir) in link

  test "a zig-target compile takes none of it":
    let link = linkCommandUnder(
      ["-d:reproZigTarget=armv7-unknown-linux-gnueabihf"], sslDir)
    checkpoint(link)
    check sslDir notin link

  removeDir(sslDir)

proc probeTypeNameUnder(args: openArray[string]): string =
  ## The mangled C name of an object type the probe defines, as compiled
  ## with `args` from a directory under this repository.
  # One fixed directory for every compile this process compares: the
  # probe's path is part of the hash, so only the map may differ between
  # them. It is this process's own: the suite runner runs each case in a
  # process of its own and in parallel, and two processes sharing one
  # directory removed each other's probe mid-compile.
  let dir = RepoRoot / "build" /
    ("zig-target-typehash-probe-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  writeFile(dir / "probe.nim",
    "type Probe = ref object\n  x: int\nlet p = Probe(x: 1)\necho p.x\n")
  let r = execCmdEx(findExe("nim") & " c --hints:off --warnings:off " &
    "--compileOnly --nimcache:" & quoteShell(dir / "cache") & " " &
    args.join(" ") & " " & quoteShell(dir / "probe.nim"),
    workingDir = RepoRoot)
  for kind, f in walkDir(dir / "cache"):
    if f.endsWith(".c") and "probe" in f.extractFilename:
      for line in readFile(f).splitLines:
        let at = line.find("tyObject_ProbecolonObjectType___")
        if at >= 0:
          var e = at
          while e < line.len and line[e] in IdentChars: inc e
          return line[at ..< e]
  "no type name: " & r.output

suite "a zig-target image's type hashes do not depend on the checkout path":
  # The Nim fork hashes a type by the absolute path of the file defining it
  # (metacraft-labs/nim 9a49ee3c), so two checkouts gave the armv7 engine
  # different bytes (measured 2026-11-04). `--typeHashPathMap` hashes the
  # repository as `/reprobuild/` and the workspace as `/workspace/`, as
  # scripts/build_addon_static.sh does.
  proc mappedTypeName(): string =
    probeTypeNameUnder(["--typeHashPathMap:" & RepoRoot & "/=/reprobuild/"])

  test "the control: the map changes the type's hash":
    let mapped = mappedTypeName()
    let plain = probeTypeNameUnder([])
    checkpoint(mapped & " / " & plain)
    check mapped.startsWith("tyObject_")
    check plain.startsWith("tyObject_")
    check mapped != plain

  test "a zig-target compile applies the map":
    let target = probeTypeNameUnder(
      ["-d:reproZigTarget=armv7-unknown-linux-gnueabihf"])
    let mapped = mappedTypeName()
    checkpoint(target & " / " & mapped)
    check target == mapped
