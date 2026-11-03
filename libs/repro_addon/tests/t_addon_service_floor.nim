## The add-on's ``serviceFloor`` default and its named exceptions (ReproOS
## Add-On Mode spec §10.1; deployment security policy CONF-1, CONF-2;
## threat model G12), the parts that need no guest: what the floor renders,
## what it refuses, what an exception lifts, which units get it by
## default, and that every exception reaches the plan. That the rendered
## floor confines a running service is the VM gate's
## (``tests/e2e/addon/t_e2e_addon_service_cannot_exec_outside_closure``).
##
## Mocks: none. Real profile text through the real parser and renderer.
## The floor-version fixtures (``fixtures/floor_versions/v1`` and ``v2``)
## are what the engines of those versions -- reprobuild 1a598170c0 and
## d03bb6759e -- stored and installed for the same sample units, rendered by
## those engines themselves (never written by hand).

import std/[os, sets, strutils, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_addon/addon_apply
import repro_addon/fingerprint
import repro_addon/generation0
import repro_addon/ledger
import repro_addon/pending_plan
import repro_infra/intent

const Prefix = "/repro/store/prefixes/svc/1.0"

proc unitStanza(name, service: string; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=x\n\n[Service]\n" & service & "\n[Install]\n" &
    "WantedBy=multi-user.target\n\"\n" & extra & "}\n"

proc rendered(text: string): string =
  for r in parseAddOnUserProfile(text).resources:
    if r.kind == srkSystemdSystemUnit: return renderedSystemUnitContent(r)

proc refused(text: string): string =
  try:
    discard parseAddOnUserProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

suite "serviceFloor":
  test "the add-on default renders the floor at the end of [Service]":
    let u = rendered(unitStanza("a.service", "User=a\nExecStart=" & Prefix &
                                "/bin/svc --serve\n"))
    for line in ["NoNewPrivileges=yes", "ProtectSystem=strict",
                 "PrivateDevices=yes", "ProtectProc=invisible",
                 "MemoryDenyWriteExecute=yes",
                 "SystemCallFilter=@system-service",
                 "SystemCallFilter=~@privileged @obsolete memfd_create " &
                   "shmget shmat shmdt shmctl",
                 "CapabilityBoundingSet=", "UMask=0077",
                 "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6",
                 "NoExecPaths=/", "ExecPaths=" & Prefix]:
      checkpoint line
      check (line & "\n") in u
    check "DynamicUser=yes" notin u          # it names an account
    # Appended to [Service], before [Install].
    check u.find("ExecPaths=") < u.find("[Install]")
    check u.find("ExecStart=") < u.find("NoNewPrivileges=yes")

  test "a unit without an account becomes a dynamic user":
    check "DynamicUser=yes\n" in rendered(unitStanza("a.service",
      "ExecStart=" & Prefix & "/bin/svc\n"))

  test "every command line's store prefix is executable, nothing else":
    let u = rendered(unitStanza("a.service", "ExecStartPre=" &
      "/repro/store/prefixes/init/2/bin/init x\nExecStart=-" & Prefix &
      "/bin/svc\n"))
    check "ExecPaths=/repro/store/prefixes/init/2 " & Prefix & "\n" in u

  test "a binary outside the closure is refused, an exception lifts it":
    let m = refused(unitStanza("a.service", "ExecStart=/bin/sleep 5\n"))
    check "outside the unit's closure" in m
    check "NoExecPaths" in m
    let u = rendered(unitStanza("a.service", "ExecStart=/bin/sleep 5\n",
      "  floorExceptions = [\"NoExecPaths: runs the base's sleep\"]\n"))
    check "NoExecPaths=/" notin u
    check "ProtectSystem=strict\n" in u
    check "# serviceFloor exception: NoExecPaths: runs the base's sleep" in u

  test "a weakened setting is refused unless it is named":
    let text = unitStanza("a.service", "ExecStart=" & Prefix &
      "/bin/svc\nMemoryDenyWriteExecute=no\n")
    check "MemoryDenyWriteExecute" in refused(text)
    let u = rendered(unitStanza("a.service", "ExecStart=" & Prefix &
      "/bin/svc\nMemoryDenyWriteExecute=no\n",
      "  floorExceptions = [\"MemoryDenyWriteExecute: the JVM needs a JIT\"]\n"))
    check "MemoryDenyWriteExecute=yes" notin u
    check "MemoryDenyWriteExecute=no\n" in u
    # A line equal to the floor's is not a weakening.
    check refused(unitStanza("a.service", "ExecStart=" & Prefix &
      "/bin/svc\nProtectSystem=strict\n")) == ""

  test "the unit's own exec paths, a + command and a ~ family list are refused":
    check "ExecPaths" in refused(unitStanza("a.service", "ExecStart=" &
      Prefix & "/bin/svc\nExecPaths=/usr\n"))
    check "'+' prefix" in refused(unitStanza("a.service", "ExecStart=+" &
      Prefix & "/bin/svc\n"))
    check "RestrictAddressFamilies" in refused(unitStanza("a.service",
      "ExecStart=" & Prefix & "/bin/svc\nRestrictAddressFamilies=~AF_PACKET\n"))
    check "specifier" in refused(unitStanza("a.service",
      "ExecStart=%h/bin/svc\n"))

  test "an exception must name a floor setting and give a reason":
    check "names no serviceFloor setting" in refused(unitStanza("a.service",
      "ExecStart=" & Prefix & "/bin/svc\n",
      "  floorExceptions = [\"Bogus: why\"]\n"))
    check "gives no reason" in refused(unitStanza("a.service",
      "ExecStart=" & Prefix & "/bin/svc\n",
      "  floorExceptions = [\"UMask: \"]\n"))
    check "named twice" in refused(unitStanza("a.service",
      "ExecStart=" & Prefix & "/bin/svc\n",
      "  floorExceptions = [\"UMask: a\", \"UMask: b\"]\n"))

  test "the whole-floor waiver renders the unit exactly as written":
    let content = "[Unit]\nDescription=x\n\n[Service]\nExecStart=/bin/sleep 5\n" &
      "\n[Install]\nWantedBy=multi-user.target\n"
    let text = "systemd.systemUnit {\n  name = \"a.service\"\n  content = \"" &
      content & "\"\n  floorExceptions = [\"serviceFloor: a fixture\"]\n}\n"
    check rendered(text) == content

  test "which units the default reaches":
    # A drop-in over a package's unit, and a unit without [Service], are
    # not the floor's.
    let dropIn = "systemd.systemUnit {\n  name = \"cron.service\"\n" &
      "  content = \"[Service]\nNice=5\n\"\n  collision = \"dropIn\"\n}\n"
    check rendered(dropIn) == "[Service]\nNice=5\n"
    let timer = "systemd.systemUnit {\n  name = \"a.timer\"\n" &
      "  content = \"[Timer]\nOnCalendar=daily\n\"\n}\n"
    check rendered(timer) == "[Timer]\nOnCalendar=daily\n"
    # Outside the add-on the floor applies only where the unit asks.
    let plain = unitStanza("a.service", "ExecStart=/bin/sleep 5\n")
    for r in parseSystemProfile(plain).resources:
      check "NoExecPaths" notin renderedSystemUnitContent(r)
    let asked = unitStanza("a.service", "ExecStart=" & Prefix & "/bin/svc\n",
      "  hardening = \"serviceFloor\"\n")
    for r in parseSystemProfile(asked).resources:
      check "NoExecPaths=/\n" in renderedSystemUnitContent(r)
    check "is not known" in (block:
      var m = ""
      try: discard parseSystemProfile(unitStanza("a.service",
             "ExecStart=/x\n", "  hardening = \"strict\"\n"))
      except ESystemProfileInvalid as e: m = e.msg
      m)

  test "an apt closure's /usr is the closure's executable path":
    const lock = staticRead("../../repro_dsl_stdlib/tests/fixtures/" &
      "apt_closure/debian-trixie-20261001-armhf-node-exporter.lock")
    let u = rendered(unitStanza("a.service",
      "ExecStart=/usr/bin/prometheus-node-exporter\n",
      "  aptClosureLock = \"" & lock & "\"\n"))
    # The closure's own prefix (the bind's source) and the /usr it is
    # bound over.
    check "ExecPaths=/repro/store/prefixes/apt-closure-" in u
    check u.contains(" /usr\n")
    check "BindReadOnlyPaths=" in u

  test "every exception is a plan line":
    let p = parseAddOnUserProfile(unitStanza("a.service",
      "ExecStart=/bin/sleep 5\n",
      "  floorExceptions = [\"NoExecPaths: runs the base's sleep\", " &
      "\"UMask: shares files\"]\n"))
    check floorExceptionPlanLines(p) == @[
      "a.service: NoExecPaths: runs the base's sleep",
      "a.service: UMask: shares files"]

suite "a host upgraded to the floor":
  test "a unit whose floor changes is named, whatever else changes":
    # The previous generation, as an engine stored it: a.service installed
    # before the floor, b.service under version 2, c.service under today's.
    let previous = parseStoredUserProfile(
      unitStanza("a.service", "User=a\nExecStart=" & Prefix & "/bin/svc --v1\n") &
      unitStanza("b.service", "User=b\nExecStart=" & Prefix & "/bin/svc\n",
        "  hardening = \"serviceFloor\"\n  floorVersion = \"2\"\n") &
      unitStanza("c.service", "User=c\nExecStart=" & Prefix & "/bin/svc\n",
        "  hardening = \"serviceFloor\"\n  floorVersion = \"" & FloorVersion &
        "\"\n"))
    # The target: a.service's command line changes in the same generation
    # (A9 review round 2, finding 5: the ledger-bytes rule missed this).
    let target = parseAddOnUserProfile(
      unitStanza("a.service", "User=a\nExecStart=" & Prefix & "/bin/svc --v2\n") &
      unitStanza("b.service", "User=b\nExecStart=" & Prefix & "/bin/svc\n") &
      unitStanza("c.service", "User=c\nExecStart=" & Prefix & "/bin/svc\n") &
      unitStanza("new.service", "User=n\nExecStart=" & Prefix & "/bin/svc\n"))
    check floorIntroducedUnits(previous, Ledger(), target.resources) == @[
      "a.service (no floor -> floor version " & FloorVersion & ")",
      "b.service (floor version 2 -> floor version " & FloorVersion & ")"]
    # A unit the floor does not reach (waived) is never named.
    let waived = parseAddOnUserProfile(unitStanza("a.service",
      "ExecStart=/bin/sleep 5\n",
      "  floorExceptions = [\"serviceFloor: a fixture\"]\n"))
    check floorIntroducedUnits(previous, Ledger(), waived.resources).len == 0

proc dropInStanza(unit, content: string): string =
  "systemd.systemDropIn {\n  unit = \"" & unit & "\"\n  name = \"x\"\n" &
    "  content = \"" & content & "\"\n}\n"

suite "what loosens the floor needs its exception (A9 review)":
  test "a drop-in of a floored unit is judged by the effective unit":
    let unit = unitStanza("a.service", "User=a\nExecStart=" & Prefix &
                          "/bin/svc\n")
    for (content, what) in [
        ("[Service]\nExecStart=\nExecStart=/tmp/evil\n", "outside"),
        ("[Service]\nNoExecPaths=\n", "exec confinement"),
        ("[Service]\nProtectSystem=no\n", "ProtectSystem"),
        ("[Service]\nUser=root\n", "root"),
        ("[Service]\nSystemCallFilter=\n", "SystemCallFilter"),
        ("[Service]\nMemoryDenyWriteExecute=no\n", "MemoryDenyWriteExecute"),
        ("[Unit]\nDescription=x\n[Service]\nExecStartPost=+" & Prefix &
           "/bin/svc\n", "'+' prefix")]:
      checkpoint content
      check what in refused(unit & dropInStanza("a.service", content))
    # A drop-in that touches nothing of the floor stays accepted.
    check refused(unit & dropInStanza("a.service",
      "[Service]\nEnvironment=X=1\n")) == ""
    # And a named exception lets the matching setting through.
    let waivedUnit = unitStanza("a.service", "User=a\nExecStart=" & Prefix &
      "/bin/svc\n", "  floorExceptions = [\"MemoryDenyWriteExecute: a JIT\"]\n")
    check refused(waivedUnit & dropInStanza("a.service",
      "[Service]\nMemoryDenyWriteExecute=no\n")) == ""

  test "settings that loosen the floor without being floor settings":
    for (service, what) in [
        ("ReadWritePaths=/\n", "ReadWritePaths"),
        ("ReadWritePaths=-/usr\n", "ReadWritePaths"),
        ("ReadWritePaths=" & Prefix & "/bin\n", "executable path"),
        ("TemporaryFileSystem=" & Prefix & "\n", "mounts over"),
        ("BindPaths=/tmp/x:" & Prefix & "/bin\n", "mounts over"),
        ("RootDirectory=/srv/root\n", "another root"),
        ("User=root\n", "root"),
        ("DynamicUser=no\n", "root"),
        ("SupplementaryGroups=disk\n", "privileged group"),
        ("Group=root\n", "root")]:
      checkpoint service
      check what in refused(unitStanza("a.service", service & "ExecStart=" &
                                       Prefix & "/bin/svc\n"))
    check "'!' prefix" in refused(unitStanza("a.service", "User=a\n" &
      "ExecStart=!" & Prefix & "/bin/svc\n"))
    # An optional (`-`) closure bind does not make /usr executable.
    check "outside the unit's closure" in refused(unitStanza("a.service",
      "BindReadOnlyPaths=-/repro/store/prefixes/c/1/usr:/usr\n" &
      "ExecStart=/usr/bin/x\n"))
    # Every `;`-separated command is checked.
    check "/bin/evil" in refused(unitStanza("a.service", "User=a\n" &
      "ExecStartPre=" & Prefix & "/bin/svc ; /bin/evil\nExecStart=" &
      Prefix & "/bin/svc\n"))

  test "a command line outside [Service] is refused, not left unconfined":
    let sock = "systemd.systemUnit {\n  name = \"a.socket\"\n  content = \"" &
      "[Socket]\nListenStream=1\nExecStartPre=/bin/true\n\"\n}\n"
    check "outside a [Service]" in refused(sock)

  test "the closure is every prefix the unit names, a launcher's target too":
    # searxng's shape: a shell from the closure execs a prefix's launcher.
    const lock = staticRead("../../repro_dsl_stdlib/tests/fixtures/" &
      "apt_closure/debian-trixie-20261001-armhf-node-exporter.lock")
    let u = rendered(unitStanza("a.service",
      "ExecStart=/bin/sh -c 'exec " & Prefix & "/bin/launch'\n",
      "  aptClosureLock = \"" & lock & "\"\n"))
    var execLine = ""
    for l in u.splitLines():
      if l.startsWith("ExecPaths="): execLine = l
    check Prefix in execLine.split({'=', ' '})
    check execLine.endsWith(" /usr")

  test "memfd_create is denied, and an exception adds back exactly":
    let u = rendered(unitStanza("a.service", "User=a\nExecStart=" & Prefix &
      "/bin/svc\n", "  floorExceptions = [\"SystemCallFilter+@setuid " &
      "memfd_create: a JIT\", \"CapabilityBoundingSet+CAP_NET_RAW: ping\"]\n"))
    check "SystemCallFilter=~@privileged @obsolete memfd_create shmget " &
      "shmat shmdt shmctl\n" in u
    check "SystemCallFilter=@setuid memfd_create\n" in u
    check "CapabilityBoundingSet=CAP_NET_RAW\n" in u
    check "AmbientCapabilities=\n" in u
    check "NoExecPaths=/\n" in u
    check "only SystemCallFilter" in refused(unitStanza("a.service",
      "User=a\nExecStart=" & Prefix & "/bin/svc\n",
      "  floorExceptions = [\"UMask+0022: x\"]\n"))

  test "a unit ending in a continuation does not swallow the floor":
    let u = rendered(unitStanza("a.service", "User=a\nExecStart=" & Prefix &
      "/bin/svc \\\n  --flag\nEnvironment=A=1 \\\n"))
    check "\n\n# serviceFloor" in u or "\\\n\n" in u
    check "\nNoNewPrivileges=yes\n" in u

suite "stored generations keep the rules they were installed with":
  test "a pre-floor stored profile parses, a new one is held to the floor":
    let preFloor = unitStanza("old.service", "ExecStart=/bin/sleep 5\n")
    check "outside the unit's closure" in refused(preFloor)
    for r in parseStoredUserProfile(preFloor).resources:
      check renderedSystemUnitContent(r) ==
        "[Unit]\nDescription=x\n\n[Service]\nExecStart=/bin/sleep 5\n" &
        "\n[Install]\nWantedBy=multi-user.target\n"

suite "A9 review round 2: floor version 3":
  test "the private mounts and the unit's directories are noexec":
    # Red under floor-private-mounts-exec.
    let u = rendered(unitStanza("a.service", "RuntimeDirectory=a-rt\n" &
      "StateDirectory=a-st:a-link\nCacheDirectory=a-c\nLogsDirectory=a-l\n" &
      "ConfigurationDirectory=a-cf\nExecStart=" & Prefix & "/bin/svc\n"))
    check "NoExecPaths=/\nNoExecPaths=-/tmp -/var/tmp -/dev/shm " &
      "-/dev/hugepages -/dev/mqueue -/run -/run/a-rt -/var/lib/a-st -/var/cache/a-c " &
      "-/var/log/a-l -/etc/a-cf\n" in u

  test "/proc is read-only and SysV shared memory is denied":
    # Red under floor-proc-writable and floor-allows-sysv-shm.
    let u = rendered(unitStanza("a.service", "User=a\nExecStart=" & Prefix &
                                "/bin/svc\n"))
    check "\nReadOnlyPaths=/proc\n" in u
    check "SystemCallFilter=~@privileged @obsolete memfd_create shmget " &
      "shmat shmdt shmctl\n" in u
    # An exception adds the calls back after the deny line, or waives /proc.
    let x = rendered(unitStanza("a.service", "User=a\nExecStart=" & Prefix &
      "/bin/svc\n", "  floorExceptions = [\"SystemCallFilter+shmget shmat " &
      "shmdt shmctl: an interlock segment\", \"ReadOnlyPaths: writes " &
      "/proc/self/oom_score_adj\"]\n"))
    check "SystemCallFilter=shmget shmat shmdt shmctl\n" in x
    check "ReadOnlyPaths=/proc" notin x

  test "paths are judged as systemd reads them":
    # Red under floor-paths-unnormalised: each was accepted in round 1.
    for service in [
        "BindPaths=/var/lib/a/x:/repro/./store/prefixes/svc/1.0/bin\n",
        "BindPaths=/var/lib/a/x://repro/store/prefixes/svc/1.0/bin\n",
        "TemporaryFileSystem=/repro/./store/prefixes/svc/1.0\n",
        "ReadWritePaths=/repro/./store/prefixes/svc/1.0/bin\n",
        "ReadWritePaths=/var/lib/a/../../../usr\n",
        "BindPaths=/var/lib/a/x:/repro/store/prefixes/%N/1.0/bin\n"]:
      checkpoint service
      check refused(unitStanza("svc.service", "User=a\n" & service &
        "ExecStart=" & Prefix & "/bin/svc\n")).len > 0
    check "'..' component" in refused(unitStanza("svc.service",
      "User=a\nExecStart=" & Prefix & "/bin/../../../../../tmp/x\n"))
    # The merged-/usr alias: /bin/x is /usr/bin/x, the apt closure's /usr.
    const lock = staticRead("../../repro_dsl_stdlib/tests/fixtures/" &
      "apt_closure/debian-trixie-20261001-armhf-node-exporter.lock")
    check refused(unitStanza("svc.service", "User=a\n" &
      "BindPaths=/var/lib/a/x:/bin/x\nExecStart=/usr/bin/true\n",
      "  aptClosureLock = \"" & lock & "\"\n")).len > 0

  test "images and extensions are refused unless named":
    # Red under floor-allows-images.
    for k in ["MountImages=/var/lib/a/img.raw:" & Prefix & "/bin",
              "ExtensionImages=/var/lib/a/ext.raw",
              "ExtensionDirectories=/var/lib/a/ext"]:
      checkpoint k
      let key = k.split('=')[0]
      check ("name the exception \"" & key) in refused(unitStanza(
        "svc.service", "User=a\n" & k & "\nExecStart=" & Prefix & "/bin/svc\n"))
      check refused(unitStanza("svc.service", "User=a\n" & k &
        "\nExecStart=" & Prefix & "/bin/svc\n",
        "  floorExceptions = [\"" & key & ": a fixture\"]\n")) == ""
      # ... and in a drop-in of the floored unit.
      check refused(unitStanza("svc.service", "User=a\nExecStart=" & Prefix &
        "/bin/svc\n") & dropInStanza("svc.service", "[Service]\n" & k &
        "\n")).len > 0

  test "drop-ins systemd applies by name prefix are judged too":
    # Red under floor-ignores-prefix-dropins.
    let pfx = "/repro/store/prefixes/svc-a/1.0"
    let u = unitStanza("svc-a.service", "User=a\nExecStart=" & pfx & "/bin/svc\n")
    for target in ["svc-a.service", "svc-.service"]:
      checkpoint target
      check refused(u & dropInStanza(target,
        "[Service]\nMemoryDenyWriteExecute=no\n")).len > 0
    let inst = unitStanza("job@x.service", "User=a\nExecStart=" & pfx & "/bin/svc\n")
    check refused(inst & dropInStanza("job@.service",
      "[Service]\nMemoryDenyWriteExecute=no\n")).len > 0
    # A drop-in of another unit's prefix is not this unit's.
    check refused(u & dropInStanza("other-.service",
      "[Service]\nMemoryDenyWriteExecute=no\n")) == ""
    check dropInApplies("a-b-.service", "a-b-c.service")
    check dropInApplies("a-.service", "a-b-c.service")
    check not dropInApplies("a-b.service", "a-b-c.service")
    check not dropInApplies("a-.socket", "a-b.service")

  test "a drop-in that resets ReadOnlyPaths= drops /proc and is refused":
    check "ReadOnlyPaths" in refused(unitStanza("a.service", "User=a\n" &
      "ExecStart=" & Prefix & "/bin/svc\n") & dropInStanza("a.service",
      "[Service]\nReadOnlyPaths=\n"))

  test "a new profile cannot ask for an older floor version":
    check "floorVersion 2" in refused(unitStanza("a.service", "User=a\n" &
      "ExecStart=" & Prefix & "/bin/svc\n", "  floorVersion = \"2\"\n"))

suite "A9 review round 2: stored generations keep their floor version":
  const Fixtures = currentSourcePath().parentDir / "fixtures" / "floor_versions"

  proc storedWith(version, stateDir: string): SystemProfile =
    parseStoredUserProfile(readFile(Fixtures / version / "stored.profile"),
                           stateDir)

  proc ledgerDir(version: string): string =
    ## A state directory whose ledger records the units the engine of
    ## ``version`` installed (their fixture bytes).
    result = getTempDir() / ("a9r2-floor-" & version & "-" & $getCurrentProcessId())
    createDir(result)
    var l = Ledger(generation: "g-" & version)
    for kind, f in walkDir(Fixtures / version):
      if f.endsWith(".service"):
        l.entries.add(LedgerEntry(class: lcUnit,
          path: unitPath(extractFilename(f)), resource: "systemUnit:" &
          extractFilename(f), sha256: sha256Hex(readFile(f))))
    writeFile(result / "addon-ledger", render(l))

  test "every unit an earlier engine stored renders byte for byte":
    # Red under stored-floor-unversioned (today's floor) and
    # stored-profile-floored.
    for version in ["v1", "v2"]:
      let sd = ledgerDir(version)
      for r in storedWith(version, sd).resources:
        if r.kind != srkSystemdSystemUnit: continue
        checkpoint version & " " & r.suName
        check r.suFloorVersion == version[1 .. ^1]
        check renderedSystemUnitContent(r) ==
          readFile(Fixtures / version / r.suName)

  test "without a ledger, a unit only version 1 accepted is still version 1":
    for r in storedWith("v1", "").resources:
      if r.suName == "root.service":
        check r.suFloorVersion == "1"
        check renderedSystemUnitContent(r) ==
          readFile(Fixtures / "v1" / "root.service")

  test "a generation stored today records its version and renders the same":
    let src = unitStanza("a.service", "User=a\nExecStart=" & Prefix &
                         "/bin/svc\n")
    let p = parseAddOnUserProfile(src)
    let stored = renderProfileText(p)
    check ("floorVersion = \"" & FloorVersion & "\"") in stored
    for r in parseStoredUserProfile(stored).resources:
      check renderedSystemUnitContent(r) == rendered(src)

suite "A9 review round 2: the switch's records":
  test "a replay knows whether its target was a stored generation":
    # Red under replay-forgets-stored-target.
    let sd = getTempDir() / ("a9r2-plan-" & $getCurrentProcessId())
    createDir(sd)
    for flag in [true, false]:
      writePendingPlan(sd, PendingPlan(targetUserText: "u", fromUserText: "",
        fromLedgerText: "", storedTarget: flag))
      let back = readPendingPlan(sd)
      check back.storedTargetRecorded
      check back.storedTarget == flag

  test "a drop-in's store prefixes are re-checked before the flip":
    # Red under recheck-skips-dropin-prefixes.
    let p = parseAddOnUserProfile(unitStanza("a.service", "User=a\n" &
      "ExecStart=" & Prefix & "/bin/svc\n") & dropInStanza("a.service",
      "[Service]\nEnvironment=HELPER=/repro/store/prefixes/helper/2/bin/h\n"))
    var named: seq[string]
    for r in p.resources:
      for o in switchStoreObjects(r): named.add(o)
    check "/repro/store/prefixes/helper/2" in named
    check Prefix in named
