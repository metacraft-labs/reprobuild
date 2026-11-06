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
## Then (A9 review round 5, finding 6) the race the trace gate hit: the
## fetch timer's own cycle applies a published sequence between two ticks,
## and the next tick must report ``timer-cycle-intervened``, not pass on
## "already converged". Variant ``tick-trusts-the-timer`` (no check): red.
##
## And (A9 review round 7, finding 7) the edges of that detection: a cycle
## between the agent's bootstrap and the first tick, a trigger while the
## tick itself runs, and a cycle before a sequence that is refused rather
## than converged. Each must be named. Variant
## ``tick-compares-previous-end`` (round 5's comparison: no baseline at
## bootstrap, none at the tick's end, only a converged tick named): red.
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

proc fireTimerOnce(g: Guest; waitFor: string) =
  ## Let the fetch timer itself fire once (a runtime ``OnActiveSec=1s``),
  ## wait until ``waitFor`` (a shell condition) holds and the apply is idle,
  ## then stop the timer and remove the drop-in.
  discard g.exec("mkdir -p /run/systemd/system/repro-agent-fetch.timer.d && " &
    "printf '[Timer]\\nOnActiveSec=1s\\n' > " &
    "/run/systemd/system/repro-agent-fetch.timer.d/zz-a9-once.conf && " &
    "systemctl daemon-reload && systemctl start repro-agent-fetch.timer; " &
    "for i in $(seq 1 600); do " & waitFor & " && " &
    "[ \"$(systemctl show -p ActiveState --value repro-agent-apply.service)\" " &
    "!= activating ] && break; sleep 1; done; " &
    "systemctl stop repro-agent-fetch.timer; rm -rf " &
    "/run/systemd/system/repro-agent-fetch.timer.d; systemctl daemon-reload")

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  record["variant"] = %getEnv("REPRO_A13_MUTATION")
  # No timer cycle may interfere with the staged one.
  discard g.exec("systemctl stop repro-agent-fetch.timer")
  # A9 review round 7, finding 7, case 1: a timer cycle between the agent's
  # bootstrap (which records the baseline) and the gate's first tick. The
  # helper used to have nothing to compare with on its first tick.
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: canonicalFile(Path, "one\n")))
  g.fireTimerOnce("[ \"$(cat " & Path & " 2>/dev/null)\" = one ]")
  let t0 = g.tickUnits()
  record["firstTick"] = %($t0)
  step("the first tick names the cycle the timer ran after bootstrap",
       t0.outcome == "timer-cycle-intervened", $t0)
  discard producer.publish(PublishSpec(sequence: 2,
    profileText: canonicalFile(Path, "two\n")))
  let t1 = g.tickUnits()
  step("sequence 2 is applied", t1.outcome == "aoApplied" and
       t1.sequence == 2, $t1 & t1.applyLog)
  # A cycle in flight: it has selected sequence 3 and is held.
  discard producer.publish(PublishSpec(sequence: 3,
    profileText: canonicalFile(Path, "three\n")))
  g.armFetchSeam("agent-fetch-after-select")
  g.startFetchNoWait()
  let held = g.waitSeam(FetchSeamDir, "agent-fetch-after-select")
  step("a fetch that selected sequence 3 is held in flight", held, "")
  if not held: return
  discard producer.publish(PublishSpec(sequence: 4,
    profileText: canonicalFile(Path, "four\n")))
  # Released from inside the guest while the tick below is under way.
  discard g.run("setsid sh -c 'sleep " & $ReleaseAfterSec & "; touch " &
    FetchSeamDir & "/test-resume' >/dev/null 2>&1 < /dev/null &")
  let t = g.tickUnits()
  record["tick"] = %($t)
  step("the tick observes a fresh cycle, which applies sequence 4",
       t.outcome == "aoApplied" and t.sequence == 4,
       $t & "\n" & t.fetchLog & t.applyLog)
  step("the file holds sequence 4's content",
       g.exec("cat " & Path).stdout == "four\n", g.exec("cat " & Path).stdout)
  # A cycle the fetch timer runs between two ticks applies what the gate
  # published, and the gate's tick then sees "already converged" (A9 review
  # round 5, finding 6: a re-run once hid this as green). Stage it: publish
  # 5, let the timer itself fire once, wait for its cycle to finish; the
  # tick must name the intervening cycle.
  discard producer.publish(PublishSpec(sequence: 5,
    profileText: canonicalFile(Path, "five\n")))
  g.fireTimerOnce("[ \"$(cat " & Path & " 2>/dev/null)\" = five ]")
  step("the timer's own cycle applied sequence 5 (the staged race)",
       g.exec("cat " & Path).stdout == "five\n", g.exec("cat " & Path).stdout)
  let ti = g.tickUnits()
  record["intervenedTick"] = %($ti)
  step("the next tick names the cycle the timer ran, never a pass",
       ti.outcome == "timer-cycle-intervened", $ti)
  # Round 7, finding 7, case 2: the timer triggers while the tick runs,
  # after its fetch finished and before the helper stops the timer (the
  # tick's apply held at its seam). The cycle it starts runs on, and the
  # helper used to record that trigger as the next tick's baseline and never
  # name it. (A trigger while the fetch itself runs starts nothing new:
  # systemd.timer(5) leaves a running unit running.)
  discard producer.publish(PublishSpec(sequence: 6,
    profileText: canonicalFile(Path, "six\n")))
  g.armApplySeam("agent-apply-after-verify")
  discard g.run("setsid sh -c 'for i in $(seq 1 600); do grep -qx " &
    "agent-apply-after-verify " & ApplySeamDir & "/test-paused-at 2>/dev/null " &
    "&& break; sleep 1; done; t0=$(systemctl show -p LastTriggerUSecMonotonic " &
    "--value repro-agent-fetch.timer); mkdir -p /run/systemd/system/repro-agent-fetch.timer.d; " &
    "printf \"[Timer]\\nOnActiveSec=1s\\n\" > " &
    "/run/systemd/system/repro-agent-fetch.timer.d/zz-a9-once.conf; " &
    "systemctl daemon-reload; systemctl start repro-agent-fetch.timer; " &
    "for i in $(seq 1 60); do [ \"$(systemctl show -p LastTriggerUSecMonotonic " &
    "--value repro-agent-fetch.timer)\" != \"$t0\" ] && break; sleep 1; done; " &
    "systemctl stop repro-agent-fetch.timer; rm -rf " &
    "/run/systemd/system/repro-agent-fetch.timer.d; systemctl daemon-reload; " &
    "touch " & ApplySeamDir & "/test-resume' >/dev/null 2>&1 < /dev/null &")
  let tc = g.tickUnits()
  record["duringTick"] = %($tc)
  step("a trigger during the tick is named, never a pass",
       tc.outcome == "timer-cycle-intervened", $tc)
  # Round 7, finding 7, case 3: a timer cycle before a sequence the gate
  # expects to be refused. Only a converged tick used to be reclassified,
  # so the refusal passed as the gate's own.
  discard producer.publish(PublishSpec(sequence: 7, profileText:
    "systemd.systemUnit {\n  name = \"a9-refused.service\"\n  content = " &
    "\"[Service]\\nUser=root\\nExecStart=/bin/true\\n\"\n}\n"))
  discard g.exec("rm -f " & TickStatus)
  g.fireTimerOnce("[ -e " & TickStatus & " ]")
  let tr = g.tickUnits()
  record["refusedTick"] = %($tr)
  step("a cycle before a refused sequence is named, whatever the outcome",
       tr.outcome == "timer-cycle-intervened", $tr)

suite Gate:
  test "a tick observes a cycle it started, after the publish":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
