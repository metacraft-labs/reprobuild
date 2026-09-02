## OpenSSL's library channel, declared by the producer instead of probed by
## each consumer.
##
## ## What this module is for
##
## `packages/openssl.nim` declares the package; `packages/nim.nim` appends
## `-lssl -lcrypto` to every `-d:ssl` edge. On Linux and macOS the `nixPackage`
## arm supplies the search path that makes those two flags resolvable, which is
## what `uses: "openssl"` promises — "graph-built binaries receive OpenSSL's
## library channels instead of depending on ambient `NIX_LDFLAGS`".
##
## On Windows the package declared no such arm, so `nim.c` emitted `-lssl
## -lcrypto` with nothing to find them with and every ssl link died on
## `ld.exe: cannot find -lssl`. That was closed in the CONSUMER —
## `windowsOpensslPassL()` in reprobuild's own `repro.nim` hard-coded MSYS2's
## `mingw64/lib` — which is the wrong layer twice over: the path was the
## consumer's to know, and it was a literal rather than a layout.
##
## This module is the producer-side replacement. It says, once:
##
##   * which prefix LAYOUTS an OpenSSL realization can have (`OpensslLayouts`),
##     named through `prefix_layout` rather than spelled as strings;
##   * which file names `ld` will accept for `-lssl` / `-lcrypto`
##     (`linkLibraryCandidates`), which is what makes "does this prefix
##     actually provide the library?" answerable instead of assumed;
##   * how to get from a RESOLVED `openssl.exe` back to its prefix and layout
##     (`opensslPrefixCandidates`), so the search path is derived from the
##     realization the engine picked rather than from a machine-specific
##     literal.
##
## ## Fail-closed, deliberately
##
## `resolvedOpensslLinkDir` returns the empty string unless a candidate prefix
## really holds an import library for BOTH stems. A host whose `openssl.exe` is
## Git-for-Windows' — which ships the executable and no development libraries —
## contributes nothing, and the link fails with the same clear `cannot find
## -lssl` it would have without this module. A `-L` pointing at a directory
## with no OpenSSL in it would be strictly worse: it would look like the
## channel was supplied.
##
## ## Why the include channel is declared but not projected
##
## `opensslIncludeDir` exists and is tested, because it is part of the layout
## the package claims. It is deliberately NOT threaded onto `nim c` edges as
## `--passC:-I...`, for two measured reasons:
##
##   1. Nim's `std/openssl` is a pure `{.dynlib.}` wrapper — it compiles no
##      OpenSSL header. Verified on the generated C for reprobuild's own
##      `repro` binary: `build/nimcache/repro/@popenssl.nim.c` includes exactly
##      `nimbase.h` and `<string.h>` and nothing else, and `objdump -p
##      build/bin/repro.exe` lists no OpenSSL DLL among its imports. The
##      `-lssl -lcrypto` on those edges are a LINK-TIME satisfaction
##      requirement only; no symbol from either import library is referenced.
##   2. On the layout a Windows host actually resolves to, the include
##      directory is a shared mingw prefix's `include/` holding hundreds of
##      unrelated headers. Putting it ahead of the compiler's own on every ssl
##      edge risks shadowing, in exchange for a flag nothing consumes.
##
## Adding an unused `-I` would be a claim this module cannot back. When a
## recipe appears that genuinely compiles against OpenSSL's headers, the
## channel is already named here for it.

import std/[os, strutils]

import repro_core/ambient_execution
import repro_dsl_stdlib/prefix_layout

export prefix_layout

const
  OpensslLinkStems* = ["ssl", "crypto"]
    ## The two `-l<stem>` names `packages/nim.nim` emits for `-d:ssl`. A prefix
    ## provides OpenSSL's link channel only if it can satisfy BOTH: a
    ## realization carrying `libssl` and not `libcrypto` links no further than
    ## one carrying neither.

  OpensslLayouts* = [plConda, plWindowsTree, plFlat]
    ## The prefix shapes an OpenSSL realization can take on Windows, most
    ## specific first.
    ##
    ## `plConda` is the shape of the declared `tarball` arm in
    ## `packages/openssl.nim` (conda-forge win-64 keeps its whole tree under
    ## `Library/`). `plWindowsTree` is the shape of an MSYS2 / mingw prefix,
    ## which is what a Windows host that installed
    ## `mingw-w64-x86_64-openssl` has on PATH. `plFlat` covers a small zip
    ## that drops `openssl.exe` at the prefix root.
    ##
    ## `plUnix` is absent on purpose rather than by oversight: its `binDir`
    ## and `linkLibDir` are `bin` and `lib`, identical to `plWindowsTree`, so
    ## listing it would produce a duplicate candidate for every prefix and
    ## change nothing about which directory is chosen.

