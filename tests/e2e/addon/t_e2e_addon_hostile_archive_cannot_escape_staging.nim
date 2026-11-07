## Gate ``e2e_addon_hostile_archive_cannot_escape_staging`` (milestone A8;
## threat model G30, F4).
##
## A cache entry signed by a bootstrap anchor -- and pinned by the signed
## manifest, so it passes every digest check and reaches the extractor --
## holds a link ``bin -> /var/lib/private/repro-agent-fetch`` (a directory
## the fetch unit may write, outside its staging area) and then
## ``bin/x-a8-escaped``. The fetch unit's extraction refuses it; nothing
## appears outside staging, nothing reaches the store, and the apply
## fails.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-extract-follows-links``):
## the extractor's symlink refusal (``refuseWriteThroughSymlink``) is
## neutered and ``x-a8-escaped`` is written outside staging: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the archive bytes are hand-built because no
## well-formed tree can hold them; they travel the real publish and
## substitute paths.

import std/[json, strutils, unittest]

import repro_test_support/reasoned_skip
import repro_profile
import repro_deploy_agent/manifest
import repro_peer_cache/auth as peerAuth

import ./addon_testbed
import ./agent_e2e_support
import ./cache_e2e_support

const
  Gate = "e2e_addon_hostile_archive_cannot_escape_staging"
  Outside = "/var/lib/private/repro-agent-fetch"

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let cache = g.startCache()
  defer: cache.stop()
  let anchored = peerAuth.generateKeypair()
  let a = ProfileBuildAction(id: "a8-hostile", argv: @["/bin/true"],
    cwd: "/repro/store/prefixes/a8-hostile/1", outputs: @["bin"],
    commandStatsId: "a8-hostile", substituteOnly: true)
  let archive = rbcarcV2(@[
    (path: "bin", kind: 2, mode: 0o777, data: Outside),
    (path: "bin/x-a8-escaped", kind: 0, mode: 0o644, data: "escaped\n")])
  let digest = cache.publishRawArchive(anchored, a, archive)
  let bs = g.bootstrapWithAgent(repro, step, cacheUrl = cache.guestUrl,
    cachePublishers = @[hexKey(anchored.publicKey)])
  producer = bs.producer
  if not bs.ok: return
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: canonicalFile("/etc/repro/a8-hostile", "x\n"),
    buildActions: @[a],
    closureDigests: @[ClosureDigest(actionId: a.id, digest: digest)]))
  let t = g.tickUnits()
  record["tick"] = %($t)
  step("the apply fails (the entry was not staged)", t.outcome == "aoApplyFailed",
       $t & "\n" & t.fetchLog)
  let escaped = g.exec("find / -xdev -name x-a8-escaped 2>/dev/null").stdout.strip()
  record["escaped"] = %escaped
  step("nothing appears outside staging", escaped == "", escaped)
  step("nothing reached the store", g.exec("test -e " & a.cwd).exitCode != 0, "")

suite Gate:
  test "a hostile archive cannot escape the fetch unit's staging area":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
