## Command-line surface of add-on mode, shared by the full ``repro`` engine
## (``repro system addon …``) and the statically linked add-on ``repro``
## (which also answers to the name ``repro-addon-fingerprint``).
##
##   repro system addon preflight [--deploy-signers F] [--cache-publishers F [--cache-url U]]
##                                [--json]
##   repro system addon bootstrap --plan <digest> [--deploy-signers F]
##                                [--cache-publishers F [--cache-url U]]
##                                [--evidence-sink A:P --evidence-sink-ca F]
##   repro system addon evidence-ship [--heartbeat]
##   repro system addon evidence-credential-check
##   repro system addon uninstall [--keep-store]
##   repro system addon verify [--boot | --after-dpkg]
##   repro system addon reassert [--boot]
##   repro system addon recover
##   repro system addon secrets [--boot]
##   repro system addon probe <healthCheck>
##   repro system addon secret put --service S --name N [--target T] < secret
##   repro system addon rotate-recipient-key
##   repro system addon agent-tick --source <manifest>... [--target T]
##   repro system rollback [<generation>] [--reconcile-drift]
##   repro system addon fingerprint [--root R] [--no-live] [--out F]
##   repro system addon fingerprint diff <before> <after>
##                                [--except <component>:<key glob>]...
##                                [--expect <file>]
##   repro system addon expected-delta <before-ledger|-> <after-ledger>
##   repro system addon ledger
##   repro system addon import --unit <name>
##   repro system addon state backup|release|verify|restore|digest|unit
##   repro system addon retention [--keep-generations N] [--keep-days D]
##   repro system addon selfcheck-write <path>
##   repro system adopt <address> --profile <file>
##   repro infra plan --profile <file>
##   repro infra apply --profile <file> [--reconcile-drift] [--plan <add-on plan-id>]
##                                [--keep-generations N] [--keep-days D]
##   repro store gc [--grace-seconds N] | roots | list
##
## Exit status: 0 success; 1 failure, drift or a non-empty diff; 2 a usage
## error or a refusal decided before anything was written (an incompatible
## host, a plan digest that does not match).

import std/[options, os, strutils]

import std/algorithm

import repro_core/host_apply_lock
import repro_infra

import repro_infra/addon_diagnostics

import repro_elevation
import repro_elevation/posix_system_driver
import repro_local_store/store as local_store

import ./addon_apply
import ./adoption_cli
import ./addon_rollback
import ./agent_record
import ./agent_repin
import ./agent_switch
import ./apt_hook
import ./base_identity
import ./bootstrap
import ./collision
import ./own_profile
import ./containment
import ./evidence_ship
import ./evidence_enrol
import ./egress_observer
import ./store_custody
import ./store_verify
import ./fingerprint
import ./generation0
import ./ledger
import ./linux_fs
import ./health
import ./preflight
import ./reassert
import ./seams
import ./secrets_ops
import ./agent_split
import ./static_tree
import ./store_root
import ./switch
import ./transitions
import ./uninstall
import ./verify

proc migrateStaleOwnObjects*(stateDir: string; atBoot = false): string =
  ## One switch to the migrated own profile when it differs (``own_profile.
  ## migrateOwnProfile``); "" when there is nothing to migrate. At boot it
  ## runs only for a stale evidence path unit.
  let p = ownProfilePath(stateDir)
  if not fileExists(p): return ""
  let own = readFile(p)
  if atBoot:
    let path = unitContentOf(own, EvidenceShipPathUnit)
    if path.len == 0 or path == evidenceShipPathUnit(): return ""
  let migrated = migrateOwnProfile(own)
  if migrated == own: return ""
  let userText = if fileExists(userProfilePath(stateDir)):
                   readFile(userProfilePath(stateDir)) else: ""
  let r = runAddonApply(AddonApplyOptions(stateDir: stateDir,
    hostIdentity: readHostname(), userProfileText: userText,
    storedTarget: true, ownProfileText: migrated, purpose: "own-migration"))
  "migrated generation 0's objects: add-on generation " & r.generationId

