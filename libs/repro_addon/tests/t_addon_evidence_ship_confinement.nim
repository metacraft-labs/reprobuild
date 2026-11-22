## The evidence shipping unit runs as a dedicated user (ReproOS Add-On Mode
## spec §13 decision 181; threat model G56, T63, T65).
##
## * The unit and every confined run carry one confinement: a dynamic user
##   (never uid 0) with no capability, its own state directory and outbox,
##   the sink credential through ``LoadCredential=`` only, ``/var/lib/repro``
##   and ``/run/repro`` hidden, and no ``AF_UNIX`` socket (so neither the
##   system bus nor PID 1's private socket). The apt hook harvest is its
##   privileged first step, which decodes nothing from the network.
## * The egress units make no Unix socket either.
## * A root caller (contain, release, uninstall, the credential check)
##   decodes nothing the sink sends: it starts a confined run with exactly
##   that confinement and takes only entry names from the outbox.
## * A root writer writes an outbox entry through descriptors that follow
##   no link, so the outbox's owner cannot redirect it with a planted link.
##
## Falsifying builds: ``evidence-ship-runs-as-root`` and
## ``evidence-ship-unix-sockets`` (the confinement step goes red),
## ``egress-units-unix-sockets`` (the egress step), ``ship-decoded-as-root``
## (the root-caller step: the shipping runs in process), and
## ``outbox-written-by-path`` (the planted-link step: the record writer's
## staging link would overwrite a file of root's), ``outbox-listed-by-path``
## (the outbox listed through a link), ``confined-output-unescaped`` (a
## confined run's control bytes reach root's terminal) and
## ``confined-copy-shared`` (two runs share one binary copy).
##
## The euid-0 branch of the root writer runs as uid 0 in a user namespace
## (``unshare --map-auto -r``, this binary re-run with ``AsRootEnv``), the
## state directory handed to a subordinate uid: no host root is needed, and
## the case skips, saying why, where the host offers no such namespace.
##
## Mocks: ``confinedRunner`` stands in for ``systemd-run`` in the
## root-caller step, because a unit test has no PID 1 to start a transient
## unit in; the VM gates (``e2e_addon_evidence_enrol`` and the drill) run the
## real one. Everything else is real files and rendered unit text.

import std/[os, osproc, posix, sequtils, streams, strtabs, strutils, unittest]

import repro_addon/evidence as addonEvidence
import repro_addon/evidence_ship
import repro_addon/generation0
import repro_addon/host_exec
import repro_addon/record_dir
import repro_test_support/reasoned_skip
import repro_core/process_streams

const AsRootEnv = "REPRO_ADDON_DELEGATED_AS_ROOT"
  ## Set to a directory, this binary is the root half of the euid-0 case:
  ## started by ``unshare --map-auto -r`` (uid 0 in a user namespace, with
  ## the subordinate uids mapped too), it hands a state directory to uid
  ## 1000, writes an entry as root, tries a state directory replaced with a
  ## link, prints what it saw, and gives everything back to uid 0 (the
  ## invoking user outside) so the suite can remove it.
if existsEnv(AsRootEnv):
  let base = getEnv(AsRootEnv)
  var said = "ASROOT euid=" & $geteuid()
  let state = base / "top" / "state"
  createDir(state)
  discard posix.chown(state.cstring, Uid(1000), Gid(1000))
  writeDelegatedEntry(state / "outbox", "f.evr", "bytes",
                      staging = state / ".outbox-staging")
  var st: Stat
  discard stat(cstring(state / "outbox"), st)
  said.add(" outbox=" & toOct(int(st.st_mode) and 0o777, 4))
  discard stat(cstring(state / "outbox" / "f.evr"), st)
  said.add(" entry=" & toOct(int(st.st_mode) and 0o777, 4))
  said.add(" listed=" & $outboxEntries(state / "outbox").len)
  createDir(base / "elsewhere")
  createDir(base / "top2")
  createSymlink(base / "elsewhere", base / "top2" / "state")
  var refused = false
  try:
    writeDelegatedEntry(base / "top2" / "state" / "outbox", "g.evr", "bytes")
  except OSError:
    refused = true
  var inElsewhere = 0
  for _ in walkDirRec(base / "elsewhere"): inc inElsewhere
  said.add(" linkRefused=" & $refused & " elsewhere=" & $inElsewhere)
  for p in walkDirRec(base, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}):
    discard posix.lchown(p.cstring, Uid(0), Gid(0))
  echo said
  quit(0)

