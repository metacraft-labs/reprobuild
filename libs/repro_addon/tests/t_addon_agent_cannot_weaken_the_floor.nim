## An unattended (deploy-agent) apply may not weaken a service's
## confinement (ReproOS Add-On Mode §10.1, *An agent apply never weakens
## the floor*): a new whole-floor waiver, a new named exception, or a
## waived unit moved onto root, gid 0 or a privileged group is an
## operator's apply, exactly as a strengthening of the floor already was.
## So is adding, changing or removing a drop-in over a unit the profile
## does not define (a distribution package's, which the floor does not
## cover and which may run as root).
##
## Before this rule the asymmetry was the defect recorded in reprobuild-pm
## ``issues/2026-11-12-agent-applies-can-weaken-confinement-unattended-but-cannot-strengthen-it-so-the-management.md``:
## an agent tick could add root units and new exceptions, printed only in
## a plan nobody reads, while removing an exception needed an operator.
##
## Falsifying builds (``scripts/run_addon_unit_mutation.sh``):
## ``-d:reproAddonMutation=agent-may-weaken-floor`` turns every weakening
## case red; ``agent-may-change-package-dropins`` turns the package
## drop-in cases red.
##
## No mocks. The profiles are parsed by the production parsers the add-on
## plan uses -- the stored generation by ``parseStoredUserProfile``, the
## target by ``parseAddOnUserProfile`` -- and the agent's refusal set is
## computed by the production procs the plan calls. The plan itself
## (``runAddonApply`` with ``planOnly``) cannot be driven here: on the
## NixOS build host ``/etc/systemd/system`` is a symbolic link, which the
## collision pass refuses before the floor is looked at (threat model
## G29). A non-plan agent apply needs root and a bootstrapped host; the VM
## gates provide those.

import std/[os, strutils, unittest]

import repro_infra
import repro_infra/intent
import repro_infra/service_floor
import repro_addon/[addon_apply, cli, ledger]

const Prefix = "/repro/store/prefixes/svc/1.0"

