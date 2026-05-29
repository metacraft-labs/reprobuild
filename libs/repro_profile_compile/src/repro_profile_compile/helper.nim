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
##     --manifest <output-source-manifest-path>
##     --nimcache <nimcache-dir>
##     --repo-root <reprobuild-repo-root>
##     [--verbose]
##
## All paths must be absolute. The helper exits 0 on success and 1
## on any failure; Nim diagnostics are forwarded to stderr inside a
## bordered banner.

import std/[os, strutils]
from repro_core/paths import extendedPath

import repro_profile_intent

import ./sources
import ./compile

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
  let manifestPath = valueAfterFlag(args, "--manifest")
  let nimcacheDir = valueAfterFlag(args, "--nimcache")
  let repoRoot = valueAfterFlag(args, "--repo-root")
  let verbose = hasFlag(args, "--verbose")

  for (name, value) in [
    ("--profile", profileRoot),
    ("--rbpi", rbpiPath),
    ("--manifest", manifestPath),
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

  let sources = discoverProfileSources(profileRoot)
  let anchorDir = profileRoot.parentDir
  let digest = computeProfileDigest(sources, anchorDir)

  let exeName =
    when defined(windows): "profile-build.exe"
    else: "profile-build"
  let outBinary = nimcacheDir / exeName

  var jsonText: string
  try:
    let res = compileProfileBinary(profileRoot, nimcacheDir, outBinary,
      repoRoot, verbose)
    jsonText = res.jsonOutput
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
  writeFile(extendedPath(manifestPath), digest.manifest)
  return 0
