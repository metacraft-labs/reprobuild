## Unit tests for the add-on switch's pure parts (ReproOS Add-On Mode
## §7.2, §7.3): the service transition table over every row, the ledger
## v3 (link form, sysctl, account, unit-state and static-link entries and
## the fingerprint expectations they produce), the static tree's naming
## and the pending marker, the no-follow filesystem primitives the switch
## materialises links with, and the text form of the two new kinds and
## the three new unit fields.
##
## No mocks: pure functions over value types, and the real filesystem
## primitives on a temporary tree. The switch's behaviour against a real
## systemd, kernel and store is the VM gates' job (``tests/e2e/addon``).

import std/[os, posix, strutils, tables, unittest]

import repro_elevation/nofollow_write
import repro_infra
import repro_addon/[fingerprint, ledger, static_tree, transitions]

proc facts(unit: string; active = true; enabled = true): UnitFacts =
  UnitFacts(unit: unit, address: "systemUnit:" & unit, owned: true,
            active: active, enabled: enabled)

proc verbsOf(ts: seq[Transition]): seq[string] =
  for t in ts: result.add($t.verb & " " & t.unit)

suite "transition planning (§7.3)":
  test "added unit: started when enabled, left alone otherwise":
    var f = facts("a.service", active = false)
    f.isNew = true
    f.fileChanged = true
    check verbsOf(planTransitions(@[f])) == @["start a.service"]
    f.enabled = false
    check planTransitions(@[f]).len == 0

  test "removed unit: stopped first; stopOnRemoval = false leaves it":
    var r = facts("old.service")
    r.removed = true
    var n = facts("new.service", active = false)
    n.isNew = true
    n.fileChanged = true
    let ts = planTransitions(@[n, r])
    check verbsOf(ts) == @["stop old.service", "start new.service"]
    check verbsOf(preStopEntries(ts)) == @["stop old.service"]
    check verbsOf(startEntries(ts)) == @["start new.service"]
    r.stopHeld = true
    let kept = planTransitions(@[r])
    check kept.len == 1 and kept[0].verb == tvLeave and
      "stopOnRemoval" in kept[0].reason
    check not kept[0].isEffective

  test "a removed inactive unit needs no transition":
    var r = facts("old.service", active = false)
    r.removed = true
    check planTransitions(@[r]).len == 0

  test "changed file, drop-in or dependency restarts an active unit":
    for field in ["file", "dropIn", "deps"]:
      var f = facts("x.service")
      case field
      of "file": f.fileChanged = true
      of "dropIn": f.dropInsChanged = true
      else: f.depsChanged = true
      let ts = planTransitions(@[f])
      check ts.len == 1 and ts[0].verb == tvRestart
      check "changed" in ts[0].reason

  test "an inactive changed unit is started only when enabled":
    var f = facts("x.service", active = false)
    f.fileChanged = true
    check verbsOf(planTransitions(@[f])) == @["start x.service"]
    f.enabled = false
    check planTransitions(@[f]).len == 0

  test "restartIfChanged = false reports a pending restart":
    var f = facts("x.service")
    f.fileChanged = true
    f.restartHeld = true
    let ts = planTransitions(@[f])
    check ts.len == 1 and ts[0].verb == tvLeave and "pending restart" in ts[0].reason

  test "reloadIfChanged reloads when only a dependency changed":
    var f = facts("x.service")
    f.depsChanged = true
    f.reloadIfChanged = true
    check verbsOf(planTransitions(@[f])) == @["reload x.service"]
    f.fileChanged = true
    check verbsOf(planTransitions(@[f])) == @["restart x.service"]

  test "exclusive: stop-start, stopped in the pre-stop step and started after":
    var f = facts("validator.service")
    f.fileChanged = true
    f.exclusive = true
    let ts = planTransitions(@[f])
    check ts.len == 1 and ts[0].verb == tvStopStart and ts[0].exclusive
    check verbsOf(preStopEntries(ts)) == @["stop-start validator.service"]
    check verbsOf(startEntries(ts)) == @["stop-start validator.service"]
    # Exclusive stops come first in the pre-stop step.
    var r = facts("other.service")
    r.removed = true
    let both = preStopEntries(planTransitions(@[r, f]))
    check both[0].unit == "validator.service" and both[1].unit == "other.service"

  test "an unchanged active unit is not touched":
    check planTransitions(@[facts("x.service")]).len == 0

  test "unitState requirements converge activity":
    var f = UnitFacts(unit: "avahi-daemon.service", unitState: true,
                      active: false, desiredActive: true)
    check verbsOf(planTransitions(@[f])) == @["start avahi-daemon.service"]
    f.active = true
    f.desiredActive = false
    check verbsOf(planTransitions(@[f])) == @["stop avahi-daemon.service"]

  test "dependency changes propagate through unit-to-unit edges":
    var a = facts("a.service")
    a.fileChanged = true
    var b = facts("b.service")
    var c = facts("c.service")
    var fs = @[a, b, c]
    propagateDependencyChanges(fs, {"systemUnit:b.service": @["systemUnit:a.service"],
                                    "systemUnit:c.service": @["systemUnit:b.service"]}.toTable)
    check fs[1].depsChanged and fs[2].depsChanged
    check verbsOf(planTransitions(fs)) ==
      @["restart a.service", "restart b.service", "restart c.service"]

  test "the transition section renders and parses back":
    var f = facts("x.service")
    f.fileChanged = true
    var r = facts("gone.service")
    r.removed = true
    let ts = planTransitions(@[f, r])
    let text = renderTransitions(ts) & "something else\n"
    let back = parseTransitions("ledger diff: no change\n" & text)
    check back.len == ts.len
    for i in 0 ..< ts.len:
      check back[i].unit == ts[i].unit and back[i].verb == ts[i].verb and
        back[i].reason == ts[i].reason
    check renderTransitions(@[]) == "service transitions: none\n"

