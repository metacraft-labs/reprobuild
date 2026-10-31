## The apt hook's wrapper, base-coupled unit flagging and the base identity
## (milestone A10; spec §7.4, §7.8, §7.9).
##
## - *The hook never blocks dpkg.* The exact shell command generation 0
##   writes into ``/etc/apt/apt.conf.d/90repro-addon`` is run with
##   ``/bin/sh -c``, as apt runs it, against four stand-ins for the
##   verification: a clean one, none at all, one that fails and one that
##   hangs. It must exit 0 every time, end within the timeout plus a few
##   seconds, and record each non-clean outcome in its event log. Under
##   ``-d:reproAddonMutation=apt-hook-without-timeout`` the hang case must
##   time out the test's own bound, and under ``apt-hook-without-exit0`` the
##   failure case must exit non-zero (``scripts/run_addon_unit_mutation.sh``).
## - *Base-coupled units* are flagged from their ``Exec*=`` lines, and a
##   closure-bound unit's ``/usr`` paths are not the base's
##   (``base-coupling-unflagged`` must turn this red).
## - *The supported matrix* refuses a base outside it and accepts Ubuntu
##   26.04 (``base-matrix-unchecked`` must turn this red).
## - The base identity's text round-trips, the dpkg status reader keeps
##   what the digest covers, and a package that came to own a ledger path
##   is reported by name.
##
## - A ledger path a package came to own is refused (``EAddOnPackageOwned``),
##   never absorbed (``package-owner-absorbed`` must turn this red); the
##   deploy agent's cursor reads each hook event once, across a rotation.
##
## *Mocking.* The verification is replaced by four small shell scripts:
## what is under test is the hook's wrapper -- its deadline, its exit
## status, its record -- which treats the binary it names as a black box;
## the real verification runs in the VM gates. The dpkg database is a
## fixture tree read by the real dpkg collision driver; unit provision is a
## stub because the build host's systemd is not a guest's (the driver's
## documented seam).

import std/[os, osproc, strutils, tables, tempfiles, times, unittest]

import repro_infra/[addon_diagnostics, profile]

import repro_addon/[apt_hook, base_identity, collision, fingerprint, generation0, ledger, mutations]

proc tool(name: string): string =
  result = findExe(name, followSymlinks = false)
  doAssert result.len > 0, name & " is not on PATH"

proc runHook(exe, logPath: string; timeoutSec, boundSec: int):
    tuple[code: int; secs: float; timedOut: bool] =
  ## Run the hook command; give up (and kill it) after ``boundSec``.
  let cmd = aptHookCommand(exe, timeoutSeconds = timeoutSec,
    logPath = logPath, setsidTool = tool("setsid"),
    loggerTool = "/nonexistent/logger", pidDir = logPath.parentDir)
  let t0 = epochTime()
  let p = startProcess(tool("sh"), args = ["-c", cmd],
                       options = {poStdErrToStdOut})
  defer: p.close()
  while p.peekExitCode() == -1:
    if epochTime() - t0 > boundSec.float:
      # The stand-in; its grandchild is the caller's to clean up.
      discard execCmd("pkill -KILL -f " & quoteShell(exe) & " >/dev/null 2>&1")
      p.kill()
      discard p.waitForExit()
      return (-1, epochTime() - t0, true)
    sleep(50)
  (p.peekExitCode(), epochTime() - t0, false)

