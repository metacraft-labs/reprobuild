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
      preserveEnv("REPROBUILD_USE_SYSTEM_HASH_LIBS")
      putEnv("REPROBUILD_USE_SYSTEM_HASH_LIBS", "1")
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

    test "portable hash sources compile outside the SDK configuration":
      let scratch = createTempDir("repro portable hashes ", "")
      defer: removeDir(scratch)
      let sourceRoot = scratch / "installed source"
      for name in ["blake3", "xxh3"]:
        copyDir(repoRoot / "libs" / name, sourceRoot / "libs" / name)
      preserveEnv("REPROBUILD_USE_SYSTEM_HASH_LIBS")
      delEnv("REPROBUILD_USE_SYSTEM_HASH_LIBS")
      let flags = consumerCompilePathFlags(sourceRoot)
      check "--passL:-lblake3" notin flags
      check "--passL:-lxxhash" notin flags
      # Exercise only the shipped hash closure. External-prefix flags would
      # let this Nix development host conceal a broken portable installation.
      # These are production flags, not replacement include paths or libraries.
      var hashFlags: seq[string]
      for flag in flags:
        if flag == "--define:reproVendoredHash" or
            flag == "--passC:-DREPRO_VENDORED_HASH" or
            (flag.startsWith("--passC:-I") and sourceRoot in flag):
          hashFlags.add(flag)
      let source = scratch / "probe.nim"
      writeFile(source, """
import blake3, xxh3
doAssert blake3.toHex(blake3.digest("")) ==
  "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
doAssert xxh3.toHex(xxh3.digest64("")) == "2d06800538d394c2"
echo "portable-hashes-ready"
""")
      let nim = getEnv("REPRO_NIM_COMPILER", findExe("nim"))
      let base = @[nim, "c", "--skipUserCfg:on", "--skipParentCfg:on",
        "--skipProjCfg:on", "--hints:off",
        "--path:" & (sourceRoot / "libs/blake3/src"),
        "--path:" & (sourceRoot / "libs/xxh3/src")]
      let binary = scratch / "probe"
      let compiled = run(base & hashFlags & @["--nimcache:" & (scratch / "cache"),
        "-o:" & binary, source])
      checkpoint(compiled.output)
      require compiled.code == 0
      let loaded = run(@[binary], cleanLoader = true)
      checkpoint(loaded.output)
      check loaded.code == 0
      check "portable-hashes-ready" in loaded.output
      # Keep real headers but omit the implementation selector: the native
      # linker must reject the unresolved hash functions, not accept a stub.
      var withoutImplementation: seq[string]
      for flag in hashFlags:
        if flag != "--define:reproVendoredHash":
          withoutImplementation.add(flag)
      let refused = run(base & withoutImplementation & @[
        "--nimcache:" & (scratch / "negative-cache"),
        "-o:" & (scratch / "negative"), source])
      checkpoint(refused.output)
      check refused.code != 0
      check "undefined reference" in refused.output
else:
  discard # ELF loader regression; Windows uses vendored C and macOS uses LC_RPATH.
