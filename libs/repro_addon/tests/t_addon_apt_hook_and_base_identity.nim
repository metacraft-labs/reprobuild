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
## *Mocking.* The verification is replaced by four small shell scripts:
## what is under test is the hook's wrapper -- its deadline, its exit
## status, its record -- which treats the binary it names as a black box;
## the real verification runs in the VM gates. The dpkg database is a
## fixture tree read by the real dpkg collision driver; unit provision is a
## stub because the build host's systemd is not a guest's (the driver's
## documented seam).

import std/[os, osproc, strutils, tables, tempfiles, times, unittest]

import repro_infra/[addon_diagnostics, profile]

import repro_addon/[base_identity, collision, generation0, ledger, mutations]

proc tool(name: string): string =
  result = findExe(name, followSymlinks = false)
  doAssert result.len > 0, name & " is not on PATH"

proc runHook(exe, logPath: string; timeoutSec, boundSec: int):
    tuple[code: int; secs: float; timedOut: bool] =
  ## Run the hook command; give up (and kill it) after ``boundSec``.
  let cmd = aptHookCommand(exe, timeoutSeconds = timeoutSec,
    logPath = logPath, timeoutTool = tool("timeout"),
    loggerTool = "/nonexistent/logger")
  let t0 = epochTime()
  let p = startProcess(tool("sh"), args = ["-c", cmd],
                       options = {poStdErrToStdOut})
  defer: p.close()
  while p.peekExitCode() == -1:
    if epochTime() - t0 > boundSec.float:
      # The whole group: the hook's sleeping child too.
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

  test "a failing verification: exit 0, recorded":
    removeFile(log)
    let r = runHook(script("fail", "exit 3"), log, 2, 20)
    check r.code == 0
    check fileExists(log) and "verify-failed exit=3" in readFile(log)

  test "a hung verification: ended at the deadline, exit 0, recorded":
    removeFile(log)
    # Ignores SIGTERM: only the follow-up SIGKILL ends it.
    let r = runHook(script("hang", "trap '' TERM\nwhile :; do sleep 1; done"),
                    log, 2, 20)
    check not r.timedOut
    check r.code == 0
    check r.secs < 2.0 + 5.0 + 3.0
    check fileExists(log) and "verify-timeout" in readFile(log)

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
    let t = parseDpkgStatus("Package: dash\nStatus: install ok installed\n" &
      "Priority: required\nArchitecture: amd64\nVersion: 0.5.12-2\n" &
      "Description: x\n more\n\nPackage: apt\nStatus: install ok installed\n" &
      "Version: 2.6.1\nArchitecture: amd64\n")
    check t["dash"].version == "0.5.12-2"
    check t["apt"].architecture == "amd64"

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
