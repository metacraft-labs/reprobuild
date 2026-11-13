## Add-on VM gate: a floored generation applies again after what systemd
## and an operator do between applies, and a failed apply's revert never
## leaves the host pending (ReproOS Add-On Mode spec §10.1, the
## hardening floor; A9 review round 12).
##
## On each base, ``REPRO_A9R_ROUNDS`` times (default 1; the template case
## passed by chance on debian-12 before round 12, so its jobs run it
## three times):
##
## - **a template pulled in by ``Wants=``** with ``RuntimeDirectory=``
##   applies twice: what was absent at the check and exists after the
##   start is recorded, whenever systemd 252 stamps the instance's start
##   (§13 decision 82);
## - **its instance restarted outside a switch** (``systemctl restart``):
##   the next apply accepts the directory the restart made, judged by the
##   instance that ran, not by the observation instance (decision 82,
##   finding 4);
## - **a socket-activated service** with ``RuntimeDirectory=<stem>`` and a
##   listener at ``/run/<stem>/sock`` applies twice: the directory its
##   socket's start made is recorded for the service (finding 3), and once
##   the service has started outside a switch, the next apply accepts the
##   directory it was handed;
##
## Then once per base:
##
## - **a stopped unit** whose ``StateDirectory=`` its last run made again
##   applies; a tree made after that run ended is refused, and the refused
##   apply's revert commits with the unit held, the host not pending
##   (decision 83; spec §10.1 on a revert's floor check);
## - **a reused inode with a new birth time** on a 16-inode ext4 the guest
##   loop-mounts at ``/var/cache``: the kernel hands the number back, and
##   the next apply refuses the directory (decision 76, finding 7);
## - **the reviewer's link**: an activator whose listener lies below a
##   directory its service can write is refused; under the falsifying
##   build ``listener-below-writable-allowed`` it applies, the service's
##   account links ``/run/a9r-lr/sub`` to ``/run/udev``, a stop of the
##   socket unlinks udev's control socket, and the gate goes red
##   (decision 84). Destructive, so last.
##
## Falsifying builds (each red here): ``revert-refuses-on-floor``,
## ``same-identity-ignores-btime``, ``listener-below-writable-allowed``,
## ``dependency-starts-unrecorded``, ``observation-instance-judged-alone``.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the real add-on, the base's own systemd and kernel.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const Gate = "e2e_addon_floor_reapplies_after_restarts"
const Head = "addOn {\n  managedEtcPrefixes = []\n}\n\n"
const Pending = "/var/lib/repro/system/addon/pending"
const Record = "/var/lib/repro/system/addon/floor-created-dirs"

proc unitResource(name, service, binary: string; unitLines = "";
                  enabled = true; description = "A9 round 12"): string =
  ## A floored oneshot unit that stays active; a template, or a unit only
  ## its socket starts (``enabled = false``), is not enabled.
  let tmpl = name.contains("@.") or not enabled
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=" & description & "\n" & unitLines &
    "\n[Service]\nType=oneshot\nRemainAfterExit=yes\n" & service &
    "ExecStart=" & binary & " --version\n" &
    (if tmpl: "\"\n  enabled = false\n}\n"
     else: "\n[Install]\nWantedBy=multi-user.target\n\"\n  enabled = true\n}\n")

proc socketResource(name, body: string): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Socket]\n" &
    body & "\n[Install]\nWantedBy=sockets.target\n\"\n  enabled = true\n}\n"

