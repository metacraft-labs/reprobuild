## The hardening floor after A9's review round 3 (ReproOS Add-On Mode spec
## §10.1, *Amended 2026-11-04*): the allowlist and the parse-time refusals
## of floor version 4, and the effective-unit check
## (``repro_addon/effective_floor``) on ``systemctl show`` output in the
## forms systemd 252, 255, 257 and 259 print (measured in the review's VM
## experiment; e.g. ``BindPaths=/var/lib/x:/srv/y:rbind``, and ``User=``
## empty with ``DynamicUser=no`` for a unit that runs as root).
##
## Falsifying builds: ``floor-static-r3-disabled`` turns every case of the
## first two suites red; ``store-objects-by-string``,
## ``floor-change-ignores-exceptions`` and ``template-observed-by-name``
## turn their own case red.
##
## Mocks: none for the floor. The effective-unit cases feed the pure
## comparison ``effectiveFloorProblems`` with ``systemctl show`` text written
## out here, because what systemd prints is the input under test; the VM
## gate ``e2e_addon_floor_effective_unit_is_checked`` reads it from real
## systemd.

import std/[sets, strutils, tables, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_infra/service_floor
import repro_addon/addon_apply
import repro_addon/effective_floor
import repro_addon/ledger
import repro_addon/collision

const Prefix = "/repro/store/prefixes/svc/1.0"

proc unitStanza(name, service: string; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=x\n\n[Service]\n" & service & "\n[Install]\n" &
    "WantedBy=multi-user.target\n\"\n" & extra & "}\n"

proc dropInStanza(unit, content: string): string =
  "systemd.systemDropIn {\n  unit = \"" & unit & "\"\n  name = \"x\"\n" &
    "  content = \"" & content & "\"\n}\n"

proc refused(text: string): string =
  try:
    discard parseAddOnUserProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

proc rendered(text: string; name = "a.service"): string =
  for r in parseAddOnUserProfile(text).resources:
    if r.kind == srkSystemdSystemUnit and r.suName == name:
      return renderedSystemUnitContent(r)

let plain = unitStanza("a.service", "User=a\nExecStart=" & Prefix & "/bin/svc\n")

suite "round 3: the parse-time half (red under floor-static-r3-disabled)":
  test "finding 1: no spelling of root gets past the account checks":
    for service in ["User=\n", "User=%u\n", "User=00\n", "User=\"a\"\n",
                    "DynamicUser=n\n", "DynamicUser=false\n",
                    "DynamicUser=0\n", "User=a\nUser=\n",
                    "DynamicUser=no\n", "Group=%g\n"]:
      checkpoint service
      check refused(unitStanza("a.service", service & "ExecStart=" & Prefix &
        "/bin/svc\n")).len > 0
    for c in ["[Service]\nUser=\n", "[Service]\nUser=b\n",
              "[Service]\nDynamicUser=no\n"]:
      checkpoint c
      check refused(plain & dropInStanza("a.service", c)).len > 0
    # What is accepted: a literal account, DynamicUser=yes, or nothing (a
    # dynamic user is rendered).
    check refused(plain) == ""
    check "DynamicUser=yes\n" in rendered(unitStanza("a.service",
      "ExecStart=" & Prefix & "/bin/svc\n"))
    check refused(unitStanza("a.service", "DynamicUser=yes\nExecStart=" &
      Prefix & "/bin/svc\n")) == ""

  test "finding 2: every writable place the unit sets up is noexec":
    let u = rendered(unitStanza("a.service", "User=a\n" &
      "ReadWritePaths=/var/lib/a-rw -/var/lib/a-opt\n" &
      "BindPaths=/var/lib/a-src:/srv/a-b\n" &
      "TemporaryFileSystem=/srv/a-t:mode=1777\n" &
      "StateDirectory=a-st\nExecStart=" & Prefix & "/bin/svc\n"))
    for p in ["-/var/lib/a-rw", "-/var/lib/a-opt", "-/srv/a-b", "-/srv/a-t",
              "-/var/lib/a-st"]:
      checkpoint p
      check (" " & p) in u
    check "TemporaryFileSystem" in refused(unitStanza("a.service",
      "User=a\nTemporaryFileSystem=/srv/t:mode=1777,exec\nExecStart=" &
      Prefix & "/bin/svc\n"))
    for c in ["[Service]\nStateDirectory=evil\n",
              "[Service]\nRuntimeDirectory=evil\n",
              "[Service]\nReadWritePaths=/var/lib/evil\n",
              "[Service]\nBindPaths=/var/lib/a:/srv/evil\n",
              "[Service]\nTemporaryFileSystem=/srv/evil\n"]:
      checkpoint c
      check refused(plain & dropInStanza("a.service", c)).len > 0

  test "no writable place in /proc or /sys; a private keyring; real paths":
    for service in ["ReadWritePaths=/proc\n", "ReadWritePaths=-/proc/self\n",
                    "BindPaths=/proc:/proc\n", "ReadWritePaths=/sys/fs\n",
                    "KeyringMode=shared\n"]:
      checkpoint service
      check refused(unitStanza("a.service", "User=a\n" & service &
        "ExecStart=" & Prefix & "/bin/svc\n")).len > 0
    check refused(plain & dropInStanza("a.service",
      "[Service]\nReadOnlyPaths=-\n")).len > 0

  test "finding 3: a quoted, escaped or specifier path is refused":
    for service in ["BindPaths=/var/lib/x:'" & Prefix & "/drop'\n",
                    "BindPaths=\\\"/var/lib/x:" & Prefix & "/bin\\\"\n",
                    "ReadWritePaths='/usr'\n",
                    "TemporaryFileSystem='" & Prefix & "'\n",
                    "ReadOnlyPaths='/srv'\n",
                    "WorkingDirectory=%h\n",
                    "StateDirectory=%N\n"]:
      checkpoint service
      check refused(unitStanza("a.service", "User=a\n" & service &
        "ExecStart=" & Prefix & "/bin/svc\n")).len > 0

  test "finding 4: an instance's drop-in over a floored template":
    let tpl = unitStanza("foo-bar@.service", "User=a\nExecStart=" & Prefix &
      "/bin/svc\n")
    const weak = "[Service]\nMemoryDenyWriteExecute=no\n"
    check refused(tpl & dropInStanza("foo-bar@1.service", weak)).len > 0
    check refused(tpl & dropInStanza("foo-bar@.service", weak)).len > 0
    check dropInApplies("foo-bar@1.service", "foo-bar@.service")
    check not dropInApplies("foo-baz@1.service", "foo-bar@.service")

  test "finding 5: a collision = dropIn unit is judged as a drop-in":
    let t = plain & "systemd.systemUnit {\n  name = \"a.service\"\n" &
      "  collision = \"dropIn\"\n  content = \"[Service]\nUser=\n\"\n}\n"
    check refused(t).len > 0

  test "finding 6: PAMName= is refused outright":
    check "PAMName" in refused(unitStanza("a.service", "User=a\n" &
      "PAMName=login\nExecStart=" & Prefix & "/bin/svc\n"))
    check "PAMName" in refused(plain & dropInStanza("a.service",
      "[Service]\nPAMName=login\n"))
    check "PAMName" in refused(unitStanza("a.service", "User=a\n" &
      "PAMName=login\nExecStart=" & Prefix & "/bin/svc\n",
      "  floorExceptions = [\"PAMName: needs a session\"]\n"))

  test "the allowlist: a key outside it is refused (round 4: no exception names it)":
    for service in ["MountAPIVFS=yes\n", "Delegate=yes\n",
                    "DeviceAllow=/dev/sda rw\n", "TTYPath=/dev/tty1\n"]:
      checkpoint service
      let s = unitStanza("a.service", "User=a\n" & service & "ExecStart=" &
        Prefix & "/bin/svc\n")
      check "allowlist" in refused(s)
      let key = service.split('=')[0]
      check "names no serviceFloor setting" in refused(unitStanza("a.service",
        "User=a\n" & service & "ExecStart=" & Prefix & "/bin/svc\n",
        "  floorExceptions = [\"" & key & ": a fixture\"]\n"))
    check "allowlist" in refused(unitStanza("a.service", "User=a\n" &
      "ExecStart=" & Prefix & "/bin/svc\n").replace("[Unit]\n",
      "[Unit]\nJoinsNamespaceOf=other.service\n"))
    check refused(unitStanza("a.service", "User=a\nExecStart=" & Prefix &
      "/bin/svc\n").replace("[Install]", "[X-Extra]\nFoo=1\n\n[Install]")).len > 0

suite "round 3: the point fixes":
  test "finding 7: the store scan reads paths as systemd does":
    # Red under store-objects-by-string.
    for spelled in ["/repro//store/prefixes/h/2/bin/h",
                    "/repro/./store/prefixes/h/2/bin/h",
                    "/repro/store//prefixes/h/2/bin/h"]:
      checkpoint spelled
      check "/repro/store/prefixes/h/2" in referencedStoreObjects(
        "[Service]\nEnvironment=HELPER=" & spelled & "\n")

  test "finding 9: removing an exception is a floor change":
    # Red under floor-change-ignores-exceptions.
    let previous = parseStoredUserProfile(unitStanza("a.service",
      "User=a\nExecStart=" & Prefix & "/bin/svc\n",
      "  hardening = \"serviceFloor\"\n  floorVersion = \"" & FloorVersion &
      "\"\n  floorExceptions = [\"MemoryDenyWriteExecute: a JIT\"]\n"))
    let target = parseAddOnUserProfile(plain)
    check floorIntroducedUnits(previous, Ledger(), target.resources) ==
      @["a.service (floor version " & FloorVersion &
        ", exception MemoryDenyWriteExecute removed)"]

  test "a floored template is observed through a probe instance":
    # systemctl refuses to show ``foo@.service``; without this the add-on
    # could install no template at all, and an instance drop-in over one
    # (finding 4) never reached the effective-unit check.
    check templateObservationName("a9e-tpl@.service") ==
      "a9e-tpl@" & TemplateProbeInstance & ".service"
    check templateObservationName("a9e-tpl@1.service") == "a9e-tpl@1.service"
    check templateObservationName("plain.service") == "plain.service"
    check templateObservationName("a@b@.socket") == "a@b@.socket"

suite "round 3: the effective-unit check":
  let ru = rendered(plain)
  let fb = floorBlock(ru)

  proc goodShow(): ShowProps =
    ## What systemd shows for the unit when it holds its floor.
    result = parseShow("LoadState=loaded\nUser=a\nGroup=\nDynamicUser=no\n" &
      "SupplementaryGroups=\nPAMName=\nDropInPaths=\n" &
      "SystemCallFilter=read write close openat\n" &
      "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n" &
      "ReadWritePaths=\nBindPaths=\nTemporaryFileSystem=\nStateDirectory=\n" &
      "RootDirectory=\nRootImage=\nMountImages=\nExtensionImages=\n" &
      "ExtensionDirectories=\n")
    for k, vs in fb:
      if k notin ["SystemCallFilter", "NoExecPaths", "ExecPaths",
                  "RestrictAddressFamilies"]:
        result[k] = vs[^1]
    var ne: seq[string]
    for l in fb["NoExecPaths"]: ne.add(l.splitWhitespace())
    result["NoExecPaths"] = ne.join(" ")
    result["ExecPaths"] = fb["ExecPaths"].join(" ")

  let denied = toHashSet(["memfd_create", "shmat", "mount", "reboot"])
  proc uid(n: string): int = (if n == "root": 0 else: 1000)

  proc noGroups(n: string): seq[string] = @[]
  proc problems(show: ShowProps; version = FloorVersion;
                own: seq[string] = @[]): seq[string] =
    var e = EffectiveInput(unit: "a.service", rendered: ru, version: version,
      show: show, denied: denied, uidOf: uid, groupsOf: noGroups,
      gidOf: proc (g: string): int = (if g == "root": 0 else: 1000))
    e.lines["ExecStartEx"] = @["{ path=" & Prefix & "/bin/svc ; argv[]=" &
      Prefix & "/bin/svc ; flags= ; start_time=[n/a] }"]
    for o in own: e.ownDropIns.add((path: o, content: ""))
    effectiveFloorProblems(e)

  test "a unit that holds its floor has no problem":
    check problems(goodShow()).len == 0

  test "it catches what the parse-time half missed (findings 1-5)":
    var s = goodShow()
    s["User"] = ""          # a drop-in's User= reset, DynamicUser= no
    check "runs as root" in problems(s).join()
    s = goodShow()
    s["ReadWritePaths"] = "/var/lib/rw"
    check "writable place /var/lib/rw" in problems(s).join()
    s = goodShow()
    s["BindPaths"] = "/var/lib/a:" & Prefix & "/drop:rbind"
    check "overlaps ExecPaths" in problems(s).join()
    s = goodShow()
    s["TemporaryFileSystem"] = "/srv/t:mode=1777,exec"
    check "writable place /srv/t" in problems(s).join()
    s = goodShow()
    s["ReadWritePaths"] = "/proc"
    check "in or over /proc" in problems(s).join()
    s = goodShow()
    s["StateDirectory"] = "evil"
    check "/var/lib/evil" in problems(s).join()
    s = goodShow()
    s["MemoryDenyWriteExecute"] = "no"
    s["DropInPaths"] = "/etc/systemd/system/a.service.d/50-x.conf"
    let p = problems(s).join()
    check "MemoryDenyWriteExecute=no" in p
    check "not one the add-on installed" in p
    # ... a drop-in the add-on installed itself is not (the distribution's
    # is, since round 4: t_addon_floor_round4)
    s = goodShow()
    s["DropInPaths"] = "/etc/systemd/system/a.service.d/x.conf"
    check problems(s, own = @["/etc/systemd/system/a.service.d/x.conf"]).len == 0

  test "denied calls, PAMName and LoadState":
    var s = goodShow()
    s["SystemCallFilter"] = "read write memfd_create"
    check "allows memfd_create" in problems(s).join()
    s = goodShow()
    s["PAMName"] = "login"
    check "PAMName=login" in problems(s).join()
    s = goodShow()
    s["LoadState"] = "bad-setting"
    check "not loaded" in problems(s).join()

  test "a stored unit is held to the floor it was stored under":
    # Version 1 did not refuse root; version 2 did; PAMName= and the
    # writable places are version 4's.
    var s = goodShow()
    s["User"] = "root"
    check problems(s, "1").join().find("runs as root") < 0
    check "runs as root" in problems(s, "2").join()
    s = goodShow()
    s["PAMName"] = "login"
    s["ReadWritePaths"] = "/var/lib/rw"
    check problems(s, "3").len == 0

  test "the deny line is expanded with the base's groups":
    let groups = parseSyscallGroups("@privileged\n    # x\n    \e[0m@chown\n" &
      "    mount\n@chown\n    chown\n    fchown\n@system-service\n    read\n")
    let d = deniedCalls("[Service]\n" & FloorMarker & "\n" &
      "SystemCallFilter=@system-service\n" &
      "SystemCallFilter=~@privileged memfd_create\n" &
      "SystemCallFilter=fchown\n", groups)
    check d == toHashSet(["chown", "mount", "memfd_create"])