const
  AddonUsage* = """usage: repro system addon <command> [options]

commands:
  preflight [--deploy-signers F] [--cache-publishers F [--cache-url U]]
            [--target T --manifest URL... [--profile-compiler P] [--poll-interval S]]
            [--evidence-sink ADDR:PORT --evidence-sink-ca F [--heartbeat-interval S]]
            [--json]
      Inventory the host read-only and print the plan and its digest.
  bootstrap --plan <digest> [--deploy-signers F] [--cache-publishers F [--cache-url U]]
            [--target T --manifest URL... [--profile-compiler P] [--poll-interval S]]
            [--evidence-sink ADDR:PORT --evidence-sink-ca F [--heartbeat-interval S]]
      Install the add-on on a host whose preflight plan has <digest>. With
      an Evidence sink, also generate the generation-attestation key and
      the sink write credential (enrol its certificate at the sink).
  evidence-ship [--heartbeat]
      The shipping unit (repro-addon-evidence.service): append every queued
      evidence record to the Evidence sink, then a heartbeat.
  evidence-enrol --evidence-sink ADDR:PORT --evidence-sink-ca F [--heartbeat-interval S]
      Give an add-on host bootstrapped without an Evidence sink one: create
      the attestation key and the sink write credential (never adopting or
      replacing a key), and apply generation 0's evidence objects -- and,
      with the deploy agent, its egress observer -- as one switch.
  evidence-enrol --rekey [--no-handover]
      Replace an enrolled host's attestation key and sink credential (spec
      §13 decision 52): the old key signs a hand-over to the new ones, which
      is shipped with the old credential before anything is replaced; then
      one switch names the new keys. --no-handover, when the old key may be
      compromised: no hand-over; enrol the new key at the sink by hand.
  store-verify [--background] [--adopt-unverified]
      Hash every store path the current generation uses and compare it with
      the digest it was realised with; quarantine an altered one (DET-AO-5).
      --adopt-unverified: record the current digest of paths realised
      before receipts carried one (an operator action).
  egress-check
      The egress observer's check (repro-addon-egress-check.service): record
      every destination the deploy agent's fetch unit was refused, and
      heartbeat.
  evidence-credential-check
      Test this host's sink write credential: an append must succeed and a
      list, a read, an overwrite and a delete must each be refused. Exit 0
      only then. It announces itself first, so the sink's check reads it as
      a self-test, not as a probe (G34).
  uninstall [--keep-store] [--discard-store-evidence]
      Reverse everything the ownership ledger records.
  verify [--boot | --after-dpkg]
      Compare every ledger object with the host (report only). --after-dpkg
      (the apt hook): also report packages that now own ledger paths and
      changed vendor units, record findings in the journal and the hook's
      event log, and always exit 0.
  reassert [--boot]
      Finish or revert an interrupted switch, check the current generation
      (static tree, store objects, ledger digests) and report ok, drift or
      degraded; never re-applies on drift. --boot (the re-assert unit):
      always exits 0.
  recover
      The same, for an operator: exits 1 unless the host ends ok or drift.
  secrets [--boot]
      Re-materialise the current generation's secrets from the retained
      envelope (the boot secrets unit; leaves them to an apply that holds
      the host apply lock). --boot: always exits 0.
  probe <healthCheck>
      Run one tcp: or http:// health check here (the confirm step runs it
      in the host's namespaces); exits 0 when it passes.
  secret put --service S --name N [--target T] < secret
      Seal the secret read from stdin to this host's recipient key as the
      entry S/N of the retained envelope, and re-materialise the current
      generation's secrets under /run/repro/secrets.
  rotate-recipient-key
      Generate the next recipient key and print its public half; the
      current key is deleted when the first envelope sealed to the new
      one opens.
  agent-repin [--apply <digest>]
      Resolve the deploy agent's origins again and print the plan for the
      fetch unit's egress allow-list and hosts file (writing nothing), or
      apply the plan the digest names as one switch (spec §9.1).
  agent-tick --source <manifest>... [--target T] [--allowed-signers F]
      One deploy-agent tick in one process: verify (RDMF v3 required),
      accept the sealed section, apply the profile through the switch; it
      compiles nothing. Exit 0, 1 (retryable) or 2 (an operator must act).
  agent-fetch
      The fetch unit (repro-agent-fetch.service, unprivileged): select,
      compile, substitute and download into its staging area.
  agent-apply
      The apply unit (repro-agent-apply.service, root, no network): copy
      the staging area, verify everything again, apply.
  migration-plan [--state-dir D] [--agent-state A] [--target T]
                 [--legacy-secrets-dir S]
      Plan, writing nothing, the migration the first tick of an agent that
      applied outside the switch runs (spec §9 "Migration"): every object it
      would adopt, write or refuse, and the service transitions. D and A
      default to the add-on's and the agent's state directories; pass
      copies to plan against a snapshot. S is the agent's --secrets-dir,
      whose hand-written LoadCredential= sources the plan accepts (spec
      §10.3). Exit 0 when it would succeed, 2
      when it would refuse, 1 when nothing can be planned.
  resume
      Let the deploy agent converge again after a local rollback paused it
      (spec §9.3): removes the pause marker of every agent the rollback
      paused. Exits 0 whether or not one was there.
  migrate
      Re-render generation 0's objects this build renders differently (the
      evidence path unit, the fetch unit) by one switch; the re-assert unit
      runs it at boot when the evidence path unit is stale. Exit 0.
  contain --operator NAME --reason TEXT
      Contain the host (spec §13 decision 51): record and ship a signed
      operator-contained record, then stop and mask the deploy agent's
      fetch and apply units (re-masked at every boot until release). The
      off-host check then reports the agent "contained", not silent.
  release --operator NAME --reason TEXT
      Record and ship operator-released, unmask the agent's units and start
      its fetch timer again.
  fingerprint [--root R] [--no-live] [--out F]
  fingerprint diff <before> <after> [--except C:GLOB]... [--expect F]
      Record the base fingerprint, or compare two.
  expected-delta <before-ledger|-> <after-ledger>
      The fingerprint diff an apply between two ledgers may cause.
  ledger
      Print the current ownership ledger.
  import --unit <name>
      Print a profile skeleton that reproduces a hand-configured unit, its
      environment files, the /etc files it names and its tmpfiles
      fragments as they are, with a FLAG line for everything it cannot
      declare (spec §11.2 step 1). Writes nothing on the host.
  state backup|release|verify|restore|digest|unit
      The profile's declared state set (stateDirectories, spec §11.1):
      back it up before a conversion, restore it after; see
      `repro system addon state --help`.
  status
      The current generation, the generations held as store roots, the
      static tree and the pending switch marker, and the store root's kind.
  retention [--keep-generations N] [--keep-days D]
      Release the store roots of generations outside the policy now (the
      current and the previous generation are always kept); default last
      5 generations or 30 days, whichever retains more.
  selfcheck-btrfs <mount point>
      Create and delete a btrfs subvolume under a btrfs mount the way the
      store root is created on a btrfs root (a test of that leg).
  selfcheck-write <path>
      Write a managed file at <path> through the system-file driver exactly
      as the switch does, with no plan and no collision pass: a test of
      the writer's refusal to follow a symbolic link on the path.

related (add-on hosts):
  repro system adopt <address> --profile <file>
      Claim the object a declared resource targets as it is, writing nothing.
  repro infra plan --profile <file>
      The ledger diff, collision report and service transition list of
      applying <file>, and the add-on plan-id that `--plan` pins; writes
      nothing.
  repro infra apply --profile <file> [--reconcile-drift] [--plan <add-on plan-id>]
                    [--keep-generations N] [--keep-days D]
      Apply an add-on generation through the switch.
  repro store gc [--grace-seconds N] | roots | list
      Collect store prefixes no root holds (never one the current or the
      previous generation holds); list the roots or the prefixes.
"""

  FingerprintUsage* = """usage: repro-addon-fingerprint [--root R] [--no-live] [--out F]
       repro-addon-fingerprint diff <before> <after> [--except C:GLOB]... [--expect F]
"""

proc takeValue(args: seq[string]; i: var int; flag: string): string =
  ## ``--flag value`` or ``--flag=value``.
  let a = args[i]
  if a.startsWith(flag & "="):
    return a[flag.len + 1 .. ^1]
  if i + 1 >= args.len:
    raise newException(ValueError, flag & " needs a value")
  inc i
  args[i]

