## `repro profile` subcommands (M83 Phase C1).
##
## The CLI compiles a user-authored `home.nim` / `system.nim` profile to
## the RBPI binary envelope (M83 Phase B) and caches the artifact by a
## BLAKE3 source digest. Phase C1 uses Nim from `PATH` (no vendored
## bootstrap — that is M83 Phase C2).
##
## Surface:
##
##   ``repro profile build [--profile <path>] [--no-cache] [--out <path>]``
##
## Default profile root: probe `home.nim`, then `system.nim`, under the
## resolved profile directory (`repro_home_intent.resolveProfileDir()`).
##
## Default `--out`: stdout if stdout is not a TTY, else the cached
## artifact path. `--out -` always writes the RBPI bytes to stdout.
##
## Cache layout (under `repro_home_generations.resolveStateDir()`):
##
##     <state-dir>/profile-cache/
##       ├── <digest>.rbpi             # cached compiled artifact
##       ├── <digest>.source.txt       # tab-separated <path>\t<file-blake3>
##       └── nimcache/
##           └── <digest>/             # nim's per-compile cache
##
## The `<digest>` is BLAKE3-256 over the concatenation of
## `(rel-path, blake3(content))` for every source file in lex-sorted
## relative-path order. Transitive sibling imports are discovered with a
## lightweight regex over `import ./...` / `import "..."` lines (a proper
## Nim AST walk is deferred to a later phase).
##
## DEVIATION from the literal phase-C1 spec: the spec's example pipes
## `nim c -r ... > <digest>.rbpi.tmp` directly to disk, assuming the
## compiled binary emits RBPI bytes. Phase A's `repro_profile` library
## emits **JSON** to stdout, and we deliberately do NOT mutate Phase A
## (that would risk regressing every M83 Phase A gate). Instead we
## capture the JSON stdout, parse it via `parseProfileIntentJson`, and
## re-encode through `encodeRbpi` (Phase B). The resulting `<digest>.rbpi`
## is byte-identical to what a future "binary emit" mode would write —
## the round-trip JSON->ProfileIntent->RBPI is lossless by construction.

import std/[algorithm, os, osproc, strutils, terminal]

import blake3
import repro_profile
import repro_profile_intent
import repro_home_generations/state_dir
import repro_home_intent/host_identity
from repro_core/paths import extendedPath

# ---------------------------------------------------------------------------
# Repo-root + Nim path discovery.
# ---------------------------------------------------------------------------

const
  ## Compile-time anchor: the reprobuild repo root computed from this file's
  ## location. `libs/repro_cli_support/src/repro_cli_support/profile.nim` is
  ## four parents deep from the repo root.
  CompiledRepoRoot* = currentSourcePath().parentDir.parentDir.parentDir.
    parentDir.parentDir
  RepoRootEnvVar* = "REPROBUILD_REPO_ROOT"

# Lib names whose `src` directories must appear on `--path:` for a profile
# compile. Mirrors the list in `config.nims`; we intentionally only include
# the libraries a profile could legitimately import (the profile macro
# library + its dependencies). This is wider than strictly required but
# matches what the user already has on `--path` when they `nim c` from the
# repo root, so user-authored profiles cannot regress here.
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
  ## The returned path is NOT guaranteed to exist on installed deployments
  ## — Phase C1 only supports running from a developer's checkout. C2 will
  ## ship the libs alongside the binary and make the override unnecessary.
  let envRoot = getEnv(RepoRootEnvVar)
  if envRoot.len > 0:
    return envRoot
  CompiledRepoRoot

proc profileNimPaths*(repoRoot: string): seq[string] =
  ## The list of `--path:<libs/<name>/src>` directories for a profile
  ## compile. Caller is responsible for any quoting.
  for libName in ProfileNimPathLibs:
    result.add repoRoot / "libs" / libName / "src"

# ---------------------------------------------------------------------------
# Profile-root resolution.
# ---------------------------------------------------------------------------

const SystemProfileAnchor* = "system.nim"

