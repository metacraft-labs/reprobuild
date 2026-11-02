## Gate ``e2e_addon_to_reproos_conversion_keeps_state`` (milestone A13;
## ReproOS Add-On Mode §11.1, §13 decisions 32 and 41).
##
## The conversion of an add-on host, rehearsed by reinstall (decision 41):
## ReproOS Anywhere installs only its fixture payload until it is qualified,
## so the gate converts the way Anywhere would have the host end up -- a
## fresh install of the same stock base on a new root disk, the activities
## realised in full by the engine (decision 32), the state carried over --
## without exercising Anywhere's own protocol.
##
## The fixture host runs the reference activities (``reference_services``:
## ``vaultwarden`` and ``ethereum_validator``, the converged forms of the
## services A13 adopts) on an add-on guest, driven by the deploy agent,
## with the state set the fixture profile declares:
##
## - ``keep:/var/lib/vaultwarden``: a second disk, mounted there by the
##   operator's own ``/etc/fstab`` line; the conversion keeps the disk;
## - ``carry:`` the execution client's, the beacon node's and the
##   validator's directories (the validator's holds its slashing-protection
##   database and its wallet).
##
## The rehearsal:
##
## 1. On the add-on guest, once the chain has justified epochs, the
##    operator stops the set's units and runs ``repro system addon state
##    backup``. Every unit of the set is then held: an operator's ``systemctl
##    start`` of the validator fails. ``state verify`` against the manifest
##    passes immediately before the "conversion" (the guest is powered off;
##    its root disk is discarded).
## 2. A new guest boots a fresh overlay of the same stock image with the
##    kept disk attached, mounts it as the old host did, gets the engine
##    and the carried directory (``/var/lib/repro/system/carried``), and is
##    re-identified as ReproOS for the engine's commands only (decision
##    32). An apply before the restore is refused with
##    ``ECarriedStatePending`` and writes no unit (the validator cannot
##    start on an empty directory).
## 3. The first-boot unit (``repro system state unit``) is installed and
##    the guest rebooted: the unit restores the carried directories before
##    ``sysinit.target``, and ``state verify`` finds every directory --
##    carried and kept -- at the manifest's digest.
## 4. The full apply realises the activities; every unit passes its health
##    check, and the beacon chain continues past the head the add-on host
##    had reached.
## 5. The validator never ran between backup and restore: on the add-on
##    guest no validator start after the backup; on the new guest its first
##    start is after the restore unit finished (the same boot's monotonic
##    clock). Its slashing-protection history, exported as EIP-3076,
##    starts at the epochs it signed on the add-on host, continues past the
##    conversion, and records no conflicting signature.
##
## Falsifying mutations:
## - add-on build ``state-units-not-held`` (the backup holds nothing): the
##   operator's start of the validator after the backup succeeds; red;
## - engine build ``apply-ignores-carried-state``: the apply before the
##   restore goes ahead; red;
## - ``REPRO_A13_MUTATION=carried-archive-tampered`` (gate-level: one byte
##   of the validator's archive is changed in transit): the restore unit
##   refuses it, the carried state stays pending and the apply is refused;
##   red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``, ``REPRO_ADDON_ENGINE_CLOSURE`` (the
## full engine built from this tree) and ``REPRO_A12_PACKAGES``. Bases:
## ``REPRO_ADDON_BASES`` (amd64).
##
## *Mocking.* None: real images, real disks, real packages, a real chain,
## the real agent and engine. What is not real is said above: the
## conversion is a reinstall, and ReproOS is the engine's full realisation
## on a re-identified guest.