let root = getTempDir() / ("addon-ship-confinement-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

const Exe = "/repro/store/prefixes/repro-addon/x/bin/repro"

let ev = EvidenceUnitsInputs(sinkAddress: "10.0.2.100", sinkPort: 7443,
  sinkCaPem: "-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----\n",
  sinkHostId: repeat('a', 64))

proc lines(unit: string): seq[string] =
  for l in unit.splitLines():
    if l.len > 0: result.add(l)

suite "the shipping unit runs as a dedicated user (§13 decision 181)":
  test "a dynamic user, the credential by LoadCredential=, no AF_UNIX":
    let u = evidenceShipUnit(Exe, ev).lines
    checkpoint u.join("\n")
    check "DynamicUser=yes" in u
    check ("User=" & EvidenceShipUser) in u
    check not u.anyIt(it.startsWith("User=root") or it == "DynamicUser=no")
    check "StateDirectory=repro-addon-evidence repro-addon-evidence/outbox" in u
    check ("LoadCredential=host-ca.crt:" & EvidenceCredentialCertPath) in u
    check ("LoadCredential=host-ca.key:" & EvidenceCredentialKeyPath) in u
    # nothing of the root-only state is writable or even visible
    check not u.anyIt(it.startsWith("ReadWritePaths="))
    check "InaccessiblePaths=-/var/lib/repro -/run/repro" in u
    check "CapabilityBoundingSet=" in u
    check "RestrictAddressFamilies=AF_INET AF_INET6" in u
    check not u.anyIt(it.startsWith("RestrictAddressFamilies=") and
                      "AF_UNIX" in it)
    check "IPAddressDeny=any" in u and "IPAddressAllow=10.0.2.100" in u
    check ("Environment=" & EvidenceShipConfinedEnv & "=1") in u
    check ("ExecStartPre=+" & Exe & " system addon evidence-harvest") in u
    check ("ExecStart=" & Exe & " system addon evidence-ship") in u

  test "the path unit makes nothing in the dynamic user's directory":
    let p = evidenceShipPathUnit().lines
    check ("DirectoryNotEmpty=" & EvidenceOutboxPath) in p
    check not p.anyIt(it.startsWith("MakeDirectory="))

  test "the egress units make no Unix socket":
    for u in [egressUnit("/usr/sbin/nft", "ab"), egressCheckUnit(Exe)]:
      let ls = u.lines
      checkpoint u
      check "RestrictAddressFamilies=AF_NETLINK" in ls
      check "IPAddressDeny=any" in ls
    check "CapabilityBoundingSet=CAP_NET_ADMIN" in
      egressUnit("/usr/sbin/nft", "ab").lines
    # the check also writes into the dynamic user's outbox
    check "CapabilityBoundingSet=CAP_NET_ADMIN CAP_DAC_OVERRIDE" in
      egressCheckUnit(Exe).lines

  test "a confined run carries exactly the unit's confinement":
    let conf = EvidenceConf(sinkEndpoint: "10.0.2.100:7443",
                            sinkHost: repeat('a', 64), heartbeatSec: 300)
    let argv = confinedRunArgv(conf, ["evidence-ship", "--no-backoff"],
                               reproExe = Exe, systemdRun = "/usr/bin/systemd-run")
    let sep = argv.find("--")
    check sep > 0
    check argv[sep + 1 .. ^1] == @[Exe, "system", "addon", "evidence-ship",
                                   "--no-backoff"]
    var props: seq[string]
    for i in 0 ..< sep:
      if argv[i] == "-p": props.add(argv[i + 1])
    for l in evidenceShipConfinement(ev):
      check l in props
    check "--wait" in argv and "--pipe" in argv
    check sinkAddressOf("[fd00::1]:7443") == "fd00::1"

  test "a confined run executes the add-on's binary in the store":
    let unit = root / "repro-addon-evidence.service"
    writeFile(unit, evidenceShipUnit(Exe, ev))
    # From a path the sandbox hides, the installed unit's binary; it must
    # exist, so a missing one falls back to this process's own.
    check confinedReproExe(unit, root / "none.json", "/root/addon/repro") ==
      "/root/addon/repro"
    let conf = EvidenceConf(sinkEndpoint: "10.0.2.100:7443",
                            sinkHost: repeat('a', 64), heartbeatSec: 300)
    # A binary outside the store runs as root's copy, in a directory of
    # this run's own under ConfinedExeCopyDir (not /run, which is noexec,
    # and not the dynamic user's state directory, which systemd refuses to
    # execute from).
    let copy = confinedCopyPath(4242, "abc")
    let a = confinedRunArgv(conf, ["evidence-ship"], reproExe = "/root/addon/repro",
                            systemdRun = "/usr/bin/systemd-run", exeCopy = copy)
    check a[a.find("--") + 1] == copy
    check copy.startsWith(ConfinedExeCopyDir & "/")
    let b = confinedRunArgv(conf, ["evidence-ship"], reproExe = Exe,
                            systemdRun = "/usr/bin/systemd-run")
    check not b.anyIt(it.startsWith("BindReadOnlyPaths="))
    check b[b.find("--") + 1] == Exe

  test "two confined runs at once never share a binary copy":
    let one = confinedCopyPath(4242)
    let two = confinedCopyPath(4242)
    checkpoint one & " " & two
    check one != two
    check parentDir(one) != ConfinedExeCopyDir
    check parentDir(parentDir(one)) == ConfinedExeCopyDir

  test "a confined run's output reaches root's terminal escaped":
    check escapeControl("ok\n") == "ok\n"
    check escapeControl("\e]0;owned\a\e[2J") == "\\x1b]0;owned\\x07\\x1b[2J"
    check escapeControl("a\\b") == "a\\\\b"
    check escapeControl("\xff") == "\\xff"

var calls: seq[seq[string]]
proc recordingRunner(argv: seq[string]): HostToolResult {.nimcall.} =
  calls.add(argv)
  HostToolResult(exitCode: 0, output: "evidence: shipped 0, queued 1\n")

suite "a root caller decodes nothing the sink sends (§13 decision 181)":
  test "the host's site ships in a confined run; the outbox is read by name":
    let base = root / "caller"
    createDir(base / "state")
    var site = defaultShipSite()
    site.confPath = base / "evidence.conf"
    site.stateDir = base / "state"
    site.harvestStateDir = base / "state"
    site.outbox = base / "state" / "outbox"
    site.aptHookLog = base / "apt-hook.log"
    site.credentialCert = base / "missing.crt"
    site.credentialKey = base / "missing.key"
    check site.confined
    writeDelegatedEntry(site.outbox, "00000000000000000001-1-x.evr", "\xff\xfe")
    let conf = EvidenceConf(sinkEndpoint: "10.0.2.100:7443",
                            sinkHost: repeat('a', 64), heartbeatSec: 300)
    calls = @[]
    confinedRunner = recordingRunner
    let r = shipFor(site, conf, "h")
    confinedRunner = nil
    checkpoint $r
    check calls.len == 1
    if calls.len == 1:
      check "DynamicUser=yes" in calls[0]
      check calls[0][^2 .. ^1] == @["evidence-ship", "--no-backoff"]
    # the entry is untouched (never decoded here) and counted by name
    check r.pending == 1
    check readFile(site.outbox / "00000000000000000001-1-x.evr") == "\xff\xfe"

  test "the unit's own view: the credential from $CREDENTIALS_DIRECTORY":
    putEnv("CREDENTIALS_DIRECTORY", "/run/credentials/x")
    let u = unitShipSite()
    delEnv("CREDENTIALS_DIRECTORY")
    check not u.confined
    check u.credentialKey == "/run/credentials/x/host-ca.key"
    check u.credentialCert == "/run/credentials/x/host-ca.crt"
    check u.stateDir == EvidenceShipUnitStateDir
    check u.aptHookLog == ""

suite "a root writer follows no link into the outbox (§13 decision 181)":
  test "an entry is written whole, 0600, with no temporary left":
    let st = root / "w1" / "state"
    createDir(st)
    writeDelegatedEntry(st / "outbox", "a.evr", "bytes",
                        staging = st / ".outbox-staging")
    check readFile(st / "outbox" / "a.evr") == "bytes"
    var s: Stat
    check stat(cstring(st / "outbox" / "a.evr"), s) == 0
    check (int(s.st_mode) and 0o777) == 0o600
    var left = 0
    for _ in walkDir(st / ".outbox-staging"): inc left
    for k, p in walkDir(st / "outbox"):
      if ".tmp-" in p: inc left
    check left == 0

  test "a staging directory replaced with a link is not written through":
    let st = root / "w2" / "state"
    let elsewhere = root / "w2" / "elsewhere"
    createDir(st / "outbox")
    createDir(elsewhere)
    createSymlink(elsewhere, st / ".outbox-staging")
    # The writer unlinks a stale temporary of its own name before it makes
    # one: through the link, that would delete this file of root's. An
    # empty ``elsewhere`` afterwards would not tell (a followed temporary
    # is renamed away).
    let sentinel = elsewhere / (".b.evr.tmp-" & $getCurrentProcessId())
    writeFile(sentinel, "ROOT'S FILE")
    writeDelegatedEntry(st / "outbox", "b.evr", "bytes",
                        staging = st / ".outbox-staging")
    check fileExists(sentinel) and readFile(sentinel) == "ROOT'S FILE"
    var inElsewhere = 0
    for _ in walkDir(elsewhere): inc inElsewhere
    checkpoint $inElsewhere
    check inElsewhere == 1
    check readFile(st / "outbox" / "b.evr") == "bytes"

  test "an outbox replaced with a link is refused":
    let st = root / "w3" / "state"
    let elsewhere = root / "w3" / "elsewhere"
    createDir(st)
    createDir(elsewhere)
    createSymlink(elsewhere, st / "outbox")
    expect OSError:
      writeDelegatedEntry(st / "outbox", "c.evr", "bytes",
                          staging = st / ".outbox-staging")
    var inElsewhere = 0
    for _ in walkDir(elsewhere): inc inElsewhere
    check inElsewhere == 0

  test "as root, an entry is handed to the state directory's owner":
    # The euid-0 branch: the state directory by O_NOFOLLOW from its
    # parent, an outbox root makes 0711, an entry 0644 on its descriptor,
    # and a state directory replaced with a link refused.
    let base = root / "w6"
    createDir(base / "top")
    let unshare = findExe("unshare")
    if unshare.len == 0:
      skip("no unshare(1) on this host: the euid-0 branch needs a user namespace")
    else:
      let p = startProcess(unshare, args = ["--map-auto", "-r", getAppFilename()],
        env = newStringTable({AsRootEnv: base, "PATH": getEnv("PATH")}),
        options = {poStdErrToStdOut})
      let output = drainStream(p.outputStream)
      let code = p.waitForExit()
      p.close()
      checkpoint output
      if code != 0 and "ASROOT" notin output and
          ("map" in output or "Operation not permitted" in output or
           "newuidmap" in output):
        skip("no user namespace with subordinate uids here: " & output.strip())
      else:
        check code == 0
        check "ASROOT euid=0" in output
        check " outbox=0711" in output
        check " entry=0644" in output
        check " listed=1" in output
        check " linkRefused=true elsewhere=0" in output

  test "an outbox whose state directory does not exist yet is made":
    let st = root / "w5" / "state"
    writeDelegatedEntry(st / "outbox", "e.evr", "bytes",
                        staging = st / ".outbox-staging")
    check readFile(st / "outbox" / "e.evr") == "bytes"

  test "the record writer goes through it":
    let st = root / "w4" / "state"
    createDir(st / "outbox")
    let elsewhere = root / "w4" / "elsewhere"
    createDir(elsewhere)
    createSymlink(elsewhere, outboxStaging(st / "outbox"))
    # A file the link would have the writer overwrite (and then move away):
    # it must keep its bytes (red under ``outbox-written-by-path``).
    writeFile(elsewhere / "d.evr", "ROOT'S FILE")
    writeOutboxEntry(st / "outbox", "d.evr", "bytes")
    check readFile(elsewhere / "d.evr") == "ROOT'S FILE"
    var inElsewhere = 0
    for _ in walkDir(elsewhere): inc inElsewhere
    check inElsewhere == 1
    check readFile(st / "outbox" / "d.evr") == "bytes"

  test "the outbox is listed without following a link":
    let st = root / "w7" / "state"
    let elsewhere = root / "w7" / "elsewhere"
    createDir(st)
    createDir(elsewhere)
    writeFile(elsewhere / "x.evr", "not the outbox's")
    createSymlink(elsewhere, st / "outbox")
    var listed: seq[string]
    try: listed = outboxEntries(st / "outbox")
    except OSError: listed = @[]
    checkpoint $listed
    check listed.len == 0
    # Inside a real outbox, a link named like an entry is not one.
    let st2 = root / "w8" / "state"
    createDir(st2 / "outbox")
    writeFile(st2 / "outbox" / "a.evr", "a")
    createSymlink(elsewhere / "x.evr", st2 / "outbox" / "b.evr")
    check outboxEntries(st2 / "outbox") == @[st2 / "outbox" / "a.evr"]

removeDir(root)