func linkLibraryCandidates*(stem: string): seq[string] =
  ## The file names GNU `ld` will accept when resolving `-l<stem>` on PE
  ## targets, in its own search order.
  ##
  ## Both the mingw shape (`libssl.dll.a`, `libssl.a`) and the MSVC-produced
  ## import-library shape (`libssl.lib`, `ssl.lib`) are here, because both are
  ## linkable by the mingw `ld` reprobuild builds with. That is not an
  ## assumption: `gcc t.c -L<conda>/Library/lib -lssl -lcrypto` against
  ## conda-forge's MSVC-built `libssl.lib` / `libcrypto.lib` links under gcc
  ## 15.2.0 and the resulting executable runs. Restricting this list to the
  ## mingw spellings would silently reject the arm this package pins.
  @["lib" & stem & ".dll.a", stem & ".dll.a", "lib" & stem & ".a",
    "lib" & stem & ".lib", stem & ".lib"]

func opensslLinkDir*(prefix: string; layout: PrefixLayout): string =
  ## The directory `-L` must name for a realization at `prefix` in `layout`.
  if prefix.len == 0: ""
  elif linkLibDir(layout) == ".": prefix
  else: prefix / linkLibDir(layout)

func opensslIncludeDir*(prefix: string; layout: PrefixLayout): string =
  ## The directory holding `openssl/*.h` for a realization at `prefix`. See the
  ## module docstring for why this is declared and not projected.
  if prefix.len == 0: ""
  elif includeDir(layout) == ".": prefix
  else: prefix / includeDir(layout)

func normalizedDirSep(path: string): string =
  path.replace('\\', '/').strip(leading = false, chars = {'/'})

func opensslPrefixCandidates*(executablePath: string):
    seq[tuple[prefix: string, layout: PrefixLayout]] =
  ## Invert `binDir(layout)` — given the `openssl.exe` a resolver picked, the
  ## prefixes it could be the executable of, one per layout that its parent
  ## directory is consistent with.
  ##
  ## This is the piece that makes the search path DERIVED. The consumer-side
  ## workaround this replaces named a directory; the layout functions name a
  ## relation, and a resolved executable is enough to invert it.
  if executablePath.len == 0:
    return @[]
  let binPath = normalizedDirSep(executablePath.parentDir)
  if binPath.len == 0:
    return @[]
  for layout in OpensslLayouts:
    let rel = normalizedDirSep(binDir(layout))
    if rel == "." or rel.len == 0:
      # Flat: the executable's own directory IS the prefix.
      result.add((prefix: binPath, layout: layout))
    elif binPath.toLowerAscii.endsWith("/" & rel.toLowerAscii):
      result.add((prefix: binPath[0 ..< binPath.len - rel.len - 1],
        layout: layout))

proc prefixProvidesLinkLibraries*(prefix: string; layout: PrefixLayout): bool =
  ## True when `prefix` really holds an import library for every stem in
  ## `OpensslLinkStems` under `layout`'s link directory.
  let dir = opensslLinkDir(prefix, layout)
  if dir.len == 0:
    return false
  for stem in OpensslLinkStems:
    var found = false
    for candidate in linkLibraryCandidates(stem):
      if fileExists(dir / candidate):
        found = true
        break
    if not found:
      return false
  true

proc opensslLinkDirForExecutable*(executablePath: string): string =
  ## The `-L` directory for a resolved `openssl.exe`, or `""` when none of its
  ## candidate prefixes actually provides the link channel.
  for candidate in opensslPrefixCandidates(executablePath):
    if prefixProvidesLinkLibraries(candidate.prefix, candidate.layout):
      return opensslLinkDir(candidate.prefix, candidate.layout)
  ""

