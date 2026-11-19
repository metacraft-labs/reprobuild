## Command-line surface of add-on mode, shared by the full ``repro`` engine
## (``repro system addon …``, ``repro system state|secret|adopt …``) and the
## statically linked add-on ``repro`` (which also answers to the name
## ``repro-addon-fingerprint``).
##
## The command line is declared once, in ``repro_infra/addon_command_line``,
## and this module generates its parser, help and completion with clispec
## (``ReproAddonCommandLine``: the static binary's whole command line;
## ``ReproAddonFingerprintTool``: ``repro-addon-fingerprint``'s). Every verb
## below runs from the typed values that parser read; nothing here reads
## argv words. The full engine splices the same declarations into its own
## description, so ``repro system addon --help`` is generated there too, and
## hands the words of the add-on's commands to ``runAddonArgs``, which parses
## them through the parser generated here.
##
## Exit status: 0 success; 1 failure, drift or a non-empty diff; 2 a usage
## error or a refusal decided before anything was written (an incompatible
## host, a plan digest that does not match).

import std/[json, macros, options, os, strutils]

import std/algorithm

import clispec

import repro_core/cli_ast
import repro_core/host_apply_lock
import repro_infra

import repro_infra/addon_diagnostics

import repro_elevation
import repro_elevation/posix_system_driver
import repro_local_store/store as local_store

import ./addon_apply
import repro_infra/addon_command_line
import ./adoption_cli
import ./image_assemble
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
import ./mutations
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
import ./boot_holds
import ./static_tree
import ./store_root
import ./switch
import ./transitions
import ./uninstall
import ./verify

export CliHelpRequest, CliUsageError, cliErrorText

macro addonCommandLinePrograms() =
  ## The static add-on binary's command line and the fingerprint tool's, as
  ## clispec programs over their descriptions.
  result = newStmtList()
  result.add(newCall(ident"cliProgram", ident"ReproAddonCommandLine",
    newLit("repro"), nnkExprEqExpr.newTree(ident"exported", ident"true"),
    unbound(addonProgramDescription())))
  result.add(newCall(ident"cliProgram", ident"ReproAddonFingerprintTool",
    newLit("repro-addon-fingerprint"),
    nnkExprEqExpr.newTree(ident"exported", ident"true"),
    unbound(fingerprintToolDescription())))

addonCommandLinePrograms()

type
  AddonVerb = ReproAddonCommandLineSystemAddonCommand

proc loadAddonCommandLine*(argv: openArray[string];
                           conf: var ReproAddonCommandLine): int =
  ## Parses ``argv`` (the static binary's arguments, without the program
  ## name) with the generated parser into ``conf``. -1 when ``conf`` holds a
  ## command to run; otherwise the command line was answered here and the
  ## result is its exit code: a help or completion request printed on stdout
  ## (0), or a usage error printed as clispec's error block on stderr (2).
  try:
    conf = ReproAddonCommandLine.load(argv)
  except CliHelpRequest as e:
    ReproAddonCommandLine.printHelp(e)
    return 0
  except CliUsageError as e:
    ReproAddonCommandLine.printError(e)
    return e.exitCode
  -1

proc printAddonHelp(path: seq[string]; topic: seq[string]) =
  ## The help a hidden ``help [<word>...]`` subcommand prints: that of the
  ## command ``path & topic`` names, else ``path``'s own.
  for candidate in [path & topic, path]:
    try:
      discard ReproAddonCommandLine.load(candidate & @["--help"])
    except CliHelpRequest as e:
      ReproAddonCommandLine.printHelp(e)
      return
    except CliUsageError:
      discard
  stdout.write(ReproAddonCommandLine.helpText(path, long = true))

proc verbWord(k: AddonVerb): string =
  ## The word of a `repro system addon` verb (``rotateRecipientKey`` is
  ## ``rotate-recipient-key``), for its diagnostics.
  for ch in $k:
    if ch in {'A' .. 'Z'}:
      result.add('-')
      result.add(ch.toLowerAscii)
    else:
      result.add(ch)

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

proc preflightInputsOf[T](c: T): PreflightInputs =
  ## The preflight's inputs from a `preflight` or `bootstrap` command line
  ## (the two declare the same input flags, ``addonPreflightFlags``).
  result = PreflightInputs(deploySignersPath: c.deploySigners,
    cachePublishersPath: c.cachePublishers, cacheUrl: c.cacheUrl,
    agentTarget: c.target, agentSources: c.manifest,
    profileCompiler: c.profileCompiler,
    agentPollSec: c.pollInterval.get(0),
    evidenceSink: c.evidenceSink, evidenceSinkCaPath: c.evidenceSinkCa,
    evidenceHeartbeatSec: c.heartbeatInterval.get(0),
    deferRecipientKey: c.deferRecipientKey)

proc bootstrapOptionsOf[T](c: T; planDigest = ""): BootstrapOptions =
  ## A bootstrap's options from the same input flags, and the plan digest.
  let inp = preflightInputsOf(c)
  BootstrapOptions(planDigest: planDigest,
    deploySignersPath: inp.deploySignersPath,
    cachePublishersPath: inp.cachePublishersPath, cacheUrl: inp.cacheUrl,
    agentTarget: inp.agentTarget, agentSources: inp.agentSources,
    profileCompiler: inp.profileCompiler, agentPollSec: inp.agentPollSec,
    evidenceSink: inp.evidenceSink,
    evidenceSinkCaPath: inp.evidenceSinkCaPath,
    evidenceHeartbeatSec: inp.evidenceHeartbeatSec,
    deferRecipientKey: inp.deferRecipientKey)

