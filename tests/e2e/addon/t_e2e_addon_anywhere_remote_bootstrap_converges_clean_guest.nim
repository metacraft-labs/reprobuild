## Gate ``e2e_addon_anywhere_remote_bootstrap_converges_clean_guest``
## (milestone A16; ReproOS Add-On Mode §6.5.3, §6.5.4).
##
## Against a stock, unbootstrapped guest of the base matrix, ONE ``repro
## anywhere --mode addon --host <host> root@<guest>`` run from this host
## (the operator's workstation) runs the read-only preflight, carries the
## static ``repro`` and the anchors to the guest's ``/run``, bootstraps with
## the digest the preflight printed, applies the profile and plans it again.
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
## *Mocking.* None. A real guest, the real engine, the real add-on.

import std/[json, os, osproc, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_peer_cache/auth as peerAuth

import ./addon_testbed

const
  Gate = "e2e_addon_anywhere_remote_bootstrap_converges_clean_guest"
  Host = "tb-anywhere"
  ServiceUnit = "tb-anywhere-hello.service"

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc engine(): string =
  result = reproRoot() / "build" / "bin" / "repro"
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
    let gen = g.exec("ls /var/lib/repro 2>&1; ls /etc/repro 2>&1")
    step("the guest is unbootstrapped", "No such file" in gen.stdout,
         gen.stdout)

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

    # ONE command.
    let cmd = quoteShell(engine()) & " anywhere --mode addon --host " & Host &
      " --profile " & quoteShell(prof / "system.nim") &
      " --addon-binary " & quoteShell(addonPath) & " --addon-sha256 " & addonSha &
      " --known-hosts " & quoteShell(prof / "known_hosts") &
      " --ssh-key " & quoteShell(g.keyPath) & " --ssh-port " & $port &
      " --deploy-signers " & quoteShell(prof / "deploy-signers.anchors") &
      " --cache-publishers " & quoteShell(prof / "cache-publishers.anchors") &
      " --cache-url " & TestCacheUrl &
      " --recipient-out " & quoteShell(prof / "recipient.pub") &
      " --applied-profile-out " & quoteShell(prof / "applied.profile") &
      " root@127.0.0.1"
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
