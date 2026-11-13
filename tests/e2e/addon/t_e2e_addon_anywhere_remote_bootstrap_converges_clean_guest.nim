## Gate ``e2e_addon_anywhere_remote_bootstrap_converges_clean_guest``
## (milestone A16; ReproOS Add-On Mode §6.5.3, §6.5.4).
##
## Against a stock, unbootstrapped guest of the base matrix, ONE ``repro
## anywhere --mode addon --host <host> root@<guest>`` run from this host
## (the operator's workstation) runs the read-only preflight, carries the
## static ``repro`` and the anchors to the guest's ``/run``, bootstraps with
## the digest the operator acknowledged, applies the profile and plans it
## again. Plan and apply are separate (§6.5.3, approved 2026-11-08 with that
## change; the digest's coverage approved 2026-11-13): the gate first runs
## the command WITHOUT ``--expect-plan`` and checks it prints the reviewable
## plan (the preflight report and the profile text) and one digest over all
## it would apply, exits 3, and leaves nothing persistent: the guest is
## unbootstrapped, its fingerprint unchanged, and the ephemeral probe's
## tmpfs and upload are gone (Anywhere Safety Contract §5's add-on
## exception). Then with a digest that is not the host's, which is refused
## the same way; then with the printed digest but a profile changed after
## the review, which must be refused with nothing applied; then with the
## printed digest and the reviewed profile.
## Afterwards, checked independently from the guest:
##
## - ``repro infra plan`` predicts nothing (no ledger change, no
##   transition), ``repro system addon verify`` is ok, the profile's unit is
##   active and its file is in place;
## - the recipient public key written to ``--recipient-out`` is the one the
##   guest generated (``/var/lib/repro/agent/recipient.pub``), and the
##   private half is ``0400 root`` on the guest only;
## - nothing the command carried is left in ``/run/repro-anywhere``;
## - ``repro system addon uninstall`` then restores the base fingerprint
##   taken before the command, byte for byte (§6.4's exceptions: none
##   apply to this profile, which declares no account).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just
## e2e_addon_anywhere_remote_bootstrap_converges_clean_guest``). Bases:
## ``REPRO_ADDON_BASES`` (the recipe's default: ``debian-13-amd64``). The
## full engine must be built (``just build``): ``repro anywhere`` runs
## here; the static add-on (built by the gate runner) runs on the guest.
##
## *The host key.* The command trusts the exact key in ``--known-hosts``
## and nothing else. The gate reads the guest's ed25519 host key through
## the test bed's own channel to it (gosti's SSH session, which the run
## created) and writes it there for the forwarded loopback port.
##
## *Plan-only writes outside the fingerprint.* The fingerprint covers the
## paths an add-on could own, not ``/root``, ``/var/tmp`` or the rest of
## ``/var/lib``. So the gate also records the guest's clock before the
## plan-only run and lists every path on every disk-backed filesystem that
## changed since, refusing each one outside the disclosed allowlist of
## incidental SSH writes (``plan_only_writes.nim``; Safety Contract §5).
##
## Falsifiers: an ENGINE built with
## ``REPRO_ADDON_MUTATION=anywhere-digest-omits-profile`` (``just build``)
## leaves the profile out of the digest; the changed profile is then
## applied and the gate goes red. One built with
## ``REPRO_ADDON_MUTATION=anywhere-probe-leaves-files`` leaves a file in
## ``/var/tmp``, ``/root`` and ``/var/lib`` during plan-only mode, which
## only the disk-write listing sees: the gate goes red on that step.
##
## *Mocking.* None. A real guest, the real engine, the real add-on.

