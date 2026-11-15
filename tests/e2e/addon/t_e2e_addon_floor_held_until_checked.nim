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
## Generation D (§13 decision 151): the triggers of held units are stopped
## for the hold. D changes the template again; the gate pauses D's switch at
## ``step-4``, with every hold in place, and fires a burst of 300
## connections at the unchanged ``Accept=yes`` socket (systemd's trigger
## rate limit for such a socket is 200 in 2 s, systemd.socket(5)), then
## requires the socket active after the switch and an instance to run on a
## connection. Falsifying build: ``REPRO_ADDON_MUTATION=triggers-left-running``
## (the socket left running under the hold): each connection starts an
## instance the hold refuses, the burst trips the rate limit, and the socket
## stays failed (``trigger-limit-hit``) after the switch -- red.
##
## Generation C (§13 decision 136): the holds go in before the privileged
## set, not at step 6. C changes the template again; the gate pauses C's
## switch at ``step-4`` -- after the drivers wrote the template and their
## own reloads loaded it, before step 6 -- and requires the hold loaded and
## no instance run by the socket or by ``systemctl start``. Falsifying
## build: ``REPRO_ADDON_MUTATION=start-holds-after-driver-writes`` (the
## holds only at step 6): the instance runs on C's unchecked definition in
## that window -- red. Generation B's window, after step 6's reload, is held
## under that build too, so its steps stay green.
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
      # Generation C: the window between the drivers' reloads and step 6.
      let beforeC = g.started()
      let pc = g.startSwitchPausedAt(repro, "c", profile(binary, "A9 hold C"),
                                     "step-4")
      step("generation C pauses after the drivers' writes, before step 6",
           pc.exitCode == 0, pc.stdout & pc.stderr)
      if pc.exitCode == 0:
        let loaded = g.exec("systemctl show -p Description -p DropInPaths " &
                            "a9h@probe.service").stdout
        record["decision136Loaded"] = %loaded
        step("generation C's definition is loaded by the drivers' reloads " &
             "(the case's premise)", "A9 hold C" in loaded, loaded)
        step("decision 136: the hold is loaded before step 6",
             "zz-repro-addon-floor-hold.conf" in loaded, loaded)
        discard g.exec("timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/" &
                       $Port & "' 2>/dev/null; systemctl start " &
                       "a9h@manual.service 2>&1; sleep 3; true")
        let inWindowC = g.started()
        record["decision136"] = %*{"startedBefore": beforeC,
                                   "startedInWindow": inWindowC}
        step("decision 136: the floored service did not start between the " &
             "drivers' reloads and step 6 (socket, systemctl start)",
             inWindowC == beforeC, beforeC & " -> " & inWindowC)
        let resC = g.resumeSwitch()
        step("generation C applies once checked", resC.exitCode == 0,
             resC.stdout & resC.stderr)
        step("no hold is left after C", g.exec("ls /run/systemd/system/" &
             "a9h@.service.d/zz-repro-addon-floor-hold.conf 2>/dev/null").
             stdout.strip() == "", "")
        discard g.exec("timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/" &
                       $Port & "' 2>/dev/null; sleep 3; true")
        step("and the service runs after C", g.started() != inWindowC,
             g.started())
        # Generation D: a burst at the socket while the switch holds its
        # service (§13 decision 151).
        let beforeD = g.started()
        let pd = g.startSwitchPausedAt(repro, "d", profile(binary, "A9 hold D"),
                                       "step-4")
        step("generation D pauses after the drivers' writes, before step 6",
             pd.exitCode == 0, pd.stdout & pd.stderr)
        if pd.exitCode == 0:
          let during = g.exec("for i in $(seq 300); do timeout 2 bash -c " &
            "'exec 3<>/dev/tcp/127.0.0.1/" & $Port & "' 2>/dev/null & done; " &
            "wait; sleep 2; ls /run/systemd/system/a9h.socket.d 2>&1 | tr '\\n' ' '; " &
            "echo; systemctl show -p ActiveState -p Result -p NAccepted " &
            "-p NRefused a9h.socket | tr '\\n' ' '").stdout.strip()
          let resD = g.resumeSwitch()
          step("generation D applies once checked", resD.exitCode == 0,
               resD.stdout & resD.stderr)
          let afterD = g.exec("systemctl show -p ActiveState -p Result " &
            "a9h.socket | tr '\\n' ' '").stdout.strip()
          discard g.exec("timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/" &
                         $Port & "' 2>/dev/null; sleep 3; true")
          let ranD = g.started()
          let okD = "ActiveState=active" in afterD and
            "trigger-limit-hit" notin afterD and ranD != beforeD
          record["decision151Seam"] = %*{"during": during, "after": afterD,
            "startedBefore": beforeD, "startedAfter": ranD, "ok": okD}
          step("decision 151, add-on switch: an Accept=yes socket hit by a " &
               "burst of connections while the switch holds its service is " &
               "active after the switch, and an instance runs on a connection",
               okD, "during: " & during & "\nafter: " & afterD & "\nstarted " &
               beforeD & " -> " & ranD)
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
