## A managed system file holds the mode and group its profile declares
## (reprobuild-pm issue
## `2026-11-12-fs-systemfile-cannot-express-mode-group-or-copy-form.md`;
## spec `System-Profile-And-Infra-Apply.md`, `fs.systemFile`, amended
## 2026-11-16).
##
## The attack: a profile puts a secret in `fsSystemFile(..., mode =
## "0640")`, and every local user reads it. Before the fix the constructor
## accepted `mode` and every later layer dropped it, so the driver wrote the
## file `0644` (or kept the bits of the file it replaced) and `root:root`.
## At reprobuild 3ee33e48db the first case below fails with
## "declared mode 0640, observed 0644 (others CAN read the secret)".
##
## Each apply runs the production path end to end: the DSL constructor ->
## the intent adapter -> the canonical text -> the text parser -> the
## privileged operation -> the broker's wire frame (encoded and decoded) ->
## the dispatcher (re-observe, compare with the desired digest, apply) ->
## the real `fs.systemFile` driver writing the real file system. The
## properties held:
##
## * a declared mode is the file's exact mode after every apply, also when
##   it replaces a `0644` file, and a later `chmod` is drift that the next
##   plan shows as an update and the next apply puts back;
## * a declared group owns the file (`root:<group>`), and a group that does
##   not exist fails the apply with the file untouched;
## * `mode`, `group` and `form` are refused at every parse layer (the
##   constructor, the adapter, the text parser, the operation validator)
##   when malformed, and `form = "link"` with either is refused;
## * a file that declares none of them is as before: its existing bits are
##   kept, and its observed and desired digests are its content digest
##   alone, so no earlier plan or record changes.
##
## The add-on half (a file with `mode`, `group` or `form = "copy"` is a
## copy whose bytes stay out of the static tree) is
## `libs/repro_addon/tests/t_addon_system_file_with_mode_or_group_is_a_private_copy.nim`.
##
## MOCK JUSTIFICATION. None of the code under test is replaced. The driver
## writes only below `/etc`, as root, so each writing case runs in a forked
## child that is root of its own user + mount namespace with a private
## tmpfs over `/etc` (the precedent is
## `repro_elevation/tests/t_addon_apt_closure_ro_store_view.nim`); the
## child's `/etc/group`, `/etc/passwd` and `/etc/nsswitch.conf` are copies
## of the host's, so group names resolve as they do on the host. An
## unprivileged user namespace maps exactly one gid. The mode cases map the
## test's gid to 0 (so `root:root` is writable, as on a real host); the
## group case maps the test's primary gid to itself and declares that
## group by name, so only a write that honours the declared group can
## succeed there (one that writes `root:root` fails with EINVAL). The
## writing cases are skipped, with a printed reason, on a kernel that
## refuses unprivileged user namespaces; they never pass there.

import std/[os, posix, strutils, tables, unittest]

import repro_test_support/reasoned_skip

import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile

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

const
  Dir = "/etc/repro-t-declared-mode"
  Secret = "ADMIN_TOKEN=s3cr3t-not-for-other-users\n"

proc permBits(path: string): int =
  var st: Stat
  doAssert lstat(path.cstring, st) == 0, "lstat " & path
  int(st.st_mode) and 0o7777

proc ownerOf(path: string): tuple[uid, gid: int] =
  var st: Stat
  doAssert lstat(path.cstring, st) == 0, "lstat " & path
  (int(st.st_uid), int(st.st_gid))

proc systemProfileOf(r: seq[ResourceIntent]): SystemProfile =
  ## DSL intent -> adapter -> canonical text -> text parser.
  let sp = profileIntentToSystemProfile(ProfileIntent(name: "t", resources: r))
  parseSystemProfile(renderSystemProfileToText(sp))

proc applyThroughProduction(r: seq[ResourceIntent]): DispatchResult =
  ## ... -> privileged operation -> broker wire frame -> dispatcher -> the
  ## real driver.
  let parsed = systemProfileOf(r)
  doAssert parsed.resources.len == 1
  let op = toPrivilegedOperation(parsed.resources[0])
  let wire = decodeOperation(decodeFrame(encodeOperation(
    WireOperation(operation: op))).body)
  dispatchOperation(FixtureContext(), wire)

