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
## 3c. **The re-assert sees the host's table** (A11 audit session 2, G4).
##    A reboot of the healthy host: the re-assert reports ``ok``, with no
##    finding about the table. Then the table is deleted and the re-assert
##    run again: it reports the table ``missing`` (drift), not
##    ``unreadable``. The observer unit then loads it again.
## 3d. **A re-pin reloads the table** (A11 review round 2). The cache
##    origin is a name in the base's ``/etc/hosts``; it moves to another
##    address and ``agent-repin`` applies the new plan: ``egress.nft``, the
##    fetch unit's ``IPAddressAllow=`` and the kernel's LOADED ``allowed4``
##    set all hold the new address and not the old.
## 4. **Uninstall removes it.** After uninstall the table is gone and the
##    fingerprint equals the pre-bootstrap one.
##
## Falsifying mutations: ``egress-observer-not-installed`` (the observer
## unit never loads the table: steps 2 and 3 go red);
## ``evidence-path-rate-limited`` (the burst step: the path unit dies on the
## start limit, A11 audit F2); ``uninstall-keeps-fetch-state`` (the
## fetch unit's state directory survives uninstall, A11 audit F5);
## ``reassert-nft-in-own-netns`` (the re-assert lists the tables in its own
## private network namespace: both steps of 3c go red, session 2 G4);
## ``egress-unit-ignores-table`` (the observer unit does not name its
## table, so the re-pin switch leaves the old set loaded: step 3d red).
##
## Seam build (the fetch unit's pause). Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support
import ./evidence_e2e_support
import repro_peer_cache/auth as peerAuth
import repro_peer_cache/evidence