proc parsePreflightArgs*(rest: seq[string]): tuple[inp: PreflightInputs;
                                                   json: bool] =
  ## ``preflight``'s options (also the docs test's parser, A11 review
  ## finding 16). Raises ``ValueError``.
  var inp: PreflightInputs
  var json = false
  var i = 0
  while i < rest.len:
    let a = rest[i]
    if a == "--deploy-signers" or a.startsWith("--deploy-signers="):
      inp.deploySignersPath = takeValue(rest, i, "--deploy-signers")
    elif a == "--cache-publishers" or a.startsWith("--cache-publishers="):
      inp.cachePublishersPath = takeValue(rest, i, "--cache-publishers")
    elif a == "--cache-url" or a.startsWith("--cache-url="):
      inp.cacheUrl = takeValue(rest, i, "--cache-url")
    elif a == "--target" or a.startsWith("--target="):
      inp.agentTarget = takeValue(rest, i, "--target")
    elif a == "--manifest" or a.startsWith("--manifest="):
      inp.agentSources.add(takeValue(rest, i, "--manifest"))
    elif a == "--profile-compiler" or a.startsWith("--profile-compiler="):
      inp.profileCompiler = takeValue(rest, i, "--profile-compiler")
    elif a == "--poll-interval" or a.startsWith("--poll-interval="):
      inp.agentPollSec = parseInt(takeValue(rest, i, "--poll-interval"))
    elif a == "--evidence-sink" or a.startsWith("--evidence-sink="):
      inp.evidenceSink = takeValue(rest, i, "--evidence-sink")
    elif a == "--evidence-sink-ca" or a.startsWith("--evidence-sink-ca="):
      inp.evidenceSinkCaPath = takeValue(rest, i, "--evidence-sink-ca")
    elif a == "--heartbeat-interval" or a.startsWith("--heartbeat-interval="):
      inp.evidenceHeartbeatSec = parseInt(takeValue(rest, i,
        "--heartbeat-interval"))
    elif a == "--json":
      json = true
    else:
      raise newException(ValueError, "unknown option " & a)
    inc i
  (inp, json)

proc parseUninstallArgs*(rest: seq[string]): UninstallOptions =
  ## ``uninstall``'s options. Raises ``ValueError``.
  for a in rest:
    if a == "--keep-store": result.keepStore = true
    elif a == "--discard-store-evidence": result.discardStoreEvidence = true
    else: raise newException(ValueError, "unknown option " & a)

proc parseBootstrapArgs*(rest: seq[string]): BootstrapOptions =
  ## ``bootstrap``'s options. Raises ``ValueError``.
  var opts: BootstrapOptions
  var i = 0
  while i < rest.len:
    let a = rest[i]
    if a == "--plan" or a.startsWith("--plan="):
      opts.planDigest = takeValue(rest, i, "--plan")
    elif a == "--deploy-signers" or a.startsWith("--deploy-signers="):
      opts.deploySignersPath = takeValue(rest, i, "--deploy-signers")
    elif a == "--cache-publishers" or a.startsWith("--cache-publishers="):
      opts.cachePublishersPath = takeValue(rest, i, "--cache-publishers")
    elif a == "--cache-url" or a.startsWith("--cache-url="):
      opts.cacheUrl = takeValue(rest, i, "--cache-url")
    elif a == "--target" or a.startsWith("--target="):
      opts.agentTarget = takeValue(rest, i, "--target")
    elif a == "--manifest" or a.startsWith("--manifest="):
      opts.agentSources.add(takeValue(rest, i, "--manifest"))
    elif a == "--profile-compiler" or a.startsWith("--profile-compiler="):
      opts.profileCompiler = takeValue(rest, i, "--profile-compiler")
    elif a == "--poll-interval" or a.startsWith("--poll-interval="):
      opts.agentPollSec = parseInt(takeValue(rest, i, "--poll-interval"))
    elif a == "--evidence-sink" or a.startsWith("--evidence-sink="):
      opts.evidenceSink = takeValue(rest, i, "--evidence-sink")
    elif a == "--evidence-sink-ca" or a.startsWith("--evidence-sink-ca="):
      opts.evidenceSinkCaPath = takeValue(rest, i, "--evidence-sink-ca")
    elif a == "--heartbeat-interval" or a.startsWith("--heartbeat-interval="):
      opts.evidenceHeartbeatSec = parseInt(takeValue(rest, i,
        "--heartbeat-interval"))
    else:
      raise newException(ValueError, "unknown option " & a)
    inc i
  opts

proc runFingerprintCli*(args: seq[string]): int =
  try:
    if args.len > 0 and args[0] == "diff":
      var paths: seq[string]
      var rules: seq[ExceptionRule]
      var expectPath = ""
      var i = 1
      while i < args.len:
        let a = args[i]
        if a == "--except" or a.startsWith("--except="):
          rules.add(parseExceptionRule(takeValue(args, i, "--except")))
        elif a == "--expect" or a.startsWith("--expect="):
          expectPath = takeValue(args, i, "--expect")
        elif a.startsWith("-"):
          raise newException(ValueError, "unknown option " & a)
        else:
          paths.add(a)
        inc i
      if paths.len != 2:
        raise newException(ValueError, "diff needs <before> <after>")
      let d = applyExceptions(
        diff(parseFingerprint(readFile(paths[0])),
             parseFingerprint(readFile(paths[1]))), rules)
      if expectPath.len > 0:
        let report = matchExpectations(d, parseExpectations(readFile(expectPath)))
        if report.ok:
          stdout.write("fingerprint diff equals the expectation (" &
                       $d.len & " records)\n")
          return 0
        stdout.write(renderExpectationReport(report))
        return 1
      stdout.write(renderDiff(d))
      return (if d.len == 0: 0 else: 1)
    var opts = CollectOptions(root: "/", live: true)
    var outPath = ""
    var i = 0
    while i < args.len:
      let a = args[i]
      if a == "--root" or a.startsWith("--root="):
        opts.root = takeValue(args, i, "--root")
      elif a == "--no-live":
        opts.live = false
      elif a == "--out" or a.startsWith("--out="):
        outPath = takeValue(args, i, "--out")
      elif a in ["-h", "--help"]:
        stdout.write(FingerprintUsage)
        return 0
      else:
        raise newException(ValueError, "unknown option " & a)
      inc i
    let text = collectFingerprint(opts).render()
    if outPath.len > 0:
      writeFile(outPath, text)
    else:
      stdout.write(text)
    0
  except ValueError as e:
    stderr.write("repro-addon-fingerprint: " & e.msg & "\n" & FingerprintUsage)
    2
  except CatchableError as e:
    stderr.write("repro-addon-fingerprint: " & e.msg & "\n")
    1