proc resolveProfileRoot*(explicit: string): string =
  ## Resolve the profile root file. Returns an empty string when no
  ## profile could be located (caller surfaces a diagnostic).
  if explicit.len > 0:
    return absolutePath(explicit)
  let dir = resolveProfileDir()
  let homePath = dir / HomeProfileAnchor
  if fileExists(extendedPath(homePath)):
    return homePath
  let sysPath = dir / SystemProfileAnchor
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
  ## FIRST module on the line is captured (the Phase C1 walker treats
  ## comma-separated import lists as out-of-scope; M83 Phase F will
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
  ## Returns absolute paths in lex-sorted order, with the root first
  ## after sorting (lex-sort is the spec rule for digest stability —
  ## the root is in the set, just not necessarily first after sort).
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

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

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
# Profile-cache layout.
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

# ---------------------------------------------------------------------------
# Compilation.
# ---------------------------------------------------------------------------

type
  CompileFailure* = object of CatchableError
    stderrText*: string

proc requireNimOnPath(): string =
  ## Locate the `nim` binary. Phase C1 fails closed with a diagnostic
  ## pointing at the Phase C2 follow-up if Nim is absent.
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    raise newException(CompileFailure,
      "repro profile build: `nim` not found on PATH. Phase C1 requires " &
      "Nim from PATH; vendored-Nim auto-bootstrap is deferred to M83 " &
      "Phase C2. Install Nim >= 2.0 (https://nim-lang.org/install.html) " &
      "and re-run `repro profile build`.")
  nimExe

proc compileProfileBinary*(profileRoot, nimcacheDir, outBinary: string;
                           repoRoot: string;
                           verbose: bool = false): tuple[
    jsonOutput: string; stderrText: string] =
  ## Invoke `nim c -r` on `profileRoot`. Returns the captured stdout
  ## (the profile binary's JSON ProfileIntent emission) and the combined
  ## diagnostic stream from Nim itself (compile errors, warnings).
  ##
  ## Raises `CompileFailure` if Nim exits non-zero.
  let nimExe = requireNimOnPath()
  createDir(extendedPath(nimcacheDir))
  createDir(extendedPath(outBinary.parentDir))

  var nimCmd = quoteShell(nimExe) & " c -r --hints:off --warnings:off" &
    " --nimcache:" & quoteShell(nimcacheDir) &
    " --out:" & quoteShell(outBinary)
  for path in profileNimPaths(repoRoot):
    nimCmd.add " --path:" & quoteShell(path)
  nimCmd.add " " & quoteShell(profileRoot)
  if verbose:
    stderr.writeLine("repro profile build: " & nimCmd)

  # We need the compiled binary's stdout (the JSON ProfileIntent) without
  # interleaving Nim's progress chatter, so we redirect Nim's own output
  # to stderr via a sub-shell and rely on `nim c -r` writing the compiled
  # binary's stdout to the parent stdout. `execCmdEx` captures the
  # COMBINED stream, which mixes them. Workaround: run Nim with output
  # capture and split by looking for the JSON marker. Simpler: invoke
  # Nim in two phases — `nim c` (no -r) to compile, then run the
  # produced binary directly with `execCmdEx`.
  #
  # Two-phase invocation gives us clean stdout from the profile binary
  # and clean stderr/diagnostics from Nim itself. The trade-off is one
  # extra process spawn per cache miss, which is negligible vs. a Nim
  # compile.
  var compileCmd = quoteShell(nimExe) & " c --hints:off --warnings:off" &
    " --nimcache:" & quoteShell(nimcacheDir) &
    " --out:" & quoteShell(outBinary)
  for path in profileNimPaths(repoRoot):
    compileCmd.add " --path:" & quoteShell(path)
  compileCmd.add " " & quoteShell(profileRoot)

  let compileRes = execCmdEx(compileCmd)
  if compileRes.exitCode != 0:
    var err = new CompileFailure
    err.msg = "nim compile failed for " & profileRoot &
      " (exit " & $compileRes.exitCode & ")"
    err.stderrText = compileRes.output
    raise err

  let runRes = execCmdEx(quoteShell(outBinary))
  if runRes.exitCode != 0:
    var err = new CompileFailure
    err.msg = "compiled profile binary exited " & $runRes.exitCode &
      " for " & profileRoot
    err.stderrText = runRes.output
    raise err
  result.jsonOutput = runRes.output
  result.stderrText = compileRes.output

