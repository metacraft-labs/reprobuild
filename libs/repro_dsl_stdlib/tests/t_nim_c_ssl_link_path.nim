## Every `-d:ssl` edge `nim.c` lowers carries OpenSSL's search path, from the
## package's declaration.
##
## `t_nim_ssl_dependency` already pins that a `-d:ssl` edge gets `-lssl
## -lcrypto` and records the `openssl` tool-identity ref. This file pins the
## part M8 was about: that the two `-l` names arrive with a `-L` that can
## actually resolve them, and that the `-L` comes from the openssl package's
## declared layout rather than from whatever the recipe author remembered to
## thread onto that particular edge.
##
## The bug being guarded against is PARTIAL coverage, which is why the shape of
## the assertions is agreement and derivation rather than presence. Before M8
## the search path was a value in `repro.nim` threaded per-edge; it reached two
## of the five `-d:ssl` edges, and the three it missed included the one that
## builds `repro` itself. Every edge going through one derivation is what makes
## that state unexpressible — so the tests below lower SEVERAL edges and demand
## they agree, and demand the value equals the package's own answer.
##
## The include channel is deliberately absent from the argv. `openssl_layout`
## explains why: Nim's `std/openssl` is a `{.dynlib.}` wrapper that compiles no
## OpenSSL header, so `--passC:-I<prefix>/include` would be an unused flag with
## a real shadowing cost on the shared mingw prefixes Windows hosts resolve to.
## The last test here holds that line, so adding one becomes a deliberate act.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/openssl_layout
import repro_dsl_stdlib/prefix_layout
import repro_dsl_stdlib/packages/nim as nim_module

proc argByName(action: BuildActionDef; name: string): seq[string] =
  ## The repeated argument's values, decoded. `PublicCliArg.encodedValue`
  ## joins a `seq[string]` with `\x1f` (`runtime_core.nim`), and the engine
  ## splits it back to one `--passL:<value>` per element — so comparing the
  ## decoded LIST is comparing what lands on the argv, where a substring
  ## check on the raw encoding would pass on `-lssl3` too.
  for arg in action.call.arguments:
    if arg.name == name:
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split("\x1f")
  @[]

proc searchPaths(action: BuildActionDef): seq[string] =
  for value in action.argByName("passL"):
    if value.startsWith("-L"):
      result.add(value)

proc makeOpensslPrefix(root: string): string =
  ## A `plWindowsTree` prefix carrying both import libraries — the shape an
  ## MSYS2 install has, and the one a Windows host resolves in practice.
  result = root
  createDir(root / binDir(plWindowsTree))
  createDir(root / linkLibDir(plWindowsTree))
  writeFile(root / binDir(plWindowsTree) / "openssl.exe", "stub")
  for name in ["libssl.dll.a", "libcrypto.dll.a"]:
    writeFile(root / linkLibDir(plWindowsTree) / name, "stub")