proc planAction(r: seq[ResourceIntent]): string =
  ## What `repro infra plan` decides for the one resource.
  let sp = profileIntentToSystemProfile(ProfileIntent(name: "t", resources: r))
  let plan = producePlan(renderSystemProfileToText(sp), "t-host")
  doAssert plan.envelope.operations.len == 1
  plan.envelope.operations[0].action

proc primaryGroup(): tuple[gid: int; name: string] =
  let gid = getgid()
  let g = getgrgid(gid)
  (int(gid), (if g != nil and g.gr_name != nil: $g.gr_name else: ""))

when defined(linux):
  proc inNamespace(gidMap: string;
                   body: proc (): seq[string]): tuple[code: int;
                                                      failures: seq[string]] =
    ## Run `body` in a forked child that is root of its own user + mount
    ## namespace (gid map line `gidMap`) with a private tmpfs over /etc;
    ## its failures come back through a file. Code 77: the kernel refuses
    ## unprivileged user namespaces.
    let report = getTempDir() / ("t-sysfile-mode-" & $getCurrentProcessId() &
                                 ".report")
    removeFile(report)
    let uid = getuid()
    var keep = initTable[string, string]()
    for f in ["group", "passwd", "nsswitch.conf"]:
      if fileExists("/etc" / f): keep[f] = readFile("/etc" / f)
    let pid = fork()
    doAssert pid >= 0
    if pid == 0:
      var code = 0
      try:
        if c_unshare(CloneNewUser or CloneNewNs) != 0:
          exitnow(77)
        writeFile("/proc/self/setgroups", "deny")
        writeFile("/proc/self/uid_map", "0 " & $uid & " 1")
        writeFile("/proc/self/gid_map", gidMap)
        doAssert c_mount(nil, "/", nil, MsRec or MsPrivate, nil) == 0
        doAssert c_mount("tmpfs", "/etc", "tmpfs", 0,
                         cast[pointer](cstring"mode=0755")) == 0
        for f, text in keep: writeFile("/etc" / f, text)
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

template expectInNamespace(gidMap: string; body: untyped) =
  ## Run `body` (which appends to `failures`) in the namespace child and
  ## report its failures here.
  when not defined(linux):
    skip("the mount namespace this test writes /etc in is Linux-only")
  else:
    let outcome = inNamespace(gidMap, proc (): seq[string] =
      var failures {.inject.}: seq[string]
      body
      failures)
    if outcome.code == 77:
      skip("unprivileged user namespaces are disabled on this kernel; " &
        "the driver cannot write /etc without root")
    else:
      for f in outcome.failures: checkpoint f
      check outcome.code == 0
      check outcome.failures.len == 0

proc expect(failures: var seq[string]; ok: bool; what: string) =
  if not ok: failures.add(what)

proc rootGidMap(): string = "0 " & $getgid() & " 1"

suite "a declared mode holds (fs.systemFile)":
  test "mode 0640 replaces a 0644 file and keeps the secret from others":
    expectInNamespace(rootGidMap()):
      let path = Dir / "config.env"
      createDir(Dir)
      writeFile(path, "OLD=1\n")
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead,
                                fpOthersRead})
      var r: seq[ResourceIntent]
      fsSystemFile(r, path = path, content = Secret, mode = "0640")
      let res = applyThroughProduction(r)
      failures.expect(res.outcome == doApplied, "not applied: " & res.detail)
      failures.expect(readFile(path) == Secret, "content not written")
      let m = permBits(path)
      failures.expect(m == 0o640, "declared mode 0640, observed " &
        toOct(m, 4) & " (others " &
        (if (m and 0o004) != 0: "CAN" else: "cannot") & " read the secret)")
      failures.expect(ownerOf(path) == (0, 0), "not root:root: " &
        $ownerOf(path))

  test "a chmod is drift: the plan shows an update and the apply restores it":
    expectInNamespace(rootGidMap()):
      let path = Dir / "drift.env"
      var r: seq[ResourceIntent]
      fsSystemFile(r, path = path, content = Secret, mode = "0640")
      discard applyThroughProduction(r)
      failures.expect(planAction(r) == "no-op",
        "a converged file plans " & planAction(r))
      let again = applyThroughProduction(r)
      failures.expect(again.outcome == doNoOp,
        "a converged file is re-applied: " & again.detail)
      # Someone makes the secret readable by every user.
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead,
                                fpOthersRead})
      failures.expect(planAction(r) == "update",
        "a chmod 0644 of a mode-0640 file plans " & planAction(r) &
        ", not update")
      let fixed = applyThroughProduction(r)
      failures.expect(fixed.outcome == doApplied,
        "the drifted file is not re-applied: " & fixed.detail)
      failures.expect(permBits(path) == 0o640, "re-apply left mode " &
        toOct(permBits(path), 4))
      failures.expect(readFile(path) == Secret, "content changed")

  test "a group that does not exist fails the apply; the file is untouched":
    expectInNamespace(rootGidMap()):
      let path = Dir / "nogroup.env"
      createDir(Dir)
      writeFile(path, "OLD=1\n")
      var r: seq[ResourceIntent]
      fsSystemFile(r, path = path, content = Secret, mode = "0640",
                   group = "repro-no-such-group-7c1e")
      var why = ""
      try:
        discard applyThroughProduction(r)
      except EProtocol as e:
        why = e.msg
      failures.expect("repro-no-such-group-7c1e" in why,
        "no EProtocol naming the missing group: '" & why & "'")
      failures.expect(readFile(path) == "OLD=1\n",
        "the file was written although its group does not exist")

