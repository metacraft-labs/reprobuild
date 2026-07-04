## M9.R.76.2 — install-mirror path resolver (spec R10).
##
## Every threading site in the DSL stdlib that used to hardcode
## ``<recipeRoot>/<depName>/.repro/output/install/`` MUST route
## through this module so the migration to content-hashed side-by-side
## prefixes can happen incrementally without touching every call
## site again.
##
## Spec: reprobuild-specs/Store-And-Installation-Layout.md §R10
##       (Immutable Side-By-Side Prefixes) + companion doc
##       Immutable-Install-Mirror-Prefixes.md.
##
## Design (see Immutable-Install-Mirror-Prefixes.md §"Resolver contract"):
##
##   Mode is chosen at plan time via ``$REPRO_INSTALL_MIRROR_MODE``:
##
##     ``legacy``                          — legacy stable-mutable path
##                                           ``<recipeRoot>/<dep>/.repro/output/install/``
##     ``hashed``                          — content-hashed prefix
##                                           ``<store>/prefixes/<dep>/<version>-<hash>/``
##                                           (falls back to legacy if
##                                           the hashed prefix cannot
##                                           be resolved yet — recipes
##                                           opt into hashed publish
##                                           per-recipe, so a mixed
##                                           tree is expected during
##                                           migration)
##     ``hashed-with-legacy-fallback``     — prefer hashed when present,
##                                           fall back to legacy otherwise
##                                           (the transitional default)
##     unset / anything else               — legacy (Phase 0 default)
##
## The resolver returns POSIX-style forward-slashed paths so the emitted
## shell scripts don't need extra escaping.
##
## v1 scope (this milestone): the ``hashed`` code paths return the same
## paths as ``legacy`` because no recipe has opted in yet. The plumbing
## is in place so that when a recipe declares ``useHashedMirror = true``
## (a follow-up milestone), the resolver can switch its return value
## without changing any consumer call site.

import std/[os, strutils]

const InstallMirrorModeEnvVar* = "REPRO_INSTALL_MIRROR_MODE"

const StoreRootEnvVar* = "REPRO_STORE_ROOT"
  ## Environment variable that overrides the default CAS/Layer-2 store
  ## root when the hashed resolver is active. Mirrors the same variable
  ## already consumed by ``repro_local_store``'s ``resolveStoreRoot``.

const RealizationInfoFileName* = ".realization-info"
  ## The per-recipe sidecar the M9.R.77.3 hashed-mirror flow writes at
  ## ``<recipesRoot>/<depName>/.repro/output/.realization-info``. Two
  ## KV lines terminate with LF:
  ##
  ##   ``version=<version-string>``
  ##   ``realization-hash=<64-char-lowercase-hex>``
  ##
  ## The file is committed by the install-mirror emit action once the
  ## recipe has opted into ``useHashedMirror`` mode. Both keys are
  ## required for the hashed resolver to return a non-empty path.

type
  InstallMirrorMode* = enum
    immLegacy = "legacy"
    immHashed = "hashed"
    immHashedWithLegacyFallback = "hashed-with-legacy-fallback"

const LegacyInstallSubpath = ".repro/output/install"

proc currentInstallMirrorMode*(): InstallMirrorMode =
  ## Resolve the mode from the environment. Unset / unrecognised falls
  ## back to ``immLegacy`` per the spec's Phase 0 default.
  case getEnv(InstallMirrorModeEnvVar).toLowerAscii()
  of "hashed":
    immHashed
  of "hashed-with-legacy-fallback":
    immHashedWithLegacyFallback
  else:
    immLegacy

proc legacyDepMirrorRoot(recipesRoot, depName: string): string =
  ## The stable per-recipe path. Kept as a single choke point so a
  ## future audit can Grep for one function name rather than eight
  ## copies of the same string literal.
  (recipesRoot / depName / LegacyInstallSubpath).replace("\\", "/")

proc resolveCasStoreRoot*(): string =
  ## Return the absolute CAS/Layer-2 store root the hashed resolver
  ## resolves against. The single choke point so a downstream caller
  ## needing the same value (a shell script, an evidence dump, a
  ## test) reads one function name.
  ##
  ## Resolution order (matches ``repro_local_store.resolveStoreRoot``):
  ##
  ##   1. ``$REPRO_STORE_ROOT`` when non-empty.
  ##   2. Platform default:
  ##        * Windows:  ``%LOCALAPPDATA%\repro\store``
  ##        * Linux:    ``$XDG_CACHE_HOME/repro/store`` or
  ##                    ``$HOME/.cache/repro/store``
  ##        * macOS:    ``$HOME/Library/Caches/repro/store``
  let fromEnv = getEnv(StoreRootEnvVar)
  if fromEnv.len > 0:
    return fromEnv
  when defined(windows):
    let localAppData = getEnv("LOCALAPPDATA")
    if localAppData.len > 0:
      return localAppData & "/repro/store"
    return getHomeDir() & "AppData/Local/repro/store"
  elif defined(macosx):
    return getHomeDir() & "Library/Caches/repro/store"
  else:
    let xdg = getEnv("XDG_CACHE_HOME")
    if xdg.len > 0:
      return xdg & "/repro/store"
    return getHomeDir() & ".cache/repro/store"

