## Unit tests for the collision observer: the dpkg driver's reading of the
## package database, the §4.3 decision table over every row, the symlink
## refusal and the before-each-write re-check.
##
## *Mocking.* The dpkg driver reads a fixture tree under a temporary root
## (real ``info/*.list``, ``*.conffiles`` and ``diversions`` files in the
## formats dpkg writes), and the targets are real files in that tree. The
## one substitution is ``unitProvision``: the build host has no guest's
## ``systemctl``, so the unit-provision query is a closure over a table
## of what ``systemctl show`` reports on Debian 13 for a package unit, a
## hand-written unit and a unit that does not exist. The real query is
## exercised by the VM gates (``tests/e2e/addon``), which also cover the
## apply path these decisions feed.

import std/[os, posix, strutils, tables, unittest]

import repro_elevation
import repro_infra/addon_diagnostics
import repro_addon/[collision, etc_write, fingerprint]

let root = getTempDir() / ("repro-addon-collision-" & $getCurrentProcessId())
removeDir(root)
createDir(root / "var/lib/dpkg/info")
createDir(root / "etc/ssh/sshd_config.d")
createDir(root / "etc/app")
createDir(root / "etc/systemd/system")
writeFile(root / "var/lib/dpkg/status", "Package: x\n")
# The fixture's dpkg database lists the paths as they are under the
# fixture root, so the ownership lookups and the file reads agree, as they
# do on a real host where both are rooted at `/`.
proc at(path: string): string = root / path
proc listing(paths: varargs[string]): string =
  for p in paths: result.add(at(p) & "\n")
writeFile(root / "var/lib/dpkg/info/openssh-server.list",
          "/.\n" & listing("/etc", "/etc/ssh", "/usr/sbin/sshd"))
writeFile(root / "var/lib/dpkg/info/openssh-client.list",
          listing("/etc/ssh/ssh_config"))
writeFile(root / "var/lib/dpkg/info/openssh-client.conffiles",
          listing("/etc/ssh/ssh_config"))
writeFile(root / "var/lib/dpkg/info/cron.list",
          listing("/usr/lib/systemd/system/cron.service", "/usr/sbin/cron"))
writeFile(root / "var/lib/dpkg/info/libc6:amd64.list",
          listing("/etc/ld.so.conf.d/x86_64-linux-gnu.conf"))
writeFile(root / "var/lib/dpkg/info/base-files.list",
          listing("/etc/legacy.conf", "/etc/issue.net"))
writeFile(root / "var/lib/dpkg/info/base-files.conffiles",
          "remove-on-upgrade " & at("/etc/legacy.conf") & "\n" &
          at("/etc/issue.net") & " obsolete\n")
createDir(root / "var/lib/ucf")
writeFile(root / "var/lib/ucf/registry",
          "openssh-server " & at("/etc/ssh/sshd_config") & "\n" &
          "\n" & "broken-line\n" & "other-pkg " & at("/etc/other/ucf.conf") & "\n")
writeFile(root / "var/lib/dpkg/diversions",
          at("/etc/foreign") & "\n" & at("/etc/foreign.other") & "\nsomepkg\n" &
          at("/etc/mine") & "\n" & at("/etc/mine.distrib") & "\n:\n")

var units = {
  "cron.service": UnitProvision(loadState: "loaded",
    fragmentPath: "/usr/lib/systemd/system/cron.service",
    unitFileState: "enabled", activeState: "active"),
  "hand.service": UnitProvision(loadState: "loaded",
    fragmentPath: "/etc/systemd/system/hand.service",
    unitFileState: "disabled", activeState: "inactive"),
  "new.service": UnitProvision(loadState: "not-found"),
  "transient.service": UnitProvision(loadState: "loaded",
    fragmentPath: "/run/systemd/system/transient.service",
    unitFileState: "transient", activeState: "active"),
  "generated.service": UnitProvision(loadState: "loaded",
    fragmentPath: "/run/systemd/generator.late/generated.service",
    unitFileState: "generated", activeState: "inactive"),
  "local.service": UnitProvision(loadState: "loaded",
    fragmentPath: "/usr/local/lib/systemd/system/local.service",
    unitFileState: "disabled", activeState: "inactive"),
  "masked.service": UnitProvision(loadState: "masked-runtime",
    fragmentPath: "/run/systemd/system/masked.service",
    unitFileState: "masked-runtime", activeState: "inactive"),
}.toTable

