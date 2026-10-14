## Repo-root and Nim-path discovery, profile-root resolution, and the
## `<state-dir>/profile-cache/` layout for the profile-compile edge.
##
## These helpers are pure (no Nim invocation, no build engine) so they can
## be reused by tests, the apply pipeline, and the internal
## `__repro-compile-profile` helper subcommand.
##
## RETIRED HERE, DELIBERATELY: the `import ./…` text walk
## (`discoverProfileSources`) and the digest computed over it
## (`computeProfileDigest`). They were the freshness key of the profile
## compile, and a text scan cannot see what Nim reads — `staticRead`,
## `include`, `when`, macros, `config.nims`, or anything the profile binary
## opens when it runs — so the key served a stale intent whenever a profile
## depended on one of those. The edge's dependency record now comes from
## io-mon (`edge.nim`). Do not reintroduce a source enumeration as a cache
## key, a depfile or an output name: see Compiles-Are-Normal-Edges.

import std/[algorithm, os, strutils]
from repro_core/paths import extendedPath
from repro_core/source_root import resolveReprobuildSourceRoot,
  describeReprobuildSourceRootSearch, InstalledSourceRootSubdir,
  ReprobuildSourceRootEnvVar, ReprobuildRepoRootEnvVar

import repro_profile_intent/envelope as profile_envelope

# ---------------------------------------------------------------------------
# Repo-root + Nim path discovery.
# ---------------------------------------------------------------------------

const
  ## Compile-time anchor: the reprobuild repo root computed from this file's
  ## location. `libs/repro_profile_compile/src/repro_profile_compile/sources.nim`
  ## is five parents deep from the repo root.
  ##
  ## M83 Phase F2: an off-by-one in this chain previously stepped one
  ## directory ABOVE the repo root, so `profileNimPaths(CompiledRepoRoot)`
  ## emitted bogus `--path:` flags whenever `$REPROBUILD_REPO_ROOT` was
  ## unset — invisibly fine for the legacy text-format gates (they took
  ## the legacy parser path), invisibly fine for tests that set the env
  ## explicitly (the F1 example), but a hard fail for every migrated
  ## Phase A fixture exercised through the production `repro home apply`
  ## CLI. F2 surfaced and fixed the chain.
  CompiledRepoRoot* = currentSourcePath().parentDir.parentDir.parentDir.
    parentDir.parentDir
  RepoRootEnvVar* = "REPROBUILD_REPO_ROOT"

const LibsDirName* = "libs"
  ## Directory under the repo root that holds every importable Nim package
  ## (`<repoRoot>/libs/<name>/src`). `profileNimPaths` enumerates it.

proc reprobuildRepoRoot*(): string =
  ## Locate the reprobuild source tree a profile compiles against.
  ##
  ## Resolved exactly as the provider compile resolves it
  ## (`repro_core/source_root.resolveReprobuildSourceRoot`, which
  ## `repro_cli_support.reprobuildLibraryWorkDir` also delegates to):
  ## `$REPROBUILD_LIBS_DIR` / `$REPROBUILD_REPO_ROOT`, then the installed
  ## package's `$REPROBUILD_SOURCE_ROOT`, then `share/repro/source` beside the
  ## running image's `bin/` (a release archive, GM1w), then the current
  ## directory, then the checkout this binary was built in (only while it
  ## runs from there). Each arm counts only when it really holds reprobuild's
  ## libs.
  ##
  ## This used to read `$REPROBUILD_REPO_ROOT` alone and otherwise return
  ## `CompiledRepoRoot` — under Nix the build sandbox path, which does not
  ## exist after the build — so the Nix package could not compile a profile
  ## although its wrapper names the sources in `$REPROBUILD_SOURCE_ROOT`
  ## (Gradual-Nix-To-Reprobuild-Migration GM1).
  ##
  ## When nothing resolves, `CompiledRepoRoot` is still returned so callers
  ## see a concrete path; `compileProfileBinary` then refuses it with a
  ## diagnostic naming the variables above. `compileProfileToRbpi` does not
  ## call this: it resolves directly and refuses with
  ## `missingReprobuildSourcesMessage` instead of compiling against a guess.
  result = resolveReprobuildSourceRoot()
  if result.len == 0:
    result = CompiledRepoRoot