proc loadPreflightFlags*(flags: seq[string]): ReproAddonCommandLineSystemAddonPreflight =
  ## ``flags`` (the input flags of a preflight, as an image's assembly
  ## payload records them) read by the generated parser as `repro system
  ## addon preflight` would; raises ``ValueError`` when they are not such a
  ## command line.
  var conf: ReproAddonCommandLine
  try:
    conf = ReproAddonCommandLine.load(@["system", "addon", "preflight"] &
      flags)
  except CliHelpRequest:
    raise newException(ValueError, "the payload's preflight flags ask for " &
      "help: " & flags.join(" "))
  except CliUsageError as e:
    raise newException(ValueError, "the payload's preflight flags are not " &
      "a preflight command line: " & cliErrorText(e).strip())
  conf.system.addon.preflight

proc runFingerprintCommand*(root: string; live: bool; outPath: string): int =
  ## ``repro system addon fingerprint [--root R] [--no-live] [--out F]``:
  ## record the base fingerprint.
  try:
    let text = collectFingerprint(CollectOptions(root: root, live: live)).render()
    if outPath.len > 0:
      writeFile(outPath, text)
    else:
      stdout.write(text)
    0
  except CatchableError as e:
    stderr.write("repro-addon-fingerprint: " & e.msg & "\n")
    1

proc runFingerprintDiff*(before, after: string; exceptRules: seq[string];
                         expectPath: string): int =
  ## ``repro system addon fingerprint diff <before> <after> [--except
  ## C:GLOB]... [--expect F]``: exit 0 when the diff is empty (or equals the
  ## expectation), 1 otherwise, 2 for a malformed rule.
  var rules: seq[ExceptionRule]
  try:
    for r in exceptRules: rules.add(parseExceptionRule(r))
  except ValueError as e:
    stderr.write("repro-addon-fingerprint: " & e.msg & "\n")
    return 2
  try:
    let d = applyExceptions(
      diff(parseFingerprint(readFile(before)),
           parseFingerprint(readFile(after))), rules)
    if expectPath.len > 0:
      let report = matchExpectations(d, parseExpectations(readFile(expectPath)))
      if report.ok:
        stdout.write("fingerprint diff equals the expectation (" &
                     $d.len & " records)\n")
        return 0
      stdout.write(renderExpectationReport(report))
      return 1
    stdout.write(renderDiff(d))
    (if d.len == 0: 0 else: 1)
  except CatchableError as e:
    stderr.write("repro-addon-fingerprint: " & e.msg & "\n")
    1

proc runFingerprintToolArgs*(argv: seq[string]): int =
  ## The static binary invoked as ``repro-addon-fingerprint``: its own
  ## command line (``fingerprintToolDescription``), through its generated
  ## parser.
  var conf: ReproAddonFingerprintTool
  try:
    conf = ReproAddonFingerprintTool.load(argv)
  except CliHelpRequest as e:
    ReproAddonFingerprintTool.printHelp(e)
    return 0
  except CliUsageError as e:
    ReproAddonFingerprintTool.printError(e)
    return e.exitCode
  case conf.command
  of ReproAddonFingerprintToolCommand.call:
    runFingerprintCommand(conf.call.root, not conf.call.noLive,
      conf.call.outPath)
  of ReproAddonFingerprintToolCommand.diff:
    runFingerprintDiff(conf.diff.before, conf.diff.after,
      conf.diff.exceptRule, conf.diff.expect)

proc previousGenerationOf*(stateDir, current: string): string =
  ## The generation `current` succeeded (its envelope's predecessor), ""
  ## for generation 0.
  if current.len == 0: return ""
  try:
    readGenerationEnvelope(pointerPath(stateDir, current)).previousGenerationId
  except CatchableError:
    ""

proc retentionCount(value: Option[int]; flag: string; default: int): int =
  ## A retention bound: a non-negative integer (0 keeps only what is
  ## always kept); ``default`` when the flag was not given.
  if value.isNone: return default
  result = value.get
  if result < 0:
    raise newException(ValueError, flag &
      " expects a non-negative integer, got " & $result)

proc retentionOf(keepGenerations, keepDays: Option[int]):
    Option[RetentionPolicy] =
  ## The retention policy the flags ask for; none when neither was given.
  if keepGenerations.isNone and keepDays.isNone: return
  some(RetentionPolicy(
    keepGenerations: retentionCount(keepGenerations, "--keep-generations",
      DefaultRetention.keepGenerations),
    keepDays: retentionCount(keepDays, "--keep-days",
      DefaultRetention.keepDays)))

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

proc runMigrationPlanCommand*(stateDir, agentState, target,
                              legacySecretsDir: string): int
  ## Below, beside the other plan verbs.

