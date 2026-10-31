## Gate ``e2e_addon_validator_never_double_signs`` (milestone A12; ReproOS
## Add-On Mode §7.3, decision 24; threat model G26).
##
## The ``ethereum_validator`` reference activity runs on an add-on guest,
## driven by the deploy agent: a local test network (one execution client,
## one beacon node, one validator client holding the eight genesis
## validators' keys; ``reference_services``). While the chain runs, the
## validator client is taken through every way its process is replaced:
##
## 1. **restart** -- ``systemctl restart`` of the unit;
## 2. **re-configuration** -- its configuration file changes, so the switch
##    restarts it (a stop-start, it is ``exclusive``);
## 3. **re-closure** -- it runs from a new store prefix;
## 4. **rename** -- the unit is removed under one name and added under
##    another;
## 5. **rollback** -- ``repro system rollback`` to the generation before the
##    rename.
##
## A monitor in the guest (``validator_safety.MonitorScript``) records every
## validator process's lifetime and the slashing-protection database each
## one held open. Green when:
##
## - **no two lifetimes overlap** (an instance that started inside the
##   polling window counts as overlapping), and there were at least six
##   instances (one per step, the vacuity guard);
## - **every instance held the same database**, the declared state
##   directory's ``validator.db`` (one device and inode);
## - the database's history, exported at the end as an EIP-3076
##   interchange, records **no conflicting signature**, begins at the first
##   epochs for every key (no step started it over) and holds attestations
##   from the whole run;
## - the beacon chain justifies epochs (the validators really signed) and
##   marks no validator slashed.
##
## Then G26's residuals, which the switch cannot see (threat model C40):
##
## - **a validator process outside the unit's control group** (started in a
##   scope of its own, as a stray or a left-behind process would be) holding
##   the database: an instance the unit starts beside it -- an activation
##   after the switch's last check -- cannot open the database
##   ("cannot obtain database lock") and signs nothing;
## - **a second host** (a second instance with a copy of the keys and an
##   empty database, outside the unit): the activity enables the
##   validator's doppelganger check, and the instance finds the keys live
##   and exits without signing anything;
##
## and the **positive control** of the conflict check on real data: a
## second instance with an empty database and *without* the doppelganger
## check, run beside the unit, double-signs for real, and the check finds
## the conflicts in the two databases' records.
##
## Falsifying mutations (each in its own run):
##
## - ``REPRO_ADDON_MUTATION=exclusive-as-plain-restart`` (a build of the
##   add-on whose switch starts an exclusive unit's successor before the
##   old instance is stopped): steps 2-4 overlap: red.
## - ``REPRO_A12_MUTATION=validator-state-follows-unit-name`` (the profile
##   puts the validator's database in a directory named after its unit):
##   the renamed instance holds a different database: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``, ``REPRO_ADDON_ENGINE_CLOSURE`` (the
## producer's compiler) and ``REPRO_A12_PACKAGES``.
##
## *Mocking.* None: real images, real packages, a real chain, the real agent.

