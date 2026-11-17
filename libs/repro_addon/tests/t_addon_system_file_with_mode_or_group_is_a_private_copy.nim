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
## * A link-to-copy switch survives step 3's flip: the previous
##   generation's own link (`/etc/X -> /etc/repro/static/X`) dangles once
##   the new tree no longer carries the file, and the write-time re-check
##   accepts exactly that link (any other is still refused); the revert of
##   a failed switch in either direction decides the add-on's own dangling
##   link instead of refusing it as "not a regular file". Found by the VM
##   gate `t_e2e_addon_declared_mode_file_is_a_private_copy` (debian-13,
##   generation 1 linked, generation 2 `form = "copy"`); at reprobuild
##   2d5d3ce3ef the re-check refused with "changed since the plan (sha256
##   absent ...)" and the rollback with "exists and is not a regular file".
##   These cases run where `/etc` can be written: a forked child that is
##   root of its own user + mount namespace with a tmpfs over `/etc` (the
##   static tree and the add-on's own link must be at their real paths,
##   which the collision observer matches by text); the flip is the
##   removal of the file from the tree the link points into. Skipped, with
##   a reason, on a kernel without unprivileged user namespaces.
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

when defined(linux):
  var
    CloneNewUser {.importc: "CLONE_NEWUSER", header: "<sched.h>".}: cint
    CloneNewNs {.importc: "CLONE_NEWNS", header: "<sched.h>".}: cint
    MsRec {.importc: "MS_REC", header: "<sys/mount.h>".}: culong
    MsPrivate {.importc: "MS_PRIVATE", header: "<sys/mount.h>".}: culong
  proc c_unshare(flags: cint): cint {.importc: "unshare", header: "<sched.h>".}
  proc c_mount(source, target, fstype: cstring; flags: culong;
               data: pointer): cint {.importc: "mount",
                                      header: "<sys/mount.h>".}

  proc inEtcNamespace(body: proc (): seq[string]): tuple[code: int;
                                                        failures: seq[string]] =
    ## `body` in a forked child that is root of its own user + mount
    ## namespace, with a private tmpfs over /etc. Code 77: no unprivileged
    ## user namespaces.
    let report = getTempDir() / ("t-addon-flip-" & $getCurrentProcessId() &
                                 ".report")
    removeFile(report)
    let uid = getuid()
    let gid = getgid()
    let pid = fork()
    doAssert pid >= 0
    if pid == 0:
      var code = 0
      try:
        if c_unshare(CloneNewUser or CloneNewNs) != 0: exitnow(77)
        writeFile("/proc/self/setgroups", "deny")
        writeFile("/proc/self/uid_map", "0 " & $uid & " 1")
        writeFile("/proc/self/gid_map", "0 " & $gid & " 1")
        doAssert c_mount(nil, "/", nil, MsRec or MsPrivate, nil) == 0
        doAssert c_mount("tmpfs", "/etc", "tmpfs", 0,
                         cast[pointer](cstring"mode=0755")) == 0
        let failures = body()
        writeFile(report, failures.join("\n"))
        if failures.len > 0: code = 1
      except CatchableError as ex:
        writeFile(report, "child raised: " & ex.msg)
        code = 1
      exitnow(cint(code))
    var status: cint
    doAssert waitpid(pid, status, 0) == pid
    result.code = if WIFEXITED(status): int(WEXITSTATUS(status)) else: 128
    if fileExists(report):
      let text = readFile(report)
      if text.len > 0: result.failures = text.splitLines()
      removeFile(report)

template withEtc(body: untyped) =
  when not defined(linux):
    skip("the mount namespace this case writes /etc in is Linux-only")
  else:
    let outcome = inEtcNamespace(proc (): seq[string] =
      var failures {.inject.}: seq[string]
      body
      failures)
    if outcome.code == 77:
      skip("unprivileged user namespaces are disabled on this kernel; " &
        "the add-on's own link cannot be made at its /etc path")
    else:
      for f in outcome.failures: checkpoint f
      check outcome.code == 0
      check outcome.failures.len == 0

proc expect(failures: var seq[string]; ok: bool; what: string) =
  if not ok: failures.add(what)

const
  Toggled = "/etc/repro-fixture/toggled.conf"
  ToggledAddress = "systemFile:/etc/repro-fixture/toggled.conf"
  ToggledBytes = "toggled=1\n"

proc linkedGeneration(): string =
  ## Generation 1 on the host: the file in the static tree and the
  ## add-on's own link to it. Returns the tree file.
  result = staticLinkTargetFor(Toggled)
  createDir(parentDir(result))
  writeFile(result, ToggledBytes)
  createDir(parentDir(Toggled))
  createSymlink(result, Toggled)

