## What the reference-service gates share (``e2e_addon_reproos_service_parity``
## and ``e2e_addon_validator_never_double_signs``): the store packages, the
## local test network, the pins the reference profile reads, the producer's
## compile of that profile, and the provisioning a guest needs before the
## activities can start.
##
## *The store packages* are built on the test host from the
## reprobuild-packages recipes (``packages/source/{vaultwarden,geth,prysm}``,
## statically linked) and found under ``REPRO_A12_PACKAGES``, the root of a
## reprobuild-packages checkout in which they were built. Each is staged as
## a prefix tree (``bin/...``), its output-archive digest is what the
## profile pins, and the gate publishes it to its own binary cache under
## the key the compiled edge derives, so a guest substitutes it exactly as
## a host substitutes from the fleet cache.
##
## *The test network* is fully local: one execution client, one beacon node
## and one validator client with eight validators, post-merge from genesis
## (Electra at epoch 0, two-second slots, six-slot epochs), no peers, no
## discovery, nothing reached outside the guest. Its genesis is generated on
## the test host with ``prysmctl testnet generate-genesis`` from the
## committed ``fixtures/reference_services/testnet/{config.yml,genesis.json}``
## and a genesis time the gate chooses (a minute ahead of the run, so the
## chain starts fresh in every guest); given that time the bytes are a pure
## function of the inputs (checked: two generations agree). The validator
## keys are the eight deterministic interop keys, encrypted into a prysm
## wallet once and cached in the test bed's cache directory; the wallet
## password and the engine API secret are delivered as secrets, never in a
## profile.
##
## *Mocking.* None: real packages, a real chain, real units.

import std/[json, os, osproc, sequtils, strutils, times]

import nimcrypto/[hash, sha2]

import repro_binary_cache_client/in_process
import repro_peer_cache/auth as peerAuth
import repro_profile
import repro_deploy_agent/manifest

import ./addon_testbed
import ./agent_e2e_support
import ./cache_e2e_support

const
  FixtureDir* = currentSourcePath().parentDir / "fixtures" / "reference_services"
  ProfileSource* = FixtureDir / "system.nim"
  PinsModule* = "reference_pins.nim"
  TestnetChainId* = 32382
  WalletPasswordValue* = "a12-testnet-wallet"
    ## The test network's wallet password: a fixture value, delivered to
    ## the guest as a secret (`<validator service>/wallet-password`) the
    ## way an operator's would be.
  KeystorePassword = "a12-testnet-keystore"
  InteropValidators* = 8
  DefaultValidatorUnit* = "eth-validator.service"
  ReferenceActivities* = ["vaultwarden", "ethereum_validator"]

type
  RefPackages* = object
    ## Prefix trees on the test host, each with the package's `bin/`.
    vaultwarden*, geth*, prysm*: string

  Testnet* = object
    dir*: string             ## the prefix tree: share/ethereum-testnet/...
    walletTar*: string       ## the encrypted wallet, as a tar of `wallet/`
    genesisTime*: int64
    pubkeys*: seq[string]

  RefPins* = object
    vaultwardenPrefix*, vaultwardenDigest*: string
    gethPrefix*, gethDigest*: string
    prysmPrefix*, prysmDigest*: string
    testnetPrefix*, testnetDigest*: string
    validatorPrefix*, validatorDigest*: string
    validatorUnit*: string
    validatorExtraConfig*: string
    validatorUnitAddress*: string
      ## The validator unit's resource address; "" is the default (it
      ## names the unit).
    validatorStateDir*: string
      ## Where the validator's database lives: the declared state
      ## directory, `/var/lib/ethereum/validator`; only the validator gate's
      ## falsifying mutation moves it.

proc sha256File(path: string): string =
  ($sha256.digest(readFile(path))).toLowerAscii()

proc run(cmd: string; what: string): string =
  let (o, c) = execCmdEx(cmd)
  if c != 0:
    raise newException(TestBedError, what & " failed (exit " & $c & "): " &
      cmd & "\n" & o)
  o

# ---------------------------------------------------------------------------
# The store packages.
# ---------------------------------------------------------------------------

proc recipeOutput(root, name: string): string =
  root / "packages" / "source" / name / ".repro" / "output" / "install" / "usr"

