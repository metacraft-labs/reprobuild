## A compile for another machine (`repro build --target=...`) links the
## library the engine named in `DEP_SQLITE_PREFIX` but writes no RPATH into
## that prefix.
##
## WHY. Under `--target` the prefix is the sibling recipe's install mirror
## (`<recipe>/.repro/output/install@<triple>/usr`), a directory of the build
## host. Baked into RPATH it is a builder path inside an installed image:
## measured 2026-11-02 at reprobuild 508aa79caf, every armv7 image of
## `.#release` carried `RPATH /tmp/.../sqlite/.repro/output/install@...`.
## On the target the images take the system's `libsqlite3.so.0` by its
## soname, which is what `scripts/cross/build_linux_cross.sh` produces (it
## links against the target sysroot and bakes no RPATH). A native compile
## keeps the RPATH: there the prefix is the library the binary runs with.
##
## HOW. A probe module that links `-lsqlite3` is compiled from inside this
## repository, so the real `config.nims` applies, with `--genScript`: Nim
## writes the link line to `compile_probe.sh` without running a C compiler,
## so the target case needs no cross toolchain. The prefix holds a
## `libsqlite3.so` that is only an ELF header -- nothing is linked; the
## property is the link line `config.nims` produces.
##
## NO MOCKS: the real compiler and the real `config.nims`.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

proc reproRoot(): string =
  ## The repository root that owns `config.nims`, found from this file.
  var dir = parentDir(currentSourcePath())
  while dir.len > 0 and dir != parentDir(dir):
    if fileExists(dir / "config.nims") and
        dirExists(dir / "libs" / "repro_interface_artifacts"):
      return dir
    dir = parentDir(dir)
  raise newException(IOError, "reprobuild root not found above " &
    currentSourcePath())

proc armElfHeader(): string =
  ## ELF32, little-endian, `e_machine` EM_ARM (40).
  result = newString(52)
  result[0] = '\x7F'; result[1] = 'E'; result[2] = 'L'; result[3] = 'F'
  result[4] = '\x01'; result[5] = '\x01'; result[6] = '\x01'
  result[18] = char(40)

proc linkScript(root, prefix: string; crossArgs: seq[string]): string =
  ## The link-and-compile script Nim generates for the probe.
  let nimcache = root / ("nimcache" & $crossArgs.len)
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  env.del("SQLITE_LIBDIR")
  env["DEP_SQLITE_PREFIX"] = prefix
  let nim = findExe("nim")
  doAssert nim.len > 0, "nim is not on PATH"
  let args = @["c", "--hints:off", "--warnings:off", "--compileOnly",
    "--genScript", "--nimcache:" & nimcache] & crossArgs &
    @[root / "probe.nim"]
  let p = startProcess(nim, workingDir = root, args = args, env = env,
    options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  checkpoint(output)
  doAssert code == 0, "nim --genScript failed"
  readFile(nimcache / "compile_probe.sh")

suite "a target compile bakes no RPATH into DEP_SQLITE_PREFIX":
  let repo = reproRoot()
  createDir(repo / "build")
  let root = createTempDir("target-rpath-probe-", "", repo / "build")
  let prefix = root / "sqlite-prefix"
  createDir(prefix / "lib")
  writeFile(prefix / "lib" / "libsqlite3.so", armElfHeader())
  writeFile(root / "probe.nim", """
{.passL: "-lsqlite3".}
proc sqlite3_libversion(): cstring {.importc, cdecl.}
echo sqlite3_libversion()
""")

  test "for armv7 the prefix is searched and not remembered":
    let script = linkScript(root, prefix, @["--cpu:arm", "--os:linux"])
    check "-L" & prefix / "lib" in script
    check "-rpath," & prefix / "lib" notin script

  test "natively the prefix is remembered (control)":
    let script = linkScript(root, prefix, @[])
    check "-L" & prefix / "lib" in script
    check "-rpath," & prefix / "lib" in script

  removeDir(root)