suite "nim.c derives the OpenSSL search path for every ssl edge":

  setup:
    resetBuildActionRegistry()
    resetTargetExportRegistry()
    resetOpensslPrefixCandidates()

  teardown:
    resetOpensslPrefixCandidates()

  test "an ssl edge carries the declared prefix's link directory":
    let root = getTempDir() / "m8-nimc-ssl"
    removeDir(root)
    discard makeOpensslPrefix(root)
    defer: removeDir(root)
    registerOpensslPrefixCandidate(root)

    let expected = windowsOpensslLinkSearchDir()
    checkpoint("package answer: [" & expected & "]")

    let action = nim.c(
      source = "src/main.nim",
      binary = "build/bin/example",
      defines = @["ssl"],
      actionId = "nim.ssl.derived")

    let passL = action.argByName("passL")
    checkpoint("passL: " & $passL)
    check "-lssl" in passL
    check "-lcrypto" in passL

    when defined(windows):
      # The whole point: a usable `-L`, and one that equals what the PACKAGE
      # says rather than a literal this test also knows.
      check expected.len > 0
      check ("-L" & expected) in passL
      check dirExists(expected)
      check fileExists(expected / "libssl.dll.a")
      # And the `-L` precedes the `-l` names it has to satisfy.
      check passL.find("-L" & expected) < passL.find("-lssl")
    else:
      # Off Windows the `nixPackage` arm supplies the channel; a second one
      # derived from the host would be exactly the ambient dependency
      # `uses: "openssl"` exists to remove.
      check expected == ""
      check searchPaths(action).len == 0

  test "every ssl edge agrees, and non-ssl edges get nothing":
    # The partial-coverage guard. Three ssl edges and one without, lowered
    # through the same alias with different `passL` inputs — the ssl ones must
    # agree with each other and with the package, and the plain one must carry
    # no OpenSSL search path at all.
    let root = getTempDir() / "m8-nimc-ssl-many"
    removeDir(root)
    discard makeOpensslPrefix(root)
    defer: removeDir(root)
    registerOpensslPrefixCandidate(root)

    let first = nim.c(source = "src/a.nim", binary = "build/bin/a",
      defines = @["ssl"], actionId = "nim.ssl.a")
    let second = nim.c(source = "src/b.nim", binary = "build/bin/b",
      defines = @["release", "ssl"], passL = @["-lz"],
      actionId = "nim.ssl.b")
    let third = nim.c(source = "src/c.nim", binary = "build/bin/c",
      defines = @["--define:ssl"], passL = @["-Wl,-rpath,/somewhere"],
      actionId = "nim.ssl.c")
    let plain = nim.c(source = "src/d.nim", binary = "build/bin/d",
      defines = @["release"], actionId = "nim.plain")

    checkpoint("a: " & $first.searchPaths())
    checkpoint("b: " & $second.searchPaths())
    checkpoint("c: " & $third.searchPaths())
    check first.searchPaths() == second.searchPaths()
    check second.searchPaths() == third.searchPaths()
    check plain.searchPaths().len == 0
    check "-lssl" notin plain.argByName("passL")

    when defined(windows):
      check first.searchPaths() == @["-L" & windowsOpensslLinkSearchDir()]
      # The edge's own `passL` survives alongside the derived one.
      check "-lz" in second.argByName("passL")
      check "-Wl,-rpath,/somewhere" in third.argByName("passL")

  test "a host with no OpenSSL development libraries gets no -L at all":
    # Fail-closed. The link still fails, with the same `cannot find -lssl` — a
    # `-L` naming a directory with no OpenSSL in it would make the diagnostic
    # lie about where to look.
    let root = getTempDir() / "m8-nimc-ssl-bare"
    removeDir(root)
    createDir(root / binDir(plWindowsTree))
    writeFile(root / binDir(plWindowsTree) / "openssl.exe", "stub")
    defer: removeDir(root)
    registerOpensslPrefixCandidate(root)

    let action = nim.c(source = "src/main.nim", binary = "build/bin/example",
      defines = @["ssl"], actionId = "nim.ssl.bare")
    check "-lssl" in action.argByName("passL")
    check opensslLinkDirFromCandidates() == ""
    # Only the host's own PATH could still supply one; what must never appear
    # is a `-L` pointing into the offered prefix, which has no libraries.
    for value in action.searchPaths():
      check root notin value

  test "the include channel is declared but not projected onto the argv":
    # Guarding a deliberate omission, so re-adding it is a decision rather
    # than a drift. `opensslIncludeDir` exists and is part of the layout; what
    # must not happen is an unused `--passC:-I` onto every ssl edge (see the
    # module docstring in `openssl_layout`).
    let root = getTempDir() / "m8-nimc-ssl-inc"
    removeDir(root)
    discard makeOpensslPrefix(root)
    createDir(root / includeDir(plWindowsTree) / "openssl")
    defer: removeDir(root)
    registerOpensslPrefixCandidate(root)

    check opensslIncludeDir(root, plWindowsTree) ==
      root / includeDir(plWindowsTree)
    check dirExists(opensslIncludeDir(root, plWindowsTree))

    let action = nim.c(source = "src/main.nim", binary = "build/bin/example",
      defines = @["ssl"], actionId = "nim.ssl.include")
    for value in action.argByName("passC"):
      check not value.startsWith("-I")
    for value in action.argByName("passL"):
      check not value.startsWith("-I")
