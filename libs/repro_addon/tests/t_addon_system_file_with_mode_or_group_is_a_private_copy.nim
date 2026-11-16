## On a ReproOS add-on host an `fs.systemFile` that declares `mode`,
## `group` or `form = "copy"` is materialised as a regular file, and its
## bytes never enter the generation's static tree (reprobuild-pm issue
## `2026-11-12-fs-systemfile-cannot-express-mode-group-or-copy-form.md`;
## spec ReproOS-Add-On-Mode §7.2 step 5, amended 2026-11-16).
##
## The static tree (`/etc/repro/static`, a store prefix) is readable by
## every local user. Before the fix every `fs.systemFile` was link-form,
## so a `mode = "0640"` secret's bytes were published there whatever the
## profile said.
##
## The plan is computed by the switch's own planning code
## (`runAddonApply`, `planOnly`): the tree it names is the digest of the
## link-form objects' paths and bytes (`staticTreePath`), so a plan whose
## tree is the one holding only the undeclared file proves the other files
## were planned as copies and their bytes are not in the tree.
##
## Two more properties of the same fix:
##
## * The collision decision compares a declared mode and group with the
##   file's. A file with the profile's bytes but another mode or group is an
##   update that keeps its bytes (preserved, when the ledger did not own
##   it), never an adoption or a no-op under which the apply would chmod it
##   silently.
## * `repro system addon import` carries a hand-configured file's mode and
##   group into the skeleton, so a `0640 root:<svc>` file round-trips.
##
## MOCK JUSTIFICATION. The dpkg database is a fixture tree (the build host
## is not a Debian base); the unit provider answers from a fixed table
## (or "not-found") because no real unit is involved. The planning, the
## scope and collision passes, the form decision, the collision observer
## (real files, real modes and groups) and the importer are the production
## ones.

import std/[options, os, posix, strutils, unittest]

import repro_test_support/reasoned_skip
import repro_infra
import repro_addon/[addon_apply, addon_import, base_identity, collision,
                    fingerprint, ledger, static_tree]

const Prefix = "/etc/repro-t-private-copy/"

proc stanza(name, extra: string): string =
  "fs.systemFile {\n  path = \"" & Prefix & name & "\"\n" &
    "  content = \"" & name & "-bytes\"\n" & extra & "}\n\n"

suite "an fs.systemFile with mode, group or form = copy is a copy":
  test "only the undeclared file is linked into the static tree":
    let tag = $getCurrentProcessId()
    let state = getTempDir() / ("t-addon-private-copy-" & tag)
    let fixture = getTempDir() / ("t-addon-private-copy-dpkg-" & tag)
    removeDir(state); removeDir(fixture)
    createDir(state / "addon")
    defer:
      removeDir(state)
      removeDir(fixture)
    # An add-on host with an empty generation 0 and no ledger entries.
    writeFile(state / "addon" / "own.profile", "")
    writeLedger(state / "addon-ledger", Ledger(generation: "g1"))
    createDir(fixture / "var/lib/dpkg/info")
    writeFile(fixture / "var/lib/dpkg/status", "")
    let d = newDpkgDriver(fixture, proc(u: string): UnitProvision {.gcsafe.} =
      UnitProvision(loadState: "not-found"))
    let profile = "addOn {\n  managedEtcPrefixes = [\"" & Prefix &
      "\"]\n}\n\n" &
      stanza("plain.conf", "") &
      stanza("secret.env", "  mode = \"0640\"\n") &
      stanza("by-group.env", "  group = \"root\"\n") &
      stanza("no-link.conf", "  form = \"copy\"\n")
    let r = runAddonApply(AddonApplyOptions(stateDir: state,
      userProfileText: profile, planOnly: true, driver: d,
      baseIdentity: some(BaseIdentity(id: "debian", versionId: "13",
                                      architecture: "amd64"))))
    let onlyPlain = staticTreePath(@[StaticFile(path: Prefix & "plain.conf",
                                                content: "plain.conf-bytes")])
    let all = staticTreePath(@[
      StaticFile(path: Prefix & "plain.conf", content: "plain.conf-bytes"),
      StaticFile(path: Prefix & "secret.env", content: "secret.env-bytes"),
      StaticFile(path: Prefix & "by-group.env", content: "by-group.env-bytes"),
      StaticFile(path: Prefix & "no-link.conf", content: "no-link.conf-bytes")])
    if r.staticTree == all:
      checkpoint "every file, the mode-0640 secret included, is in the " &
        "world-readable static tree: all four were planned as links"
    check r.staticTree == onlyPlain