proc missingReprobuildSourcesMessage*(): string =
  ## The diagnostic for a profile compile that found no reprobuild sources:
  ## where an installed `repro` keeps them, every candidate the resolver
  ## tried (`describeReprobuildSourceRootSearch`, so this message and the
  ## resolution cannot disagree), and the variables that select a tree.
  "repro profile compile: no reprobuild sources to compile the profile " &
    "against. An installed repro ships them in " &
    InstalledSourceRootSubdir & " under its install prefix (beside bin/); " &
    "a source checkout is found from the current directory. Looked at:\n" &
    describeReprobuildSourceRootSearch() &
    "Set $" & ReprobuildSourceRootEnvVar & " (or $" &
    ReprobuildRepoRootEnvVar & ") to a reprobuild source tree, or " &
    "reinstall repro with its share/ directory."

proc profileNimPaths*(repoRoot: string): seq[string] =
  ## Every `<repoRoot>/libs/<name>/src` directory that exists, lex-sorted by
  ## lib name. These are passed via `--path:` for a profile compile; the
  ## caller is responsible for any quoting.
  ##
  ## DERIVED, NOT HAND-MAINTAINED. This used to be a literal
  ## `ProfileNimPathLibs` array listing "the libraries a profile could
  ## legitimately import". That premise does not survive contact with a
  ## transitive import graph: a profile's `import repro_profile` reaches
  ## `repro_profile/build_actions` -> `repro_project_dsl` ->
  ## `repro_project_dsl/install_mirror_resolver` -> `repro_local_store`,
  ## and further into `repro_peer_cache`,
  ## `repro_provider_runtime`, `repro_solver` and `repro_system_apply`. Any
  ## commit that adds an `import` anywhere in that closure silently widened
  ## the requirement without touching this file, so the list drifted; the
  ## repo history shows three separate "add <lib> to ProfileNimPathLibs"
  ## fix commits, each one entry behind the actual graph. Enumerating the
  ## directory removes the class of bug rather than its latest instance.
  ##
  ## Over-inclusion is safe. Command-line `--path:` entries are appended at
  ## LOWER precedence than the `switch("path", ...)` entries the wrapper
  ## `config.nims` contributes, so a lib that is already resolved correctly
  ## cannot be hijacked by an entry added here; these only supply modules
  ## that would otherwise not resolve at all. Nim compiles only what is
  ## actually imported, so unreferenced entries cost a path-probe, not a
  ## compile. There are no cross-lib collisions among the top-level module
  ## names exposed by `libs/*/src` (each lib exposes only `<name>.nim` and
  ## `<name>/`), so an extra entry cannot shadow another lib's module.
  ##
  ## NOT covered here, by design: packages that live outside `libs/*/src`
  ## (`libs/nimcrypto`, whose `--path:` root is the package dir itself, and
  ## the sibling checkouts such as `nim-shm-queue`). Those are resolved
  ## through the env-var handshake with `config.nims` that `compile.nim`
  ## sets up.
  let libsRoot = repoRoot / LibsDirName
  if not dirExists(extendedPath(libsRoot)):
    return @[]
  var libNames: seq[string]
  for kind, path in walkDir(extendedPath(libsRoot)):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let libName = path.lastPathPart
    if libName.len == 0:
      continue
    if not dirExists(extendedPath(libsRoot / libName / "src")):
      continue
    libNames.add libName
  # Sort so the emitted command line is deterministic across filesystems
  # with different readdir orders — the argv is part of the profile-compile
  # BuildAction, and a reordered argv is a needless cache miss.
  libNames.sort()
  for libName in libNames:
    result.add libsRoot / libName / "src"