proc unitStanza(name, service: string; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=x\n\n[Service]\n" & service & "\n[Install]\n" &
    "WantedBy=multi-user.target\n\"\n" & extra & "}\n"

proc waived(why: string): string =
  "  floorExceptions = [\"serviceFloor: " & why & "\"]\n"

const Accounts = "passwd.user {\n  name = \"svc\"\n}\n\n"

proc storedAs(installed: string): string =
  ## The stored generation an add-on apply of the profile ``installed``
  ## leaves (``runAddonApply`` stores ``renderProfileText`` of the profile
  ## as the add-on parsed it): a unit the floor reached, waived or not,
  ## carries ``hardening = "serviceFloor"`` and its floor version.
  renderProfileText(parseAddOnUserProfile(installed))

proc planOf(previousStored, target: string): AddonApplyResult =
  ## The confinement changes the add-on plan of ``target`` reports on a
  ## host whose current generation is ``previousStored`` (stored form; ""
  ## for a host with none), parsed as the plan parses them.
  let state = getTempDir() / ("repro-addon-weaken-" & $getCurrentProcessId())
  removeDir(state)
  createDir(state)
  defer: removeDir(state)
  let previous = if previousStored.len > 0:
                   parseStoredUserProfile(previousStored, state)
                 else: SystemProfile()
  planFloorChanges(result, previous, Ledger(), parseAddOnUserProfile(target))

suite "an agent apply cannot weaken the floor":
  test "a new waiver, a new exception and root under a waiver need an operator":
    let previous = Accounts &
      # floored, no exception
      unitStanza("a.service", "User=svc\nExecStart=" & Prefix & "/bin/a\n") &
      # floored, no exception
      unitStanza("b.service", "User=svc\nExecStart=" & Prefix & "/bin/b\n") &
      # waived, as an unprivileged account
      unitStanza("e.service", "User=svc\nExecStart=" & Prefix & "/bin/e\n",
                 waived("an operator approved it")) &
      # floored with an exception the target keeps
      unitStanza("f.service", "User=svc\nExecStart=" & Prefix & "/bin/f\n",
                 "  floorExceptions = [\"UMask: shares files\"]\n") &
      # waived as root, approved by an operator
      unitStanza("g.service", "ExecStart=" & Prefix & "/bin/g --v1\n",
                 waived("an operator approved root"))
    let target = Accounts &
      # a new named exception
      unitStanza("a.service", "User=svc\nExecStart=" & Prefix & "/bin/a\n",
                 "  floorExceptions = [\"UMask: shares files\"]\n") &
      # a new whole-floor waiver (it runs as root: no User=)
      unitStanza("b.service", "ExecStart=" & Prefix & "/bin/b\n",
                 waived("a signed profile says so")) &
      # a new unit with a waiver
      unitStanza("c.service", "ExecStart=" & Prefix & "/bin/c\n",
                 waived("a signed profile says so")) &
      # a new unit with a named exception
      unitStanza("d.service", "User=svc\nExecStart=" & Prefix & "/bin/d\n",
                 "  floorExceptions = [\"UMask: shares files\"]\n") &
      # a waived unit moved onto root
      unitStanza("e.service", "User=root\nExecStart=" & Prefix & "/bin/e\n",
                 waived("an operator approved it")) &
      # unchanged confinement: never named
      unitStanza("f.service", "User=svc\nExecStart=" & Prefix & "/bin/f\n",
                 "  floorExceptions = [\"UMask: shares files\"]\n") &
      unitStanza("g.service", "ExecStart=" & Prefix & "/bin/g --v2\n",
                 waived("an operator approved root"))
    let r = planOf(storedAs(previous), target)
    # What the agent refuses: the production decision ``runAddonApply``
    # raises ``AddonNeedsOperator`` (``aoOperatorAction``) from.
    let refused = agentApplyRefusal(r)
    checkpoint "the agent's refusal: " & refused
    check refused.startsWith("operator action required")
    for u in ["a.service", "b.service", "c.service", "d.service",
              "e.service"]:
      checkpoint u & " weakens its confinement in an unattended apply"
      check u in refused
    for u in ["f.service", "g.service"]:
      check u notin refused
    check r.floorWeakened == @[
      "a.service (floor version " & FloorVersion & ", exception UMask added)",
      "b.service (whole floor waived; runs as root)",
      "c.service (whole floor waived on a new unit; runs as root)",
      "d.service (floor version " & FloorVersion &
        ", exception UMask added on a new unit)",
      "e.service (whole floor waived; account changes: runs as root)"]
    # Each is printed in the operator's plan, apart from the other lists.
    let rendered = renderAddonSections(r)
    check "service floor weakened" in rendered
    for l in r.floorWeakened: check ("  " & l & "\n") in rendered

  test "a privileged group given to a waived unit's account needs an operator":
    let unit = unitStanza("e.service", "User=svc\nExecStart=" & Prefix &
                          "/bin/e\n", waived("an operator approved it"))
    let r = planOf(storedAs(Accounts & unit),
      "passwd.user {\n  name = \"svc\"\n  groups = [\"sudo\"]\n}\n\n" & unit)
    check r.floorWeakened ==
      @["e.service (whole floor waived; account changes: runs in the " &
        "privileged group sudo)"]
    check "e.service" in agentApplyRefusal(r)

  test "a drop-in that moves a waived unit onto root needs an operator":
    # The account is read from the unit and the profile's drop-ins onto it,
    # as systemd reads it: a drop-in's User= wins.
    let unit = unitStanza("e.service", "User=svc\nExecStart=" & Prefix &
                          "/bin/e\n", waived("an operator approved it"))
    let r = planOf(storedAs(Accounts & unit), Accounts & unit &
      "systemd.systemDropIn {\n  unit = \"e.service\"\n  name = \"root\"\n" &
      "  content = \"[Service]\nUser=root\n\"\n}\n")
    check r.floorWeakened ==
      @["e.service (whole floor waived; account changes: runs as root)"]
    check "e.service" in agentApplyRefusal(r)

  test "a waived unit given a root command or capabilities needs an operator":
    # The account stays svc, but a '+' or '!' command, PermissionsStartOnly=
    # or ambient capabilities run with root's powers all the same.
    let before = Accounts & unitStanza("e.service", "User=svc\nExecStart=" &
      Prefix & "/bin/e\n", waived("an operator approved it"))
    for (service, why) in [
        ("ExecStartPre=+" & Prefix & "/bin/setup\n",
         "runs ExecStartPre=+" & Prefix & "/bin/setup as root"),
        ("ExecStartPre=!" & Prefix & "/bin/setup\n",
         "runs ExecStartPre=!" & Prefix & "/bin/setup as root"),
        ("PermissionsStartOnly=yes\nExecStartPre=" & Prefix & "/bin/setup\n",
         "runs its other commands as root (PermissionsStartOnly=)"),
        ("AmbientCapabilities=CAP_SYS_ADMIN\n",
         "runs with the ambient capabilities CAP_SYS_ADMIN")]:
      checkpoint service
      let r = planOf(storedAs(before), Accounts & unitStanza("e.service",
        "User=svc\n" & service & "ExecStart=" & Prefix & "/bin/e\n",
        waived("an operator approved it")))
      check r.floorWeakened ==
        @["e.service (whole floor waived; account changes: " & why & ")"]
      check "e.service" in agentApplyRefusal(r)

  test "a unit installed before the floor and now waived as root needs an operator":
    # Unconfined before (no floor) and after (waived): only its account
    # can weaken, and running as root where it ran as svc does.
    let prefloor = Accounts & unitStanza("p.service", "User=svc\nExecStart=" &
      Prefix & "/bin/p\n")
    let r = planOf(prefloor, Accounts & unitStanza("p.service", "ExecStart=" &
      Prefix & "/bin/p\n", waived("now as root")))
    check r.floorIntroduced.len == 0
    check r.floorWeakened ==
      @["p.service (whole floor waived; account changes: runs as root)"]
    check "p.service" in agentApplyRefusal(r)

  test "a unit that ran no command, now waived with one, needs an operator":
    # A socket with no command line had nothing to confine; a waiver that
    # comes with its first command line is a new root command.
    let socket = "systemd.systemUnit {\n  name = \"s.socket\"\n  content = " &
      "\"[Unit]\nDescription=x\n\n[Socket]\nListenStream=/run/s.sock\n" &
      "%EXEC%\n[Install]\nWantedBy=sockets.target\n\"\n%EXTRA%}\n"
    let r = planOf(storedAs(socket.replace("%EXEC%", "").replace("%EXTRA%", "")),
      socket.replace("%EXEC%", "ExecStartPre=" & Prefix & "/bin/s\n").
        replace("%EXTRA%", waived("prepares the socket")))
    check r.floorWeakened == @["s.socket (whole floor waived; runs as root)"]
    check "s.socket" in agentApplyRefusal(r)

  test "an exception that adds a value needs an operator":
    let unit = proc(adds: string): string =
      Accounts & unitStanza("f.service", "User=svc\nExecStart=" & Prefix &
        "/bin/f\n", "  floorExceptions = [\"AmbientCapabilities+" & adds &
        ": binds a low port\"]\n")
    let r = planOf(storedAs(unit("CAP_NET_BIND_SERVICE")),
                   unit("CAP_NET_BIND_SERVICE CAP_NET_RAW"))
    check r.floorWeakened == @["f.service (floor version " & FloorVersion &
      ", exception AmbientCapabilities+CAP_NET_BIND_SERVICE CAP_NET_RAW added)"]
    check "f.service" in agentApplyRefusal(r)

  test "a drop-in over a package's unit needs an operator":
    # cron.service is the distribution's and runs as root; the floor does
    # not cover it. A drop-in can give it a command line, an account or an
    # environment (LD_PRELOAD) that runs with root's powers, so adding,
    # changing or removing one is an operator's apply.
    let dropIn = proc(service: string): string =
      "systemd.systemDropIn {\n  unit = \"cron.service\"\n  name = \"tune\"\n" &
        "  content = \"[Service]\n" & service & "\"\n}\n"
    let collision = proc(service: string): string =
      "systemd.systemUnit {\n  name = \"ssh-agent.service\"\n" &
        "  content = \"[Service]\n" & service & "\"\n" &
        "  collision = \"dropIn\"\n}\n"
    let path = "/etc/systemd/system/cron.service.d/50-repro-tune.conf"
    let base = Accounts & unitStanza("a.service", "User=svc\nExecStart=" &
      Prefix & "/bin/a\n")
    for (before, after, want) in [
        ("", dropIn("ExecStartPre=" & Prefix & "/bin/x\n"),
         "cron.service (drop-in over a unit the profile does not define " &
           "added: " & path & ")"),
        (dropIn("Nice=5\n"), dropIn("Environment=LD_PRELOAD=" & Prefix &
           "/lib/x.so\n"),
         "cron.service (drop-in over a unit the profile does not define " &
           "changed: " & path & ")"),
        (dropIn("User=nobody\n"), "",
         "cron.service (drop-in over a unit the profile does not define " &
           "removed: " & path & ")"),
        ("", collision("User=root\n"),
         "ssh-agent.service (drop-in over a unit the profile does not " &
           "define added: collision = dropIn: ssh-agent.service)")]:
      checkpoint after
      let r = planOf(storedAs(base & before), base & after)
      check r.floorWeakened == @[want]
      let refused = agentApplyRefusal(r)
      check refused.startsWith("operator action required")
      check ("changes a drop-in over a unit the profile does not define") in
        refused
    # On a host with no generation, a profile's first such drop-in is an
    # operator's apply too.
    check planOf("", base & dropIn("Nice=5\n")).floorWeakened.len == 1

  test "a drop-in that cannot change what a package's unit runs is not refused":
    # The same drop-in again, and a drop-in with no [Service] and no
    # command line (an ordering), change nothing that runs.
    let base = Accounts & unitStanza("a.service", "User=svc\nExecStart=" &
      Prefix & "/bin/a\n")
    let same = base & "systemd.systemDropIn {\n  unit = \"cron.service\"\n" &
      "  name = \"tune\"\n  content = \"[Service]\nNice=5\n\"\n}\n"
    check planOf(storedAs(same), same).floorWeakened.len == 0
    let ordering = base & "systemd.systemDropIn {\n  unit = \"cron.service\"\n" &
      "  name = \"order\"\n  content = \"[Unit]\nAfter=a.service\n\"\n}\n"
    let r = planOf(storedAs(base), ordering)
    check r.floorWeakened.len == 0
    check agentApplyRefusal(r) == ""

  test "a root service's first deployment is an operator's apply":
    # A host with no stored generation: every waiver is new.
    let r = planOf("", unitStanza("c.service", "ExecStart=" & Prefix &
      "/bin/c\n", waived("a root service")))
    check r.floorWeakened ==
      @["c.service (whole floor waived on a new unit; runs as root)"]
    check agentApplyRefusal(r).len > 0

  test "after an operator deploys a root service, the agent applies it beside a floored one":
    # The adversarial-audit bed's shape (``t_e2e_addon_audit_bed``, gate
    # ``addon_adversarial_audit_bed``):
    # the agent's sequence 1 carries a waived root service and a new
    # floored one. Straight onto the bootstrapped host (no stored user
    # generation) the agent refuses it; once an operator has applied the
    # waived service, the same sequence is the agent's to apply.
    let waivedRoot = unitStanza("w.service", "ExecStart=/bin/sleep infinity\n",
                                waived("a test fixture"))
    let target = waivedRoot &
      unitStanza("f.service", "ExecStart=" & Prefix & "/bin/f 864000\n")
    let straight = planOf("", target)
    check straight.floorWeakened ==
      @["w.service (whole floor waived on a new unit; runs as root)"]
    check agentApplyRefusal(straight).len > 0
    let afterOperator = planOf(storedAs(waivedRoot), target)
    check afterOperator.floorWeakened.len == 0
    check afterOperator.floorIntroduced.len == 0
    check agentApplyRefusal(afterOperator) == ""

  test "a legacy agent's units are taken over as they run":
    # A migration commits what the legacy agent already applied: the
    # add-on has no generation to compare with, but nothing on the host is
    # weakened, so only the stricter-floor half refuses.
    let r = planOf("", unitStanza("c.service", "ExecStart=" & Prefix &
      "/bin/c\n", waived("installed by the legacy agent")))
    check r.floorWeakened.len == 1
    check agentApplyRefusal(r, migration = true) == ""
    check agentApplyRefusal(r).len > 0

  test "what does not weaken confinement is not refused":
    # The same profile again; a unit installed before the floor (stored
    # without ``hardening``) and now waived keeps what it had: no floor.
    let profile = Accounts & unitStanza("f.service", "User=svc\nExecStart=" &
      Prefix & "/bin/f\n", "  floorExceptions = [\"UMask: shares files\"]\n")
    let same = planOf(storedAs(profile), profile)
    check same.floorWeakened.len == 0
    check same.floorIntroduced.len == 0
    check agentApplyRefusal(same) == ""
    let prefloor = unitStanza("p.service", "ExecStart=" & Prefix & "/bin/p\n")
    let r = planOf(prefloor, unitStanza("p.service", "ExecStart=" & Prefix &
      "/bin/p\n", waived("kept as it ran")))
    check r.floorWeakened.len == 0
    check r.floorIntroduced.len == 0
    check agentApplyRefusal(r) == ""
    # A waived unit as an account the profile does not create (the host's
    # www-data), or with capabilities and a root command it already had,
    # whose command line changes: its privilege is what it was.
    for service in ["User=www-data\n",
                    "User=svc\nAmbientCapabilities=CAP_NET_BIND_SERVICE\n" &
                      "ExecStartPre=+" & Prefix & "/bin/setup\n"]:
      checkpoint service
      let waivedUnit = proc(v: string): string =
        Accounts & unitStanza("w.service", service & "ExecStart=" & Prefix &
          "/bin/w --" & v & "\n", waived("an operator approved it"))
      let w = planOf(storedAs(waivedUnit("v1")), waivedUnit("v2"))
      check w.floorWeakened.len == 0
      check agentApplyRefusal(w) == ""
    # Dropping an exception is still refused, as a stricter floor.
    let stricter = planOf(storedAs(profile), Accounts & unitStanza("f.service",
      "User=svc\nExecStart=" & Prefix & "/bin/f\n"))
    check stricter.floorWeakened.len == 0
    check "exception UMask removed" in agentApplyRefusal(stricter)
