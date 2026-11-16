## Gate ``e2e_addon_bootstrap_uninstall_byte_identity``.
##
## On each base of the matrix, in a disposable guest: fingerprint the base,
## preflight, bootstrap with the acknowledged plan digest, apply a
## generation that adds a unit, an ``/etc`` file and a diversion of a
## package-owned file, apply one that removes the unit and the ``/etc``
## file, uninstall, and fingerprint again. The two base fingerprints must be
## equal, with no exception needed (the add-on creates no account; the
## journal is not part of the fingerprint). Between the steps, every
## fingerprint diff must equal the delta the ledgers account for -- which is
## what makes this a test of the ledger as well as of uninstall.
##
## Before the comparison means anything, the base must fingerprint the same
## twice in a row (the determinism guard): a volatile record the
## fingerprint failed to exclude would otherwise show up as an add-on
## difference.
##
## Two more steps before the uninstall: an apply declaring a kind the add-on
## does not manage (``linux.sysctl``) must be refused with nothing written,
## no generation committed; and an uninstall that meets drift (a tampered
## ledger file) must fail, keep the object and the ledger copy, and
## complete once the object is restored.
##
## Then the same guest is bootstrapped again with ``--defer-recipient-key``
## (spec §6.5.2: how an image's assembly boot bootstraps): no recipient key
## at bootstrap, the host's own created by the next re-assert (a ``lateKey``
## ledger entry), and an uninstall that again restores the first
## fingerprint byte for byte.
##
## Negative control: with ``REPRO_ADDON_MUTATION=uninstall-skips-diversion-removal``
## the run uses the add-on binary built with that mutation; this gate must
## then FAIL, with a diff naming the diversion of ``/etc/issue.net``. Two
## more mutations: ``apply-skips-kind-check`` (the sysctl is applied and
## left behind) and ``uninstall-discards-state-on-drift`` (the ledger is
## gone after the failed uninstall, so the second one cannot run).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_bootstrap_uninstall_byte_identity``).
## Bases: ``REPRO_ADDON_BASES`` (default: the amd64 matrix). Backend:
## ``REPRO_ADDON_BACKEND=incus`` for the inner loop.
##
## *Mocking.* None: real distribution images, real systemd, dpkg and apt,
## the real static add-on binary, real disks.