import std/[json, os, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/generation0
import repro_peer_cache/auth as peerAuth

import ./addon_testbed
import ./agent_e2e_support
import ./cache_e2e_support
import ./reference_services
import ./validator_safety

const
  Gate = "e2e_addon_to_reproos_conversion_keeps_state"
  ReidentifiedOsRelease = "/etc/repro-testbed/os-release-reproos"
  ReidentifyPrefix = "unshare --mount -- sh -c 'mount --bind " &
    ReidentifiedOsRelease & " /etc/os-release && exec \"$@\"' sh "
    ## As the parity gate (decision 32): the engine is shown a ReproOS base
    ## in its own mount namespace only.
  RefDir = "/root/reference-services"
  KeepDir = "/var/lib/vaultwarden"
  KeepFstab = "LABEL=repro-keep " & KeepDir & " ext4 defaults,nofail 0 2"
  CarriedDir = "/var/lib/repro/system/carried"
  SetUnits = ["vaultwarden.service", "eth-execution.service",
              "eth-beacon.service", DefaultValidatorUnit]
  RestoreUnit = "repro-state-restore.service"

proc gateMutation(): string = getEnv("REPRO_A13_MUTATION")

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc enginePath(engine: string): string = engine / "bin" / "reprobuild"

proc mountKeep(g: Guest; format: bool) =
  ## The operator's disk layout: the second disk, labelled, mounted where
  ## vaultwarden keeps its data, by an fstab line.
  if format:
    discard g.run("mkfs.ext4 -q -L repro-keep /dev/vdb")
  discard g.run("mkdir -p " & KeepDir & " && grep -q repro-keep /etc/fstab || " &
    "echo '" & KeepFstab & "' >> /etc/fstab; systemctl daemon-reload; " &
    "mount " & KeepDir)

proc monotonicOf(g: Guest; unit, prop: string): int64 =
  try: parseBiggestInt(g.run("systemctl show -P " & prop & " " & unit).strip())
  except ValueError: -1

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var old, nw: Guest
  var dd: DataDisk
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    let engine = engineFromEnv()
    record["engine"] = %engine
    let eng = enginePath(engine)
    dd = newDataDisk(4)
    # ------------------------------------------------------------------
    # The add-on host.
    old = newGuest(b, diskGiB = 16, cpus = 4, memoryMB = 6144)
    old.dataDisks = @[dd.path]
    old.boot()
    old.prepareBase()
    old.mountKeep(format = true)
    let (repro, sha) = old.installArtefact()
    record["artefactSha256"] = %sha
    let work = old.runDir.parentDir / (old.name & "-a13")
    createDir(work)
    defer: removeDir(work)
    let pk = refPackages(work)
    record["packages"] = packageSha256s(pk)
    let cache = old.startCache()
    defer: cache.stop()
    let kp = peerAuth.generateKeypair()
    let bs = old.bootstrapWithAgent(repro, step, cacheUrl = cache.guestUrl,
      cachePublishers = @[hexKey(kp.publicKey)])
    if not bs.ok: return fails
    defer: bs.producer.stop()
    let net = makeTestnet(pk, work)
    record["genesisTime"] = %net.genesisTime
    let pins = basePins(pk, net)
    let addC = compileReference(engine, pins, "addOn", ReferenceActivities)
    let digests = publishAll(cache, kp, pk, net, pins, addC.actions)
    let jwt = jwtHex()
    let adminToken = "a13-admin-" & jwtHex()[0 ..< 24]
    putReferenceSecrets(old, repro & " system addon secret put", jwt,
                        adminToken, [DefaultValidatorUnit], step)
    provisionWallet(old, net)
    discard bs.producer.publish(PublishSpec(sequence: 1,
      profileText: addC.canonical, buildActions: addC.actions,
      closureDigests: digests))
    let t1 = old.tickUnits()
    step("the add-on host applies the reference activities",
         t1.outcome == "aoApplied", $t1 & "\n" & t1.fetchLog & t1.applyLog &
         "\n" & old.serviceJournal(SetUnits))
    if fails.len > 0: return fails
    let guestNow = parseInt(old.run("date +%s").strip())
    let startEpoch = max(guestNow - net.genesisTime, 0) div 12
    step("the chain justifies on the add-on host",
         old.waitJustified(startEpoch + 2, 900),
         "justified " & $old.justifiedEpoch() & ", started " & $startEpoch)
    let oldHead = old.headSlot()
    let oldEpoch = oldHead div 6
    record["addOnHead"] = %oldHead
    step("vaultwarden is healthy on the add-on host, on the kept disk",
         old.exec(repro & " system addon probe http://127.0.0.1:8000/alive").exitCode == 0 and
         old.exec("findmnt -n -o SOURCE " & KeepDir).stdout.strip().len > 0 and
         old.exec("test -f " & KeepDir & "/db.sqlite3").exitCode == 0, "")

    # --- 1. Backup and hold.
    writeFile(work / "ref.profile", addC.canonical)
    old.copyTo(work / "ref.profile", "/root/ref.profile")
    discard old.run("systemctl stop " & SetUnits.join(" "))
    let backupAt = old.run("date +%s.%N").strip()
    let bk = old.exec(repro & " system addon state backup --profile " &
      "/root/ref.profile --out /root/carry")
    step("the state set is backed up", bk.exitCode == 0, bk.stdout & bk.stderr)
    record["backup"] = %bk.stdout
    let tryStart = old.exec("systemctl start " & DefaultValidatorUnit)
    discard old.exec("sleep 5")
    let started = old.exec("journalctl -u " & DefaultValidatorUnit &
      " -o short-unix --no-pager --since @" & backupAt.split('.')[0] &
      " | grep -c 'Started' || true").stdout.strip()
    step("after the backup the validator is held: a start fails and none ran",
         tryStart.exitCode != 0 and started == "0" and
         old.exec("systemctl is-active " & DefaultValidatorUnit).stdout.strip() != "active",
         "start exit " & $tryStart.exitCode & ", starts since backup " & started &
         "\n" & tryStart.stderr)
    let ver = old.exec(repro & " system addon state verify --from /root/carry")
    step("immediately before the conversion the source matches the manifest",
         ver.exitCode == 0, ver.stdout & ver.stderr)
    old.copyFrom("/root/carry", work / "carry")
    let manifest = parseJson(readFile(work / "carry" / "state-set.json"))
    record["manifest"] = manifest
    if gateMutation() == "carried-archive-tampered":
      for e in manifest["entries"]:
        if e["path"].getStr() == "/var/lib/ethereum/validator":
          let a = work / "carry" / e["archive"].getStr()
          var bytes = readFile(a)
          bytes[bytes.len div 2] = char((ord(bytes[bytes.len div 2]) + 1) mod 256)
          writeFile(a, bytes)
    # The "conversion": the add-on host's root disk is gone.
    old.shutdown()
    old.destroy()
    old = nil
    if fails.len > 0: return fails

    # ------------------------------------------------------------------
    # --- 2. The reinstalled host.
    nw = newGuest(b, diskGiB = 16, cpus = 4, memoryMB = 6144)
    nw.dataDisks = @[dd.path]
    nw.boot()
    nw.prepareBase()
    nw.mountKeep(format = false)
    nw.installEngineClosure(engine)
    discard nw.run("mkdir -p /etc/repro /etc/repro-testbed " & CarriedDir &
      " " & RefDir & " && printf 'ID=reproos\\nNAME=\"ReproOS (re-identified " &
      "by the test bed)\"\\nVERSION_ID=test\\nREPRO_TESTBED_REIDENTIFIED=1\\n' > " &
      ReidentifiedOsRelease)
    writeFile(work / "caches.conf", renderCachesConf(cache.guestUrl,
                                                     @[hexKey(kp.publicKey)]))
    nw.copyTo(work / "caches.conf", "/etc/repro/caches.conf")
    for f in walkDir(work / "carry"):
      nw.copyTo(f.path, CarriedDir / f.path.extractFilename)
    discard nw.run("chmod -R go-rwx " & CarriedDir)
    writeFile(work / "system.nim", readFile(ProfileSource))
    writeFile(work / PinsModule, pinsSource(pins))
    writeFile(work / "home.nim", readFile(FixtureDir / "home.nim"))
    for f in ["system.nim", PinsModule, "home.nim"]:
      nw.copyTo(work / f, RefDir / f)
    let env = ReidentifyPrefix
    putReferenceSecrets(nw, env & eng & " system secret put", jwt, adminToken,
                        [DefaultValidatorUnit], step)
    let applyCmd = env & eng & " infra apply --profile " & RefDir &
      "/system.nim --host " & AgentTarget & " --no-preview"
    let early = nw.exec(applyCmd, timeoutSec = 3600)
    step("an apply before the restore is refused (ECarriedStatePending)",
         early.exitCode != 0 and "ECarriedStatePending" in
           early.stdout & early.stderr,
         early.stdout & early.stderr)
    step("... and wrote no unit",
         nw.exec("test -e /etc/systemd/system/" & DefaultValidatorUnit).exitCode != 0 and
         nw.exec("systemctl is-active " & DefaultValidatorUnit).stdout.strip() != "active",
         "")

    # --- 3. The first-boot unit restores before anything starts.
    let unitText = nw.exec(eng & " system state unit")
    writeFile(work / RestoreUnit, unitText.stdout)
    nw.copyTo(work / RestoreUnit, "/etc/systemd/system/" & RestoreUnit)
    discard nw.run("systemctl daemon-reload && systemctl enable " & RestoreUnit)
    nw.rebootGuest()
    let res = nw.run("systemctl show -p Result -p ActiveState " & RestoreUnit)
    step("the first-boot unit restored the carried state",
         "Result=success" in res and "ActiveState=active" in res,
         res & "\n" & nw.serviceJournal([RestoreUnit]))
    let ver2 = nw.exec(eng & " system state verify --from " & CarriedDir)
    step("every carried and kept directory is at the manifest's digest",
         ver2.exitCode == 0 and "DIFFERS" notin ver2.stdout and
         ver2.stdout.count("ok ") == 4, ver2.stdout & ver2.stderr)
    let restoredDone = nw.monotonicOf(RestoreUnit, "ExecMainExitTimestampMonotonic")

    # --- 4. The full realisation.
    let applied = nw.exec(applyCmd, timeoutSec = 3600)
    step("the reinstalled host realises the activities in full",
         applied.exitCode == 0, applied.stdout & applied.stderr & "\n" &
         nw.serviceJournal(SetUnits))
    for (u, check) in [("vaultwarden.service", "http://127.0.0.1:8000/alive"),
                       ("eth-execution.service", "tcp:127.0.0.1:8545"),
                       ("eth-beacon.service",
                        "http://127.0.0.1:3500/eth/v1/node/version"),
                       (DefaultValidatorUnit, "http://127.0.0.1:8081/healthz")]:
      var ok = false
      for i in 0 ..< 60:
        if nw.exec(eng & " system addon probe " & check).exitCode == 0:
          ok = true
          break
        discard nw.exec("sleep 2")
      step(u & " passes its health check after the conversion", ok,
           nw.serviceJournal([u]))
    step("the chain continues past the add-on host's head",
         nw.waitHeadSlot(oldHead + 12, 900),
         "head " & $nw.headSlot() & ", add-on host had " & $oldHead)

    # --- 5. The validator never ran between backup and restore, and never
    # signed a conflicting message.
    let firstStart = nw.monotonicOf(DefaultValidatorUnit,
                                    "ExecMainStartTimestampMonotonic")
    let starts = nw.exec("journalctl -b -u " & DefaultValidatorUnit &
      " --no-pager | grep -c 'Started' || true").stdout.strip()
    step("on the new host the validator first started after the restore",
         restoredDone > 0 and firstStart > restoredDone and starts == "1",
         "restore done " & $restoredDone & ", validator start " & $firstStart &
         ", starts this boot " & starts)
    step("the validator signs on the new host",
         nw.waitJustified(oldEpoch + 3, 900),
         "justified " & $nw.justifiedEpoch() & ", add-on host epoch " & $oldEpoch)
    discard nw.run("systemctl stop " & DefaultValidatorUnit)
    let hist = block:
      let r = nw.exec("rm -rf /root/hist && mkdir -p /root/hist && chown " &
        "eth-validator: /root/hist && runuser -u eth-validator -- " &
        pins.validatorPrefix & "/bin/validator slashing-protection-history " &
        "export --accept-terms-of-use --datadir " & pins.validatorStateDir &
        " --slashing-protection-export-dir /root/hist >/root/hist.log 2>&1 " &
        "&& cat /root/hist/*.json")
      if r.exitCode != 0: newJObject() else: parseJson(r.stdout)
    let cs = conflicts([hist])
    let earliest = earliestTarget([hist])
    var latest = 0
    for rec in hist{"data"}.getElems():
      for a in rec{"signed_attestations"}.getElems():
        latest = max(latest, parseInt(a{"target_epoch"}.getStr("0")))
    var carriedHistory = earliest.len > 0
    for k, ep in earliest:
      if ep > oldEpoch: carriedHistory = false
    step("the slashing-protection history was carried and continues: it " &
         "begins on the add-on host, reaches past the conversion and holds " &
         "no conflicting signature",
         cs.len == 0 and carriedHistory and latest > oldEpoch and
         attestationCount([hist]) > 0,
         "conflicts " & $cs.len & ", earliest " & $earliest & ", latest " &
         $latest & ", add-on epoch " & $oldEpoch)
    record["history"] = %*{"keys": earliest.len, "latestTarget": latest,
                           "addOnEpoch": oldEpoch, "conflicts": cs.len}
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    var logs: seq[string]
    for g in [old, nw]:
      if g != nil:
        logs.add(g.log)
        g.destroy()
    record["log"] = %logs
    try: dd.release()
    except CatchableError: discard
  fails

suite Gate:
  test "a converted add-on host keeps and carries its state and never " &
       "runs the validator before the restore":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1, " &
           "REPRO_ADDON_ENGINE_CLOSURE and REPRO_A12_PACKAGES")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": "qemu", "mutation": mutation(),
          "gateMutation": gateMutation(), "reprobuild": gitHead(),
          "gosti": gostiHead(), "started": $now().utc,
          "conversion": "rehearsed by reinstall (decision 41); ReproOS " &
            "Anywhere's protocol not exercised"}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
