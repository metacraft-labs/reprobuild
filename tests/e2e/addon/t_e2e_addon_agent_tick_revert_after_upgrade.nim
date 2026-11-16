## Add-on VM gate: on a host an earlier engine bootstrapped with the deploy
## agent, the agent's units run the upgrading engine, so an agent tick's
## revert left pending is held across a reboot (ReproOS Add-On Mode spec
## §6.2 step 4, §9.1, §10.1; §13 decision 173, the owner's decision of
## 2026-11-16 on A9 review round 17, finding 3: re-point the agent's units
## under decision 164's rules).
##
## On each base:
##
## 1. the PREVIOUS engine (``REPRO_A9_PREVIOUS_ADDON``, a static add-on
##    artefact from before the boot-hold unit) bootstraps the add-on with
##    the deploy agent;
## 2. one local apply by this engine re-points the re-assert, boot-confirm,
##    agent-apply and agent-fetch units at this engine, realised in the
##    store and named in the ledger;
## 3. an agent tick applies a floored service only its socket starts; the
##    next tick's switch is refused (a tree the service never made) and its
##    revert cannot write the holds (both drop-in directories full), so the
##    tick leaves the switch pending -- with the start holds recorded for
##    the boot-hold unit, because the apply unit ran this engine;
## 4. at the reboot the boot-hold unit puts the holds back before
##    ``sysinit.target``, the re-assertion commits the revert, and the
##    socket never listens: no floored unit started unchecked.
##
## Falsifying build, red here: ``reassert-not-repointed`` (the units keep
## the previous engine: the tick records no boot holds and its revert does
## not hold the socket, which listens after the reboot).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_A9_PREVIOUS_ADDON``.
##
## *Mocking.* None: the real add-on of two engines, the real agent units
## fetching from a producer on the host's loopback, the base's own systemd.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_agent_tick_revert_after_upgrade"
  Head = "addOn {\n  managedEtcPrefixes = []\n}\n\n"
  Pending = "/var/lib/repro/system/addon/pending"
  EngineUnits = ["repro-addon-reassert.service", "repro-addon-boot-confirm.service",
                 "repro-agent-apply.service", "repro-agent-fetch.service"]

proc installPrevious(g: Guest; dir = "/root/addon-prev"): tuple[repro, sha: string] =
  ## The previous engine's artefact, verified in the guest against its
  ## published digest before it runs, as ``installArtefact`` does.
  let root = getEnv("REPRO_A9_PREVIOUS_ADDON")
  if root.len == 0:
    raise newException(TestBedError, "REPRO_A9_PREVIOUS_ADDON must name the " &
      "previous engine's add-on artefact directory")
  let a = root / g.base.debArch
  let sha = readFile(a / "repro.sha256").splitWhitespace()[0]
  discard g.run("mkdir -p " & dir)
  g.copyTo(a / "repro", dir & "/repro")
  g.copyTo(a / "reprobuild-sandbox-launcher", dir & "/reprobuild-sandbox-launcher")
  discard g.run("cd " & dir & " && echo '" & sha & "  repro' | sha256sum -c - && " &
                "chmod 0755 repro reprobuild-sandbox-launcher")
  (dir & "/repro", sha)