proc previousGenerationOf*(stateDir, current: string): string =
  ## The generation `current` succeeded (its envelope's predecessor), ""
  ## for generation 0.
  if current.len == 0: return ""
  try:
    readGenerationEnvelope(pointerPath(stateDir, current)).previousGenerationId
  except CatchableError:
    ""

proc retentionCount(value, flag: string): int =
  ## A retention bound: a non-negative integer (0 keeps only what is
  ## always kept).
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, flag & " expects a non-negative integer, got " & value)
  if result < 0:
    raise newException(ValueError, flag & " expects a non-negative integer, got " & value)

proc selfcheckManagedWrite*(path: string): string =
  ## Exercise the system-file driver's write at ``path`` the way the
  ## switch's copy step does (``applyFsSystemFile`` with the add-on's
  ## policy, a copy): no plan, no collision pass, so a link planted on the
  ## path meets the WRITER's own refusal. Returns a one-line report;
  ## raises on refusal (``EProtocol`` naming the link) or failure.
  let op = PrivilegedOperation(kind: pokFsSystemFile,
    address: "selfcheck:" & path, sfPath: path,
    sfContent: "repro-addon selfcheck-write\n")
  let policy: AddOnDispatchPolicy = proc(op: PrivilegedOperation):
      AddOnMaterialisation {.gcsafe.} =
    AddOnMaterialisation(orchestrated: true)
  let post = applyFsSystemFile(FixtureContext(addOn: policy), op)
  "wrote " & path & " (digest " & post.digestHex[0 ..< 12] & ")"

proc runMigrationPlanCli*(args: seq[string]): int
  ## Below, beside the other plan verbs.