proc realizationInfoPath*(recipesRoot, depName: string): string =
  ## Location of the sidecar the hashed-mirror emit writes for
  ## ``depName``. The resolver reads (version, realization-hash) out
  ## of this file to compute the hashed prefix path.
  (recipesRoot / depName / ".repro" / "output" / RealizationInfoFileName)
    .replace("\\", "/")

proc writeRealizationInfoFile*(recipesRoot, depName, version,
                               realizationHashHex: string) =
  ## Write the two-line KV sidecar the hashed resolver consumes.
  ## Used by the install-mirror emit action once the recipe has opted
  ## into ``useHashedMirror`` mode. Idempotent: an identical file
  ## already on disk is left alone.
  if recipesRoot.len == 0 or depName.len == 0: return
  if version.len == 0 or realizationHashHex.len != 64: return
  let path = realizationInfoPath(recipesRoot, depName)
  let payload = "version=" & version & "\n" &
                "realization-hash=" & realizationHashHex & "\n"
  if fileExists(path):
    let existing = try: readFile(path) except: ""
    if existing == payload:
      return
  createDir(parentDir(path))
  writeFile(path, payload)

type
  RealizationInfo* = object
    ## Parsed contents of the ``.realization-info`` sidecar. Both
    ## fields are non-empty iff the parse succeeded.
    version*: string
    realizationHashHex*: string

proc readRealizationInfoFile*(recipesRoot, depName: string): RealizationInfo =
  ## Read + parse the ``.realization-info`` sidecar. Returns a
  ## zero-initialised ``RealizationInfo`` (both fields empty) when
  ## the sidecar is missing / malformed / partial. Every caller MUST
  ## check both ``.version`` AND ``.realizationHashHex`` are non-empty
  ## before consuming the return value.
  if recipesRoot.len == 0 or depName.len == 0: return
  let path = realizationInfoPath(recipesRoot, depName)
  if not fileExists(path): return
  let raw = try: readFile(path) except: ""
  if raw.len == 0: return
  for rawLine in raw.splitLines():
    let line = rawLine.strip()
    if line.len == 0: continue
    let eqIdx = line.find('=')
    if eqIdx < 1: continue
    let key = line[0 ..< eqIdx].strip()
    let value = line[eqIdx + 1 .. ^1].strip()
    if key == "version":
      result.version = value
    elif key == "realization-hash":
      if value.len == 64:
        result.realizationHashHex = value

proc hashedDepMirrorRoot*(recipesRoot, depName: string): string =
  ## Return the content-hashed prefix path for ``depName``. Reads the
  ## ``.realization-info`` sidecar the emit-side wrote and constructs
  ## ``<store-root>/prefixes/<depName>/<version>-<hash>/``.
  ##
  ## Returns the empty string when the sidecar is missing or the recipe
  ## has not yet opted into hashed publish. Callers MUST fall back to
  ## the legacy path in that case (both ``immHashed`` and
  ## ``immHashedWithLegacyFallback`` do this).
  ##
  ## Spec: Store-And-Installation-Layout.md §R11 Two-Layer Split; the
  ## returned path is the Layer-2 read view built on top of the CAS
  ## store's blob layout.
  if recipesRoot.len == 0 or depName.len == 0: return ""
  let info = readRealizationInfoFile(recipesRoot, depName)
  if info.version.len == 0 or info.realizationHashHex.len == 0:
    return ""
  let storeRoot = resolveCasStoreRoot().replace("\\", "/")
  storeRoot & "/prefixes/" & depName & "/" &
    info.version & "-" & info.realizationHashHex

proc packageInstallMirrorRoot*(recipesRoot, depName: string): string =
  ## Return the resolved install-mirror root for ``depName``. POSIX-
  ## slashed. Empty if the caller passes an empty dep or an empty
  ## recipes root (unit-test mode).
  if depName.len == 0 or recipesRoot.len == 0:
    return ""
  case currentInstallMirrorMode()
  of immLegacy:
    legacyDepMirrorRoot(recipesRoot, depName)
  of immHashed:
    let hashed = hashedDepMirrorRoot(recipesRoot, depName)
    if hashed.len > 0: hashed
    else: legacyDepMirrorRoot(recipesRoot, depName)
  of immHashedWithLegacyFallback:
    let hashed = hashedDepMirrorRoot(recipesRoot, depName)
    let legacy = legacyDepMirrorRoot(recipesRoot, depName)
    if hashed.len > 0 and dirExists(hashed): hashed
    else: legacy

