## Source discovery, sibling-import walk, and source-digest computation for
## the M83 profile-compile build-graph edge.
##
## These helpers are pure (no Nim invocation, no build engine) so they can
## be reused by tests, the apply pipeline (Phase D), and the internal
## `__repro-compile-profile` helper subcommand.

import std/[algorithm, os, strutils]
from repro_core/paths import extendedPath

import blake3
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
  ## Locate the reprobuild repo root. Precedence:
  ##
  ## 1. `$REPROBUILD_REPO_ROOT` (operator override).
  ## 2. The compile-time root computed from this file's location.
  ##
  ## The returned path is NOT guaranteed to exist on installed deployments.
  ## A future phase will ship the libs alongside the binary and make the
  ## override unnecessary.
  let envRoot = getEnv(RepoRootEnvVar)
  if envRoot.len > 0:
    return envRoot
  CompiledRepoRoot

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
  ## `repro_project_dsl/install_mirror_resolver` -> `repro_local_store` ->
  ## `repro_shm_index`, and further into `repro_peer_cache`,
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
# Sibling-import discovery (lightweight manual parser).
# ---------------------------------------------------------------------------

proc isRelativeImport(spec: string): bool =
  ## True for `./...` or `../...` — the sibling-import family the
  ## walker follows. Absolute paths, package names (`repro_profile`),
  ## and stdlib (`std/os`) are all rejected.
  spec.startsWith("./") or spec.startsWith("../")

proc trimComment(line: string): string =
  let hashIdx = line.find('#')
  if hashIdx < 0:
    line
  else:
    line[0 ..< hashIdx]

proc parseSiblingImports*(source: string): seq[string] =
  ## Return the relative module paths (without `.nim` suffix) imported
  ## from `source` via `import ./...` / `import "./..."`. Only the
  ## FIRST module on the line is captured (the walker treats
  ## comma-separated import lists as out-of-scope; a later phase will
  ## upgrade to a proper Nim AST walk).
  ##
  ## Quoted form (`import "./foo"`) is supported because the Phase A
  ## profile DSL examples show it occasionally.
  for rawLine in source.splitLines:
    var line = trimComment(rawLine).strip()
    if not line.startsWith("import"):
      continue
    if line.len < 7 or line[6] notin {' ', '\t'}:
      continue
    var rest = line[6 .. ^1].strip()
    var spec: string
    if rest.startsWith("\""):
      let closeIdx = rest.find('"', 1)
      if closeIdx <= 0:
        continue
      spec = rest[1 ..< closeIdx]
    else:
      var endIdx = 0
      while endIdx < rest.len and rest[endIdx] notin {' ', '\t', ','}:
        inc endIdx
      spec = rest[0 ..< endIdx]
    if not isRelativeImport(spec):
      continue
    if spec.endsWith(".nim"):
      spec = spec[0 ..< spec.len - 4]
    result.add spec

proc resolveImportedFile(importerDir, importSpec: string): string =
  ## Resolve a sibling-import spec like `./modules/foo` against the
  ## importer's directory, returning the absolute path to the `.nim`
  ## file (or empty string if it does not exist).
  let combined = importerDir / importSpec
  let candidate = if combined.endsWith(".nim"): combined
                  else: combined & ".nim"
  let abs = absolutePath(candidate)
  if fileExists(extendedPath(abs)):
    return abs
  ""

proc discoverProfileSources*(profileRoot: string): seq[string] =
  ## BFS-walk transitive `import ./...` siblings from `profileRoot`.
  ## Returns absolute paths in lex-sorted order.
  var seen: seq[string] = @[absolutePath(profileRoot)]
  var pending = @[absolutePath(profileRoot)]
  while pending.len > 0:
    let cur = pending[0]
    pending.delete(0)
    let body =
      try:
        readFile(extendedPath(cur))
      except IOError:
        ""
    let curDir = cur.parentDir
    for spec in parseSiblingImports(body):
      let resolved = resolveImportedFile(curDir, spec)
      if resolved.len == 0:
        continue
      if resolved notin seen:
        seen.add resolved
        pending.add resolved
  result = seen
  result.sort()

