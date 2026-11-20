## Add-On Mode ``package(apt, ...)`` closures run their alternatives-managed
## commands — a real amd64 Debian 13 closure, executed.
##
## Governing spec: ``reprobuild-pm/spec/ReproOS-Add-On-Mode.md`` §8.3, "How a
## closure is pinned, stored and bound", item 4 ("Alternatives") and item 6.
## Regression test for reprobuild-pm
## ``issues/2026-11-12-apt-closures-leave-out-every-alternatives-managed-command.md``:
## Debian ships ``awk``, ``which``, ``nc`` and ``iptables`` only through
## ``update-alternatives`` calls in the providers' ``postinst``, the realiser
## runs no maintainer script, so a bound unit's ``/usr/bin/awk`` did not
## exist and a script-driven service failed at run time on a clean plan.
##
## The fixture lock ``fixtures/apt_closure/debian-trixie-20261001-amd64-alternatives.lock``
## pins the closure of ``mawk``, ``iptables`` and ``netcat-openbsd`` (with
## the Essential set) in Debian 13 "trixie" for ``amd64`` on
## ``snapshot.debian.org`` at ``20261001T000000Z``, written by
## ``repro-harvest-apt --emit-lock`` after verifying that ``InRelease``
## against ``recipes/catalog/foreign/apt/keys/archives/debian-archive-trixie.gpg``
## (the archive URL then written ``http://``, as in the armhf fixture: every
## member is pinned by SHA-256, so the transport is not trusted).
##
## NO MOCKS. The realiser downloads the real ``.deb``s with its own fetcher,
## verifies them, unpacks them, reads their real ``postinst`` scripts, and
## the closure's own binaries are then EXECUTED: ``awk`` through the
## closure's own dynamic loader and libc (the binding of item 5 cannot be
## reproduced without root on a host whose ``/lib64`` is not Debian's, so
## the loader is invoked by path -- the program it loads is the link the
## unit would run), and ``which`` by the closure's own ``dash``.
##
## NETWORK. Like ``t_addon_apt_closure_trixie_armhf.nim``: offline when every
## member is in ``$REPRO_TEST_APT_DEB_CACHE`` (default
## ``<user cache>/reprobuild-test-fixtures/apt-debs``), otherwise only with
## ``REPRO_LIVE=1``; it skips with that reason. Executing amd64 binaries
## needs an x86_64 Linux host; elsewhere the execution checks skip.

from repro_core/process_streams import drainStream
import std/[os, osproc, streams, strtabs, strutils, unittest]

import repro_dsl_stdlib/packages/apt_closure
import repro_dsl_stdlib/packages/apt_jammy
import repro_test_support/reasoned_skip
from repro_test_support/process_fixtures import releaseDirAtProcessExit

const LockText = staticRead(
  "fixtures/apt_closure/debian-trixie-20261001-amd64-alternatives.lock")

proc debCache(): string =
  result = getEnv("REPRO_TEST_APT_DEB_CACHE")
  if result.len == 0:
    result = getCacheDir() / "reprobuild-test-fixtures" / "apt-debs"
  createDir(result)

proc liveAllowed(lock: AptClosureLock): bool =
  if getEnv("REPRO_LIVE") == "1": return true
  for d in lock.debs:
    if not fileExists(debCache() / (d.sha256 & ".deb")): return false
  true

const SkipReason = "needs the network: set REPRO_LIVE=1, or populate " &
  "$REPRO_TEST_APT_DEB_CACHE with the lock's members"

proc run(argv: seq[string]; env: seq[(string, string)] = @[]):
    tuple[output: string; code: int] =
  ## Run ``argv`` with exactly ``env`` (nothing inherited: no host PATH a
  ## command could be found on instead of the closure's).
  let envTable = newStringTable(modeCaseSensitive)
  for (k, v) in env: envTable[k] = v
  let p = startProcess(argv[0], args = argv[1 .. ^1], env = envTable,
    options = {poStdErrToStdOut})
  defer: p.close()
  result.output = drainStream(p.outputStream)
  result.code = p.waitForExit()

suite "Add-On apt closure: alternatives-managed commands exist and run":
  test "awk, which, nc and iptables resolve inside the closure and run":
    let lock = parseAptClosureLock(LockText)
    check lock.architecture == "amd64"
    check lock.roots == @["mawk", "iptables", "netcat-openbsd"]
    if not liveAllowed(lock):
      skip(SkipReason)
    else:
      let store = getTempDir() / ("t-addon-apt-alternatives-" &
        $getCurrentProcessId())
      releaseDirAtProcessExit(store)
      if dirExists(store): removeDir(store)
      createDir(store)
      let prefix = realiseAptClosure(lock, store, debCache(),
        hostMachine = "", retainDebCache = true)

      proc linkTarget(rel: string): string =
        if symlinkExists(prefix / rel): expandSymlink(prefix / rel) else: ""

      # No package ships these paths; each exists only because its
      # provider's postinst registers it.
      check linkTarget("usr/bin/awk") == "mawk"
      check linkTarget("usr/bin/nawk") == "mawk"
      check linkTarget("usr/bin/which") == "which.debianutils"
      # /bin/nc is registered pre-merged-/usr and lands where the union
      # folds /bin.
      check linkTarget("usr/bin/nc") == "nc.openbsd"
      # iptables registers BOTH backends (legacy at 10, nft at 20); the
      # highest priority wins, as dpkg's automatic mode chooses, and the
      # slaves follow the master's choice.
      check linkTarget("usr/sbin/iptables") == "iptables-nft"
      check linkTarget("usr/sbin/iptables-save") == "iptables-nft-save"
      check linkTarget("usr/sbin/ip6tables") == "ip6tables-nft"
      let record = readFile(prefix / ".repro-apt-alternatives").splitLines()
      check "master iptables usr/sbin/iptables usr/sbin/iptables-nft 20 " &
        "iptables" in record
      check "master nc usr/bin/nc usr/bin/nc.openbsd 50 netcat-openbsd" in
        record

      when defined(linux) and defined(amd64):
        let loader = prefix / "usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
        let libs = prefix / "usr/lib/x86_64-linux-gnu"
        check fileExists(loader)
        # The program behind /usr/bin/awk is the closure's mawk, and it runs
        # on the closure's own libc.
        let awk = run(@[loader, "--library-path", libs,
          prefix / "usr/bin/awk", "BEGIN { print 6 * 7 }"])
        check awk.code == 0
        check awk.output.strip() == "42"
        # ``which`` is a shell script; the closure's dash runs it and it
        # finds awk on a PATH holding only the closure's bin directory.
        let which = run(@[loader, "--library-path", libs,
          prefix / "usr/bin/dash", prefix / "usr/bin/which", "awk"],
          env = @[("PATH", prefix / "usr/bin")])
        check which.code == 0
        check which.output.strip() == prefix / "usr/bin/awk"
      else:
        skip("executing the closure needs an x86_64 Linux host")