proc provision(unit: string): UnitProvision {.gcsafe.} =
  {.cast(gcsafe).}:
    units.getOrDefault(unit)

let d = newDpkgDriver(root, provision)

suite "the dpkg driver":
  test "package ownership from info/*.list, conffiles from *.conffiles":
    let o = d.packageOwner(at("/etc/ssh/ssh_config"))
    check o.package == "openssh-client" and o.conffile and not o.viaUcf
    check d.packageOwner(at("/usr/sbin/sshd")).package == "openssh-server"
    check not d.packageOwner(at("/usr/sbin/sshd")).conffile
    check d.packageOwner(at("/etc/app/app.conf")).package == ""

  test "an architecture-qualified instance names its package":
    check d.packageOwner(at("/etc/ld.so.conf.d/x86_64-linux-gnu.conf")).package == "libc6"

  test "conffile flags (remove-on-upgrade, obsolete) are not part of the path":
    check d.packageOwner(at("/etc/legacy.conf")).conffile
    check d.packageOwner(at("/etc/issue.net")).conffile
    check d.packageOwner(at("/etc/issue.net")).package == "base-files"

  test "a ucf-registered file is package-owned (the fourth record), as a conffile":
    let o = d.packageOwner(at("/etc/ssh/sshd_config"))
    check o.package == "openssh-server" and o.conffile and o.viaUcf
    check not d.packageOwner(at("/etc/ssh/ssh_config")).viaUcf
    let r = parseUcfRegistry("pkg /etc/a\nbad\n\nother\t/etc/b\n")
    check r.len == 2 and r["/etc/a"] == "pkg" and r["/etc/b"] == "other"

  test "diversions come from dpkg's database":
    let f = d.diversion(at("/etc/foreign"))
    check f.present and f.package == "somepkg" and f.divertTo == at("/etc/foreign.other")
    let m = d.diversion(at("/etc/mine"))
    check m.present and m.package == ":" and m.divertTo == at("/etc/mine.distrib")
    check not d.diversion(at("/etc/app/app.conf")).present

  test "unit provision is parsed from systemctl show output":
    let u = unitProvisionFromShow("LoadState=loaded\nFragmentPath=/usr/lib/systemd/system/cron.service\n" &
      "DropInPaths=/etc/systemd/system/cron.service.d/a.conf /etc/systemd/system/cron.service.d/b.conf\n" &
      "UnitFileState=enabled\nActiveState=active\n")
    check u.fragmentPath == "/usr/lib/systemd/system/cron.service"
    check u.dropInPaths.len == 2 and u.unitFileState == "enabled"

  test "the drop-in hint names a .d directory the program reads":
    check d.dropInHint(at("/etc/ssh/sshd_config")) == at("/etc/ssh/sshd_config") & ".d/"
    check d.dropInHint(at("/etc/app/app.conf")) == ""

proc fileInputs(address, content: string; collision = "";
                ledgerSha = ""; reconcile = false; adopt = false;
                diverted = false): DecisionInputs =
  DecisionInputs(address: address, kind: tkFile, desiredContent: content,
    desiredSha256: sha256Hex(content), collision: collision,
    ledgerOwns: ledgerSha.len > 0, ledgerSha256: ledgerSha,
    reconcileDrift: reconcile, adopt: adopt, divertedByProfile: diverted)

