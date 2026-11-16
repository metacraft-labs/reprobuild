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
##   (spec §10.1 round 12, "What the start step made");
## - **its instance restarted outside a switch** (``systemctl restart``):
##   the next apply accepts the directory the restart made, judged by the
##   instance that ran, not by the observation instance (spec
##   §10.1 round 12, "A directory made again outside a switch", finding 4);
## - **a socket-activated service** with ``RuntimeDirectory=<stem>`` and a
##   listener at ``/run/<stem>/sock`` applies twice: the directory its
##   socket's start made is recorded for the service (finding 3; spec
##   §10.1, round 12), and once
##   the service has started outside a switch, the next apply accepts the
##   directory it was handed; that apply, which changes the running
##   service, does not stop its socket, and neither does a refused switch
##   that changes it while it runs, whose revert commits with the socket
##   active and the host not pending (§11.1, the triggers of the held
##   units; issue 2026-11-15-addon-switch-a-socket-stopped-for-a-hold-
##   while-its-service-runs-cannot-start-again);
##
## Then once per base:
##
## - **a stopped unit** whose ``StateDirectory=`` its last run made again
##   applies; a tree made after that run ended is refused, and the refused
##   apply's revert commits with the unit held, the host not pending
##   (spec §10.1 round 12, "A stopped unit's directory" and
##   "A revert does not refuse on its own floor check");
## - **a template's record naming its observation instance**, as an engine
##   before the start step recorded a template's directory for the
##   instance that ran wrote it: ``a9r-to@.service`` with
##   ``StateDirectory=``, its instance ``a9r-to@1.service`` pulled in by
##   ``Wants=``, applies; the record's entry is rewritten to name
##   ``a9r-to@repro-addon-observe.service``, and the directory is removed
##   and made again by a run of the instance that then stops. The next
##   apply accepts it under every name of the template (the instance the
##   generation names vouches for it), writes exactly one
##   ``recreated-accepted`` audit record for it, and records it for the
##   instance under its new identity; a refused apply leaves the record as
##   it was (issue 2026-11-13-floor-template-observation-instance-refuses-
##   a-directory-its-instance-restart-made);
## - **a reused inode with a new birth time** on a 16-inode ext4 the guest
##   loop-mounts at ``/var/cache``: the kernel hands the number back, and
##   the next apply refuses the directory (decision 76, finding 7);
## - **the reviewer's link**: an activator whose listener lies below a
##   directory its service can write is refused; under the falsifying
##   build ``listener-below-writable-allowed`` it applies, the service's
##   account links ``/run/a9r-lr/sub`` to ``/run/udev``, a stop of the
##   socket unlinks udev's control socket, and the gate goes red
##   (spec §10.1 round 12, "A listener below a place its service can write").
##   Destructive, so last.
##
## - **the revert hold by its content** (A9 review round 13): an operator's
##   file of the hold's name on a unit the add-on does not install survives
##   a passing apply; one planted under that name on a floored unit is
##   refused as a foreign drop-in, and the revert does not write over it but
##   keeps the unit's start hold and stays pending until the file goes;
## - **a hold that cannot be written** (``chattr +i`` on the drop-in
##   directory): the refused unit keeps its start hold and cannot start, the
##   host is pending, and the recovery commits once the directory is
##   writable;
## - **a reboot before the recovery** of that pending revert: every floored
##   unit waits for the boot re-assertion, which replays the revert and puts
##   its start holds back first, so the refused unit stays down and its tree
##   root's (§13 decision 144);
## - **a full file system** (a filled 4 KiB tmpfs over the drop-in
##   directory): the hold's write fails at the flush, the revert sees it and
##   stays pending, the refused unit cannot start, and with room again the
##   recovery writes the hold in full (A9 review round 14, finding 1);
## - **a tree made 3 s into a run before its main process**, during a 6 s
##   ``ExecStartPre=`` or before a oneshot's last ``ExecStart=``, is refused
##   (§13 decision 145: the bound counts from the run's start);
## - **a base template whose place carries a specifier**
##   (``RuntimeDirectory=<stem>/%i``) covers a listener below
##   ``/run/<stem>/`` (§13 decision 146);
## - **a tree made 3 s into a run** that began outside a switch is refused
##   (§13 decision 141: no later than the main process's start plus
##   ``MainStartToleranceNs``);
## - **listeners below /run/<stem>/** (§13 decision 139): a template of the
##   stem that owns ``/run/<stem>`` (the reviewer's profile; the parse
##   half), a base template of the stem the parse half cannot see (the
##   effective half), and a ``ReadWritePaths=`` spelled through
##   ``/var/run``; under a falsifier each applies, the account links the
##   listener's directory to a root-owned victim, and the manager unlinks
##   it;
## - **a unit whose start returns before its directories exist** (A9 review
##   round 15, finding 2): a ``Type=simple``, a ``Type=notify`` and a
##   ``Type=forking`` unit with ``RuntimeDirectory=`` and ``StateDirectory=``
##   apply twice, their directories recorded by the first;
## - **a ``Restart=`` restart** (§13 decision 156): a ``Restart=on-failure``
##   unit killed with ``RestartSec=0`` and with ``RestartSec=3``; the next
##   apply accepts the directory the restart made, and with the delay a root
##   tree made 3 s into the restarted run is refused;
## - **a ``RestartSteps=`` restart** (systemd 254 and later; §13 decision
##   156 as amended): after two restarts whose delays grow, the next apply
##   accepts the directory the second made;
## - **a socket the revert holds** (§13 decision 155): a base template of the
##   stem makes the socket's listener refused; the revert keeps the socket
##   held, stopped and not listening;
## - **activators across a reboot** (§13 decisions 155 and 159): beside the
##   service whose hold cannot be written, three floored services that only
##   a socket, a path unit and a timer start; after the reboot with the
##   revert pending, the boot-hold unit exited before any activator
##   asserted, each is down with its assertion failed, and the socket is not
##   listening; after the recovery they are back;
## - **a held service's socket across a reboot** (§13 decision 155): a
##   revert that commits holding a service started only by its socket holds
##   the socket persistently too; after a reboot it is down and not
##   listening, and the next passing apply clears both holds;
## - **a socket's listener after the switch restarts it** (§13 decisions 78
##   and 151): the switch stops the socket for its holds and starts it again,
##   the manager binds a new listener, and the record follows it, so the
##   next apply accepts it;
##
## Falsifying builds (each red here): ``revert-refuses-on-floor``,
## ``revert-hold-runtime-only`` (the held unit starts at the reboot),
## ``revert-holds-any-subject`` (a hold for every service),
## ``cleared-hold-not-started`` (a held unit stays down after its hold goes),
## ``same-identity-ignores-btime``, ``listener-below-writable-allowed``,
## ``dependency-starts-unrecorded``, ``observation-instance-judged-alone``,
## ``template-instances-unjudged`` (the observation instance's record is
## refused, under every name, and the refused apply leaves it as it was),
## ``template-acceptance-per-name`` (the directory is accepted, but its
## ``recreated-accepted`` record is written once per name: two),
## ``revert-hold-any-content`` (the planted file passes),
## ``revert-hold-written-after-release`` (the refused unit starts),
## ``recreated-no-upper-bound`` (the tree made 3 s into the run passes),
## ``listener-writable-own-unit-only`` (the template's and the base
## template's links are followed), ``listener-writable-by-spelling`` (the
## ``/var/run`` link is followed), ``floored-not-after-reassert`` (the
## refused unit starts at the reboot), ``hold-written-unchecked`` (the
## revert commits over an empty hold and the unit starts),
## ``recreated-bound-from-main-start`` (the trees made before the main
## process pass), ``writable-specifier-resolved`` (the instance's link is
## followed), ``triggers-of-running-units-stopped`` (the socket is stopped
## while its service runs and cannot start again: the apply after the
## service ran, and the refused switch's revert, fail),
## ``record-without-waiting`` is red in
## ``t_addon_floor_round15``, not here: the end-of-step record usually
## catches the directory under this host's timing, so these cases are its
## positive control only), ``recreated-bound-from-inactive-exit-only`` (the
## restart's directory is refused), ``restart-delay-from-next`` (the
## directory the second ``RestartSteps=`` restart made is refused, debian-13),
## ``revert-held-left-running`` (the
## control unit the revert holds keeps running),
## ``activators-unheld`` (the held service's socket has no
## persistent hold and listens after the reboot; the switch's trigger holds,
## §13 decision 151, cover the other activator cases), ``boot-hold-after-sysinit`` and
## ``boot-holds-unrecorded`` (at the reboot the activators start),
## ``restarted-listener-not-rerecorded`` (the socket's next apply is
## refused ``existing-listener``), ``revert-stopped-not-restarted`` (the
## floored service only a Wants= starts stays down after the passing
## switch: A9 review round 17, finding 7, a case decision 160's
## held-triggers record does not cover).
##
## Also red here: ``restarted-listener-not-rerecorded`` (the record keeps
## the listener the socket's restart unlinked). ``start-hold-any-content``
## is red in ``t_addon_floor_round12``.
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
                  enabled = true; description = "A9 round 12";
                  exceptions = ""; exec = "";
                  kind = "oneshot\nRemainAfterExit=yes"): string =
  ## A floored oneshot unit that stays active; a template, or a unit only
  ## its socket starts (``enabled = false``), is not enabled. ``exec``
  ## replaces the one ``ExecStart=`` line; ``exceptions`` is one floor
  ## exception.
  let tmpl = name.contains("@.") or not enabled
  "systemd.systemUnit {\n" &
    (if exceptions.len > 0: "  floorExceptions = [\"" & exceptions & "\"]\n" else: "") &
    "  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=" & description & "\n" & unitLines &
    "\n[Service]\nType=" & kind & "\n" & service &
    (if exec.len > 0: exec else: "ExecStart=" & binary & " --version\n") &
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
      # The template, pulled in by the control unit (finding 1; spec
      # §10.1 round 12, "What the start step made").
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
      # Its instance restarted outside a switch (finding 4; spec
      # §10.1 round 12, "A directory made again outside a switch").
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
      # §13 decisions 78 and 151: the switch stopped the socket for its holds
      # and started it again, and the manager bound a new listener; the
      # record follows it, naming the listener there now.
      let lrec = g.exec("awk -F'\\t' '$1 == \"/run/a9r-sk/sock\" {print $4}' " & Record &
                        "; stat -c %i /run/a9r-sk/sock").stdout.splitLines()
      step("the record names the listener the socket's restart bound" & tag,
           lrec.len >= 2 and lrec[0].strip().len > 0 and lrec[0].strip() == lrec[1].strip(),
           lrec.join("\n") & g.exec("cat " & Record).stdout)
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
           r.exitCode == 0, r.stdout & r.stderr & ev4 & (if r.exitCode == 0: "" else:
             g.exec("stat -c '%n %U %i %.9W' /run/a9r-sk /run/a9r-sk/sock; " &
               "systemctl show -p ActiveState -p InvocationID a9r-sk.socket a9r-sk.service; " &
               "journalctl -b --no-pager -n 40 -u a9r-sk.socket -u a9r-sk.service").stdout))
      notPending("the socket's apply after its service ran" & tag)
      # A refused switch that changes the socket's service while it runs
      # (issue 2026-11-15-addon-switch-a-socket-stopped-for-a-hold-while-
      # its-service-runs-cannot-start-again): a unit of the same switch is
      # refused (a tree made before its first start), so the switch is
      # reverted. Neither the switch nor its revert may stop the socket
      # while its service runs (with Accept=no the service holds the
      # listening descriptor, and the socket could not start again), so the
      # revert commits, the socket is active and the host is not pending.
      # (Whether /run/a9r-sk/sock exists is evidence only: the listener is
      # below the service's RuntimeDirectory=, which a stop of the service
      # removes.)
      # Falsifier: the add-on build triggers-of-running-units-stopped.
      discard g.run("systemctl start a9r-sk.service; rm -rf /var/lib/a9r-skbad; " &
                    "mkdir /var/lib/a9r-skbad; touch /var/lib/a9r-skbad/theirs")
      let before4 = g.exec("systemctl show -p ActiveState a9r-sk.service " &
                           "a9r-sk.socket | tr '\\n' ' '").stdout.strip()
      r = g.applyProfile(repro, "s4-" & $n, sk("s4") &
        unitResource("a9r-skbad.service", "User=a9e\nStateDirectory=a9r-skbad\n",
                     binary, description = "s4"))
      let out4 = r.stdout & r.stderr
      let after4 = g.exec("systemctl show -p ActiveState -p Result a9r-sk.socket " &
        "a9r-sk.service | tr '\\n' ' '; test -S /run/a9r-sk/sock && echo listening").stdout.strip()
      step("a refused switch that changes the socket's running service is " &
           "refused for its other unit" & tag, r.exitCode != 0 and
           "[rule:existing-tree" in out4 and "/var/lib/a9r-skbad" in out4,
           out4 & "\nbefore: " & before4)
      step("and its revert commits with the socket active and its " &
           "service running" & tag,
           before4.count("ActiveState=active") == 2 and
           "could not be rolled back" notin out4 and
           "Job failed" notin out4 and
           after4.count("ActiveState=active") == 2 and
           after4.startsWith("Result=success ActiveState=active"),
           out4 & "\nbefore: " & before4 & "\nafter: " & after4)
      notPending("the refused switch with the socket's service running" & tag)
      r = g.applyProfile(repro, "c-" & $n, control)
      step("back to the control" & tag, r.exitCode == 0, r.stdout & r.stderr)
      discard g.run("systemctl stop 'a9r-t@*' a9r-sk.socket a9r-sk.service 2>/dev/null; " &
                    "systemctl reset-failed 'a9r-*' 2>/dev/null; rm -rf /run/a9r-sk " &
                    "/var/lib/a9r-skbad; true")
    record["evidence"] = evidences
    # A stopped unit (spec §10.1 round 12, "A stopped unit's
    # directory"), and a failed apply's revert ("A revert does not refuse
    # on its own floor check").
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
    # §13 decision 133: the revert's hold is persistent and covers only
    # units the generation installs, across a reboot.
    const HoldName = "zz-repro-addon-revert-hold.conf"
    let stHold = "/etc/systemd/system/a9r-st.service.d/" & HoldName
    let ctlHold = "/etc/systemd/system/a9r-control.service.d/" & HoldName
    let typeHold = "/etc/systemd/system/service.d/" & HoldName
    step("the revert's hold is written under /etc",
         g.exec("test -e " & stHold).exitCode == 0,
         g.exec("ls -la /etc/systemd/system/a9r-st.service.d /run/systemd/system/a9r-st.service.d 2>&1").stdout)
    # A host's drop-in for every service: the next apply's check, and its
    # revert's, refuse it under the subject `service`, which the generation
    # does not install, so the revert holds the generation's floored units.
    discard g.run("mkdir -p /usr/lib/systemd/system/service.d && printf " &
      "'[Service]\\nEnvironment=A9R_HOST=1\\n' > /usr/lib/systemd/system/service.d/zz-a9r.conf; " &
      "systemctl daemon-reload")
    r = g.applyProfile(repro, "p3b", st("p3b"))
    let out3b = r.stdout & r.stderr
    step("a host's drop-in for every service is refused, and the revert commits",
         r.exitCode != 0 and "[rule:foreign-drop-in" in out3b and
         "could not be rolled back" notin out3b, out3b)
    notPending("the refused apply over the host's drop-in and its revert")
    step("the revert held the generation's floored units, never `service`",
         g.exec("test -e " & typeHold).exitCode != 0 and
         g.exec("test -e " & ctlHold).exitCode == 0,
         g.exec("ls -la /etc/systemd/system/service.d /etc/systemd/system/a9r-control.service.d 2>&1").stdout)
    # §13 decision 155: a hold keeps a unit from starting, not from running.
    # The control unit ran before this switch and the switch did not change
    # it; the revert holds it, so it stops it.
    let ctlState = g.exec("systemctl show -p ActiveState -p InactiveEnterTimestamp " &
                          "a9r-control.service").stdout
    step("and stopped the held units that were running (§13 decision 155)",
         "ActiveState=active" notin ctlState, ctlState)
    discard g.run("rm -f /usr/lib/systemd/system/service.d/zz-a9r.conf; " &
                  "rmdir /usr/lib/systemd/system/service.d 2>/dev/null; systemctl daemon-reload")
    g.rebootGuest()
    let afterBoot = g.exec("systemctl is-active a9r-st.service a9r-control.service; " &
      "systemctl show -p InvocationID -p AssertResult a9r-st.service; stat -c %U /var/lib/a9r-st; " &
      "ls /etc/systemd/system/a9r-st.service.d/").stdout
    record["afterReboot"] = %afterBoot
    step("after a reboot the held units did not start and the tree is still root's",
         g.exec("systemctl is-active a9r-st.service").stdout.strip() != "active" and
         g.exec("systemctl is-active a9r-control.service").stdout.strip() != "active" and
         g.exec("stat -c %U /var/lib/a9r-st").stdout.strip() == "root" and
         g.exec("test -e " & stHold).exitCode == 0, afterBoot)
    notPending("the reboot")
    discard g.run("rm -rf /var/lib/a9r-st")
    r = g.applyProfile(repro, "p4", st("p4"))
    step("once the tree is gone the unit applies and starts", r.exitCode == 0 and
         g.exec("systemctl is-active a9r-st.service").stdout.strip() == "active",
         r.stdout & r.stderr)
    step("and the passing apply cleared the revert's holds",
         g.exec("test -e " & stHold).exitCode != 0 and g.exec("test -e " & ctlHold).exitCode != 0 and
         g.exec("systemctl is-active a9r-control.service").stdout.strip() == "active",
         g.exec("ls -la /etc/systemd/system/a9r-st.service.d /etc/systemd/system/a9r-control.service.d 2>&1").stdout)
    r = g.applyProfile(repro, "c-st", control)
    discard g.run("rm -rf /var/lib/a9r-st; systemctl reset-failed 'a9r-*' 2>/dev/null; true")
    # A9 review round 13: a revert hold is the add-on's only when it holds
    # exactly its text on a unit the generation installs. An operator's file
    # of that name on a unit the add-on does not install is never removed;
    # one planted on a floored unit is judged like any drop-in, and the
    # revert never writes over it.
    const OpNote = "/etc/systemd/system/a9r-opbase.service.d/" & HoldName
    const Planted = "/etc/systemd/system/a9r-control.service.d/" & HoldName
    const StartHold = "/run/systemd/system/a9r-control.service.d/zz-repro-addon-floor-hold.conf"
    discard g.run("mkdir -p /etc/systemd/system/a9r-opbase.service.d && printf " &
      "'[Unit]\\nDescription=the operator note\\n' > " & OpNote)
    r = g.applyProfile(repro, "h1", st("h1"))
    step("a floored generation applies beside an operator's file of the hold's name",
         r.exitCode == 0 and g.exec("test -e " & OpNote).exitCode == 0,
         r.stdout & r.stderr)
    discard g.run("mkdir -p /etc/systemd/system/a9r-control.service.d && printf " &
      "'[Unit]\\nDescription=planted by an operator\\n[Service]\\nEnvironment=A9R_PLANTED=1\\n' > " &
      Planted & "; systemctl daemon-reload")
    r = g.applyProfile(repro, "h2", st("h2"))
    let outh = r.stdout & r.stderr
    step("a drop-in planted under the hold's name with other content is refused " &
         "as a foreign drop-in", r.exitCode != 0 and "[rule:foreign-drop-in" in outh, outh)
    step("the revert did not write over it: it kept the unit's start hold, and " &
         "is pending until the file goes",
         "planted by an operator" in g.exec("cat " & Planted).stdout and
         g.exec("test -e " & StartHold).exitCode == 0 and
         g.exec("test -e " & Pending).exitCode == 0 and
         StartHold in g.exec("systemctl show -p DropInPaths a9r-control.service").stdout,
         outh & g.exec("ls -la /run/systemd/system/a9r-control.service.d " &
                       "/etc/systemd/system/a9r-control.service.d; cat " & Pending).stdout)
    discard g.run("rm -f " & Planted & "; systemctl daemon-reload")
    let rech = g.exec(repro & " system addon recover", timeoutSec = 1200)
    step("once the planted file is gone, the recovery commits", rech.exitCode == 0,
         rech.stdout & rech.stderr)
    notPending("the recovery of the revert over the planted file")
    r = g.applyProfile(repro, "h3", st("h3"))
    step("and the next apply passes, leaving the operator's file of that name",
         r.exitCode == 0 and g.exec("test -e " & OpNote).exitCode == 0 and
         "the operator note" in g.exec("cat " & OpNote).stdout,
         r.stdout & r.stderr & g.exec("ls -la /etc/systemd/system/a9r-opbase.service.d").stdout)
    # A9 review round 13: a revert whose hold cannot be written keeps the
    # start holds, does not reload, and does not commit. Round 15 (§13
    # decisions 155 and 159): beside it, three floored services that only a
    # socket, a path unit and a timer start, so at the reboot below only the
    # boot-hold unit stands between those activators and the pending
    # switch's holds. (Each activator has a service of its own: systemd
    # refuses to start a socket whose service is already running.)
    let sta = proc (d: string): string =
      st(d) &
        unitResource("a9r-sa.service", "User=a9e\n", binary, enabled = false, description = d) &
        unitResource("a9r-sp.service", "User=a9e\n", binary, enabled = false, description = d) &
        unitResource("a9r-sb.service", "User=a9e\n", binary, enabled = false, description = d) &
        socketResource("a9r-sa.socket", "ListenStream=/run/a9r-sa\nService=a9r-sa.service\n") &
        "systemd.systemUnit {\n  name = \"a9r-sp.path\"\n  content = \"[Path]\n" &
        "PathExists=/etc/a9r-st.trigger\nUnit=a9r-sp.service\n\n[Install]\n" &
        "WantedBy=paths.target\n\"\n  enabled = true\n}\n" &
        "systemd.systemUnit {\n  name = \"a9r-sb.timer\"\n  content = \"[Timer]\n" &
        "OnBootSec=1\nUnit=a9r-sb.service\n\n[Install]\nWantedBy=timers.target\n" &
        "\"\n  enabled = true\n}\n"
    const Activators = ["a9r-sa.socket", "a9r-sp.path", "a9r-sb.timer"]
    discard g.run("systemctl stop a9r-st.service; rm -rf /var/lib/a9r-st; touch /etc/a9r-st.trigger")
    r = g.applyProfile(repro, "wa", sta("wa"))
    step("three floored services with a socket, a path unit and a timer apply",
         r.exitCode == 0, r.stdout & r.stderr & (if r.exitCode == 0: "" else:
           g.exec("journalctl -b --no-pager -n 40 -u 'a9r-s*'").stdout))
    const lockDirs = " /etc/systemd/system/a9r-st.service.d"
    discard g.run("systemctl stop a9r-st.service; rm -rf /var/lib/a9r-st; " &
                  "mkdir /var/lib/a9r-st; touch /var/lib/a9r-st/theirs; " &
                  "mkdir -p" & lockDirs & "; chattr +i" & lockDirs)
    r = g.applyProfile(repro, "w1", sta("w1"))
    let outw = r.stdout & r.stderr
    let startW = g.exec("systemctl start a9r-st.service; echo start=$?; " &
      "systemctl is-active a9r-st.service; stat -c '%n %U' /var/lib/a9r-st; " &
      "ls -la /run/systemd/system/a9r-st.service.d 2>&1")
    record["unwritableHold"] = %startW.stdout
    step("a refused apply whose revert cannot write the hold leaves the host " &
         "pending, reporting it", r.exitCode != 0 and
         "hold could not be written" in outw and
         g.exec("test -e " & Pending).exitCode == 0, outw)
    step("and the refused unit cannot start: its start hold stays and the tree " &
         "is still root's", "start=0" notin startW.stdout and
         g.exec("stat -c %U /var/lib/a9r-st").stdout.strip() == "root",
         startW.stdout & startW.stderr)
    # §13 decision 144: a reboot before the recovery. Every floored unit
    # waits for the boot re-assertion, which replays the pending revert and
    # puts its start holds back first, so the refused unit stays down.
    g.rebootGuest()
    # The boot re-assertion replays the pending revert; wait for it to end
    # (a oneshot that stays active), so the recovery below does not find it
    # running and defer.
    discard g.exec("for i in $(seq 1 300); do [ \"$(systemctl show -p ActiveState " &
      "--value repro-addon-reassert.service)\" = active ] && break; sleep 2; done", timeoutSec = 900)
    let bootW = g.exec("test -e " & Pending & " && echo pending=yes; " &
      "systemctl is-active a9r-st.service; stat -c '%n %U' /var/lib/a9r-st; " &
      "systemctl show -p After a9r-st.service | tr ' ' '\\n' | grep -c reassert; " &
      "journalctl -b --no-pager -u a9r-st.service -u repro-addon-reassert.service | tail -8")
    record["unwritableHoldReboot"] = %bootW.stdout
    step("a reboot before the recovery does not start the refused unit: its " &
         "tree is still root's and the revert still pending (§13 decision 144)",
         g.exec("systemctl is-active a9r-st.service").stdout.strip() != "active" and
         g.exec("stat -c %U /var/lib/a9r-st").stdout.strip() == "root" and
         g.exec("test -e " & Pending).exitCode == 0, bootW.stdout & bootW.stderr)
    # §13 decision 159: the boot-hold unit ran before sysinit.target and put
    # the holds back, so no activator got past its assertions: each start
    # the boot queued asserted after the unit had exited, and failed.
    let bh = g.exec("systemctl show -p ActiveState -p Result " &
      "-p ExecMainExitTimestampMonotonic repro-addon-boot-hold.service; " &
      "journalctl -b -o cat --no-pager -u repro-addon-boot-hold.service | tail -3").stdout
    var bhExit = 0'i64
    for l in bh.splitLines():
      if l.startsWith("ExecMainExitTimestampMonotonic="):
        try: bhExit = parseBiggestInt(l.split('=')[1]) except ValueError: discard
    var actOk = bhExit > 0 and "ActiveState=active" in bh and "Result=success" in bh
    var actDetail = bh
    for a in Activators:
      let sh = g.exec("systemctl show -p ActiveState -p AssertResult " &
                      "-p AssertTimestampMonotonic " & a).stdout
      actDetail.add(a & ":\n" & sh)
      var at = 0'i64
      for l in sh.splitLines():
        if l.startsWith("AssertTimestampMonotonic="):
          try: at = parseBiggestInt(l.split('=')[1]) except ValueError: discard
      if "ActiveState=active" in sh or (at > 0 and at < bhExit) or
          (at > 0 and "AssertResult=no" notin sh):
        actOk = false
    let listening = g.exec("ss -xlH | grep -c ' /run/a9r-sa '; true").stdout.strip()
    actDetail.add("listening=" & listening & "\n")
    record["bootHold"] = %actDetail
    step("and the boot-hold unit put the holds back before sysinit.target: " &
         "the socket, path unit and timer of the floored services stayed down, the socket not " &
         "listening (§13 decision 159)", actOk and listening == "0", actDetail)
    discard g.run("chattr -i" & lockDirs)
    let recw = g.exec(repro & " system addon recover", timeoutSec = 1200)
    step("once the directory is writable, the recovery commits with the hold written",
         recw.exitCode == 0 and g.exec("test -e " & stHold).exitCode == 0 and
         g.exec("systemctl is-active a9r-st.service").stdout.strip() != "active",
         recw.stdout & recw.stderr)
    notPending("the recovery of the revert with an unwritable hold")
    # The header's claim, checked (A9 review round 16, finding 11): the
    # three activators the boot kept down are back once the revert commits.
    var actBack = ""
    for a in Activators:
      actBack.add(a & " " & g.exec("systemctl is-active " & a & "; true").stdout.strip() & "\n")
    step("and the socket, path unit and timer the boot kept down are back",
         actBack.count(" active\n") == Activators.len, actBack)
    discard g.run("rm -rf /var/lib/a9r-st")
    r = g.applyProfile(repro, "w2", sta("w2"))
    step("then the unit applies and starts, its hold cleared, its socket listening",
         r.exitCode == 0 and
         g.exec("test -e " & stHold).exitCode != 0 and
         g.exec("systemctl is-active a9r-st.service").stdout.strip() == "active" and
         g.exec("systemctl is-active a9r-sa.socket").stdout.strip() == "active",
         r.stdout & r.stderr)
    r = g.applyProfile(repro, "w3", st("w3"))
    step("and back without the activators", r.exitCode == 0, r.stdout & r.stderr)
    discard g.run("rm -f /etc/a9r-st.trigger")
    # §13 decision 155: a revert that holds a service holds its activator
    # with it, by the persistent hold too, so the activator stays down
    # across a reboot. The service is started only by its socket, the
    # revert commits (its holds can be written), and the guest reboots.
    let srp = proc (d: string): string =
      control & unitResource("a9r-sr.service", "User=a9e\nStateDirectory=a9r-sr\n",
                             binary, enabled = false, description = d) &
        socketResource("a9r-sr.socket", "ListenStream=/run/a9r-sr\nService=a9r-sr.service\n") &
        # A9 review round 16, finding 5: a timer declared as a
        # systemd.systemTimer resource, which the revert holds and stops too.
        "systemd.systemTimer {\n  name = \"a9r-sr.timer\"\n  content = \"[Timer]\n" &
        "OnCalendar=daily\nUnit=a9r-sr.service\n\"\n}\n"
    const SrHold = "/etc/systemd/system/a9r-sr.socket.d/" & HoldName
    r = g.applyProfile(repro, "r1", srp("r1"))
    step("a floored service only its socket starts applies", r.exitCode == 0,
         r.stdout & r.stderr)
    discard g.run("rm -rf /var/lib/a9r-sr; mkdir /var/lib/a9r-sr; touch /var/lib/a9r-sr/theirs")
    r = g.applyProfile(repro, "r2", srp("r2"))
    let outr = r.stdout & r.stderr
    step("a tree its service never made is refused, and the revert commits holding " &
         "the service and its socket, persistently (§13 decision 155)",
         r.exitCode != 0 and "keeps a9r-sr.service" in outr and "a9r-sr.socket" in outr and
         g.exec("test -e " & SrHold).exitCode == 0 and
         g.exec("test -e " & Pending).exitCode != 0 and
         g.exec("systemctl is-active a9r-sr.socket").stdout.strip() != "active",
         outr & g.exec("ls -la /etc/systemd/system/a9r-sr.socket.d 2>&1").stdout)
    g.rebootGuest()
    discard g.waitReasserted()
    let srBoot = g.exec("systemctl show -p ActiveState -p AssertResult a9r-sr.socket; " &
                        "ss -xlH | grep -c ' /run/a9r-sr '; true").stdout
    record["heldSocketReboot"] = %srBoot
    step("after a reboot the held service's socket is still down and not " &
         "listening (§13 decision 155)",
         "ActiveState=active" notin srBoot and srBoot.strip().endsWith("0") and
         g.exec("stat -c %U /var/lib/a9r-sr").stdout.strip() == "root", srBoot)
    discard g.run("rm -rf /var/lib/a9r-sr")
    r = g.applyProfile(repro, "r3", srp("r3"))
    step("once the tree is gone the next apply clears both holds and the socket listens",
         r.exitCode == 0 and g.exec("test -e " & SrHold).exitCode != 0 and
         g.exec("systemctl is-active a9r-sr.socket").stdout.strip() == "active",
         r.stdout & r.stderr)
    step("and the timer resource the revert stopped is running again (A9 review " &
         "round 16, finding 5)",
         g.exec("systemctl is-active a9r-sr.timer").stdout.strip() == "active",
         g.exec("systemctl show -p ActiveState -p UnitFileState a9r-sr.timer; " &
                "cat /var/lib/repro/system/revert-stopped 2>&1").stdout)
    # A9 review round 17, finding 7: a floored service no switch starts by
    # itself (enabled = false, no trigger), pulled in by Wants= from an
    # enabled unit and running when a revert holds it and stops it. The
    # held-triggers record (§13 decision 160) does not name it, its file is
    # unchanged and it is not enabled, so only the revert's record of what
    # it stopped brings it back.
    let wtp = proc (d: string): string =
      Head & unitResource("a9r-control.service", "", binary, description = d) &
        unitResource("a9r-wp.service", "", binary,
                     unitLines = "Wants=a9r-wt.service\nAfter=a9r-wt.service\n",
                     description = "A9 round 17 puller") &
        unitResource("a9r-wt.service", "User=a9e\nStateDirectory=a9r-wt\n",
                     binary, enabled = false, description = "A9 round 17 wanted")
    r = g.applyProfile(repro, "q1", wtp("q1"))
    step("a floored service only another unit's Wants= starts applies, and runs",
         r.exitCode == 0 and
         g.exec("systemctl is-active a9r-wt.service").stdout.strip() == "active",
         r.stdout & r.stderr)
    discard g.run("rm -rf /var/lib/a9r-wt; mkdir /var/lib/a9r-wt; touch /var/lib/a9r-wt/theirs")
    r = g.applyProfile(repro, "q2", wtp("q2"))
    let outWanted = r.stdout & r.stderr
    let stoppedRec = g.exec("cat /var/lib/repro/system/addon/revert-stopped " &
      "/var/lib/repro/system/revert-stopped 2>/dev/null; true").stdout
    step("its tree refused, the revert holds it, stops it and records it",
         r.exitCode != 0 and "a9r-wt.service" in outWanted and
         g.exec("systemctl is-active a9r-wt.service").stdout.strip() != "active" and
         "a9r-wt.service" in stoppedRec,
         outWanted & "\nrecord: " & stoppedRec)
    discard g.run("rm -rf /var/lib/a9r-wt")
    r = g.applyProfile(repro, "q3", wtp("q1"))
    step("once the tree is gone, the switch whose check passes starts it again " &
         "from the record alone, and clears the record (A9 review round 17, finding 7)",
         r.exitCode == 0 and
         g.exec("systemctl is-active a9r-wt.service").stdout.strip() == "active" and
         "a9r-wt.service" notin g.exec("cat /var/lib/repro/system/addon/revert-stopped " &
           "/var/lib/repro/system/revert-stopped 2>/dev/null; true").stdout,
         r.stdout & r.stderr & g.exec("systemctl status --no-pager a9r-wt.service 2>&1 | head -5").stdout)
    # Back to the floored unit the next case refuses, so its revert has a
    # unit to hold.
    discard g.run("systemctl stop a9r-st.service; rm -rf /var/lib/a9r-st")
    r = g.applyProfile(repro, "r4", st("r4"))
    step("and back to the floored unit", r.exitCode == 0, r.stdout & r.stderr)
    # A9 review round 14, finding 1: a full file system under the drop-in
    # directory. The hold's write fails at the flush; the revert must see it,
    # keep the start holds and stay pending, and no empty hold may block the
    # recovery once there is room.
    discard g.run("systemctl stop a9r-st.service; rm -rf /var/lib/a9r-st; " &
                  "mkdir /var/lib/a9r-st; touch /var/lib/a9r-st/theirs; " &
                  "mkdir -p /etc/systemd/system/a9r-st.service.d; " &
                  "mount -t tmpfs -o size=4k a9full /etc/systemd/system/a9r-st.service.d; " &
                  "dd if=/dev/zero of=/etc/systemd/system/a9r-st.service.d/.fill bs=4096 count=4 2>/dev/null; true")
    r = g.applyProfile(repro, "f1", st("f1"))
    let outf = r.stdout & r.stderr
    let fullW = g.exec("df -h /etc/systemd/system/a9r-st.service.d; " &
      "ls -la /etc/systemd/system/a9r-st.service.d /run/systemd/system/a9r-st.service.d 2>&1; " &
      "systemctl start a9r-st.service; echo start=$?; systemctl is-active a9r-st.service; " &
      "stat -c '%n %U' /var/lib/a9r-st")
    record["fullHold"] = %fullW.stdout
    step("a refused apply whose revert finds the hold's file system full stays " &
         "pending, reporting it", r.exitCode != 0 and
         "hold could not be written" in outf and
         g.exec("test -e " & Pending).exitCode == 0, outf & fullW.stdout)
    step("and the refused unit cannot start; the tree is still root's",
         "start=0" notin fullW.stdout and
         g.exec("stat -c %U /var/lib/a9r-st").stdout.strip() == "root", fullW.stdout)
    discard g.run("umount /etc/systemd/system/a9r-st.service.d; true")
    let recf = g.exec(repro & " system addon recover", timeoutSec = 1200)
    step("with room again, the recovery commits with the hold written in full",
         recf.exitCode == 0 and
         g.exec("grep -qx 'AssertPathExists=!/' " & stHold).exitCode == 0 and
         g.exec("systemctl is-active a9r-st.service").stdout.strip() != "active",
         recf.stdout & recf.stderr & g.exec("ls -la /etc/systemd/system/a9r-st.service.d").stdout)
    notPending("the recovery of the revert over a full file system")
    discard g.run("rm -rf /var/lib/a9r-st")
    r = g.applyProfile(repro, "f2", st("f2"))
    step("then the unit applies and starts again", r.exitCode == 0 and
         g.exec("systemctl is-active a9r-st.service").stdout.strip() == "active",
         r.stdout & r.stderr)
    # §13 decision 145: the bound counts from the run's start, so a tree
    # made during an ExecStartPre= (6 s), or before a oneshot's last
    # ExecStart=, is refused.
    for (label, exec) in [("pre", "ExecStartPre=/bin/sleep 6\nExecStart=" & binary & " --version\n"),
                          ("multi", "ExecStart=/bin/sleep 6\nExecStart=" & binary & " --version\n")]:
      let pu = proc (d: string): string =
        control & unitResource("a9r-p.service", "User=a9e\nStateDirectory=a9r-p\n", binary,
          description = d, exceptions = "NoExecPaths: the gate runs the base's sleep",
          exec = exec)
      r = g.applyProfile(repro, label & "1", pu(label & "1"))
      step("a floored unit with a 6 s " & label & " phase and a StateDirectory applies",
           r.exitCode == 0, r.stdout & r.stderr)
      let evp = g.exec("systemctl restart --no-block a9r-p.service; sleep 3; rm -rf /var/lib/a9r-p; " &
        "mkdir /var/lib/a9r-p; touch /var/lib/a9r-p/planted; sleep 7; " &
        "stat -c '%n %U %.9W' /var/lib/a9r-p; systemctl show --timestamp=us+utc " &
        "-p InvocationID -p InactiveExitTimestamp -p ExecMainStartTimestamp -p ActiveState a9r-p.service").stdout
      record["beforeMain-" & label] = %evp
      r = g.applyProfile(repro, label & "2", pu(label & "2"))
      let outp = r.stdout & r.stderr
      # Decision 145: the bound counts from the run's start.
      step("a root tree made 3 s into the run, before its main process (" & label &
           "), is refused (§13 decision 145)", r.exitCode != 0 and
           "[rule:existing-tree" in outp and "/var/lib/a9r-p" in outp, evp & outp)
      notPending("the refused apply over a tree made before the main process (" & label & ")")
      discard g.run("systemctl stop a9r-p.service; rm -rf /var/lib/a9r-p; true")
      discard g.applyProfile(repro, label & "-c", control)
    # A9 review round 15, finding 2: a unit whose start returns before its
    # directories exist (Type=simple, and on systemd 257 every type whose
    # executor makes them after the fork) has them recorded all the same,
    # so the same profile applies again. Type=notify and Type=forking too.
    const Sleep = "NoExecPaths: the gate runs the base's sleep and shells"
    for (label, kind, exec) in [
        ("simple", "simple", "ExecStart=/bin/sleep infinity\n"),
        ("notify", "notify\nRemainAfterExit=yes", "ExecStart=/usr/bin/systemd-notify --ready\n"),
        ("forking", "forking", "ExecStart=/bin/sh -c '/bin/sleep infinity & exit 0'\n")]:
      let tu = proc (d: string): string =
        control & unitResource("a9r-k.service", "User=a9e\nRuntimeDirectory=a9r-k\n" &
          "StateDirectory=a9r-k\n", binary, description = d, exceptions = Sleep,
          exec = exec, kind = kind)
      r = g.applyProfile(repro, label & "-1", tu(label & "-1"))
      let rec1 = g.exec("grep -c a9r-k " & Record & "; systemctl show -p ActiveState a9r-k.service").stdout
      step("a Type=" & label & " unit with its directories applies, and they are recorded",
           r.exitCode == 0 and rec1.startsWith("2"), r.stdout & r.stderr & rec1)
      r = g.applyProfile(repro, label & "-2", tu(label & "-2"))
      step("and the same profile applies again (Type=" & label & ")", r.exitCode == 0,
           r.stdout & r.stderr)
      notPending("the second apply of the Type=" & label & " unit")
      discard g.run("systemctl stop a9r-k.service; rm -rf /var/lib/a9r-k; true")
      discard g.applyProfile(repro, label & "-c", control)
    # §13 decision 156: a Restart= restart. The run begins RestartSec=
    # after systemd 257 stamps InactiveExitTimestamp, so the bound counts
    # from the run's real start; and a root tree made later in that run is
    # still refused.
    for delay in ["0", "3"]:
      let ru = proc (d: string): string =
        control & unitResource("a9r-r.service", "User=a9e\nRuntimeDirectory=a9r-r\n" &
          "Restart=on-failure\nRestartSec=" & delay & "\n", binary, description = d,
          exceptions = Sleep, exec = "ExecStart=/bin/sleep infinity\n", kind = "exec")
      r = g.applyProfile(repro, "rs" & delay & "-1", ru("rs" & delay & "-1"))
      step("a Restart=on-failure unit with RestartSec=" & delay & " applies",
           r.exitCode == 0, r.stdout & r.stderr)
      let evr = g.exec("systemctl kill -s KILL a9r-r.service; sleep $((" & delay & " + 3)); " &
        "systemctl show --timestamp=us+utc -p NRestarts -p InactiveExitTimestamp " &
        "-p ExecMainStartTimestamp -p ActiveState a9r-r.service; stat -c '%n %U %.9W' /run/a9r-r").stdout
      record["restart-" & delay] = %evr
      r = g.applyProfile(repro, "rs" & delay & "-2", ru("rs" & delay & "-2"))
      step("after a Restart= restart with RestartSec=" & delay & ", the next apply accepts " &
           "the directory the restart made (§13 decision 156)",
           r.exitCode == 0 and "NRestarts=1" in evr, evr & r.stdout & r.stderr)
      notPending("the apply after a Restart= restart (RestartSec=" & delay & ")")
      if delay == "3":
        let evt = g.exec("systemctl kill -s KILL a9r-r.service; sleep 6; " &
          "rm -rf /run/a9r-r; mkdir /run/a9r-r; touch /run/a9r-r/planted; " &
          "systemctl show --timestamp=us+utc -p NRestarts -p InactiveExitTimestamp " &
          "a9r-r.service; stat -c '%n %U %.9W' /run/a9r-r").stdout
        r = g.applyProfile(repro, "rs-t", ru("rs-t"))
        step("a root tree made 3 s into a restarted run is refused (§13 decision 156)",
             r.exitCode != 0 and "/run/a9r-r" in r.stdout & r.stderr, evt & r.stdout & r.stderr)
        notPending("the refused apply over a tree made into a restarted run")
      discard g.run("systemctl stop a9r-r.service; true")
      discard g.applyProfile(repro, "rs" & delay & "-c", control)
    # §13 decision 156 as amended (A9 review round 16, finding 2): with
    # RestartSteps= the delay before restart n grows from RestartSec=
    # towards RestartMaxDelaySec=; RestartUSecNext is the NEXT one. Two
    # restarts: the second waits 2 s (1 s * (4 / 1) ^ (1 / 2)) where
    # RestartUSecNext says 4 s, and a 6 s ExecStartPre= puts the main
    # process well after the run's start, so reading the next delay moves
    # the run's start past the directory's birth. systemd 254 and later.
    let sdv = g.exec("systemctl --version | head -1 | cut -d' ' -f2").stdout.strip()
    var sdMajor = 0
    try: sdMajor = parseInt(sdv) except ValueError: discard
    if sdMajor >= 254:
      let rsp = proc (d: string): string =
        control & unitResource("a9r-rp.service", "User=a9e\nRuntimeDirectory=a9r-rp\n" &
          "Restart=on-failure\nRestartSec=1\nRestartSteps=2\nRestartMaxDelaySec=4\n",
          binary, description = d, exceptions = Sleep, kind = "exec",
          exec = "ExecStartPre=/bin/sleep 6\nExecStart=/bin/sleep infinity\n")
      r = g.applyProfile(repro, "rp-1", rsp("rp-1"))
      step("a Restart= unit with RestartSteps= applies", r.exitCode == 0, r.stdout & r.stderr)
      let evp = g.exec("systemctl kill -s KILL a9r-rp.service; sleep 10; " &
        "systemctl kill -s KILL a9r-rp.service; sleep 12; " &
        "systemctl show --timestamp=us+utc -p NRestarts -p RestartUSecNext " &
        "-p InactiveExitTimestamp -p ExecMainStartTimestamp -p ActiveState a9r-rp.service; " &
        "stat -c '%n %U %.9W' /run/a9r-rp").stdout
      record["restartSteps"] = %evp
      r = g.applyProfile(repro, "rp-2", rsp("rp-2"))
      step("after the second RestartSteps= restart the next apply accepts the " &
           "directory it made (§13 decision 156)",
           r.exitCode == 0 and "NRestarts=2" in evp, evp & r.stdout & r.stderr)
      notPending("the apply after RestartSteps= restarts")
      discard g.run("systemctl stop a9r-rp.service; true")
      discard g.applyProfile(repro, "rp-c", control)
    else:
      record["restartSteps"] = %("systemd " & sdv & " has no RestartSteps=")
    # §13 decision 141, the upper bound: a tree a root process makes seconds
    # into a run that began outside a switch is not systemd's.
    discard g.run("systemctl restart a9r-st.service; sleep 3; rm -rf /var/lib/a9r-st; " &
                  "mkdir /var/lib/a9r-st; touch /var/lib/a9r-st/planted")
    let evm = g.exec("stat -c '%n %U %.9W' /var/lib/a9r-st; systemctl show " &
      "--timestamp=us+utc -p InvocationID -p InactiveExitTimestamp " &
      "-p ExecMainStartTimestamp -p ActiveState a9r-st.service").stdout
    record["laterInTheRun"] = %evm
    r = g.applyProfile(repro, "m1", st("m1"))
    let outm = r.stdout & r.stderr
    # Decision 141's upper bound: born no later than the run's start.
    step("a root tree made 3 s into a run that began outside a switch is refused " &
         "(§13 decision 141)", r.exitCode != 0 and "[rule:existing-tree" in outm and
         "/var/lib/a9r-st" in outm, outm & evm)
    notPending("the refused apply over a tree made later in the run")
    discard g.run("systemctl stop a9r-st.service; rm -rf /var/lib/a9r-st")
    r = g.applyProfile(repro, "m2", st("m2"))
    step("and once it is gone the unit applies again", r.exitCode == 0, r.stdout & r.stderr)
    r = g.applyProfile(repro, "c-st2", control)
    discard g.run("rm -rf /var/lib/a9r-st; systemctl reset-failed 'a9r-*' 2>/dev/null; true")
    # A template's record naming its observation instance, as an engine
    # before the start step recorded a template's directory for the
    # instance that ran wrote it (issue 2026-11-13-floor-template-
    # observation-instance-refuses-a-directory-its-instance-restart-made).
    # Its instance's last run made the directory again and has ended, so
    # no running instance vouches for it: every name of the template must
    # judge it against the instance the generation names and reach one
    # verdict, written once, and a refused apply must not rewrite it.
    const ToDir = "/var/lib/a9r-to"
    let obs = proc (d: string): string =
      Head & unitResource("a9r-control.service", "", binary,
                          unitLines = "Wants=a9r-to@1.service\n", description = d) &
      unitResource("a9r-to@.service", "User=a9e\nStateDirectory=a9r-to\n", binary)
    # The record's line for the directory, its tab-separated fields
    # (``readCreatedDirs``: path, unit, st_dev, st_ino, birth ns,
    # InvocationID).
    proc toEntry(): seq[string] =
      g.exec("awk -F'\\t' '$1==\"" & ToDir & "\"' " & Record).stdout.strip().split('\t')
    # The directory's identity as the add-on records it: st_dev as
    # major << 32 | minor (statx), the inode, the birth time in ns.
    proc toIdentity(): seq[string] =
      let f = g.exec("stat -c '%Hd %Ld %i %.9W' " & ToDir).stdout.strip().splitWhitespace()
      if f.len != 4: return @[]
      try:
        @[$((parseBiggestUInt(f[0]) shl 32) or parseBiggestUInt(f[1])), f[2],
          f[3].replace(".", "").strip(chars = {'0'}, trailing = false)]
      except ValueError: @[]
    # The ``recreated-accepted`` audit records for the directory, over every
    # generation's apply log: its resourceAddress and outcome are adjacent,
    # with the outcome's 4-byte length between them (``encodeAuditRecord``).
    proc toAccepted(): int =
      let c = g.exec("cat /var/lib/repro/system/generations/*/log/apply.log " &
        "2>/dev/null | tr '\\000' '#' | LC_ALL=C grep -a -o " &
        "'directory:" & ToDir & ".###recreated-accepted' | wc -l").stdout.strip()
      try: parseInt(c) except ValueError: -1
    r = g.applyProfile(repro, "o1", obs("o1"))
    let e1 = toEntry()
    step("a floored template with a StateDirectory, pulled in by Wants=, applies",
         r.exitCode == 0 and e1.len == 6 and e1[1] == "a9r-to@1.service",
         r.stdout & r.stderr & e1.join(" | "))
    let rw = g.exec("awk -F'\\t' -v OFS='\\t' '$1==\"" & ToDir & "\"{$2=\"" &
      "a9r-to@repro-addon-observe.service\"}1' " & Record & " > " & Record &
      ".a9r && chmod 0600 " & Record & ".a9r && mv " & Record & ".a9r " & Record)
    let e2 = toEntry()
    step("its record is rewritten to name the observation instance",
         rw.exitCode == 0 and e1.len == 6 and e2.len == 6 and
         e2[1] == "a9r-to@repro-addon-observe.service" and e2[2 .. 5] == e1[2 .. 5],
         rw.stdout & rw.stderr & e2.join(" | "))
    discard g.run("systemctl stop a9r-to@1.service; rm -rf " & ToDir & "; " &
                  "systemctl start a9r-to@1.service; systemctl stop a9r-to@1.service")
    let ev5 = evidence(ToDir, "a9r-to@1.service")
    record["observationRecord"] = %ev5
    let id5 = toIdentity()
    let before5 = g.exec("cat " & Record).stdout
    let accepted5 = toAccepted()
    r = g.applyProfile(repro, "o2", obs("o2"))
    let out5 = r.stdout & r.stderr
    let after5 = g.exec("cat " & Record).stdout
    let e3 = toEntry()
    step("the next apply accepts the directory its stopped instance's run made " &
         "again, though the record names the observation instance",
         r.exitCode == 0, out5 & ev5)
    notPending("the apply over the observation instance's record")
    let accepted6 = toAccepted()
    step("it writes exactly one recreated-accepted record for the directory",
         accepted5 >= 0 and accepted6 - accepted5 == 1,
         "before " & $accepted5 & ", after " & $accepted6)
    if r.exitCode == 0:
      step("the record names the instance, with the directory's new identity",
           e3.len == 6 and e3[1] == "a9r-to@1.service" and id5.len == 3 and
           e3[2 .. 4] == id5,
           e3.join(" | ") & " / " & id5.join(" ") & "\n" & after5)
    else:
      step("the refused apply left the record as it was", after5 == before5,
           before5 & "---\n" & after5)
    r = g.applyProfile(repro, "c-to", control)
    discard g.run("systemctl stop 'a9r-to@*' 2>/dev/null; rm -rf " & ToDir &
                  "; systemctl reset-failed 'a9r-*' 2>/dev/null; true")
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
    # §13 decision 139: the places every unit sharing the stem can write,
    # compared as the kernel resolves them. A root-owned victim stands for
    # udev's socket: if the manager ever binds or unlinks through a link
    # the service's account planted, the victim is gone.
    proc victimSafe(label, plantDir: string; leaf = "sub"): tuple[ok: bool; detail: string] =
      let o = g.exec("mkdir -p /run/a9v && rm -f /run/a9v/control && touch /run/a9v/control; " &
        "runuser -u a9e -- sh -c 'mv " & plantDir & "/" & leaf & " " & plantDir & "/old && " &
        "ln -s /run/a9v " & plantDir & "/" & leaf & "'; echo plant=$?; " &
        "systemctl stop " & label & ".socket; echo stop=$?; " &
        "systemctl start " & label & ".socket; echo start=$?; stat -c '%n %U %F' /run/a9v/control")
      (g.exec("test -f /run/a9v/control && test \"$(stat -c %U /run/a9v/control)\" = root").exitCode == 0,
       o.stdout & o.stderr)
    proc listenerSocket(label: string): string =
      socketResource(label & ".socket", "ListenStream=/run/" & label & "/sub/control\n" &
        "Service=" & label & ".service\nSocketUser=a9e\nSocketMode=0600\nRemoveOnStop=yes\n")
    # (a) The reviewer's profile: a template of the stem owns /run/<stem>.
    let ls = Head & unitResource("a9r-control.service", "", binary,
                                 unitLines = "Wants=a9r-s@1.service\n") &
      unitResource("a9r-s.service", "User=a9e\n", binary, enabled = false) &
      unitResource("a9r-s@.service", "User=a9e\nRuntimeDirectory=a9r-s\n", binary) &
      listenerSocket("a9r-s")
    r = g.applyProfile(repro, "ls", ls)
    let outs = r.stdout & r.stderr
    if r.exitCode != 0:
      step("a listener below /run/<stem>/ that a template of the stem owns is " &
           "refused (§13 decision 139)", "unit sharing its stem" in outs, outs)
    else:
      let v = victimSafe("a9r-s", "/run/a9r-s")
      step("the manager did not follow the template's link to a root file", v.ok,
           outs & v.detail)
    discard g.applyProfile(repro, "c-ls", control)
    discard g.run("systemctl stop a9r-s.socket 'a9r-s@*' 2>/dev/null; rm -rf /run/a9r-s; true")
    # (b) The effective half: a base template of the stem, which the parse
    # half cannot see, owns /run/<stem> while its instance runs.
    discard g.run("printf '[Service]\\nUser=a9e\\nRuntimeDirectory=a9r-h\\n" &
      "ExecStart=/bin/sleep infinity\\n' > /usr/lib/systemd/system/a9r-h@.service; " &
      "systemctl daemon-reload; systemctl start a9r-h@1.service")
    let lh = control & unitResource("a9r-h.service", "User=a9e\n", binary, enabled = false) &
      listenerSocket("a9r-h")
    r = g.applyProfile(repro, "lh", lh)
    let outh2 = r.stdout & r.stderr
    if r.exitCode != 0:
      step("the effective half refuses it when a base template of the stem owns " &
           "/run/<stem> (§13 decision 139)", "unit sharing its stem" in outh2, outh2)
      notPending("the refused apply over a base template of the stem")
    else:
      let v = victimSafe("a9r-h", "/run/a9r-h")
      step("the manager did not follow the base template's link to a root file",
           v.ok, outh2 & v.detail)
    discard g.applyProfile(repro, "c-lh", control)
    discard g.run("systemctl stop a9r-h.socket 'a9r-h@*' 2>/dev/null; rm -f " &
      "/usr/lib/systemd/system/a9r-h@.service; systemctl daemon-reload; rm -rf /run/a9r-h; true")
    # (d) §13 decision 146: a base template whose place carries a specifier
    # (RuntimeDirectory=a9r-q/%i) counts by its literal prefix, though the
    # observation instance resolves it to a directory no instance has.
    discard g.run("printf '[Service]\\nUser=a9e\\nRuntimeDirectory=a9r-q/%%i\\n" &
      "ExecStart=/bin/sleep infinity\\n' > /usr/lib/systemd/system/a9r-q@.service; " &
      "systemctl daemon-reload")
    let lq = control & unitResource("a9r-q.service", "User=a9e\n", binary, enabled = false) &
      socketResource("a9r-q.socket", "ListenStream=/run/a9r-q/sub/x/control\n" &
        "Service=a9r-q.service\nSocketUser=a9e\nSocketMode=0600\nRemoveOnStop=yes\n")
    r = g.applyProfile(repro, "lq", lq)
    let outq = r.stdout & r.stderr
    if r.exitCode != 0:
      step("a base template whose RuntimeDirectory= is <stem>/%i covers the " &
           "listener below /run/<stem>/ (§13 decision 146)",
           "unit sharing its stem" in outq, outq)
      notPending("the refused apply over a specifier place")
    else:
      discard g.run("systemctl start a9r-q@sub.service; for i in $(seq 1 50); do " &
        "[ \"$(stat -c %U /run/a9r-q/sub 2>/dev/null)\" = a9e ] && break; sleep 0.2; done")
      let v = victimSafe("a9r-q", "/run/a9r-q/sub", leaf = "x")
      step("the manager did not follow the instance's link to a root file", v.ok,
           outq & v.detail)
    discard g.applyProfile(repro, "c-lq", control)
    discard g.run("systemctl stop a9r-q.socket 'a9r-q@*' 2>/dev/null; rm -f " &
      "/usr/lib/systemd/system/a9r-q@.service; systemctl daemon-reload; rm -rf /run/a9r-q /run/a9v; true")
    # (e) §13 decision 155: an activator the revert holds is stopped, so it
    # no longer listens (the reviewer's section F2): a base template of the
    # stem appears after the apply, the next apply refuses the socket, and
    # its revert holds and stops it.
    let lj = proc (d: string): string =
      control & unitResource("a9r-j.service", "User=a9e\n", binary, enabled = false,
                             description = d) & listenerSocket("a9r-j")
    r = g.applyProfile(repro, "lj1", lj("lj1"))
    step("a floored service and its socket apply", r.exitCode == 0 and
         g.exec("systemctl is-active a9r-j.socket").stdout.strip() == "active",
         r.stdout & r.stderr)
    discard g.run("printf '[Service]\\nUser=a9e\\nRuntimeDirectory=a9r-j/%%i\\n" &
      "ExecStart=/bin/sleep infinity\\n' > /usr/lib/systemd/system/a9r-j@.service; " &
      "systemctl daemon-reload")
    r = g.applyProfile(repro, "lj2", lj("lj2"))
    let outj = r.stdout & r.stderr
    let sj = g.exec("systemctl show -p ActiveState -p SubState -p DropInPaths a9r-j.socket; " &
      "ss -xl | grep -c a9r-j; ls /etc/systemd/system/a9r-j.socket.d 2>&1")
    record["heldSocket"] = %sj.stdout
    step("the revert holds the refused socket and stops it: it no longer listens " &
         "(§13 decision 155)", r.exitCode != 0 and
         "keeps a9r-j.socket" in outj and "SubState=listening" notin sj.stdout and
         sj.stdout.contains("\n0\n"), outj & sj.stdout)
    notPending("the refused apply over the held socket")
    discard g.run("systemctl stop a9r-j.socket 'a9r-j@*' 2>/dev/null; rm -f " &
      "/usr/lib/systemd/system/a9r-j@.service; systemctl daemon-reload; rm -rf /run/a9r-j; true")
    discard g.applyProfile(repro, "c-lj", control)
    # (c) A place spelled through /var/run covers a listener below /run.
    discard g.run("mkdir -p /run/a9r-v && chown a9e /run/a9r-v")
    let lv = control & unitResource("a9r-v.service", "User=a9e\nReadWritePaths=/var/run/a9r-v\n",
                                    binary, enabled = false) & listenerSocket("a9r-v")
    r = g.applyProfile(repro, "lv", lv)
    let outv = r.stdout & r.stderr
    if r.exitCode != 0:
      step("ReadWritePaths= spelled through /var/run covers the listener below " &
           "/run (§13 decision 139)", "lies below /run/a9r-v" in outv, outv)
    else:
      let v = victimSafe("a9r-v", "/run/a9r-v")
      step("the manager did not follow the link under /var/run's spelling", v.ok,
           outv & v.detail)
    discard g.applyProfile(repro, "c-lv", control)
    discard g.run("systemctl stop a9r-v.socket 2>/dev/null; rm -rf /run/a9r-v /run/a9v; true")
    # The reviewer's link (spec §10.1 round 12, "A listener below a place
    # its service can write"). Last: the falsifier breaks udev.
    let lr = control & unitResource("a9r-lr.service", "User=a9e\nRuntimeDirectory=a9r-lr\n",
                                    binary, enabled = false) &
      socketResource("a9r-lr.socket", "ListenStream=/run/a9r-lr/sub/control\n" &
                     "Service=a9r-lr.service\nSocketUser=a9e\nSocketMode=0600\n" &
                     "RemoveOnStop=yes\n")
    r = g.applyProfile(repro, "lr", lr)
    let outl = r.stdout & r.stderr
    if r.exitCode != 0:
      step("an activator whose listener lies below a directory its service " &
           "can write is refused, citing its rule (§10.1 round 12)",
           "A listener below a place its service can write" in outl, outl)
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
