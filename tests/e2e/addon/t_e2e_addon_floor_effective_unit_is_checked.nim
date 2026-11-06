## Gate ``e2e_addon_floor_effective_unit_is_checked`` (milestone A9, review
## round 3's structural requirement; spec §10.1 *Amended 2026-11-04*).
##
## A floored unit never starts with a weaker floor than it was rendered
## under, whatever spelling, key, drop-in rule or default the floor's
## parse-time checks do not predict: after the switch's daemon-reload and
## before step 7 starts anything, the add-on reads each floored unit's
## effective properties with ``systemctl show`` and compares them with the
## floor (``repro_addon/effective_floor``); a difference is
## ``EAddOnFloorNotEffective``, nothing starts, and the switch reverts.
##
## The cases are review round 3's findings 1-5 (and 6): a unit that runs as
## root by an empty ``User=``, by ``DynamicUser=n``, or by a drop-in's
## ``User=`` reset; writable places the unit sets up (``ReadWritePaths=``, a
## bind, an ``exec`` tmpfs, a drop-in's ``StateDirectory=``); a quoted bind
## over the closure; an instance's drop-in over a floored template; a
## ``collision = "dropIn"`` unit over a floored one; ``PAMName=``. Rounds 4,
## 5 and 6 add theirs (round 6: a static account under ``DynamicUser=yes``,
## a second name for uid 0, ``OnFailure=reboot.target``, the first of two
## ``EnvironmentFile=`` lines; round 7: ``EnvironmentFile=`` naming a host
## file or another service's secrets, a ``RuntimeDirectory=`` in the
## add-on's tree or at the existing ``/run/systemd``, a system-state target
## reached through a unit of the profile, an isolating job mode, an
## activator socket with ``Mark=``; §13 decision 55: ``Conflicts=`` naming a
## base service). Each is
## applied by an operator on a fresh add-on host. A case passes when the
## apply is refused and the unit never started, or -- for a writable place
## the floor now covers -- when the unit runs and systemd shows it holding
## the floor (not root, the place in ``NoExecPaths=``). A positive control
## (a plain floored unit) must apply and start.
##
## Round 8 (finding 4) makes every case carry its own proof: each names the
## refusal of the rule it targets (``expect``); between cases every case
## unit is stopped and reset, host drop-ins removed, the control applied
## and systemd's answer checked (a host left unusable fails every later
## case as not exercised); the cases that change the host for good when a
## build lets them through run last; the dependency cases put their lines
## in the unit's own ``[Unit]``, so they reach their rule, not the drop-in
## allowlist.
##
## Builds:
##
## - the product build: each case is refused at parse time, or held;
## - ``REPRO_ADDON_MUTATION=floor-static-r3-disabled`` (the parse-time half
##   off): the effective check alone must refuse every case, each refusal
##   naming ``EAddOnFloorNotEffective`` and the case's own rule -- green;
## - ``REPRO_ADDON_MUTATION=floor-unchecked`` (both halves off): every case
##   must start (a case refused for another reason is a failed step), so
##   each case's "refused, never started" step is red -- red, case by case.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the real add-on, the base's own systemd.

