## Gate ``e2e_addon_store_is_read_only_to_everything_else`` (milestone A9;
## spec §10.2; threat model G11, DET-AO-5).
##
## First half: on a bootstrapped add-on host, root outside the apply unit
## -- an operator's shell, and a service the host's systemd runs -- cannot
## create, modify or unlink anything under ``/repro/store``: the store is a
## read-only bind (``repro-store.mount``), and only a process that enters
## its own mount namespace and remounts the bind there (the apply unit's
## private writable view) can write it. The bytes of the file the attempts
## aim at are unchanged afterwards.
##
## Second half: a store path corrupted between the switch's realise step and
## its flip makes the switch refuse. The apply unit is paused (seam build)
## after step 2; the new generation's static tree -- realised in step 1,
## about to be flipped to in step 3 -- has a byte appended through a
## private writable view; on resume the switch refuses with
## ``EAddOnStoreChanged``, ``/etc/repro/static`` still names the previous
## tree and the managed file keeps its previous content.
##
## Falsifying mutations (``REPRO_ADDON_MUTATION=``):
## - ``store-mount-writable``: generation 0's store mount is a plain bind,
##   not read-only; root's writes succeed and the first half is red (the
##   mutation the milestone names);
## - ``flip-skips-store-recheck``: the switch does not re-verify the store
##   before its flip; the corrupted tree is activated and the second half
##   is red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (seam build).
##
## *Mocking.* None: real units, a real switch, real mounts.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_store_is_read_only_to_everything_else"
  Managed = "/etc/repro/a9-ro"
  PendingMarker = "/var/lib/repro/system/addon/pending"

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: canonicalFile(Managed, "one\n")))
  let t1 = g.tickUnits()
  step("the first generation applies", t1.outcome == "aoApplied", $t1)

  # --- First half: root outside the apply unit cannot write the store.
  let opts = g.exec("findmnt -n -o OPTIONS --target /repro/store").stdout.strip()
  record["storeMountOptions"] = %opts
  let target = g.exec("ls -d /repro/store/prefixes/repro-addon/*/bin/repro " &
    "| head -1").stdout.strip()
  step("the add-on binary is in the store", target.len > 0, target)
  let before = g.exec("sha256sum " & target).stdout
  var attempts = newJObject()
  for (what, cmd) in [
      ("create", "touch /repro/store/a9-created"),
      ("create-dir", "mkdir /repro/store/prefixes/a9-dir"),
      ("modify", "printf x >> " & target),
      ("truncate", "truncate -s 0 " & target),
      ("chmod", "chmod 0777 " & target),
      ("unlink", "rm -f " & target),
      ("rename", "mv " & target & " " & target & ".moved"),
      ("from-a-service", "systemd-run --wait --pipe --quiet " &
        "-p DynamicUser=no /bin/sh -c 'touch /repro/store/a9-unit && " &
        "printf x >> " & target & "'")]:
    let r = g.exec(cmd)
    attempts[what] = %*{"exit": r.exitCode, "stderr": r.stderr.strip()}
    step("root's " & what & " under /repro/store fails", r.exitCode != 0,
         "exit " & $r.exitCode & " " & r.stdout & r.stderr)
  record["rootAttempts"] = attempts
  step("nothing was created", g.exec("test -e /repro/store/a9-created || " &
       "test -e /repro/store/prefixes/a9-dir || test -e /repro/store/a9-unit"
       ).exitCode != 0, "")
  step("the store file is unchanged", g.exec("sha256sum " & target).stdout ==
       before, before)

  # --- Second half: a corruption between realise and flip is refused.
  let staticBefore = g.exec("readlink /etc/repro/static").stdout.strip()
  g.armApplySeam("step-2")
  discard producer.publish(PublishSpec(sequence: 2,
    profileText: canonicalFile(Managed, "two\n")))
  g.startFetchNoWait()
  let paused = g.waitSeam(ApplySeamDir, "step-2")
  step("the switch paused after its pre-stop (step 2)", paused, "")
  if paused:
    let tree = g.exec("sed -n 's/^static\\t//p' " & PendingMarker).stdout.strip()
    record["realisedTree"] = %tree
    step("the pending marker names the realised tree",
         tree.startsWith("/repro/store/") and tree != staticBefore, tree)
    # A private writable view, as the apply unit's own: root that bothers to
    # remount can write the store; the switch must notice.
    let file = g.exec("find " & tree & " -type f | head -1").stdout.strip()
    let corrupt = g.exec("unshare --mount --propagation private /bin/sh -c " &
      quoteShell("mount -o remount,bind,rw /repro/store && printf tampered >> " &
                 file))
    step("the realised tree is corrupted through a private view",
         corrupt.exitCode == 0 and file.len > 0,
         file & " " & corrupt.stdout & corrupt.stderr)
    g.resumeSeam(ApplySeamDir)
  g.waitApplyIdle()
  let t2 = g.lastTick()
  record["corruptedTick"] = %($t2)
  step("the switch refuses the corrupted store path",
       t2.outcome != "aoApplied" and "EAddOnStoreChanged" in t2.message, $t2)
  step("/etc/repro/static still names the previous tree",
       g.exec("readlink /etc/repro/static").stdout.strip() == staticBefore, "")
  step("the managed file keeps the previous generation's content",
       g.exec("cat " & Managed).stdout == "one\n", "")

suite Gate:
  test "the store is read-only to everything but the apply unit":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