proc linkLedger(): Ledger =
  Ledger(generation: "g1", entries: @[LedgerEntry(class: lcEtcFile,
    path: Toggled, resource: ToggledAddress, form: "link",
    linkTarget: staticLinkTargetFor(Toggled),
    sha256: sha256Hex(ToggledBytes))])

proc ownedInputs(): DecisionInputs =
  DecisionInputs(address: ToggledAddress, kind: tkFile,
    desiredContent: ToggledBytes, desiredSha256: sha256Hex(ToggledBytes),
    ledgerOwns: true, ledgerSha256: sha256Hex(ToggledBytes))

suite "a link-to-copy switch survives the flip of the static tree":
  test "the write-time re-check accepts exactly the own link, dangling":
    let fixture = scratch("flip-recheck")
    defer: removeDir(fixture)
    withEtc:
      let d = fixtureDriver(fixture / "root")
      let tree = linkedGeneration()
      # The plan of generation 2 (`form = "copy"`): the own link, as the
      # ledger recorded it, with generation 1's bytes behind it.
      let inp = ownedInputs()
      let (dec, obs) = decide(d, inp, Toggled)
      failures.expect(obs.ownLink, "the plan did not see the own link")
      failures.expect(dec.verdict == cvNoOp, "planned " & $dec.verdict)
      var t = plannedTarget(ToggledAddress, inp, Toggled, dec, obs)
      t.replacesOwnLink = replacesOwnLink(linkLedger(), ToggledAddress,
        Toggled, "copy", obs.ownLink, replay = false, revert = false)
      failures.expect(t.replacesOwnLink, "the switch does not mark the " &
        "copy as replacing its own link")
      # Step 3: the static tree now holds generation 2's link-form files,
      # and toggled.conf is not one of them. The own link dangles.
      removeFile(tree)
      let why = preWriteRefusal(d, t)
      failures.expect(why == "", "the own dangling link is refused at " &
        "write time: " & why)
      # Any other link at the path is still refused.
      removeFile(Toggled)
      createSymlink("/etc/repro/static/elsewhere.conf", Toggled)
      failures.expect("symbolic link" in preWriteRefusal(d, t),
        "a foreign link was accepted at write time")

  test "a revert decides the add-on's own dangling link, never refuses it":
    let fixture = scratch("flip-revert")
    defer: removeDir(fixture)
    withEtc:
      let d = fixtureDriver(fixture / "root")
      let tree = linkedGeneration()
      removeFile(tree)       # the failed switch's flip: the link dangles
      var msg = ""
      var verdict = cvAdopt
      try:
        verdict = decide(d, ownedInputs(), Toggled).decision.verdict
      except AddonCollisionError as e:
        msg = e.msg
      failures.expect(msg == "", "the revert refuses its own link: " & msg)
      failures.expect(verdict == cvUpdate, "the revert decided " & $verdict)
      # A dangling link the ledger does not own is still not the add-on's
      # to rewrite.
      var notOwned = ownedInputs()
      notOwned.ledgerOwns = false
      notOwned.ledgerSha256 = ""
      var refused = false
      try: discard decide(d, notOwned, Toggled)
      except AddonCollisionError: refused = true
      failures.expect(refused, "an unowned dangling link was accepted")

  test "copy to link: the revert to the copy replaces the own link":
    let fixture = scratch("flip-copy-to-link")
    defer: removeDir(fixture)
    withEtc:
      let d = fixtureDriver(fixture / "root")
      # Generation 1 was a copy; the failed generation 2 linked it, and its
      # tree is still current when the revert plans.
      let tree = linkedGeneration()
      let inp = ownedInputs()
      let (dec, obs) = decide(d, inp, Toggled)
      var t = plannedTarget(ToggledAddress, inp, Toggled, dec, obs)
      # The committed ledger (generation 1's) recorded a copy.
      var copyLedger = linkLedger()
      copyLedger.entries[0].form = "copy"
      copyLedger.entries[0].linkTarget = ""
      t.replacesOwnLink = replacesOwnLink(copyLedger, ToggledAddress,
        Toggled, "copy", obs.ownLink, replay = false, revert = true)
      failures.expect(t.replacesOwnLink, "the revert does not mark the " &
        "copy as replacing the failed switch's link")
      failures.expect(not replacesOwnLink(copyLedger, ToggledAddress,
        Toggled, "copy", obs.ownLink, replay = false, revert = false),
        "an ordinary apply takes over a link the ledger never recorded")
      removeFile(tree)       # the revert's flip back to generation 1's tree
      let why = preWriteRefusal(d, t)
      failures.expect(why == "", "the revert's copy is refused at write " &
        "time: " & why)