suite "the decision table, file rows":
  test "absent and unowned: create":
    let (dec, _) = d.decide(fileInputs("f", "x"), at("/etc/app/new.conf"))
    check dec.verdict == cvCreate and dec.observation == "absent"

  test "present, unowned, identical: adopted silently with the bytes kept":
    writeFile(at("/etc/app/same.conf"), "same\n")
    let (dec, _) = d.decide(fileInputs("f", "same\n"), at("/etc/app/same.conf"))
    check dec.verdict == cvAdopt and dec.preWriteBytes == "same\n"
    check dec.observation == "unowned"

  test "present, unowned, different: EDrift; adopt claims it; reconcile replaces":
    writeFile(at("/etc/app/diff.conf"), "theirs\n")
    expect AddonDriftError:
      discard d.decide(fileInputs("f", "ours\n"), at("/etc/app/diff.conf"))
    let (a, _) = d.decide(fileInputs("f", "ours\n", adopt = true), at("/etc/app/diff.conf"))
    check a.verdict == cvAdopt and a.preWriteBytes == "theirs\n"
    let (r, _) = d.decide(fileInputs("f", "ours\n", reconcile = true), at("/etc/app/diff.conf"))
    check r.verdict == cvReconcile and r.preWriteBytes == "theirs\n"

  test "the ledger owns it: update, no-op, or EDrift when changed":
    writeFile(at("/etc/app/owned.conf"), "v1\n")
    let (u, _) = d.decide(fileInputs("f", "v2\n", ledgerSha = sha256Hex("v1\n")), at("/etc/app/owned.conf"))
    check u.verdict == cvUpdate
    let (n, _) = d.decide(fileInputs("f", "v1\n", ledgerSha = sha256Hex("v1\n")), at("/etc/app/owned.conf"))
    check n.verdict == cvNoOp
    expect AddonDriftError:
      discard d.decide(fileInputs("f", "v2\n", ledgerSha = sha256Hex("v0\n")), at("/etc/app/owned.conf"))
    let (rc, _) = d.decide(fileInputs("f", "v2\n", ledgerSha = sha256Hex("v0\n"), reconcile = true), at("/etc/app/owned.conf"))
    check rc.verdict == cvReconcile and rc.preWriteBytes == "v1\n"
    # Changed out of band to exactly the desired bytes (a writer outside
    # the switch applied the same profile; spec §9 "Migration"): nothing
    # conflicts, nothing is written. At reprobuild 63757c8dd8 this was
    # EDrift, which refused rpi2's caches.conf.
    let (same, _) = d.decide(fileInputs("f", "v1\n", ledgerSha = sha256Hex("v0\n")), at("/etc/app/owned.conf"))
    check same.verdict == cvNoOp

  test "package-owned conffile: EAddOnPackageOwned naming the package and the drop-in":
    # The fixture's dpkg index lists the dpkg-side path; the driver is
    # asked about that path and the file need not exist for the row.
    try:
      discard d.decide(fileInputs("sshd", "Port 22\n"), at("/etc/ssh/sshd_config"))
      check false
    except EAddOnPackageOwned as e:
      check e.package == "openssh-server" and e.conffile
      check e.diagnostic == adPackageOwned
      check e.msg.startsWith("EAddOnPackageOwned: ")
      # The hint is read below the fixture root for a rooted path only;
      # the dpkg-side path has no `.d` under the host root here.
      check e.path == at("/etc/ssh/sshd_config")
      check e.dropInHint == at("/etc/ssh/sshd_config") & ".d/"

  test "a ucf-managed file is package-owned and cannot be diverted, naming ucf and the drop-in":
    try:
      discard d.decide(fileInputs("sshd", "Port 22\n"), at("/etc/ssh/sshd_config"))
      check false
    except EAddOnPackageOwned as e:
      check e.package == "openssh-server" and e.conffile
    for inp in [fileInputs("sshd", "Port 22\n", collision = "divert"),
                fileInputs("sshd", "Port 22\n", diverted = true)]:
      try:
        discard d.decide(inp, at("/etc/ssh/sshd_config"))
        check false
      except AddonCollisionError as e:
        check "through ucf" in e.msg and "cannot be diverted" in e.msg
        check (at("/etc/ssh/sshd_config") & ".d/") in e.msg
    # The diversion itself is refused the same way.
    expect AddonCollisionError:
      discard d.decide(DecisionInputs(address: "dv", kind: tkDiversion),
                       at("/etc/ssh/sshd_config"))

  test "package-owned with the divert opt-in (field or declared diversion): divert":
    let (a, _) = d.decide(fileInputs("ssh", "Host *\n", collision = "divert"), at("/etc/ssh/ssh_config"))
    check a.verdict == cvDivert and a.observation == "conffile:openssh-client"
    let (b, _) = d.decide(fileInputs("ssh", "Host *\n", diverted = true), at("/etc/ssh/ssh_config"))
    check b.verdict == cvDivert

  test "a foreign diversion is refused, opt-in or not":
    expect AddonCollisionError:
      discard d.decide(fileInputs("f", "x", collision = "divert"), at("/etc/foreign"))
    expect AddonCollisionError:
      discard d.decide(DecisionInputs(address: "dv", kind: tkDiversion), at("/etc/foreign"))

  test "a diversion the ledger does not list is foreign even when it is local and named <path>.distrib":
    writeFile(root / "var/lib/dpkg/info/mine.list", listing("/etc/mine"))
    let d3 = newDpkgDriver(root, provision)
    expect AddonCollisionError:
      discard d3.decide(DecisionInputs(address: "dv", kind: tkDiversion), at("/etc/mine"))
    expect AddonCollisionError:
      discard d3.decide(fileInputs("f", "x", collision = "divert"), at("/etc/mine"))
    # The ledger's own diversion is a no-op for the diversion and lets the
    # file through.
    let (own, _) = d3.decide(DecisionInputs(address: "dv", kind: tkDiversion,
      ledgerOwns: true), at("/etc/mine"))
    check own.verdict == cvNoOp
    var fi = fileInputs("f", "x", collision = "divert")
    fi.ledgerOwnsDiversion = true
    let (fd, _) = d3.decide(fi, at("/etc/mine"))
    check fd.verdict == cvDivert

  test "a diversion of an unowned path is refused; of an owned one, created":
    expect AddonCollisionError:
      discard d.decide(DecisionInputs(address: "dv", kind: tkDiversion), at("/etc/app/new.conf"))
    let (c, _) = d.decide(DecisionInputs(address: "dv", kind: tkDiversion), at("/etc/ssh/ssh_config"))
    check c.verdict == cvCreate