proc enginesOf(g: Guest): string =
  ## The add-on binary each engine unit runs, one line per unit.
  for u in EngineUnits:
    result.add(u & " " & g.exec("grep -h -o -m1 '/repro/store/prefixes/repro-addon/[^ ]*/bin/repro' " &
      "/etc/systemd/system/" & u & " 2>/dev/null; true").stdout.strip() & "\n")

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let (prev, prevSha) = g.installPrevious()
  record["previousArtefactSha256"] = %prevSha
  discard g.run("useradd -r -M -s /usr/sbin/nologin a9t")
  let bs = g.bootstrapWithAgent(prev, step)
  producer = bs.producer
  if not bs.ok: return
  let binary = g.run("ls -d /repro/store/prefixes/repro-addon/*/bin/repro | head -1").strip()
  let before = g.enginesOf()
  record["enginesBefore"] = %before
  # The upgrade: one local apply by this engine.
  let control = Head & "systemd.systemUnit {\n  name = \"a9t-control.service\"\n" &
    "  content = \"[Unit]\nDescription=A9 round 17\n\n[Service]\nType=oneshot\n" &
    "RemainAfterExit=yes\nUser=a9t\nExecStart=" & binary & " --version\n\n" &
    "[Install]\nWantedBy=multi-user.target\n\"\n  enabled = true\n}\n"
  var r = g.applyProfile(repro, "u1", control)
  step("this engine's local apply passes", r.exitCode == 0, r.stdout & r.stderr)
  let after = g.enginesOf()
  record["enginesAfter"] = %after
  let ledger = g.ledgerOf()
  var allNew = true
  var newExe = ""
  for l in after.splitLines():
    let w = l.splitWhitespace()
    if w.len < 2: continue
    if w.len < 2 or w[1] == binary: allNew = false
    if newExe.len == 0: newExe = w[1]
    elif w[1] != newExe: allNew = false
  step("it re-points the re-assert, boot-confirm, agent-apply and agent-fetch " &
       "units at this engine, ledgered (§13 decision 173)",
       allNew and newExe.len > 0 and parentDir(parentDir(newExe)) in ledger and
       g.exec("cmp -s " & newExe & " " & repro).exitCode == 0,
       "before:\n" & before & "after:\n" & after)
  let srp = proc (d: string): string =
    Head & "systemd.systemUnit {\n  name = \"a9t-sr.service\"\n" &
      "  content = \"[Unit]\nDescription=" & d & "\n\n[Service]\nType=oneshot\n" &
      "RemainAfterExit=yes\nUser=a9t\nStateDirectory=a9t-sr\nExecStart=" & binary &
      " --version\n\"\n  enabled = false\n}\n" &
      "systemd.systemUnit {\n  name = \"a9t-sr.socket\"\n  content = \"[Socket]\n" &
      "ListenStream=/run/a9t-sr\nService=a9t-sr.service\n\n[Install]\n" &
      "WantedBy=sockets.target\n\"\n  enabled = true\n}\n"
  discard producer.publish(PublishSpec(sequence: 1, profileText: srp("A9 round 17 t1")))
  var t = g.tickUnits()
  step("an agent tick applies a floored service only its socket starts",
       t.outcome == "aoApplied", $t & t.applyLog)
  discard g.run("rm -rf /var/lib/a9t-sr; mkdir /var/lib/a9t-sr; touch /var/lib/a9t-sr/theirs; " &
    "for u in service socket; do d=/etc/systemd/system/a9t-sr.$u.d; mkdir -p $d; " &
    "mount -t tmpfs -o size=4k a9full $d; " &
    "dd if=/dev/zero of=$d/.fill bs=4096 count=4 2>/dev/null; done; true")
  discard producer.publish(PublishSpec(sequence: 2, profileText: srp("A9 round 17 t2")))
  t = g.tickUnits()
  let rec = g.exec("cat /var/lib/repro/system/addon/boot-holds 2>&1; true").stdout
  record["tickRevert"] = %*{"tick": $t, "bootHolds": rec}
  step("the next tick's switch is refused and its revert, unable to write the " &
       "holds, is pending with the boot's holds recorded",
       t.outcome != "aoApplied" and g.exec("test -e " & Pending).exitCode == 0 and
       "a9t-sr.socket.d" in rec,
       $t & t.applyLog & "\nboot-holds: " & rec)
  g.rebootGuest()
  discard g.waitReasserted()
  let sock = g.exec("test -e " & Pending & " && echo pending; " &
    "systemctl show -p ActiveState -p AssertResult a9t-sr.socket a9t-sr.service; " &
    "ss -xlH | grep -c ' /run/a9t-sr '; " &
    # The unit's own lines this boot: it runs at boot, and a switch may
    # start it again later, when its condition skips it.
    "journalctl -b -o cat --no-pager -u repro-addon-boot-hold.service | " &
    "grep -e 'repro-addon boot-holds' -e skipped; true").stdout
  record["rebootAfterTick"] = %sock
  step("after the reboot the tick's revert is committed and no floored unit " &
       "started unchecked: the socket is down and never listened",
       "pending" notin sock and "ActiveState=active" notin sock and
       "held " in sock and
       # systemd's own line for the socket when it binds (its unit's
       # journal; the add-on's report names the socket in other lines).
       g.exec("journalctl -b -o cat --no-pager -u a9t-sr.socket | " &
              "grep -c '^Listening on'; true").stdout.strip() == "0",
       sock)
  discard g.run("rm -rf /var/lib/a9t-sr")

suite Gate:
  test "an agent tick's revert on an upgraded host is held across a reboot":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif getEnv("REPRO_A9_PREVIOUS_ADDON").len == 0:
      skip("set REPRO_A9_PREVIOUS_ADDON to the previous engine's add-on artefact")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
