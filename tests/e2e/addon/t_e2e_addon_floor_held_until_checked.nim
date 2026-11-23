## Gate ``e2e_addon_floor_held_until_checked`` (milestone A9, review round
## 4, finding 7; spec §10.1 *Amended 2026-11-05*).
##
## Between step 6's daemon-reload and the effective-unit check, systemd
## already has the generation's definitions loaded, and anything that can
## start a unit -- a socket, a timer, a path unit, D-Bus, a ``Wants=``, an
## operator's ``systemctl start`` -- would start a floored unit on
## definitions nothing has checked yet. The switch closes that window: it
## writes a runtime drop-in with an assertion that always fails
## (``effective_floor.StartHoldText``) for every floored unit before the
## reload, and removes it, with a second reload, only once the check
## passes.
##
## The case: generation A installs a socket (``Accept=yes``) and the
## floored template service it activates, one instance per connection; the
## socket listens. Generation B changes the template. The gate pauses B's
## switch at the seam just before the check (``floor-check``), connects to
## the socket and runs ``systemctl start`` on an instance, and requires
## that no instance ran in the window (the journal of ``a9h@*`` gains no
## line). After the switch resumes, B applies and a connection runs an
## instance again.
##
## Falsifying build: ``REPRO_ADDON_MUTATION=floor-start-unheld`` (no hold):
## the service runs in the window -- red.
##
## Needs the seam build: ``REPRO_ADDON_TEST_SEAMS=1``. Opt-in:
## ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the real add-on and the base's own systemd.

import std/[json, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  Gate = "e2e_addon_floor_held_until_checked"
  Port = 18493

proc profile(binary, description: string): string =
  "addOn {\n  managedEtcPrefixes = []\n}\n\n" &
    "systemd.systemUnit {\n  name = \"a9h.socket\"\n  content = \"[Unit]\n" &
    "Description=A9 hold socket\n\n[Socket]\nListenStream=127.0.0.1:" & $Port &
    "\nAccept=yes\n\n[Install]\nWantedBy=sockets.target\n\"\n  enabled = true\n}\n" &
    "systemd.systemUnit {\n  name = \"a9h@.service\"\n  content = \"[Unit]\n" &
    "Description=" & description & "\n\n[Service]\nType=oneshot\nUser=a9h\n" &
    "ExecStart=" & binary & " --version\n\"\n  enabled = false\n}\n"

proc started(g: Guest): string =
  ## How many lines the instances have logged (each run prints one).
  discard g.exec("journalctl --sync 2>/dev/null; sleep 1; true")
  ## Only the service's own lines (identifier ``repro``), not the
  ## manager's ("Started ...", "Assertion failed ...").
  g.exec("journalctl -q -o cat --no-pager -u 'a9h@*' -t repro | grep -c . ; " &
         "true").
    stdout.strip()

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
    discard g.run("useradd -r -M -s /usr/sbin/nologin a9h")
    let binary = g.run("ls -d /repro/store/prefixes/repro-addon/*/bin/repro " &
                       "| head -1").strip()
    var r = g.applyProfile(repro, "a", profile(binary, "A9 hold A"))
    step("generation A applies", r.exitCode == 0, r.stdout & r.stderr)
    step("its socket listens",
         g.exec("systemctl is-active a9h.socket").stdout.strip() == "active", "")
    # The service ran once already (a connect), so the window shows as a
    # change of its last start.
    discard g.exec("timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/" & $Port &
                   "' 2>/dev/null; sleep 2; true")
    let before = g.started()
    let p = g.startSwitchPausedAt(repro, "b", profile(binary, "A9 hold B"),
                                  "floor-check")
    step("generation B pauses before the effective-unit check",
         p.exitCode == 0, p.stdout & p.stderr)
    if p.exitCode == 0:
      step("the hold is loaded",
           "zz-repro-addon-floor-hold.conf" in g.exec("systemctl show -p " &
             "DropInPaths a9h@probe.service").stdout, "")
      discard g.exec("timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/" & $Port &
                     "' 2>/dev/null; systemctl start a9h@manual.service 2>&1; " &
                     "sleep 3; true")
      let inWindow = g.started()
      record["startedBefore"] = %before
      record["startedInWindow"] = %inWindow
      step("the floored service did not start in the window (socket, " &
           "systemctl start)", inWindow == before, before & " -> " & inWindow)
      let res = g.resumeSwitch()
      step("generation B applies once checked", res.exitCode == 0,
           res.stdout & res.stderr)
      step("no hold is left", g.exec("ls /run/systemd/system/a9h@.service.d/" &
           "zz-repro-addon-floor-hold.conf 2>/dev/null").stdout.strip() == "", "")
      discard g.exec("timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/" & $Port &
                     "' 2>/dev/null; sleep 3; true")
      step("and the service runs after", g.started() != inWindow, g.started())
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
  test "no floored unit starts before its effective configuration is checked":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif not testSeams():
      skip("needs the seam build: set REPRO_ADDON_TEST_SEAMS=1")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
