## Source discovery, sibling-import walk, and source-digest computation for
## the M83 profile-compile build-graph edge.
##
## These helpers are pure (no Nim invocation, no build engine) so they can
## be reused by tests, the apply pipeline (Phase D), and the internal
## `__repro-compile-profile` helper subcommand.

import std/[algorithm, os, strutils]
from repro_core/paths import extendedPath

import blake3

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

## Lib names whose `src` directories must appear on `--path:` for a profile
## compile. Mirrors the list in `config.nims`; we intentionally only include
## the libraries a profile could legitimately import (the profile macro
## library + its dependencies). The same list is reused by the internal
## `__repro-compile-profile` helper to construct the Nim command line.
const ProfileNimPathLibs* = [
  "repro_core",
  "repro_platform",
  "repro_diagnostics",
  "blake3",
  "xxh3",
  "gxhash",
  "repro_hash",
  "cbor",
  "repro_domain_types",
  "repro_profile",
  "repro_profile_intent",
]

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
  ## The list of `<libs>/<name>/src` directories that must be passed via
  ## `--path:` for a profile compile. Caller is responsible for any quoting.
  for libName in ProfileNimPathLibs:
    result.add repoRoot / "libs" / libName / "src"

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
  ## `(rel-path, blake3(content))` for each source file. `anchorDir`
  ## is the directory the relative paths are computed against — the
  ## profile root's parent. Using a stable anchor makes the digest
  ## reproducible across machines.
  var hasher = initHasher()
  var manifestParts: seq[string]
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
