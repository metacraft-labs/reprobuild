## M62 gate 3: integration_apply_lock_serializes.
##
## Per Reprobuild-Development.milestones.org:
##
##   "Two concurrent `repro home apply` invocations: the second fails
##    closed with `EApplyBusy` within the 30-second timeout."
##
## allowed_mocks: none. This gate spawns two real OS processes (the
## `harness_apply_lock_holder` binary built alongside this gate) and
## verifies one acquires the lock while the other times out with
## exit code 3 (the harness's mapping of `EApplyBusy`).

import std/[os, osproc, streams, strutils, unittest]

import repro_home_generations

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()
const FixtureDir = "build/test-tmp/m62-gate3"

proc resetDir(path: string) =
  if dirExists(path):
    removeDir(path)
  createDir(path)

proc harnessBinary(): string =
  let exeName =
    when defined(windows): "harness_apply_lock_holder.exe"
    else: "harness_apply_lock_holder"
  let candidate = ProjectRoot / "build" / "test-bin" / exeName
  doAssert fileExists(candidate),
    "harness binary not found at " & candidate &
    "; the gate's `just` recipe builds it"
  candidate

proc waitFor(p: Process; timeoutMs: int): int =
  ## Wait for `p` to exit up to `timeoutMs` milliseconds. Returns the
  ## exit code, or -1 if it has not exited yet.
  var elapsed = 0
  while elapsed < timeoutMs:
    if not p.running():
      return p.waitForExit()
    sleep(50)
    elapsed += 50
  -1

proc readAvailable(p: Process): string =
  ## Read whatever has accumulated on the process's stdout so far,
  ## without blocking past EOF. Used to detect the "lock held" marker
  ## emitted by the harness.
  let s = p.outputStream()
  result = ""
  while not s.atEnd():
    let line = s.readLine()
    if line.len == 0: break
    result.add(line)
    result.add('\n')
    if line.contains("HARNESS_LOCK_HELD") or
        line.contains("HARNESS_LOCK_BUSY"):
      break

# ---------------------------------------------------------------------------
# The gate.
# ---------------------------------------------------------------------------

suite "M62 gate 3: apply lock serializes concurrent processes":

  let stateDir = absolutePath(FixtureDir / "state")
  resetDir(FixtureDir)
  resetDir(stateDir)
  let harness = harnessBinary()

  test "second concurrent process fails closed with EApplyBusy":
    # First process: acquire and hold for 3 seconds, with a 1-second
    # acquire timeout. It should win uncontested.
    let pHolder = startProcess(harness,
      args = [stateDir, "3", "1"],
      options = {poUsePath, poStdErrToStdOut})
    # Wait for the holder to emit its "HARNESS_LOCK_HELD" marker so
    # we know it actually owns the lock before launching the
    # contender. Without this, the second process can win the race
    # and the test loses signal.
    let holderMarker = readAvailable(pHolder)
    check holderMarker.contains("HARNESS_LOCK_HELD")

    # Second process: acquire with a 1-second timeout against the
    # held lock. Should hit `EApplyBusy` and exit 3 within ~1.2 s.
    let pContender = startProcess(harness,
      args = [stateDir, "0", "1"],
      options = {poUsePath, poStdErrToStdOut})
    let contenderRc = waitFor(pContender, timeoutMs = 5_000)
    let contenderOut = readAvailable(pContender)
    check contenderRc == 3
    check contenderOut.contains("HARNESS_LOCK_BUSY")
    pContender.close()

    # Now wait for the holder to release and exit cleanly.
    let holderRc = waitFor(pHolder, timeoutMs = 10_000)
    check holderRc == 0
    pHolder.close()

  test "after release the lock is acquirable again":
    let p = startProcess(harness,
      args = [stateDir, "0", "1"],
      options = {poUsePath, poStdErrToStdOut})
    let rc = waitFor(p, timeoutMs = 5_000)
    p.close()
    check rc == 0