# ---------------------------------------------------------------------------
# Digest computation.
# ---------------------------------------------------------------------------

type
  ProfileDigest* = object
    digestHex*: string
    manifest*: string  ## human-readable "<rel-path>\t<file-blake3-hex>\n" lines

proc computeProfileDigest*(sources: seq[string]; anchorDir: string):
    ProfileDigest =
  ## Compute the BLAKE3-256 cache key over the concatenation of
  ## `(rel-path, blake3(content))` for each source file, prefixed with
  ## a stable schema-identity tag. `anchorDir` is the directory the
  ## relative paths are computed against — the profile root's parent.
  ## Using a stable anchor makes the digest reproducible across machines.
  ##
  ## Schema-identity prefix (2026-06-09): the digest input starts with
  ## a fixed `"rbpi-schema-v<N>\n"` line, where `<N>` is the current
  ## `RbpiSchemaVersion`. Bumping the envelope schema therefore
  ## changes the digest for the SAME source content — every cache
  ## entry under `<state-dir>/profile-cache/<digest>.rbpi` from the
  ## previous schema is automatically a cache miss (the cache key
  ## doesn't collide with any v<N> entry). Combined with the strict
  ## envelope reader (which rejects unsupported versions outright),
  ## this gives two-layer cache safety: the lookup misses BEFORE we
  ## try to read a stale file, and even if we did read one, the
  ## reader would reject it.
  ##
  ## What this does NOT cover: behaviour changes within a single
  ## schema version (e.g. a bug-fix to the planner that doesn't
  ## change the envelope shape). Those need a manual
  ## `--force-rebuild` or a wider-scoped invalidation mechanism. The
  ## schema version is the right granularity for *interpretation*
  ## changes only.
  var hasher = initHasher()
  hasher.update("rbpi-schema-v" & $profile_envelope.RbpiSchemaVersion & "\n")
  var manifestParts: seq[string]
  manifestParts.add "schema-version\t" &
    $profile_envelope.RbpiSchemaVersion & "\n"
  for absPath in sources:
    let relPath = relativePath(absPath, anchorDir).replace('\\', '/')
    let content =
      try:
        readFile(extendedPath(absPath))
      except IOError:
        ""
    let fileDigest = blake3.digest(content)
    let fileDigestHex = toHex(fileDigest)
    hasher.update(relPath)
    hasher.update(fileDigest)
    manifestParts.add relPath & "\t" & fileDigestHex & "\n"
  let overall = hasher.finalize()
  hasher.close()
  result.digestHex = toHex(overall)
  result.manifest = manifestParts.join("")

# ---------------------------------------------------------------------------
# Cache-layout helpers (state-dir/profile-cache/<digest>.{rbpi,source.txt}).
# ---------------------------------------------------------------------------

const ProfileCacheDirName* = "profile-cache"

proc profileCacheDir*(stateDir: string): string =
  stateDir / ProfileCacheDirName

proc cachedRbpiPath*(stateDir, digestHex: string): string =
  profileCacheDir(stateDir) / (digestHex & ".rbpi")

proc cachedSourcesPath*(stateDir, digestHex: string): string =
  profileCacheDir(stateDir) / (digestHex & ".source.txt")

proc cachedNimcacheDir*(stateDir, digestHex: string): string =
  profileCacheDir(stateDir) / "nimcache" / digestHex

proc pruneStaleProfileCache*(stateDir: string): int =
  ## Walk `<stateDir>/profile-cache/` and delete every `.rbpi` file
  ## whose envelope header does NOT match the current
  ## `RbpiSchemaVersion`. Also removes any sibling `.source.txt`
  ## manifest. Returns the number of `.rbpi` files deleted.
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
