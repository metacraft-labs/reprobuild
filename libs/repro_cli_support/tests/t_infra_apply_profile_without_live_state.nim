## `resolveSystemProfileText` must decide "did this profile compile?"
## from the compile, not from how much text it rendered.
##
## THE DEFECT.
##
## `resolveSystemProfileText` returned success on `outcome.text.len > 0`.
## `outcome.text` is `renderSystemProfileToText(sp)`, which emits one
## block per LIVE-STATE resource — so a profile whose `resources:` block
## declares only action edges (`inlineExecCall(...)`,
## `expandArchive.build(...)`) renders to the empty string even though it
## compiled cleanly. Every `repro infra plan` / `repro infra apply` /
## `repro system sync` against such a profile was refused with
##
##   repro infra apply: profile compilation failed for <path>
##     diagnostic:
##
## — a hard failure whose diagnostic block is EMPTY, because there was no
## error to quote. Two defects in one line: a valid profile refused, and
## the refusal naming no cause.
##
## The judgement this gate encodes: a profile that compiles cleanly and
## declares zero live-state resources SHOULD converge. It is a legitimate
## manifest shape — "this host declares no live state; its work is the
## build-action half" — and it is the same shape as a manifest with an
## empty `profileText`, which the apply path has always accepted by
## parsing "" as zero resources.
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED.
##
## Nothing is mocked. The test writes a real `system.nim`, spawns the
## real `build/bin/repro`, and lets it run the real profile-compile edge
## (a real `nim c` via the real `__repro-compile-profile` helper) and a
## real apply. `REPROBUILD_REPO_ROOT` is exported so the profile resolves
## `import repro_profile` — the same variable a deployed host sets.
##
## The profile declares no live-state resources ON PURPOSE, and not only
## because that is the shape under test: every system-resource kind is
## privileged, so a live-state create would route the apply's LIVE-STATE
## half through the elevation broker, and a test must not raise an
## elevation prompt on the machine running it. The action edge carries
## `requiresElevation = true` — what a deployed profile's edges carry,
## and also what keeps this hermetic: the engine hands an elevated edge
## to the apply's `brokerSpawn` closure instead of its monitored-spawn
## path, which would otherwise refuse with "automatic monitor dependency
## gathering requires an io-monitor driver". It mutates nothing outside
## its temp cwd.
##
## The third case is the guard against over-correcting: a profile that
## genuinely does not compile must still fail, and must still carry a
## non-empty diagnostic.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir

const ActionEdgeOnlyProfileTemplate = """
import repro_profile

profile "infraApplyActionEdgesOnly":
  resources:
    inlineExecCall(
      argv = @["/bin/sh", "-c", "@CMD@"],
      cwd = "@CWD@",
      outputs = @["@OUT@"],
      requiresElevation = true,
      address = "writeMarker",
      commandStatsId = "infra.apply.action.edges.only")
"""

proc reproBinary(): string =
  result = RepoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  doAssert fileExists(result),
    "repro binary not found at " & result & "; build with `just build` first"

proc actionEdgeOnlyProfile(cwd, outDir, outRel, payload: string): string =
  ## The shell command is kept free of double quotes so it survives
  ## verbatim into a Nim string literal in the generated profile.
  let cmd = "mkdir -p " & outDir & "; printf '%s' '" & payload &
    "' > '" & outRel & "'"
  ActionEdgeOnlyProfileTemplate.multiReplace(
    ("@CMD@", cmd), ("@CWD@", cwd), ("@OUT@", outRel))

proc readIfExists(path: string): string =
  ## Reading a missing file raises and takes the whole suite down with
  ## it, hiding every case after this one. The `fileExists` check next
  ## to each call site is the assertion; this keeps a failure reported
  ## rather than fatal.
  if fileExists(path): readFile(path) else: ""

type CliRun = object
  exitCode: int
  output: string   ## stdout + stderr, interleaved as an operator sees them

proc runRepro(cacheRoot: string; args: seq[string]): CliRun =
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

suite "repro infra: a profile with no live-state resources compiles":

  setup:
    let tmpRoot = createTempDir("infra-no-live-state-", "")
    let stateDir = tmpRoot / "state"
    let applyCwd = tmpRoot / "target"
    let profilePath = tmpRoot / "profile" / "system.nim"
    createDir(stateDir)
    createDir(applyCwd)
    createDir(profilePath.parentDir)

  teardown:
    try: removeDir(tmpRoot)
    except CatchableError: discard

  test "infra plan accepts a profile whose resources are all action edges":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      writeFile(profilePath,
        actionEdgeOnlyProfile(applyCwd, "bin", "bin/planned.txt", "planned"))
      let run = runRepro(tmpRoot,
        @["infra", "plan", "--profile", profilePath,
          "--state-dir", stateDir, "--host", "no-live-state-host"])
      # The pre-fix symptom, verbatim: a clean compile reported as a
      # compilation failure.
      check "profile compilation failed" notin run.output
      check run.exitCode == 0

  test "infra apply converges a profile whose resources are all action edges":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      const OutRel = "bin/applied.txt"
      const Payload = "action-edge-only-profile-converged"
      writeFile(profilePath,
        actionEdgeOnlyProfile(applyCwd, "bin", OutRel, Payload))
      let run = runRepro(tmpRoot,
        @["infra", "apply", "--profile", profilePath,
          "--state-dir", stateDir, "--host", "no-live-state-host",
          "--no-preview"])
      check "profile compilation failed" notin run.output
      check run.exitCode == 0
      # A generation was committed — the apply ran rather than bailing
      # out before it.
      check "  generation   : " in run.output
      # CONVERGENCE: the profile's action edge produced its output. This
      # is the load-bearing assertion — the build-action half is the
      # whole point of a profile that declares no live state.
      check fileExists(applyCwd / OutRel)
      check readIfExists(applyCwd / OutRel) == Payload

  test "a profile that genuinely fails to compile still fails, with a reason":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      # Guard against over-correcting: keying success on the compile
      # rather than on the rendered text must not turn a broken profile
      # into a converging one.
      writeFile(profilePath, """
import repro_profile

profile "infraApplyBrokenProfile":
  resources:
    thisTemplateDoesNotExist(nope = 1)
""")
      let run = runRepro(tmpRoot,
        @["infra", "apply", "--profile", profilePath,
          "--state-dir", stateDir, "--host", "no-live-state-host",
          "--no-preview"])
      check run.exitCode != 0
      check "profile compilation failed" in run.output
      # And the refusal must NAME a cause. An empty `diagnostic:` block
      # is what the old success test produced for every zero-resource
      # profile; nothing should ever print one.
      let marker = "diagnostic:"
      let idx = run.output.find(marker)
      check idx >= 0
      check run.output[idx + marker.len .. ^1].strip().len > 0