suite "the apt hook's wrapper":
  let dir = createTempDir("repro-apt-hook-", "")
  let log = dir / "apt-hook.log"
  proc script(name, body: string): string =
    result = dir / name
    writeFile(result, "#!/bin/sh\n" & body & "\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

  test "the hook text carries no double quote inside the command and no backslash":
    let c = aptHookCommand("/repro/store/x/bin/repro")
    check '"' notin c
    check '\\' notin c
    check aptHook("/repro/store/x/bin/repro").count("DPkg::Post-Invoke") == 1

  test "a clean verification: exit 0, nothing recorded":
    removeFile(log)
    let r = runHook(script("ok", "exit 0"), log, 2, 20)
    check r.code == 0
    check not fileExists(log)

  test "a missing verification: exit 0, recorded":
    removeFile(log)
    let r = runHook(dir / "absent", log, 2, 20)
    check r.code == 0
    check "verify-missing" in readFile(log)

  test "the binary test runs inside the bounded group":
    let c = aptHookCommand("/repro/store/x/bin/repro")
    check "[ -x $1 ] || exit 127; exec $1 system addon verify" in c
    check c.find("[ -x") > c.find("setsid")

  test "a failing verification: exit 0, recorded":
    removeFile(log)
    let r = runHook(script("fail", "exit 3"), log, 2, 20)
    check r.code == 0
    check fileExists(log) and "verify-failed exit=3" in readFile(log)

  test "a hung verification: ended at the deadline, exit 0, recorded":
    removeFile(log)
    # Ignores SIGTERM, and leaves a grandchild: only the follow-up SIGKILL
    # to the whole group ends it (uutils' timeout would leave the
    # grandchild behind).
    # A grandchild with a duration unique to this run, so a leftover of an
    # earlier (mutated) run cannot be mistaken for this one's.
    let marker = $(100000 + getCurrentProcessId() mod 800000)
    let r = runHook(script("hang", "trap '' TERM\nsleep " & marker & " &\n" &
                    "while :; do sleep 1; done"), log, 2, 20)
    check not r.timedOut
    check r.code == 0
    check r.secs < 2.0 + 5.0 + 3.0
    check fileExists(log) and "verify-timeout" in readFile(log)
    sleep(500)
    check execCmd("pgrep -x -f 'sleep " & marker & "' >/dev/null") != 0
    # This run's grandchild, if a mutated hook left it (never anyone else's).
    discard execCmd("pkill -KILL -x -f 'sleep " & marker & "' >/dev/null 2>&1")
    var leftovers: seq[string]
    for k, f in walkDir(dir):
      if "repro-addon-hook." in f: leftovers.add(f)
    check leftovers.len == 0

suite "base-coupled units":
  proc unit(name, content: string; lock = ""; collision = ""): SystemResource =
    SystemResource(kind: srkSystemdSystemUnit, suName: name,
      suContent: content, suAptClosureLock: lock, suCollision: collision)

  test "Exec lines are read with their prefixes dropped":
    check execPrograms("[Service]\nExecStartPre=-/usr/sbin/nft -f x\n" &
      "ExecStart=@/repro/store/a/bin/d d\nExecStop=+kill -TERM $MAINPID\n") ==
      @["/usr/sbin/nft", "/repro/store/a/bin/d", "kill"]

  test "base binaries, bare names and drop-ins are flagged; the store is not":
    let rs = @[
      unit("store.service", "[Service]\nExecStart=/repro/store/p/bin/d\n"),
      unit("nft.service", "[Service]\nExecStartPre=/usr/sbin/nft -f /x\n" &
           "ExecStart=/repro/store/p/bin/d\n"),
      unit("bare.service", "[Service]\nExecStart=python3 -m http.server\n"),
      unit("closure.service", "[Service]\nExecStart=/usr/bin/busybox httpd -f\n" &
           "ExecStartPre=/bin/true\n", lock = "x"),
      unit("ssh.service", "", collision = "dropIn"),
      SystemResource(kind: srkSystemdSystemDropIn, diUnit: "cron.service",
                     diName: "addon")]
    let c = baseCoupledUnits(rs)
    var units: seq[string]
    for x in c: units.add(x.unit)
    check "store.service" notin units
    check "closure.service" notin units
    check "nft.service" in units
    check "bare.service" in units
    check "ssh.service" in units
    check "cron.service" in units

  test "EnvironmentFile=, ExecSearchPath= and a store script's interpreter":
    proc interp(p: string): string =
      if p.endsWith("/run.sh"): "/usr/bin/python3"
      elif p.endsWith("/run2.sh"): "/repro/store/py/bin/python3"
      else: ""
    let rs = @[
      unit("env.service", "[Service]\nEnvironmentFile=-/etc/default/foo\n" &
           "ExecStart=/repro/store/p/bin/d\n"),
      unit("envstore.service", "[Service]\nEnvironmentFile=/repro/store/e/env\n" &
           "ExecStart=/repro/store/p/bin/d\n"),
      unit("search.service", "[Service]\nExecSearchPath=/repro/store/p/bin\n" &
           "ExecStart=d --flag\n"),
      unit("searchbase.service", "[Service]\nExecSearchPath=/repro/store/p/bin:/usr/bin\n" &
           "ExecStart=d\n"),
      unit("script.service", "[Service]\nExecStart=/repro/store/s/run.sh\n"),
      unit("script2.service", "[Service]\nExecStart=/repro/store/s/run2.sh\n")]
    var units: seq[string]
    for x in baseCoupledUnits(rs, interp): units.add(x.unit)
    check "env.service" in units
    check "envstore.service" notin units
    check "search.service" notin units
    check "searchbase.service" in units
    check "script.service" in units
    check "script2.service" notin units

suite "the supported matrix and the base identity":
  test "a base outside the matrix is refused, Ubuntu 26.04 is accepted":
    check matrixRefusal(BaseIdentity(id: "debian", versionId: "14",
      architecture: "amd64")).len > 0
    check matrixRefusal(BaseIdentity(id: "ubuntu", versionId: "26.04",
      architecture: "amd64")).len == 0
    check matrixRefusal(BaseIdentity(id: "debian", versionId: "13",
      architecture: "i386")).len > 0
    expect EAddOnUnsupportedBase:
      checkSupportedBase(BaseIdentity(id: "fedora", versionId: "42",
                                      architecture: "amd64"))

  test "the identity round-trips and reports what changed":
    let pkgs = @[BasePackage(name: "systemd", version: "252.39-1~deb12u1",
      architecture: "amd64", status: "install ok installed")]
    let a = BaseIdentity(id: "debian", versionId: "12",
      versionCodename: "bookworm", architecture: "amd64",
      systemd: "systemd 252 (252.39-1~deb12u1)", packages: pkgs,
      packagesSha256: packagesDigest(pkgs),
      vendorUnits: @[VendorUnit(unit: "cron.service",
        fragment: "/usr/lib/systemd/system/cron.service", sha256: "ab")],
      coupled: @[CoupledUnit(unit: "x.service", reason: "runs /bin/sh from the base")])
    check parseBaseIdentity(renderBaseIdentity(a)) == a
    var b = a
    b.versionId = "13"
    b.packages[0].version = "257.9-1~deb13u1"
    let ch = baseIdentityChanges(a, b)
    check ch.len == 2
    check "debian 12 -> debian 13" in ch[0]
    check baseIdentityChanges(BaseIdentity(), b).len == 0

  test "dpkg status: first stanza per package, the fields the digest covers":
    let t = parseDpkgPackages("Package: dash\nStatus: install ok installed\n" &
      "Priority: required\nArchitecture: amd64\nVersion: 0.5.12-2\n" &
      "Description: x\n more\n\nPackage: apt\nStatus: install ok installed\n" &
      "Version: 2.6.1\nArchitecture: amd64\n")
    check t["dash"].version == "0.5.12-2"
    check t["apt"].architecture == "amd64"
    # Multiarch: the native stanza wins whatever the order.
    let m = parseDpkgPackages("Package: libc6\nArchitecture: i386\nVersion: 2\n\n" &
      "Package: libc6\nArchitecture: amd64\nVersion: 1\n", nativeArch = "amd64")
    check m["libc6"].architecture == "amd64"

  test "a malformed identity is a ValueError, never an index defect":
    expect ValueError:
      discard parseBaseIdentity(BaseIdentityHeader & "\nid\n")

  test "a package that now owns a ledger path is named":
    let root = createTempDir("repro-dpkg-", "")
    createDir(root / "var/lib/dpkg/info")
    writeFile(root / "var/lib/dpkg/status", "")
    writeFile(root / "var/lib/dpkg/info/fixture-pkg.list",
              "/etc\n/etc/repro-fixture\n/etc/repro-fixture/a.conf\n")
    writeFile(root / "var/lib/dpkg/info/fixture-pkg.conffiles",
              "/etc/repro-fixture/a.conf\n")
    let d = newDpkgDriver(root, proc(u: string): UnitProvision =
      UnitProvision(loadState: "not-found"))
    let l = Ledger(entries: @[
      LedgerEntry(class: lcEtcFile, path: "/etc/repro-fixture/a.conf",
                  resource: "fs.systemFile.a", observation: "absent"),
      LedgerEntry(class: lcEtcFile, path: "/etc/repro-fixture/b.conf",
                  resource: "fs.systemFile.b", observation: "absent"),
      LedgerEntry(class: lcDir, path: "/etc/repro-fixture",
                  resource: "fs.systemFile.a")])
    let f = newOwnerFindings(l, d)
    check f.len == 1
    check "fixture-pkg" in f[0] and "/etc/repro-fixture/a.conf" in f[0]
    # A diverted conffile was package-owned at plan time: not reported.
    var l2 = l
    l2.entries[0].observation = "conffile:fixture-pkg"
    check newOwnerFindings(l2, d).len == 0

suite "a ledger path a package came to own":
  test "the plan refuses it with EAddOnPackageOwned, never absorbs it":
    let root = createTempDir("repro-dpkg-own-", "")
    createDir(root / "var/lib/dpkg/info")
    writeFile(root / "var/lib/dpkg/status", "")
    let target = root / "a.conf"
    writeFile(target, "add-on\n")
    writeFile(root / "var/lib/dpkg/info/fixture-pkg.list", target & "\n")
    writeFile(root / "var/lib/dpkg/info/fixture-pkg.conffiles", target & "\n")
    let d = newDpkgDriver(root, proc(u: string): UnitProvision =
      UnitProvision(loadState: "not-found"))
    let sha = sha256OfFile(target)
    var inp = DecisionInputs(address: "systemFile:a", kind: tkFile,
      desiredSha256: sha, desiredContent: "add-on\n", ledgerSha256: sha,
      ledgerOwns: true, ledgerObservation: "absent")
    expect EAddOnPackageOwned:
      discard decide(d, inp, target)
    # Package-owned at plan time already (a diversion's conffile): decided
    # as the ledger's, as before.
    inp.ledgerObservation = "conffile:fixture-pkg"
    check decide(d, inp, target).decision.verdict == cvNoOp

suite "the agent's cursor over the hook's event log":
  test "new events once each, across a rotation; a first read sees all":
    let dir = createTempDir("repro-hook-cursor-", "")
    let log = dir / "apt-hook.log"
    let cur = dir / "state" / AptHookCursorName
    writeFile(log, "t1 drift 1 finding(s)\nt1 finding a\n")
    check hookEventsSince(cur, log) == @["t1 drift 1 finding(s)", "t1 finding a"]
    check hookEventsSince(cur, log).len == 0
    appendEventLog(log, ["finding b"])
    let e = hookEventsSince(cur, log)
    check e.len == 1 and e[0].endsWith(" finding b")
    appendEventLog(log, ["finding c"])
    rotateEventLog(log, maxBytes = 1)       # c is now in .1, unread
    appendEventLog(log, ["finding d"])
    let r = hookEventsSince(cur, log)
    check r.len == 2 and r[0].endsWith(" finding c") and r[1].endsWith(" finding d")