proc runAddonCli*(args: seq[string]): int =
  ## Dispatch ``repro system addon <args>``.
  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    stdout.write(AddonUsage)
    return (if args.len == 0: 2 else: 0)
  let cmd = args[0]
  let rest = args[1 .. ^1]
  # The verbs that hold plaintext secrets run where their heap cannot be
  # swapped (spec §10.3): `secret`, `rotate-recipient-key` and `agent-tick`
  # always, the re-assert and secrets verbs on a host that keeps envelopes
  # (their boot units carry MemorySwapMax=0 themselves).
  if cmd in ["secret", "rotate-recipient-key", "agent-tick", "agent-apply"] or
      (cmd in ["reassert", "recover", "secrets"] and "--boot" notin rest and
       hostHasSecrets()):
    let r = reexecInNoSwapScope()
    if r >= 0: return r
  try:
    case cmd
    of "fingerprint":
      return runFingerprintCli(rest)
    of "import":
      return runAddonImportCli(rest)
    of "state":
      return runStateCli(rest)
    of "preflight":
      let (inp, json) = parsePreflightArgs(rest)
      let r = runPreflight(inp)
      if json:
        stdout.write(r.planJson & "\n")
      else:
        stdout.write(renderPreflightHuman(r))
      return (if r.compatible: 0 else: 2)
    of "bootstrap":
      let opts = parseBootstrapArgs(rest)
      try:
        let r = runAddonBootstrap(opts)
        stdout.write("plan digest:          " & r.planDigest & "\n" &
                     "generation:           " & r.generationId & "\n" &
                     "add-on binary:        " & r.reproExe & "\n" &
                     "binary sha256:        " & r.binarySha256 & "\n" &
                     "recipient public key: " & r.recipientPublicKeyHex & "\n")
        if r.evidenceCredentialHost.len > 0:
          # Evidence ships once the sink knows this host: the operator
          # copies the credential's certificate into the sink's anchor
          # directory (records wait in the outbox until then).
          stdout.write("attestation key:      " & r.attestationPublicKeyHex & "\n" &
                       "evidence credential:  " & r.evidenceCredentialHost &
                       " (enrol " & r.evidenceCredentialCert & " at the sink)\n")
        return 0
      except AddonPlanMismatch as e:
        stderr.write("repro system addon bootstrap: " & e.msg & "\n")
        return 2
    of "uninstall":
      let r = runAddonUninstall(parseUninstallArgs(rest))
      for p in r.removed: stdout.write("removed " & p & "\n")
      for d in r.drift: stdout.write("left in place (drift): " & d & "\n")
      for e in r.errors: stderr.write("error: " & e & "\n")
      stdout.write("accounts kept: " &
        (if r.keptAccounts.len == 0: "none" else: r.keptAccounts.join(", ")) &
        "\n")
      return (if r.ok: 0 else: 1)
    of "verify":
      var reportOnly = false
      for a in rest:
        if a in ["--boot", "--after-dpkg"]: reportOnly = true
        else: raise newException(ValueError, "unknown option " & a)
      if "--after-dpkg" in rest:
        # The apt hook (spec §7.8): ledger digests, new package owners of
        # ledger paths, changed vendor units; recorded, always exit 0.
        return runAfterDpkgCli()
      if reportOnly:
        # Report-only callers (the boot unit, the apt hook) must never fail
        # whatever invoked them, so nothing here may raise or exit non-zero.
        try:
          stdout.write(renderVerify(runAddonVerify()))
        except CatchableError as e:
          stdout.write("repro-addon verify: degraded\n  " & e.msg & "\n")
        return 0
      let r = runAddonVerify()
      stdout.write(renderVerify(r))
      return (if r.status == "ok": 0 else: 1)
    of "reassert", "recover":
      var atBoot = false
      for a in rest:
        if a == "--boot" and cmd == "reassert": atBoot = true
        else: raise newException(ValueError, "unknown option " & a)
      if atBoot:
        # A contained host stays contained across the reboot (decision 51):
        # the runtime masks are gone, so they are put back first.
        try: discard reapplyContainment()
        except CatchableError: discard
        # The boot unit: never fails the boot transaction, whatever it finds.
        try:
          stdout.write(renderReassert(runAddonReassert(DefaultStateDir,
            atBoot = true)))
        except CatchableError as e:
          stdout.write("repro-addon reassert: degraded\n  " & e.msg & "\n")
        # A host bootstrapped before the shipping path unit's fix (the drill's
        # D1) is migrated here, by one switch, rather than waiting for its
        # next generation (A11 review finding 8).
        try:
          let m = migrateStaleOwnObjects(DefaultStateDir, atBoot = true)
          if m.len > 0: stdout.write(m & "\n")
        except CatchableError as e:
          stdout.write("repro-addon migration: " & e.msg & "\n")
        return 0
      let r = runAddonReassert(DefaultStateDir, atBoot = false)
      stdout.write(renderReassert(r))
      return (if r.status in ["ok", "drift", "deferred"]: 0 else: 1)
    of "secrets":
      # `repro system addon secrets [--boot]`: re-materialise the current
      # generation's secrets (repro-addon-secrets.service at boot, §7.7).
      var atBoot = false
      for a in rest:
        if a == "--boot": atBoot = true
        else: raise newException(ValueError, "unknown option " & a)
      let r = bootSecrets(DefaultStateDir)
      stdout.write("repro-addon secrets: " & r.line & "\n")
      return (if atBoot or r.ok: 0 else: 1)
    of "secret":
      return runSecretPutCli(rest)
    of "rotate-recipient-key":
      return runRotateRecipientKeyCli(rest)
    of "evidence-ship":
      return runEvidenceShipCli(rest)
    of "evidence-credential-check":
      return runCredentialCheckCli(rest)
    of "evidence-enrol":
      return runEvidenceEnrolCli(rest)
    of "egress-check":
      return runEgressCheckCli(rest)
    of "store-verify":
      return runStoreVerifyCli(rest)
    of "agent-tick":
      return agent_split.runAgentTickCli(rest)
    of "agent-fetch":
      return runAgentFetchCli(rest)
    of "agent-apply":
      return runAgentApplyCli(rest)
    of "resume":
      return runResumeCli(rest)
    of "migrate":
      if rest.len != 0: raise newException(ValueError, "migrate takes no option")
      let m = migrateStaleOwnObjects(DefaultStateDir)
      stdout.write((if m.len > 0: m else: "generation 0 is current; nothing " &
        "to migrate") & "\n")
      return 0
    of "contain":
      return runContainCli(rest)
    of "release":
      return runContainCli(rest, release = true)
    of "agent-repin":
      return runAgentRepinCli(rest)
    of "migration-plan":
      return runMigrationPlanCli(rest)
    of "test-sleep":
      # Seam builds only (a hanging command in the store, for a gate);
      # every other build answers with a usage error.
      return seamSleepCommand(rest)
    of "probe":
      if rest.len != 1:
        raise newException(ValueError, "probe needs one healthCheck value")
      let spec = parseHealthCheck(rest[0])
      if spec.kind notin {hcTcp, hcHttp}:
        raise newException(ValueError, "probe runs tcp: and http:// checks only")
      let why = runProbe(spec)
      if why.len == 0:
        stdout.write("probe " & rest[0] & ": ok\n")
        return 0
      stdout.write("probe " & rest[0] & ": " & why & "\n")
      return 1
    of "expected-delta":
      if rest.len != 2:
        raise newException(ValueError, "expected-delta needs two ledgers")
      let before = if rest[0] == "-": Ledger() else: readLedger(rest[0])
      let after = readLedger(rest[1])
      for e in expectedDelta(before, after):
        stdout.write(renderExpectation(e) & "\n")
      return 0
    of "ledger":
      stdout.write(readLedger(ledgerCopyPath(DefaultStateDir)).render())
      return 0
    of "status":
      # What an operator (and the store-roots gate) needs to see: the
      # current generation, every generation registered as a store root,
      # the static tree and any pending switch, and what kind of thing
      # /repro is.
      let current = readCurrentGenerationId(DefaultStateDir)
      stdout.write("current generation: " & current & "\n")
      # The generation `current` was switched from, as its envelope
      # records: the history `repro system rollback` walks.
      stdout.write("previous generation: " &
        previousGenerationOf(DefaultStateDir, current) & "\n")
      stdout.write("static tree: " &
        (if readStaticTarget().len > 0: readStaticTarget() else: "none") & "\n")
      if hasPendingMarker(DefaultStateDir):
        let m = readPendingMarker(DefaultStateDir)
        stdout.write("pending switch: " & m.status & " at step " & $m.step &
          " (from " & m.fromGeneration & " to " & m.newStatic & ")" &
          (if m.detail.len > 0: ": " & m.detail else: "") & "\n")
      stdout.write("store root: " & ReproRoot & " " &
        (if not dirExists(ReproRoot): "absent"
         elif isBtrfsSubvolume(ReproRoot): "btrfs-subvolume" else: "dir") &
        "\n")
      var roots = generationRoots()
      roots.sort()
      stdout.write("generation store roots (" & $roots.len & "):\n")
      for g in roots:
        stdout.write("  " & g & (if g == current: " (current)" else: "") & "\n")
      return 0
    of "selfcheck-btrfs":
      if rest.len != 1:
        raise newException(ValueError, "selfcheck-btrfs needs a btrfs mount point")
      stdout.write(selfcheckBtrfsSubvolume(rest[0]) & "\n")
      return 0
    of "selfcheck-write":
      if rest.len != 1:
        raise newException(ValueError, "selfcheck-write needs a path")
      stdout.write(selfcheckManagedWrite(rest[0]) & "\n")
      return 0
    of "retention":
      var policy = DefaultRetention
      var i = 0
      while i < rest.len:
        let a = rest[i]
        if a == "--keep-generations" or a.startsWith("--keep-generations="):
          policy.keepGenerations = retentionCount(takeValue(rest, i, "--keep-generations"), "--keep-generations")
        elif a == "--keep-days" or a.startsWith("--keep-days="):
          policy.keepDays = retentionCount(takeValue(rest, i, "--keep-days"), "--keep-days")
        else:
          raise newException(ValueError, "unknown option " & a)
        inc i
      let current = readCurrentGenerationId(DefaultStateDir)
      let previous = previousGenerationOf(DefaultStateDir, current)
      let dropped = pruneGenerationRoots(current, previous, policy,
        held = heldGenerations(DefaultStateDir,
          readLedger(ledgerCopyPath(DefaultStateDir)), current))
      stdout.write("kept: " & current & " (current)" &
        (if previous.len > 0: ", " & previous & " (previous)" else: "") & "\n")
      stdout.write("released store roots (" & $dropped.len & "):\n")
      for g in dropped: stdout.write("  " & g & "\n")
      return 0
    else:
      raise newException(ValueError, "unknown command " & cmd)
  except ValueError as e:
    stderr.write("repro system addon: " & e.msg & "\n" & AddonUsage)
    return 2
  except CatchableError as e:
    stderr.write("repro system addon " & cmd & ": " & e.msg & "\n")
    return 1