proc stageTree(dest: string; sources: openArray[(string, string)]) =
  ## A prefix tree at ``dest`` with each (source file, name) under `bin/`.
  removeDir(dest)
  createDir(dest / "bin")
  for (src, name) in sources:
    if not fileExists(src):
      raise newException(TestBedError, "missing package binary " & src &
        " (build it: repro build packages/source/<name> in REPRO_A12_PACKAGES)")
    copyFileWithPermissions(src, dest / "bin" / name)

proc refPackages*(work: string): RefPackages =
  ## Stage the three packages from ``REPRO_A12_PACKAGES`` under ``work``.
  let root = getEnv("REPRO_A12_PACKAGES")
  if root.len == 0:
    raise newException(TestBedError, "REPRO_A12_PACKAGES must name the " &
      "reprobuild-packages checkout the reference packages were built in")
  result.vaultwarden = work / "trees" / "vaultwarden"
  stageTree(result.vaultwarden,
    [(recipeOutput(root, "vaultwarden") / "bin" / "vaultwarden", "vaultwarden")])
  result.geth = work / "trees" / "geth"
  stageTree(result.geth, [(recipeOutput(root, "geth") / "bin" / "geth", "geth")])
  result.prysm = work / "trees" / "prysm"
  let p = recipeOutput(root, "prysm") / "bin"
  stageTree(result.prysm, [(p / "beacon-chain", "beacon-chain"),
    (p / "validator", "validator"), (p / "prysmctl", "prysmctl"),
    (p / "prysm-keystores", "prysm-keystores")])

proc packageSha256s*(p: RefPackages): JsonNode =
  ## The binaries' digests, for the gate record.
  result = newJObject()
  for tree in [p.vaultwarden, p.geth, p.prysm]:
    for f in walkDir(tree / "bin"):
      result[f.path.extractFilename] = %sha256File(f.path)

# ---------------------------------------------------------------------------
# The test network.
# ---------------------------------------------------------------------------

proc interopPrivateKeys(): seq[string] =
  ## The interop keys: sha256 of the little-endian 32-byte index, read as a
  ## little-endian integer, reduced modulo the BLS12-381 group order
  ## (the consensus specs' interop mocked-start key derivation; prysm's
  ## `runtime/interop`). Computed by python3's big integers.
  let script = "import hashlib\n" &
    "r=0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001\n" &
    "for i in range(" & $InteropValidators & "):\n" &
    "  k=int.from_bytes(hashlib.sha256(i.to_bytes(32,'little')).digest(),'little')%r\n" &
    "  print(k.to_bytes(32,'big').hex())\n"
  run("python3 -I -c " & quoteShell(script), "interop keys").strip().splitLines()

proc walletFixture(prysm: string): tuple[tar: string; pubkeys: seq[string]] =
  ## The eight interop keys as a prysm wallet (encrypted, password
  ## `WalletPasswordValue`), cached per prysm build: keystore encryption
  ## draws a random salt, so the wallet is made once and reused.
  let key = sha256File(prysm / "bin" / "validator")[0 ..< 16]
  let dir = cacheDir() / "a12-testnet" / ("wallet-" & key)
  result.tar = dir / "wallet.tar"
  let pubs = dir / "pubkeys"
  if fileExists(result.tar) and fileExists(pubs):
    result.pubkeys = readFile(pubs).strip().splitLines()
    return
  let tmp = dir & ".tmp-" & $getCurrentProcessId()
  removeDir(tmp)
  createDir(tmp / "keys")
  var pubkeys: seq[string]
  for i, k in interopPrivateKeys():
    let o = run(quoteShell(prysm / "bin" / "prysm-keystores") & " encrypt " &
      "--password " & quoteShell(KeystorePassword) & " --private-key " & k &
      " --output-path " & quoteShell(tmp / "keys" / ("keystore-" & $i & ".json")),
      "prysm-keystores encrypt")
    discard o
    pubkeys.add(parseJson(readFile(tmp / "keys" / ("keystore-" & $i &
      ".json")))["pubkey"].getStr())
  writeFile(tmp / "account-password", KeystorePassword)
  writeFile(tmp / "wallet-password", WalletPasswordValue)
  discard run(quoteShell(prysm / "bin" / "validator") & " accounts import " &
    "--accept-terms-of-use --keys-dir=" & quoteShell(tmp / "keys") &
    " --wallet-dir=" & quoteShell(tmp / "wallet") &
    " --wallet-password-file=" & quoteShell(tmp / "wallet-password") &
    " --account-password-file=" & quoteShell(tmp / "account-password"),
    "validator accounts import")
  discard run("tar -C " & quoteShell(tmp) & " -cf " &
    quoteShell(tmp / "wallet.tar") & " wallet", "tar wallet")
  writeFile(tmp / "pubkeys", pubkeys.join("\n") & "\n")
  removeDir(tmp / "keys")
  removeFile(tmp / "account-password")
  removeFile(tmp / "wallet-password")
  removeDir(tmp / "wallet")
  removeDir(dir)
  moveDir(tmp, dir)
  result.pubkeys = pubkeys

