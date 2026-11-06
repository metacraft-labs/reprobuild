## Gate ``e2e_addon_custody_crash_points`` (milestone A11; ReproOS Add-On
## Mode §10.2 "Custody", §13 decision 47; threat model DET-AO-5; A11 code
## review finding 10).
##
## A recovery of an altered store object is interrupted by a hard reset at
## each of its crash points, and the host must lose neither the altered
## bytes nor the record of them, and must still recover the object:
##
## - ``custody-after-move-aside``: a file of the generation-0 files prefix
##   (the store file behind ``/etc/profile.d/repro-addon.sh``) is altered;
##   the next switch renames it aside within the store and is reset before
##   it is filed. The expected digest was kept (it is dropped only once a
##   rebuild is verified), so a later switch re-realises the prefix; the
##   object left aside is filed as an evidence entry and recorded
##   ``store-recovery-interrupted``.
## - ``custody-before-record``: the same, reset after the rebuild was
##   verified and the entry filed, before its ``store-recovered`` record:
##   the next switch writes that record, exactly once.
## - ``tree-after-move-aside``: a file of a committed static tree (the
##   previous generation's ``/etc`` tree) is altered; the switch back to
##   that generation stages and hashes the replacement first, renames the
##   altered tree aside and is reset there. As above, it is filed and
##   recorded ``store-recovery-interrupted``, and the tree is realised.
## - ``tree-before-record``: reset after the replacement is published and
##   the entry filed, before the record: written by the next switch, once.
##
## After each reset the guest boots, the re-assert unit runs, and a fresh
## switch to the generation must commit, with the object holding its
## original bytes, nothing left under the store's ``tmp/custody-aside``,
## every evidence entry recorded (its ``recorded`` stamp), and the altered
## bytes in a new entry.
##
## Falsifying mutations (each red at the points named):
## ``custody-forgets-before-rebuild`` (``custody-after-move-aside``: the
## expected digest is gone with the object, and every later switch
## refuses), ``custody-ignores-leftovers`` (both ``*-after-move-aside``
## points: the altered object is never filed), ``custody-skips-unrecorded``
## (both ``*-before-record`` points: the record is never written),
## ``custody-rebuild-unsynced`` (``custody-before-record``: the rebuilt
## prefix is not on the disk after the reset, so the next switch files it
## as a second alteration).
## ``REPRO_ADDON_CRASH_POINTS`` (comma separated) selects points.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``; needs the seam build and a QEMU
## guest (``hardReset``).
##
## *Mocking.* None: the alteration is a root write through a private
## writable view of the store, as in ``e2e_addon_store_custody``; the reset
## is QEMU's ``system_reset``.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_custody_crash_points"
  Managed = "/etc/repro/a11-crash"
  Evidence = "/var/lib/repro/system/addon/store-evidence"
  Records = "/var/lib/repro/system/addon/evidence"
  Aside = "/repro/store/tmp/custody-aside"
  Points = ["custody-after-move-aside", "custody-before-record",
            "tree-after-move-aside", "tree-before-record"]

proc prof(note: string): string = canonicalFile(Managed, note & "\n")

proc inStore(g: Guest; script: string): ExecOut =
  ## ``script`` as root through a private writable view of the store.
  g.exec("unshare --mount --propagation private /bin/sh -c " &
    quoteShell("mount -o remount,bind,rw /repro/store && " & script))

proc sha(g: Guest; path: string): string =
  g.exec("sha256sum " & quoteShell(path) & " | cut -d' ' -f1").stdout.strip()

proc count(g: Guest; cmd: string): int =
  let o = g.exec(cmd & " 2>/dev/null").stdout.strip()
  if o.len == 0: 0 else: o.splitLines().len

proc entries(g: Guest): int = g.count("ls -1d " & Evidence & "/*/")
proc recordsOf(g: Guest; kind: string): int =
  g.count("ls -1 " & Records & "/*-" & kind & ".json")

proc treeHolding(g: Guest; content: string): string =
  ## The static tree (``repro-addon-etc`` prefix) whose file holds exactly
  ## ``content``.
  let f = g.exec("grep -rlx " & quoteShell(content) &
    " /repro/store/prefixes/repro-addon-etc/ 2>/dev/null | head -1").stdout.strip()
  if f.len == 0: return ""
  let parts = f.split('/')
  parts[0 .. 5].join("/")       # /repro/store/prefixes/repro-addon-etc/<ver>

