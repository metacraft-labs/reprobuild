## Gate ``e2e_addon_fetch_substitutes_only_from_bootstrap_anchors``
## (milestone A8; spec §9.1; threat model G5, F1).
##
## A binary cache on the test network holds two entries for two build
## actions with the same outputs: one signed by the publisher key the host
## was bootstrapped to trust (``/etc/repro/caches.conf``), one signed by a
## key it was not. A manifest with only the anchored action applies, and
## its output is in the store. A manifest that adds the unanchored one
## fails: the fetch unit's substitution reads it as a miss, nothing of it is
## staged or reaches the store. No publisher key exists on the host, no
## unit carries the publish variables, and the cache receives no publish
## from it.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-substitutes-untrusted``):
## the fetch substitutes with trust enforcement off (the apply path before
## reprobuild 1c2752eef9) and the unanchored entry lands: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the real cache daemon and the real units.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip
import repro_profile
import repro_deploy_agent/manifest
import repro_peer_cache/auth as peerAuth

import ./addon_testbed
import ./agent_e2e_support
import ./cache_e2e_support

const Gate = "e2e_addon_fetch_substitutes_only_from_bootstrap_anchors"

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc action(id: string): ProfileBuildAction =
  ProfileBuildAction(id: id, argv: @["/bin/true"],
    cwd: "/repro/store/prefixes/" & id & "/1", outputs: @["bin"],
    commandStatsId: id, substituteOnly: true)

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let cache = g.startCache()
  defer: cache.stop()
  let anchored = peerAuth.generateKeypair()
  let stranger = peerAuth.generateKeypair()
  let tree = g.runDir / "tree"
  createDir(tree / "bin")
  writeFile(tree / "bin" / "a8-tool", "#!/bin/sh\necho a8\n")
  let a = action("a8-anchored")
  let u = action("a8-unanchored")
  let da = cache.publishTree(anchored, a, tree)
  let du = cache.publishTree(stranger, u, tree)
  let bs = g.bootstrapWithAgent(repro, step, cacheUrl = cache.guestUrl,
    cachePublishers = @[hexKey(anchored.publicKey)])
  producer = bs.producer
  if not bs.ok: return
  let published0 = cache.publishCount()
  let marker = canonicalFile("/etc/repro/a8-subst", "x\n")
  discard producer.publish(PublishSpec(sequence: 1, profileText: marker,
    buildActions: @[a],
    closureDigests: @[ClosureDigest(actionId: a.id, digest: da)]))
  let t1 = g.tickUnits()
  step("the anchored entry is substituted and applied", t1.outcome == "aoApplied",
       $t1 & "\n" & t1.fetchLog & t1.applyLog)
  step("its output is in the store", g.exec("cat " & a.cwd &
       "/bin/a8-tool").stdout == "#!/bin/sh\necho a8\n", "")
  var digests = @[ClosureDigest(actionId: a.id, digest: da),
                  ClosureDigest(actionId: u.id, digest: du)]
  sortClosureDigests(digests)
  discard producer.publish(PublishSpec(sequence: 2, profileText: marker,
    buildActions: @[a, u], closureDigests: digests))
  let t2 = g.tickUnits()
  record["unanchoredTick"] = %($t2)
  step("the entry signed outside the anchors is a miss; the apply fails",
       t2.outcome == "aoApplyFailed", $t2 & "\n" & t2.fetchLog)
  step("nothing of it reached the store", g.exec("test -e " & u.cwd).exitCode != 0, "")
  step("nothing of it was staged", g.exec("ls /var/lib/private/repro-agent-fetch/" &
       "staging/*/outputs/1/bin 2>/dev/null").stdout.strip() == "", "")
  let keys = g.exec("find /etc/repro /var/lib/repro /repro/store -maxdepth 4 " &
    "-name '*.key' ! -name recipient.key 2>/dev/null").stdout.strip()
  step("no publisher key exists on the host", keys == "", keys)
  let env = g.exec("systemctl show -p Environment repro-agent-fetch.service " &
    "repro-agent-apply.service").stdout
  step("no unit carries the publish variables",
       "REPRO_BINARY_CACHE_KEY_PATH" notin env and "REPRO_APPLY_PUBLISH" notin env, env)
  step("the cache received no publish from the host",
       cache.publishCount() == published0,
       $published0 & " -> " & $cache.publishCount())

suite Gate:
  test "the fetch unit substitutes only from the bootstrap anchors":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