proc renderCompletedDiscard*(keyHex: string; removed, kept: seq[string]): string =
  ## The operator-facing verdict of a completed discard (§13 decisions 64
  ## and 81): the objects removed are "discarded unshipped", those the
  ## completion records as kept with the store (``--keep-store``) are named
  ## as kept, never as discarded.
  # Round 10: with objects kept, the verdict names them first -- a plain
  # "completed:" would read as every object gone.
  let head = if kept.len > 0:
      "completed with " & $kept.len & " object(s) kept with the store " &
        "(--keep-store), not discarded"
    else: "completed"
  result = head & ": the intent record and its completion are signed by " &
    keyHex & " over exactly their bytes; " & $removed.len &
    " object(s) discarded unshipped:\n"
  for o in removed: result.add("  " & o & "\n")
  if kept.len > 0:
    result.add($kept.len & " object(s) kept with the store (--keep-store), " &
      "not discarded:\n")
    for o in kept: result.add("  " & o & "\n")

proc discardReport*(r: UninstallResult): string =
  ## What ``uninstall`` prints about a discard of store evidence: the intent
  ## it authorised, or the earlier one it completed (§13 decisions 62, 81
  ## and 148), whether the discard completed, and how to verify it (§13
  ## decision 162).
  if r.overrideRecord.len > 0 and r.resumedIntent:
    # §13 decision 148: an earlier run's intent, carrying its discard
    # marker; this run authorised nothing, so it never says it did.
    result.add("completing the discard an earlier uninstall " &
      "authorised and carried out (its discard marker " &
      discardMarkerPath(custodySite(DefaultStateDir), r.overrideRecord) &
      " is valid); its signed intent record is " & r.overrideRecord & "\n")
    if r.completionRecord.len > 0:
      result.add("the discard completed; the signed completion " &
        "record is " & r.completionRecord & " (signature " &
        r.completionRecord & DiscardRecordSigExt & ")\n")
    else:
      result.add("the discard did NOT complete: there is no " &
        "completion record\n")
    # §13 decision 162: the same verify hint a plain run prints.
    result.add("check it with `repro system addon " &
      "verify-discard-record " & r.overrideRecord &
      " --key <enrolled key>`\n")
  elif r.overrideRecord.len > 0:
    # §13 decisions 62 and 64: the record of what was discarded
    # unshipped, its signature beside it.
    result.add("discarding store evidence the Evidence sink has " &
      "not acknowledged was authorised; the signed intent record is " &
      r.overrideRecord & " (signature " & r.overrideRecord &
      DiscardRecordSigExt & "):\n" & r.overrideRecordText)
    if r.completionRecord.len > 0:
      result.add("the discard completed; the signed completion " &
        "record is " & r.completionRecord & " (signature " &
        r.completionRecord & DiscardRecordSigExt & ")\n")
    else:
      result.add("the discard did NOT complete: there is no " &
        "completion record\n")
    result.add("check it with `repro system addon " &
      "verify-discard-record " & r.overrideRecord &
      " --key <enrolled key>`\n")

proc runImageAssemble(payload: string): int =
  ## ``repro system addon image-assemble --payload <dir>``.
  if payload.len == 0:
    raise newException(ValueError, "--payload <dir> is required")
  let spec = parseAssemblySpec(readFile(payload / "assembly.json"))
  # The payload's binary is this one: refuse a payload staged for
  # another (the build host pinned it by digest).
  let self = sha256OfFile(getAppFilename())
  if self != spec.binarySha256:
    raise newException(ValueError, "this binary hashes to " & self &
      ", but the payload was staged for " & spec.binarySha256)
  let flags = loadPreflightFlags(spec.preflightFlags)
  let r = runImageAssembly(payload, spec, preflightInputsOf(flags),
    bootstrapOptionsOf(flags))
  (if r.ok: 0 else: 1)

proc runAddonStateVerb[T](s: T; path: seq[string]): int =
  ## A `state` verb, from the configuration of `repro system addon state`
  ## or of `repro system state` (the static binary declares both, over the
  ## same declarations, ``addonStateCommands``); ``path`` is the command's,
  ## for its hidden `help`.
  type V = typeof(s.command)
  case s.command
  of V.help:
    printAddonHelp(path, s.help.topic)
    0
  of V.backup:
    runStateCommand(StateCommand(verb: "backup", profile: s.backup.profile,
      outDir: s.backup.outDir, root: s.backup.root))
  of V.release:
    runStateCommand(StateCommand(verb: "release",
      profile: s.release.profile))
  of V.verify:
    runStateCommand(StateCommand(verb: "verify", fromDir: s.verify.fromDir,
      root: s.verify.root, only: s.verify.only, source: s.verify.source))
  of V.restore:
    runStateCommand(StateCommand(verb: "restore",
      fromDir: s.restore.fromDir, root: s.restore.root,
      boot: s.restore.boot))
  of V.digest:
    runStateCommand(StateCommand(verb: "digest", path: s.digest.path))
  of V.unit:
    runStateCommand(StateCommand(verb: "unit"))
  of V.installUnit:
    runStateCommand(StateCommand(verb: "install-unit",
      fromDir: s.installUnit.fromDir, root: s.installUnit.root))

