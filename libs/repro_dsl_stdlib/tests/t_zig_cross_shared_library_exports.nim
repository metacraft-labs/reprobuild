## A shared library linked through the `cross_zig` wrappers exports its own
## symbols and none of zig's compiler-rt.
##
## WHY. zig 0.13 links its compiler-rt into a 32-bit ARM shared library as
## weak, default-visibility symbols, so the library exports them (385,
## including 69 `__aeabi_*`). A program linked against such a library binds
## its own calls to those helpers to the library, not to the compiler-rt
## its own link carries, because the linker meets the library's definition
## first. Measured 2026-11-02 (reprobuild-pm issue
## 2026-11-02-zig-built-shared-libraries-export-compiler-rt-and-armv7-images-import-it):
## the armv7 `reprobuild` image linked the catalog's zig-built
## `libsqlite3.so` and imported 11 `__aeabi_*` symbols from it. On the
## Raspberry Pi the soname resolves to the system's gcc-built sqlite, which
## exports none, and the image died with "undefined symbol: __aeabi_uidiv".
## zig 0.13 refuses `--exclude-libs`, and zig 0.14.1 exports the same set.
##
## HOW. The wrappers and the map are the adapter's own text
## (`zigCrossWrapperScript`, `zigCrossCompilerRtMap`), written into a temp
## directory the way the wrapper edge writes them. The links are real `zig cc`
## links for `arm-linux-gnueabihf.2.38`, and the exports are read with `nm -D`
## from the dev shell. zig hands the linker only the last version script
## of a link (measured: a second one dropped the first's `GLIBC_2.*`
## versions), so the wrapper adds the map only to a `-shared` link that
## brings none. A link with its own script is accepted when that script
## already makes compiler-rt local (`local: *;`, or the marker of the merge
## edge `emitZigCrossVersionScriptAction`) and refused otherwise; io-mon's
## shim script, which only versions `dlsym`, is the case the merge serves.
##
## NO MOCKS: the real zig and the real linker. Without zig 0.13 or nm on
## PATH the link cases skip with the reason, and fail in a gate run.