proc packageInstallMirrorLibDirs*(recipesRoot, depName: string): seq[string] =
  ## Return the dep's install-mirror lib + lib64 directories.
  ## Both entries are always returned (whether they exist on disk or
  ## not); the emitted shell script guards each with ``[ -d ... ]``.
  let root = packageInstallMirrorRoot(recipesRoot, depName)
  if root.len == 0: return
  result.add(root & "/usr/lib")
  result.add(root & "/usr/lib64")

proc packageInstallMirrorPkgConfigDirs*(recipesRoot, depName: string):
    seq[string] =
  ## Return the dep's install-mirror pkgconfig directories.
  let root = packageInstallMirrorRoot(recipesRoot, depName)
  if root.len == 0: return
  result.add(root & "/usr/lib/pkgconfig")
  result.add(root & "/usr/lib64/pkgconfig")
  result.add(root & "/usr/share/pkgconfig")

proc packageInstallMirrorCmakeRoot*(recipesRoot, depName: string): string =
  ## Return the dep's install-mirror CMake config root
  ## (``<mirror>/usr/lib/cmake``). Empty if the mirror root is empty.
  let root = packageInstallMirrorRoot(recipesRoot, depName)
  if root.len == 0: return ""
  root & "/usr/lib/cmake"

proc packageInstallMirrorIncludeDir*(recipesRoot, depName: string): string =
  let root = packageInstallMirrorRoot(recipesRoot, depName)
  if root.len == 0: return ""
  root & "/usr/include"

proc packageInstallMirrorPropagatedManifestPath*(recipesRoot, depName,
    manifestFile: string): string =
  ## Return the absolute path of the dep's ``.m9r30_propagated_libdirs.txt``
  ## (or any other per-recipe manifest file that lives at the mirror root).
  ## ``manifestFile`` is the filename WITHIN the mirror root.
  let root = packageInstallMirrorRoot(recipesRoot, depName)
  if root.len == 0: return ""
  root & "/" & manifestFile

proc packageInstallMirrorHumanFriendlyPath*(recipesRoot, depName: string):
    string =
  ## Return the *legacy* path unconditionally — for diagnostic/log
  ## messages that must be stable across mode switches. Use
  ## ``packageInstallMirrorRoot`` for actual on-disk operations.
  if depName.len == 0 or recipesRoot.len == 0: return ""
  legacyDepMirrorRoot(recipesRoot, depName)

proc emitInstallMirrorReadOnlyEnforcement*(mirrorRoot: string;
                                            mode = currentInstallMirrorMode()):
    string =
  ## M9.R.76.4 — emit a POSIX shell snippet that makes ``mirrorRoot``
  ## read-only after publish, per spec R10 "Read-Only Enforcement".
  ##
  ## Gating:
  ##   * ``immLegacy``: returns the empty string — the legacy mutable
  ##     stable path MUST stay writable so the next rebuild's ``rm -rf``
  ##     can clobber it.
  ##   * ``immHashed`` / ``immHashedWithLegacyFallback``: emits
  ##     ``chmod -R a-w`` on the mirror root. The prefix is content-
  ##     hashed and will never be rewritten — any later attempt to
  ##     mutate it MUST fail with EROFS per R7 (double-write is an
  ##     error).
  ##
  ## The snippet is guarded by ``[ -d ... ]`` so an idempotent re-run
  ## does not attempt to chmod a non-existent path.
  ##
  ## On non-Linux hosts the snippet is a no-op because the mirror
  ## action itself never runs there. When the resolver is later
  ## extended to a sandbox-policy backend (per the spec addendum's
  ## "Read-Only Enforcement" §2), this helper is the single point
  ## the mode-switch flows through.
  if mode == immLegacy:
    return ""
  if mirrorRoot.len == 0:
    return ""
  let escapedRoot = mirrorRoot.replace("\"", "\\\"")
  var s = ""
  s.add("if [ -d \"" & escapedRoot & "\" ]; then ")
  # ``chmod -R a-w`` strips write bits for user/group/other on every
  # file + dir under the prefix. A deliberate mutation attempt then
  # fails with EACCES (or EROFS on a bind-mounted ro root — the two
  # error codes are treated identically at the sandbox policy layer).
  s.add("chmod -R a-w \"" & escapedRoot & "\"; ")
  s.add("fi; ")
  s

proc installMirrorEnforcesReadOnly*(mode = currentInstallMirrorMode()): bool =
  ## Convenience predicate for callers that need to decide whether to
  ## emit the enforcement snippet at plan time.
  mode != immLegacy