proc resolvedOpensslExecutable*(): string =
  ## Where `openssl` resolves for this build.
  ##
  ## `uncontrolledFindExe` reproduces, exactly, the rule
  ## `repro_tool_profiles.resolvePathOnlyTool` applies under
  ## `--tool-provisioning=path` (`findExecutableOnPath` over `splitPathList
  ## getEnv "PATH"`), which is the mode reprobuild's own recipe declares. So
  ## the prefix this derives from is the prefix the engine's own resolver
  ## picks for `uses: "openssl"`, not a second, divergent opinion.
  ##
  ## It is ambient resolution, and it is labelled as such rather than hidden.
  ## The durable replacement is an action-time `toolPrefix("openssl")`
  ## accessor: `toolIdentityRefs` hands an action a bin DIRECTORY on PATH, not
  ## a prefix, so there is currently no way for a lowered edge to address into
  ## the realization the engine chose. That gap is recorded in
  ## `docs/ambient-execution-linter.md` under "Blocked on a missing
  ## capability", and closing it retires this proc.
  uncontrolledFindExe("openssl")

# ---------------------------------------------------------------------------
# Consumer-offered prefixes, and why the seam is a PREFIX rather than a flag.
# ---------------------------------------------------------------------------

var opensslPrefixCandidateRegistry: seq[string] = @[]

proc registerOpensslPrefixCandidate*(prefix: string) =
  ## Offer a prefix that a consumer knows holds an OpenSSL realization.
  ##
  ## Some projects provision OpenSSL out of band — reprobuild's own Windows
  ## dev-deps tree installs MSYS2's `mingw-w64-x86_64-openssl` under a root
  ## its recipe knows and this catalog cannot — and that prefix is not always
  ## on `PATH` (Git-for-Windows ships an `openssl.exe` with no development
  ## libraries and routinely shadows it).
  ##
  ## What is offered is a PREFIX, deliberately, and that is the whole
  ## difference from the `windowsOpensslPassL()` this replaces. The consumer
  ## says "OpenSSL may be installed here"; the PACKAGE decides whether that is
  ## true, which directory the linker should be given, and in what order the
  ## sources are consulted. A consumer can no longer hand the build a `-L` the
  ## producer never agreed to, and it cannot express a layout — so a prefix
  ## whose shape does not match any arm this package declares contributes
  ## nothing rather than a directory the linker will search in vain.
  ##
  ## Registration is additive and order-preserving; duplicates are dropped.
  if prefix.len == 0:
    return
  if prefix notin opensslPrefixCandidateRegistry:
    opensslPrefixCandidateRegistry.add(prefix)

proc registeredOpensslPrefixCandidates*(): seq[string] =
  ## The offered prefixes, in registration order.
  opensslPrefixCandidateRegistry

proc resetOpensslPrefixCandidates*() =
  ## Drop every offered prefix. Tests use this to pin the precedence rule
  ## without depending on what the host happens to have.
  opensslPrefixCandidateRegistry = @[]

proc opensslLinkDirFromCandidates*(): string =
  ## The first offered prefix that satisfies the declared layout, or `""`.
  for prefix in registeredOpensslPrefixCandidates():
    for layout in OpensslLayouts:
      if prefixProvidesLinkLibraries(prefix, layout):
        return opensslLinkDir(prefix, layout)
  ""

proc windowsOpensslLinkSearchDir*(): string =
  ## The OpenSSL `-L` directory for this host, or `""`.
  ##
  ## PRECEDENCE, stated once because a fallback whose order is implicit is a
  ## fallback nobody can reason about:
  ##
  ##   1. The prefix of the `openssl.exe` that `--tool-provisioning=path`
  ##      resolution will pick. This is FIRST because it is the realization
  ##      the engine itself binds `uses: "openssl"` to; deriving the search
  ##      path from anything else while the engine resolves that one is how
  ##      a link and its declared dependency come to disagree.
  ##   2. Prefixes offered by the consuming project through
  ##      `registerOpensslPrefixCandidate`, in registration order. Reached
  ##      only when (1) resolved nothing or resolved a prefix with no
  ##      development libraries in it — which is the ordinary Windows case,
  ##      Git-for-Windows' `openssl.exe` being on almost every host's PATH.
  ##
  ## Both arms end in the same acceptance test: the directory must really
  ## contain an import library for both stems. An unsatisfied host gets `""`
  ## and the familiar `cannot find -lssl`, never a `-L` that resolves nothing.
  ##
  ## Non-Windows returns `""` unconditionally: the `nixPackage` arm already
  ## supplies the channel there, and a second one derived from PATH would be
  ## exactly the ambient dependency `uses: "openssl"` exists to remove.
  when defined(windows):
    let fromPath = opensslLinkDirForExecutable(resolvedOpensslExecutable())
    if fromPath.len > 0:
      return fromPath
    opensslLinkDirFromCandidates()
  else:
    ""