suite "a declared group holds (fs.systemFile)":
  test "the file is root:<group>, with the declared mode":
    let g = primaryGroup()
    if g.name.len == 0:
      skip("the test user's primary gid " & $g.gid & " has no group name")
    else:
      # Only the test's primary gid is mapped (to itself): a write that
      # ignored `group` and wrote root:root could not succeed here.
      expectInNamespace($g.gid & " " & $g.gid & " 1"):
        let path = Dir / "by-group.env"
        var r: seq[ResourceIntent]
        fsSystemFile(r, path = path, content = Secret, mode = "0640",
                     group = g.name)
        var res: DispatchResult
        try:
          res = applyThroughProduction(r)
        except CatchableError as e:
          failures.add("declared group " & g.name & " not honoured: " & e.msg)
        if failures.len == 0:
          failures.expect(res.outcome == doApplied,
            "not applied: " & res.detail)
          failures.expect(ownerOf(path) == (0, g.gid), "declared group " &
            g.name & " (gid " & $g.gid & "), observed " & $ownerOf(path))
          failures.expect(permBits(path) == 0o640, "mode " &
            toOct(permBits(path), 4))
          failures.expect(applyThroughProduction(r).outcome == doNoOp,
            "a converged root:" & g.name & " file is re-applied")

proc applyOnAddOnHost(r: seq[ResourceIntent];
                      m: AddOnMaterialisation): DispatchResult =
  ## The same path, with the add-on switch's materialisation policy for
  ## this one operation (what `runAddonApply` hands the drivers).
  let op = toPrivilegedOperation(systemProfileOf(r).resources[0])
  let policy: AddOnDispatchPolicy = proc(o: PrivilegedOperation):
      AddOnMaterialisation {.gcsafe.} = m
  dispatchOperation(FixtureContext(addOn: policy), WireOperation(operation: op))

