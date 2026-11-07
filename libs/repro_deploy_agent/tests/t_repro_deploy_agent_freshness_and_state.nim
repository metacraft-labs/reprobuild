## The deploy agent's freshness bounds and its durable state (ReproOS
## Add-On Mode A8 review, findings M2 and M4; Deploy-Agent.md §Outcomes).
##
##   * an ``issuedAt`` more than ``MaxIssuedAtFutureSkewSeconds`` ahead of
##     the host's clock is ``aoStale`` (``issued_in_future``), one within
##     the skew applies;
##   * an ``issuedAt`` older than the one last accepted is ``aoStale``
##     (``issued_at_regressed``), whatever the clock says;
##   * several sources serving the same sequence and deployment signed at
##     different times select the latest signature, whatever the order the
##     sources are listed in (A8 review 2026-11-01, finding 2);
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

proc publish(dir: string; sequence: uint64; issuedAt: int64;
             deploymentId = ""): string =
  var m = DeployManifest(target: "h1", sequence: sequence,
    deploymentId: (if deploymentId.len > 0: deploymentId
                   else: "d" & $sequence & "-" & $issuedAt), profileText: "",
    issuedAt: uint64(issuedAt), maxAgeSeconds: 3600)
  signManifest(kp, m)
  let bytes = encodeManifest(m)
  var s = newString(bytes.len)
  for i, b in bytes: s[i] = char(b)
  createDir(dir)
  result = dir / "m.rdm"
  writeFile(result, s)

proc tick(stateDir: string; srcs: varargs[string]): AgentOutcome =
  let cfg = AgentConfig(target: "h1", sources: @srcs, anchors: anchors,
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

  test "copies of one deployment from several sources: the latest signature wins in either order":
    # The host last accepted sequence 5 signed at Now-80. One source still
    # serves a copy signed at Now-100 (a mirror that froze before the
    # re-signing), another the copy signed at Now-50. Both are the same
    # sequence and deployment, so neither is ambiguous; the verdict must
    # not depend on which source the configuration happens to list first.
    let older = publish(root / "m5a", 5, Now - 100, "d5")
    let newer = publish(root / "m5b", 5, Now - 50, "d5")
    for order in [@[older, newer], @[newer, older]]:
      let st = root / ("s5-" & $(order[0] == older))
      check tick(st, publish(root / "m5c", 5, Now - 80, "d5")).kind == aoApplied
      let o = tick(st, order)
      check o.kind == aoConverged
      check o.errorCode == ""

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