import std/[json, os, sets, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip
import repro_peer_cache/auth as peerAuth

import ./addon_testbed
import ./agent_e2e_support
import ./cache_e2e_support
import ./reference_services
import ./validator_safety

const
  Gate = "e2e_addon_validator_never_double_signs"
  Activities = ["ethereum_validator"]
  RenamedUnit = "eth-validator-b.service"
  LifetimeLog = "/root/validator-lifetimes.log"
  StateDir = "/var/lib/ethereum/validator"

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc gateMutation(): string = getEnv("REPRO_A12_MUTATION")

proc validatorCmd(prysm, extra: string): string =
  ## A validator client outside every unit, as the validator's account.
  prysm & "/bin/validator --config-file=/etc/ethereum/validator.yaml " &
    "--chain-config-file=" & extra

proc waitSigning(g: Guest; epochs: int) =
  ## Let the validators sign for ``epochs`` more epochs (six two-second
  ## slots each) past the current head.
  let start = g.headSlot()
  discard g.waitHeadSlot(max(start, 0) + 6 * epochs, 60 + 12 * epochs * 3)

proc exportHistory(g: Guest; prysm, datadir, outDir: string): JsonNode =
  ## The EIP-3076 interchange of the database in ``datadir`` (the client
  ## using it must be stopped: the database is locked while it runs).
  let r = g.exec("rm -rf " & outDir & " && mkdir -p " & outDir & " && " &
    "chown eth-validator: " & outDir & " && runuser -u eth-validator -- " &
    prysm & "/bin/validator slashing-protection-history export " &
    "--accept-terms-of-use --datadir " & datadir &
    " --slashing-protection-export-dir " & outDir & " >/dev/null 2>&1 " &
    "&& cat " & outDir & "/*.json")
  if r.exitCode != 0:
    raise newException(TestBedError, "export of " & datadir & " failed: " &
      r.stdout & r.stderr)
  parseJson(r.stdout)

proc publishPins(p: Producer; cache: CacheServer; kp: PeerKeypair;
                 engine: string; pk: RefPackages; net: Testnet; pins: RefPins;
                 sequence: uint64): ExecOut =
  let c = compileReference(engine, pins, "addOn", Activities)
  let digests = publishAll(cache, kp, pk, net, pins, c.actions)
  discard p.publish(PublishSpec(sequence: sequence, profileText: c.canonical,
    buildActions: c.actions, closureDigests: digests))

proc body(g: Guest; repro, engine: string; step: StepFn; record: JsonNode) =
  let work = g.runDir / "a12"
  createDir(work)
  let pk = refPackages(work)
  record["packages"] = packageSha256s(pk)
  let cache = g.startCache()
  defer: cache.stop()
  let kp = peerAuth.generateKeypair()
  let bs = g.bootstrapWithAgent(repro, step, cacheUrl = cache.guestUrl,
    cachePublishers = @[hexKey(kp.publicKey)])
  if not bs.ok: return
  defer: bs.producer.stop()
  let net = makeTestnet(pk, work)
  record["genesisTime"] = %net.genesisTime
  var pins = basePins(pk, net)
  if gateMutation() == "validator-state-follows-unit-name":
    pins.validatorStateDir = "/var/lib/ethereum/" &
      pins.validatorUnit.replace(".service", "")
  putReferenceSecrets(g, repro & " system addon secret put", jwtHex(),
                      [DefaultValidatorUnit, RenamedUnit], step)
  provisionWallet(g, net)
  writeFile(work / "monitor.py", MonitorScript)
  g.copyTo(work / "monitor.py", "/root/validator-monitor.py")
  discard g.run("setsid nohup python3 /root/validator-monitor.py " &
    LifetimeLog & " >/dev/null 2>&1 < /dev/null &")
  var sequence = 1'u64
  proc apply(what: string): bool =
    discard publishPins(bs.producer, cache, kp, engine, pk, net, pins, sequence)
    let t = g.tickUnits()
    result = t.outcome == "aoApplied"
    step(what & ": applied", result, $t & "\n" & t.fetchLog & t.applyLog &
         (if result: "" else: "\n" & g.serviceJournal(["eth-execution.service",
            "eth-beacon.service", pins.validatorUnit])))
    inc sequence
  # 0. The activity comes up and the chain justifies.
  if not apply("the validator activity"): return
  # The epoch the validators began signing in: the chain starts when the
  # activity does, whatever the genesis time (empty slots before it).
  let guestNow = parseInt(g.run("date +%s").strip())
  let startEpoch = max(guestNow - net.genesisTime, 0) div 12
  record["startEpoch"] = %startEpoch
  step("the chain justifies an epoch",
       g.waitJustified(startEpoch + 2, 900),
       "justified " & $g.justifiedEpoch() & ", started at " & $startEpoch)
  # 1. restart
  discard g.run("systemctl restart " & pins.validatorUnit)
  g.waitSigning(2)
  # 2. re-configuration
  pins.validatorExtraConfig = "graffiti: \"a12-reconfigured\"\n"
  if not apply("re-configuration"): return
  g.waitSigning(2)
  # 3. re-closure
  pins.validatorPrefix = prefixPath("prysm-validator", "7.3.1-b",
                                    pins.validatorDigest)
  if not apply("re-closure"): return
  g.waitSigning(2)
  # 4a. A rename that keeps the unit's resource address is refused: the
  # ledger knows objects by address, so it would leave the old unit (and
  # its instance) in place beside the new one.
  let kept = pins
  pins.validatorUnit = RenamedUnit
  pins.validatorUnitAddress = "systemd.systemUnit:" & DefaultValidatorUnit
  block:
    var fixedAddress = kept
    fixedAddress.validatorUnitAddress = pins.validatorUnitAddress
    discard publishPins(bs.producer, cache, kp, engine, pk, net, fixedAddress,
                        sequence)
    inc sequence
    discard g.tickUnits()
    discard publishPins(bs.producer, cache, kp, engine, pk, net, pins, sequence)
    let t = g.tickUnits()
    inc sequence
    step("a rename that keeps its address is refused, nothing changed",
         t.outcome != "aoApplied" and "address" in t.message and
         g.exec("systemctl is-active " & DefaultValidatorUnit).exitCode == 0 and
         g.exec("test -e /etc/systemd/system/" & RenamedUnit).exitCode != 0,
         $t)
  pins.validatorUnitAddress = ""
  # 4. rename
  pins.validatorUnit = RenamedUnit
  if gateMutation() == "validator-state-follows-unit-name":
    pins.validatorStateDir = "/var/lib/ethereum/" &
      pins.validatorUnit.replace(".service", "")
  if not apply("rename"): return
  step("the old unit is stopped and disabled after the rename",
       g.exec("systemctl is-active " & DefaultValidatorUnit).exitCode != 0 and
       g.exec("systemctl is-enabled " & DefaultValidatorUnit).exitCode != 0, "")
  g.waitSigning(2)
  # 5. rollback
  let rb = g.exec(repro & " system rollback", timeoutSec = 1800)
  step("rollback to the generation before the rename", rb.exitCode == 0,
       rb.stdout & rb.stderr)
  step("after the rollback the validator runs under its old name",
       g.exec("systemctl is-active " & DefaultValidatorUnit).exitCode == 0 and
       g.exec("systemctl is-active " & RenamedUnit).exitCode != 0, "")
  g.waitSigning(3)
  # The lifetimes and databases of the five steps.
  discard g.exec("pkill -f validator-monitor.py")
  let lifeLog = g.run("cat " & LifetimeLog)
  record["lifetimes"] = %lifeLog
  let ls = parseLifetimes(lifeLog)
  let ov = overlaps(ls)
  step("no two validator lifetimes overlap", ov.len == 0, ov.join("\n"))
  step("each step started a new instance (at least six)", ls.len >= 6,
       $ls.len)
  let dbs = databasesHeld(lifeLog)
  record["databases"] = %dbs
  step("every instance held the same slashing-protection database",
       dbs.len == 1, $dbs)
  # The chain, before anything below touches it.
  let slashed = g.slashedValidators()
  step("no validator is slashed", slashed.len == 0, $slashed)
  # G26 residual 1: a validator outside the unit's control group.
  let unit = DefaultValidatorUnit
  let prysmBin = pins.validatorPrefix
  let chainCfg = pins.testnetPrefix & "/share/ethereum-testnet/config.yml"
  let walletPw = "/run/repro/secrets/eth-validator/wallet-password"
  let strayCmd = "systemd-run --scope --unit=a12-stray-" & $getCurrentProcessId() &
    " --uid=eth-validator --gid=eth-validator " &
    validatorCmd(prysmBin, chainCfg & " --wallet-password-file=/run/a12-pw")
  discard g.run("install -m 0400 -o eth-validator " & walletPw & " /run/a12-pw")
  let besideUnit = g.exec("timeout 60 " & strayCmd)
  step("a validator beside the running unit cannot open its database",
       besideUnit.exitCode != 0 and "cannot obtain database lock" in
         besideUnit.stdout & besideUnit.stderr,
       besideUnit.stdout & besideUnit.stderr)
  discard g.run("systemctl stop " & unit)
  discard g.run("setsid nohup " & strayCmd & " > /root/stray.log 2>&1 &")
  sleep(15_000)
  let since = g.run("date +%s").strip()
  discard g.exec("systemctl start " & unit)
  sleep(20_000)
  let unitLog = g.exec("journalctl -q -o cat --since @" & since & " -u " & unit).stdout
  step("an instance the unit starts beside it cannot open the database",
       "cannot obtain database lock" in unitLog, unitLog)
  discard g.exec("pkill -u eth-validator -f 'bin/validator'; sleep 5; " &
                 "systemctl reset-failed " & unit & "; systemctl start " & unit)
  g.waitSigning(2)
  # G26 residual 2: a second host with the same keys.
  let rogueDir = "/var/lib/ethereum/a12-second-host"
  discard g.run("rm -rf " & rogueDir & " && mkdir -p " & rogueDir & " && " &
    "cp -a " & StateDir & "/wallet " & rogueDir & "/ && " &
    "chown -R eth-validator: " & rogueDir)
  let second = g.exec("timeout 180 runuser -u eth-validator -- " &
    validatorCmd(prysmBin, chainCfg & " --wallet-password-file=/run/a12-pw " &
      "--datadir=" & rogueDir & " --wallet-dir=" & rogueDir & "/wallet " &
      "--monitoring-port=8091"), timeoutSec = 240)
  step("a second host's instance finds the keys live and exits",
       "Duplicate instances exists" in second.stdout & second.stderr,
       second.stdout & second.stderr)
  # The unit's history.
  discard g.run("systemctl stop " & unit)
  let hist = g.exportHistory(prysmBin, StateDir, "/root/a12-exp-unit")
  var all = @[hist]
  if dirExists(rogueDir):
    let r2 = g.exec("test -e " & rogueDir & "/validator.db")
    if r2.exitCode == 0:
      let h2 = g.exportHistory(prysmBin, rogueDir, "/root/a12-exp-second")
      step("the second host's instance signed nothing",
           attestationCount([h2]) == 0, $attestationCount([h2]))
      all.add(h2)
  let cs = conflicts(all)
  step("the slashing-protection records hold no conflicting signature",
       cs.len == 0, $cs.len & ": " & $(%cs))
  let first = earliestTarget([hist])
  var late: seq[string]
  for k in net.pubkeys:
    if first.getOrDefault(k.toLowerAscii(), high(int)) > startEpoch + 2:
      late.add(k)
  step("every key's history begins where the run began (none started over)",
       late.len == 0, $late)
  step("the history holds the run's attestations",
       attestationCount([hist]) >= 8 * 10, $attestationCount([hist]))
  # Positive control: a real double sign, found by the same check.
  discard g.run("systemctl start " & unit)
  let ctlDir = "/var/lib/ethereum/a12-control"
  discard g.run("rm -rf " & ctlDir & " && mkdir -p " & ctlDir & " && " &
    "cp -a " & StateDir & "/wallet " & ctlDir & "/ && chown -R eth-validator: " &
    ctlDir)
  discard g.exec("timeout 120 runuser -u eth-validator -- " &
    validatorCmd(prysmBin, chainCfg & " --wallet-password-file=/run/a12-pw " &
      "--datadir=" & ctlDir & " --wallet-dir=" & ctlDir & "/wallet " &
      "--monitoring-port=8092 --enable-doppelganger=false " &
      "--graffiti=a12-control"), timeoutSec = 200)
  discard g.run("systemctl stop " & unit)
  let hu = g.exportHistory(prysmBin, StateDir, "/root/a12-exp-unit2")
  let hc = g.exportHistory(prysmBin, ctlDir, "/root/a12-exp-control")
  let found = conflicts([hu, hc])
  record["positiveControlConflicts"] = %found.len
  step("positive control: a second database's real double sign is found",
       found.len > 0, "")

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  let step: StepFn = proc(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    let engine = engineFromEnv()
    record["engine"] = %engine
    g = newGuest(b, diskGiB = 16, cpus = 4, memoryMB = 6144)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    body(g, repro, engine, step, record)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["log"] = %g.log
      g.destroy()
  fails

suite Gate:
  test "the validator never double-signs across its replacements":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var fails: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "mutation": mutation(), "gateMutation": gateMutation(),
          "reprobuild": gitHead(), "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        fails.add(f)
      for f in fails: echo "FAIL ", f
      check fails.len == 0
