## The ALPM hook, the Omarchy post-update hook and the verification they run
## (milestone AR6; spec ReproOS-Add-On-Mode §4.3.1, §4.3.2, §7.7, §7.8, §7.9;
## threat model T45-T50, G43, G45).
##
## - *The ALPM hook file* is a well-formed alpm-hooks(5) file: a
##   ``PostTransaction`` action over every package and operation, whose
##   ``Exec`` libalpm splits into exactly ``/bin/sh``, ``-c`` and the bounded
##   command (the split is libalpm's ``_alpm_wordsplit`` rule, reimplemented
##   below from pacman's ``lib/libalpm/util.c``). The command itself is run
##   with ``/bin/sh -c``, as libalpm runs it, against stand-ins for the
##   verification -- clean, missing, failing and hung -- and must exit 0
##   every time and end within the deadline plus the kill grace
##   (``alpm-hook-without-timeout`` / ``alpm-hook-without-exit0`` turn the
##   hang and failure cases red).
## - *The Omarchy hook script* runs under ``bash``, as ``omarchy-hook`` runs
##   it, with a stand-in ``sudo``: when ``sudo -n`` fails it prints and logs
##   ``verify-unprivileged`` and exits 0
##   (``omarchy-hook-no-unprivileged-record`` turns this red); when it
##   succeeds the root side's bounded command runs, its hung verification
##   ended at the deadline, and the script still exits 0.
## - *The no-follow writer with the owner checks* (``omarchy_hook.nim``):
##   it creates ``post-update.d`` owned by the account and writes the hook
##   beside nothing else; it refuses a link at the hook's path, a link in
##   place of a directory and a directory writable by others, writing
##   nothing outside the home; observation reports a changed, linked or
##   missing hook; removal leaves anything that is not the add-on's object
##   and removes the directory only while empty
##   (``omarchy-hook-writer-follows-links`` turns the link cases red).
## - Generation 0 on an Arch-family base carries the ALPM hook and no apt
##   hook; the re-assert unit sees ``/home`` read-only only when generation 0
##   carries the Omarchy hook; the ledger round-trips the new class and its
##   expected fingerprint records are ``omarchy-hooks`` records.
## - ``.pacnew`` and ``.pacsave`` beside ledger paths are reported naming the
##   package (``alpm-hook-ignores-pacnew`` turns this red); a packaged hook
##   under the ALPM hook's name is refused by the preflight and reported by
##   the verification; the ``overrideBaseLayer`` re-check reports an
##   acknowledgement the installed Omarchy no longer needs, and a declared
##   path its scripts now name (``omarchy-override-not-rechecked`` turns
##   this red).
##
## *Mocking.* The verification, ``sudo`` and ``logger`` are replaced by
## small shell scripts: what is under test is each hook's wrapper -- its
## deadline, its exit status, its record -- which treats the binary it names
## as a black box; the real verification runs in the VM gates. The hook
## file's owner is the test's own uid (it cannot chown to root); every other
## check is the production code's. The pacman database and Omarchy's
## scripts are fixture files in pacman's format (alpm-db(7)).

import std/[os, osproc, posix, streams, strutils, tables, tempfiles, times, unittest]

import repro_infra/profile

import repro_addon/[apt_hook, base_identity, collision, fingerprint,
  generation0, ledger, mutations, omarchy, omarchy_hook, preflight]

proc tool(name: string): string =
  result = findExe(name, followSymlinks = false)
  doAssert result.len > 0, name & " is not on PATH"

proc wordsplit(s: string): seq[string] =
  ## libalpm's ``_alpm_wordsplit`` (pacman ``lib/libalpm/util.c``): words
  ## split on white space; a run quoted with ``'`` or ``"`` is part of one
  ## word, the quotes dropped; a backslash escapes only a quote character
  ## (inside a quoted run, only that run's quote).
  var i = 0
  while i < s.len and s[i] in Whitespace: inc i
  while i < s.len:
    var w = ""
    while i < s.len and s[i] notin Whitespace:
      if s[i] in {'\'', '"'}:
        let q = s[i]
        inc i
        while i < s.len and s[i] != q:
          if s[i] == '\\' and i + 1 < s.len and s[i + 1] == q: inc i
          w.add(s[i]); inc i
        doAssert i < s.len, "unbalanced quote"
        inc i
      else:
        if s[i] == '\\' and i + 1 < s.len and s[i + 1] in {'\'', '"'}: inc i
        w.add(s[i]); inc i
    result.add(w)
    while i < s.len and s[i] in Whitespace: inc i

