## Real-loader regression for the source-built interface helper's OpenSSL
## runtime closure.
##
## WHY. ``externalHashFlags`` gives the binaries Reprobuild compiles for itself
## (the interface extract runner, the project provider) the runtime search
## path of every C library their code may load: Clingo, the hash libraries,
## SQLite. It gave them none for OpenSSL. A source-built ``repro`` has no
## installed wrapper to publish ``REPROBUILD_RUNTIME_LIBRARY_PATH``, and the
## helper runs in a scrubbed environment, so a recipe whose module-init code
## loads OpenSSL (``std/net`` under ``-d:ssl``, or a direct ``loadLib``)
## failed extraction with ``could not load: libcrypto…`` — the CodeTracer
## prerequisite failure recorded in reprobuild-pm
## ``issues/2026-10-03-source-interface-extraction-cannot-load-openssl-in-codetracer-ci.md``.
## Distribution-And-Packaging §5 requires that closure to be complete,
## OpenSSL included.
##
## HOW. The real Nim compiler, the real interface extractor and the real
## OpenSSL shared library; no mocks. The library is exposed under a private
## name inside a private ``OPENSSL_PREFIX``, so nothing but the helper's own
## baked search path can satisfy the lookup: not the system, not Homebrew,
## not the dev shell. The recipe ``loadLib``s that name at module init and
## calls ``OpenSSL_version``. The negative control removes the prefix and must
## fail to load it, which proves the positive case was decided by the
## selected prefix and not by an ambient path.
##
## The real library is located here, independently of the code under test,
## so that on a tree without the fix the positive case fails for the reason
## it exists for (the helper cannot load OpenSSL) rather than at a setup
## ``require``.
##
## This is a separate executable because compiler selection is cached for the
## process lifetime; compiler-observer tests need their own process and must
## retain all of their failure and concurrency assertions.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_test_support

when defined(posix) and isNixSupported:
  const cryptoName = when defined(macosx): "libcrypto.dylib" else: "libcrypto.so"
  const sslName = when defined(macosx): "libssl.dylib" else: "libssl.so"

  proc realOpensslLibDir(): string =
    ## A directory holding a real libssl + libcrypto pair for this host: the
    ## dev shell's explicit selection, then its own link inputs, then the
    ## Homebrew prefixes. The first two are what CI and ``nix develop``
    ## provide; Homebrew covers a developer running outside the shell.
    var candidates = @[getEnv("OPENSSL_LIBDIR"), getEnv("OPENSSL_PREFIX") / "lib"]
    for token in getEnv("NIX_LDFLAGS").splitWhitespace():
      if token.startsWith("-L") and token.len > 2:
        candidates.add(token[2 .. ^1])
    candidates.add(["/opt/homebrew/opt/openssl@3/lib", "/usr/local/opt/openssl@3/lib"])
    for dir in candidates:
      if dir.len > 0 and fileExists(dir / cryptoName) and fileExists(dir / sslName):
        return dir
    ""

  suite "source interface runtime closure":
    test "source interface helpers load real OpenSSL from their selected prefix":
      let repoRoot = getCurrentDir()
      let realLibDir = realOpensslLibDir()
      checkpoint("real OpenSSL libdir: " & realLibDir)
      require realLibDir.len > 0
      let scratch = createTempDir("repro-source-openssl-", "")
      defer: removeDir(scratch)
      let prefix = scratch / "openssl"
      let libDir = prefix / "lib"
      createDir(libDir)
      # The private name is what makes the check falsifiable: no loader
      # default, Homebrew prefix or dev-shell path can carry it.
      let privateName = "librepro_crypto_" & $getCurrentProcessId() &
        (when defined(macosx): ".dylib" else: ".so")
      createSymlink(realLibDir / cryptoName, libDir / privateName)
      # ``libssl`` under its ordinary name is the marker the selector looks
      # for when it decides that a prefix holds OpenSSL.
      createSymlink(realLibDir / sslName, libDir / sslName)
      # On macOS ``dlopen`` consults LC_RPATH only for an ``@rpath/`` name; on
      # Linux a bare name is searched through DT_RPATH.
      let loaderName = (when defined(macosx): "@rpath/" else: "") & privateName
      let body = "import repro_project_dsl\nimport std/[dynlib, strutils]\n" &
        "let library = loadLib(" & loaderName.escape() & ")\n" &
        "if library == nil: raise newException(IOError, \"missing private OpenSSL\")\n" &
        "type VersionProc = proc(kind: cint): cstring {.cdecl.}\n" &
        "let version = cast[VersionProc](library.symAddr(\"OpenSSL_version\"))\n" &
        "doAssert version != nil\ndoAssert ($version(0)).startsWith(\"OpenSSL\")\n" &
        "unloadLib(library)\npackage opensslRuntimeProbe:\n  build:\n    discard\n"
      # The installed-wrapper path and the dev shell's explicit selection are
      # both cleared: the first would mask the source-bootstrap shape this
      # test is about, the second would outrank the private prefix.
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
      try:
        discard extractInterfaceFromModule(modulePath, scratch / "positive.rbsz",
          scratch / "positive-interface.nim", repoRoot, scratch / "positive-cache")
      except CatchableError as exc:
        # Surface the extractor's diagnostic: on a tree without the fix it is
        # the helper's own "missing private OpenSSL" failure.
        checkpoint(exc.msg)
        fail()
      check fileExists(scratch / "positive.rbsz")

      # With OPENSSL_PREFIX unset the selector no longer names the private
      # prefix (the directory itself is left in place, so a helper reused
      # with the positive case's RPATH would still load it and fail this
      # control), and the private name is unreachable.
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
