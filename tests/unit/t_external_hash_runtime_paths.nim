when not defined(windows):
  import std/[os, tempfiles, unittest]

  import repro_interface_artifacts

  const RepoRoot = currentSourcePath().parentDir().parentDir().parentDir()

  proc makeFakePrefix(name, headerName, libName: string): string =
    result = createTempDir("reprobuild-" & name & "-", "")
    createDir(result / "include")
    createDir(result / "lib")
    writeFile(result / "include" / headerName, "// header")
    writeFile(result / "lib" / libName, "")

  template withEnvVar(name, value: string; body: untyped) =
    let hadValue = existsEnv(name)
    let oldValue = getEnv(name)
    putEnv(name, value)
    try:
      body
    finally:
      if hadValue:
        putEnv(name, oldValue)
      else:
        delEnv(name)

  suite "external hash runtime paths":
    test "system hash prefixes add rpath linker flags":
      let blake3Prefix = makeFakePrefix("blake3-prefix", "blake3.h",
        "libblake3.so")
      let xxhashPrefix = makeFakePrefix("xxhash-prefix", "xxhash.h",
        "libxxhash.so")
      defer:
        removeDir(blake3Prefix)
        removeDir(xxhashPrefix)

      withEnvVar("BLAKE3_PREFIX", blake3Prefix):
        withEnvVar("XXHASH_PREFIX", xxhashPrefix):
          let flags = consumerCompilePathFlags(RepoRoot)
          check "--passL:-Wl,-rpath," & (blake3Prefix / "lib") in flags
          check "--passL:-Wl,-rpath," & (xxhashPrefix / "lib") in flags