proc execOf(hookFile: string): string =
  for l in hookFile.splitLines():
    if l.startsWith("Exec = "): return l["Exec = ".len .. ^1]

let dir = createTempDir("repro-ar6-hooks-", "")

proc script(name, body: string): string =
  result = dir / name
  writeFile(result, "#!/bin/sh\n" & body & "\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc runBounded(argv: seq[string]; boundSec: int; marker = ""):
    tuple[code: int; secs: float; timedOut: bool; output: string] =
  let t0 = epochTime()
  let p = startProcess(argv[0], args = argv[1 .. ^1],
                       options = {poStdErrToStdOut})
  defer: p.close()
  while p.peekExitCode() == -1:
    if epochTime() - t0 > boundSec.float:
      if marker.len > 0:
        discard execCmd("pkill -KILL -f " & quoteShell(marker) & " >/dev/null 2>&1")
      p.kill()
      discard p.waitForExit()
      return (-1, epochTime() - t0, true, "")
    sleep(50)
  (p.peekExitCode(), epochTime() - t0, false, p.outputStream.readAll())

suite "the ALPM hook":
  let exe = "/repro/store/0123-repro/bin/repro"
  let hook = alpmHook(exe)

  test "a PostTransaction action over every package and operation":
    check "When = PostTransaction\n" in hook
    for op in ["Install", "Upgrade", "Remove"]:
      check ("Operation = " & op & "\n") in hook
    check "Type = Package\nTarget = *\n" in hook
    check "AbortOnFail" notin hook          # a post hook cannot, never asks
    check AlpmHookPath == "/etc/pacman.d/hooks/90-repro-addon.hook"

  test "libalpm splits Exec into /bin/sh, -c and the whole bounded command":
    let w = wordsplit(execOf(hook))
    check w.len == 3
    check w[0] == "/bin/sh" and w[1] == "-c"
    check w[2] == alpmHookCommand(exe)
    check "verify --after-pacman" in w[2]
    check "repro-addon-alpm-hook" in w[2]
    check AlpmHookLogPath in w[2]

  proc runAlpm(verifier, log: string; timeoutSec, boundSec: int; marker = ""):
      tuple[code: int; secs: float; timedOut: bool; output: string] =
    let cmd = boundedHookCommand(verifier, AlpmBoundedHook, timeoutSec, log,
      tool("setsid"), "/nonexistent/logger", dir)
    runBounded(@[tool("sh"), "-c", cmd], boundSec, marker)

  test "clean, missing and failing verifications: exit 0, the non-clean recorded":
    let log = dir / "alpm-hook.log"
    removeFile(log)
    check runAlpm(script("ok", "exit 0"), log, 2, 20).code == 0
    check not fileExists(log)
    check runAlpm(dir / "absent", log, 2, 20).code == 0
    check "verify-missing" in readFile(log)
    check runAlpm(script("fail", "exit 4"), log, 2, 20).code == 0
    check "verify-failed exit=4" in readFile(log)

  test "a hung verification: ended at the deadline plus the grace, exit 0":
    let log = dir / "alpm-hook-hang.log"
    removeFile(log)
    let marker = $(200000 + getCurrentProcessId() mod 700000)
    let r = runAlpm(script("hang", "trap '' TERM\nsleep " & marker & " &\n" &
                    "while :; do sleep 1; done"), log, 2, 20, "sleep " & marker)
    check not r.timedOut
    check r.code == 0
    check r.secs < 2.0 + AptHookKillGraceSeconds.float + 3.0
    check fileExists(log) and "verify-timeout" in readFile(log)
    sleep(500)
    check execCmd("pgrep -x -f 'sleep " & marker & "' >/dev/null") != 0
    discard execCmd("pkill -KILL -x -f 'sleep " & marker & "' >/dev/null 2>&1")

suite "the Omarchy post-update hook script":
  let exe = "/repro/store/0123-repro/bin/repro"

  test "it is bash, runs the root side through sudo -n and always exits 0":
    let s = omarchyHookScript(exe)
    check s.startsWith("#!/bin/bash\n")
    check "/usr/bin/sudo -n /usr/bin/true" in s
    check "/usr/bin/sudo -n /bin/sh -s <<'REPRO_ADDON_ROOT_EOF'" in s
    check "verify --after-base-update" in s
    check s.strip().endsWith("exit 0")
    check omarchyHookPath("/home/omarchy/") ==
      "/home/omarchy/.config/omarchy/hooks/post-update.d/90-repro-addon"

  proc run(sudoBody, verifier: string; boundSec = 20; marker = ""):
      tuple[code: int; secs: float; timedOut: bool; output: string; logged: string] =
    let logged = dir / "logger-out"
    removeFile(logged)
    let logger = script("logger", "echo \"$@\" >> " & logged)
    let sudo = script("sudo", sudoBody)
    let log = dir / "omarchy-hook.log"
    removeFile(log)
    let s = omarchyHookScript(verifier, timeoutSeconds = 2, logPath = log,
      setsidTool = tool("setsid"), loggerTool = logger, sudoTool = sudo,
      trueTool = tool("true"))
    writeFile(dir / "90-repro-addon", s)
    let r = runBounded(@[tool("bash"), dir / "90-repro-addon"], boundSec, marker)
    sleep(300)              # the backgrounded logger
    (r.code, r.secs, r.timedOut, r.output,
     (if fileExists(logged): readFile(logged) else: ""))

  test "sudo -n fails: verify-unprivileged printed and logged, exit 0":
    let r = run("exit 1", script("v-ok", "exit 0"))
    check r.code == 0
    check "verify-unprivileged" in r.output
    check "-t repro-addon-omarchy-hook" in r.logged
    check "verify-unprivileged" in r.logged

  test "sudo -n works: the root side runs the verification, exit 0":
    let mark = dir / "verified"
    removeFile(mark)
    # The stand-in sudo drops `-n` and runs the rest as this user.
    let r = run("[ \"$1\" = -n ] && shift\nexec \"$@\"",
                script("v-mark", "touch " & mark & "\nexit 0"))
    check r.code == 0
    check fileExists(mark)
    check "verify-unprivileged" notin r.output

  test "a hung root-side verification is bounded; the script still exits 0":
    let marker = $(300000 + getCurrentProcessId() mod 600000)
    let r = run("[ \"$1\" = -n ] && shift\nexec \"$@\"",
                script("v-hang", "trap '' TERM\nsleep " & marker & " &\n" &
                       "while :; do sleep 1; done"), 20, "sleep " & marker)
    check not r.timedOut
    check r.code == 0
    check r.secs < 2.0 + AptHookKillGraceSeconds.float + 3.0
    check "verify-timeout" in readFile(dir / "omarchy-hook.log")
    sleep(500)
    check execCmd("pgrep -x -f 'sleep " & marker & "' >/dev/null") != 0
    discard execCmd("pkill -KILL -x -f 'sleep " & marker & "' >/dev/null 2>&1")

suite "the no-follow writer with the owner checks":
  let uid = int(getuid())
  let gid = int(getgid())
  # Observation and removal read the account's uid from the password
  # database again (``targetFor``): the account is this test's own.
  let me = $getpwuid(getuid()).pw_name

  proc home(name: string): OmarchyHookTarget =
    let h = dir / name
    createDir(h / ".config/omarchy/hooks")
    for p in [h, h / ".config", h / ".config/omarchy",
              h / ".config/omarchy/hooks"]:
      setFilePermissions(p, {fpUserRead, fpUserWrite, fpUserExec,
                             fpGroupRead, fpGroupExec, fpOthersRead,
                             fpOthersExec})
    OmarchyHookTarget(account: me, uid: uid, gid: gid, home: h,
      dir: h / OmarchyHookDirRel, path: omarchyHookPath(h),
      fileUid: uid, fileGid: gid)

  proc lmode(p: string): int =
    var st: Stat
    doAssert lstat(p.cstring, st) == 0
    int(st.st_mode) and 0o7777

  test "creates post-update.d owned by the account, writes the hook 0644":
    let t = home("h1")
    check omarchyHookPathProblem(t) == ""
    let objs = writeOmarchyHook(t, "hook\n")
    check objs.len == 2
    check objs[0].kindHint == KindDir and objs[0].path == t.dir and
      objs[0].owner == $uid & ":" & $gid and objs[0].mode == "0755"
    check objs[1].kindHint == KindFile and objs[1].path == t.path and
      objs[1].sha256 == sha256Hex("hook\n") and objs[1].mode == "0644"
    check readFile(t.path) == "hook\n"
    check lmode(t.path) == 0o644 and lmode(t.dir) == 0o755
    check observeOmarchyHook(objs[0]) == ""
    check observeOmarchyHook(objs[1]) == ""
    # Nothing but the hook is left in the directory (no temporary).
    var names: seq[string]
    for k, p in walkDir(t.dir): names.add(extractFilename(p))
    check names == @["90-repro-addon"]
    # A second write refuses: the path is taken.
    check omarchyHookPathProblem(t).len > 0
    expect OmarchyHookError:
      discard writeOmarchyHook(t, "again\n")
    check readFile(t.path) == "hook\n"

  test "an existing post-update.d is used, not recorded as created":
    let t = home("h2")
    createDir(t.dir)
    setFilePermissions(t.dir, {fpUserRead, fpUserWrite, fpUserExec,
                               fpGroupRead, fpGroupExec, fpOthersRead,
                               fpOthersExec})
    let objs = writeOmarchyHook(t, "x\n")
    check objs.len == 1 and objs[0].kindHint == KindFile

  test "a link at the hook's path is refused; its target is not written":
    let t = home("h3")
    createDir(t.dir)
    setFilePermissions(t.dir, {fpUserRead, fpUserWrite, fpUserExec,
                               fpGroupRead, fpGroupExec})
    let outside = dir / "outside-file"
    writeFile(outside, "outside\n")
    createSymlink(outside, t.path)
    check omarchyHookPathProblem(t).len > 0
    expect OmarchyHookError:
      discard writeOmarchyHook(t, "hook\n")
    check readFile(outside) == "outside\n"
    check symlinkExists(t.path)

  test "a directory replaced with a link is refused; nothing is written through it":
    let t = home("h4")
    let elsewhere = dir / "elsewhere-dir"
    createDir(elsewhere)
    createSymlink(elsewhere, t.dir)
    check omarchyHookPathProblem(t).len > 0
    expect OmarchyHookError:
      discard writeOmarchyHook(t, "hook\n")
    check not fileExists(elsewhere / "90-repro-addon")
    # The hooks directory itself replaced with a link: refused as well.
    let t2 = home("h4b")
    let hooks = t2.home / ".config/omarchy/hooks"
    removeDir(hooks)
    createSymlink(elsewhere, hooks)
    check omarchyHookPathProblem(t2).len > 0
    expect OmarchyHookError:
      discard writeOmarchyHook(t2, "hook\n")
    check not dirExists(elsewhere / "post-update.d")

  test "a directory below the home writable by others is refused":
    let t = home("h5")
    let hooks = t.home / ".config/omarchy/hooks"
    setFilePermissions(hooks, {fpUserRead, fpUserWrite, fpUserExec,
                               fpGroupRead, fpGroupExec, fpOthersRead,
                               fpOthersWrite, fpOthersExec})
    let p = omarchyHookPathProblem(t)
    check "writable by no one else" in p
    expect OmarchyHookError:
      discard writeOmarchyHook(t, "hook\n")
    check not dirExists(t.dir)

  test "observation: changed, replaced by a link, missing":
    let t = home("h6")
    let objs = writeOmarchyHook(t, "hook\n")
    let f = objs[1]
    writeFile(t.path, "edited\n")
    check observeOmarchyHook(f).startsWith("content changed")
    removeFile(t.path)
    check observeOmarchyHook(f) == "missing"
    createSymlink("/etc/passwd", t.path)
    check observeOmarchyHook(f).startsWith("replaced by a symbolic link")

  test "removal: the add-on's hook and an empty created directory go":
    let t = home("h7")
    let objs = writeOmarchyHook(t, "hook\n")
    check removeOmarchyHook(objs[1]) == (true, "")
    check not fileExists(t.path)
    check removeOmarchyHook(objs[0]) == (true, "")
    check not dirExists(t.dir)
    # Already gone: still removed, nothing to report.
    check removeOmarchyHook(objs[1]).removed

  test "removal leaves a planted link, a changed hook and a non-empty directory":
    let t = home("h8")
    let objs = writeOmarchyHook(t, "hook\n")
    removeFile(t.path)
    let outside = dir / "outside-2"
    writeFile(outside, "keep\n")
    createSymlink(outside, t.path)
    let r = removeOmarchyHook(objs[1])
    check not r.removed and "symbolic link" in r.left
    check symlinkExists(t.path) and readFile(outside) == "keep\n"
    removeFile(t.path)
    writeFile(t.path, "the account's own\n")
    check not removeOmarchyHook(objs[1]).removed
    check readFile(t.path) == "the account's own\n"
    let d = removeOmarchyHook(objs[0])
    check not d.removed and "is not empty" in d.left
    check dirExists(t.dir)

  test "removal through a directory replaced with a link removes nothing there":
    let t = home("h9")
    let objs = writeOmarchyHook(t, "hook\n")
    let moved = dir / "moved-dir"
    moveDir(t.dir, moved)
    createSymlink(moved, t.dir)
    let r = removeOmarchyHook(objs[1])
    check not r.removed and "symbolic link" in r.left
    check fileExists(moved / "90-repro-addon")

suite "generation 0, the ledger and the fingerprint":
  let exe = "/repro/store/0123-repro/bin/repro"

  test "an Arch-family generation 0 carries the ALPM hook and no apt hook":
    let objs = generation0Objects(Gen0Inputs(reproExe: exe,
      packageManagerHook: pmhAlpm))
    var paths: seq[string]
    for o in objs: paths.add(o.path)
    check AlpmHookPath in paths
    check AptHookPath notin paths
    let deb = generation0Objects(Gen0Inputs(reproExe: exe))
    var debPaths: seq[string]
    for o in deb: debPaths.add(o.path)
    check AptHookPath in debPaths and AlpmHookPath notin debPaths

  test "the re-assert unit sees /home read-only only with the Omarchy hook":
    proc reassertOf(inp: Gen0Inputs): string =
      for o in generation0Objects(inp):
        if o.unit == ReassertUnit: return o.content
    let plain = reassertOf(Gen0Inputs(reproExe: exe, packageManagerHook: pmhAlpm))
    check "ProtectHome=yes\n" in plain and "ProtectHome=read-only" notin plain
    let om = reassertOf(Gen0Inputs(reproExe: exe, packageManagerHook: pmhAlpm,
                                   omarchyHome: "/home/omarchy"))
    check "ProtectHome=read-only\n" in om and "ProtectHome=yes" notin om
    # Only the re-assert unit: the secrets unit keeps ProtectHome=yes.
    for o in generation0Objects(Gen0Inputs(reproExe: exe,
        packageManagerHook: pmhAlpm, omarchyHome: "/home/omarchy")):
      if o.unit == SecretsUnit:
        check "ProtectHome=yes\n" in o.content

  test "the ledger round-trips the hook's entries; expected omarchy-hooks records":
    let l = Ledger(generation: "g1", entries: @[
      LedgerEntry(class: lcOmarchyHook, path: "/home/o/.config/omarchy/hooks/post-update.d",
                  unit: "o", kindHint: KindDir, mode: "0755", owner: "1000:1000"),
      LedgerEntry(class: lcOmarchyHook, path: "/home/o/.config/omarchy/hooks/post-update.d/90-repro-addon",
                  unit: "o", kindHint: KindFile, sha256: sha256Hex("x"),
                  mode: "0644", owner: "0:0")])
    let back = parseLedger(render(l))
    check back.entries.len == 2
    check back.entries[1].class == lcOmarchyHook
    check back.entries[1].unit == "o" and back.entries[1].kindHint == KindFile
    var recs: seq[(FingerprintComponent, string, string)]
    for r in expectedRecords(l): recs.add((r.component, r.key, r.value))
    check (fcOmarchyHooks, l.entries[0].path, "d 0755 1000:1000") in recs
    check (fcOmarchyHooks, l.entries[1].path,
           "f 0644 0:0 sha256:" & sha256Hex("x")) in recs

suite "pacman's side files and the hook's name":
  test ".pacnew and .pacsave beside ledger paths are reported, naming the package":
    let d = createTempDir("repro-ar6-pacnew-", "")
    let a = d / "a.conf"
    let b = d / "b.conf"
    writeFile(a, "copy\n")
    writeFile(a & ".pacnew", "vendor\n")
    writeFile(b & ".pacsave", "kept\n")
    let drv = newPacmanDriver(createTempDir("repro-ar6-pacroot-", ""),
      proc(u: string): UnitProvision = UnitProvision(loadState: "not-found"))
    let l = Ledger(entries: @[
      LedgerEntry(class: lcEtcFile, path: a, resource: "fs.systemFile.a",
                  observation: "backup:repro-fx-a", collision: "takeOver"),
      LedgerEntry(class: lcEtcFile, path: b, resource: "fs.systemFile.b",
                  observation: "backup:repro-fx-b"),
      LedgerEntry(class: lcDir, path: d, resource: "fs.systemFile.a")])
    let f = pacnewFindings(l, drv)
    check f.len == 2
    check f.len == 2 and "repro-fx-a" in f[0] and (a & ".pacnew") in f[0] and
      "taken-over file" in f[0]
    check f.len == 2 and "repro-fx-b" in f[1] and (b & ".pacsave") in f[1]

  test "a packaged hook under the ALPM hook's name is refused and reported":
    let root = createTempDir("repro-ar6-alpmroot-", "")
    proc put(rel, content: string) =
      createDir(parentDir(root / rel))
      writeFile(root / rel, content)
    put("var/lib/pacman/local/ALPM_DB_VERSION", "9\n")
    put("var/lib/pacman/local/other-1-1/desc", "%NAME%\nother\n\n%VERSION%\n1-1\n\n")
    put("var/lib/pacman/local/other-1-1/files", "%FILES%\nusr/\nusr/bin/x\n\n")
    check alpmHookNameProblem(root) == ""
    check alpmHookShadowFindings(root).len == 0
    put("var/lib/pacman/local/shadow-1-1/desc", "%NAME%\nshadow\n\n%VERSION%\n1-1\n\n")
    put("var/lib/pacman/local/shadow-1-1/files",
        "%FILES%\nusr/\nusr/share/\nusr/share/libalpm/\nusr/share/libalpm/hooks/\n" &
        "usr/share/libalpm/hooks/90-repro-addon.hook\n\n")
    put("usr/share/libalpm/hooks/90-repro-addon.hook", "[Trigger]\n")
    check "shadow" in alpmHookNameProblem(root)
    let f = alpmHookShadowFindings(root)
    check f.len == 1 and "shadow" in f[0] and "silently disables" in f[0]

suite "the overrideBaseLayer re-check after an Omarchy update":
  let root = createTempDir("repro-ar6-omroot-", "")
  let state = createTempDir("repro-ar6-state-", "")
  proc put(rel, content: string) =
    createDir(parentDir(root / rel))
    writeFile(root / rel, content)
  proc omarchyVersion(version, script: string) =
    removeDir(root / "var/lib/pacman/local")
    put("var/lib/pacman/local/ALPM_DB_VERSION", "9\n")
    let d = "var/lib/pacman/local/omarchy-" & version
    put(d & "/desc", "%NAME%\nomarchy\n\n%VERSION%\n" & version & "\n\n")
    put(d & "/files", "%FILES%\nusr/\nusr/share/\nusr/share/omarchy/\n" &
      "usr/share/omarchy/install/\nusr/share/omarchy/install/a.sh\n" &
      "usr/share/omarchy/migrations/\nusr/share/omarchy/migrations/1.sh\n\n")
    put("usr/share/omarchy/install/a.sh", "sudo tee /etc/omarchy-fixture/kept.conf\n")
    put("usr/share/omarchy/migrations/1.sh", script)
  createDir(state / "addon")
  writeFile(state / "addon/user.profile",
    "addOn {\n  managedEtcPrefixes = [\"/etc/repro-x/\"]\n" &
    "  omarchyAccount = \"omarchy\"\n}\n\n" &
    "fs.systemFile {\n  path = \"/etc/repro-x/acked.conf\"\n" &
    "  content = \"a\"\n  collision = \"overrideBaseLayer\"\n}\n\n" &
    "fs.systemFile {\n  path = \"/etc/repro-x/plain.conf\"\n  content = \"b\"\n}\n")

  test "the first version names the acknowledged path: nothing to report":
    omarchyVersion("4.5.0-3", "sudo cp x /etc/repro-x/acked.conf\n")
    check overrideRecheckFindings(state, root).len == 0

  test "the second version no longer names it, and names a declared path":
    omarchyVersion("4.5.0-4", "sudo cp x /etc/repro-x/plain.conf\n")
    let f = overrideRecheckFindings(state, root)
    # The acknowledgement, and the declaration the new script names (the
    # file, and the managed prefix that covers it).
    check f.len >= 2
    var acked, named = false
    for x in f:
      if "acknowledges nothing now" in x and "acked.conf" in x and
          "4.5.0-4" in x: acked = true
      if "now names a path" in x and "plain.conf" in x and
          "migrations/1.sh" in x: named = true
    check acked
    check named