# ---------------------------------------------------------------------------
# Profile-root resolution.
# ---------------------------------------------------------------------------

const
  HomeProfileAnchor* = "home.nim"
  SystemProfileAnchor* = "system.nim"

proc resolveProfileRoot*(profileDir: string;
                         explicit: string = ""): string =
  ## Resolve a profile root file against a directory. When `explicit` is
  ## non-empty it is returned as an absolute path. Otherwise we probe
  ## `home.nim` then `system.nim` under `profileDir`. Returns an empty
  ## string when no profile could be located.
  if explicit.len > 0:
    return absolutePath(explicit)
  let homePath = profileDir / HomeProfileAnchor
  if fileExists(extendedPath(homePath)):
    return homePath
  let sysPath = profileDir / SystemProfileAnchor
  if fileExists(extendedPath(sysPath)):
    return sysPath
  ""

# ---------------------------------------------------------------------------
# Cache-layout helpers (state-dir/profile-cache/<profile-key>.rbpi, nimcache/<profile-key>).
# ---------------------------------------------------------------------------

const ProfileCacheDirName* = "profile-cache"

proc profileCacheDir*(stateDir: string): string =
  stateDir / ProfileCacheDirName

proc cachedRbpiPath*(stateDir, profileKey: string): string =
  ## Where the edge publishes the envelope of the profile `profileKey`
  ## (`edge.profileCompileKey`) names. A stable per-profile location: the
  ## content behind it is the action cache's to decide.
  profileCacheDir(stateDir) / (profileKey & ".rbpi")

proc cachedNimcacheDir*(stateDir, profileKey: string): string =
  ## The per-profile Nim cache: derived state, excluded from the edge's
  ## recorded inputs.
  profileCacheDir(stateDir) / "nimcache" / profileKey

proc pruneStaleProfileCache*(stateDir: string): int =
  ## Walk `<stateDir>/profile-cache/` and delete every `.rbpi` file
  ## whose envelope header does NOT match the current
  ## `RbpiSchemaVersion`. Also removes any sibling `.source.txt`
  ## manifest (written by releases whose edge still published one).
  ## Returns the number of `.rbpi` files deleted.
  ##
  ## The `readRbpiHeader` envelope reader raises on version mismatch,
  ## corrupt magic, or truncated input — we treat all of those the
  ## same way (the file is unusable to the current build) and remove
  ## the artefact. Files we cannot delete (e.g. read-only filesystem)
  ## are silently skipped.
  ##
  ## Called once per compile-entry from `edge.nim` so a reprobuild
  ## upgrade that bumps the schema version automatically cleans the
  ## previous version's cache the next time anyone runs
  ## `repro home apply`. The walk is O(N) over the file list but
  ## bounded by the per-profile cache footprint (usually 1-3 files);
  ## the call is no-op cheap when no stale entries exist.
  let cacheDir = profileCacheDir(stateDir)
  if not dirExists(extendedPath(cacheDir)):
    return 0
  for kind, path in walkDir(extendedPath(cacheDir)):
    if kind != pcFile: continue
    if not path.endsWith(".rbpi"): continue
    var isStale = false
    try:
      let raw = readFile(path)
      var bytes = newSeq[byte](raw.len)
      for i, ch in raw:
        bytes[i] = byte(ord(ch))
      discard profile_envelope.readRbpiHeader(bytes)
      # Reached: header is current schema. Keep the file.
    except CatchableError:
      isStale = true
    if isStale:
      try:
        removeFile(path)
        inc result
      except CatchableError:
        continue
      # Best-effort clean-up of the sibling manifest. Failure is
      # acceptable — the .rbpi removal alone is enough to force a
      # recompile on the next lookup.
      let manifestPath = path[0 ..< path.len - ".rbpi".len] & ".source.txt"
      if fileExists(extendedPath(manifestPath)):
        try: removeFile(extendedPath(manifestPath))
        except CatchableError: discard
