## Gate ``e2e_addon_egress_observer`` (milestone A11; owner decision
## 2026-11-04; threat model DET-AO-3, G40; spec §10.4).
##
## The add-on's own nftables table, from bootstrap to uninstall:
##
## 1. **Fail closed.** With the base's ``nft`` made unavailable, the
##    preflight of a host with the deploy agent and an Evidence sink is
##    incompatible, naming ``EAddOnEgressObserverUnavailable``; bootstrap has
##    nothing to fall back to.
## 2. **Bootstrap installs it, ledgered.** The table ``inet
##    repro_addon_egress`` exists, the ledger has its ``nftTable`` entry, and
##    the fingerprint diff (its ``nftables`` component included) equals the
##    ledger's delta, record by record. No other table changed.
## 3. **It counts.** A connect to a third address from inside the paused
##    fetch unit is refused by the unit's filter, counted by the table, and
##    recorded by the check (``addon-egress`` / ``egress-refused``), which
##    reaches the gate's sink.
## 4. **Uninstall removes it.** After uninstall the table is gone and the
##    fingerprint equals the pre-bootstrap one.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=egress-observer-not-installed``):
## the observer unit never loads the table: steps 2 and 3 go red.
##
## Seam build (the fetch unit's pause). Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support
import ./evidence_e2e_support

const Gate = "e2e_addon_egress_observer"

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  var sink = startGateSink(g)
  defer: sink.stop()
  g.provideSinkCa(sink)
  # 1. Fail closed without nft (the binary hidden for the preflight only).
  let anchors = g.installAnchors()
  var probe = g.startProducer(anchors.deploySignerKeys[0])
  let flags = agentFlags(anchors, probe) & sink.evidenceFlags
  let nft = g.exec("command -v nft || ls /usr/sbin/nft").stdout.strip()
  discard g.exec("mount --bind /dev/null " & nft)
  let refused = g.exec(repro & " system addon preflight" & flags)
  discard g.exec("umount " & nft)
  probe.stop()
  step("without nft the preflight is incompatible, naming the observer",
       refused.exitCode != 0 and "EAddOnEgressObserverUnavailable" in refused.stdout,
       refused.stdout & refused.stderr)
  # 2. Bootstrap installs the table, ledgered.
  let f0 = g.takeFingerprint(repro)
  let bs = g.bootstrapWithAgent(repro, step, extraFlags = sink.evidenceFlags)
  producer = bs.producer
  if not bs.ok: return
  let host = g.enrol(sink)
  let tables = g.exec("nft list tables").stdout
  record["tables"] = %tables
  step("the add-on's table is loaded", "table inet repro_addon_egress" in tables,
       tables)
  let l1 = g.ledgerOf()
  step("the ledger tracks the table", "nftTable" in l1 and
       "inet repro_addon_egress" in l1, "")
  # bootstrapWithAgent stopped the fetch timer (the gates drive ticks);
  # generation 0 left it active, which is what its ledger records.
  discard g.exec("systemctl start repro-agent-fetch.timer")
  let f1 = g.takeFingerprint(repro)
  discard g.exec("systemctl stop repro-agent-fetch.timer")
  let d = deltaReport(f0, f1, "", l1)
  step("bootstrap's fingerprint diff (nftables included) == the ledger's delta",
       d.ok, d.text)
  # 3. It counts a forbidden connect from the fetch unit.
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: canonicalFile("/etc/repro/a11-egress", "x\n")))
  let since = sink.headSeq()
  let fc = g.forbiddenConnectFromFetch()
  step("the fetch unit's connect to a third address is refused",
       fc.paused and fc.connect != 0, $fc)
  let counted = g.exec("nft list set inet repro_addon_egress refused4").stdout
  record["refused4"] = %counted
  step("the table counted the refused destination", "1.1.1.1" in counted, counted)
  discard g.exec("systemctl start repro-addon-evidence.service")
  step("the DET-AO-3 record reached the sink",
       sink.waitFor(host, "addon-egress", "egress-refused", 180, since = since),
       g.exec("journalctl -q -o cat -u repro-addon-egress-check.service | tail -20").stdout)
  # 4. Uninstall removes it.
  let un = g.exec(repro & " system addon uninstall", timeoutSec = 1800)
  step("uninstall succeeds", un.exitCode == 0, un.stdout & un.stderr)
  let after = g.exec("nft list tables").stdout
  step("the table is gone", "repro_addon_egress" notin after, after)
  # The one enumerated exception (spec §6.4): the kernel's packet-logger
  # bindings the table's log statement loaded stay after the table is gone.
  let id = identityReport(f0, g.takeFingerprint(repro),
                          ["sysctl:net.netfilter.nf_log.*"])
  step("the fingerprint equals the pre-bootstrap one (but the logger " &
       "bindings)", id.ok, id.text)

suite Gate:
  test "the egress observer: fail closed, ledgered, counting, uninstalled":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