proc rbpiBytesFromJson*(jsonText: string): seq[byte] =
  ## Parse the JSON ProfileIntent and re-encode through the Phase B
  ## RBPI envelope. The JSON->ProfileIntent->RBPI round-trip is lossless.
  let trimmed = jsonText.strip()
  let p = parseProfileIntentJson(trimmed)
  encodeRbpi(p)

# ---------------------------------------------------------------------------
# Output sink.
# ---------------------------------------------------------------------------

type
  OutputSink = enum
    osinkDefault     ## "" — stdout if not a TTY, else the cache path.
    osinkStdout      ## "-" — always stdout.
    osinkExplicit    ## absolute path.

proc classifyOut(value: string):
    tuple[kind: OutputSink; path: string] =
  if value.len == 0:
    (osinkDefault, "")
  elif value == "-":
    (osinkStdout, "")
  else:
    (osinkExplicit, absolutePath(value))

proc writeBytesAtomic(path: string; bytes: seq[byte]) =
  let tmpPath = path & ".tmp"
  createDir(extendedPath(path.parentDir))
  let f = open(extendedPath(tmpPath), fmWrite)
  if bytes.len > 0:
    discard f.writeBuffer(unsafeAddr bytes[0], bytes.len)
  f.close()
  if fileExists(extendedPath(path)):
    removeFile(extendedPath(path))
  moveFile(extendedPath(tmpPath), extendedPath(path))

proc readFileBytes(path: string): seq[byte] =
  let s = readFile(extendedPath(path))
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ord(ch))

proc writeBytesToStdout(bytes: seq[byte]) =
  if bytes.len == 0: return
  discard stdout.writeBuffer(unsafeAddr bytes[0], bytes.len)
  stdout.flushFile()

# ---------------------------------------------------------------------------
# `repro profile build` driver.
# ---------------------------------------------------------------------------

type
  BuildFlags = object
    profile: string
    noCache: bool
    outValue: string
    verbose: bool

proc parseBuildFlags(args: openArray[string]): BuildFlags =
  var i = 0
  while i < args.len:
    let a = args[i]
    template valueOf(): string =
      if i + 1 >= args.len:
        raise newException(ValueError, a & " requires a value")
      else:
        inc i
        args[i]
    if a == "--profile":
      result.profile = valueOf()
    elif a.startsWith("--profile="):
      result.profile = a["--profile=".len .. ^1]
    elif a == "--no-cache":
      result.noCache = true
    elif a == "--out":
      result.outValue = valueOf()
    elif a.startsWith("--out="):
      result.outValue = a["--out=".len .. ^1]
    elif a == "--verbose" or a == "-v":
      result.verbose = true
    else:
      raise newException(ValueError,
        "repro profile build: unknown flag '" & a & "'")
    inc i

proc cachedArtifactIsValid(path: string): bool =
  ## Cheap structural sanity-check: read the file and confirm it parses
  ## as an RBPI envelope. Avoids returning a half-written or corrupted
  ## artifact on cache lookup.
  if not fileExists(extendedPath(path)):
    return false
  try:
    let raw = readFile(extendedPath(path))
    var bytes = newSeq[byte](raw.len)
    for i, ch in raw:
      bytes[i] = byte(ord(ch))
    discard readEnvelope(bytes)
    true
  except CatchableError:
    false