suite "ledger v3":
  test "link, sysctl, account, unit-state and static-link entries round-trip":
    var l = Ledger(generation: "g1", entries: @[
      LedgerEntry(class: lcEtcFile, path: "/etc/app/a.conf", sha256: "aa",
                  mode: "0777", owner: "0:0", form: "link",
                  linkTarget: "/etc/repro/static/app/a.conf",
                  resource: "systemFile:/etc/app/a.conf"),
      LedgerEntry(class: lcStaticLink, path: StaticLinkPath,
                  linkTarget: "/repro/store/prefixes/x", resource: "static-tree"),
      LedgerEntry(class: lcSysctl, path: "net.ipv4.ip_forward", value: "1",
                  replaced: "0", resource: "sysctl:net.ipv4.ip_forward"),
      LedgerEntry(class: lcAccount, path: "user:web", value: "990:990::/:/usr/sbin/nologin",
                  kindHint: "user"),
      LedgerEntry(class: lcUnitState, path: "cron.service", unit: "cron.service",
                  unitState: "enabled", activeState: "active",
                  baseUnitState: "disabled", baseActiveState: "inactive",
                  resource: "unitState:cron.service")])
    let text = l.render()
    check text.startsWith(LedgerHeader)
    let back = parseLedger(text)
    check back.render() == text
    check back.entries[0].isLink and back.entries[0].form == "link"
    check back.entries[2].value == "1" and back.entries[2].replaced == "0"

  test "a v2 ledger is read, every file a copy":
    let v2 = LedgerHeaderV2 & "\ngeneration\tg0\n" &
      "etcFile\t/etc/a\t\taa\t0644\t0:0\t\t\t0\t0\t0\t\tsystemFile:/etc/a\tabsent\t\t\t\t\t\t\n"
    let l = parseLedger(v2)
    check l.entries.len == 1 and not l.entries[0].isLink
    check l.render().startsWith(LedgerHeader)

  test "expectations: a link records its target, the rest their values":
    let l = Ledger(generation: "g1", entries: @[
      LedgerEntry(class: lcEtcFile, path: "/etc/app/a.conf", sha256: "aa",
                  mode: "0777", owner: "0:0", form: "link",
                  linkTarget: "/etc/repro/static/app/a.conf", resource: "r"),
      LedgerEntry(class: lcStaticLink, path: StaticLinkPath,
                  linkTarget: "/repro/store/prefixes/x", resource: "static-tree"),
      LedgerEntry(class: lcSysctl, path: "net.ipv4.ip_forward", value: "1",
                  replaced: "0", resource: "s"),
      LedgerEntry(class: lcAccount, path: "user:web", value: "990:990::/:/usr/sbin/nologin"),
      LedgerEntry(class: lcUnitState, path: "cron.service", unit: "cron.service",
                  unitState: "enabled", activeState: "active",
                  baseUnitState: "disabled", baseActiveState: "inactive",
                  resource: "u")])
    var lines: seq[string]
    for e in expectedDelta(Ledger(), l): lines.add(renderExpectation(e))
    check "+ etc\t/etc/app/a.conf\tl 0777 0:0 -> /etc/repro/static/app/a.conf" in lines
    check "+ etc\t/etc/repro/static\tl 0777 0:0 -> /repro/store/prefixes/x" in lines
    check "~ sysctl\tnet.ipv4.ip_forward\t1" in lines
    check "+ accounts\tuser:web\t990:990::/:/usr/sbin/nologin" in lines
    check "~ unit-files\tcron.service\tenabled" in lines
    check "+ active-units\tcron.service\tactive" in lines
    # Removing the generation puts the sysctl and the unit state back and
    # keeps the account (it is retained: a resource-less entry survives).
    # (`after` is spelled out rather than taken from `l.entries`: the
    # compiler may move `l` into the call's first argument at its last use,
    # and the second argument must not depend on it.)
    let retained = Ledger(entries: @[
      LedgerEntry(class: lcAccount, path: "user:web",
                  value: "990:990::/:/usr/sbin/nologin")])
    var back: seq[string]
    for e in expectedDelta(l, retained):
      back.add(renderExpectation(e))
    checkpoint("back: " & $back)
    check "~ sysctl\tnet.ipv4.ip_forward\t0" in back
    check "~ unit-files\tcron.service\tdisabled" in back
    check "- active-units\tcron.service\tactive" in back
    for b in back: check "accounts" notin b

