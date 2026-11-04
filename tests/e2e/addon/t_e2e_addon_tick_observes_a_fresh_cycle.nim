## Gate ``e2e_addon_tick_observes_a_fresh_cycle``: the positive control of
## the test helper ``agent_e2e_support.tickUnits`` (A13 round 2).
##
## The deploy-agent gates publish a manifest and then run one cycle of the
## real units with ``tickUnits``. A cycle the agent's own timer started can
## be in flight at that moment (``OnBootSec=``: soon after a reboot); a
## `systemctl start` then joins it, and the cycle observed fetched before
## the publish. The conversion gate hit exactly that on ubuntu-24.04 at
## reprobuild a2a1d662ae (a tick after the source host's reboot reported
## sequence 1 when 2 was published). ``tickUnits`` now waits for both units
## to settle and proves that the fetch it observed started after the tick
## began, reporting ``stale-cycle`` otherwise.
##
## This gate stages the race deterministically (seam build): sequence 1 is
## applied; sequence 2 is published and a fetch is started and held at
## ``agent-fetch-after-select`` (it has selected 2); sequence 3 is
## published; a guest-side timer releases the held fetch after 20 s; then
## ``tickUnits`` runs. It must observe a fresh cycle that applies 3.
##
## Variants (gate-level ``REPRO_A13_MUTATION``):
##
## - ``tick-joins-in-flight`` (the old helper: no wait, no proof): the tick
##   joins the held fetch and silently reports sequence 2: red;
## - ``tick-skips-idle-wait`` (the proof without the wait): the tick joins
##   the held fetch and the proof reports ``stale-cycle``: red, and the
##   record shows the detection.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (seam build).
##
## *Mocking.* None: the real units under the guest's systemd, the real
## producer; the hold is the fetch unit's own test seam.

import std/[json, os, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_tick_observes_a_fresh_cycle"
  Path = "/etc/repro/a13-tick"
  ReleaseAfterSec = 20

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  record["variant"] = %getEnv("REPRO_A13_MUTATION")
  # No timer cycle may interfere with the staged one.
  discard g.exec("systemctl stop repro-agent-fetch.timer")
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: canonicalFile(Path, "one\n")))
  let t1 = g.tickUnits()
  step("sequence 1 is applied", t1.outcome == "aoApplied" and
       t1.sequence == 1, $t1 & t1.applyLog)
  # A cycle in flight: it has selected sequence 2 and is held.
  discard producer.publish(PublishSpec(sequence: 2,
    profileText: canonicalFile(Path, "two\n")))
  g.armFetchSeam("agent-fetch-after-select")
  g.startFetchNoWait()
  let held = g.waitSeam(FetchSeamDir, "agent-fetch-after-select")
  step("a fetch that selected sequence 2 is held in flight", held, "")
  if not held: return
  discard producer.publish(PublishSpec(sequence: 3,
    profileText: canonicalFile(Path, "three\n")))
  # Released from inside the guest while the tick below is under way.
  discard g.run("setsid sh -c 'sleep " & $ReleaseAfterSec & "; touch " &
    FetchSeamDir & "/test-resume' >/dev/null 2>&1 < /dev/null &")
  let t = g.tickUnits()
  record["tick"] = %($t)
  step("the tick observes a fresh cycle, which applies sequence 3",
       t.outcome == "aoApplied" and t.sequence == 3,
       $t & "\n" & t.fetchLog & t.applyLog)
  step("the file holds sequence 3's content",
       g.exec("cat " & Path).stdout == "three\n", g.exec("cat " & Path).stdout)

suite Gate:
  test "a tick observes a cycle it started, after the publish":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
