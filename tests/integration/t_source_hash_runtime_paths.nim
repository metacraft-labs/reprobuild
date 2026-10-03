## Real compiler/loader regression for source-bootstrap interface helpers.
## No mocks: both shared libraries are built from the tracked BLAKE3/xxHash
## implementations. Private SONAMEs keep the no-RPATH control from finding
## an unrelated installed library. All child loader search variables are absent.
import std/[os, osproc, strtabs, strutils, tempfiles, unittest]
import repro_interface_artifacts

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir

when defined(linux):
  proc run(argv: seq[string]; cleanLoader = false): tuple[output: string, code: int] =
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      if not cleanLoader or key notin ["LD_LIBRARY_PATH", "LD_PRELOAD",
          "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH"]:
        env[key] = value
    # Nix's compiler wrapper otherwise manufactures RPATHs from -L flags,
    # which would conceal this bug. Both controls use only the explicit flags.
    env["NIX_DONT_SET_RPATH"] = "1"
    let p = startProcess(argv[0], args = argv[1 .. ^1], env = env,
      options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    for line in p.lines(keepNewLines = true):
      result.output.add(line)
    result.code = p.waitForExit()

  template preserveEnv(key: string): untyped =
    let existed = existsEnv(key)
    let old = getEnv(key)
    defer:
      if existed: putEnv(key, old)
      else: delEnv(key)

  suite "Source bootstrap hash-library runtime paths":
    test "real hash libraries load without ambient paths; missing RPATH fails":
      let scratch = createTempDir("repro-hash-runtime-", "")
      defer: removeDir(scratch)
      let prefix = scratch / "hashes"
      let libDir = prefix / "lib"
      createDir(libDir)
      createDir(prefix / "include")
      let blake = repoRoot / "libs/blake3/src/blake3/vendor"
      let xxhash = repoRoot / "libs/xxh3/src/xxh3/vendor"
      copyFile(blake / "blake3.h", prefix / "include/blake3.h")
      copyFile(xxhash / "xxhash.h", prefix / "include/xxhash.h")
      let cc = getEnv("CC", "cc")
      let suffix = $getCurrentProcessId()
      let blakeSoname = "librepro_test_blake3_" & suffix & ".so.0"
      let xxhashSoname = "librepro_test_xxhash_" & suffix & ".so.0"
      let blakeBuild = run(@[cc, "-shared", "-fPIC",
        "-DBLAKE3_NO_AVX2", "-DBLAKE3_NO_AVX512", "-DBLAKE3_NO_SSE2",
        "-DBLAKE3_NO_SSE41", "-DBLAKE3_USE_NEON=0", "-I" & blake,
        "-Wl,-soname," & blakeSoname, "-o", libDir / blakeSoname,
        blake / "blake3.c", blake / "blake3_dispatch.c", blake / "blake3_portable.c"])
      checkpoint(blakeBuild.output)
      require blakeBuild.code == 0
      createSymlink(blakeSoname, libDir / "libblake3.so")
      let xxhashBuild = run(@[cc, "-shared", "-fPIC", "-I" & xxhash,
        "-Wl,-soname," & xxhashSoname, "-o", libDir / xxhashSoname,
        xxhash / "xxhash.c"])
      checkpoint(xxhashBuild.output)
      require xxhashBuild.code == 0
      createSymlink(xxhashSoname, libDir / "libxxhash.so")

      preserveEnv("BLAKE3_PREFIX")
      preserveEnv("XXHASH_PREFIX")
      preserveEnv("REPROBUILD_RUNTIME_LIBRARY_PATH")
      putEnv("BLAKE3_PREFIX", prefix)
      putEnv("XXHASH_PREFIX", prefix)
      delEnv("REPROBUILD_RUNTIME_LIBRARY_PATH")
      let flags = consumerCompilePathFlags(repoRoot)
      var compileArgs = @[cc]
      for flag in flags:
        if flag.startsWith("--passC:") or flag.startsWith("--passL:"):
          compileArgs.add(flag["--passC:".len .. ^1])
      let source = scratch / "probe.c"
      writeFile(source, """
#include <stdio.h>
#include <blake3.h>
#include <xxhash.h>
int main(void) {
  printf("hash-libraries-ready %s %u\n", blake3_version(), XXH_versionNumber());
  return 0;
}
""")
      let binary = scratch / "probe"
      let compiled = run(@[cc, source] & compileArgs[1 .. ^1] & @["-o", binary])
      checkpoint(compiled.output)
      require compiled.code == 0
      let loaded = run(@[binary], cleanLoader = true)
      checkpoint(loaded.output)
      check loaded.code == 0
      check loaded.output.startsWith("hash-libraries-ready ")

      # Remove only the hash-directory RPATHs and preserve the same source,
      # libraries, compiler and other flags. This executable must not load.
      var controlArgs: seq[string]
      for arg in compileArgs:
        if not ("rpath" in arg and libDir in arg): controlArgs.add(arg)
      let control = scratch / "no-rpath"
      let controlBuilt = run(@[cc, source] & controlArgs[1 .. ^1] & @["-o", control])
      checkpoint(controlBuilt.output)
      require controlBuilt.code == 0
      let refused = run(@[control], cleanLoader = true)
      checkpoint(refused.output)
      check refused.code != 0
      check blakeSoname in refused.output or xxhashSoname in refused.output
else:
  discard # ELF loader regression; Windows uses vendored C and macOS uses LC_RPATH.
