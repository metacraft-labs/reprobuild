## Gate ``e2e_addon_write_time_recheck``.
##
## The collision observer runs at plan time and again immediately before
## each write (the ``PreWriteGuard``), and the objects a removal would
## delete are observed again immediately before the delete. What changes
## in between is refused, or left in place as drift. This gate makes that
## window deterministic: it runs a test-only build with a pause seam
## (``-d:reproAddonMutation=pause-before-write``: after the plan and its
## observations, before the first write, the apply blocks on the FIFO
## ``/run/repro-addon-test-seam/continue`` while that FIFO exists) and
## changes the host while the apply is paused:
##
## - **(a) a package installs a file at a planned path**: an ``equivs``
##   package shipping ``/etc/repro-fixture-rc/a.conf`` is installed while
##   the apply that plans to create that path is paused. The write is
##   refused ("ownership observation changed"), the apply exits non-zero
##   and the package's bytes stay.
## - **(b) a local diversion is planted** on a planned path
##   (``dpkg-divert --local --divert ... --add``). The write is refused
##   ("the diversion of ... changed") and nothing is written there.
## - **(c) an object due for removal is edited**: ``c.conf``, owned by the
##   ledger, leaves the profile; while the apply is paused it is replaced
##   by a hand-edited file. The removal leaves it in place as drift (exit
##   1, the ledger keeps the entry) instead of deleting the edit.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=pause-before-write-no-recheck``):
## the same seam with the write-time re-check not installed. (a) then
## overwrites the package's file, (b) writes through the new diversion's
## path, (c) deletes the hand edit: red.
##
## The default run (no ``REPRO_ADDON_MUTATION``) selects the
## ``pause-before-write`` build: the seam is the instrument of this gate,
## not a breakage. It is never part of a product build.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_write_time_recheck``).
##
## *Mocking.* None: real dpkg, a real equivs package, the real add-on
## binary; the seam only pauses it.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/[fingerprint, ledger]

import ./addon_testbed

const
  Dir = "/etc/repro-fixture-rc"
  SeamDir = "/run/repro-addon-test-seam"
  Prefix = """addOn {
  managedEtcPrefixes = ["/etc/repro-fixture-rc/"]
}
"""
  WithA = Prefix & """
fs.systemFile {
  path = "/etc/repro-fixture-rc/a.conf"
  content = "ours
"
}
"""
  WithB = Prefix & """
fs.systemFile {
  path = "/etc/repro-fixture-rc/b.conf"
  content = "ours
"
}
"""
  WithC = Prefix & """
fs.systemFile {
  path = "/etc/repro-fixture-rc/c.conf"
  content = "c
"
}
"""

proc listed(ledgerText, path: string): int =
  for e in parseLedger(ledgerText).entries:
    if e.path == path: inc result