proc renderAddonSections*(r: AddonApplyResult): string =
  ## The add-on's plan sections (spec §7.1): the ledger diff, the
  ## collision report and the service transition list; after an apply,
  ## the sysctl values observed from the host's namespaces too.
  result = renderLedgerDiff(r) & renderCollisionReport(r.collisions) &
    renderTransitions(r.transitions)
  if r.floorIntroduced.len > 0:
    # Units installed without the floor that it now changes (§10.1): each
    # is in the transition list as a restart too.
    result.add("service floor changed (installed without it, or under an " &
      "older floor version; the unit file changes and the unit " &
      "restarts):\n")
    for u in r.floorIntroduced: result.add("  " & u & "\n")
  if r.floorExceptions.len > 0:
    # Every weakening of the hardening floor, in every plan (§10.1, CONF-2).
    result.add("service floor exceptions:\n")
    for l in r.floorExceptions: result.add("  " & l & "\n")
  if r.baseIdentity.id.len > 0:
    # The base the plan was computed against (§7.4) and, after a
    # distribution upgrade, what changed since the current generation (§7.9).
    result.add("base: " & describeBase(r.baseIdentity) & " (identity " &
      baseIdentityDigest(r.baseIdentity)[0 ..< 16] & ", in the supported " &
      "matrix)\n")
    if r.baseChanges.len > 0:
      result.add("base changed since generation " & r.previousGenerationId &
        " (" & describeBase(r.previousBase) & "):\n")
      for c in r.baseChanges: result.add("  " & c & "\n")
    result.add(renderReleaseUpgradeChecklist(r.baseIdentity))
  if r.storeSpace.len > 0:
    result.add("store space: " & r.storeSpace & "\n")
  if r.closureSources.len > 0:
    result.add("closure members (reuse an older realiser's prefix of the " &
      "same archive, cached archive, or download):\n")
    for l in r.closureSources: result.add("  " & l & "\n")
  if r.planId.len > 0:
    result.add("add-on plan-id: " & r.planId & "\n")
  if r.staticTree.len > 0:
    result.add("static tree: " & r.staticTree & "\n")
  if r.sysctlObserved.len > 0:
    result.add("sysctl observed (host namespaces):\n")
    for (k, v) in r.sysctlObserved:
      result.add("  " & k & "\t" & v & "\n")

proc runAddonStoreCli*(args: seq[string]): int =
  ## ``repro store gc | recover | roots | list`` on the add-on's
  ## system-scope store: the same ``repro_local_store`` collector and
  ## recovery the full engine's ``repro store gc`` and ``repro store
  ## recover`` run (the engine's extra, re-deriving pin roots from project
  ## locks, has nothing to re-derive here: an add-on host has no project
  ## locks). Roots decide what survives; the retention policy keeps the
  ## current and the previous generation's roots whatever is asked, and the
  ## hand-back hold keeps what a preserved record names (spec §5.2, §9).
  if args.len == 0 or args[0] in ["-h", "--help"]:
    stdout.write("usage: repro store gc [--grace-seconds N] | recover | " &
      "roots | list\n")
    return (if args.len == 0: 2 else: 0)
  try:
    # `gc` deletes prefixes no root holds; an apply realising a closure
    # holds no root on it until it commits, so a collection during an apply
    # could delete what that apply is about to bind. `gc` therefore runs
    # under the host-wide apply lock, like every other store writer.
    # `recover` quarantines every prefix without a receipt, so it adopts
    # first, under the same lock, as `gc` does.
    let writes = args[0] in ["gc", "recover"]
    var hostLock: HostApplyLock
    if writes:
      hostLock = acquireHostApplyLock("repro store " & args[0])
    defer: hostLock.release()
    if writes:
      # Adopt and root any closure prefix an older realiser left without a
      # receipt before collecting or recovering, so a closure a retained
      # generation binds is held by that generation's root, and one a
      # preserved record names by the hand-back hold
      # (``migrateLegacyAptClosures``).
      let legacy = migrateLegacyAptClosures(
        handBack = hostHandBackDirs())
      for r in legacy.refused:
        stderr.write("repro store " & args[0] &
          ": legacy apt prefix not adopted: " &
          r.path & ": " & r.reason & "\n")
      for r in legacy.heldUnverified:
        stderr.write("repro store " & args[0] & ": held unverified (a " &
          "file on the host names it): " & r.path & ": " & r.reason & "\n")
    enterWritableStoreView()
    if args[0] == "recover":
      # The store's own recovery (the engine's ``repro store recover``):
      # the staging area swept, every prefix directory reconciled with the
      # index from its receipt, an unreadable index rebuilt.
      if args.len > 1:
        raise newException(ValueError, "unknown option " & args[1])
      # The sweep removes everything under the store's tmp/, where a
      # custody recovery a crash interrupted left the altered object it
      # renamed aside: it is filed as evidence first (A11 review finding
      # 10), never swept with the staging debris.
      fileLeftoverAsides(custodySite("/var/lib/repro/system"))
      let report = recoverStoreRoot(StoreRoot)
      stdout.write("repro store recover: store-root=" & StoreRoot & "\n")
      stdout.write("index rebuilt: " &
        (if report.indexRebuilt: "yes" else: "no") & "\n")
      stdout.write("reinserted: " & $report.reinsertedPrefixes.len & "\n")
      for path in report.reinsertedPrefixes:
        stdout.write("  - " & path & "\n")
      stdout.write("quarantined: " & $report.quarantinedPrefixes.len & "\n")
      for path in report.quarantinedPrefixes:
        stdout.write("  - " & path & "\n")
      return 0
    var s = openStore(StoreRoot)
    defer: s.close()
    case args[0]
    of "gc":
      var grace = DefaultGcGraceSeconds
      var i = 1
      while i < args.len:
        let a = args[i]
        if a == "--grace-seconds" or a.startsWith("--grace-seconds="):
          grace = parseInt(takeValue(args, i, "--grace-seconds"))
        else:
          raise newException(ValueError, "unknown option " & a)
        inc i
      let report = s.gc(graceSeconds = grace)
      stdout.write("repro store gc: store-root=" & StoreRoot & "\n")
      stdout.write("quarantined: " & $report.quarantined.len & "\n")
      for row in report.quarantined:
        stdout.write("  - " & row.adapter & " " & row.packageName & " " &
          row.version & " " & row.realizedPath & "\n")
      stdout.write("reclaimed: " & $report.reclaimed.len & "\n")
      for path in report.reclaimed:
        stdout.write("  - " & path & "\n")
      return 0
    of "roots":
      stdout.write("repro store roots: store-root=" & StoreRoot & "\n")
      for row in s.listRoots():
        stdout.write("  - " & row.rootId & " (" & row.kind & ")\n")
      return 0
    of "list":
      stdout.write("repro store list: store-root=" & StoreRoot & "\n")
      for row in s.listPrefixes():
        stdout.write("  - " & row.adapter & " " & row.packageName & " " &
          row.version & " " & row.realizedPath & "\n")
      return 0
    else:
      raise newException(ValueError, "unknown store command " & args[0])
  except ValueError as e:
    stderr.write("repro store: " & e.msg & "\n")
    return 2
  except CatchableError as e:
    stderr.write("repro store " & args[0] & ": " & e.msg & "\n")
    return 1