import std/[os, osproc, sequtils, sets, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip
import repro_project_dsl
import repro_dsl_stdlib/adapters/cross_zig

const
  Glibc = "armv7-unknown-linux-gnueabihf"
  LibSource = """
unsigned f(unsigned a, unsigned b) { return a / b; }
long long g(long long a, long long b) { return a / b; }
"""

proc toolMissing(): string =
  ## Why the link cases cannot run here, or "" when they can.
  if findExe("zig").len == 0: return "zig is not on PATH"
  if findExe("nm").len == 0: return "nm is not on PATH"
  let (version, code) = execCmdEx("zig version")
  if code != 0 or not version.strip().startsWith("0.13."):
    return "the list is zig 0.13's; zig on PATH is " & version.strip()
  ""

template requireTools(body: untyped) =
  let missing = toolMissing()
  if missing.len > 0:
    if getEnv("REPROBUILD_GATE_RUN") == "1":
      checkpoint(missing & " in a gate run")
      check false
    else:
      skip(missing)
  else:
    body

proc writeWrappers(dir, triple: string) =
  ## The wrapper edge's files: the scripts, and the map beside them.
  let t = zigCrossTarget(triple)
  createDir(dir / "lib")
  for role in ["cc", "c++"]:
    writeFile(dir / role, zigCrossWrapperScript(role, t, dir / "lib"))
    setFilePermissions(dir / role, {fpUserRead, fpUserWrite, fpUserExec})
  let map = zigCrossCompilerRtMap(t)
  if map.len > 0:
    writeFile(dir / ZigCrossCompilerRtMapName, map)

proc run(cmd: string; dir: string): tuple[output: string, code: int] =
  putEnv("ZIG_GLOBAL_CACHE_DIR", dir / "zig-global")
  putEnv("ZIG_LOCAL_CACHE_DIR", dir / "zig-local")
  let r = execCmdEx(cmd, workingDir = dir)
  (r.output, r.exitCode)

const
  ShimLikeScript = """
GLIBC_2.2.5 {
  global:
    dlsym;
};

GLIBC_2.17 {
  global:
    dlsym;
} GLIBC_2.2.5;
"""
  ShimLikeSource = """
unsigned f(unsigned a, unsigned b) { return a / b; }
void *dlsym(void *handle, const char *name) { return 0; }
"""

proc scriptOf(act: BuildActionDef): string =
  ## The operand of `sh -c` in an inline-exec action.
  for arg in act.call.arguments:
    if arg.name == "argv":
      let argv = arg.encodedValue.split('\x1f')
      return argv[argv.find("-c") + 1]
  ""

proc exported(lib, dir: string): seq[string] =
  let (output, code) = run("nm -D --defined-only " & quoteShell(lib), dir)
  doAssert code == 0, output
  for line in output.splitLines():
    let fields = line.splitWhitespace()
    if fields.len == 3:
      result.add(fields[2])

suite "cross_zig: a shared library exports none of compiler-rt":

  test "the 32-bit ARM rows carry the map; the others need none":
    let arm = zigCrossCompilerRtMap(zigCrossTarget(Glibc))
    check "__aeabi_uidiv;" in arm
    check "local:" in arm
    check "global:" notin arm
    check arm == zigCrossCompilerRtMap(
      zigCrossTarget("armv7-unknown-linux-musleabihf"))
    # Measured: zig 0.13's aarch64 and x86_64 musl libraries export only
    # `_init` / `_fini` beyond their own symbols.
    check zigCrossCompilerRtMap(
      zigCrossTarget("aarch64-unknown-linux-musl")).len == 0
    check zigCrossCompilerRtMap(
      zigCrossTarget("x86_64-unknown-linux-musl")).len == 0

  test "a -shared link through the wrapper exports only its own symbols":
    requireTools:
      let dir = createTempDir("zig-shared-exports-", "")
      defer: removeDir(dir)
      writeWrappers(dir / "w", Glibc)
      writeFile(dir / "l.c", LibSource)
      let link = run(quoteShell(dir / "w" / "cc") &
        " -shared -fPIC -o l.so l.c", dir)
      checkpoint(link.output)
      require link.code == 0
      let names = exported(dir / "l.so", dir)
      checkpoint(names.join(" "))
      check "f" in names
      check "g" in names
      check names.filterIt(it.startsWith("__aeabi")).len == 0
      let runtime = zigArmCompilerRtSymbols().toHashSet
      check names.filterIt(it in runtime).len == 0

  test "a recipe's own version script decides alone":
    requireTools:
      let dir = createTempDir("zig-shared-own-map-", "")
      defer: removeDir(dir)
      writeWrappers(dir / "w", Glibc)
      writeFile(dir / "l.c", LibSource)
      writeFile(dir / "own.map", "{ global: f; local: *; };\n")
      let link = run(quoteShell(dir / "w" / "cc") &
        " -shared -fPIC -o l.so l.c -Wl,--version-script=own.map", dir)
      checkpoint(link.output)
      require link.code == 0
      check exported(dir / "l.so", dir) == @["f"]

  test "a version script that leaves compiler-rt exported is refused":
    requireTools:
      let dir = createTempDir("zig-shared-refused-", "")
      defer: removeDir(dir)
      writeWrappers(dir / "w", Glibc)
      writeFile(dir / "l.c", ShimLikeSource)
      writeFile(dir / "shim.map", ShimLikeScript)
      let link = run(quoteShell(dir / "w" / "cc") &
        " -shared -fPIC -o l.so l.c -Wl,--version-script=shim.map", dir)
      checkpoint(link.output)
      check link.code != 0
      check "shim.map leaves zig's compiler-rt exported" in link.output
      check "emitZigCrossVersionScriptAction" in link.output
      check not fileExists(dir / "l.so")

  test "a merged script keeps the recipe's versions and hides compiler-rt":
    requireTools:
      let dir = createTempDir("zig-shared-merged-", "")
      defer: removeDir(dir)
      writeWrappers(dir / "w", Glibc)
      writeFile(dir / "l.c", ShimLikeSource)
      writeFile(dir / "shim.map", ShimLikeScript)
      resetBuildActionRegistry()
      let merge = emitZigCrossVersionScriptAction(dir, "pkg", Glibc,
        dir / "shim.map", dir / "merged.map")
      check merge.outputs == @[dir / "merged.map"]
      let (mergeOut, mergeCode) = execCmdEx("sh -c " &
        quoteShell(scriptOf(merge)))
      checkpoint(mergeOut)
      require mergeCode == 0
      check readFile(dir / "merged.map").startsWith(ShimLikeScript)
      check ZigCrossCompilerRtMarker in readFile(dir / "merged.map")
      let link = run(quoteShell(dir / "w" / "cc") &
        " -shared -fPIC -o l.so l.c -Wl,--version-script=merged.map", dir)
      checkpoint(link.output)
      require link.code == 0
      let names = exported(dir / "l.so", dir)
      checkpoint(names.join(" "))
      check names.filterIt(it in zigArmCompilerRtSymbols().toHashSet).len == 0
      check "f" in names
      # The recipe's version nodes survive the merge: `dlsym` keeps the
      # default version the script alone gives it.
      let (versions, _) = run("nm -D " & quoteShell(dir / "l.so"), dir)
      check "dlsym@@GLIBC_2.2.5" in versions

  test "an anonymous script is refused by the merge edge":
    let dir = createTempDir("zig-merge-anonymous-", "")
    defer: removeDir(dir)
    writeFile(dir / "own.map", "/* exports */\n{ global: f; };\n")
    resetBuildActionRegistry()
    let merge = emitZigCrossVersionScriptAction(dir, "pkg", Glibc,
      dir / "own.map", dir / "merged.map")
    let (output, code) = execCmdEx("sh -c " & quoteShell(scriptOf(merge)))
    checkpoint(output)
    check code != 0
    check "anonymous version script" in output
    check not fileExists(dir / "merged.map")
    expect ValueError:
      discard emitZigCrossVersionScriptAction(dir, "pkg",
        "x86_64-unknown-linux-musl", dir / "own.map", dir / "merged.map")

  test "an executable link is unchanged by the map":
    requireTools:
      let dir = createTempDir("zig-exe-no-map-", "")
      defer: removeDir(dir)
      writeWrappers(dir / "w", Glibc)
      writeFile(dir / "m.c", "int main(void) { return 0; }\n")
      let link = run(quoteShell(dir / "w" / "cc") & " -o m m.c -v", dir)
      checkpoint(link.output)
      require link.code == 0
      check ZigCrossCompilerRtMapName notin link.output

  test "the list is the compiler-rt of the zig on PATH":
    requireTools:
      let dir = createTempDir("zig-compiler-rt-list-", "")
      defer: removeDir(dir)
      writeFile(dir / "l.c", LibSource)
      let link = run("zig cc -target " & zigCrossTarget(Glibc).zigTarget &
        " -shared -fPIC -o l.so l.c", dir)
      require link.code == 0
      var archive = ""
      for path in walkDirRec(dir / "zig-global"):
        if path.extractFilename == "libcompiler_rt.a":
          archive = path
      require archive.len > 0
      let (output, code) = run("nm -g --defined-only " &
        quoteShell(archive), dir)
      require code == 0
      var actual: HashSet[string]
      for line in output.splitLines():
        let fields = line.splitWhitespace()
        if fields.len == 3:
          actual.incl(fields[2])
      let listed = zigArmCompilerRtSymbols().toHashSet
      checkpoint("in the archive, not listed: " &
        toSeq(actual - listed).join(" "))
      checkpoint("listed, not in the archive: " &
        toSeq(listed - actual).join(" "))
      check actual == listed

suite "cross_zig: a link finds the libraries LIBRARY_PATH names":
  ## The engine hands a consumer its `buildDeps:` libraries through
  ## `LIBRARY_PATH` (and their headers through `CPATH`). `zig cc` honours
  ## `CPATH` and ignores `LIBRARY_PATH` (measured, zig 0.13.0: "unable to
  ## find dynamic system library 'zz' ... searched paths: none"), so the
  ## wrappers turn each entry into `-L` on a link. Measured first on
  ## catalog zstd for armv7, whose `zstd` program links the target zlib.

  test "a library only LIBRARY_PATH names is linked":
    requireTools:
      let dir = createTempDir("zig-library-path-", "")
      defer: removeDir(dir)
      writeWrappers(dir / "w", Glibc)
      createDir(dir / "lib")
      writeFile(dir / "zz.c", "int zz(void) { return 3; }\n")
      writeFile(dir / "m.c", "int zz(void);\nint main(void) { return zz(); }\n")
      let cc = quoteShell(dir / "w" / "cc")
      require run(cc & " -c -o zz.o zz.c", dir).code == 0
      require run("zig ar rc lib/libzz.a zz.o", dir).code == 0
      require run(cc & " -c -o m.o m.c", dir).code == 0
      let link = run("LIBRARY_PATH=" & quoteShell(dir / "lib") & ":/nonexistent " &
        cc & " -o m m.o -lzz", dir)
      checkpoint(link.output)
      check link.code == 0
      check fileExists(dir / "m")