proc generateGenesis*(prysm, outDir: string; genesisTime: int64) =
  ## The network definition for ``genesisTime`` into ``outDir``.
  createDir(outDir)
  copyFile(FixtureDir / "testnet" / "config.yml", outDir / "config.yml")
  discard run(quoteShell(prysm / "bin" / "prysmctl") &
    " testnet generate-genesis --fork=electra --num-validators=" &
    $InteropValidators & " --genesis-time=" & $genesisTime &
    " --chain-config-file=" & quoteShell(outDir / "config.yml") &
    " --geth-genesis-json-in=" &
    quoteShell(FixtureDir / "testnet" / "genesis.json") &
    " --geth-genesis-json-out=" & quoteShell(outDir / "genesis.json") &
    " --output-ssz=" & quoteShell(outDir / "genesis.ssz"),
    "prysmctl testnet generate-genesis")

proc makeTestnet*(p: RefPackages; work: string; leadSeconds = 240): Testnet =
  ## A fresh network starting ``leadSeconds`` from now.
  result.genesisTime = getTime().toUnix() + leadSeconds
  result.dir = work / "trees" / "testnet"
  removeDir(result.dir)
  generateGenesis(p.prysm, result.dir / "share" / "ethereum-testnet",
                  result.genesisTime)
  # prysmctl writes its outputs owner-only; the network definition is
  # public and read by three service accounts, so it is published 0644.
  for f in walkDirRec(result.dir):
    setFilePermissions(f, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
  let w = walletFixture(p.prysm)
  result.walletTar = w.tar
  result.pubkeys = w.pubkeys

# ---------------------------------------------------------------------------
# Pins and the producer's compile.
# ---------------------------------------------------------------------------

proc prefixPath*(name, version, digest: string): string =
  ## A store prefix named by the package, a version and the first sixteen
  ## hex digits of its output digest, so a new build is a new path.
  "/repro/store/prefixes/" & name & "/" & version & "-" &
    digest.replace("blake3:", "")[0 ..< 16]

proc digestOf*(tree: string): string = "blake3:" & prefixArchiveDigestHex(tree)

proc basePins*(p: RefPackages; t: Testnet): RefPins =
  result.vaultwardenDigest = digestOf(p.vaultwarden)
  result.vaultwardenPrefix = prefixPath("vaultwarden", "1.36.0",
                                        result.vaultwardenDigest)
  result.gethDigest = digestOf(p.geth)
  result.gethPrefix = prefixPath("geth", "1.17.10", result.gethDigest)
  result.prysmDigest = digestOf(p.prysm)
  result.prysmPrefix = prefixPath("prysm", "7.3.1", result.prysmDigest)
  result.testnetDigest = digestOf(t.dir)
  result.testnetPrefix = prefixPath("ethereum-testnet", $t.genesisTime,
                                    result.testnetDigest)
  result.validatorDigest = result.prysmDigest
  result.validatorPrefix = prefixPath("prysm-validator", "7.3.1",
                                      result.prysmDigest)
  result.validatorUnit = DefaultValidatorUnit
  result.validatorStateDir = "/var/lib/ethereum/validator"

proc nimStr(s: string): string = escapeJson(s)

proc pinsSource*(p: RefPins): string =
  ## The ``reference_pins.nim`` the profile imports.
  "## Written by the reference-service gate (reference_services.pinsSource).\n" &
    "const\n" &
    "  VaultwardenPrefix* = " & nimStr(p.vaultwardenPrefix) & "\n" &
    "  VaultwardenDigest* = " & nimStr(p.vaultwardenDigest) & "\n" &
    "  GethPrefix* = " & nimStr(p.gethPrefix) & "\n" &
    "  GethDigest* = " & nimStr(p.gethDigest) & "\n" &
    "  PrysmPrefix* = " & nimStr(p.prysmPrefix) & "\n" &
    "  PrysmDigest* = " & nimStr(p.prysmDigest) & "\n" &
    "  TestnetPrefix* = " & nimStr(p.testnetPrefix) & "\n" &
    "  TestnetDigest* = " & nimStr(p.testnetDigest) & "\n" &
    "  ValidatorPrefix* = " & nimStr(p.validatorPrefix) & "\n" &
    "  ValidatorDigest* = " & nimStr(p.validatorDigest) & "\n" &
    "  ValidatorUnit* = " & nimStr(p.validatorUnit) & "\n" &
    "  ValidatorExtraConfig* = " & nimStr(p.validatorExtraConfig) & "\n" &
    "  ValidatorStateDir* = " & nimStr(p.validatorStateDir) & "\n" &
    "  ValidatorUnitAddress* = " & nimStr(p.validatorUnitAddress) & "\n"

type Compiled* = object
  canonical*: string
  actions*: seq[ProfileBuildAction]
  actionsJson*: string

proc engineFromEnv*(): string =
  ## The full engine (a store path holding ``bin/reprobuild``, built from
  ## this tree): ``REPRO_ADDON_ENGINE_CLOSURE``.
  result = getEnv("REPRO_ADDON_ENGINE_CLOSURE")
  if result.len == 0 or not fileExists(result / "bin" / "reprobuild"):
    raise newException(TestBedError, "REPRO_ADDON_ENGINE_CLOSURE must name " &
      "a store path with bin/reprobuild built from this tree")

proc compileReference*(engine: string; pins: RefPins; mode: string;
                       activities: openArray[string];
                       host = AgentTarget): Compiled =
  ## The producer's compile of the reference profile for ``host``, realised
  ## per ``mode`` (``addOn`` / ``full``) with ``activities`` selected:
  ## ``repro deploy-agent compile-profile`` with the selection flags.
  let work = getTempDir() / ("a12-compile-" & $getCurrentProcessId() & "-" &
    $epochTime().int64)
  createDir(work / "src")
  defer: removeDir(work)
  copyFile(ProfileSource, work / "src" / "system.nim")
  writeFile(work / "src" / PinsModule, pinsSource(pins))
  discard run("env HOME=" & quoteShell(work / "home") & " " &
    quoteShellCommand(@[engine / "bin" / "reprobuild", "deploy-agent",
      "compile-profile", "--staged", work / "src" / "system.nim",
      "--canonical-out", work / "c", "--actions-out", work / "a",
      "--state-dir", work / "state", "--host", host, "--platform", "linux",
      "--arch", "x86_64", "--system-mode", mode,
      "--system-activities", activities.toSeq.join(",")]),
    "the producer's compile (" & mode & ")")
  result.canonical = readFile(work / "c")
  result.actionsJson = readFile(work / "a")
  result.actions = to(parseJson(result.actionsJson), seq[ProfileBuildAction])

proc treeFor*(p: RefPackages; t: Testnet; pins: RefPins; a: ProfileBuildAction): string =
  ## The tree an action's prefix is published from.
  if a.cwd == pins.vaultwardenPrefix: p.vaultwarden
  elif a.cwd == pins.gethPrefix: p.geth
  elif a.cwd == pins.prysmPrefix or a.cwd == pins.validatorPrefix: p.prysm
  elif a.cwd == pins.testnetPrefix: t.dir
  else: raise newException(TestBedError, "no tree for the action at " & a.cwd)

proc publishAll*(c: CacheServer; kp: PeerKeypair; p: RefPackages; t: Testnet;
                 pins: RefPins; actions: seq[ProfileBuildAction]):
    seq[ClosureDigest] =
  ## Publish every substitute-only edge's prefix under its compiled
  ## identity; returns the manifest's closure digests (each the pinned one).
  for a in actions:
    if not a.substituteOnly: continue
    let d = c.publishTree(kp, a, treeFor(p, t, pins, a))
    if d != a.expectedOutputDigest:
      raise newException(TestBedError, "published " & a.id & " as " & d &
        " but the profile pins " & a.expectedOutputDigest)
    result.add(ClosureDigest(actionId: a.id, digest: d))
  sortClosureDigests(result)

# ---------------------------------------------------------------------------
# Guest provisioning.
# ---------------------------------------------------------------------------

proc jwtHex*(): string =
  ## A fresh engine-API secret (32 random bytes, hex), per run.
  let (o, c) = execCmdEx("od -An -tx1 -N32 /dev/urandom")
  doAssert c == 0
  o.multiReplace((" ", ""), ("\n", ""))

proc provisionWallet*(g: Guest; t: Testnet) =
  ## The operator's step before the first apply: the encrypted wallet in
  ## the validator's state directory, as root (the profile's tmpfiles rule
  ## hands it to the validator's account).
  g.copyTo(t.walletTar, "/root/wallet.tar")
  discard g.run("mkdir -p /var/lib/ethereum/validator && " &
    "tar -C /var/lib/ethereum/validator -xf /root/wallet.tar && " &
    "rm /root/wallet.tar && chmod -R go-rwx /var/lib/ethereum/validator/wallet")

proc putSecret*(g: Guest; verb, service, name, value: string): ExecOut =
  ## ``<verb> --service S --name N`` with ``value`` on stdin, never in an
  ## argument (the value goes through a root-only file the shell removes).
  let f = "/root/.a12-secret-" & service & "-" & name
  writeFile(g.runDir / "secret.tmp", value)
  g.copyTo(g.runDir / "secret.tmp", f)
  removeFile(g.runDir / "secret.tmp")
  g.exec("chmod 0400 " & f & " && " & verb & " --service " & service &
    " --name " & name & " < " & f & "; rc=$?; rm -f " & f & "; exit $rc")

proc putReferenceSecrets*(g: Guest; verb: string; jwt: string;
                          validatorUnits: openArray[string];
                          step: StepFn) =
  ## Every secret the reference activities load: the admin token, the
  ## engine API secret for its two services, and the wallet password for
  ## each unit name the validator may run under.
  var entries = @[("vaultwarden", "admin-token",
                   "a12-admin-" & jwtHex()[0 ..< 24]),
                  ("eth-execution", "jwt", jwt), ("eth-beacon", "jwt", jwt)]
  for u in validatorUnits:
    entries.add((u[0 ..< u.len - ".service".len], "wallet-password",
                 WalletPasswordValue))
  for (svc, name, value) in entries:
    let r = g.putSecret(verb, svc, name, value)
    step("secret " & svc & "/" & name & " put", r.exitCode == 0,
         r.stdout & r.stderr)

proc beaconApi*(g: Guest; path: string): JsonNode =
  ## A GET on the guest's beacon node REST API (loopback in the guest).
  let r = g.exec("curl -sf --max-time 10 http://127.0.0.1:3500" & path)
  if r.exitCode != 0: return newJNull()
  try: parseJson(r.stdout) except CatchableError: newJNull()

proc headSlot*(g: Guest): int =
  let j = g.beaconApi("/eth/v1/beacon/headers/head")
  if j.kind != JObject: return -1
  parseInt(j["data"]["header"]["message"]["slot"].getStr())

proc justifiedEpoch*(g: Guest): int =
  let j = g.beaconApi("/eth/v1/beacon/states/head/finality_checkpoints")
  if j.kind != JObject: return -1
  parseInt(j["data"]["current_justified"]["epoch"].getStr())

proc slashedValidators*(g: Guest): seq[string] =
  ## The indices the head state marks slashed ("" list when none; a failed
  ## query raises, it never reads as none).
  let j = g.beaconApi("/eth/v1/beacon/states/head/validators")
  if j.kind != JObject:
    raise newException(TestBedError, "the beacon node did not answer " &
      "/eth/v1/beacon/states/head/validators")
  for v in j["data"]:
    if v["validator"]["slashed"].getBool():
      result.add(v["index"].getStr())

proc waitHeadSlot*(g: Guest; atLeast: int; timeoutSec = 600): bool =
  let deadline = epochTime() + float(timeoutSec)
  while epochTime() < deadline:
    if g.headSlot() >= atLeast: return true
    sleep(2000)
  false

proc waitJustified*(g: Guest; atLeast: int; timeoutSec = 900): bool =
  let deadline = epochTime() + float(timeoutSec)
  while epochTime() < deadline:
    if g.justifiedEpoch() >= atLeast: return true
    sleep(3000)
  false

proc serviceJournal*(g: Guest; units: openArray[string]; lines = 80): string =
  ## The last ``lines`` journal lines of ``units`` and their status, for a
  ## failed step's record.
  var args = ""
  for u in units: args.add(" -u " & quoteShell(u))
  g.exec("journalctl -q --no-pager -o short-monotonic -n " & $lines & args &
    "; systemctl status --no-pager -l" & args.replace(" -u ", " ") &
    " 2>&1 | head -80").stdout