suite "the decision table, unit rows":
  proc unitInputs(unit, content: string; collision = ""; ledgerSha = ""): DecisionInputs =
    DecisionInputs(address: "systemUnit:" & unit, kind: tkUnit, unit: unit,
      desiredContent: content, desiredSha256: sha256Hex(content),
      collision: collision, ledgerOwns: ledgerSha.len > 0, ledgerSha256: ledgerSha)

  test "a package unit: EAddOnUnitShadows naming the fragment":
    try:
      discard d.decide(unitInputs("cron.service", "[Unit]\n"), at("/etc/systemd/system/cron.service"))
      check false
    except EAddOnUnitShadows as e:
      check e.unit == "cron.service"
      check e.fragmentPath == "/usr/lib/systemd/system/cron.service"

  test "a package unit with replace: replace; with dropIn: drop-in":
    let (r, _) = d.decide(unitInputs("cron.service", "[Unit]\n", collision = "replace"), at("/etc/systemd/system/cron.service"))
    check r.verdict == cvReplace and r.observation == "unit:/usr/lib/systemd/system/cron.service"
    let (di, _) = d.decide(unitInputs("cron.service", "[Service]\n", collision = "dropIn"), at("/etc/systemd/system/cron.service"))
    check di.verdict == cvDropIn

  test "a hand-written /etc unit, not in the ledger: adopt when identical, else EDrift":
    writeFile(at("/etc/systemd/system/hand.service"), "[Unit]\nDescription=hand\n")
    let (a, _) = d.decide(unitInputs("hand.service", "[Unit]\nDescription=hand\n"), at("/etc/systemd/system/hand.service"))
    check a.verdict == cvAdopt
    expect AddonDriftError:
      discard d.decide(unitInputs("hand.service", "[Unit]\nDescription=other\n"), at("/etc/systemd/system/hand.service"))

  test "no unit of that name anywhere: create":
    let (c, _) = d.decide(unitInputs("new.service", "[Unit]\n"), at("/etc/systemd/system/new.service"))
    check c.verdict == cvCreate and c.observation == "absent"

  test "a transient, generated, local or masked unit is refused with no opt-in":
    for u in ["transient.service", "generated.service", "local.service", "masked.service"]:
      for c in ["", "replace", "dropIn"]:
        expect AddonCollisionError:
          discard d.decide(unitInputs(u, "[Unit]\n", collision = c), at("/etc/systemd/system/" & u))
    check classifyUnit(units["transient.service"]) == ucElsewhere
    check classifyUnit(units["local.service"]) == ucElsewhere
    check classifyUnit(units["masked.service"]) == ucMasked
    check classifyUnit(units["cron.service"]) == ucPackage
    check classifyUnit(units["hand.service"]) == ucEtc
    check classifyUnit(units["new.service"]) == ucNone

  test "a drop-in for a unit nothing provides is refused":
    try:
      discard d.decide(unitInputs("new.service", "[Service]\n", collision = "dropIn"), at("/etc/systemd/system/new.service"))
      check false
    except AddonCollisionError as e:
      check "nothing provides new.service" in e.msg

  test "drop-in paths follow the spec's naming":
    check dropInPath("cron.service", "") == "/etc/systemd/system/cron.service.d/50-repro-addon.conf"
    check dropInPath("cron.service", "hardening") == "/etc/systemd/system/cron.service.d/50-repro-hardening.conf"