proc runAddonVerb*(c: ReproAddonCommandLineSystemAddon): int =
  ## ``repro system addon <verb> ...``, from the configuration the generated
  ## parser read.
  let cmd = verbWord(c.command)
  # The verbs that hold plaintext secrets run where their heap cannot be
  # swapped (spec §10.3): `secret`, `rotate-recipient-key` and `agent-tick`
  # always, the re-assert and secrets verbs on a host that keeps envelopes
  # (their boot units carry MemorySwapMax=0 themselves).
  let atBootVerb = case c.command
    of AddonVerb.reassert: c.reassert.boot
    of AddonVerb.secrets: c.secrets.boot
    else: false
  if c.command in {AddonVerb.secret, AddonVerb.rotateRecipientKey,
                   AddonVerb.agentTick, AddonVerb.agentApply} or
      (c.command in {AddonVerb.reassert, AddonVerb.recover,
                     AddonVerb.secrets} and not atBootVerb and
       hostHasSecrets()):
    let r = reexecInNoSwapScope()
    if r >= 0: return r
  try:
    case c.command
    of AddonVerb.help:
      printAddonHelp(@["system", "addon"], c.help.topic)
      return 0
    of AddonVerb.fingerprint:
      let f = c.fingerprint
      case f.command
      of ReproAddonCommandLineSystemAddonFingerprintCommand.call:
        return runFingerprintCommand(f.call.root, not f.call.noLive,
          f.call.outPath)
      of ReproAddonCommandLineSystemAddonFingerprintCommand.diff:
        return runFingerprintDiff(f.diff.before, f.diff.after,
          f.diff.exceptRule, f.diff.expect)
    of AddonVerb.`import`:
      return runAddonImport(c.`import`.unit)
    of AddonVerb.state:
      return runAddonStateVerb(c.state, @["system", "addon", "state"])
    of AddonVerb.preflight:
      let r = runPreflight(preflightInputsOf(c.preflight))
      if c.preflight.json:
        stdout.write(r.planJson & "\n")
      else:
        stdout.write(renderPreflightHuman(r))
      return (if r.compatible: 0 else: 2)
    of AddonVerb.bootstrap:
      let opts = bootstrapOptionsOf(c.bootstrap, c.bootstrap.plan)
      try:
        let r = runAddonBootstrap(opts)
        stdout.write("plan digest:          " & r.planDigest & "\n" &
                     "generation:           " & r.generationId & "\n" &
                     "add-on binary:        " & r.reproExe & "\n" &
                     "binary sha256:        " & r.binarySha256 & "\n" &
                     "recipient public key: " &
                       (if opts.deferRecipientKey:
                          "deferred: the host creates its own at its next boot"
                        else: r.recipientPublicKeyHex) & "\n")
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
    of AddonVerb.verifyDiscardRecord:
      let path = c.verifyDiscardRecord.record
      let key = c.verifyDiscardRecord.key
      # The key is required (§13 decision 64, amended round 6): a record
      # checked only against the key it names itself is not authenticated.
      if key.len == 0 and not mutated("verify-accepts-missing-key"):
        stderr.write("repro system addon verify-discard-record: --key HEX " &
          "is required (HEX: the host's enrolled attestation key)\n")
        return 2
      let v = verifyDiscardRecord(path, key)
      case v.status
      of dsInvalid:
        stderr.write("repro system addon verify-discard-record: " & path &
                     " does not verify: " & v.why & "\n")
        return 1
      of dsAuthorised:
        # §13 decision 81: never a discard that did not finish.
        stdout.write("authorised, not completed: the intent record is " &
                     "signed by " & v.keyHex & " over exactly its bytes, " &
                     "but " & v.why & "; " & $v.objects.len &
                     " object(s) were to be discarded unshipped:\n")
        for o in v.objects: stdout.write("  " & o & "\n")
        return 3
      of dsCompleted, dsCompletedKept:
        stdout.write(renderCompletedDiscard(v.keyHex, v.removed, v.kept))
        # Round 9: an object kept with the store (--keep-store) is still on
        # the host; it was not discarded, and the exit status says so too.
        if v.kept.len > 0: return 4
        return 0
    of AddonVerb.uninstall:
      let u = c.uninstall
      let r = runAddonUninstall(UninstallOptions(keepStore: u.keepStore,
        discardStoreEvidence: u.discardStoreEvidence,
        discardUnacknowledgedStoreEvidence:
          u.discardUnacknowledgedStoreEvidence))
      stdout.write(discardReport(r))
      for p in r.removed: stdout.write("removed " & p & "\n")
      for d in r.drift: stdout.write("left in place (drift): " & d & "\n")
      for n in r.notes: stdout.write("note: " & n & "\n")
      for k in r.keptEvidence:
        stdout.write("kept with the store (store evidence left aside): " &
                     k & "\n")
      for e in r.errors: stderr.write("error: " & e & "\n")
      stdout.write("accounts kept: " &
        (if r.keptAccounts.len == 0: "none" else: r.keptAccounts.join(", ")) &
        "\n")
      return (if r.ok: 0 else: 1)
    of AddonVerb.verify:
      if c.verify.afterDpkg:
        # The apt hook (spec §7.8): ledger digests, new package owners of
        # ledger paths, changed vendor units; recorded, always exit 0.
        return runAfterDpkgCli()
      if c.verify.boot:
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
    of AddonVerb.reassert, AddonVerb.recover:
      let atBoot = c.command == AddonVerb.reassert and c.reassert.boot
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
        # The holds the boot-hold unit wrote are lifted once the pending
        # switch is resolved (§13 decision 159); a switch still pending
        # keeps them.
        try:
          for l in releaseBootHolds(DefaultStateDir,
                                    reload = proc () = daemonReload()):
            stdout.write("repro-addon boot-holds: " & l & "\n")
        except CatchableError as e:
          stdout.write("repro-addon boot-holds: " & e.msg & "\n")
        # A host bootstrapped before the shipping path unit's fix (the drill's
        # D1) is migrated by one switch rather than waiting for its next
        # generation (A11 review finding 8). That switch confirms its
        # health checks, which a floored unit cannot pass while this unit
        # runs (§13 decision 157): where the boot-confirm unit is installed,
        # it migrates instead, after this unit.
        if not fileExists(unitPath(BootConfirmUnit)):
          try:
            let m = migrateStaleOwnObjects(DefaultStateDir, atBoot = true)
            if m.len > 0: stdout.write(m & "\n")
          except CatchableError as e:
            stdout.write("repro-addon migration: " & e.msg & "\n")
        return 0
      let r = runAddonReassert(DefaultStateDir, atBoot = false)
      stdout.write(renderReassert(r))
      return (if r.status in ["ok", "drift", "deferred"]: 0 else: 1)
    of AddonVerb.bootConfirm:
      # `repro system addon boot-confirm` (repro-addon-boot-confirm.service,
      # §13 decision 157): after the re-assertion, replay the pending switch
      # it left here -- with queued starts and the confirm, now that the
      # floored units can start -- then lift the boot's holds and migrate
      # stale generation-0 objects. Never fails the boot transaction.
      let flag = bootConfirmFlagPath(DefaultStateDir)
      if fileExists(flag):
        try:
          stdout.write(renderReassert(runAddonReassert(DefaultStateDir,
            atBoot = true, bootConfirm = true)))
        except CatchableError as e:
          stdout.write("repro-addon reassert: degraded\n  " & e.msg & "\n")
        try: removeFile(flag)
        except OSError: discard
        try:
          for l in releaseBootHolds(DefaultStateDir,
                                    reload = proc () = daemonReload()):
            stdout.write("repro-addon boot-holds: " & l & "\n")
        except CatchableError as e:
          stdout.write("repro-addon boot-holds: " & e.msg & "\n")
      else:
        stdout.write("repro-addon boot-confirm: nothing was left to confirm\n")
      try:
        let m = migrateStaleOwnObjects(DefaultStateDir, atBoot = true)
        if m.len > 0: stdout.write(m & "\n")
      except CatchableError as e:
        stdout.write("repro-addon migration: " & e.msg & "\n")
      return 0
    of AddonVerb.secrets:
      # `repro system addon secrets [--boot]`: re-materialise the current
      # generation's secrets (repro-addon-secrets.service at boot, §7.7).
      let r = bootSecrets(DefaultStateDir)
      stdout.write("repro-addon secrets: " & r.line & "\n")
      return (if c.secrets.boot or r.ok: 0 else: 1)
    of AddonVerb.secret:
      case c.secret.command
      of ReproAddonCommandLineSystemAddonSecretCommand.put:
        let p = c.secret.put
        return runSecretPutCommand(p.service, p.name, p.target)
    of AddonVerb.imageAssemble:
      return runImageAssemble(c.imageAssemble.payload)
    of AddonVerb.rotateRecipientKey:
      return runRotateRecipientKeyCommand()
    of AddonVerb.evidenceShip:
      return runEvidenceShipCommand(c.evidenceShip.heartbeat,
        c.evidenceShip.noBackoff)
    of AddonVerb.evidenceHarvest:
      return runEvidenceHarvestCommand()
    of AddonVerb.evidenceCredentialCheck:
      return runCredentialCheckCommand()
    of AddonVerb.evidenceEnrol:
      let e = c.evidenceEnrol
      return runEvidenceEnrolCommand(e.rekey, e.noHandover,
        EnrolOptions(sink: e.evidenceSink, sinkCaPath: e.evidenceSinkCa,
          heartbeatSec: e.heartbeatInterval.get(0)))
    of AddonVerb.egressCheck:
      return runEgressCheckCommand()
    of AddonVerb.storeVerify:
      return runStoreVerifyCommand(c.storeVerify.background,
        c.storeVerify.adoptUnverified)
    of AddonVerb.agentTick:
      let t = c.agentTick
      return agent_split.runAgentTickCommand(t.source, t.target,
        t.allowedSigners)
    of AddonVerb.agentFetch:
      return runAgentFetchCommand()
    of AddonVerb.agentApply:
      return runAgentApplyCommand()
    of AddonVerb.resume:
      return runResumeCommand()
    of AddonVerb.migrate:
      let m = migrateStaleOwnObjects(DefaultStateDir)
      stdout.write((if m.len > 0: m else: "generation 0 is current; nothing " &
        "to migrate") & "\n")
      return 0
    of AddonVerb.contain:
      return runContainCommand(c.contain.operator, c.contain.reason)
    of AddonVerb.release:
      return runContainCommand(c.release.operator, c.release.reason,
        release = true)
    of AddonVerb.agentRepin:
      return runAgentRepin(c.agentRepin.apply)
    of AddonVerb.migrationPlan:
      let m = c.migrationPlan
      return runMigrationPlanCommand(m.stateDir, m.agentState, m.target,
        m.legacySecretsDir)
    of AddonVerb.probe:
      let check = c.probe.healthCheck
      let spec = parseHealthCheck(check)
      if spec.kind notin {hcTcp, hcHttp}:
        raise newException(ValueError, "probe runs tcp: and http:// checks only")
      let why = runProbe(spec)
      if why.len == 0:
        stdout.write("probe " & check & ": ok\n")
        return 0
      stdout.write("probe " & check & ": " & why & "\n")
      return 1
    of AddonVerb.expectedDelta:
      let d = c.expectedDelta
      let before = if d.before == "-": Ledger() else: readLedger(d.before)
      let after = readLedger(d.after)
      for e in expectedDelta(before, after):
        stdout.write(renderExpectation(e) & "\n")
      return 0
    of AddonVerb.ledger:
      stdout.write(readLedger(ledgerCopyPath(DefaultStateDir)).render())
      return 0
    of AddonVerb.status:
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
    of AddonVerb.selfcheckBtrfs:
      stdout.write(selfcheckBtrfsSubvolume(c.selfcheckBtrfs.mountPoint) & "\n")
      return 0
    of AddonVerb.selfcheckWrite:
      stdout.write(selfcheckManagedWrite(c.selfcheckWrite.path) & "\n")
      return 0
    of AddonVerb.retention:
      let policy = retentionOf(c.retention.keepGenerations,
        c.retention.keepDays).get(DefaultRetention)
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
    of AddonVerb.testSleep:
      # Declared by the static binary only; it sleeps in a seam build
      # (`-d:reproAddonTestSeams`) and is refused in any other.
      if not AddonTestSeams:
        stderr.write("repro system addon test-sleep: only a test-seam " &
          "build runs it\n")
      return seamSleepCommand(c.testSleep.seconds)
  except ValueError as e:
    stderr.write("repro system addon " & cmd & ": " & e.msg & "\n")
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
  if r.floorWeakened.len > 0:
    # Units whose confinement the generation weakens (§10.1): an agent
    # apply refuses them, so the operator's plan names them apart.
    result.add("service floor weakened (a new waiver, a new exception or " &
      "a waived unit on a privileged account; only an operator's apply " &
      "makes it):\n")
    for u in r.floorWeakened: result.add("  " & u & "\n")
  if r.floorExceptions.len > 0:
    # Every weakening of the hardening floor, in every plan (§10.1, CONF-2).
    result.add("service floor exceptions:\n")
    for l in r.floorExceptions: result.add("  " & l & "\n")
  if r.liveJudged.len > 0:
    # What the carried-state live check read from systemd (§11.1).
    result.add("carried-state live check judged:\n")
    for u in r.liveJudged: result.add("  " & u & "\n")
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

