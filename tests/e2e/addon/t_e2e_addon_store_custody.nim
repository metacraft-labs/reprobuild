## Gate ``e2e_addon_store_custody`` (milestone A11; ReproOS Add-On Mode §13
## decisions 47 and 48; threat model DET-AO-5, G42; A11 audit session 2,
## finding G1).
##
## Every store object a generation references is checked against the
## digest recorded at its realisation, and an altered one is recovered from
## a trusted source -- its altered bytes kept in the root-only evidence
## directory, a DET-AO-5 ``store-recovered`` record shipped -- or the switch
## refuses. On one host bootstrapped with the deploy agent and an Evidence
## sink:
##
## 1. **Coverage.** An operator apply of a unit bound to an apt closure:
##    the ledger records a digest for every store object it names.
## 2. **A generation-0 /etc source, quarantined, recovered.** One byte of
##    the store file behind ``/etc/profile.d/repro-addon.sh`` changes and
##    store verification quarantines its prefix. The next switch applies;
##    the ``/etc`` copy and the store file hold the original bytes, the
##    quarantine is released, the altered tree is in the evidence directory
##    (0700, root), and ``store-recovered`` reaches the sink.
## 3. **An apt closure member, its union intact, refused, then recovered
##    through the fetch.** A file is planted in the closure's member prefix
##    only; the union keeps its bytes. The closure's unit is published to
##    the deploy agent, whose archive (the lock's) is served by the
##    producer. The first tick's fetch stages nothing (the member is
##    there) and its switch has no copy of the member's ``.deb``: it
##    refuses (``EAddOnStoreChanged``) and moves the altered member aside.
##    The next tick's fetch stages the missing member's archive from the
##    lock's URL, and its switch re-realises the member and applies, the
##    member and the union holding the original bytes (A11 review finding
##    1: the member used to stay missing behind an intact union, and the
##    fetch stage it only when the union was missing, so every switch
##    refused).
## 4. **The egress observer's source, no wedge.** The store file behind
##    ``/etc/repro/egress.nft`` changes and no verification runs: the
##    agent's next switch finds it by digest and recovers it; after a
##    reboot the observer loads its table and the agent applies the next
##    sequence (the audit's wedge: an altered ``egress.nft`` installed made
##    the fetch unit's ``Requires=`` fail).
## 5. **Uninstall** names the evidence entries before it removes anything:
##    without ``--discard-store-evidence`` it refuses, naming each, and
##    removes nothing; with it, it removes them with the state. An object
##    left aside in the store (as a crash leaves it) is named too, and (§13
##    decision 56) its DET-AO-5 ``store-recovery-interrupted`` record
##    reaches the sink before anything is discarded. Then the sink
##    receives the records and does not acknowledge them (the host's
##    credential revoked at the sink), and ``--discard-store-evidence`` is
##    refused, removing nothing (decision 56). With
##    ``--discard-unacknowledged-store-evidence`` (decision 62) uninstall
##    removes them, after writing a signed record of each object discarded
##    unshipped to ``/var/log/repro-addon``, which it prints and which
##    stays after it; ``repro system addon verify-discard-record`` accepts
##    its signature with the attestation key bootstrap printed (decision
##    64).
##
## Falsifying mutations: ``custody-skips-file-sources`` (steps 2 and 4: the
## altered bytes are installed into /etc), ``custody-skips-closures`` (step
## 3: the altered member is used), ``recovery-discards-evidence`` (the
## evidence steps), ``recovery-trusts-store-bytes`` (step 2: the files
## prefix is "recovered" from its own altered copy, does not hash to its
## recorded digest, and the switch refuses), ``apt-closure-member-stays-missing``
## and ``fetch-skips-missing-member`` (step 3: the second tick refuses
## too), ``uninstall-discards-evidence-silently`` (step 5: the first
## uninstall removes the evidence), ``uninstall-discards-unrecorded`` (step
## 5: the object left aside reaches no record), ``uninstall-skips-ack-refusal``
## (step 5: the unacknowledged discard goes ahead), ``override-unrecorded``
## (step 5: the override writes and prints no record),
## ``override-signs-other-bytes`` and ``override-empty-signature`` (step 5:
## ``verify-discard-record`` refuses the record), ``verify-accepts-missing-key``
## (step 5: it verifies without ``--key``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* The fixture ``.deb`` is built here. Step 1's operator apply
## (which has no fetch unit) finds it seeded into the realiser's ``.deb``
## cache, verified against the lock as a download would be (as in
## ``e2e_addon_closure_prefixes_survive_gc``); step 3's recovery takes it
## through the deploy agent's own fetch, from the producer serving the
## lock's archive URL. The archive is the fixture's, not a Debian mirror.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip
import repro_dsl_stdlib/packages/apt_closure
import repro_peer_cache/evidence
import repro_peer_cache/types