import std/[json, os, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip

import repro_dsl_stdlib/packages/apt_closure
import repro_addon/generation0

import ./addon_testbed
import ./deb_fixture_support

proc aptFixtureDeb(work, name, debArch: string):
    tuple[path: string; lock: AptClosureLock] =
  ## A one-file .deb and its closure lock for the guest's architecture.
  result.path = work / (name & ".deb")
  writeDeb(result.path, @[dir("./"), dir("./usr/"), dir("./usr/share/"),
    dir("./usr/share/" & name & "/"),
    ("./usr/share/" & name & "/ok.txt", '0', 0o644, name & "\n", "")])
  result.lock = fixtureLock(name, result.path, debArch)

const Gate = "e2e_addon_floor_effective_unit_is_checked"

type Case = object
  name: string          ## the unit's name
  service: string       ## lines added to its [Service]
  extra: string         ## more resources (a drop-in, a dropIn unit)
  coveredPlace: string  ## a writable place the floor now covers (may run)
  host: string          ## a shell line run on the host before the apply
                        ## (a host's, a package's or a type-wide drop-in;
                        ## an account in a privileged group)
  probes: string        ## the units the case tries to start (default: it)
  unitLines: string     ## lines added to its [Unit] (round 8: the
                        ## dependency cases reach their own rule, not the
                        ## drop-in allowlist)
  activatorOnly: bool   ## the service only through its socket: systemd
                        ## refuses to start a socket whose service is
                        ## already active (systemd.socket(5)), so a service
                        ## the switch started would keep the socket from
                        ## ever applying its options
  expect: seq[string]   ## the refusal of the rule the case targets: one of
                        ## these is in the effective check's refusal
                        ## (round 8, finding 4)

proc unitResource(name, service, binary: string; unitLines = "";
                  enabled = true): string =
  ## A floored oneshot unit; a template, or a unit only its socket starts
  ## (``enabled = false``), is declared without ``[Install]`` and is not
  ## enabled.
  let tmpl = name.contains("@.") or not enabled
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=A9 round 3\n" & unitLines & "\n[Service]\nType=oneshot\nRemainAfterExit=yes\n" &
    service & "ExecStart=" & binary & " --version\n" &
    (if tmpl: "\"\n  enabled = false\n}\n"
     else: "\n[Install]\nWantedBy=multi-user.target\n\"\n  enabled = true\n}\n")

proc dropIn(unit, content: string): string =
  "systemd.systemDropIn {\n  unit = \"" & unit & "\"\n  name = \"x\"\n" &
    "  content = \"" & content & "\"\n}\n"

proc hostDropIn(dir, content: string): string =
  "mkdir -p " & dir & " && printf '" & content.replace("\n", "\\n") &
    "' > " & dir & "/host.conf"

const HostCleanup = "rm -rf /etc/systemd/system/a9e-*.service.d/host.conf " &
  "/usr/lib/systemd/system/a9e-*.service.d " &
  "/usr/lib/systemd/system/service.d/zz-a9e.conf; systemctl daemon-reload"

proc cases(binary, prefix: string): seq[Case] =
  let etc = "/etc/systemd/system/"
  let vendor = "/usr/lib/systemd/system/"
  @[Case(name: "a9e-user-empty.service", expect: @["runs as root"], service: "User=\n"),
    Case(name: "a9e-dyn-n.service", expect: @["runs as root"], service: "DynamicUser=n\n"),
    Case(name: "a9e-drop-user.service", expect: @["runs as root"], service: "User=a9e\n",
         extra: dropIn("a9e-drop-user.service", "[Service]\nUser=\n")),
    Case(name: "a9e-rw.service", expect: @["/var/lib/a9e-rw"], service: "User=a9e\nReadWritePaths=/var/lib/a9e-rw\n",
         coveredPlace: "/var/lib/a9e-rw"),
    Case(name: "a9e-bind.service", expect: @["/srv/a9e-b"],
         service: "User=a9e\nBindPaths=/var/lib/a9e-rw:/srv/a9e-b\n",
         coveredPlace: "/srv/a9e-b"),
    Case(name: "a9e-tmpfs-exec.service", expect: @["/srv/a9e-t"],
         service: "TemporaryFileSystem=/srv/a9e-t:mode=1777,exec\n"),
    Case(name: "a9e-drop-state.service", expect: @["a9e-evil"], service: "",
         extra: dropIn("a9e-drop-state.service", "[Service]\nStateDirectory=a9e-evil\n")),
    Case(name: "a9e-quoted.service", expect: @["/drop"],
         service: "User=a9e\nBindPaths=/var/lib/a9e-rw:'" & prefix & "/drop'\n"),
    # An instance's drop-in over a floored template of the same generation
    # (round 4, finding 8: no first generation needed).
    Case(name: "a9e-tpl@.service", expect: @["MemoryDenyWriteExecute=no"], service: "",
         extra: dropIn("a9e-tpl@1.service", "[Service]\nMemoryDenyWriteExecute=no\n")),
    Case(name: "a9e-cd@.service", expect: @["runs as root"], service: "User=a9e\n",
         extra: "systemd.systemUnit {\n  name = \"a9e-cd@1.service\"\n" &
                "  collision = \"dropIn\"\n  content = \"[Service]\nUser=\n\"\n}\n"),
    Case(name: "a9e-pam.service", expect: @["PAMName"], service: "User=a9e\nPAMName=login\n"),
    # Review round 4.
    Case(name: "a9e-gshadow.service", expect: @["privileged group shadow"], service: "User=a9e\nGroup=shadow\n"),
    Case(name: "a9e-member.service", expect: @["privileged group adm", "privileged group shadow"], service: "User=a9g\n",
         host: "id a9g >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin " &
               "-G shadow,adm a9g"),
    Case(name: "a9e-psonly.service", expect: @["PermissionsStartOnly"], service: "User=a9e\nPermissionsStartOnly=yes\n" &
         "ExecStartPre=" & binary & " --version\n"),
    Case(name: "a9e-openfile.service", expect: @["OpenFile"], service: "OpenFile=/etc/a9e-target:t\n"),
    Case(name: "a9e-stdout.service", expect: @["StandardOutput=truncate"], service: "StandardOutput=truncate:/etc/a9e-out\n"),
    Case(name: "a9e-hostdrop.service", expect: @["a drop-in the add-on did not install"], service: "",
         host: hostDropIn(etc & "a9e-hostdrop.service.d",
                          "[Service]\nDynamicUser=no\nUser=\nNoExecPaths=\n")),
    Case(name: "a9e-vplus.service", expect: @["a drop-in the add-on did not install"], service: "",
         host: hostDropIn(vendor & "a9e-vplus.service.d",
                          "[Service]\nExecStartPre=+" & binary & " --version\n")),
    Case(name: "a9e-vtype.service", expect: @["a drop-in the add-on did not install"], service: "",
         host: "mkdir -p " & vendor & "service.d && printf '[Service]\\n" &
               "PermissionsStartOnly=yes\\n' > " & vendor & "service.d/zz-a9e.conf"),
    Case(name: "a9e-th@.service", expect: @["a drop-in the add-on did not install"], service: "", probes: "a9e-th@x.service",
         host: hostDropIn(etc & "a9e-th@.service.d",
                          "[Service]\nDynamicUser=no\nUser=\nNoExecPaths=\n")),
    Case(name: "a9e-ti@.service", expect: @["a drop-in the add-on did not install"], service: "",
         probes: "a9e-ti@1.service a9e-ti@2.service",
         extra: dropIn("a9e-ti@1.service", "[Service]\nEnvironment=A9E=1\n"),
         host: hostDropIn(etc & "a9e-ti@2.service.d",
                          "[Service]\nDynamicUser=no\nUser=\nNoExecPaths=\n")),
    # Review round 5.
    Case(name: "a9e-envwild.service", expect: @["wildcard"], service: "EnvironmentFile=/etc/*/a9e.env\n"),
    Case(name: "a9e-envstate.service", expect: @["/var/lib/a9e-envs/env"],
         service: "StateDirectory=a9e-envs\nEnvironmentFile=-/var/lib/a9e-envs/env\n"),
    Case(name: "a9e-rt.service", expect: @["realtime"],
         service: "CPUSchedulingPolicy=fifo\nCPUSchedulingPriority=10\n"),
    Case(name: "a9e-fail.service", expect: @["FailureAction"], service: "FailureAction=reboot-force\n"),
    Case(name: "a9e-memlock.service", expect: @["LimitMEMLOCK"], service: "LimitMEMLOCK=infinity\n"),
    Case(name: "a9e-sockets.service", expect: @["Sockets=dbus.socket"], service: "Sockets=dbus.socket\n"),
    Case(name: "a9e-special.service", expect: @["(Special)"], service: "",
         activatorOnly: true,
         extra: "systemd.systemUnit {\n  name = \"a9e-special.socket\"\n" &
                "  content = \"[Socket]\nListenSpecial=/etc/a9e-target\n" &
                "Writable=yes\n\n[Install]\nWantedBy=sockets.target\n\"\n" &
                "  enabled = true\n}\n"),
    Case(name: "a9e-shade.service", expect: @["privileged group shade"], service: "User=a9s\n",
         host: "getent group shade >/dev/null || groupadd -o -g " &
               "$(getent group shadow | cut -d: -f3) shade; id a9s >/dev/null " &
               "2>&1 || useradd -r -M -s /usr/sbin/nologin -G shade a9s"),
    # Review round 6: what only the host's systemd and account databases
    # decide. A static account in sudo under DynamicUser=yes (systemd uses
    # it); a second name for uid 0; a dependency that reboots the host; the
    # first of two EnvironmentFile= lines. (A hand-written LoadCredential=
    # is refused in add-on mode before the floor sees it, since a unit gets
    # secrets only through its `credentials` field, so the effective check's
    # own reading of it is a unit test: t_addon_floor_round6.)
    Case(name: "a9e-dynstatic.service", expect: @["privileged group sudo"], service: "DynamicUser=yes\nUser=a9d\n",
         host: "id a9d >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin " &
               "-G sudo a9d"),
    Case(name: "a9e-alias.service", expect: @["runs as root"], service: "User=a9z\n",
         host: "id a9z >/dev/null 2>&1 || useradd -o -u 0 -M -s " &
               "/usr/sbin/nologin a9z"),
    Case(name: "a9e-onfail.service", expect: @["reboot.target"], service: "",
         unitLines: "OnFailure=reboot.target\n"),
    Case(name: "a9e-envtwo.service", expect: @["/etc/a9e-one.env"],
         service: "EnvironmentFile=/etc/a9e-one.env\nEnvironmentFile=/etc/a9e-two.env\n",
         host: "printf 'A=1\\n' > /etc/a9e-one.env; chown nobody /etc/a9e-one.env; " &
               "printf 'B=1\\n' > /etc/a9e-two.env"),
    # Review round 7. EnvironmentFile= naming a host file (root-owned, 0644)
    # and another service's secrets (§13 decision 50); a RuntimeDirectory=
    # in the add-on's tree and one at /run/systemd, which exists and is
    # root's; a system-state target reached through a unit of the profile,
    # and an isolating job mode (both through OnFailure= of a unit that
    # succeeds, so nothing fires if a build lets them through); an activator
    # socket with Mark= (CAP_NET_ADMIN).
    Case(name: "a9e-envhost.service", expect: @["/etc/a9e-host.env"], service: "EnvironmentFile=/etc/a9e-host.env\n",
         host: "printf 'A=1\\n' > /etc/a9e-host.env; chmod 0644 /etc/a9e-host.env"),
    Case(name: "a9e-envsecret.service", expect: @["/run/repro/secrets/a9e-other/env"],
         service: "EnvironmentFile=-/run/repro/secrets/a9e-other/env\n"),
    Case(name: "a9e-rtrepro.service", expect: @["/run/repro/a9e-x"], service: "User=a9e\nRuntimeDirectory=repro/a9e-x\n"),
    Case(name: "a9e-reach.service", expect: @["reboot.target"], service: "",
         unitLines: "OnFailure=a9e-reach-x.target\n",
         extra: "systemd.systemUnit {\n  name = \"a9e-reach-x.target\"\n" &
                "  content = \"[Unit]\nWants=reboot.target\n\"\n  enabled = false\n}\n"),
    Case(name: "a9e-isolate.service", expect: @["changes the system's state beyond the unit"], service: "",
         unitLines: "OnFailure=multi-user.target\nOnFailureJobMode=isolate\n"),
    Case(name: "a9e-mark.service", expect: @["Mark=1"], service: "",
         activatorOnly: true,
         extra: "systemd.systemUnit {\n  name = \"a9e-mark.socket\"\n" &
                "  content = \"[Socket]\nListenStream=127.0.0.1:18091\nMark=1\n\n" &
                "[Install]\nWantedBy=sockets.target\n\"\n  enabled = true\n}\n"),
    # §13 decision 55: Conflicts= naming a unit the profile does not define
    # (a base service that is harmless to stop, if a build lets it through).
    Case(name: "a9e-conflicts.service", expect: @["Conflicts=systemd-timesyncd.service names a unit"], service: "",
         unitLines: "Conflicts=systemd-timesyncd.service\n"),
    # Review round 8: a profile target the unit reaches, conflicting with a
    # base service (decision 55, the reviewer's open question); directories
    # inside other software's trees (finding 1). Last, because a build that
    # lets them through changes the host for every later case: a directory
    # handed to the service at /run/systemd, the existing /run/systemd itself.
    Case(name: "a9e-rconf.service", expect: @["reached from a9e-rconf.service"], service: "",
         unitLines: "Wants=a9e-rconf-x.target\n",
         extra: "systemd.systemUnit {\n  name = \"a9e-rconf-x.target\"\n" &
                "  content = \"[Unit]\nConflicts=systemd-timesyncd.service\n\"\n" &
                "  enabled = false\n}\n"),
    Case(name: "a9e-udev.service", expect: @["udev is not"], service: "User=a9e\nRuntimeDirectory=udev/rules.d\n"),
    Case(name: "a9e-rtnested.service", expect: @["systemd is not"],
         service: "User=a9e\nRuntimeDirectory=systemd/system/zz-a9e.service.d\n"),
    Case(name: "a9e-rtsys.service", expect: @["systemd is not", "/run/systemd: it exists"], service: "User=a9e\nRuntimeDirectory=systemd\n")]

proc invocation(g: Guest; unit: string): string =
  g.exec("systemctl show -p InvocationID --value " & unit).stdout.strip()

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
    discard g.run("useradd -r -M -s /usr/sbin/nologin a9e; " &
                  "mkdir -p /var/lib/a9e-rw")
    let binary = g.run("ls -d /repro/store/prefixes/repro-addon/*/bin/repro " &
                       "| head -1").strip()
    let prefix = binary[0 ..< binary.len - "/bin/repro".len]
    let head = "addOn {\n  managedEtcPrefixes = []\n}\n\n"
    # The positive control: a plain floored unit applies and starts.
    var r = g.applyProfile(repro, "control", head &
      unitResource("a9e-control.service", "", binary))
    step("a plain floored unit applies", r.exitCode == 0, r.stdout & r.stderr)
    step("and starts", g.invocation("a9e-control.service").len > 0, "")
    let effectiveOnly = mutation() == "floor-static-r3-disabled"
    # A floored unit bound to an apt closure applies (round 4, finding 5:
    # the closure's read-only /usr bind was taken for a writable place, and
    # every such unit was refused). No FixtureFloorWaiver.
    let deb = aptFixtureDeb(g.runDir, "a9e-closure", g.base.debArch)
    discard g.run("mkdir -p " & AddOnAptDebCacheDir & " && chmod 0700 " &
                  AddOnAptDebCacheDir)
    g.copyTo(deb.path, AddOnAptDebCacheDir & "/" & deb.lock.debs[0].sha256 &
             ".deb")
    r = g.applyProfile(repro, "apt", head &
      unitResource("a9e-control.service", "", binary) &
      "systemd.systemUnit {\n  name = \"a9e-apt.service\"\n  content = " &
      "\"[Service]\nType=oneshot\nUser=a9e\nExecStart=/usr/bin/true\n\"\n" &
      "  enabled = false\n  aptClosureLock = \"" &
      renderAptClosureLock(deb.lock) & "\"\n}\n")
    step("a floored unit bound to an apt closure applies (no waiver)",
         r.exitCode == 0, r.stdout & r.stderr)
    step("systemd shows its closure bind read-only",
         "apt-closure" in g.exec("systemctl show -p BindReadOnlyPaths " &
           "a9e-apt.service").stdout, "")
    discard g.applyProfile(repro, "back", head &
      unitResource("a9e-control.service", "", binary))
    var results = newJArray()
    let unchecked = mutation() == "floor-unchecked"
    var healthy = true
    for c in cases(binary, prefix):
      # Each case on a host the previous one left as the control's: every
      # case unit stopped and reset, host drop-ins gone, the control applied,
      # and systemd answering (round 8, finding 4: a case judged on a broken
      # host proves nothing). The destructive cases run last.
      if not healthy:
        step(c.name & ": not exercised (the host was left unusable)", false, "")
        continue
      let base = head & unitResource("a9e-control.service", "", binary)
      if c.host.len > 0:
        discard g.run(c.host & "; systemctl daemon-reload")
      let text = base & unitResource(c.name, c.service, binary, c.unitLines,
                                     enabled = not c.activatorOnly) & c.extra
      r = g.applyProfile(repro, c.name.split('.')[0].replace("@", "-"), text)
      let output = r.stdout & r.stderr
      let probes = if c.probes.len > 0: c.probes.splitWhitespace()
                   elif c.activatorOnly: @[c.name.replace(".service", ".socket")]
                   elif c.name.contains("@."): @[c.name.replace("@.", "@1.")]
                   else: @[c.name]
      var started = false
      for u in probes:
        # A refused unit is gone with its generation and cannot start; one
        # the switch left behind would start here.
        discard g.exec("systemctl start " & u & " 2>/dev/null; true")
        if g.invocation(u).len > 0: started = true
      var held = false
      if r.exitCode == 0 and c.coveredPlace.len > 0 and started:
        var show = initTable[string, string]()
        for l in g.exec("systemctl show -p User,DynamicUser,NoExecPaths " &
                        c.name).stdout.splitLines():
          let eq = l.find('=')
          if eq > 0: show[l[0 ..< eq]] = l[eq + 1 .. ^1]
        let user = show.getOrDefault("User")
        let notRoot = show.getOrDefault("DynamicUser") == "yes" or
                      (user.len > 0 and user notin ["root", "0"])
        var noexec = false
        for t in show.getOrDefault("NoExecPaths").splitWhitespace():
          if t.strip(leading = true, trailing = false, chars = {'-'}) ==
              c.coveredPlace: noexec = true
        held = notRoot and noexec
      var ownRule = false
      for m in c.expect:
        if m in output: ownRule = true
      results.add(%*{"case": c.name, "exit": r.exitCode, "started": started,
                     "held": held, "ownRule": ownRule,
                     "output": output[max(0, output.len - 6000) .. ^1]})
      if c.coveredPlace.len > 0 and r.exitCode == 0:
        step(c.name & ": runs, holding its floor (not root, the place " &
             "noexec)", held and not effectiveOnly, output)
      else:
        step(c.name & ": refused, never started", r.exitCode != 0 and
             not started, output)
        if effectiveOnly:
          step(c.name & ": refused by the effective-unit check",
               "EAddOnFloorNotEffective" in output, output)
          # By the rule the case targets, not by another (round 8, finding
          # 4: the drop-in allowlist stood in for the route rule).
          step(c.name & ": refused by its own rule (" & c.expect.join(" | ") & ")",
               ownRule, output)
      if unchecked and c.coveredPlace.len == 0:
        # Under the falsifier only the floor stands between the case and its
        # start: a case refused for any other reason proves nothing.
        step(c.name & ": under floor-unchecked it starts (nothing but the " &
             "floor refuses it)", started, output)
      # The host back on the control's generation: every case unit stopped
      # and reset, no host drop-in left behind.
      discard g.run(HostCleanup & "; rm -f /etc/a9e-out; echo orig > /etc/a9e-target; " &
        "systemctl stop 'a9e-*' 2>/dev/null; systemctl reset-failed 'a9e-*' " &
        "2>/dev/null; systemctl daemon-reload; true")
      let back = g.applyProfile(repro, "back", head &
        unitResource("a9e-control.service", "", binary))
      let sys = g.exec("systemctl is-system-running 2>&1; systemctl show -p Version --value")
      healthy = back.exitCode == 0 and sys.exitCode == 0 and
        ("running" in sys.stdout or "degraded" in sys.stdout)
      if not healthy:
        step("after " & c.name & ", the host is back on the control and " &
             "systemd answers", false, back.stdout & back.stderr & sys.stdout)
    record["cases"] = results
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
  test "a floored unit never starts weaker than its floor":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
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