proc addonSectionsJson*(r: AddonApplyResult): JsonNode =
  ## The add-on's plan sections as ``renderAddonSections`` prints them, one
  ## key per section, for ``repro infra|system plan --json``
  ## (CLI-UX-AREQ4; spec/CLI/infra/plan.md §JSON output). Nothing here is
  ## rendered text a consumer has to parse back: each record of a text
  ## section is an object or a string of its own.
  var ledgerDiff = newJArray()
  for line in r.ledgerDiff:
    # ``<verb>\t<target>\t<detail>`` (``AddonApplyResult.ledgerDiff``);
    # the detail is the resource address, or for ``drop-groups`` the
    # dropped groups, with any parenthetical note the record carries.
    let f = line.split('\t', maxsplit = 2)
    ledgerDiff.add(%*{"verb": f[0],
      "target": (if f.len > 1: f[1] else: ""),
      "detail": (if f.len > 2: f[2] else: "")})
  var collisions = newJArray()
  for l in r.collisions:
    collisions.add(%*{"verdict": l.verdict, "target": l.target,
      "observation": l.observation, "address": l.address,
      "reason": l.reason})
  var transitions = newJArray()
  for t in r.transitions:
    transitions.add(%*{"verb": $t.verb, "unit": t.unit, "reason": t.reason,
      "exclusive": t.exclusive})
  var base = newJNull()
  if r.baseIdentity.id.len > 0:
    var coupled = newJArray()
    for c in r.baseIdentity.coupled:
      coupled.add(%*{"unit": c.unit, "reason": c.reason})
    base = %*{"description": describeBase(r.baseIdentity),
      "id": r.baseIdentity.id, "versionId": r.baseIdentity.versionId,
      "versionCodename": r.baseIdentity.versionCodename,
      "architecture": r.baseIdentity.architecture,
      "identityDigest": baseIdentityDigest(r.baseIdentity),
      "changes": r.baseChanges,
      "previousGenerationId":
        (if r.baseChanges.len > 0: r.previousGenerationId else: ""),
      "previousDescription":
        (if r.baseChanges.len > 0: describeBase(r.previousBase) else: ""),
      "baseCoupled": coupled}
  var sysctl = newJArray()
  for (k, v) in r.sysctlObserved:
    sysctl.add(%*{"key": k, "value": v})
  result = %*{"planId": r.planId, "ledgerDiff": ledgerDiff,
    "unlisted": r.unlisted, "drift": r.drift, "collisions": collisions,
    "transitions": transitions, "floorIntroduced": r.floorIntroduced,
    "floorWeakened": r.floorWeakened, "floorExceptions": r.floorExceptions,
    "liveJudged": r.liveJudged, "base": base, "storeSpace": r.storeSpace,
    "closureSources": r.closureSources, "staticTree": r.staticTree,
    "sysctlObserved": sysctl}

