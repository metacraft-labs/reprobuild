## A deploy-agent tick whose action hangs ENDS, fails, and leaves the
## manifest to be retried by the next tick.
##
## win-ci-bare-001, 2026-11-15: one elevated action stopped making progress
## and `repro deploy-agent` waited on it with no deadline. The tick never
## ended, so Task Scheduler (MultipleInstances = IgnoreNew) refused every later
## run with 0x800710E0, and the runner the deploy had drained stayed stopped
## for ~21 h.
##
## This runs the production apply hook (`mkRunInfraApplyHook`, the real
## `runInfraApply` path and the real dispatcher) against a signed manifest
## whose one action starts a grandchild and waits on it forever. The deadline
## comes from `REPRO_APPLY_ACTION_TIMEOUT_SECONDS`, the path a manifest's own
## pre-compiled actions take (the manifest encoding carries no per-edge
## deadline). Required:
##
##   * the tick returns, `aoApplyFailed`, exit code 1 (retryable), within a
##     bound set by the deadline rather than by the action;
##   * the action's whole process tree is gone, grandchild included;
##   * the failed sequence is NOT recorded as applied, and the next tick runs
##     the action again rather than reporting the manifest converged.

import std/[os, strutils, tempfiles, times, unittest]

import repro_deploy_agent
import repro_deploy_agent/apply_hook
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import repro_profile
import repro_test_support/reasoned_skip

when defined(posix):
  import std/posix

const Target = "hang-target"

proc writeManifestFile(path: string; m: DeployManifest) =
  let bytes = encodeManifest(m)
  var s = newString(bytes.len)
  for i, b in bytes:
    s[i] = char(b)
  createDir(parentDir(path))
  writeFile(path, s)

proc processAlive(pid: int): bool =
  when defined(posix):
    if kill(Pid(pid), 0) != 0:
      return false
    when defined(linux):
      try:
        let stat = readFile("/proc/" & $pid & "/stat")
        let close = stat.rfind(')')
        if close >= 0 and close + 2 < stat.len and stat[close + 2] == 'Z':
          return false
      except CatchableError:
        return false
    true
  else:
    false

proc waitUntilDead(pid: int; seconds: float): bool =
  let until = epochTime() + seconds
  while epochTime() < until:
    if not processAlive(pid):
      return true
    sleep(50)
  not processAlive(pid)

suite "a deploy-agent tick ends when one of its actions hangs":

  test "the hung action is killed with its tree, the tick fails, and the next tick retries":
    when not (defined(linux) or defined(macosx)):
      skip("the hung action is a /bin/sh child and its tree a POSIX process group")
    else:
      let saved = getEnv("REPRO_APPLY_ACTION_TIMEOUT_SECONDS")
      let hadSaved = existsEnv("REPRO_APPLY_ACTION_TIMEOUT_SECONDS")
      defer:
        if hadSaved: putEnv("REPRO_APPLY_ACTION_TIMEOUT_SECONDS", saved)
        else: delEnv("REPRO_APPLY_ACTION_TIMEOUT_SECONDS")
      putEnv("REPRO_APPLY_ACTION_TIMEOUT_SECONDS", "2")
      putEnv("REPRO_CACHE_DISABLE", "1")

      let tmpRoot = createTempDir("deploy-agent-hang-", "")
      defer:
        try: removeDir(tmpRoot) except CatchableError: discard
      let signer = peerAuth.generateKeypair()
      let agentStateDir = tmpRoot / "agent-state"
      let applyStateDir = tmpRoot / "apply-state"
      let cacheRoot = tmpRoot / "apply-cache"
      let work = tmpRoot / "work"
      for d in [agentStateDir, applyStateDir, cacheRoot, work]:
        createDir(d)
      let runsFile = work / "runs.log"
      let pidFile = work / "grandchild.pid"

      let cfg = AgentConfig(
        target: Target,
        sources: @[tmpRoot / "manifests" / "latest.rdm"],
        anchors: anchorsFromKeypairs(@[signer.publicKey]),
        stateDir: agentStateDir,
        fetchTimeoutMs: 5000)
      let deps = AgentDeps(
        apply: mkRunInfraApplyHook(applyStateDir, cacheRoot,
          hostIdentity = "hang-test-host", reproExe = "/usr/bin/false"))

      # Records each run, starts a grandchild, and waits on it: the seed
      # wrapper waiting on setup.ps1. `cacheable = false`, like the seed, so
      # every apply runs it.
      var m = DeployManifest(
        target: Target,
        sequence: 5'u64,
        deploymentId: "hang-5",
        profileText: "",
        buildActions: @[ProfileBuildAction(
          id: "hangs-forever",
          argv: @["/bin/sh", "-c",
            "echo run >> '" & runsFile & "'; sleep 600 & " &
            "echo $! > '" & pidFile & "'; wait"],
          cwd: work,
          outputs: @["never-written.txt"],
          commandStatsId: "deploy.hang",
          requiresElevation: true,
          cacheable: false)])
      signManifest(signer, m)
      writeManifestFile(cfg.sources[0], m)

      # ---- tick 1: ends, fails, kills the tree --------------------------
      let t0 = epochTime()
      let r1 = runAgentTick(cfg, deps)
      let elapsed = epochTime() - t0
      check r1.kind == aoApplyFailed
      check deployAgentExitCode(r1.kind) == 1
      check elapsed < 60.0
      # The tick's message summarises the apply; the edge's own diagnostic is
      # in the generation's apply log, which is what an operator reads.
      check "apply reported 1 errors" in r1.message
      var logged = false
      for f in walkDirRec(applyStateDir):
        if f.endsWith("apply.log") and "deadline of 2 s" in readFile(f):
          logged = true
      check logged
      check readLastAppliedSequence(cfg) == 0'u64
      check fileExists(pidFile)
      let grandchild1 = parseInt(readFile(pidFile).strip())
      check waitUntilDead(grandchild1, 10.0)
      check readFile(runsFile).strip().splitLines().len == 1

      # ---- tick 2: the same manifest is retried, not reported converged --
      let r2 = runAgentTick(cfg, deps)
      check r2.kind == aoApplyFailed
      check r2.sequence == 5'u64
      check readFile(runsFile).strip().splitLines().len == 2
      let grandchild2 = parseInt(readFile(pidFile).strip())
      check grandchild2 != grandchild1
      check waitUntilDead(grandchild2, 10.0)
