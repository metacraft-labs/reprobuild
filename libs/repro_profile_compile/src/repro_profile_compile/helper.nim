## Body of the internal `__repro-compile-profile` helper subcommand.
##
## This proc is invoked by the public `repro` CLI's main dispatcher
## when it sees the `__repro-compile-profile` argv. The
## `__repro-compile-profile` argv is NEVER user-facing; it is the
## subprocess shape that the profile COMPILE edge
## (`__repro_profile_compile`, `edge.nim`) expects.
##
## Argv shape:
##
##   repro __repro-compile-profile
##     --profile <profile-root.nim>
##     --binary <output-profile-binary>
##     --nimcache <nimcache-dir>
##     --repo-root <reprobuild-repo-root>
##     [--verbose]
##
## All paths must be absolute. The helper exits 0 on success, 1 on a
## compile failure and 2 on a usage error; Nim's diagnostics are forwarded
## to stderr (inside a bordered banner on failure).
##
## THE HELPER ONLY COMPILES. It links the profile binary and stops. It does
## not run it: the run is a separate, UNBLESSED edge (`__repro_profile_run`)
## that launches the binary directly, while this helper's edge carries the
## provider compile's entropy blessing. That blessing is sound only because
## nothing in this process tree runs what it produced -- running the binary
## here would put the profile's own behaviour under it
## (reprobuild-pm `spec/Profile-Compilation-Model.md` §2.1).
##
## IT ALSO ALWAYS COMPILES. It has no freshness check of its own: when the
## engine spawns it, the action cache has already decided the previous result
## is not good enough, and a short-circuit in here would re-publish exactly
## the result the edge was re-run to replace (the provider compile's child
## carried such a copy of its parent's gate; see Compiles-Are-Normal-Edges).
## It writes no depfile and no source manifest -- the edge's dependency
## record is what io-mon observes this process and its children (`nim`, the
## C toolchain) read.

import std/[os, strutils]
from repro_core/paths import extendedPath

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
  let binaryPath = valueAfterFlag(args, "--binary")
  let nimcacheDir = valueAfterFlag(args, "--nimcache")
  let repoRoot = valueAfterFlag(args, "--repo-root")
  let verbose = hasFlag(args, "--verbose")

  for (name, value) in [
    ("--profile", profileRoot),
    ("--binary", binaryPath),
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

  try:
    let transcript = compileProfileExecutable(profileRoot, nimcacheDir,
      binaryPath, repoRoot, verbose)
    # Keep Nim's diagnostics visible when the compile succeeds too (the
    # engine captures them with the action result).
    if transcript.len > 0:
      stderr.write(transcript)
      if not transcript.endsWith('\n'):
        stderr.writeLine("")
  except CompileFailure as err:
    stderr.writeLine("repro __repro-compile-profile: " & err.msg)
    if err.stderrText.len > 0:
      stderr.writeLine("---- nim diagnostics ----")
      stderr.write(err.stderrText)
      if not err.stderrText.endsWith('\n'):
        stderr.writeLine("")
      stderr.writeLine("---- end nim diagnostics ----")
    return 1
  if not fileExists(extendedPath(binaryPath)):
    # `nim c` exited 0 without linking the declared output: refuse here so
    # the edge fails naming the cause, instead of the run edge failing to
    # launch a binary that is not there.
    stderr.writeLine("repro __repro-compile-profile: nim exited 0 but " &
      "wrote no binary at " & binaryPath)
    return 1
  0

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
