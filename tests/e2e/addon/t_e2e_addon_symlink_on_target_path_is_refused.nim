## Gate ``e2e_addon_symlink_on_target_path_is_refused``.
##
## A root write that follows a symbolic link lands wherever the link points
## (threat model T34, G29). The collision observer therefore ``lstat``s
## every component of a target path at plan time and refuses a path with a
## link on it, naming the link, before anything is written. Two fixtures on
## each base:
##
## - a managed-prefix directory that is a link to ``/usr/lib/...``
##   (``/etc/repro-fixture-link -> /usr/lib/repro-fixture-target``), with a
##   resource below it;
## - the distribution's own ``/etc/os-release -> ../usr/lib/os-release``,
##   declared as a resource.
##
## Each is refused with the link named; the fingerprint is unchanged and the
## link targets are byte-identical afterwards.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=observer-checks-path-text-only``):
## an observer that looks at the path's text only. The first fixture is then
## let through, the apply writes ``/usr/lib/repro-fixture-target/x.conf``
## through the link, and the gate goes red; the second is refused for the
## wrong reason (package ownership), red too.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_symlink_on_target_path_is_refused``).
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  LinkedDir = """addOn {
  managedEtcPrefixes = ["/etc/repro-fixture-link/"]
}

fs.systemFile {
  path = "/etc/repro-fixture-link/x.conf"
  content = "through the link
"
}
"""
  OsRelease = """addOn {
  managedEtcPrefixes = ["/etc/os-release"]
}

fs.systemFile {
  path = "/etc/os-release"
  content = "ID=repro-fixture
"
}
"""

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
    step("vacuity guard: /etc/os-release is a link on this base",
         g.sha256InGuest("/etc/os-release") == "link", "")
    discard g.run("mkdir -p /usr/lib/repro-fixture-target && " &
                  "ln -s /usr/lib/repro-fixture-target /etc/repro-fixture-link")
    let fBase = g.takeFingerprint(repro)
    sleep(20_000)
    let det = identityReport(fBase, g.takeFingerprint(repro))
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails
    if not g.bootstrapAddon(repro, step): return fails
    let f = g.takeFingerprint(repro)
    let l = g.ledgerOf()
    let osReleaseBefore = g.sha256InGuest("/usr/lib/os-release")

    let a1 = g.applyProfile(repro, "linked-dir", LinkedDir)
    step("a linked managed-prefix directory is refused, naming the link",
         a1.exitCode == 2 and "/etc/repro-fixture-link" in a1.stderr and
         "symbolic link" in a1.stderr,
         "exit " & $a1.exitCode & "\n" & a1.stdout & a1.stderr)
    step("nothing was written through the link",
         g.run("ls -A /usr/lib/repro-fixture-target").strip().len == 0 and
         identityReport(f, g.takeFingerprint(repro)).ok and g.ledgerOf() == l, "")
    let p1 = g.planProfile(repro, "linked-dir-plan", LinkedDir)
    step("the plan refuses it the same way", p1.exitCode == 2 and
         "symbolic link" in p1.stderr, p1.stdout & p1.stderr)

    let a2 = g.applyProfile(repro, "os-release", OsRelease)
    step("/etc/os-release (a link) is refused, naming the link",
         a2.exitCode == 2 and "/etc/os-release" in a2.stderr and
         "symbolic link" in a2.stderr,
         "exit " & $a2.exitCode & "\n" & a2.stdout & a2.stderr)
    step("/usr/lib/os-release is byte-identical and /etc/os-release still a link",
         g.sha256InGuest("/usr/lib/os-release") == osReleaseBefore and
         g.sha256InGuest("/etc/os-release") == "link" and
         identityReport(f, g.takeFingerprint(repro)).ok, "")

    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let ident = identityReport(fBase, g.takeFingerprint(repro))
    step("base fingerprint after uninstall == before bootstrap", ident.ok, ident.text)
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

suite "e2e_addon_symlink_on_target_path_is_refused":
  test "a symlinked component on a target path is refused at plan time":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_symlink_on_target_path_is_refused)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_symlink_on_target_path_is_refused",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_symlink_on_target_path_is_refused", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