import std/[json, os, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const Gen1Profile = """addOn {
  managedEtcPrefixes = ["/etc/repro-addon-fixture/", "/etc/issue.net"]
}

systemd.systemUnit {
  floorExceptions = ["serviceFloor: a test fixture that runs the base's own binaries"]
  name = "repro-addon-fixture.service"
  content = "[Unit]
Description=Reprobuild add-on test fixture service

[Service]
ExecStart=/bin/sleep infinity

[Install]
WantedBy=repro-addon.target
"
  enabled = true
}

fs.systemFile {
  path = "/etc/repro-addon-fixture/fixture.conf"
  content = "fixture = 1
"
}

linux.dpkgDiversion {
  path = "/etc/issue.net"
}

fs.systemFile {
  path = "/etc/issue.net"
  content = "Managed by the Reprobuild add-on test fixture.
"
  depends_on = ["linux.dpkgDiversion:/etc/issue.net"]
}
"""

const UnmanagedKindProfile = """linux.udevRule {
  name = "99-repro-fixture.rules"
  content = "KERNEL==\"null\", MODE=\"0666\"
"
}
"""

const Gen2Profile = """addOn {
  managedEtcPrefixes = ["/etc/repro-addon-fixture/", "/etc/issue.net"]
}

linux.dpkgDiversion {
  path = "/etc/issue.net"
}

fs.systemFile {
  path = "/etc/issue.net"
  content = "Managed by the Reprobuild add-on test fixture.
"
  depends_on = ["linux.dpkgDiversion:/etc/issue.net"]
}
"""

const
  R3Target = "rpi2"
  R3Dirs = [("/repro", "0711"), ("/repro/store", "0755"),
            ("/etc/repro", "0750"), ("/var/lib/repro", "0750"),
            ("/var/lib/repro/agent", "0750"),
            ("/var/lib/repro/agent/state", "0755"),
            ("/var/lib/repro/agent/state/deploy-agent", "0750"),
            ("/run/repro", "0755"), ("/run/repro/secrets", "0700")]
    ## Round 3's pre-bootstrap directories, with modes that differ from the
    ## add-on's own (spec §5.3) wherever the preflight allows one: a
    ## takeover makes each root's with its §5.3 mode, and uninstall must put
    ## back these.
  R3Files = ["/etc/repro/deploy-manifest-allowed-signers",
             "/etc/tmpfiles.d/repro-addon-bootstrap.conf",
             "/var/lib/repro/agent/recipient.key",
             "/var/lib/repro/agent/recipient.pub",
             "/var/lib/repro/agent/state/deploy-agent/" & R3Target & ".seq"]
  R3Token = "/var/log/repro-addon/uninstall-state-removal-pending.json"

proc r3Stat(g: Guest): Table[string, string] =
  ## Identity, mode and owner of every round-3 input, and each file's
  ## sha256. The identity is the inode number AND the birth time (statx
  ## ``%w``, with nanoseconds): ext4 hands a file created right after one
  ## was unlinked the same inode number, so the number alone does not tell
  ## a removed-and-rewritten input from the one that was there (A11 round
  ## 17: the site falsifiers were green on it).
  var paths: seq[string]
  for (d, _) in R3Dirs: paths.add(d)
  for f in R3Files: paths.add(f)
  let st = g.run("stat -c '%n %i %a %u:%g %w' " & paths.join(" ") & " 2>&1")
  for line in st.splitLines():
    let f = line.splitWhitespace()
    if f.len >= 5:
      result[f[0]] = f[1] & "@" & f[4 .. ^1].join("_") & " " & f[2] & " " & f[3]
  let sums = g.run("sha256sum " & R3Files.join(" ") & " 2>&1")
  for line in sums.splitLines():
    let f = line.splitWhitespace()
    if f.len == 2 and f[1] in R3Files: result[f[1]] = result.getOrDefault(f[1]) & " " & f[0]

proc preBootstrapRound(g: Guest; repro: string; anchors: Anchors;
                       step: proc (name: string; ok: bool; detail: string)):
    tuple[before, after: string] =
  ## Round 3 (A11 code review round 16, §13 decisions 166-168): a host that
  ## carries every pre-bootstrap input of spec §6.1 -- an empty store under
  ## ``/repro``, the signers file in ``/etc/repro``, the deploy agent's key,
  ## its public half and a sequence floor, the ``/run/repro`` directories
  ## and the tmpfiles fragment -- with modes that are not the add-on's.
  ## Bootstrap takes them over; the floor is bumped and a floor for a
  ## second target appears, as the add-on's deploy agent would write them;
  ## the first uninstall stops after the ledger copy (``system/`` made a
  ## mount point, so its rmdir fails with EBUSY) and must leave the token
  ## and every input intact; the re-run finishes. Then every input must
  ## have its inode, its bytes, its prior mode and owner (0:0), both floors
  ## must be there, and the fingerprint must equal the staged host's.
  let tmpfiles = "d /run/repro 0755 root root -\nd /run/repro/secrets 0700 root root -\n"
  writeFile(g.runDir / "r3-tmpfiles.conf", tmpfiles)
  g.copyTo(g.runDir / "r3-tmpfiles.conf", "/root/addon/r3-tmpfiles.conf")
  var stage = "set -e; "
  for (d, m) in R3Dirs: stage.add("mkdir -p " & d & "; chmod " & m & " " & d & "; ")
  stage.add("cp /root/addon/deploy-signers.anchors /etc/repro/deploy-manifest-allowed-signers; " &
    "chmod 0644 /etc/repro/deploy-manifest-allowed-signers; " &
    "cp /root/addon/r3-tmpfiles.conf /etc/tmpfiles.d/repro-addon-bootstrap.conf; " &
    "chmod 0644 /etc/tmpfiles.d/repro-addon-bootstrap.conf; " &
    "cp /root/addon/r3.key /var/lib/repro/agent/recipient.key; " &
    "chmod 0400 /var/lib/repro/agent/recipient.key; " &
    "cp /root/addon/r3.pub /var/lib/repro/agent/recipient.pub; " &
    "chmod 0444 /var/lib/repro/agent/recipient.pub; " &
    "printf '7\\n' > /var/lib/repro/agent/state/deploy-agent/" & R3Target & ".seq; " &
    "chmod 0600 /var/lib/repro/agent/state/deploy-agent/" & R3Target & ".seq; " &
    "chown -R 0:0 /repro /etc/repro /var/lib/repro /run/repro; " &
    # The earlier rounds' uninstalls made /var/log/repro-addon; it goes, so
    # this round sees bootstrap make it (§13 decision 178).
    "rm -rf /var/log/repro-addon")
  let st0 = g.exec(stage)
  step("round 3: the pre-bootstrap inputs are staged", st0.exitCode == 0,
       st0.stdout & st0.stderr)
  result.before = g.takeFingerprint(repro)
  let pre = r3Stat(g)
  # The identity is only as good as its birth time: where the file system
  # reports none (statx gives "-"), the comparison fails closed here.
  var noBirth: seq[string]
  for k, v in pre:
    if v.splitWhitespace()[0].endsWith("@-"): noBirth.add(k)
  step("round 3: every input has a birth time", noBirth.len == 0 and
       pre.len == R3Dirs.len + R3Files.len,
       "no birth time: " & noBirth.join(", ") & "; inputs read: " & $pre.len)
  # R16-5: who owns /var/log here (Ubuntu's is root:syslog 0775).
  let logOwner = g.run("stat -c '%n %U:%G %a' /var/log 2>&1")
  step("round 3: /var/log ownership (recorded)", true, logOwner)
  let pf = g.exec(repro & " system addon preflight" & anchors.flags)
  step("round 3: preflight accepts the inputs", pf.exitCode == 0,
       pf.stdout & pf.stderr)
  if pf.exitCode != 0: return
  let bs = g.exec(repro & " system addon bootstrap --plan " &
                  planDigestOf(pf.stdout) & anchors.flags)
  step("round 3: bootstrap", bs.exitCode == 0, bs.stdout & bs.stderr)
  if bs.exitCode != 0: return
  # §13 decision 178: bootstrap made the uninstall records' directory,
  # root's 0700, and verify checks it.
  let logDir = g.exec("stat -c '%U:%G %a %F' /var/log/repro-addon")
  let vf = g.exec(repro & " system addon verify")
  step("round 3: bootstrap made /var/log/repro-addon root's 0700, and verify checks it",
       logDir.exitCode == 0 and logDir.stdout.strip() == "root:root 700 directory" and
         "/var/log/repro-addon:" notin vf.stdout,
       logDir.stdout & logDir.stderr & "\n" & vf.stdout)
  let taken = g.run("stat -c '%n %a %u:%g' /var/lib/repro/agent/state/deploy-agent /var/lib/repro/agent")
  step("round 3: the takeover gave the inputs the add-on's modes (recorded)", true, taken)
  # The deploy agent's writes: the floor bumped in place, a floor for a
  # target the preflight never saw (§13 decision 168).
  # The agent writes a floor to a temporary name and renames it into place
  # (a new inode at every tick), so the inodes the uninstall must keep are
  # the ones these writes leave.
  const Records = "/var/lib/repro/agent/state/deploy-agent/"
  let ag = g.exec("printf '8\\n' > " & Records & R3Target & ".seq.tmp && " &
    "chmod 0600 " & Records & R3Target & ".seq.tmp && mv " & Records &
    R3Target & ".seq.tmp " & Records & R3Target & ".seq && " &
    "printf '41\\n' > " & Records & "rpi3.seq.tmp && chmod 0600 " & Records &
    "rpi3.seq.tmp && mv " & Records & "rpi3.seq.tmp " & Records & "rpi3.seq")
  let floorIno = g.exec("stat -c '%i %w' " & Records & R3Target & ".seq " &
                        Records & "rpi3.seq").stdout
  step("round 3: the agent's floors are written", ag.exitCode == 0, ag.stdout & ag.stderr)
  # The crash leg: system/ a mount point, so the rmdir after the ledger
  # copy fails (EBUSY). /var/lib/repro itself is an input and never removed,
  # so its parent's attributes cannot make that step fail.
  discard g.run("mount --bind /var/lib/repro/system /var/lib/repro/system")
  let u1 = g.exec(repro & " system addon uninstall")
  let tokenThere = g.exec("test -f " & R3Token).exitCode == 0
  let ledgerGone = g.exec("test ! -e /var/lib/repro/system/addon-ledger").exitCode == 0
  let mid = r3Stat(g)
  var intact = true
  var why = ""
  for f in R3Files:
    let a = pre.getOrDefault(f).splitWhitespace()
    let b = mid.getOrDefault(f).splitWhitespace()
    if a.len < 4 or b.len < 4 or (a[0] != b[0] and not f.endsWith(".seq")) or
        (a[3] != b[3] and not f.endsWith(".seq")):
      intact = false
      why.add(f & ": " & a.join(" ") & " -> " & b.join(" ") & "\n")
  let midFloors = g.exec("stat -c '%i %w' " & Records & R3Target & ".seq " &
                         Records & "rpi3.seq").stdout
  if midFloors != floorIno:
    intact = false
    why.add("floors' inodes " & floorIno.strip() & " -> " & midFloors.strip() & "\n")
  step("round 3: an uninstall stopped after the ledger copy leaves the " &
       "token and every input intact",
       u1.exitCode != 0 and tokenThere and ledgerGone and intact,
       "exit " & $u1.exitCode & " token " & $tokenThere & " ledger gone " &
       $ledgerGone & "\n" & why & u1.stdout & u1.stderr)
  discard g.run("umount /var/lib/repro/system")
  let u2 = g.exec(repro & " system addon uninstall")
  step("round 3: the re-run finishes", u2.exitCode == 0 and
       g.exec("test ! -e " & R3Token).exitCode == 0, u2.stdout & u2.stderr)
  let post = r3Stat(g)
  var diffs: seq[string]
  for k, v in pre:
    let w = post.getOrDefault(k)
    let a = v.splitWhitespace()
    let b = w.splitWhitespace()
    let isFloor = k.endsWith(R3Target & ".seq")
    if b.len < 3 or (a[0] != b[0] and not isFloor) or a[1] != b[1] or
        a[2] != b[2]:
      diffs.add(k & ": " & v & " -> " & w)
    elif a.len == 4 and not k.endsWith(R3Target & ".seq") and
        (b.len < 4 or a[3] != b[3]):
      diffs.add(k & ": bytes " & v & " -> " & w)
  step("round 3: every input keeps its inode, bytes, prior mode and owner",
       diffs.len == 0, diffs.join("\n"))
  let floors = g.exec("cat " & Records & R3Target & ".seq " & Records &
                      "rpi3.seq; stat -c '%i %w' " & Records & R3Target & ".seq " &
                      Records & "rpi3.seq")
  step("round 3: both floors stay", floors.exitCode == 0 and
       floors.stdout == "8\n41\n" & floorIno,
       "exit " & $floors.exitCode & "\n" & floors.stdout & floors.stderr &
       "\ninodes after the agent's writes: " & floorIno)
  # The comparison with the staged host: the agent's own writes undone in
  # place first (the bump and the second target are not the add-on's).
  discard g.run("printf '7\\n' > /var/lib/repro/agent/state/deploy-agent/" &
    R3Target & ".seq; rm -f /var/lib/repro/agent/state/deploy-agent/rpi3.seq")
  result.after = g.takeFingerprint(repro)
  let same = identityReport(result.before, result.after)
  step("round 3: base fingerprint after uninstall == the staged host",
       same.ok, same.text)

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  ## Run the whole sequence on one base. Returns the failures (empty when
  ## the gate is green for this base).
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha

    let f0 = g.takeFingerprint(repro)
    sleep(20_000)
    let f0b = g.takeFingerprint(repro)
    let det = identityReport(f0, f0b)
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails

    let anchors = g.installAnchors()
    let pre = g.exec(repro & " system addon preflight" & anchors.flags)
    step("preflight is compatible", pre.exitCode == 0, pre.stdout & pre.stderr)
    if pre.exitCode != 0: return fails
    let digest = planDigestOf(pre.stdout)
    let boot = g.exec(repro & " system addon bootstrap --plan " & digest & anchors.flags)
    step("bootstrap", boot.exitCode == 0, boot.stdout & boot.stderr)
    if boot.exitCode != 0: return fails
    let l0 = g.ledgerOf()
    let f1 = g.takeFingerprint(repro)
    let d0 = deltaReport(f0, f1, "", l0)
    step("bootstrap diff == generation 0 ledger", d0.ok, d0.text)

    writeFile(g.runDir / "gen1.profile", Gen1Profile)
    g.copyTo(g.runDir / "gen1.profile", "/root/addon/gen1.profile")
    let a1 = g.exec(repro & " infra apply --profile /root/addon/gen1.profile")
    step("apply generation 1", a1.exitCode == 0, a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails
    let l1 = g.ledgerOf()
    let f2 = g.takeFingerprint(repro)
    let d1 = deltaReport(f1, f2, l0, l1)
    step("generation 1 diff == ledger delta", d1.ok, d1.text)

    writeFile(g.runDir / "gen2.profile", Gen2Profile)
    g.copyTo(g.runDir / "gen2.profile", "/root/addon/gen2.profile")
    let a2 = g.exec(repro & " infra apply --profile /root/addon/gen2.profile")
    step("apply generation 2", a2.exitCode == 0, a2.stdout & a2.stderr)
    if a2.exitCode != 0: return fails
    let l2 = g.ledgerOf()
    let f3 = g.takeFingerprint(repro)
    let d2 = deltaReport(f2, f3, l1, l2)
    step("generation 2 diff == ledger delta", d2.ok, d2.text)

    # A kind the add-on does not manage is refused before anything is
    # written: the fingerprint, the ledger and `current` are unchanged.
    writeFile(g.runDir / "gen3.profile", UnmanagedKindProfile)
    g.copyTo(g.runDir / "gen3.profile", "/root/addon/gen3.profile")
    let cur2 = g.run("cat /var/lib/repro/system/current 2>/dev/null || readlink /var/lib/repro/system/current").strip()
    let a3 = g.exec(repro & " infra apply --profile /root/addon/gen3.profile")
    # (incus exec merges the guest's stderr into stdout; ssh keeps them apart.)
    let a3Out = a3.stdout & a3.stderr
    step("an unmanaged kind is refused", a3.exitCode != 0 and
         "linux.udevRule" in a3Out and "nothing was applied" in a3Out,
         "exit " & $a3.exitCode & "\n" & a3.stdout & a3.stderr)
    let f3b = g.takeFingerprint(repro)
    let unchanged = identityReport(f3, f3b)
    step("the refused apply wrote nothing", unchanged.ok, unchanged.text)
    let cur3 = g.run("cat /var/lib/repro/system/current 2>/dev/null || readlink /var/lib/repro/system/current").strip()
    step("the refused apply committed no generation", cur2 == cur3 and
         g.ledgerOf() == l2, "current " & cur2 & " -> " & cur3)

    # An uninstall that meets drift leaves the object AND the ledger, and
    # fails; once the object is restored a second uninstall completes.
    discard g.run("cp -p /etc/profile.d/repro-addon.sh /root/addon/profile.d.orig && " &
                  "echo '# tampered' >> /etc/profile.d/repro-addon.sh")
    let unDrift = g.exec(repro & " system addon uninstall")
    let ledgerKept = g.exec("test -f /var/lib/repro/system/addon-ledger").exitCode == 0
    let fileKept = g.exec("grep -q tampered /etc/profile.d/repro-addon.sh").exitCode == 0
    step("uninstall with drift fails, keeps the object and the ledger",
         unDrift.exitCode == 1 and ledgerKept and fileKept and
         "repro-addon.sh" in unDrift.stdout,
         unDrift.stdout & unDrift.stderr & "\nledger kept: " & $ledgerKept &
         " file kept: " & $fileKept)
    # The kept ledger describes what is still owned: the objects the first
    # uninstall did undo (the diversion, the units) are no longer in it.
    let kept = g.exec("cat /var/lib/repro/system/addon-ledger").stdout
    step("the kept ledger lists only what is still owned",
         "\ndiversion\t" notin kept and "repro-addon.target" notin kept and
         "repro-addon.sh" in kept, kept)
    discard g.run("cp -p /root/addon/profile.d.orig /etc/profile.d/repro-addon.sh")

    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let f4 = g.takeFingerprint(repro)
    let ident = identityReport(f0, f4)
    step("base fingerprint after uninstall == before bootstrap", ident.ok,
         ident.text)

    # A deferred recipient key (spec §6.5.2, what an image's assembly boot
    # bootstraps with): none at bootstrap, the host's own created by the
    # next re-assert, and still nothing left after uninstall.
    let preD = g.exec(repro & " system addon preflight --defer-recipient-key" &
                      anchors.flags)
    let bootD = g.exec(repro & " system addon bootstrap --defer-recipient-key" &
      " --plan " & planDigestOf(preD.stdout) & anchors.flags)
    let noKey = g.exec("ls -A /var/lib/repro/agent")
    step("a deferred-key bootstrap creates no recipient key",
         bootD.exitCode == 0 and "recipient.key" notin noKey.stdout and
           "deferred" in bootD.stdout,
         bootD.stdout & bootD.stderr & "\nagent dir: " & noKey.stdout)
    let reD = g.exec(repro & " system addon reassert")
    # Round 3 stages this key as a pre-bootstrap one: a key the add-on's own
    # code made is one the preflight accepts.
    discard g.run("cp -p /var/lib/repro/agent/recipient.key /root/addon/r3.key; " &
                  "cp -p /var/lib/repro/agent/recipient.pub /root/addon/r3.pub")
    let keyD = g.exec("stat -c '%a %U' /var/lib/repro/agent/recipient.key; " &
                      "cat /var/lib/repro/agent/recipient.pub")
    step("the next re-assert creates the host's own key, 0400 root",
         reD.exitCode == 0 and "recipient key: created" in reD.stdout and
           keyD.stdout.startsWith("400 root\n"),
         reD.stdout & reD.stderr & "\n" & keyD.stdout & keyD.stderr)
    let unD = g.exec(repro & " system addon uninstall")
    step("uninstall after a deferred key", unD.exitCode == 0,
         unD.stdout & unD.stderr)
    let f5 = g.takeFingerprint(repro)
    let identD = identityReport(f0, f5)
    step("base fingerprint after the deferred-key uninstall == before " &
         "bootstrap", identD.ok, identD.text)
    let (f6, f7) = preBootstrapRound(g, repro, anchors, step)
    for (n, t) in [("f0", f0), ("f1", f1), ("f2", f2), ("f3", f3), ("f4", f4),
                   ("f5", f5), ("f6", f6), ("f7", f7),
                   ("l0", l0), ("l1", l1), ("l2", l2)]:
      writeFile(g.runDir / (n & ".txt"), t)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      let keep = getEnv("REPRO_ADDON_KEEP_ARTIFACTS")
      if keep.len > 0 and dirExists(g.runDir):
        let dest = keep / g.name
        createDir(keep)
        for f in walkFiles(g.runDir / "*.txt"):
          createDir(dest)
          copyFile(f, dest / extractFilename(f))
        if fileExists(g.serialLog):
          createDir(dest)
          copyFile(g.serialLog, dest / "serial.log")
      g.destroy()
  fails

suite "e2e_addon_bootstrap_uninstall_byte_identity":
  test "bootstrap, two generations and uninstall leave the base byte-identical":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_addon_bootstrap_uninstall_byte_identity)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{
          "gate": "e2e_addon_bootstrap_uninstall_byte_identity",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_bootstrap_uninstall_byte_identity",
                                     record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