proc pausedApply(g: Guest; repro, name, profile: string;
                 during: proc()): ExecOut =
  ## Start the apply with the seam's FIFO in place, wait until it reports
  ## the pause, run ``during``, release it and return its result.
  let p = g.putProfile(name, profile)
  discard g.run("rm -rf " & SeamDir & " && mkdir -p " & SeamDir &
                " && mkfifo " & SeamDir & "/continue")
  # Detached from the ssh session (setsid, every descriptor redirected),
  # so the exec returns while the apply runs on.
  discard g.run("rm -f /root/" & name & ".rc; setsid sh -c '" & repro &
    " infra apply --profile " & p & " > /root/" & name & ".out 2>&1; " &
    "echo $? > /root/" & name & ".rc' </dev/null >/dev/null 2>&1 &")
  let waited = g.exec("for i in $(seq 1 600); do test -e " & SeamDir &
    "/paused && exit 0; test -e /root/" & name & ".rc && exit 3; sleep 1; done; exit 2",
    timeoutSec = 700)
  if waited.exitCode == 0:
    during()
    discard g.run("echo go > " & SeamDir & "/continue")
  discard g.exec("for i in $(seq 1 1200); do test -e /root/" & name &
    ".rc && exit 0; sleep 1; done; exit 2", timeoutSec = 1300)
  discard g.exec("rm -rf " & SeamDir)
  let rc = g.exec("cat /root/" & name & ".rc").stdout.strip()
  result = ExecOut(exitCode: (try: parseInt(rc) except ValueError: -1),
                   stdout: g.exec("cat /root/" & name & ".out").stdout &
                     (if waited.exitCode != 0: "\n[the apply never paused: " &
                        $waited.exitCode & "]" else: ""),
                   stderr: "")

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    g.installEquivs()
    let pkg = g.buildEquivsPackage("repro-fixture-late", "1.0",
      @[(name: "a.conf", content: "theirs\n", destDir: Dir)])
    if not g.bootstrapAddon(repro, step): return fails
    discard g.run("mkdir -p " & Dir)

    # (a) A package installs a file at the planned path during the pause.
    let ra = g.pausedApply(repro, "late-package", WithA, proc() =
      discard g.run("export DEBIAN_FRONTEND=noninteractive; dpkg -i " & pkg &
                    " >/dev/null < /dev/null"))
    step("(a) a package's file appearing at a planned path refuses the write",
         ra.exitCode != 0 and "at write time" in ra.stdout and
         "ownership observation changed" in ra.stdout and
         g.run("cat " & Dir & "/a.conf") == "theirs\n" and
         g.sha256InGuest(Dir & "/a.conf") != "link",
         "exit " & $ra.exitCode & "\n" & ra.stdout)
    discard g.run("export DEBIAN_FRONTEND=noninteractive; dpkg -P repro-fixture-late >/dev/null; " &
                  "rm -f " & Dir & "/a.conf; mkdir -p " & Dir)

    # (b) A local diversion is planted on the planned path.
    let rb = g.pausedApply(repro, "late-diversion", WithB, proc() =
      discard g.run("dpkg-divert --local --divert " & Dir &
                    "/b.conf.elsewhere --add " & Dir & "/b.conf"))
    step("(b) a local diversion planted on a planned path refuses the write",
         rb.exitCode != 0 and "at write time" in rb.stdout and
         "the diversion of" in rb.stdout and
         g.sha256InGuest(Dir & "/b.conf") == "absent",
         "exit " & $rb.exitCode & "\n" & rb.stdout & "\n" & g.exec("ls -la " & Dir).stdout)
    discard g.exec("dpkg-divert --local --remove " & Dir & "/b.conf; rm -f " & Dir & "/b.conf")

    # (c) An object due for removal is edited during the pause.
    let rc0 = g.applyProfile(repro, "with-c", WithC)
    step("(c) c.conf is applied and ledgered", rc0.exitCode == 0 and
         listed(g.ledgerOf(), Dir & "/c.conf") == 1, rc0.stdout & rc0.stderr)
    let rc = g.pausedApply(repro, "remove-c", Prefix, proc() =
      discard g.run("rm -f " & Dir & "/c.conf && printf 'hand edit\\n' > " &
                    Dir & "/c.conf"))
    step("(c) an object edited after the plan is left in place as drift",
         rc.exitCode == 1 and "drift" in rc.stdout and
         g.run("cat " & Dir & "/c.conf") == "hand edit\n" and
         listed(g.ledgerOf(), Dir & "/c.conf") == 1,
         "exit " & $rc.exitCode & "\n" & rc.stdout)
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

suite "e2e_addon_write_time_recheck":
  test "what changes between the plan and the write is refused or kept":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_write_time_recheck)")
    else:
      # The seam build is this gate's instrument; the falsifying run names
      # the no-recheck build explicitly.
      if mutation().len == 0:
        putEnv("REPRO_ADDON_MUTATION", "pause-before-write")
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_write_time_recheck",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_write_time_recheck", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
