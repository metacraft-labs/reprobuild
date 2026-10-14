## Body of the internal `__repro-compile-profile` helper subcommand.
##
## This proc is invoked by the public `repro` CLI's main dispatcher
## when it sees the `__repro-compile-profile` argv. The
## `__repro-compile-profile` argv is NEVER user-facing; it is the
## subprocess shape that the profile-compile BuildAction expects.
##
## Argv shape:
##
##   repro __repro-compile-profile
##     --profile <profile-root.nim>
##     --rbpi <output-rbpi-path>
##     --nimcache <nimcache-dir>
##     --repo-root <reprobuild-repo-root>
##     [--verbose]
##
## All paths must be absolute. The helper exits 0 on success and 1
## on any failure; Nim diagnostics are forwarded to stderr inside a
## bordered banner.
##
## THE HELPER ALWAYS COMPILES AND ALWAYS RUNS. It has no freshness check of
## its own: when the engine spawns it, the action cache has already decided
## the previous result is not good enough, and a short-circuit in here would
## re-publish exactly the result the edge was re-run to replace (the provider
## compile's child carried such a copy of its parent's gate; see
## Compiles-Are-Normal-Edges). It also writes no depfile and no source
## manifest — the edge's dependency record is what io-mon observes this
## process and its children (`nim`, the C toolchain, the profile binary)
## read.

import std/[os, strutils]
from repro_core/paths import extendedPath

import repro_profile_intent

import ./compile
import ./platforms

proc valueAfterFlag(args: openArray[string]; flag: string): string =
  var i = 0
  while i < args.len:
    if args[i] == flag and i + 1 < args.len:
      return args[i + 1]
    inc i
  ""

proc hasFlag(args: openArray[string]; flag: string): bool =
  for a in args:
    if a == flag:
      return true
  false

proc runProfileCompileHelper*(args: openArray[string]): int =
  ## Implementation of `repro __repro-compile-profile`. See module docs.
  let profileRoot = valueAfterFlag(args, "--profile")
  let rbpiPath = valueAfterFlag(args, "--rbpi")
  let nimcacheDir = valueAfterFlag(args, "--nimcache")
  let repoRoot = valueAfterFlag(args, "--repo-root")
  let verbose = hasFlag(args, "--verbose")

  for (name, value) in [
    ("--profile", profileRoot),
    ("--rbpi", rbpiPath),
    ("--nimcache", nimcacheDir),
    ("--repo-root", repoRoot)
  ]:
    if value.len == 0:
      stderr.writeLine("repro __repro-compile-profile: missing " & name)
      return 2

  if not fileExists(extendedPath(profileRoot)):
    stderr.writeLine("repro __repro-compile-profile: profile root does " &
      "not exist: " & profileRoot)
    return 1

  let exeName =
    when defined(windows): "profile-build.exe"
    else: "profile-build"
  let outBinary = nimcacheDir / exeName

  var jsonText: string
  try:
    let res = compileProfileBinary(profileRoot, nimcacheDir, outBinary,
      repoRoot, verbose)
    jsonText = res.jsonOutput
    # Keep diagnostics visible even when the profile succeeds or its
    # stdout subsequently fails JSON/RBPI encoding. Never parse stderr.
    if res.stderrText.len > 0:
      stderr.write(res.stderrText)
      if not res.stderrText.endsWith("\n"):
        stderr.writeLine("")
  except CompileFailure as err:
    stderr.writeLine("repro __repro-compile-profile: " & err.msg)
    if err.stderrText.len > 0:
      stderr.writeLine("---- nim diagnostics ----")
      stderr.write(err.stderrText)
      if not err.stderrText.endsWith("\n"):
        stderr.writeLine("")
      stderr.writeLine("---- end nim diagnostics ----")
    let tmpPath = rbpiPath & ".tmp"
    if fileExists(extendedPath(tmpPath)):
      try: removeFile(extendedPath(tmpPath)) except OSError: discard
    return 1

  var rbpiBytes: seq[byte]
  try:
    rbpiBytes = rbpiBytesFromJson(jsonText)
  except CatchableError as err:
    stderr.writeLine("repro __repro-compile-profile: failed to encode " &
      "RBPI envelope from compiled profile output: " & err.msg)
    return 1

  try:
    discard readEnvelope(rbpiBytes)
  except CatchableError as err:
    stderr.writeLine("repro __repro-compile-profile: generated RBPI " &
      "envelope is structurally invalid: " & err.msg)
    return 1

  writeBytesAtomic(rbpiPath, rbpiBytes)
  return 0

proc runProfilePlatformProbeHelper*(args: openArray[string]): int =
  ## Implementation of `repro __repro-probe-profile-platforms`: evaluate the
  ## profile for every target platform (`runProfilePlatformProbes`) and write
  ## the outcomes to `--out`. The body of the platform-probe edge
  ## (`probeProfilePlatforms`), with the compile helper's contract: no
  ## freshness check of its own, no depfile -- io-mon observes what the
  ## checks read.
  ##
  ## Argv: `--profile <root.nim> --out <json> --nimcache <dir>
  ## --repo-root <dir>`. Exits 0 when the document was written (whatever
  ## each platform's outcome), 1 when the probe could not run at all, 2 on
  ## a usage error.
  let profileRoot = valueAfterFlag(args, "--profile")
  let outPath = valueAfterFlag(args, "--out")
  let nimcacheDir = valueAfterFlag(args, "--nimcache")
  let repoRoot = valueAfterFlag(args, "--repo-root")
  for (name, value) in [
    ("--profile", profileRoot),
    ("--out", outPath),
    ("--nimcache", nimcacheDir),
    ("--repo-root", repoRoot)
  ]:
    if value.len == 0:
      stderr.writeLine("repro __repro-probe-profile-platforms: missing " & name)
      return 2
  if not fileExists(extendedPath(profileRoot)):
    stderr.writeLine("repro __repro-probe-profile-platforms: profile root " &
      "does not exist: " & profileRoot)
    return 1
  var outcomes: seq[ProbeOutcome]
  try:
    outcomes = runProfilePlatformProbes(profileRoot, nimcacheDir, repoRoot)
  except CompileFailure as err:
    stderr.writeLine("repro __repro-probe-profile-platforms: " & err.msg)
    return 1
  let text = encodeProbeOutcomes(outcomes)
  var bytes = newSeq[byte](text.len)
  for i, ch in text:
    bytes[i] = byte(ord(ch))
  writeBytesAtomic(outPath, bytes)
  0