suite "static tree and pending marker":
  test "paths":
    check staticRelPath("/etc/systemd/system/a.service") == "systemd/system/a.service"
    check staticLinkTargetFor("/etc/app/a.conf") == "/etc/repro/static/app/a.conf"
    check isStaticLinkTarget("/etc/app/a.conf", "/etc/repro/static/app/a.conf")
    check not isStaticLinkTarget("/etc/app/a.conf", "/etc/repro/static/app/b.conf")
    check not isStaticLinkTarget("/etc/app/a.conf", "/tmp/x")
    check not isStaticLinkTarget("/usr/lib/x", "/etc/repro/static/x")
    expect StaticTreeError:
      discard staticRelPath("/usr/lib/os-release")

  test "the tree is named by its content, whatever the order":
    let a = @[StaticFile(path: "/etc/a", content: "1"),
              StaticFile(path: "/etc/b", content: "2")]
    let b = @[a[1], a[0]]
    check treeManifest(a) == treeManifest(b)
    check staticTreePath(a) == staticTreePath(b)
    check staticTreePath(a) != staticTreePath(@[a[0]])
    check staticTreePath(a).startsWith("/repro/store/prefixes/")

  test "the pending marker round-trips and names a step":
    let m = PendingMarker(fromGeneration: "g1", planId: "p", newStatic: "/n",
      previousStatic: "/o", step: ssFlip, status: "in-progress",
      stopped: @["a.service", "b.service"], detail: "")
    let back = parsePendingMarker(m.render())
    check back.fromGeneration == "g1" and back.step == ssFlip and
      back.stopped == @["a.service", "b.service"] and back.newStatic == "/n"
    let dir = getTempDir() / ("repro-addon-marker-" & $getCurrentProcessId())
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    check not hasPendingMarker(dir)
    writePendingMarker(dir, m)
    check hasPendingMarker(dir) and readPendingMarker(dir).step == ssFlip
    clearPendingMarker(dir)
    check not hasPendingMarker(dir)

