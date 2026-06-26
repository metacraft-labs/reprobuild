## Direct Nim-invocation + JSON->RBPI bridge for the M83 profile-compile
## path.
##
## This module is the "interior" of the compile step — the bit that
## actually runs `nim c` against the user's profile source and converts
## the emitted JSON `ProfileIntent` into the RBPI binary envelope. It is
## invoked directly by tests and by the internal
## `__repro-compile-profile` helper subcommand; the BuildAction-based
## edge in `edge.nim` wraps it so the build engine can cache the result.
##
## DEVIATION from a literal "binary emit" pipeline: the Phase A
## `repro_profile` library emits JSON on stdout. We deliberately do NOT
## change that surface (it would risk regressing every Phase A gate);
## instead we capture the JSON, parse it via `parseProfileIntentJson`,
## and re-encode through `encodeRbpi` (Phase B). The JSON ->
## ProfileIntent -> RBPI round-trip is lossless by construction.

import std/[os, osproc, strutils]
from repro_core/paths import extendedPath

import repro_profile
import repro_profile_intent

import ./sources

# ---------------------------------------------------------------------------
# Errors.
# ---------------------------------------------------------------------------

type
  CompileFailure* = object of CatchableError
    stderrText*: string

proc requireNimOnPath*(): string =
  ## Locate the `nim` binary. Fails closed with a diagnostic pointing at
  ## the vendored-Nim follow-up phase if Nim is absent.
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    raise newException(CompileFailure,
      "repro profile compile: `nim` not found on PATH. The current " &
      "release requires Nim from PATH; vendored-Nim auto-bootstrap is " &
      "deferred to a later phase. Install Nim >= 2.0 " &
      "(https://nim-lang.org/install.html) and retry.")
  nimExe

# ---------------------------------------------------------------------------
# Direct Nim invocation (two-phase: `nim c` then run the binary).
# ---------------------------------------------------------------------------

proc compileProfileBinary*(profileRoot, nimcacheDir, outBinary: string;
                           repoRoot: string;
                           verbose: bool = false): tuple[
    jsonOutput: string; stderrText: string] =
  ## Two-phase invocation: `nim c` (no `-r`) emits the binary, then we
  ## run it directly via `execCmdEx`. The split keeps Nim's diagnostic
  ## chatter on stderr and the profile binary's stdout JSON on stdout.
  ## Raises `CompileFailure` if either step exits non-zero.
  let nimExe = requireNimOnPath()
  createDir(extendedPath(nimcacheDir))
  createDir(extendedPath(outBinary.parentDir))

  # Stage a wrapper config.nims next to the profile so nim's parent-walk
  # picks it up and pulls in reprobuild's config.nims (which resolves
  # sibling-repo paths from env vars: NIMCRYPTO_SRC, BEARSSL_SRC, IO_MON_SRC,
  # etc.). Without this, a profile at e.g. C:\Users\admin\reprobuild-source\
  # never sees reprobuild's config.nims, and transitive imports of
  # repro_project_dsl -> nimcrypto/sha2 fail with "cannot open file".
  let profileDir = profileRoot.parentDir
  let stagedConfig = profileDir / "config.nims"
  let upstreamConfig = repoRoot / "config.nims"
  var didStageConfig = false
  if fileExists(extendedPath(upstreamConfig)) and
     not fileExists(extendedPath(stagedConfig)):
    writeFile(extendedPath(stagedConfig),
      "include \"" & upstreamConfig.replace('\\', '/') & "\"\n")
    didStageConfig = true

  var compileCmd = quoteShell(nimExe) & " c --hints:off --warnings:off" &
    " --nimcache:" & quoteShell(nimcacheDir) &
    " --out:" & quoteShell(outBinary)
  for path in profileNimPaths(repoRoot):
    compileCmd.add " --path:" & quoteShell(path)
  compileCmd.add " " & quoteShell(profileRoot)
  if verbose:
    stderr.writeLine("repro profile compile: " & compileCmd)

  try:
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
  finally:
    if didStageConfig:
      try: removeFile(extendedPath(stagedConfig))
      except OSError: discard

proc rbpiBytesFromJson*(jsonText: string): seq[byte] =
  ## Parse the JSON ProfileIntent emitted by the compiled profile and
  ## re-encode it through the Phase B RBPI envelope. The JSON ->
  ## ProfileIntent -> RBPI round-trip is lossless.
  let trimmed = jsonText.strip()
  let p = parseProfileIntentJson(trimmed)
  encodeRbpi(p)

# ---------------------------------------------------------------------------
# Atomic envelope publishing.
# ---------------------------------------------------------------------------

proc writeBytesAtomic*(path: string; bytes: seq[byte]) =
  ## Write `bytes` to `path` via a `<path>.tmp` rename. The parent
  ## directory is created lazily.
  let tmpPath = path & ".tmp"
  createDir(extendedPath(path.parentDir))
  let f = open(extendedPath(tmpPath), fmWrite)
  if bytes.len > 0:
    discard f.writeBuffer(unsafeAddr bytes[0], bytes.len)
  f.close()
  if fileExists(extendedPath(path)):
    removeFile(extendedPath(path))
  moveFile(extendedPath(tmpPath), extendedPath(path))

proc readBytes*(path: string): seq[byte] =
  let s = readFile(extendedPath(path))
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ord(ch))

proc cachedArtifactIsValid*(path: string): bool =
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
