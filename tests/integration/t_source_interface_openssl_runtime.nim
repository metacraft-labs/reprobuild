## Real-loader regression for source-built interface helper runtime closure.
##
## This test uses the real Nim compiler, interface extractor and OpenSSL shared
## library. A private library name prevents an unrelated system installation
## from satisfying the loader lookup. The positive case calls OpenSSL_version;
## the negative case removes the selected prefix and must fail to load it.
## No mocks are used. This is a separate executable because compiler selection
## is cached for the process lifetime; compiler-observer tests need their own
## process and must retain all of their failure and concurrency assertions.

import std/[os, strutils, tempfiles, unittest]

import repro_core
import repro_interface_artifacts
import repro_test_support

when defined(posix) and isNixSupported:
  suite "source interface runtime closure":
    test "source interface helpers load real OpenSSL from their selected prefix":
      # No mock: give the real OpenSSL library a private name so the loader
      # cannot satisfy this check from an unrelated system installation.
      let repoRoot = getCurrentDir()
      let scratch = createTempDir("repro-source-openssl-", "")
      defer: removeDir(scratch)
      let prefix = scratch / "openssl"
      let libDir = prefix / "lib"
      createDir(libDir)
      const cryptoName = when defined(macosx): "libcrypto.dylib" else: "libcrypto.so"
      const sslName = when defined(macosx): "libssl.dylib" else: "libssl.so"
      var realLibDir = ""
      for flag in consumerCompilePathFlags(repoRoot):
        if flag.startsWith("--passL:-Wl,-rpath,"):
          for dir in flag["--passL:-Wl,-rpath,".len .. ^1].split(PathSep):
            if fileExists(dir / cryptoName) and fileExists(dir / sslName):
              realLibDir = dir
      require realLibDir.len > 0
      let privateName = "librepro_crypto_" & $getCurrentProcessId() &
        (when defined(macosx): ".dylib" else: ".so")
      createSymlink(realLibDir / cryptoName, libDir / privateName)
      createSymlink(realLibDir / sslName, libDir / sslName)
      let loaderName = (when defined(macosx): "@rpath/" else: "") & privateName
      let body = "import repro_project_dsl\nimport std/[dynlib, strutils]\n" &
        "let library = loadLib(" & loaderName.escape() & ")\n" &
        "if library == nil: raise newException(IOError, \"missing private OpenSSL\")\n" &
        "type VersionProc = proc(kind: cint): cstring {.cdecl.}\n" &
        "let version = cast[VersionProc](library.symAddr(\"OpenSSL_version\"))\n" &
        "doAssert version != nil\ndoAssert ($version(0)).startsWith(\"OpenSSL\")\n" &
        "unloadLib(library)\npackage opensslRuntimeProbe:\n  build:\n    discard\n"
      let envNames = ["OPENSSL_PREFIX", "OPENSSL_LIBDIR",
        "REPROBUILD_RUNTIME_LIBRARY_PATH"]
      var savedEnv: seq[tuple[name: string, present: bool, value: string]]
      for name in envNames:
        savedEnv.add((name, existsEnv(name), getEnv(name)))
      defer:
        for entry in savedEnv:
          if entry.present: putEnv(entry.name, entry.value)
          else: delEnv(entry.name)
      delEnv("REPROBUILD_RUNTIME_LIBRARY_PATH")
      delEnv("OPENSSL_LIBDIR")
      putEnv("OPENSSL_PREFIX", prefix)
      let modulePath = scratch / "positive.nim"
      writeFile(modulePath, body)
      discard extractInterfaceFromModule(modulePath, scratch / "positive.rbsz",
        scratch / "positive-interface.nim", repoRoot, scratch / "positive-cache")
      check fileExists(scratch / "positive.rbsz")

      # With the selected prefix removed the private name is unreachable.
      # Use a distinct module and scratch root so a cached extraction cannot
      # hide the loader failure; all source behavior stays identical.
      delEnv("OPENSSL_PREFIX")
      let controlPath = scratch / "negative.nim"
      writeFile(controlPath, body)
      var refused = false
      try:
        discard extractInterfaceFromModule(controlPath, scratch / "negative.rbsz",
          scratch / "negative-interface.nim", repoRoot, scratch / "negative-cache")
      except CatchableError as exc:
        checkpoint(exc.msg)
        check "missing private OpenSSL" in exc.msg
        refused = true
      check refused
      check not fileExists(scratch / "negative.rbsz")