suite "on an add-on host (ReproOS-Add-On-Mode §7.2 step 5)":
  test "a link of the previous generation becomes a private copy":
    # The previous generation linked the file into its static tree; this
    # one declares a mode, so the switch plans a copy and lets the writer
    # rename it over exactly that link -- and over no other.
    expectInNamespace(rootGidMap()):
      let path = Dir / "was-linked.env"
      let tree = "/etc/repro/static/repro-t-declared-mode/was-linked.env"
      createDir(parentDir(tree))
      createDir(Dir)
      writeFile(tree, Secret)
      createSymlink(tree, path)
      var r: seq[ResourceIntent]
      fsSystemFile(r, path = path, content = Secret, mode = "0640")
      var refused = ""
      try:
        discard applyOnAddOnHost(r, AddOnMaterialisation(orchestrated: true))
      except EProtocol as e:
        refused = e.msg
      failures.expect("symbolic link" in refused,
        "a copy was written through a link it was not told it replaces: '" &
        refused & "'")
      let res = applyOnAddOnHost(r, AddOnMaterialisation(orchestrated: true,
        replacingLinkTo: tree))
      failures.expect(res.outcome == doApplied, "not applied: " & res.detail)
      failures.expect(not symlinkExists(path), "still a link")
      failures.expect(permBits(path) == 0o640, "the copy is " &
        toOct(permBits(path), 4))
      failures.expect(readFile(path) == Secret, "content")

  test "a form = copy file the previous generation linked becomes a copy":
    # Only `form = "copy"`: no mode or group, and the bytes are unchanged.
    # The switch computes its plan before it flips the static tree, so the
    # link still resolves to the declared bytes then. Unless the
    # observation sees the link, the plan is a no-op, nothing replaces the
    # link, and after the flip it points into a tree that no longer holds
    # the file (the new tree carries link-form objects only).
    expectInNamespace(rootGidMap()):
      let path = Dir / "was-linked.conf"
      let tree = "/etc/repro/static/repro-t-declared-mode/was-linked.conf"
      createDir(parentDir(tree))
      createDir(Dir)
      writeFile(tree, Secret)
      createSymlink(tree, path)
      var r: seq[ResourceIntent]
      fsSystemFile(r, path = path, content = Secret, form = "copy")
      failures.expect(planAction(r) == "update",
        "a link where a copy is declared plans " & planAction(r) &
        ", not update: the link is never replaced")
      let res = applyOnAddOnHost(r, AddOnMaterialisation(orchestrated: true,
        replacingLinkTo: tree))
      failures.expect(res.outcome == doApplied, "not applied: " & res.detail)
      failures.expect(not symlinkExists(path), "still a link")
      failures.expect(readFile(path) == Secret, "content")
      failures.expect(planAction(r) == "no-op",
        "the copy plans " & planAction(r) & " once written")

  test "a file declaring a mode is never written as a link":
    expectInNamespace(rootGidMap()):
      let path = Dir / "never-linked.env"
      createDir(Dir)
      var r: seq[ResourceIntent]
      fsSystemFile(r, path = path, content = Secret, mode = "0640")
      var refused = ""
      try:
        discard applyOnAddOnHost(r, AddOnMaterialisation(orchestrated: true,
          linkTarget: "/etc/repro/static/repro-t-declared-mode/x"))
      except EProtocol as e:
        refused = e.msg
      failures.expect("cannot be materialised as a link" in refused,
        "a mode-0640 file was linked into the static tree: '" & refused &
        "'")
      failures.expect(not symlinkExists(path) and not fileExists(path),
        "something was written")

suite "an undeclared mode and group behave as before":
  test "the replaced file's bits are kept; a new file is 0644":
    expectInNamespace(rootGidMap()):
      let kept = Dir / "kept.conf"
      createDir(Dir)
      writeFile(kept, "OLD=1\n")
      setFilePermissions(kept, {fpUserRead, fpUserWrite})
      var r: seq[ResourceIntent]
      fsSystemFile(r, path = kept, content = "NEW=1\n")
      discard applyThroughProduction(r)
      failures.expect(permBits(kept) == 0o600, "an operator's 0600 was " &
        "not kept: " & toOct(permBits(kept), 4))
      let fresh = Dir / "fresh.conf"
      var f: seq[ResourceIntent]
      fsSystemFile(f, path = fresh, content = "NEW=1\n")
      discard applyThroughProduction(f)
      failures.expect(permBits(fresh) == 0o644, "a new undeclared file is " &
        toOct(permBits(fresh), 4))
      # Observed by its content alone, as every earlier record was.
      let op = toPrivilegedOperation(systemProfileOf(f).resources[0])
      failures.expect(observeFsSystemFile(op).digestHex ==
        posixDigestHexOfText("NEW=1\n"), "the observed digest is not the " &
        "content digest")

  test "the intent, the text and the desired digest are unchanged":
    var r: seq[ResourceIntent]
    fsSystemFile(r, path = "/etc/x/plain.conf", content = "a=1\n")
    check "mode" notin r[0].fields
    check "group" notin r[0].fields
    check "form" notin r[0].fields
    let sp = profileIntentToSystemProfile(ProfileIntent(name: "t",
                                                        resources: r))
    let text = renderSystemProfileToText(sp)
    check "mode" notin text and "group" notin text and "form" notin text
    let op = toPrivilegedOperation(parseSystemProfile(text).resources[0])
    check posixSystemDesiredDigestHex(op) == posixDigestHexOfText("a=1\n")
    # A declared one is no longer the content digest: it covers the mode.
    var d: seq[ResourceIntent]
    fsSystemFile(d, path = "/etc/x/plain.conf", content = "a=1\n",
                 mode = "0640")
    let dop = toPrivilegedOperation(systemProfileOf(d).resources[0])
    check dop.sfMode == "0640"
    check posixSystemDesiredDigestHex(dop) != posixDigestHexOfText("a=1\n")

