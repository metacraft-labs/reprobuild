## Convention emit-time fingerprint cache (M18).
##
## Several Tier 2b conventions (Nim, Rust, Go, ...) eagerly run an
## ecosystem subprocess inside ``emitFragment`` to enumerate the build
## graph:
##
##   * Nim   : ``nim c --skipParentCfg --compileOnly`` to produce a
##              nimcache manifest listing every per-``.c`` compile.
##   * Rust  : ``cargo metadata --no-deps --offline`` to enumerate the
##              workspace's packages + bin/lib targets.
##   * Go    : ``go list -export -json -deps ./...`` to enumerate every
##              project + stdlib package.
##
## The original M3-M5 design (Option 1) ran the subprocess on every
## ``emitFragment`` invocation. M18 (per
## ``Standard-Provider-Implementation.milestones.org §M18``) makes the
## subprocess skip on repeat builds whose inputs are unchanged — a
## pragmatic fingerprint cache instead of a full dyndep migration. The
## engine's ``refreshProviderGraph`` already short-circuits the
## convention when the graph snapshot is current; this helper covers the
## remaining cases where ``emitFragment`` IS re-invoked (cold provider
## snapshot, snapshot store wiped, evaluation-input change that doesn't
## actually mutate the source set, etc.) so the subprocess fires at most
## once per input change.
##
## ## Cache contract
##
## Each convention computes a deterministic fingerprint over its
## ``inputs`` (typically: tool exe path + every source file's
## ``fileContentDigest`` + every manifest file's digest + any flag that
## changes the subprocess's behaviour). The fingerprint is written to a
## sidecar text file at ``<scratchDir>/<cacheBaseName>.repro-emit-fingerprint``
## right after a successful subprocess run.
##
## On subsequent ``emitFragment`` calls, the convention:
##   1. Computes the current fingerprint.
##   2. Reads the sidecar; if it matches the current fingerprint AND
##      every ``requiredOutput`` exists on disk, returns ``true``
##      ("cache hit — skip the subprocess").
##   3. Otherwise returns ``false`` ("must re-run the subprocess").
##
## After a successful subprocess run, the convention calls
## ``writeEmitCacheFingerprint`` to refresh the sidecar.
##
## **Why fingerprint sidecar instead of true dyndep?** The engine's
## current dyndep contract (``BuildAction.dynamicDepsFile``) only ADDS
## deps/outputs to actions that already exist in the static graph; it
## can't synthesise new per-``.c`` compile actions from a dyndep
## fragment. True Option 2 dyndep for Nim/Rust/Go would require
## extending the dyndep contract to also CREATE actions, which is a
## non-trivial engine refactor. The fingerprint sidecar delivers the
## headline M18 perf goal ("eager subprocess doesn't fire on every
## ``repro build``") without that refactor and lands in a single
## milestone budget. See the M18 milestone hand-off for the deferred
## work list.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime

const
  EmitCacheVersion* = "1"
    ## Bump this when the fingerprint layout changes in a way the cache
    ## can't reconcile (e.g., a new input class becomes load-bearing).
    ## Pre-existing sidecars with a different version are treated as
    ## misses and overwritten.

type
  EmitCacheInputKind* = enum
    eckText
      ## A literal string contribution. Use for flags, exe paths,
      ## version tokens.
    eckFile
      ## A filesystem path; its content digest is folded into the
      ## fingerprint. ``fileContentDigest`` returns ``"missing"`` when
      ## the path is absent, which is a valid cache key — the next
      ## build that finds the file present will mismatch and re-run.

  EmitCacheInput* = object
    kind*: EmitCacheInputKind
    value*: string

proc textInput*(text: string): EmitCacheInput =
  EmitCacheInput(kind: eckText, value: text)

proc fileInput*(path: string): EmitCacheInput =
  EmitCacheInput(kind: eckFile, value: path)

proc normalisedFilePath(path: string): string =
  ## Canonical key for an ``eckFile`` input. Lower-case + forward-slash
  ## on Windows so a fixture rebuilt with a different drive-letter
  ## casing still hits the same cache slot. POSIX keeps the path
  ## verbatim — case sensitivity matters there.
  when defined(windows):
    path.replace('\\', '/').toLowerAscii
  else:
    path

proc computeEmitCacheFingerprint*(inputs: openArray[EmitCacheInput]): string =
  ## Deterministic single-string fingerprint over the input set.
  ## ``eckFile`` entries are sorted by their normalised path so the
  ## emitter doesn't have to pre-sort the convention's source list.
  ## ``eckText`` entries are kept in declaration order — they're
  ## typically convention-controlled tokens (driver path, flag set)
  ## whose ordering is itself semantic.
  var textParts: seq[string] = @[]
  var fileEntries: seq[tuple[path: string; digest: string]] = @[]
  for input in inputs:
    case input.kind
    of eckText:
      textParts.add("text:" & input.value)
    of eckFile:
      let key = normalisedFilePath(input.value)
      fileEntries.add((path: key, digest: fileContentDigest(input.value)))
  fileEntries.sort(proc(a, b: tuple[path: string; digest: string]): int =
    cmp(a.path, b.path))
  var buf = "repro-emit-cache-v" & EmitCacheVersion & "\n"
  for part in textParts:
    buf.add(part)
    buf.add('\n')
  for entry in fileEntries:
    buf.add("file:" & entry.path & "\t" & entry.digest & "\n")
  buf

proc emitCacheFingerprintPath*(scratchDir, cacheBaseName: string): string =
  ## The on-disk sidecar path. The convention picks a scratch directory
  ## (typically the per-entry ``nimcacheDir`` or
  ## ``<scratch>/<projectEntry>``) plus a stable basename
  ## (``nim-c-compileonly``, ``cargo-metadata``, ``go-list-export``) so
  ## multiple cached subprocesses can coexist in the same scratch dir.
  scratchDir / (cacheBaseName & ".repro-emit-fingerprint")

proc readEmitCacheFingerprint*(scratchDir, cacheBaseName: string): string =
  ## Returns the cached fingerprint text or "" when the sidecar is
  ## missing/unreadable. Treating any read failure as a miss is
  ## conservative — the worst case is one extra subprocess run.
  let path = emitCacheFingerprintPath(scratchDir, cacheBaseName)
  if not fileExists(extendedPath(path)):
    return ""
  try:
    readFile(extendedPath(path))
  except CatchableError:
    ""

proc writeEmitCacheFingerprint*(scratchDir, cacheBaseName, fingerprint: string) =
  ## Persist the fingerprint sidecar. Creates ``scratchDir`` if needed.
  ## Any failure here is intentionally non-fatal at the caller — a
  ## missing sidecar just forces the next build to re-run the
  ## subprocess, which is correct (just not optimal).
  createDir(extendedPath(scratchDir))
  let path = emitCacheFingerprintPath(scratchDir, cacheBaseName)
  try:
    writeFile(extendedPath(path), fingerprint)
  except CatchableError:
    discard

proc emitCacheIsUsable*(scratchDir, cacheBaseName, currentFingerprint: string;
                       requiredOutputs: openArray[string]): bool =
  ## Atomic helper: true iff the on-disk fingerprint matches AND every
  ## required output exists. The convention's caller checks this BEFORE
  ## running its subprocess; on hit it can skip straight to parsing the
  ## cached manifest the previous run already produced.
  let cached = readEmitCacheFingerprint(scratchDir, cacheBaseName)
  if cached.len == 0 or cached != currentFingerprint:
    return false
  for output in requiredOutputs:
    if not fileExists(extendedPath(output)):
      return false
  true