import ./addon_testbed
import ./agent_e2e_support
import ./deb_fixture_support
import ./evidence_e2e_support

const
  Gate = "e2e_addon_store_custody"
  Unit = "repro-custody.service"
  Managed = "/etc/repro/a11-custody"
  Evidence = "/var/lib/repro/system/addon/store-evidence"
  Quarantine = "/var/lib/repro/system/addon/store-quarantine"

proc unitBlock(lockText, note: string): string =
  "systemd.systemUnit {\n" & FixtureFloorWaiver & "  name = \"" & Unit &
    "\"\n  content = \"[Unit]\nDescription=custody " & note &
    "\n[Service]\nType=oneshot\nExecStart=/usr/bin/true\n\"\n" &
    "  enabled = false\n  aptClosureLock = \"" & lockText & "\"\n}\n" &
    canonicalFile(Managed, note & "\n")

proc tamper(g: Guest; file, text: string): ExecOut =
  ## Append ``text`` to a store file through a private writable view of
  ## the store, as a root writer outside the apply unit would.
  g.exec("unshare --mount --propagation private /bin/sh -c " &
    quoteShell("mount -o remount,bind,rw /repro/store && printf " &
      quoteShell(text) & " >> " & quoteShell(file)))

proc sha(g: Guest; path: string): string =
  g.exec("sha256sum " & quoteShell(path) & " | cut -d' ' -f1").stdout.strip()

proc storeSourceOf(g: Guest; etcPath: string): string =
  ## The files-prefix file whose name is the SHA-256 of ``etcPath``.
  let h = g.sha(etcPath)
  g.exec("ls -d /repro/store/prefixes/repro-addon-files/*/" & h &
    " 2>/dev/null | head -1").stdout.strip()