const
  Gate = "e2e_addon_egress_observer"
  CacheName = "repro-cache.a11.test"
  CacheOldAddr = "10.0.2.3"
  CacheNewAddr = "10.0.2.4"

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc tmpMountFacts(g: Guest): string =
  ## What decides how ``/tmp``'s tmpfs options read: the kernel prints
  ## ``size=`` only when the mount's block limit differs from the default
  ## (half of RAM at the time of reading), so ``MemTotal`` beside the
  ## options says whether a difference is the base's RAM accounting.
  g.exec("grep -E 'MemTotal' /proc/meminfo; findmnt -no OPTIONS /tmp; " &
    "systemctl show tmp.mount -p Options -p ActiveEnterTimestampMonotonic; " &
    "dmesg | grep -iE 'Memory:|Freeing|balloon|hotplug' | tail -8").stdout

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
  # Step 3c reboots the host, and the units a cloud image runs only on its
  # first boot (ldconfig, sysusers, machine-id commit, ...) are active in a
  # first boot's fingerprint and not after: the baseline is taken after a
  # boot that is not the first, so step 4 compares like with like.
  g.rebootGuest()
  # A cache origin given by name (step 3d moves it): resolved through the
  # base's /etc/hosts at bootstrap and pinned in the fetch unit's allow-list.
  # Nothing listens there; only the allow-list matters.
  discard g.exec("printf '%s\\n' " & quoteShell(CacheOldAddr & " " & CacheName) &
                 " >> /etc/hosts")
  record["tmpBefore"] = %g.tmpMountFacts()
  let f0 = g.takeFingerprint(repro)
  let bs = g.bootstrapWithAgent(repro, step, extraFlags = sink.evidenceFlags,
    cacheUrl = "http://" & CacheName & ":9",
    cachePublishers = @[hexKey(peerAuth.generateKeypair().publicKey)])
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
  # 3b. A burst of records (A11 audit F2): thirty refused destinations from
  # the fetch slice make the check write thirty records at once. The path
  # unit must survive the burst and ship them within a minute.
  let burstSince = sink.headSeq()
  discard g.exec("systemd-run --wait --quiet --slice=" & "system-reproagent.slice" &
    " -p DynamicUser=yes -p IPAddressDeny=any -p IPAddressAllow=10.0.2.2 " &
    "/bin/bash -c 'for i in $(seq 20 49); do timeout 1 bash -c " &
    "\"exec 3<>/dev/tcp/198.51.100.$i/443\" 2>/dev/null; done; true'",
    timeoutSec = 300)
  discard g.exec("systemctl start repro-addon-egress-check.service")
  var arrived = 0
  for _ in 0 ..< 30:
    arrived = 0
    for e in sink.entries():
      if e.seq > burstSince and e.kind == ekRecord and
          e.record.trigger == "egress-refused" and
          e.record.field("destination").startsWith("198.51.100."): inc arrived
    if arrived >= 30: break
    sleep(2000)
  let pathState = g.exec("systemctl is-failed repro-addon-evidence.path").stdout.strip()
  record["burst"] = %*{"arrived": arrived, "pathUnit": pathState}
  step("a burst of thirty records leaves within a minute, the path unit alive",
       arrived >= 30 and pathState != "failed", $arrived & " arrived; path " &
       pathState)
  # 3c. The re-assert, confined to a private network namespace, reads the
  # HOST's table (session 2, G4): a healthy reboot is ``ok``, a deleted
  # table is ``missing``.
  g.rebootGuest()
  discard g.waitReasserted()
  let healthy = g.exec("cat /var/lib/repro/system/addon/reassert-report").stdout
  record["reassertHealthy"] = %healthy
  step("a healthy reboot: the re-assert is ok, nothing about the table (G4)",
       "repro-addon reassert: ok" in healthy and
         "nftTable" notin healthy, healthy)
  discard g.exec("nft delete table inet repro_addon_egress")
  discard g.exec("systemctl restart repro-addon-reassert.service",
                 timeoutSec = 900)
  let removed = g.exec("cat /var/lib/repro/system/addon/reassert-report").stdout
  record["reassertRemoved"] = %removed
  step("the table deleted: the re-assert reports it missing (G4)",
       "nftTable inet repro_addon_egress: missing" in removed, removed)
  discard g.exec("systemctl restart repro-addon-egress.service")
  step("the observer unit loads the table again",
       "table inet repro_addon_egress" in g.exec("nft list tables").stdout, "")
  # 3d. A re-pin reloads the kernel's table (A11 review round 2): the cache
  # name moves to another address, `agent-repin` re-renders the fetch unit
  # and egress.nft, and the switch must restart the observer so the LOADED
  # set is the new one -- the file alone is not enough.
  proc liveSet(): string =
    g.exec("nft list set inet repro_addon_egress allowed4").stdout
  step("before the re-pin the loaded set holds the cache's address",
       CacheOldAddr in liveSet(), liveSet())
  discard g.exec("sed -i " & quoteShell("s/^" & CacheOldAddr & " " & CacheName &
                 "$/" & CacheNewAddr & " " & CacheName & "/") & " /etc/hosts")
  let plan = g.exec(repro & " system addon agent-repin")
  var digest = ""
  for l in plan.stdout.splitLines():
    let i = l.find("--apply ")
    if l.startsWith("plan ") and i >= 0: digest = l[i + "--apply ".len .. ^1].strip()
  let applied = g.exec(repro & " system addon agent-repin --apply " & digest,
                       timeoutSec = 1800)
  record["repin"] = %(plan.stdout & applied.stdout & applied.stderr)
  step("agent-repin plans and applies the moved origin",
       digest.len > 0 and applied.exitCode == 0, plan.stdout & applied.stdout &
         applied.stderr)
  step("egress.nft names the new address",
       CacheNewAddr in g.exec("cat /etc/repro/egress.nft").stdout, "")
  let live = liveSet()
  step("the kernel's loaded set holds the new address, not the old",
       CacheNewAddr in live and CacheOldAddr notin live, live)
  step("the fetch unit allows the new address",
       CacheNewAddr in g.exec("systemctl show -p IPAddressAllow --value " &
         "repro-agent-fetch.service").stdout, "")
  discard g.exec("sed -i " & quoteShell("s/^" & CacheNewAddr & " " & CacheName &
                 "$/" & CacheOldAddr & " " & CacheName & "/") & " /etc/hosts")
  # 4. Uninstall removes it.
  let un = g.exec(repro & " system addon uninstall", timeoutSec = 1800)
  step("uninstall succeeds", un.exitCode == 0, un.stdout & un.stderr)
  let after = g.exec("nft list tables").stdout
  step("the table is gone", "repro_addon_egress" notin after, after)
  let leftover = g.exec("ls -d /var/lib/private/repro-agent-fetch " &
    "/var/lib/repro-agent-fetch 2>/dev/null").stdout.strip()
  step("the fetch unit's state directory is gone (A11 audit F5)",
       leftover.len == 0, leftover)
  # The one enumerated exception (spec §6.4): the kernel's packet-logger
  # bindings the table's log statement loaded stay after the table is gone.
  record["tmpAfter"] = %g.tmpMountFacts()
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