proc rounds(): int =
  try: max(1, parseInt(getEnv("REPRO_A9R_ROUNDS", "1")))
  except ValueError: 1

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail[max(0, detail.len - 3000) .. ^1])
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    discard g.run("useradd -r -M -s /usr/sbin/nologin a9e")
    let binary = g.run("ls -d /repro/store/prefixes/repro-addon/*/bin/repro " &
                       "| head -1").strip()
    let control = Head & unitResource("a9r-control.service", "", binary)
    var r = g.applyProfile(repro, "control", control)
    step("a plain floored unit applies", r.exitCode == 0, r.stdout & r.stderr)
    proc notPending(after: string) =
      let p = g.exec("test -e " & Pending & " && cat " & Pending & "; true").stdout
      step("after " & after & ", no switch is pending", p.strip().len == 0, p)
    proc evidence(path, unit: string): string =
      g.exec("stat -c '%n %i %.9W' " & path & "; systemctl show " &
             "--timestamp=us+utc -p InvocationID -p InactiveExitTimestamp " &
             "-p ActiveState " & unit & "; cat " & Record).stdout
    var evidences = newJArray()
    for n in 1 .. rounds():
      let tag = " (round " & $n & ")"
      # The template, pulled in by the control unit (finding 1, decision 82).
      let tpl = proc (d: string): string =
        Head & unitResource("a9r-control.service", "", binary,
                            unitLines = "Wants=a9r-t@1.service\n", description = d) &
        unitResource("a9r-t@.service", "User=a9e\nRuntimeDirectory=a9r-t\n", binary)
      r = g.applyProfile(repro, "t1-" & $n, tpl("t1"))
      let ev1 = evidence("/run/a9r-t", "a9r-t@1.service")
      evidences.add(%*{"round": n, "template": ev1})
      step("a floored template pulled in by Wants= applies" & tag, r.exitCode == 0,
           r.stdout & r.stderr & ev1)
      r = g.applyProfile(repro, "t2-" & $n, tpl("t2"))
      step("and applies again over the directory its instance's start made" & tag,
           r.exitCode == 0, r.stdout & r.stderr & ev1)
      notPending("the template's second apply" & tag)
      # Its instance restarted outside a switch (finding 4, decision 82).
      let rs = g.exec("systemctl restart a9r-t@1.service")
      step("its instance restarts outside a switch" & tag, rs.exitCode == 0,
           rs.stdout & rs.stderr)
      let ev2 = evidence("/run/a9r-t", "a9r-t@1.service")
      evidences.add(%*{"round": n, "restart": ev2})
      r = g.applyProfile(repro, "t3-" & $n, tpl("t3"))
      step("after its instance's restart the template applies again" & tag,
           r.exitCode == 0, r.stdout & r.stderr & ev2)
      notPending("the apply after the restart" & tag)
      # The socket-activated service with its runtime directory (finding 3).
      let sk = proc (d: string): string =
        control & unitResource("a9r-sk.service", "User=a9e\nRuntimeDirectory=a9r-sk\n",
                               binary, enabled = false, description = d) &
        socketResource("a9r-sk.socket", "ListenStream=/run/a9r-sk/sock\n" &
                       "Service=a9r-sk.service\nSocketUser=a9e\n")
      r = g.applyProfile(repro, "s1-" & $n, sk("s1"))
      step("a socket-activated service with its runtime directory applies" & tag,
           r.exitCode == 0, r.stdout & r.stderr)
      r = g.applyProfile(repro, "s2-" & $n, sk("s2"))
      step("and applies again" & tag, r.exitCode == 0,
           r.stdout & r.stderr & g.exec("ls -la /run/a9r-sk; cat " & Record).stdout)
      notPending("the socket's second apply" & tag)
      # The service started once outside a switch, as its socket would start
      # it: systemd hands it the directory its socket's start made (the same
      # directory, now owned by the service's account), and the next apply,
      # which changes and so restarts the service, accepts it (the issue's
      # second measurement).
      let ss = g.exec("systemctl start a9r-sk.service")
      let ev4 = g.exec("stat -c '%n %U %i %.9W' /run/a9r-sk; cat " & Record).stdout
      step("the socket's service starts outside a switch" & tag, ss.exitCode == 0,
           ss.stdout & ss.stderr & ev4)
      r = g.applyProfile(repro, "s3-" & $n, sk("s3"))
      step("and the next apply accepts the directory it was handed" & tag,
           r.exitCode == 0, r.stdout & r.stderr & ev4)
      notPending("the socket's apply after its service ran" & tag)
      r = g.applyProfile(repro, "c-" & $n, control)
      step("back to the control" & tag, r.exitCode == 0, r.stdout & r.stderr)
      discard g.run("systemctl stop 'a9r-t@*' a9r-sk.socket a9r-sk.service 2>/dev/null; " &
                    "systemctl reset-failed 'a9r-*' 2>/dev/null; rm -rf /run/a9r-sk; true")
    record["evidence"] = evidences
    # A stopped unit (decision 83), and a failed apply's revert.
    let st = proc (d: string): string =
      control & unitResource("a9r-st.service", "User=a9e\nStateDirectory=a9r-st\n",
                             binary, description = d)
    r = g.applyProfile(repro, "p1", st("p1"))
    step("a floored unit with a StateDirectory applies", r.exitCode == 0, r.stdout & r.stderr)
    discard g.run("systemctl stop a9r-st.service; rm -rf /var/lib/a9r-st; " &
                  "systemctl start a9r-st.service; systemctl stop a9r-st.service")
    let ev3 = evidence("/var/lib/a9r-st", "a9r-st.service") &
      g.exec("systemctl show --timestamp=us+utc -p InactiveEnterTimestamp a9r-st.service").stdout
    record["stopped"] = %ev3
    r = g.applyProfile(repro, "p2", st("p2"))
    step("stopped, with the directory its last run made again, it applies",
         r.exitCode == 0, r.stdout & r.stderr & ev3)
    let current = g.exec("readlink /var/lib/repro/system/current " &
                         "/var/lib/repro/system/addon/current 2>/dev/null; true").stdout
    # p2 started the unit again; stop it, so the tree below is made after
    # its last run ended and the held unit must stay down.
    discard g.run("systemctl stop a9r-st.service; rm -rf /var/lib/a9r-st; " &
                  "mkdir /var/lib/a9r-st; touch /var/lib/a9r-st/theirs")
    r = g.applyProfile(repro, "p3", st("p3"))
    let out3 = r.stdout & r.stderr
    step("a tree made after its last run ended is refused", r.exitCode != 0 and
         "[rule:existing-tree" in out3 and "/var/lib/a9r-st" in out3, out3)
    step("and its revert commits, holding the unit (not refused)",
         "could not be rolled back" notin out3 and "keeps a9r-st.service on hold" in out3, out3)
    notPending("the refused apply and its revert")
    let after = g.exec("readlink /var/lib/repro/system/current " &
                       "/var/lib/repro/system/addon/current 2>/dev/null; true").stdout
    # A revert re-applies the generation `current` named under a new id
    # (§7.5): "rolled back to <previous> (re-applied as generation <new>)".
    let previous = extractFilename(current.strip())
    var reapplied = ""
    let at = out3.find("(re-applied as generation ")
    if at >= 0:
      reapplied = out3[at + len("(re-applied as generation ") .. ^1].split(')')[0].strip()
    step("current is the revert's re-application of the generation before " &
         "the refused apply",
         previous.len > 0 and ("rolled back to " & previous) in out3 and
         reapplied.len > 0 and extractFilename(after.strip()) == reapplied,
         current & " / " & after & " / " & reapplied)
    step("the held unit was not started on the refused tree",
         g.exec("systemctl is-active a9r-st.service").stdout.strip() != "active" and
         g.exec("stat -c %U /var/lib/a9r-st").stdout.strip() == "root",
         g.exec("systemctl status a9r-st.service --no-pager; ls -la /var/lib/a9r-st").stdout)
    discard g.run("rm -rf /var/lib/a9r-st")
    r = g.applyProfile(repro, "p4", st("p4"))
    step("once the tree is gone the unit applies and starts", r.exitCode == 0 and
         g.exec("systemctl is-active a9r-st.service").stdout.strip() == "active",
         r.stdout & r.stderr)
    r = g.applyProfile(repro, "c-st", control)
    discard g.run("rm -rf /var/lib/a9r-st; systemctl reset-failed 'a9r-*' 2>/dev/null; true")
    # A reused inode with a new birth time, on kernel ext4 (finding 7).
    let fsOk = g.exec("set -e; truncate -s 4M /var/tmp/a9r16.img; " &
      "mkfs.ext4 -q -F -N 16 /var/tmp/a9r16.img; mount -o loop /var/tmp/a9r16.img /var/cache")
    step("a 16-inode ext4 is mounted at /var/cache", fsOk.exitCode == 0,
         fsOk.stdout & fsOk.stderr)
    if fsOk.exitCode == 0:
      let cache = proc (d: string): string =
        control & unitResource("a9r-c.service", "User=a9e\nCacheDirectory=a9r-c\n",
                               binary, description = d)
      r = g.applyProfile(repro, "i1", cache("i1"))
      step("a floored unit with a CacheDirectory on it applies", r.exitCode == 0,
           r.stdout & r.stderr)
      # Remade until the kernel hands the same number back, with a new birth.
      let swap = g.exec("systemctl stop a9r-c.service; b=$(stat -c '%i %.9W' /var/cache/a9r-c); " &
        "echo before $b; for i in $(seq 1 20); do rm -rf /var/cache/a9r-c; " &
        "mkdir /var/cache/a9r-c; n=$(stat -c '%i %.9W' /var/cache/a9r-c); " &
        "[ \"${n%% *}\" = \"${b%% *}\" ] && break; done; echo after $n")
      record["inodeReuse"] = %swap.stdout
      let lines = swap.stdout.strip().splitLines()
      var reused = false
      if lines.len >= 2:
        let b4 = lines[0].splitWhitespace()
        let af = lines[^1].splitWhitespace()
        reused = b4.len == 3 and af.len == 3 and b4[1] == af[1] and b4[2] != af[2]
      step("the kernel reused the inode with a new birth time", reused, swap.stdout)
      r = g.applyProfile(repro, "i2", cache("i2"))
      let outi = r.stdout & r.stderr
      step("the next apply refuses it (§13 decision 76)", r.exitCode != 0 and
           "[rule:existing-tree" in outi and "/var/cache/a9r-c" in outi, swap.stdout & outi)
      notPending("the refused apply over the reused inode")
      discard g.run("rm -rf /var/cache/a9r-c; true")
      discard g.applyProfile(repro, "c-c", control)
      discard g.run("systemctl stop a9r-c.service 2>/dev/null; umount /var/cache; true")
    # The reviewer's link (decision 84). Last: the falsifier breaks udev.
    let lr = control & unitResource("a9r-lr.service", "User=a9e\nRuntimeDirectory=a9r-lr\n",
                                    binary, enabled = false) &
      socketResource("a9r-lr.socket", "ListenStream=/run/a9r-lr/sub/control\n" &
                     "Service=a9r-lr.service\nSocketUser=a9e\nSocketMode=0600\n" &
                     "RemoveOnStop=yes\n")
    r = g.applyProfile(repro, "lr", lr)
    let outl = r.stdout & r.stderr
    if r.exitCode != 0:
      step("an activator whose listener lies below a directory its service " &
           "can write is refused (§13 decision 84)", "decision 84" in outl, outl)
    else:
      let plant = g.exec("systemctl start a9r-lr.service; stat -c '%n %U' /run/udev/control; " &
        "runuser -u a9e -- sh -c 'mv /run/a9r-lr/sub /run/a9r-lr/old && " &
        "ln -s /run/udev /run/a9r-lr/sub'; echo plant=$?; " &
        "systemctl stop a9r-lr.socket; echo stop=$?")
      step("the manager left udev's control socket alone",
           g.exec("test -S /run/udev/control").exitCode == 0,
           outl & plant.stdout & plant.stderr)
    notPending("the activator's apply")
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
  test "a floored generation applies again, and a revert never stays pending":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "rounds": rounds(), "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