suite "no-follow primitives":
  let root = getTempDir() / ("repro-addon-nofollow-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root / "etc" / "app")
  createDir(root / "outside")
  writeFile(root / "outside" / "victim", "untouched\n")

  test "replaceWithLinkNoFollow replaces a file or an older link atomically":
    let p = root / "etc" / "app" / "a.conf"
    writeFile(p, "copy\n")
    replaceWithLinkNoFollow(p, "/etc/repro/static/app/a.conf")
    check symlinkExists(p) and expandSymlink(p) == "/etc/repro/static/app/a.conf"
    replaceWithLinkNoFollow(p, "/etc/repro/static/app/b.conf")
    check expandSymlink(p) == "/etc/repro/static/app/b.conf"
    check readLinkNoFollow(p) == "/etc/repro/static/app/b.conf"
    # No temporary name left behind.
    var leftovers = 0
    for _ in walkDir(root / "etc" / "app"): inc leftovers
    check leftovers == 1

  test "a link component on the way is refused, not followed":
    createSymlink(root / "outside", root / "etc" / "linked")
    expect SymlinkOnPath:
      writeFileNoFollow(root / "etc" / "linked" / "victim", "evil\n", 0o644)
    expect SymlinkOnPath:
      replaceWithLinkNoFollow(root / "etc" / "linked" / "victim", "/x")
    expect SymlinkOnPath:
      createDirsNoFollow(root / "etc" / "linked" / "sub" / "dir")
    check readFile(root / "outside" / "victim") == "untouched\n"
    check not dirExists(root / "outside" / "sub")

  test "createDirsNoFollow is mkdir -p":
    createDirsNoFollow(root / "etc" / "new" / "deep" / "dir")
    check dirExists(root / "etc" / "new" / "deep" / "dir")
    createDirsNoFollow(root / "etc" / "new" / "deep" / "dir")

  test "removeLeafNoFollow removes a dangling link and never a directory":
    let d = root / "etc" / "dangling"
    createSymlink(root / "nowhere", d)
    check symlinkExists(d) and not fileExists(d)
    check removeLeafNoFollow(d)
    check not symlinkExists(d)
    check not removeLeafNoFollow(d)
    expect NoFollowError:
      discard removeLeafNoFollow(root / "etc" / "app")
    check removeEmptyDirNoFollow(root / "etc" / "new" / "deep" / "dir")
    check not removeEmptyDirNoFollow(root / "etc" / "new")  # not empty

  test "leafNoFollow reports what is there":
    check leafNoFollow(root / "etc" / "app" / "a.conf").kind == lkLink
    check leafNoFollow(root / "etc" / "app").kind == lkDir
    check leafNoFollow(root / "etc" / "app" / "none").kind == lkAbsent
    writeFile(root / "etc" / "app" / "m.conf", "x")
    discard chmod((root / "etc" / "app" / "m.conf").cstring, Mode(0o600))
    let (k, mode) = leafNoFollow(root / "etc" / "app" / "m.conf")
    check k == lkFile and mode == 0o600

  removeDir(root)

suite "profile text: the new kinds and unit fields":
  test "systemd.systemDropIn and linux.sysusersEntry round-trip":
    let text = """systemd.systemDropIn {
  unit = "cron.service"
  name = "nice"
  content = "[Service]
Nice=5
"
  restartIfChanged = false
}

linux.sysusersEntry {
  name = "web"
  id = "990"
  description = "web service"
  home = "/var/lib/web"
  shell = "/usr/sbin/nologin"
}

linux.sysusersEntry {
  name = "webgrp"
  kind = "group"
}

systemd.systemUnit {
  name = "v.service"
  content = "[Unit]
X-Repro-Exclusive=true
[Service]
ExecStart=/bin/true
"
  stopOnRemoval = false
  reloadIfChanged = true
}
"""
    let p = parseSystemProfile(text)
    check p.resources.len == 4
    let d = p.resources[0]
    check d.kind == srkSystemdSystemDropIn and d.diUnit == "cron.service" and
      d.diName == "nice" and d.diRestartHeld
    check realWorldIdentity(d) == "systemDropIn:cron.service/nice"
    let u = p.resources[1]
    check u.kind == srkLinuxSysusersEntry and u.seKind == "user"
    check sysusersEntryContent(u) ==
      "u web 990 \"web service\" /var/lib/web /usr/sbin/nologin\n"
    check sysusersEntryContent(p.resources[2]) == "g webgrp -\n"
    let s = p.resources[3]
    check s.suStopHeld and s.suReloadIfChanged and not s.suExclusive
    check isExclusiveUnit(s)   # from the X- marker in its content
    check parseSystemProfile(renderProfileText(p)).resources.len == 4
    check "stopOnRemoval = false" in renderProfileText(p)
    check "reloadIfChanged = true" in renderProfileText(p)

  test "malformed entries are refused at parse time":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("linux.sysusersEntry {\n  name = \"bad name\"\n}\n")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("linux.sysusersEntry {\n  name = \"x\"\n  kind = \"role\"\n}\n")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("linux.sysusersEntry {\n  name = \"x\"\n  description = \"a\"\"b\"\n}\n")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("systemd.systemDropIn {\n  unit = \"../x.service\"\n  content = \"\"\n}\n")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("systemd.systemDropIn {\n  unit = \"x.service\"\n  name = \"a/b\"\n  content = \"\"\n}\n")