proc runProfileBuild*(args: seq[string]): int =
  ## `repro profile build` implementation. See module docstring.
  var flags: BuildFlags
  try:
    flags = parseBuildFlags(args)
  except ValueError as err:
    stderr.writeLine(err.msg)
    stderr.writeLine(
      "usage: repro profile build [--profile <path>] [--no-cache] " &
      "[--out <path>|-] [--verbose]")
    return 2

  let profileRoot = resolveProfileRoot(flags.profile)
  if profileRoot.len == 0:
    stderr.writeLine("repro profile build: no profile root found.")
    stderr.writeLine("  hint: pass --profile <path>, set " &
      "$REPRO_HOME_PROFILE_DIR, or create `home.nim` / `system.nim` " &
      "under the resolved profile directory (" & resolveProfileDir() &
      ").")
    return 2

  let stateDir = resolveStateDir()
  let cacheDir = profileCacheDir(stateDir)
  createDir(extendedPath(cacheDir))

  let sources = discoverProfileSources(profileRoot)
  let anchorDir = profileRoot.parentDir
  let digest = computeProfileDigest(sources, anchorDir)
  let rbpiPath = cachedRbpiPath(stateDir, digest.digestHex)
  let manifestPath = cachedSourcesPath(stateDir, digest.digestHex)
  let nimcacheDir = cachedNimcacheDir(stateDir, digest.digestHex)

  let outKind = classifyOut(flags.outValue)

  # Cache hit path.
  if not flags.noCache and cachedArtifactIsValid(rbpiPath):
    if flags.verbose:
      stderr.writeLine("repro profile build: cache hit " &
        digest.digestHex & " (" & rbpiPath & ")")
    case outKind.kind
    of osinkStdout:
      writeBytesToStdout(readFileBytes(rbpiPath))
    of osinkExplicit:
      copyFile(extendedPath(rbpiPath), extendedPath(outKind.path))
      stdout.writeLine(outKind.path)
    of osinkDefault:
      if isatty(stdout):
        stdout.writeLine(rbpiPath)
      else:
        writeBytesToStdout(readFileBytes(rbpiPath))
    return 0

  if flags.verbose:
    stderr.writeLine("repro profile build: cache miss " &
      digest.digestHex & "; compiling " & profileRoot)

  # Cache miss → invoke Nim.
  let exeName = when defined(windows): "profile-build.exe" else: "profile-build"
  let outBinary = nimcacheDir / exeName
  var rbpiBytes: seq[byte]
  var jsonText: string
  try:
    let res = compileProfileBinary(profileRoot, nimcacheDir, outBinary,
      reprobuildRepoRoot(), flags.verbose)
    jsonText = res.jsonOutput
  except CompileFailure as err:
    stderr.writeLine("repro profile build: " & err.msg)
    if err.stderrText.len > 0:
      stderr.writeLine("---- nim diagnostics ----")
      stderr.write(err.stderrText)
      if not err.stderrText.endsWith("\n"):
        stderr.writeLine("")
      stderr.writeLine("---- end nim diagnostics ----")
    # Best-effort cleanup of any partial artifact.
    let tmpPath = rbpiPath & ".tmp"
    if fileExists(extendedPath(tmpPath)):
      try: removeFile(extendedPath(tmpPath)) except OSError: discard
    return 1

  try:
    rbpiBytes = rbpiBytesFromJson(jsonText)
  except CatchableError as err:
    stderr.writeLine("repro profile build: failed to encode RBPI " &
      "envelope from compiled profile output: " & err.msg)
    return 1

  # Validate the envelope before publishing it.
  try:
    discard readEnvelope(rbpiBytes)
  except CatchableError as err:
    stderr.writeLine("repro profile build: generated RBPI envelope is " &
      "structurally invalid: " & err.msg)
    return 1

  writeBytesAtomic(rbpiPath, rbpiBytes)
  writeFile(extendedPath(manifestPath), digest.manifest)

  case outKind.kind
  of osinkStdout:
    writeBytesToStdout(rbpiBytes)
  of osinkExplicit:
    copyFile(extendedPath(rbpiPath), extendedPath(outKind.path))
    stdout.writeLine(outKind.path)
  of osinkDefault:
    if isatty(stdout):
      stdout.writeLine(rbpiPath)
    else:
      writeBytesToStdout(rbpiBytes)

  0

# ---------------------------------------------------------------------------
# Top-level dispatcher.
# ---------------------------------------------------------------------------

proc runProfileCommand*(args: seq[string]): int =
  ## `repro profile <subcommand>`. v1 subcommands:
  ##   build [--profile <path>] [--no-cache] [--out <path>|-]
  if args.len == 0:
    stderr.writeLine("usage: repro profile {build} ...")
    return 2
  case args[0]
  of "build":
    let rest = if args.len > 1: args[1 .. ^1] else: @[]
    return runProfileBuild(rest)
  of "--help", "-h", "help":
    echo "usage: repro profile {build} ..."
    echo ""
    echo "subcommands:"
    echo "  build [--profile <path>] [--no-cache] [--out <path>|-]"
    echo "    Compile a home.nim / system.nim profile to the RBPI"
    echo "    binary envelope and cache the artifact by source digest."
    return 0
  else:
    stderr.writeLine("repro profile: unknown subcommand: " & args[0])
    stderr.writeLine("usage: repro profile {build} ...")
    return 2
