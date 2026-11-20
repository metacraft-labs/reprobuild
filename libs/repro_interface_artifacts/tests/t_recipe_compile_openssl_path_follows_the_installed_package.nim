## The OpenSSL search path baked into the binaries Reprobuild compiles from a
## recipe (the project provider, the interface extract runner) comes from the
## installed package, not from whatever the host's Nix store holds.
##
## WHY. The flag is part of the recipe compile's command, so it is part of the
## key of every provider compile and interface extraction. Its last fallback
## names the first `*-openssl-*` path of `/nix/store` that holds a libssl for
## this host. An installed package publishes its own runtime libraries,
## OpenSSL among them, in `REPROBUILD_RUNTIME_LIBRARY_PATH`, but the
## resolution never looked there, so with no dev shell selecting an OpenSSL
## the key followed the host's store: the same package, the same recipe and
## the same compiler selection keyed the compiles differently on a machine
## whose store held another OpenSSL (measured: a workspace bundle restored in
## a container rebuilt every provider and interface the bundle carried,
## because the exporter's store sorted an `openssl-4.0.3` first and the
## container's held only the package's `openssl-3.6.1`).
##
## Asserts, with `OPENSSL_LIBDIR`, `OPENSSL_PREFIX` and `NIX_LDFLAGS` unset
## (no dev shell selects an OpenSSL) and `REPROBUILD_RUNTIME_LIBRARY_PATH`
## naming a private directory that holds a real libssl:
##   the only RPATH directory among the flags that holds a libssl is that
##   private directory.
##
## Negative control: with `REPROBUILD_RUNTIME_LIBRARY_PATH` unset, and a Nix
## store that holds an OpenSSL for this host, the flags name a store OpenSSL,
## so the assertion above can see a second one.
##
## Falsifying mutation: dropping the runtime-library-path step from the
## resolution adds the store glob's OpenSSL next to the private directory and
## turns the first case red (when the host's store holds an OpenSSL, which a
## Nix host running this suite does: the dev shell's own).
##
## NO MOCKS: the real flag builder over the real filesystem and /nix/store;
## the private directory holds symlinks to a real OpenSSL.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_interface_artifacts

const sslName = when defined(macosx): "libssl.dylib" else: "libssl.so"
const cryptoName = when defined(macosx): "libcrypto.dylib" else: "libcrypto.so"

proc realOpensslLibDir(): string =
  ## A directory holding a real libssl for this host, found independently of
  ## the code under test: the dev shell's selection or its link inputs.
  var candidates = @[getEnv("OPENSSL_LIBDIR"), getEnv("OPENSSL_PREFIX") / "lib"]
  for token in getEnv("NIX_LDFLAGS").splitWhitespace():
    if token.startsWith("-L") and token.len > 2:
      candidates.add(token[2 .. ^1])
  for dir in candidates:
    if dir.len > 0 and fileExists(dir / sslName) and
        fileExists(dir / cryptoName):
      return dir
  ""

proc sslRpathDirs(flags: seq[string]): seq[string] =
  ## Every RPATH directory the flags name that holds a libssl.
  const rp = "--passL:-Wl,-rpath,"
  for f in flags:
    if f.startsWith(rp):
      for d in f[rp.len .. ^1].split(':'):
        if d.len > 0 and fileExists(d / sslName) and d notin result:
          result.add(d)

suite "recipe compile OpenSSL path follows the installed package":
  test "the package's runtime library path decides the OpenSSL RPATH":
    when defined(windows):
      skip("the OpenSSL RPATH block is POSIX-only")
    else:
      let real = realOpensslLibDir()
      if real.len == 0:
        skip("no dev shell OpenSSL (OPENSSL_LIBDIR, OPENSSL_PREFIX or " &
          "NIX_LDFLAGS) to link the private directory to; run it in the " &
          "flake dev shell")
      else:
        let saved = @[("OPENSSL_LIBDIR", getEnv("OPENSSL_LIBDIR")),
          ("OPENSSL_PREFIX", getEnv("OPENSSL_PREFIX")),
          ("NIX_LDFLAGS", getEnv("NIX_LDFLAGS")),
          ("REPROBUILD_RUNTIME_LIBRARY_PATH",
            getEnv("REPROBUILD_RUNTIME_LIBRARY_PATH"))]
        let private = createTempDir("repro-openssl-runtime-", "")
        defer:
          removeDir(private)
          for (k, v) in saved:
            if v.len > 0: putEnv(k, v) else: delEnv(k)
        for name in [sslName, cryptoName]:
          createSymlink(expandFilename(real / name), private / name)
        for (k, _) in saved:
          delEnv(k)

        putEnv("REPROBUILD_RUNTIME_LIBRARY_PATH", private)
        let withPackage = sslRpathDirs(consumerCompilePathFlags())
        checkpoint("with the package's runtime path: " & $withPackage)
        check withPackage == @[private]

        # Negative control: without it, a store OpenSSL is named.
        delEnv("REPROBUILD_RUNTIME_LIBRARY_PATH")
        let withoutPackage = sslRpathDirs(consumerCompilePathFlags())
        checkpoint("without it: " & $withoutPackage)
        var storeHasOpenssl = false
        for kind, path in walkDir("/nix/store"):
          if kind == pcDir and "-openssl-" in path and
              fileExists(path / "lib" / sslName):
            storeHasOpenssl = true
            break
        if storeHasOpenssl:
          check withoutPackage.len == 1
          check withoutPackage.len == 1 and
            withoutPackage[0].startsWith("/nix/store/")