proc runAddonStoreCommand*(c: ReproAddonCommandLineStore): int =
  ## ``repro store gc | recover | roots | list`` on the add-on's
  ## system-scope store: the same ``repro_local_store`` collector and
  ## recovery the full engine's ``repro store gc`` and ``repro store
  ## recover`` run (the engine's extra, re-deriving pin roots from project
  ## locks, has nothing to re-derive here: an add-on host has no project
  ## locks). Roots decide what survives; the retention policy keeps the
  ## current and the previous generation's roots whatever is asked, and the
  ## hand-back hold keeps what a preserved record names (spec §5.2, §9).
  type StoreVerb = ReproAddonCommandLineStoreCommand
  let verb = case c.command
    of StoreVerb.gc: "gc"
    of StoreVerb.recover: "recover"
    of StoreVerb.roots: "roots"
    of StoreVerb.list: "list"
  try:
    # `gc` deletes prefixes no root holds; an apply realising a closure
    # holds no root on it until it commits, so a collection during an apply
    # could delete what that apply is about to bind. `gc` therefore runs
    # under the host-wide apply lock, like every other store writer.
    # `recover` quarantines every prefix without a receipt, so it adopts
    # first, under the same lock, as `gc` does.
    let writes = c.command in {StoreVerb.gc, StoreVerb.recover}
    var hostLock: HostApplyLock
    if writes:
      hostLock = acquireHostApplyLock("repro store " & verb)
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
        stderr.write("repro store " & verb &
          ": legacy apt prefix not adopted: " &
          r.path & ": " & r.reason & "\n")
      for r in legacy.heldUnverified:
        stderr.write("repro store " & verb & ": held unverified (a " &
          "file on the host names it): " & r.path & ": " & r.reason & "\n")
    enterWritableStoreView()
    if c.command == StoreVerb.recover:
      # The store's own recovery (the engine's ``repro store recover``):
      # the staging area swept, every prefix directory reconciled with the
      # index from its receipt, an unreadable index rebuilt.
      #
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
    case c.command
    of StoreVerb.gc:
      let report = s.gc(graceSeconds = c.gc.graceSeconds.get(
        DefaultGcGraceSeconds))
      stdout.write("repro store gc: store-root=" & StoreRoot & "\n")
      stdout.write("quarantined: " & $report.quarantined.len & "\n")
      for row in report.quarantined:
        stdout.write("  - " & row.adapter & " " & row.packageName & " " &
          row.version & " " & row.realizedPath & "\n")
      stdout.write("reclaimed: " & $report.reclaimed.len & "\n")
      for path in report.reclaimed:
        stdout.write("  - " & path & "\n")
      return 0
    of StoreVerb.roots:
      stdout.write("repro store roots: store-root=" & StoreRoot & "\n")
      for row in s.listRoots():
        stdout.write("  - " & row.rootId & " (" & row.kind & ")\n")
      return 0
    of StoreVerb.list:
      stdout.write("repro store list: store-root=" & StoreRoot & "\n")
      for row in s.listPrefixes():
        stdout.write("  - " & row.adapter & " " & row.packageName & " " &
          row.version & " " & row.realizedPath & "\n")
      return 0
    of StoreVerb.recover:
      return 0  # answered above
  except ValueError as e:
    stderr.write("repro store: " & e.msg & "\n")
    return 2
  except CatchableError as e:
    stderr.write("repro store " & verb & ": " & e.msg & "\n")
    return 1