import std/[json, os, osproc, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_peer_cache/auth as peerAuth

import ./addon_testbed
import ./plan_only_writes

const
  Gate = "e2e_addon_anywhere_remote_bootstrap_converges_clean_guest"
  Host = "tb-anywhere"
  ServiceUnit = "tb-anywhere-hello.service"

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc engine(): string =
  result = reproRoot() / "build" / "bin" / "repro".addFileExt(ExeExt)
  if not fileExists(result):
    raise newException(TestBedError, "no engine at " & result &
      "; build it with `just build`")

const ProfileText = """import repro_profile

profile "tb-anywhere":
  addOn:
    managedEtcPrefixes:
      "/etc/tb-anywhere/"

  resources:
    fsSystemFile(path = "/etc/tb-anywhere/motd",
      content = "bootstrapped by repro anywhere\n", address = "motd")
    systemdSystemUnit(name = "tb-anywhere-hello.service",
      content = "[Unit]\nDescription=A16 anywhere fixture\n\n[Service]\nExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n",
      floorExceptions = @["serviceFloor: a test fixture that runs the base's own sleep"],
      healthCheck = "active", address = "hello")
"""

proc runBase(b: BaseImage; record: JsonNode; work: string): seq[string] =
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
    # The base fingerprint, with the test bed's own copy of the tool.
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let f0 = g.takeFingerprint(repro)
    sleep(20_000)
    let f0b = g.takeFingerprint(repro)
    let det = identityReport(f0, f0b)
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails
    proc unbootstrapped(): tuple[ok: bool; detail: string] =
      # BOTH roots absent: either one present is a bootstrapped host.
      let r = g.exec("for d in /var/lib/repro /etc/repro; do " &
        "if test -e $d; then echo present $d; else echo absent $d; fi; done")
      (r.exitCode == 0 and "absent /var/lib/repro" in r.stdout and
         "absent /etc/repro" in r.stdout and "present" notin r.stdout,
       r.stdout & r.stderr)
    let u0 = unbootstrapped()
    step("the guest is unbootstrapped", u0.ok, u0.detail)

    # The operator's inputs.
    let prof = work / b.name
    createDir(prof)
    writeFile(prof / "system.nim", ProfileText)
    var signers: seq[string]
    for i in 0 ..< 2: signers.add hexKey(peerAuth.generateKeypair().publicKey)
    writeFile(prof / "deploy-signers.anchors", signers.join("\n") & "\n")
    writeFile(prof / "cache-publishers.anchors",
              hexKey(peerAuth.generateKeypair().publicKey) & "\n")
    let hostKey = g.run("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
    when defined(gostiAvailable):
      let port = g.vm.sshPort
    else:
      let port = 0
    writeFile(prof / "known_hosts", "[127.0.0.1]:" & $port & " " &
      hostKey.splitWhitespace()[0 .. 1].join(" ") & "\n")
    let (addonPath, addonSha) = artefact(b.debArch)

    # ONE command, run four times: unacknowledged, wrongly acknowledged,
    # acknowledged with a profile changed after the review, acknowledged.
    proc anywhereCmd(profile: string): string =
      quoteShell(engine()) & " anywhere --mode addon --host " & Host &
      " --profile " & quoteShell(profile) &
      " --addon-binary " & quoteShell(addonPath) & " --addon-sha256 " & addonSha &
      " --known-hosts " & quoteShell(prof / "known_hosts") &
      " --ssh-key " & quoteShell(g.keyPath) & " --ssh-port " & $port &
      " --deploy-signers " & quoteShell(prof / "deploy-signers.anchors") &
      " --cache-publishers " & quoteShell(prof / "cache-publishers.anchors") &
      " --cache-url " & TestCacheUrl &
      " --recipient-out " & quoteShell(prof / "recipient.pub") &
      " --applied-profile-out " & quoteShell(prof / "applied.profile")
    let base = anywhereCmd(prof / "system.nim")
    let target = " root@127.0.0.1"
    proc ephemeralGone(): tuple[ok: bool; detail: string] =
      # The plan-only probe's tmpfs and upload (Anywhere Safety Contract
      # §5, add-on exception approved 2026-11-13): neither the directory
      # nor a mount may remain.
      let r = g.exec("if test -e /run/repro-anywhere; then echo dir-present; " &
        "else echo dir-gone; fi; if findmnt -n /run/repro-anywhere; then " &
        "echo mount-present; else echo mount-gone; fi")
      ("dir-gone" in r.stdout and "mount-gone" in r.stdout, r.stdout)

    # Without an acknowledged plan: the reviewable plan and its digest, and
    # nothing persistent left (the base fingerprint is unchanged).
    # The fingerprint covers only the paths an add-on could own, so the
    # guest's clock is recorded first and every disk-backed filesystem is
    # listed for what changed since (plan_only_writes.nim).
    # systemd-timesyncd stamps /var/lib/systemd/timesync/clock on its own
    # schedule and when it stops, whatever the run does: it is not an SSH
    # write and not a log, so it is stopped (its stop-time write included)
    # before the clock is taken instead of being allowlisted.
    discard g.exec("systemctl stop systemd-timesyncd.service 2>/dev/null; true")
    let t0 = g.run("date +%s.%N").strip()
    let (planOut, planRc) = execCmdEx(base & target)
    record["planOnlyOutput"] = %planOut
    var digest = ""
    for line in planOut.splitLines():
      if line.strip().startsWith("anywhere plan digest:"):
        digest = line.split(':', 1)[1].strip()
    let u1 = unbootstrapped()
    let carried0 = ephemeralGone()
    let written = g.exec("bash -c " & quoteShell(listWritesScript(t0)))
    let unexplained = unexplainedWrites(written.stdout)
    # Back to the base's own state before the fingerprint, which lists
    # active units.
    discard g.exec("systemctl start systemd-timesyncd.service 2>/dev/null; true")
    let fPlan = g.takeFingerprint(repro)
    let dPlan = identityReport(f0, fPlan)
    step("plan-only wrote no file on a disk-backed filesystem beyond the " &
         "disclosed SSH writes", written.exitCode == 0 and unexplained.len == 0,
         "exit " & $written.exitCode & "\n" & written.stderr &
           "\nunexplained writes:\n" & unexplained.join("\n") &
           "\ndisk-backed mounts:\n" & g.exec("findmnt -rn -o TARGET,SOURCE,FSTYPE").stdout)
    step("without --expect-plan it prints the plan and leaves nothing",
         planRc == 3 and digest.len == 64 and
           "nothing was applied" in planOut and
           "/etc/tb-anywhere/motd" in planOut and
           "tb-anywhere-hello.service" in planOut and
           "== the host's preflight" in planOut and u1.ok and
           carried0.ok and dPlan.ok,
         "exit " & $planRc & "\n" & planOut & "\n" & u1.detail &
           "\ncarried: " & carried0.detail & "\n" & dPlan.text)
    if digest.len == 0: return fails

    # The profile changed after the review, run with the reviewed digest:
    # refused before anything is written (the verifier's 2026-11-13
    # experiment applied /etc/tb-anywhere/injected under the old digest).
    createDir(prof / "swapped")
    writeFile(prof / "swapped" / "system.nim", ProfileText.replace(
      "  resources:\n",
      "  resources:\n    fsSystemFile(path = \"/etc/tb-anywhere/injected\",\n" &
      "      content = \"not in the acknowledged plan\\n\", address = \"injected\")\n"))
    let (swapOut, swapRc) = execCmdEx(anywhereCmd(prof / "swapped" / "system.nim") &
                                      " --expect-plan " & digest & target)
    record["swappedProfileOutput"] = %swapOut
    let uS = unbootstrapped()
    let injected = g.exec("test -e /etc/tb-anywhere/injected && echo present || echo absent")
    let fSwap = g.takeFingerprint(repro)
    let dSwap = identityReport(f0, fSwap)
    step("a profile changed after the acknowledgement is refused, nothing applied",
         swapRc != 0 and "nothing was written" in swapOut and uS.ok and
           injected.stdout.strip() == "absent" and dSwap.ok and
           ephemeralGone().ok,
         "exit " & $swapRc & "\n" & swapOut & "\n" & uS.detail &
           "\ninjected: " & injected.stdout & "\n" & dSwap.text)
    if swapRc == 0: return fails

    # A digest that is not this host's plan: refused, nothing written.
    let wrong = (if digest[0] == '0': "1" else: "0") & digest[1 .. ^1]
    let (wrongOut, wrongRc) = execCmdEx(base & " --expect-plan " & wrong & target)
    let u2 = unbootstrapped()
    step("a digest that is not the host's plan is refused",
         wrongRc != 0 and "nothing was written" in wrongOut and u2.ok,
         "exit " & $wrongRc & "\n" & wrongOut & "\n" & u2.detail)

    let cmd = base & " --expect-plan " & digest & target
    record["command"] = %cmd
    let started = epochTime()
    let (out1, rc) = execCmdEx(cmd)
    record["seconds"] = %int(epochTime() - started)
    record["output"] = %out1
    step("one repro anywhere --mode addon converges the guest", rc == 0 and
         "ledger diff: no change" in out1 and "service transitions: none" in out1,
         out1)
    if rc != 0: return fails

    # Independently, from the guest.
    let reproExe = block:
      var p = ""
      for line in out1.splitLines():
        if line.strip().startsWith("repro      :"):
          p = line.split(':', 1)[1].strip()
      p
    step("the command reported the store copy of repro", reproExe.startsWith(
         "/repro/store/"), reproExe)
    g.copyTo(prof / "applied.profile", "/root/addon/applied.profile")
    let plan = g.exec(reproExe & " infra plan --profile /root/addon/applied.profile")
    record["plan"] = %(plan.stdout & plan.stderr)
    step("repro infra plan on the guest predicts nothing", plan.exitCode == 0 and
         "ledger diff: no change" in plan.stdout and
         "service transitions: none" in plan.stdout, plan.stdout & plan.stderr)
    let v = g.exec(reproExe & " system addon verify")
    step("verify is ok", v.exitCode == 0 and "verify: ok" in v.stdout,
         v.stdout & v.stderr)
    let act = g.exec("systemctl is-active " & ServiceUnit &
                     " repro-addon.target && cat /etc/tb-anywhere/motd")
    step("the profile's unit is active and its file in place",
         act.exitCode == 0 and "bootstrapped by repro anywhere" in act.stdout,
         act.stdout & act.stderr)
    let pub = g.exec("cat /var/lib/repro/agent/recipient.pub; " &
                     "stat -c '%a %U' /var/lib/repro/agent/recipient.key")
    let registered = (if fileExists(prof / "recipient.pub"):
                        readFile(prof / "recipient.pub").strip() else: "")
    step("the registered recipient key is the one generated on the guest",
         registered.len == 130 and registered in pub.stdout and
         "400 root" in pub.stdout, registered & "\n" & pub.stdout)
    let carried = g.exec("test -e /run/repro-anywhere && echo present || echo gone")
    step("nothing the command carried is left in /run", carried.stdout.strip() ==
         "gone", carried.stdout)

    # Uninstall restores the base.
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let f1 = g.takeFingerprint(repro)
    let ident = identityReport(f0, f1)
    step("base fingerprint after uninstall == before repro anywhere",
         ident.ok, ident.text)
    writeFile(g.runDir / "f0.txt", f0)
    writeFile(g.runDir / "f1.txt", f1)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite Gate:
  test "one repro anywhere converges a stock guest; uninstall restores it":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      let work = getTempDir() / ("repro-a16-anywhere-" & $getCurrentProcessId())
      createDir(work)
      defer: removeDir(work)
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": "qemu", "mutation": mutation(), "reprobuild": gitHead(),
          "gosti": gostiHead(), "started": $now().utc}
        let f = runBase(b, record, work)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