suite "symbolic links on the target path":
  test "a link component is refused at plan time, naming the link":
    createDir(at("/usr/lib/app"))
    discard posix.symlink(cstring(at("/usr/lib/app")), cstring(at("/etc/app/linked")))
    try:
      discard d.decide(fileInputs("f", "x"), at("/etc/app/linked/x.conf"))
      check false
    except AddonCollisionError as e:
      check at("/etc/app/linked") in e.msg
      check "symbolic link" in e.msg
    writeFile(at("/usr/lib/app/target"), "t")
    discard posix.symlink(cstring(at("/usr/lib/app/target")), cstring(at("/etc/app/leaf.conf")))
    try:
      discard d.decide(fileInputs("f", "x"), at("/etc/app/leaf.conf"))
      check false
    except AddonCollisionError as e:
      check at("/etc/app/leaf.conf") in e.msg
    check readFile(at("/usr/lib/app/target")) == "t"

  test "symlinkComponent names the first link and ignores what does not exist":
    check symlinkComponent(at("/etc/app/linked/x/y")) == at("/etc/app/linked")
    check symlinkComponent(at("/etc/app/none/x")) == ""

let sameDriver: DriverFactory = proc(): CollisionDriver {.gcsafe.} =
  {.cast(gcsafe).}: d