proc runAddonGeneration(verb: string; args: seq[string];
                        planOnly: bool; adopt: seq[string] = @[]): int =
  ## The shared body of ``repro infra plan``, ``repro infra apply`` and
  ## ``repro system adopt`` on an add-on host: the profile is the
  ## operator's; the add-on's own objects are added and the ledger is
  ## kept. Exit 2 for a usage error or a refusal decided before anything
  ## was written (scope, a collision, a link on the path), 1 for an apply
  ## that failed or left actionable drift, 0 otherwise.
  var profile = ""
  var reconcile = false
  var retention = none(RetentionPolicy)
  var planId = ""
  var i = 0
  try:
    while i < args.len:
      let a = args[i]
      if a == "--profile" or a.startsWith("--profile="):
        profile = takeValue(args, i, "--profile")
      elif a == "--reconcile-drift" or a == "--accept-drift":
        reconcile = true
      elif a == "--keep-generations" or a.startsWith("--keep-generations="):
        var p = retention.get(DefaultRetention)
        p.keepGenerations = retentionCount(takeValue(args, i, "--keep-generations"), "--keep-generations")
        retention = some(p)
      elif a == "--keep-days" or a.startsWith("--keep-days="):
        var p = retention.get(DefaultRetention)
        p.keepDays = retentionCount(takeValue(args, i, "--keep-days"), "--keep-days")
        retention = some(p)
      elif a == "--plan" or a.startsWith("--plan="):
        planId = takeValue(args, i, "--plan")
      elif a == "--no-preview":
        discard          # an add-on apply always converges without preview
      else:
        raise newException(ValueError, "unknown option " & a)
      inc i
    if profile.len == 0:
      raise newException(ValueError, "--profile <file> is required")
    if not isAddonHost():
      raise newException(ValueError,
        "this host is not an add-on host (no ownership ledger); run " &
        "`repro system addon bootstrap` first")
    let profileText = readFile(profile)
    let r = runAddonApply(AddonApplyOptions(stateDir: DefaultStateDir,
      hostIdentity: readHostname(), userProfileText: profileText,
      reconcileDrift: reconcile, adoptAddresses: adopt, planOnly: planOnly,
      retention: retention, planId: planId))
    stdout.write(renderAddonSections(r))
    if planOnly:
      stdout.write("plan only: nothing was written\n")
      return 0
    stdout.write("generation " & r.generationId & " (previous " &
      r.previousGenerationId & "): applied " & $r.infra.appliedCount &
      ", no-op " & $r.infra.noOpCount & ", removed " & $r.removed.len &
      ", restored " & $r.restored.len & "\n")
    if r.retentionDropped.len > 0:
      stdout.write("retention released the store roots of: " &
        r.retentionDropped.join(", ") & "\n")
    if r.drift.len > 0:
      stderr.write(verb & ": " & $r.drift.len & " object(s) left in " &
        "place as actionable drift\n")
      return 1
    0
  except ValueError as e:
    stderr.write(verb & ": " & e.msg & "\n")
    2
  except EPlanStale as e:
    # Exit 3, as `repro infra apply` does for a stale plain plan.
    stderr.write(verb & ": " & e.msg & "\n")
    for d in e.drifted: stderr.write("  drifted: " & d & "\n")
    3
  except EAddOn as e:
    stderr.write(verb & ": " & e.msg & "\n")
    2
  except AddonCollisionError as e:
    stderr.write(verb & ": " & e.msg & "\n")
    2
  except AddonDriftError as e:
    stderr.write(verb & ": " & e.msg & "\n")
    2
  except ESystemProfileInvalid as e:
    # The profile was refused as written (a non-canonical path, a bad
    # prefix, a malformed stanza) before anything was observed or written.
    stderr.write(verb & ": " & e.msg & "\n")
    2
  except CatchableError as e:
    stderr.write(verb & ": " & e.msg & "\n")
    1

proc noSwapIfSecrets*(): int =
  ## An apply, plan or rollback on a host that keeps sealed envelopes opens
  ## one: it runs where its heap cannot be swapped (spec §10.3).
  if isAddonHost() and hostHasSecrets(): reexecInNoSwapScope() else: -1