proc selected(): seq[string] =
  let env = getEnv("REPRO_ADDON_CRASH_POINTS")
  for p in Points:
    if env.len == 0 or p in env.split(','): result.add(p)

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let a0 = g.applyProfile(repro, "crash-one", prof("tree-one"))
  step("generation one commits", a0.exitCode == 0, a0.stdout & a0.stderr)
  let treeOne = g.treeHolding("tree-one")
  step("generation one's static tree is in the store", treeOne.len > 0, "")
  let a1 = g.applyProfile(repro, "crash-two", prof("tree-two"))
  step("generation two commits", a1.exitCode == 0, a1.stdout & a1.stderr)
  var outcomes = newJObject()
  var n = 0
  for point in selected():
    inc n
    let src = g.exec("ls -d /repro/store/prefixes/repro-addon-files/*/" &
      g.sha("/etc/profile.d/repro-addon.sh") & " 2>/dev/null | head -1").stdout.strip()
    let isTree = point.startsWith("tree-")
    # The alteration, then a switch that must recover it.
    var target, profile: string
    if isTree:
      # On generation two, generation one's tree is the previous one: the
      # switch back to generation one realises it again.
      if n > 1:
        discard g.applyProfile(repro, "crash-away-" & $n, prof("tree-two"))
      target = treeOne
      profile = prof("tree-one")
      let t = g.inStore("printf planted >> " &
        quoteShell(target & "/" & Managed[5 .. ^1]))
      step(point & ": a file of generation one's tree changed",
           t.exitCode == 0 and target.len > 0, t.stderr)
    else:
      target = parentDir(src)
      profile = prof("crash-" & $n)
      let t = g.inStore("printf planted >> " & quoteShell(src))
      step(point & ": the store file behind /etc/profile.d/repro-addon.sh " &
           "changed", src.len > 0 and t.exitCode == 0, src & t.stderr)
    let entriesBefore = g.entries()
    let interruptedBefore = g.recordsOf("store-recovery-interrupted")
    let recoveredBefore = g.recordsOf("store-recovered")
    g.holdWriteback()
    let paused = g.startSwitchPausedAt(repro, "crash-" & point, profile, point)
    step(point & ": the switch reached the point", paused.exitCode == 0,
         paused.stdout & paused.stderr)
    if paused.exitCode != 0: continue
    g.hardResetAfterSettle()
    g.boot()
    let ra = g.waitReasserted()
    let after = g.applyProfile(repro, "after-" & point, profile)
    let entriesNow = g.entries()
    let interrupted = g.recordsOf("store-recovery-interrupted") - interruptedBefore
    let recovered = g.recordsOf("store-recovered") - recoveredBefore
    outcomes[point] = %*{"apply": after.exitCode, "entries": entriesNow -
      entriesBefore, "interrupted": interrupted, "recovered": recovered,
      "reassert": ra.splitLines()[max(0, ra.splitLines().len - 5) .. ^1]}
    step(point & ": after the reset a switch to the generation commits",
         after.exitCode == 0, after.stdout & after.stderr)
    let holds =
      if isTree:
        g.exec("cat " & quoteShell(target & "/" &
          Managed[5 .. ^1])).stdout == "tree-one\n"
      else:
        g.exec("test -f " & quoteShell(src)).exitCode == 0 and
          g.sha(src) == extractFilename(src)
    step(point & ": the object holds its original bytes", holds, target)
    step(point & ": nothing is left aside in the store",
         g.count("ls -1 " & Aside) == 0, g.exec("ls -la " & Aside).stdout)
    step(point & ": the altered bytes are in a new evidence entry",
         entriesNow == entriesBefore + 1 and g.exec("grep -rl planted " &
           Evidence).stdout.strip().len > 0,
         g.exec("ls -l " & Evidence).stdout)
    step(point & ": every evidence entry is recorded",
         g.count("for d in " & Evidence & "/*/; do test -e $d/recorded || " &
           "echo $d; done") == 0, "")
    if point.endsWith("-after-move-aside"):
      step(point & ": the interrupted recovery is recorded",
           interrupted == 1, $interrupted)
    else:
      step(point & ": store-recovered is recorded exactly once",
           recovered == 1 and interrupted == 0,
           $recovered & " recovered, " & $interrupted & " interrupted")
  record["outcomes"] = outcomes

suite Gate:
  test "a custody recovery reset at each crash point loses nothing":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
