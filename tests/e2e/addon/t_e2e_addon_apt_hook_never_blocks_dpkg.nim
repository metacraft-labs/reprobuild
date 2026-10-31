## Gate ``e2e_addon_apt_hook_never_blocks_dpkg`` (milestone A10; spec §7.8;
## threat model G19, T24, T39).
##
## ``apt-get install -y`` of an ``equivs`` package must succeed in each of
## three fault states injected under the hook, and record each:
##
## - *removed*: the verify binary is gone (an empty directory is bind-mounted
##   over the store directory that holds it) -> ``verify-missing``;
## - *fails*: the binary exits 1 -> ``verify-failed``;
## - *hangs*: the binary ignores SIGTERM, starts a grandchild and never
##   returns -> ``verify-timeout``; apt completes within the hook's timeout
##   (60 s) plus 60 s, and nothing of the hung process group is left (the
##   grandchild included: uutils' ``timeout`` would leave it on 26.04).
##
## A positive control first: with the real binary the same install succeeds
## and records nothing.
##
## *Falsifying mutations* (``REPRO_ADDON_MUTATION``):
## ``apt-hook-without-timeout`` -- the hang case hangs apt past the gate's
## deadline (``HangDeadlineSec``); ``apt-hook-without-exit0`` -- the failing
## (and the hung) case fails apt. Each turns the gate red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_apt_hook_never_blocks_dpkg``).
##
## *Mocking.* The three faults replace the verify binary with a stand-in
## (bind mounts, undone after each case): the property under test is the
## hook's handling of whatever process it starts, and a fault is exactly a
## binary that is missing, fails or hangs. apt, dpkg and the hook are real.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./snapshot_mirror
import ./upgrade_support

const
  Gate = "e2e_addon_apt_hook_never_blocks_dpkg"
  HookTimeoutSec = 60
  HangBoundSec = HookTimeoutSec + 60     ## the milestone's bound
  HangDeadlineSec = 300                  ## the gate gives up on apt here
  Snapshot = "20261028T000000Z"

proc hookExe(g: Guest): string =
  g.run("sed -n 's/.*r=\\([^;]*\\);.*/\\1/p' /etc/apt/apt.conf.d/90repro-addon").strip()

proc runBase(m: SnapshotMirror; b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    m.setTimestamp(Snapshot)
    g = newMirroredGuest(b, m)
    g.boot()
    g.prepareMirroredBase(m)
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    g.installEquivs()
    let deb = g.buildEquivsPackage("repro-fixture-hook", "1.0",
      @[(name: "readme", content: "hook fixture\n",
         destDir: "/usr/share/repro-fixture-hook")])
    if not g.bootstrapAddon(repro, step): return fails
    let exe = g.hookExe()
    step("the hook names the add-on's binary in the store",
         exe.startsWith("/repro/store/"), exe)
    discard g.run("mkdir -p /root/fault-empty; " &
      "printf '#!/bin/sh\\necho forced failure >&2\\nexit 1\\n' > /root/fault-fail; " &
      "printf '#!/bin/sh\\ntrap \"\" TERM\\nsleep 1717 &\\nwhile :; do sleep 1; done\\n' > /root/fault-hang; " &
      "chmod 0755 /root/fault-fail /root/fault-hang")
    proc install(name: string; deadline: int): tuple[code: int; secs: float; output: string] =
      let t0 = epochTime()
      let r = g.exec("export DEBIAN_FRONTEND=noninteractive; apt-get install -y " &
        "--reinstall " & deb & " < /dev/null 2>&1", timeoutSec = deadline)
      (r.exitCode, epochTime() - t0, r.stdout & r.stderr)
    proc logLines(): seq[string] =
      for l in g.exec("cat /var/lib/repro/system/addon/apt-hook.log 2>/dev/null").stdout.splitLines():
        if l.strip().len > 0: result.add(l)

    # Positive control.
    var n = logLines().len
    let c = install("control", 600)
    step("control: apt-get install succeeds with the real binary",
         c.code == 0, c.output)
    step("control: the hook ran and recorded no fault",
         "repro-addon apt hook: ok" in c.output and logLines().len == n, c.output)

    type Fault = tuple[name, setup, expect: string]
    let faults: seq[Fault] = @[
      (name: "removed", setup: "mount --bind /root/fault-empty " & parentDir(exe),
       expect: "verify-missing"),
      (name: "fails", setup: "mount --bind /root/fault-fail " & exe,
       expect: "verify-failed exit=1"),
      (name: "hangs", setup: "mount --bind /root/fault-hang " & exe,
       expect: "verify-timeout")]
    var timings = newJObject()
    for f in faults:
      n = logLines().len
      discard g.run(f.setup)
      let ok0 = f.name != "removed" or g.exec("test -x " & exe).exitCode != 0
      step(f.name & ": vacuity guard: the fault is in place", ok0, "")
      let r = install(f.name, HangDeadlineSec)
      timings[f.name] = %r.secs
      step(f.name & ": apt-get install succeeds", r.code == 0,
           "exit " & $r.code & " after " & $r.secs & " s\n" & r.output)
      if f.name == "hangs":
        step("hangs: apt completed within the timeout plus 60 s",
             r.code == 0 and r.secs <= HangBoundSec.float,
             $r.secs & " s (bound " & $HangBoundSec & " s)")
        step("hangs: nothing of the hung verification is left",
             # The bracket keeps pgrep from matching this shell's own line.
             g.exec("pgrep -f '[s]ystem addon verify --after-dpkg' || " &
                    "pgrep -f '[s]leep 1717' || ls /run/repro-addon-hook.* 2>/dev/null").exitCode != 0,
             g.exec("ps axf").stdout)
      let lines = logLines()
      step(f.name & ": the event is recorded (" & f.expect & ")",
           lines.len > n and f.expect in lines[^1], lines.join("\n"))
      step(f.name & ": the event is in the journal",
           f.expect.split(' ')[0] in g.exec("journalctl -o cat --no-pager " &
             "-t repro-addon-apt-hook").stdout, "")
      discard g.exec("umount " & (if f.name == "removed": parentDir(exe) else: exe))
    record["installSeconds"] = timings
    let v = g.exec(repro & " system addon verify")
    step("after the faults: verify reports ok", v.exitCode == 0, v.stdout & v.stderr)
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

suite Gate:
  test "the apt hook never fails or stalls dpkg":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_apt_hook_never_blocks_dpkg)")
    else:
      let m = startSnapshotMirror(Snapshot)
      var failures: seq[string]
      try:
        for b in selectedBases():
          let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
            "backend": "qemu", "mutation": mutation(), "reprobuild": gitHead(),
            "started": $now().utc, "snapshot": Snapshot}
          let f = runBase(m, b, record)
          record["verdict"] = %(if f.len == 0: "green" else: "red")
          record["finished"] = %($now().utc)
          echo "record: ", writeRecord(Gate, record)
          failures.add(f)
      finally:
        m.stop()
      for f in failures: echo "FAIL ", f
      check failures.len == 0