proc runMigrationPlanCli*(args: seq[string]): int =
  ## ``repro system addon migration-plan``: the migration's plan, nothing
  ## written (spec §9 "Migration"). Read-only on the host and on the state
  ## directories it is given, so it can run against copies before the
  ## binary that would migrate is installed.
  let reexec = noSwapIfSecrets()
  if reexec >= 0: return reexec
  var stateDir = hostAddonStateDir()
  var agentState = AgentStateDir
  var target = ""
  var legacySecrets = ""
  var i = 0
  try:
    while i < args.len:
      let a = args[i]
      if a == "--legacy-secrets-dir" or a.startsWith("--legacy-secrets-dir="):
        legacySecrets = takeValue(args, i, "--legacy-secrets-dir")
      elif a == "--state-dir" or a.startsWith("--state-dir="):
        stateDir = takeValue(args, i, "--state-dir")
      elif a == "--agent-state" or a.startsWith("--agent-state="):
        agentState = takeValue(args, i, "--agent-state")
      elif a == "--target" or a.startsWith("--target="):
        target = takeValue(args, i, "--target")
      else:
        raise newException(ValueError, "unknown option " & a)
      inc i
  except ValueError as e:
    stderr.write("repro system addon migration-plan: " & e.msg & "\n")
    return 2
  if target.len == 0: target = readHostname()
  const verb = "repro system addon migration-plan"
  if not isAddonHost(stateDir):
    stderr.write(verb & ": " & stateDir & " is not an add-on state " &
      "directory (no ownership ledger)\n")
    return 1
  if anyAgentGeneration(stateDir):
    stdout.write("no migration: an add-on generation of " & stateDir &
      " already carries an agent record\n")
    return 0
  let legacyGen = legacyAgentGeneration(agentState)
  if legacyGen.len == 0:
    stdout.write("no migration: " & agentState & " holds no agent " &
      "generation\n")
    return 0
  stdout.write("migration of agent generation " & legacyGen & " (" &
    agentState & ") into " & stateDir & "\n")
  try:
    let r = planLegacyMigration(stateDir, agentState, target, readHostname(),
                                legacySecretsDir = legacySecrets,
                                probeArchives = true)
    stdout.write(renderAddonSections(r))
    var restarts = 0
    for t in r.transitions:
      if t.verb in {tvRestart, tvStopStart, tvStop}: inc restarts
    stdout.write("units stopped or restarted: " & $restarts & "\n")
    if r.drift.len > 0:
      stdout.write("drift the migration would leave in place:\n")
      for d in r.drift: stdout.write("  " & d & "\n")
    stdout.write("plan only: nothing was written\n")
    0
  except EAddOn, AddonCollisionError, AddonDriftError, AddonApplyError,
      ESystemProfileInvalid:
    let e = getCurrentException()
    stdout.write("the migration would refuse, with nothing written: " &
      e.msg & "\n")
    2
  except CatchableError as e:
    stderr.write(verb & ": " & e.msg & "\n")
    1

proc runAddonInfraApplyCli*(args: seq[string]): int =
  ## ``repro infra apply --profile <canonical text> [--reconcile-drift]``
  ## on an add-on host.
  let r = noSwapIfSecrets()
  if r >= 0: return r
  runAddonGeneration("repro infra apply", args, planOnly = false)

proc runAddonInfraPlanCli*(args: seq[string]): int =
  ## ``repro infra plan --profile <canonical text>`` on an add-on host:
  ## the ledger diff and the collision report, nothing written.
  let r = noSwapIfSecrets()
  if r >= 0: return r
  runAddonGeneration("repro infra plan", args, planOnly = true)

proc runAddonRollbackCli*(args: seq[string]): int =
  ## ``repro system rollback [<generation>] [--reconcile-drift]`` on an
  ## add-on host: re-apply a retained generation through the switch.
  let nr = noSwapIfSecrets()
  if nr >= 0: return nr
  var opts = AddonRollbackOptions(stateDir: DefaultStateDir,
                                  hostIdentity: readHostname())
  for a in args:
    if a == "--reconcile-drift": opts.reconcileDrift = true
    elif a.startsWith("-"):
      stderr.write("repro system rollback: unknown option " & a & "\n")
      return 2
    elif opts.target.len == 0: opts.target = a
    else:
      stderr.write("repro system rollback: unexpected argument " & a & "\n")
      return 2
  try:
    let r = runAddonRollback(opts)
    stdout.write("rolled back from " & r.fromGeneration & " to " &
      r.toGeneration & " (applied as generation " & r.apply.generationId &
      ")\n")
    # The deploy agent only moves forward: a local rollback pauses it
    # until `repro system addon resume` (spec §9.3). The rollback itself
    # paused every agent registered with the add-on (`pausedAgents`);
    # A8's pause covers a configured agent that has not applied yet.
    pauseAfterRollback(r.apply.generationId)
    if r.pausedAgents.len > 0:
      stdout.write("paused the deploy agent of " & r.pausedAgents.join(", ") &
        " (spec §9.3); `repro system addon resume` lets it apply again\n")
    elif fileExists(AgentConfPath):
      stdout.write("the deploy agent is paused (aoPaused) until " &
        "`repro system addon resume`\n")
    0
  except AddonApplyError as e:
    stderr.write("repro system rollback: " & e.msg & "\n")
    1
  except CatchableError as e:
    stderr.write("repro system rollback: " & e.msg & "\n")
    1

proc runAddonAdoptCli*(args: seq[string]): int =
  ## ``repro system adopt <address> --profile <file>`` (spec §11.2 step
  ## 3): the object the resource targets is claimed as it is -- its bytes
  ## become the add-on's, nothing is written to it -- and the generation
  ## that results owns it. Only that resource is taken from the profile;
  ## the generation is otherwise the current one, so no pending change
  ## of the profile is applied on the way (``scopedAdoptProfile``). An
  ## object that cannot be adopted as it is refuses before anything is
  ## written or committed (exit 2).
  var address = ""
  var rest: seq[string]
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--profile":
      # The option and its value go to the shared parser as a pair.
      rest.add(a)
      if i + 1 < args.len:
        inc i
        rest.add(args[i])
    elif a.startsWith("-"): rest.add(a)
    elif address.len == 0: address = a
    else:
      stderr.write("repro system adopt: unexpected argument " & a & "\n")
      return 2
    inc i
  if address.len == 0:
    stderr.write("repro system adopt: <address> is required\n")
    return 2
  let nr = noSwapIfSecrets()
  if nr >= 0: return nr
  runAddonGeneration("repro system adopt", rest, planOnly = false,
                     adopt = @[address])