suite "the before-each-write re-check":
  test "the plan's decision stands while the host still matches":
    writeFile(at("/etc/app/guarded.conf"), "g\n")
    let (dec, _) = d.decide(fileInputs("f", "g\n"), at("/etc/app/guarded.conf"))
    let t = PlannedTarget(address: "f", path: at("/etc/app/guarded.conf"),
      kind: tkFile, observation: dec.observation,
      observedSha256: dec.observedSha256, verdict: dec.verdict)
    check preWriteRefusal(d, t) == ""
    writeFile(at("/etc/app/guarded.conf"), "changed\n")
    check "changed since the plan" in preWriteRefusal(d, t)
    writeFile(at("/etc/app/guarded.conf"), "g\n")
    removeFile(at("/etc/app/guarded.conf"))
    discard posix.symlink(cstring(at("/usr/lib/app/target")), cstring(at("/etc/app/guarded.conf")))
    check "symbolic link" in preWriteRefusal(d, t)

  test "a package that appeared since the plan refuses the write, through the guard the apply uses":
    writeFile(at("/etc/app/late.conf"), "l\n")
    # The guard takes the SAME factory the apply does. The apply hands it
    # the one driver it planned with, so the index that driver read at
    # plan time must not be what decides a write: it is re-read once the
    # package database changed (`indexStamp`).
    let factory: DriverFactory = proc(): CollisionDriver {.gcsafe.} =
      {.cast(gcsafe).}: newDpkgDriver(root, provision)
    let planDriver = factory()
    let (dec, _) = planDriver.decide(fileInputs("systemFile:" & at("/etc/app/late.conf"), "l\n"),
                                     at("/etc/app/late.conf"))
    let t = PlannedTarget(address: "systemFile:" & at("/etc/app/late.conf"),
      path: at("/etc/app/late.conf"), kind: tkFile, observation: dec.observation,
      observedSha256: dec.observedSha256, verdict: dec.verdict)
    let guard = makePreWriteGuard(factory, @[t])
    let op = PrivilegedOperation(kind: pokFsSystemFile, address: t.address,
      sfPath: at("/etc/app/late.conf"), sfContent: "l\n")
    check guard(op) == ""
    let stampBefore = indexStamp(root)
    writeFile(root / "var/lib/dpkg/info/late.list", listing("/etc/app/late.conf"))
    check indexStamp(root) != stampBefore
    check "ownership observation changed" in guard(op)
    # The plan-time driver sees it as well: its index was read again.
    check "ownership observation changed" in preWriteRefusal(planDriver, t)
    removeFile(root / "var/lib/dpkg/info/late.list")

  test "a local diversion made between the plan and the write refuses it":
    # The ledger's observation text leaves local diversions out (the
    # add-on's own must not change how its file is recorded), so the guard
    # compares the diversion itself.
    writeFile(at("/etc/app/div.conf"), "d\n")
    let inp = fileInputs("f", "d\n")
    let (dec, obs) = d.decide(inp, at("/etc/app/div.conf"))
    let t = plannedTarget("f", inp, at("/etc/app/div.conf"), dec, obs)
    check preWriteRefusal(d, t) == ""
    let db = root / "var/lib/dpkg/diversions"
    let saved = readFile(db)
    writeFile(db, saved & at("/etc/app/div.conf") & "\n" &
              at("/etc/app/div.conf.distrib") & "\n:\n")
    check "the diversion of" in preWriteRefusal(d, t)
    writeFile(db, saved)
    check preWriteRefusal(d, t) == ""

  test "a divert verdict needs exactly the add-on's own diversion, made by the apply":
    # Plan: the dpkg conffile ssh_config, absent diversion, divert opt-in.
    writeFile(at("/etc/ssh/ssh_config"), "pkg\n")
    let inp = fileInputs("ssh", "Host *\n", collision = "divert")
    let (dec, obs) = d.decide(inp, at("/etc/ssh/ssh_config"))
    check dec.verdict == cvDivert
    let t = plannedTarget("ssh", inp, at("/etc/ssh/ssh_config"), dec, obs)
    # Before the diversion operation ran: the write is refused.
    check "is not in place" in preWriteRefusal(d, t)
    # The diversion operation ran: dpkg moved the package's copy aside.
    let db = root / "var/lib/dpkg/diversions"
    let saved = readFile(db)
    moveFile(at("/etc/ssh/ssh_config"), at("/etc/ssh/ssh_config.distrib"))
    writeFile(db, saved & at("/etc/ssh/ssh_config") & "\n" &
              at("/etc/ssh/ssh_config.distrib") & "\n:\n")
    check preWriteRefusal(d, t) == ""
    # A package's diversion (or a local one elsewhere) is not the add-on's.
    writeFile(db, saved & at("/etc/ssh/ssh_config") & "\n" &
              at("/etc/ssh/ssh_config.other") & "\n:\n")
    check "the diversion of" in preWriteRefusal(d, t)
    writeFile(db, saved)
    moveFile(at("/etc/ssh/ssh_config.distrib"), at("/etc/ssh/ssh_config"))
    removeFile(at("/etc/ssh/ssh_config"))

  test "the unit behind a drop-in is re-checked before the drop-in is written":
    let unitInp = DecisionInputs(address: "dropIn:cron", kind: tkUnit,
      unit: "cron.service", collision: "dropIn")
    let (udec, uobs) = d.decide(unitInp, at("/etc/systemd/system/cron.service"))
    check udec.verdict == cvDropIn
    let fileInp = fileInputs("dropIn:cron", "[Service]\nNice=5\n")
    let dpath = at("/etc/systemd/system/cron.service.d/50-repro-addon.conf")
    let (fdec, fobs) = d.decide(fileInp, dpath)
    let guard = makePreWriteGuard(sameDriver,
      @[plannedTarget("dropIn:cron", unitInp, at("/etc/systemd/system/cron.service"), udec, uobs),
        plannedTarget("dropIn:cron", fileInp, dpath, fdec, fobs)])
    let op = PrivilegedOperation(kind: pokSystemdSystemDropIn,
      address: "dropIn:cron", diUnit: "cron.service", diName: "addon",
      diContent: "[Service]\nNice=5\n")
    check guard(op) == ""
    let saved = units["cron.service"]
    # Masked at runtime: the fragment systemd names is still the
    # package's, so the ownership text alone would not change.
    units["cron.service"] = UnitProvision(loadState: "masked-runtime",
      fragmentPath: "/usr/lib/systemd/system/cron.service",
      unitFileState: "masked-runtime", activeState: "inactive")
    check "cron.service is now masked" in guard(op)
    units["cron.service"] = saved
    check guard(op) == ""

  test "a destroy is re-observed: an object changed since the plan is kept, not removed":
    var changed = false
    let destroyCheck: DestroyCheck = proc(op: PrivilegedOperation): string =
      {.cast(gcsafe).}:
        (if changed: "changed since the plan" else: "")
    let guard = makePreWriteGuard(sameDriver, @[], destroyCheck)
    let op = PrivilegedOperation(kind: pokFsSystemFile, address: "f",
      sfPath: at("/etc/app/x"), sfDestroy: true)
    check guard(op) == ""
    changed = true
    let answer = guard(op)
    check answer.startsWith(PreWriteKeepPrefix) and "changed since the plan" in answer
    # Without a check a destroy goes through, as before.
    check makePreWriteGuard(sameDriver, @[])(op) == ""

  test "a foreign diversion of an /etc unit path refuses it even when no file is there":
    let db = root / "var/lib/dpkg/diversions"
    let saved = readFile(db)
    writeFile(db, saved & at("/etc/systemd/system/new.service") & "\n" &
              at("/etc/systemd/system/new.service.x") & "\nsomepkg\n")
    try:
      discard d.decide(DecisionInputs(address: "u", kind: tkUnit,
        unit: "new.service", desiredContent: "[Unit]\n",
        desiredSha256: sha256Hex("[Unit]\n")),
        at("/etc/systemd/system/new.service"))
      check false
    except AddonCollisionError as e:
      check "already diverted" in e.msg
    writeFile(db, saved)

  test "a missing dpkg info directory fails closed":
    let r2 = getTempDir() / ("repro-addon-noinfo-" & $getCurrentProcessId())
    removeDir(r2)
    createDir(r2 / "var/lib/dpkg")
    writeFile(r2 / "var/lib/dpkg/status", "Package: x\n")
    expect AddonCollisionError:
      discard detectCollisionDriver(r2)
    let d2 = newDpkgDriver(r2, provision)
    expect AddonCollisionError:
      discard d2.packageOwner(r2 / "etc/x")
    removeDir(r2)

  test "an operation the plan did not decide on is refused by the guard":
    let factory: DriverFactory = proc(): CollisionDriver {.gcsafe.} =
      {.cast(gcsafe).}: newDpkgDriver(root, provision)
    let guard = makePreWriteGuard(factory, @[])
    let op = PrivilegedOperation(kind: pokFsSystemFile, address: "systemFile:/etc/x",
      sfPath: "/etc/x", sfContent: "x")
    check "decided nothing" in guard(op)

removeDir(root)