proc runAddonGeneration[T](verb: string; c: T; planOnly: bool;
                           adopt: seq[string] = @[]): int =
  ## The shared body of ``repro infra plan``, ``repro infra apply`` and
  ## ``repro system adopt`` on an add-on host, from a command line that
  ## declares the generation flags (``addonGenerationFlags``): the profile is
  ## the operator's; the add-on's own objects are added and the ledger is
  ## kept. Exit 2 for a usage error or a refusal decided before anything
  ## was written (scope, a collision, a link on the path), 1 for an apply
  ## that failed or left actionable drift, 0 otherwise. ``--no-preview`` is
  ## accepted and changes nothing: an add-on apply always converges without
  ## a preview.
  try:
    if c.profile.len == 0:
      raise newException(ValueError, "--profile <file> is required")
    let retention = retentionOf(c.keepGenerations, c.keepDays)
    if not isAddonHost():
      raise newException(ValueError,
        "this host is not an add-on host (no ownership ledger); run " &
        "`repro system addon bootstrap` first")
    let profileText = readFile(c.profile)
    let r = runAddonApply(AddonApplyOptions(stateDir: DefaultStateDir,
      hostIdentity: readHostname(), userProfileText: profileText,
      reconcileDrift: c.reconcileDrift, adoptAddresses: adopt,
      planOnly: planOnly, retention: retention, planId: c.plan))
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

