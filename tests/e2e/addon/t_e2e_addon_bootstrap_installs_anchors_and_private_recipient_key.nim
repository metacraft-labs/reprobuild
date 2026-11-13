## Gate ``e2e_addon_bootstrap_installs_anchors_and_private_recipient_key``.
##
## After bootstrap on each base:
##
## - the recipient key is a regular file owned by root with mode ``0400``
##   (and its public half is the one bootstrap printed);
## - the deploy-signer anchors hold exactly the keys given on the bootstrap
##   command line;
## - ``/etc/repro/caches.conf``, parsed by the binary-cache client's own
##   parser, lists exactly one cache -- the URL given -- trusting exactly
##   the publisher keys given;
## - no other key material exists under ``/etc/repro`` or
##   ``/var/lib/repro``: no file carries a private-key marker except the
##   recipient key, and no ``*.key`` / ``*.pem`` / certificate file but the
##   recipient pair exists. In particular no cache publisher key.
##
## Falsifying mutations: ``REPRO_ADDON_MUTATION=recipient-key-0644`` (the
## key written group- and world-readable) and
## ``REPRO_ADDON_MUTATION=provisions-publisher-key`` (bootstrap leaves a
## publisher keypair) must each turn the gate red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_addon_bootstrap_installs_anchors_and_private_recipient_key``).
##
## *Mocking.* None.

import std/[algorithm, json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/generation0
import repro_binary_cache_client/caches_config

import ./addon_testbed

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let anchors = g.installAnchors()
    let pre = g.exec(repro & " system addon preflight" & anchors.flags)
    step("preflight is compatible", pre.exitCode == 0, pre.stdout & pre.stderr)
    if pre.exitCode != 0: return fails
    let boot = g.exec(repro & " system addon bootstrap --plan " &
                      planDigestOf(pre.stdout) & anchors.flags)
    step("bootstrap", boot.exitCode == 0, boot.stdout & boot.stderr)
    if boot.exitCode != 0: return fails

    let st = g.run("stat -c '%u %g %a %F' /var/lib/repro/agent/recipient.key").strip()
    step("recipient key is root-owned, 0400, a regular file",
         st == "0 0 400 regular file", st)
    let printed = block:
      var v = ""
      for line in boot.stdout.splitLines():
        if line.startsWith("recipient public key:"):
          v = line["recipient public key:".len .. ^1].strip()
      v
    let pubFile = g.run("cat /var/lib/repro/agent/recipient.pub").strip()
    step("the printed recipient public key is the one on disk",
         printed.len == 130 and printed == pubFile, printed & " vs " & pubFile)

    var expectedSigners = anchors.deploySigners
    expectedSigners.sort()
    let signers = parseAnchorKeys(g.run("cat " & DeploySignersPath),
                                  DeploySignersPath)
    step("deploy-signer anchors are exactly the keys given",
         signers == expectedSigners, $signers & " vs " & $expectedSigners)

    let caches = parseCachesText(g.run("cat " & CachesConfPath), CachesConfPath)
    var cacheOk = caches.len == 1
    var detail = $caches.len & " cache(s)"
    if cacheOk:
      var keys: seq[string]
      for k in caches[0].trustedKeys: keys.add(hexKey(k))
      keys.sort()
      var expected = anchors.cachePublishers
      expected.sort()
      cacheOk = caches[0].url == TestCacheUrl and keys == expected
      detail = caches[0].url & " trusting " & $keys & " (expected " &
               TestCacheUrl & " trusting " & $expected & ")"
    step("caches.conf: one cache, trusting exactly the publisher anchors",
         cacheOk, detail)

    let marked = g.run("grep -rlI 'ecdsa-p256:' /etc/repro /var/lib/repro " &
                       "2>/dev/null | sort; true").strip()
    step("no private key but the recipient key",
         marked == "/var/lib/repro/agent/recipient.key", marked)
    let keyFiles = g.run("find /etc/repro /var/lib/repro -type f \\( " &
      "-name '*.key' -o -name '*.pem' -o -name '*cert*' -o -name '*.pub' \\) " &
      "| sort").strip()
    step("no key or certificate file but the recipient pair",
         keyFiles == "/var/lib/repro/agent/recipient.key\n" &
                     "/var/lib/repro/agent/recipient.pub", keyFiles)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite "e2e_addon_bootstrap_installs_anchors_and_private_recipient_key":
  test "anchors are exactly the given keys, and the only key is the recipient's, 0400":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_addon_bootstrap_installs_anchors_and_private_recipient_key)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{
          "gate": "e2e_addon_bootstrap_installs_anchors_and_private_recipient_key",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(
          "e2e_addon_bootstrap_installs_anchors_and_private_recipient_key", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
