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

proc hashedDepMirrorRoot(depName: string): string =
  ## Placeholder for the content-hashed resolver.
  ##
  ## In v1 (this milestone) no recipe publishes to a hashed prefix so
  ## we return the empty string; the caller then falls back to legacy.
  ## Once the emit-side wiring lands (a follow-up milestone), this
  ## reads the recipe's realization hash from a per-recipe metadata
  ## file at ``<recipesRoot>/<depName>/.repro/output/.realization-hash``
  ## and returns
  ## ``<REPRO_STORE_ROOT>/prefixes/<depName>/<version>-<hash>/``.
  discard depName
  ""

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
    let hashed = hashedDepMirrorRoot(depName)
    if hashed.len > 0: hashed
    else: legacyDepMirrorRoot(recipesRoot, depName)
  of immHashedWithLegacyFallback:
    let hashed = hashedDepMirrorRoot(depName)
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