const Bad = [
  # (mode, group, form, what the refusal names)
  ("644", "", "", "four octal digits"),
  ("0648", "", "", "four octal digits"),
  ("4755", "", "", "setuid"),
  ("1640", "", "", "setuid"),
  ("0646", "", "", "lets every user write"),
  ("0640", "", "link", "form 'link'"),
  ("", "web", "link", "form 'link'"),
  ("", "", "symlink", "form 'symlink'"),
  ("", "a:b", "", "outside letters"),
  ("", "../etc", "", "outside letters"),
  ("", "web ops", "", "outside letters"),
  ("", "-web", "", "starts with '-'"),
  ("", "1000", "", "all digits")]

suite "malformed mode, group and form are refused at every layer":
  test "the constructor refuses them":
    for (mode, group, form, why) in Bad:
      checkpoint mode & "/" & group & "/" & form
      var r: seq[ResourceIntent]
      var msg = ""
      try:
        fsSystemFile(r, path = "/etc/x/a.conf", content = "x", mode = mode,
                     group = group, form = form)
      except ValueError as e:
        msg = e.msg
      check why in msg
      check r.len == 0

  test "the adapter refuses them in an intent built without the constructor":
    for (mode, group, form, why) in Bad:
      checkpoint mode & "/" & group & "/" & form
      var fields = {"path": strField("/etc/x/a.conf"),
                    "content": strField("x")}.toTable
      if mode.len > 0: fields["mode"] = strField(mode)
      if group.len > 0: fields["group"] = strField(group)
      if form.len > 0: fields["form"] = strField(form)
      var msg = ""
      try:
        discard profileIntentToSystemProfile(ProfileIntent(name: "t",
          resources: @[ResourceIntent(kind: "fs.systemFile",
                                      address: "f", fields: fields)]))
      except ValueError as e:
        msg = e.msg
      check why in msg

  test "the text parser refuses them":
    for (mode, group, form, why) in Bad:
      checkpoint mode & "/" & group & "/" & form
      var text = "fs.systemFile {\n  path = \"/etc/x/a.conf\"\n" &
        "  content = \"x\"\n"
      if mode.len > 0: text.add("  mode = \"" & mode & "\"\n")
      if group.len > 0: text.add("  group = \"" & group & "\"\n")
      if form.len > 0: text.add("  form = \"" & form & "\"\n")
      text.add("}\n")
      var msg = ""
      try:
        discard parseSystemProfile(text)
      except ESystemProfileInvalid as e:
        msg = e.msg
      check why in msg

  test "the operation validator refuses a decoded mode, group or form":
    for (mode, group, form, why) in Bad:
      checkpoint mode & "/" & group & "/" & form
      let op = PrivilegedOperation(kind: pokFsSystemFile, address: "f",
        sfPath: "/etc/x/a.conf", sfContent: "x", sfMode: mode,
        sfGroup: group, sfForm: form)
      check why in operationValidationError(op)

  test "well-formed declarations pass every layer":
    for (mode, group, form) in [("0640", "", ""), ("0600", "web", "copy"),
                                ("", "_svc.d-1", ""), ("", "", "link"),
                                ("", "", "copy"), ("0000", "", "")]:
      checkpoint mode & "/" & group & "/" & form
      var r: seq[ResourceIntent]
      fsSystemFile(r, path = "/etc/x/a.conf", content = "x", mode = mode,
                   group = group, form = form)
      let res = systemProfileOf(r).resources[0]
      check res.sfMode == mode and res.sfGroup == group and res.sfForm == form
      let op = toPrivilegedOperation(res)
      check operationValidationError(op) == ""
