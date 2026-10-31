## Gate ``e2e_addon_writes_never_follow_symlinks``.
##
## The system-file driver's write never follows a symbolic link on the
## target path (ReproOS Add-On Mode threat model T34, G29, the A4 half:
## the add-on's own writer was A3's). The collision observer refuses a
## link at plan time and again just before each write (A3's gate
## ``e2e_addon_symlink_on_target_path_is_refused``), so a link planted
## BEFORE an apply never reaches the writer. This gate reaches the writer
## directly: ``repro system addon selfcheck-write <path>`` runs the
## driver's write exactly as the switch's copy step does, with no plan and
## no collision pass, against
##
## - a target file that is a link to a file outside ``/etc``, and
## - a parent directory that is a link to a directory outside ``/etc``,
##
## and in both cases the write is refused naming the link and the link
## targets are byte-identical afterwards. A full apply with the same
## links planted is refused too, before anything is written.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=path-based-write-follows-links``):
## the pre-A4 writer, a path-based ``open``, writes through both links and
## the files outside ``/etc`` change: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_writes_never_follow_symlinks``).
## Bases: ``REPRO_ADDON_BASES`` (default here: debian-13-amd64,ubuntu-24.04-amd64).
##
## *Mocking.* None: a real filesystem as root, the real driver in the
## static add-on binary.

import std/[json, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  Profile = """addOn {
  managedEtcPrefixes = ["/etc/repro-fixture/", "/etc/repro-fixture-linked/"]
}

fs.systemFile {
  path = "/etc/repro-fixture/x.conf"
  content = "managed
"
}

fs.systemFile {
  path = "/etc/repro-fixture-linked/y.conf"
  content = "managed
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
    if not g.bootstrapAddon(repro, step): return fails
    # The links: a target file linked outside /etc, a parent directory
    # linked outside /etc.
    discard g.run("mkdir -p /tmp/outside/dir /etc/repro-fixture && " &
      "printf 'victim\\n' > /tmp/outside/victim && " &
      "ln -s /tmp/outside/victim /etc/repro-fixture/x.conf && " &
      "ln -s /tmp/outside/dir /etc/repro-fixture-linked")
    let victimBefore = g.sha256InGuest("/tmp/outside/victim")
    # The writer itself, with no plan in front of it.
    let w1 = g.exec(repro & " system addon selfcheck-write /etc/repro-fixture/x.conf")
    step("a target that is a link outside /etc is refused at write time, naming the link",
         w1.exitCode != 0 and "symbolic link" in w1.stderr and
         "/etc/repro-fixture/x.conf" in w1.stderr, "exit " & $w1.exitCode & "\n" & w1.stdout & w1.stderr)
    step("the file behind the link is byte-identical",
         g.sha256InGuest("/tmp/outside/victim") == victimBefore and
         g.run("cat /tmp/outside/victim") == "victim\n", "")
    let w2 = g.exec(repro & " system addon selfcheck-write /etc/repro-fixture-linked/y.conf")
    step("a parent directory that is a link outside /etc is refused at write time, naming the link",
         w2.exitCode != 0 and "symbolic link" in w2.stderr and
         "/etc/repro-fixture-linked" in w2.stderr, "exit " & $w2.exitCode & "\n" & w2.stdout & w2.stderr)
    step("nothing was written through the linked directory",
         g.exec("test ! -e /tmp/outside/dir/y.conf").exitCode == 0,
         g.run("ls -la /tmp/outside/dir"))
    # Vacuity guard: the same writer succeeds on an honest path.
    let w3 = g.exec(repro & " system addon selfcheck-write /etc/repro-fixture/honest.conf")
    step("vacuity guard: the writer writes an honest path",
         w3.exitCode == 0 and g.run("cat /etc/repro-fixture/honest.conf") == "repro-addon selfcheck-write\n",
         w3.stdout & w3.stderr)
    discard g.run("rm -f /etc/repro-fixture/honest.conf")
    # The full apply: refused before anything is written (the observer).
    let f = g.takeFingerprint(repro)
    let ap = g.applyProfile(repro, "links", Profile)
    step("a full apply with the links planted is refused",
         ap.exitCode == 2 and "symbolic link" in ap.stderr, ap.stdout & ap.stderr)
    let same = identityReport(f, g.takeFingerprint(repro))
    step("the refused apply wrote nothing", same.ok and
         g.sha256InGuest("/tmp/outside/victim") == victimBefore, same.text)
    discard g.run("rm -f /etc/repro-fixture/x.conf /etc/repro-fixture-linked; rmdir /etc/repro-fixture; rm -rf /tmp/outside")
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
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

suite "e2e_addon_writes_never_follow_symlinks":
  test "a managed write refuses a link on its path at write time":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_writes_never_follow_symlinks)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_writes_never_follow_symlinks",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_writes_never_follow_symlinks", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