proc runMigrationPlanCommand*(stateDir, agentState, target,
                              legacySecretsDir: string): int =
  ## ``repro system addon migration-plan``: the migration's plan, nothing
  ## written (spec §9 "Migration"). Read-only on the host and on the state
  ## directories it is given, so it can run against copies before the
  ## binary that would migrate is installed. Each empty value takes its
  ## default: the host's add-on and agent state directories, this host.
  let reexec = noSwapIfSecrets()
  if reexec >= 0: return reexec
  let stateDir = if stateDir.len > 0: stateDir else: hostAddonStateDir()
  let agentState = if agentState.len > 0: agentState else: AgentStateDir
  let target = if target.len > 0: target else: readHostname()
  let legacySecrets = legacySecretsDir
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

proc runAddonInfraCommand*(c: ReproAddonCommandLineInfra): int =
  ## ``repro infra plan|apply --profile <canonical text> [--reconcile-drift]
  ## ...`` on an add-on host: the ledger diff and the collision report,
  ## nothing written (`plan`), or an add-on generation (`apply`).
  let r = noSwapIfSecrets()
  if r >= 0: return r
  case c.command
  of ReproAddonCommandLineInfraCommand.plan:
    runAddonGeneration("repro infra plan", c.plan, planOnly = true)
  of ReproAddonCommandLineInfraCommand.apply:
    runAddonGeneration("repro infra apply", c.apply, planOnly = false)

proc runAddonRollbackCommand*(target: string; reconcileDrift: bool): int

proc runAddonRollbackCommand*(target: string; reconcileDrift: bool): int =
  ## Re-apply the retained generation ``target`` (default: the previous
  ## one) through the add-on switch; ``reconcileDrift`` replaces drifted
  ## objects. The command a full engine's ``repro system rollback`` runs on
  ## an add-on host, with its command line already read.
  let nr = noSwapIfSecrets()
  if nr >= 0: return nr
  var opts = AddonRollbackOptions(stateDir: DefaultStateDir,
                                  hostIdentity: readHostname(),
                                  target: target,
                                  reconcileDrift: reconcileDrift)
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

proc runAddonAdoptCommand*(c: ReproAddonCommandLineSystemAdopt): int =
  ## ``repro system adopt <address> --profile <file>`` (spec §11.2 step
  ## 3): the object the resource targets is claimed as it is -- its bytes
  ## become the add-on's, nothing is written to it -- and the generation
  ## that results owns it. Only that resource is taken from the profile;
  ## the generation is otherwise the current one, so no pending change
  ## of the profile is applied on the way (``scopedAdoptProfile``). An
  ## object that cannot be adopted as it is refuses before anything is
  ## written or committed (exit 2).
  let nr = noSwapIfSecrets()
  if nr >= 0: return nr
  runAddonGeneration("repro system adopt", c, planOnly = false,
                     adopt = @[c.address])

proc runAddonCommandLine*(conf: ReproAddonCommandLine;
                          version = ""): int =
  ## The static add-on binary's command line, from the configuration the
  ## generated parser read (``loadAddonCommandLine``). ``version`` is the
  ## line ``--version`` and ``version`` print.
  case conf.command
  of ReproAddonCommandLineCommand.call:
    if conf.call.version:
      echo version
      return 0
    # Bare `repro`: no command was given, which is a usage error.
    stderr.write(ReproAddonCommandLine.helpText([]))
    return 2
  of ReproAddonCommandLineCommand.version:
    echo version
    return 0
  of ReproAddonCommandLineCommand.system:
    let s = conf.system
    case s.command
    of ReproAddonCommandLineSystemCommand.addon:
      return runAddonVerb(s.addon)
    of ReproAddonCommandLineSystemCommand.state:
      # What the first-boot restore unit this binary writes runs.
      return runAddonStateVerb(s.state, @["system", "state"])
    of ReproAddonCommandLineSystemCommand.adopt:
      return runAddonAdoptCommand(s.adopt)
    of ReproAddonCommandLineSystemCommand.rollback:
      return runAddonRollbackCommand(s.rollback.generation,
        s.rollback.reconcileDrift)
  of ReproAddonCommandLineCommand.infra:
    return runAddonInfraCommand(conf.infra)
  of ReproAddonCommandLineCommand.store:
    return runAddonStoreCommand(conf.store)

proc runAddonArgs*(argv: seq[string]; version = ""): int =
  ## ``argv`` (the static binary's arguments, or the words the full engine
  ## hands over: ``system addon …``, ``system adopt …``) parsed by the
  ## generated parser and run.
  var conf: ReproAddonCommandLine
  result = loadAddonCommandLine(argv, conf)
  if result < 0:
    result = runAddonCommandLine(conf, version)

proc runAddonCli*(args: seq[string]): int =
  ## ``repro system addon <args>``, through the generated parser.
  runAddonArgs(@["system", "addon"] & args)

proc runStateCli*(args: seq[string]): int =
  ## ``repro system addon state <args>``, through the generated parser.
  runAddonCli(@["state"] & args)

proc runAddonStoreCli*(args: seq[string]): int =
  ## ``repro store <args>`` on the add-on's store, through the generated
  ## parser.
  runAddonArgs(@["store"] & args)