proc scratch(name: string): string =
  result = getTempDir() / ("t-addon-private-copy-" & name & "-" &
                           $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc fixtureDriver(root: string): CollisionDriver =
  createDir(root / "var/lib/dpkg/info")
  writeFile(root / "var/lib/dpkg/status", "")
  newDpkgDriver(root, proc(u: string): UnitProvision {.gcsafe.} =
    UnitProvision(loadState: "not-found"))

proc ownGroupName(): string =
  let g = getgrgid(getgid())
  if g != nil and g.gr_name != nil: $g.gr_name else: "#" & $int(getgid())

suite "a mode or group mismatch is an update, never a silent chmod":
  test "unowned, the profile's bytes, another mode: update, bytes kept":
    let dir = scratch("decide")
    defer: removeDir(dir)
    let d = fixtureDriver(dir / "root")
    let path = dir / "secret.env"
    writeFile(path, "TOKEN=x\n")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead,
                              fpOthersRead})
    var inp = DecisionInputs(address: "systemFile:" & path, kind: tkFile,
      desiredContent: "TOKEN=x\n", desiredSha256: sha256Hex("TOKEN=x\n"),
      desiredMode: "0640")
    let (dec, _) = decide(d, inp, path)
    check dec.verdict == cvUpdate        # was `adopt`: a silent chmod
    check dec.takesOverUnowned
    check dec.preWriteBytes == "TOKEN=x\n"
    check "mode 0644 (declared 0640)" in dec.reason
    # As declared: adopted without writing, as before.
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead})
    check decide(d, inp, path).decision.verdict == cvAdopt
    # Undeclared: the mode is not compared.
    inp.desiredMode = ""
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpOthersRead})
    check decide(d, inp, path).decision.verdict == cvAdopt
    # Another group than the declared one is an update too.
    inp.desiredGroup = "repro-no-such-group-7c1e"
    let g = decide(d, inp, path).decision
    check g.verdict == cvUpdate
    check ("group " & ownGroupName() & " (declared " &
           "repro-no-such-group-7c1e)") in g.reason
    inp.desiredGroup = ownGroupName()
    check decide(d, inp, path).decision.verdict == cvAdopt

  test "owned by the ledger, the declared bytes, another mode: update":
    let dir = scratch("owned")
    defer: removeDir(dir)
    let d = fixtureDriver(dir / "root")
    let path = dir / "owned.env"
    writeFile(path, "A=1\n")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead,
                              fpOthersRead})
    let inp = DecisionInputs(address: "systemFile:" & path, kind: tkFile,
      desiredContent: "A=1\n", desiredSha256: sha256Hex("A=1\n"),
      ledgerOwns: true, ledgerSha256: sha256Hex("A=1\n"),
      desiredMode: "0640")
    let dec = decide(d, inp, path).decision
    check dec.verdict == cvUpdate        # was `no-op`: a silent chmod
    check not dec.takesOverUnowned
    check "mode 0644 (declared 0640)" in dec.reason
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead})
    check decide(d, inp, path).decision.verdict == cvNoOp

suite "import carries a hand-configured file's mode and group":
  test "a 0640 file of the service's group round-trips":
    let root = scratch("import")
    defer: removeDir(root)
    proc put(path, content: string) =
      createDir(parentDir(root & path))
      writeFile(root & path, content)
    put("/etc/systemd/system/svc.service", "[Service]\n" &
      "ExecStart=/usr/local/bin/svc --config=/etc/svc/secret.conf " &
      "--motd=/etc/svc/motd\n")
    put("/etc/svc/secret.conf", "token=1\n")
    put("/etc/svc/motd", "hello\n")
    put("/usr/local/bin/svc", "ELF")
    put("/var/lib/dpkg/status", "")
    createDir(root & "/var/lib/dpkg/info")
    # The host's group database names the test's gid `svcgrp` (an
    # unprivileged test cannot give a file another group).
    put("/etc/group", "root:x:0:\nsvcgrp:x:" & $getgid() & ":\n")
    setFilePermissions(root & "/etc/svc/secret.conf",
                       {fpUserRead, fpUserWrite, fpGroupRead})
    let o = ImportObserver(root: root, driver: newDpkgDriver(root,
      proc(u: string): UnitProvision {.gcsafe.} =
        if u == "svc.service":
          UnitProvision(loadState: "loaded",
            fragmentPath: "/etc/systemd/system/svc.service",
            unitFileState: "enabled", activeState: "active")
        else: UnitProvision(loadState: "not-found")))
    let sk = importUnit(o, "svc.service")
    var secret, motd: SystemResource
    for r in parseSystemProfile(sk.text).resources:
      if r.kind == srkFsSystemFile and r.sfPath == "/etc/svc/secret.conf":
        secret = r
      if r.kind == srkFsSystemFile and r.sfPath == "/etc/svc/motd":
        motd = r
    check secret.sfPath.len > 0 and motd.sfPath.len > 0
    check secret.sfMode == "0640"        # was "": rewritten 0644
    check secret.sfGroup == "svcgrp"     # was "": rewritten root:root
    check motd.sfMode == ""              # 0644 is the default
    check motd.sfGroup == "svcgrp"

  test "a gid the host does not name is flagged, not guessed":
    let root = scratch("import-unnamed")
    defer: removeDir(root)
    proc put(path, content: string) =
      createDir(parentDir(root & path))
      writeFile(root & path, content)
    put("/etc/systemd/system/svc.service", "[Service]\n" &
      "ExecStart=/usr/local/bin/svc --config=/etc/svc/secret.conf\n")
    put("/etc/svc/secret.conf", "token=1\n")
    put("/usr/local/bin/svc", "ELF")
    put("/var/lib/dpkg/status", "")
    createDir(root & "/var/lib/dpkg/info")
    put("/etc/group", "root:x:0:\n")
    let o = ImportObserver(root: root, driver: newDpkgDriver(root,
      proc(u: string): UnitProvision {.gcsafe.} =
        if u == "svc.service":
          UnitProvision(loadState: "loaded",
            fragmentPath: "/etc/systemd/system/svc.service",
            unitFileState: "enabled", activeState: "active")
        else: UnitProvision(loadState: "not-found")))
    let sk = importUnit(o, "svc.service")
    if getgid() == 0:
      skip("the test runs with gid 0, which is root's group")
    else:
      var found = false
      for f in sk.flags:
        if "/etc/svc/secret.conf" in f and "does not name" in f: found = true
      check found
