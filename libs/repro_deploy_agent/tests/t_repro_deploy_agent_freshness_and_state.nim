## The deploy agent's freshness bounds and its durable state (ReproOS
## Add-On Mode A8 review, findings M2 and M4; Deploy-Agent.md §Outcomes).
##
##   * an ``issuedAt`` more than ``MaxIssuedAtFutureSkewSeconds`` ahead of
##     the host's clock is ``aoStale`` (``issued_in_future``), one within
##     the skew applies;
##   * an ``issuedAt`` older than the one last accepted is ``aoStale``
##     (``issued_at_regressed``), whatever the clock says;
##   * an empty sequence-floor file fails the tick closed instead of
##     reading as "nothing applied";
##   * the floor, quarantine and pause files are replaced whole (no
##     temporary left behind, content exact).
##
## Falsifying mutations (``-d:reproAddonMutation=``):
## ``agent-issued-at-future-trusted`` and ``agent-state-plain-write``.
##
## Mocks: the apply hook records instead of applying (what is under test
## is the agent's verdict); the clock is pinned through ``AgentDeps.nowUnix``.
## Everything else is the real codec, real signatures and real files.

import std/[os, strutils, times, unittest]

import repro_deploy_agent
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

let root = getTempDir() / ("agent-freshness-" & $getCurrentProcessId())
removeDir(root)
createDir(root)
let kp = peerAuth.generateKeypair()
let anchors = anchorsFromKeypairs([kp.publicKey])
const Now = 1_800_000_000'i64

proc publish(dir: string; sequence: uint64; issuedAt: int64): string =
  var m = DeployManifest(target: "h1", sequence: sequence,
    deploymentId: "d" & $sequence & "-" & $issuedAt, profileText: "",
    issuedAt: uint64(issuedAt), maxAgeSeconds: 3600)
  signManifest(kp, m)
  let bytes = encodeManifest(m)
  var s = newString(bytes.len)
  for i, b in bytes: s[i] = char(b)
  createDir(dir)
  result = dir / "m.rdm"
  writeFile(result, s)

proc tick(stateDir, src: string): AgentOutcome =
  let cfg = AgentConfig(target: "h1", sources: @[src], anchors: anchors,
    stateDir: stateDir, requireAttestations: true)
  var deps: AgentDeps
  deps.apply = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
    (true, "recorded")
  deps.nowUnix = proc(): int64 {.gcsafe.} = Now
  runAgentTick(cfg, deps)

suite "deploy agent: freshness bounds and durable state":
  test "an issuedAt beyond the future skew is stale; within it, fresh":
    let st = root / "s1"
    let o = tick(st, publish(root / "m1", 1, Now + 3600))
    check o.kind == aoStale
    check o.errorCode == "issued_in_future"
    let o2 = tick(st, publish(root / "m1b", 1,
                  Now + MaxIssuedAtFutureSkewSeconds - 10))
    check o2.kind == aoApplied

  test "an issuedAt older than the last accepted one is refused":
    let st = root / "s2"
    check tick(st, publish(root / "m2", 5, Now - 100)).kind == aoApplied
    let o = tick(st, publish(root / "m2b", 6, Now - 200))
    check o.kind == aoStale
    check o.errorCode == "issued_at_regressed"
    # The same sequence re-signed later is converged, and raises the mark.
    check tick(st, publish(root / "m2c", 5, Now - 50)).kind == aoConverged
    check tick(st, publish(root / "m2d", 6, Now - 80)).kind == aoStale

  test "an empty floor file fails closed":
    let st = root / "s3"
    createDir(st / "deploy-agent")
    writeFile(st / "deploy-agent" / "h1.seq", "")
    expect CatchableError:
      discard tick(st, publish(root / "m3", 1, Now))

  test "state files are replaced whole":
    let st = root / "s4"
    check tick(st, publish(root / "m4", 3, Now)).kind == aoApplied
    check readFile(st / "deploy-agent" / "h1.seq") == "3\n"
    for kind, p in walkDir(st / "deploy-agent"):
      check ".tmp-" notin p
    writePauseMarker(st, "g1", "op")
    check readPauseMarker(st).paused
    writeQuarantine(AgentConfig(target: "h1", stateDir: st), 4, "d4")
    check readQuarantine(AgentConfig(target: "h1", stateDir: st)).sequence == 4
    for kind, p in walkDir(st / "deploy-agent"):
      check ".tmp-" notin p

removeDir(root)
