## Command-line surface of add-on mode, shared by the full ``repro`` engine
## (``repro system addon …``) and the statically linked add-on ``repro``
## (which also answers to the name ``repro-addon-fingerprint``).
##
##   repro system addon preflight [--deploy-signers F] [--cache-publishers F [--cache-url U]]
##                                [--json]
##   repro system addon bootstrap --plan <digest> [--deploy-signers F]
##                                [--cache-publishers F [--cache-url U]]
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
import ./addon_rollback
import ./apt_hook
import ./base_identity
import ./bootstrap
import ./collision
import ./fingerprint
import ./generation0
import ./ledger
import ./linux_fs
import ./health
import ./preflight
import ./reassert
import ./seams
import ./secrets_ops
import ./static_tree
import ./store_root
import ./switch
import ./uninstall
import ./verify

const
  AddonUsage* = """usage: repro system addon <command> [options]

commands:
  preflight [--deploy-signers F] [--cache-publishers F [--cache-url U]] [--json]
      Inventory the host read-only and print the plan and its digest.
  bootstrap --plan <digest> [--deploy-signers F] [--cache-publishers F [--cache-url U]]
      Install the add-on on a host whose preflight plan has <digest>.
  uninstall [--keep-store]
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
  agent-tick --source <manifest>... [--target T] [--allowed-signers F]
      One deploy-agent tick: verify, accept the sealed section, apply the
      profile through the switch. Exit 0, 1 (retryable) or 2 (an operator
      must act; aoSecretsFailed among them).
  fingerprint [--root R] [--no-live] [--out F]
  fingerprint diff <before> <after> [--except C:GLOB]... [--expect F]
      Record the base fingerprint, or compare two.
  expected-delta <before-ledger|-> <after-ledger>
      The fingerprint diff an apply between two ledgers may cause.
  ledger
      Print the current ownership ledger.
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

proc runAddonCli*(args: seq[string]): int =
  ## Dispatch ``repro system addon <args>``.
  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    stdout.write(AddonUsage)
    return (if args.len == 0: 2 else: 0)
  let cmd = args[0]
  let rest = args[1 .. ^1]
  try:
    case cmd
    of "fingerprint":
      return runFingerprintCli(rest)
    of "preflight":
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
        elif a == "--json":
          json = true
        else:
          raise newException(ValueError, "unknown option " & a)
        inc i
      let r = runPreflight(inp)
      if json:
        stdout.write(r.planJson & "\n")
      else:
        stdout.write(renderPreflightHuman(r))
      return (if r.compatible: 0 else: 2)
    of "bootstrap":
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
        else:
          raise newException(ValueError, "unknown option " & a)
        inc i
      try:
        let r = runAddonBootstrap(opts)
        stdout.write("plan digest:          " & r.planDigest & "\n" &
                     "generation:           " & r.generationId & "\n" &
                     "add-on binary:        " & r.reproExe & "\n" &
                     "binary sha256:        " & r.binarySha256 & "\n" &
                     "recipient public key: " & r.recipientPublicKeyHex & "\n")
        return 0
      except AddonPlanMismatch as e:
        stderr.write("repro system addon bootstrap: " & e.msg & "\n")
        return 2
    of "uninstall":
      var opts: UninstallOptions
      for a in rest:
        if a == "--keep-store": opts.keepStore = true
        else: raise newException(ValueError, "unknown option " & a)
      let r = runAddonUninstall(opts)
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
        # The boot unit: never fails the boot transaction, whatever it finds.
        try:
          stdout.write(renderReassert(runAddonReassert(DefaultStateDir,
            atBoot = true)))
        except CatchableError as e:
          stdout.write("repro-addon reassert: degraded\n  " & e.msg & "\n")
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
    of "agent-tick":
      return runAgentTickCli(rest)
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
  if r.planId.len > 0:
    result.add("add-on plan-id: " & r.planId & "\n")
  if r.staticTree.len > 0:
    result.add("static tree: " & r.staticTree & "\n")
  if r.sysctlObserved.len > 0:
    result.add("sysctl observed (host namespaces):\n")
    for (k, v) in r.sysctlObserved:
      result.add("  " & k & "\t" & v & "\n")

proc runAddonStoreCli*(args: seq[string]): int =
  ## ``repro store gc | roots | list`` on the add-on's system-scope store:
  ## the same ``repro_local_store`` collector the full engine's ``repro
  ## store gc`` runs (the engine's extra, re-deriving pin roots from
  ## project locks, has nothing to re-derive here: an add-on host has no
  ## project locks). Roots decide what survives; the retention policy
  ## keeps the current and the previous generation's roots whatever is
  ## asked (spec §5.2).
  if args.len == 0 or args[0] in ["-h", "--help"]:
    stdout.write("usage: repro store gc [--grace-seconds N] | roots | list\n")
    return (if args.len == 0: 2 else: 0)
  try:
    # `gc` deletes prefixes no root holds; an apply realising a closure
    # holds no root on it until it commits, so a collection during an apply
    # could delete what that apply is about to bind. `gc` therefore runs
    # under the host-wide apply lock, like every other store writer.
    var hostLock: HostApplyLock
    if args[0] == "gc":
      hostLock = acquireHostApplyLock("repro store gc")
    defer: hostLock.release()
    enterWritableStoreView()
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
    let r = runAddonApply(AddonApplyOptions(stateDir: DefaultStateDir,
      hostIdentity: readHostname(), userProfileText: readFile(profile),
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

proc runAddonInfraApplyCli*(args: seq[string]): int =
  ## ``repro infra apply --profile <canonical text> [--reconcile-drift]``
  ## on an add-on host.
  runAddonGeneration("repro infra apply", args, planOnly = false)

proc runAddonInfraPlanCli*(args: seq[string]): int =
  ## ``repro infra plan --profile <canonical text>`` on an add-on host:
  ## the ledger diff and the collision report, nothing written.
  runAddonGeneration("repro infra plan", args, planOnly = true)

proc runAddonRollbackCli*(args: seq[string]): int =
  ## ``repro system rollback [<generation>] [--reconcile-drift]`` on an
  ## add-on host: re-apply a retained generation through the switch.
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
  runAddonGeneration("repro system adopt", rest, planOnly = false,
                     adopt = @[address])
