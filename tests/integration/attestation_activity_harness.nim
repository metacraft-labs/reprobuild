## Shared harness for the gates that drive `repro infra plan` against a
## profile which enables the `attestation` activity.
##
## ## Why the gates go through the real CLI
##
## The property under test is "this configuration does not survive to a
## plan". That is a statement about a pipeline, not about a proc: the
## profile is compiled by a real `nim c` the engine drives, run as a real
## process, and only then does its output reach the planner. A test that
## called the validator directly would prove the validator raises — which
## is worth proving and is proved separately, in-process — but it would
## say nothing about whether the raise is caught, swallowed, or reached at
## all when the profile is evaluated the way a deployment evaluates it.
##
## So these gates spawn `build/bin/repro` and read its exit code and its
## output, the two things an operator and a script see.
##
## ## What the profile is shaped like, and why
##
## It declares one ACTION EDGE and no live-state resources. Every
## system-resource kind is privileged, so declaring one would route an
## apply through the elevation broker; the same shape is used by
## `libs/repro_cli_support/tests/t_infra_apply_profile_without_live_state
## .nim` and for the same reason. These gates only ever `plan`, which is
## read-only and non-elevated, but the shape keeps them from ever being a
## prompt on the machine running them.
##
## The profile also WRITES THE ACTIVITY OUT to a file while it is being
## evaluated. That is the difference between "nothing raised" and "the
## activity was built": a positive case that only checked the exit code
## would pass against a module whose `attestationActivity` returned an
## empty spec, or against a profile that never called it.
##
## ## Mocking
##
## None. Real CLI, real compile, real planner.

import std/[os, osproc, streams, strtabs, strutils]

const RepoRoot* = currentSourcePath.parentDir.parentDir.parentDir

const ProfileTemplate = """
import repro_profile
import repro_dsl_stdlib/packages/system/attestation

let attestationSpec = attestationActivity(
  attestationConfig("@LAYOUT@", tier = @TIER@))
writeFile("@ACTIVITY_OUT@", emitSystemActivityJson(attestationSpec))

profile "@NAME@":
  resources:
    inlineExecCall(
      argv = @["/bin/sh", "-c", "true"],
      cwd = "@CWD@",
      outputs = @["@OUT@"],
      requiresElevation = true,
      address = "attestationActivityProbe",
      commandStatsId = "attestation.activity.probe")
"""

proc reproBinary*(): string =
  result = RepoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  doAssert fileExists(result),
    "repro binary not found at " & result & "; build with `just build` first"

proc attestationProfileSource*(name, layout, tier, cwd, activityOut: string):
    string =
  ## The profile text for one (layout, tier) pairing.
  ##
  ## `tier` is spliced as a Nim EXPRESSION (`atMock` / `atTpm` / `atCvm`),
  ## not as a string, so a tier name that does not exist is a compile
  ## error in the profile rather than a silent fallback — the same
  ## reason the tier is an enum in the first place.
  ProfileTemplate.multiReplace(
    ("@NAME@", name),
    ("@LAYOUT@", layout),
    ("@TIER@", tier),
    ("@CWD@", cwd),
    ("@OUT@", "probe.marker"),
    ("@ACTIVITY_OUT@", activityOut))

type CliRun* = object
  exitCode*: int
  output*: string   ## stdout + stderr, interleaved as an operator sees them

proc runRepro*(cacheRoot: string; args: seq[string]): CliRun =
  var childEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    childEnv[k] = v
  childEnv["REPROBUILD_REPO_ROOT"] = RepoRoot
  childEnv["REPROBUILD_ACTION_CACHE_ROOT"] = cacheRoot / "action-cache"
  var p = startProcess(reproBinary(), args = args, env = childEnv,
                       options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.exitCode = p.waitForExit()
  p.close()

proc planFor*(tmpRoot, name, layout, tier: string):
    tuple[run: CliRun; activityJson: string] =
  ## Write a profile for one pairing, plan it, and report both what the
  ## CLI said and what the profile managed to emit before it was stopped
  ## (the empty string when it never got that far).
  let profilePath = tmpRoot / name / "system.nim"
  let stateDir = tmpRoot / name / "state"
  let workDir = tmpRoot / name / "work"
  let activityOut = tmpRoot / name / "activity.json"
  createDir(profilePath.parentDir)
  createDir(stateDir)
  createDir(workDir)
  writeFile(profilePath,
    attestationProfileSource(name, layout, tier, workDir, activityOut))
  result.run = runRepro(tmpRoot,
    @["infra", "plan", "--profile", profilePath,
      "--state-dir", stateDir, "--host", "attestation-activity-host"])
  result.activityJson =
    if fileExists(activityOut): readFile(activityOut) else: ""

proc diagnosticBody*(output: string): string =
  ## Everything the CLI printed after its `diagnostic:` marker. Empty
  ## when there was no such block — which is itself a failure worth
  ## distinguishing from a block whose contents are wrong.
  const Marker = "diagnostic:"
  let idx = output.find(Marker)
  if idx < 0: "" else: output[idx + Marker.len .. ^1].strip()
