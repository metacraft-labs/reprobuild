## Gate ``e2e_addon_compiled_pin_carries_activity_selection`` (milestone
## A12; ReproOS Add-On Mode §8.2, §13 decisions 28 and 34).
##
## A manifest that ships its profile as source carries the producer's
## compile pin (RDMF v3 flags bit 1), and with it the system selection the
## producer compiled for (flags bit 2): the mode and the activities the
## target's host-registry entry selects. The host's agent compiles with
## exactly that selection and applies the result only when it reproduces
## the signed digest, which binds the selection too.
##
## The source declares a profile-level file and two activities, `web` and
## `backup`, each with one file.
##
## 1. The producer pins its compile for `addOn` with `backup` selected. The
##    host applies the profile-level file and backup's file, and not
##    web's: a non-default selection, reached through a compile on the
##    host.
## 2. The producer signs a pin that names `web` but carries the digest of
##    its compile for `backup`, so the selection does not match what was
##    compiled. The host compiles for `web` (the signed selection), gets
##    another output and refuses with a compiled-profile digest mismatch.
##    Nothing changes.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=compile-pin-drops-selection``,
## a build of the add-on whose agent neither passes the selection to the
## compile nor binds it into the digest): the host compiles `default` only
## and case 1 fails.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_ADDON_ENGINE_CLOSURE`` (the
## full engine of this tree, the guest's profile compiler and the
## producer's). amd64 bases.
##
## *Mocking.* None: the real engine compiles on both sides, the real units.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip
import repro_deploy_agent/manifest

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_compiled_pin_carries_activity_selection"
  Compiler = "/usr/local/bin/repro-profile-compiler"
  Source = "import repro_profile\n\nprofile \"a12Selection\":\n" &
    "  activity web:\n    resources:\n" &
    "      fsSystemFile(path = \"/etc/repro/a12-web\", content = \"web\\n\",\n" &
    "        address = \"a12Web\")\n" &
    "  activity backup:\n    resources:\n" &
    "      fsSystemFile(path = \"/etc/repro/a12-backup\", content = \"backup\\n\",\n" &
    "        address = \"a12Backup\")\n" &
    "  resources:\n" &
    "    fsSystemFile(path = \"/etc/repro/a12-base\", content = \"base\\n\",\n" &
    "      address = \"a12Base\")\n"

let engine = getEnv("REPRO_ADDON_ENGINE_CLOSURE")

proc installEngine(g: Guest) =
  g.installEngineClosure(engine)
  discard g.run("ln -sfn " & engine & "/bin/reprobuild " & Compiler)

proc present(g: Guest; path: string): bool = g.exec("test -e " & path).exitCode == 0

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  # 1. The selection the producer signs is the one the host compiles.
  let pin = producerCompile(engine, Source, systemMode = "addOn",
                            systemActivities = @["backup"])
  record["pin"] = %*{"digest": pin.digest, "mode": pin.systemMode,
                     "activities": pin.systemActivities}
  discard producer.publish(PublishSpec(sequence: 1, profileText: Source,
    compiledProfile: pin))
  let t1 = g.tickUnits(timeoutSec = 2400)
  step("a host compiling signed source with a non-default selection gets it",
       t1.outcome == "aoApplied" and g.present("/etc/repro/a12-base") and
       g.present("/etc/repro/a12-backup") and not g.present("/etc/repro/a12-web"),
       $t1 & "\n" & t1.fetchLog & t1.applyLog)
  # 2. A pin whose selection is not what its digest was compiled for.
  var lying = pin
  lying.systemActivities = @["web"]
  discard producer.publish(PublishSpec(sequence: 2, profileText: Source,
    compiledProfile: lying))
  let t2 = g.tickUnits(timeoutSec = 2400)
  step("a selection that does not match the signed digest is refused",
       t2.outcome != "aoApplied" and "digest mismatch" in t2.message and
       not g.present("/etc/repro/a12-web") and g.present("/etc/repro/a12-backup"),
       $t2 & "\n" & t2.fetchLog & t2.applyLog)

suite Gate:
  test "a compiled-profile pin carries the system-activity selection":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif engine.len == 0:
      echo "FAIL: REPRO_ADDON_ENGINE_CLOSURE is not set"
      check false
    else:
      check gateMain(Gate, body, diskGiB = 20,
        extraFlags = " --profile-compiler " & Compiler,
        beforeBootstrap = installEngine).len == 0