proc evidenceCount(g: Guest): int =
  let o = g.exec("ls -1 " & Evidence & " 2>/dev/null").stdout.strip()
  if o.len == 0: 0 else: o.splitLines().len

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  var sink = startGateSink(g)
  defer: sink.stop()
  g.provideSinkCa(sink)
  let bs = g.bootstrapWithAgent(repro, step, extraFlags = sink.evidenceFlags)
  producer = bs.producer
  if not bs.ok: return
  let host = g.enrol(sink)
  proc ship() =
    discard g.exec("systemctl start repro-addon-evidence.service")

  # The fixture closure, seeded where the realiser looks first.
  let deb = g.runDir / "custody.deb"
  writeDeb(deb, @[dir("./"), dir("./usr/"), dir("./usr/share/"),
    dir("./usr/share/custody/"),
    ("./usr/share/custody/ok.txt", '0', 0o644, "custody\n", "")])
  var lock = fixtureLock("custody", deb)
  # The lock's archive is the producer's origin, so the agent's fetch unit
  # can stage the member's archive from the URL the lock names.
  lock.archive = producer.originUrl() & "/debian"
  createDir(producer.dir / "debian" / parentDir(lock.debs[0].filename))
  copyFile(deb, producer.dir / "debian" / lock.debs[0].filename)
  let lockText = renderAptClosureLock(lock)
  let union = aptClosurePrefixPath(AddOnSystemStoreRoot, lock)
  let member = aptDebPrefixPath(AddOnSystemStoreRoot, lock.debs[0])
  proc seed() =
    discard g.run("mkdir -p " & AddOnAptDebCacheDir & " && chmod 0700 " &
                  AddOnAptDebCacheDir)
    g.copyTo(deb, AddOnAptDebCacheDir & "/" & lock.debs[0].sha256 & ".deb")

  # 1. Coverage.
  seed()
  let a1 = g.applyProfile(repro, "custody-1", unitBlock(lockText, "one"))
  step("an apply bound to a closure commits", a1.exitCode == 0,
       a1.stdout & a1.stderr)
  let l1 = g.ledgerOf()
  record["ledger1"] = %l1
  var undigested: seq[string]
  var named = 0
  for line in l1.splitLines():
    if line.startsWith("storePrefix\t"):
      inc named
      if "tree-v2:" notin line: undigested.add(line.split('\t')[1])
  step("the ledger records a digest for every store object it names",
       named >= 5 and undigested.len == 0 and union in l1 and member in l1,
       $named & " named; without a digest: " & undigested.join(", "))

  # 2. A generation-0 /etc source, quarantined, then recovered.
  let prof = "/etc/profile.d/repro-addon.sh"
  let profSha = g.sha(prof)
  let src = g.storeSourceOf(prof)
  let filesPrefix = parentDir(src)
  let t2 = g.tamper(src, "# planted\n")
  step("a byte of the store file behind " & prof & " changed",
       src.len > 0 and t2.exitCode == 0 and g.sha(src) != profSha,
       src & t2.stderr)
  discard g.exec("systemctl start repro-addon-store-verify.service",
                 timeoutSec = 1200)
  step("store verification quarantines its prefix",
       filesPrefix in g.exec("cat " & Quarantine).stdout,
       g.exec("cat " & Quarantine).stdout)
  let since2 = sink.headSeq()
  let before2 = g.evidenceCount()
  let a2 = g.applyProfile(repro, "custody-2", unitBlock(lockText, "two"))
  step("the next switch commits", a2.exitCode == 0, a2.stdout & a2.stderr)
  step("the /etc copy keeps its bytes", g.sha(prof) == profSha, g.sha(prof))
  step("the store file holds its bytes again", g.sha(src) == profSha,
       g.sha(src))
  step("the quarantine is released",
       filesPrefix notin g.exec("cat " & Quarantine & " 2>/dev/null").stdout, "")
  step("the altered tree is kept in the evidence directory",
       g.evidenceCount() == before2 + 1 and g.exec("grep -rl planted " &
         Evidence).stdout.strip().len > 0,
       g.exec("ls -lR " & Evidence & " | head -40").stdout)
  let mode = g.exec("stat -c '%a %U' " & Evidence).stdout.strip()
  step("the evidence directory is root's alone", mode == "700 root", mode)
  ship()
  step("the DET-AO-5 store-recovered record reached the sink",
       sink.waitFor(host, "addon-store", "store-recovered", 180,
                    since = since2), "")

  # 3. An apt closure member, its union intact: refused without its
  #    archive, then recovered through the fetch.
  let memberFile = member / "usr/share/custody/ok.txt"
  let unionFile = union / "usr/share/custody/ok.txt"
  let unionSha = g.sha(unionFile)
  let t3 = g.exec("unshare --mount --propagation private /bin/sh -c " &
    quoteShell("mount -o remount,bind,rw /repro/store && printf planted > " &
      quoteShell(member / "usr/share/custody/planted.txt")))
  step("a file was planted in the closure's member, its union untouched",
       t3.exitCode == 0 and g.sha(unionFile) == unionSha and
         g.exec("test -e " & quoteShell(union /
           "usr/share/custody/planted.txt")).exitCode != 0,
       t3.stderr)
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: unitBlock(lockText, "three")))
  let k3 = g.tickUnits()
  record["closureRefusal"] = %($k3)
  step("without the member's archive the agent's switch refuses",
       k3.outcome != "aoApplied" and
         "EAddOnStoreChanged" in k3.message & k3.applyLog, $k3)
  step("the altered member was moved aside, its bytes kept",
       g.exec("test -e " & quoteShell(member)).exitCode != 0 and
         g.exec("grep -rl planted " & Evidence).stdout.splitLines().len >= 2,
       g.exec("ls " & Evidence).stdout)
  let k4 = g.tickUnits()
  step("the next fetch stages the member's archive and the switch applies",
       k4.outcome == "aoApplied" and k4.sequence == 1, $k4)
  step("the member and the union hold the original bytes",
       g.run("cat " & memberFile).strip() == "custody" and
         g.sha(unionFile) == unionSha and
         g.exec("test -e " & quoteShell(member /
           "usr/share/custody/planted.txt")).exitCode != 0,
       g.run("cat " & memberFile & " " & unionFile))

  # 4. The egress observer's source, recovered by digest, no wedge.
  let nftConf = "/etc/repro/egress.nft"
  let nftSha = g.sha(nftConf)
  let nftSrc = g.storeSourceOf(nftConf)
  let t5 = g.tamper(nftSrc, "this is not nft syntax\n")
  step("the store file behind " & nftConf & " changed",
       nftSrc.len > 0 and t5.exitCode == 0, nftSrc & t5.stderr)
  discard producer.publish(PublishSpec(sequence: 2,
    profileText: canonicalFile(Managed, "agent one\n")))
  let k1 = g.tickUnits()
  step("the agent's switch recovers it and applies", k1.outcome == "aoApplied",
       $k1)
  step(nftConf & " keeps its bytes", g.sha(nftConf) == nftSha, g.sha(nftConf))
  g.rebootGuest()
  discard g.waitReasserted()
  step("after a reboot the observer is active",
       g.exec("systemctl is-active repro-addon-egress.service").stdout.strip() ==
         "active", g.exec("systemctl status repro-addon-egress.service " &
           "--no-pager | tail -5").stdout)
  discard producer.publish(PublishSpec(sequence: 3,
    profileText: canonicalFile(Managed, "agent two\n")))
  let k2 = g.tickUnits()
  step("and the agent fetches and applies the next sequence",
       k2.outcome == "aoApplied" and k2.sequence == 3, $k2)

  # 5. Uninstall names the evidence before it removes anything, and (§13
  # decision 56) records and ships first what no record named yet: here an
  # object a crashed recovery left aside in the store.
  let aside = "/repro/store/tmp/custody-aside/20261107T000000Z-gate-1-a"
  let leave = g.exec("unshare --mount --propagation private /bin/sh -c " &
    quoteShell("mount -o remount,bind,rw /repro/store && mkdir -p " & aside &
      " && printf altered > " & aside & "/f && printf '%s\\n' " &
      "/repro/store/prefixes/gate/1-a > " & aside & ".from"))
  step("an object is left aside in the store, as a crash leaves it",
       leave.exitCode == 0, leave.stderr)
  let since5 = sink.headSeq()
  let entries = g.evidenceCount()
  let un0 = g.exec(repro & " system addon uninstall", timeoutSec = 1800)
  record["uninstallRefused"] = %(un0.stdout & un0.stderr)
  step("without --discard-store-evidence uninstall refuses, naming each " &
       "entry and the object left aside, and removes nothing",
       un0.exitCode != 0 and entries > 0 and
         (un0.stdout & un0.stderr).count("store evidence ") == entries + 1 and
         aside in un0.stdout & un0.stderr and
         "nothing was removed" in un0.stdout & un0.stderr and
         g.evidenceCount() == entries and
         g.exec("test -d /var/lib/repro/system").exitCode == 0,
       un0.stdout & un0.stderr)
  var asideRecorded = false
  for e in sink.entries():
    if e.seq > since5 and e.kind == ekRecord and $e.senderHostId == host and
        e.record.trigger == "store-recovery-interrupted" and
        e.record.field("evidence") == aside:
      asideRecorded = true
  step("the object left aside was recorded and the record reached the sink " &
       "before anything was discarded (decision 56)", asideRecorded, "")

  # Decision 56's refusal: the sink receives the records and does not
  # acknowledge them (the host's credential is revoked at the sink: it
  # still proves, the sink reads the append and records it refused, and
  # sends no receipt). A second object left aside is recorded but not
  # acknowledged, and ``--discard-store-evidence`` is refused.
  let aside2 = "/repro/store/tmp/custody-aside/20261107T000001Z-gate-2-a"
  let leave2 = g.exec("unshare --mount --propagation private /bin/sh -c " &
    quoteShell("mount -o remount,bind,rw /repro/store && mkdir -p " & aside2 &
      " && printf altered > " & aside2 & "/f && printf '%s\\n' " &
      "/repro/store/prefixes/gate/2-a > " & aside2 & ".from"))
  step("a second object is left aside in the store",
       leave2.exitCode == 0, leave2.stderr)
  sink.revoke(host)
  let since6 = sink.headSeq()
  let un1 = g.exec(repro & " system addon uninstall --discard-store-evidence",
                   timeoutSec = 1800)
  record["uninstallUnacknowledged"] = %(un1.stdout & un1.stderr)
  step("the sink receiving but not acknowledging, --discard-store-evidence " &
       "is refused and nothing is removed (decision 56)",
       un1.exitCode != 0 and
         "has not acknowledged" in un1.stdout & un1.stderr and
         "--discard-unacknowledged-store-evidence" in un1.stdout & un1.stderr and
         "nothing was removed" in un1.stdout & un1.stderr and
         g.evidenceCount() == entries and
         g.exec("test -d " & aside2).exitCode == 0 and
         g.exec("test -d /var/lib/repro/system").exitCode == 0,
       un1.stdout & un1.stderr)
  var refusedAppend, aside2Appended = false
  for e in sink.entries():
    if e.seq > since6 and $e.senderHostId == host:
      if e.kind == ekRefusedVerb: refusedAppend = true
      if e.kind == ekRecord and e.record.field("evidence") == aside2:
        aside2Appended = true
  step("the sink received the append and appended none of its records",
       refusedAppend and not aside2Appended, "")

  # Decision 62, the explicit recorded override: uninstall discards anyway,
  # after a signed local record of every object discarded unshipped, which
  # it prints and leaves outside the state it removes.
  let un = g.exec(repro & " system addon uninstall " &
                  "--discard-unacknowledged-store-evidence", timeoutSec = 1800)
  record["uninstall"] = %(un.stdout & un.stderr)
  let said = un.stdout & un.stderr
  let marker = "the signed record is "
  var recordPath = ""
  if marker in said:
    recordPath = said[said.find(marker) + marker.len .. ^1].splitLines()[0]
    recordPath = recordPath.split(' ')[0]
    recordPath.removeSuffix(":")
  step("with --discard-unacknowledged-store-evidence uninstall succeeds, " &
       "names each store-evidence entry and prints its signed record",
       un.exitCode == 0 and
         said.count("(store evidence)") == entries and
         (aside2 & " (store evidence left aside)") in said and
         recordPath.startsWith("/var/log/repro-addon/") and
         aside2 in said[said.find(marker) .. ^1],
       said)
  let kept = g.exec("cat " & quoteShell(recordPath)).stdout
  # Decision 64: checked the way an operator checks it, with the command,
  # against the attestation key bootstrap printed (the enrolled one).
  let verify = g.exec(repro & " system addon verify-discard-record " &
    quoteShell(recordPath) & " --key " & quoteShell(bs.attestationKey))
  record["overrideVerify"] = %(verify.stdout & verify.stderr)
  # Without --key nothing is verified: a usage error (decision 64, amended
  # round 6).
  let keyless = g.exec(repro & " system addon verify-discard-record " &
    quoteShell(recordPath))
  record["overrideVerifyWithoutKey"] = %(keyless.stdout & keyless.stderr)
  let signed = bs.attestationKey.len > 0 and verify.exitCode == 0 and
    ("  " & aside2) in verify.stdout and keyless.exitCode == 2 and
    "verified" notin keyless.stdout
  record["overrideRecord"] = %kept
  step("the record names the object discarded unshipped, stays after " &
       "uninstall, and verify-discard-record accepts its signature with the " &
       "enrolled key and refuses to verify without one (decisions 62, 64)",
       signed, kept & "\n" & verify.stdout & verify.stderr & "\n" &
       keyless.stdout & keyless.stderr)
  step("the evidence directory is gone with the state",
       g.exec("test -e " & Evidence).exitCode != 0, "")

suite Gate:
  test "store custody: coverage, recovery with evidence, refusal":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
