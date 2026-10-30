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
##   repro system addon fingerprint [--root R] [--no-live] [--out F]
##   repro system addon fingerprint diff <before> <after>
##                                [--except <component>:<key glob>]...
##                                [--expect <file>]
##   repro system addon expected-delta <before-ledger|-> <after-ledger>
##   repro system addon ledger
##   repro system adopt <address> --profile <file>
##   repro infra plan --profile <file>
##   repro infra apply --profile <file> [--reconcile-drift]
##
## Exit status: 0 success; 1 failure, drift or a non-empty diff; 2 a usage
## error or a refusal decided before anything was written (an incompatible
## host, a plan digest that does not match).

import std/[os, strutils]

import std/algorithm

import repro_infra

import repro_infra/addon_diagnostics

import ./addon_apply
import ./bootstrap
import ./collision
import ./fingerprint
import ./ledger
import ./linux_fs
import ./preflight
import ./store_root
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
      Compare every ledger object with the host (report only).
  fingerprint [--root R] [--no-live] [--out F]
  fingerprint diff <before> <after> [--except C:GLOB]... [--expect F]
      Record the base fingerprint, or compare two.
  expected-delta <before-ledger|-> <after-ledger>
      The fingerprint diff an apply between two ledgers may cause.
  ledger
      Print the current ownership ledger.
  status
      The current generation, the generations held as store roots, and the
      store root's kind.
  selfcheck-btrfs <mount point>
      Create and delete a btrfs subvolume under a btrfs mount the way the
      store root is created on a btrfs root (a test of that leg).

related (add-on hosts):
  repro system adopt <address> --profile <file>
      Claim the object a declared resource targets as it is, writing nothing.
  repro infra plan --profile <file>
      The ledger diff and collision report of applying <file>; writes nothing.
  repro infra apply --profile <file> [--reconcile-drift]
      Apply an add-on generation.
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
      # and what kind of thing /repro is.
      let current = readCurrentGenerationId(DefaultStateDir)
      stdout.write("current generation: " & current & "\n")
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
    else:
      raise newException(ValueError, "unknown command " & cmd)
  except ValueError as e:
    stderr.write("repro system addon: " & e.msg & "\n" & AddonUsage)
    return 2
  except CatchableError as e:
    stderr.write("repro system addon " & cmd & ": " & e.msg & "\n")
    return 1

proc renderAddonSections*(r: AddonApplyResult): string =
  ## The add-on's plan sections (spec §7.1): the ledger diff and the
  ## collision report. (The service transition list is A4's.)
  renderLedgerDiff(r) & renderCollisionReport(r.collisions)

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
  var i = 0
  try:
    while i < args.len:
      let a = args[i]
      if a == "--profile" or a.startsWith("--profile="):
        profile = takeValue(args, i, "--profile")
      elif a == "--reconcile-drift" or a == "--accept-drift":
        reconcile = true
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
      reconcileDrift: reconcile, adoptAddresses: adopt, planOnly: planOnly))
    stdout.write(renderAddonSections(r))
    if planOnly:
      stdout.write("plan only: nothing was written\n")
      return 0
    stdout.write("generation " & r.generationId & " (previous " &
      r.previousGenerationId & "): applied " & $r.infra.appliedCount &
      ", no-op " & $r.infra.noOpCount & ", removed " & $r.removed.len &
      ", restored " & $r.restored.len & "\n")
    for a in adopt:
      var found = false
      for c in r.collisions:
        if c.address == a and c.verdict in ["adopt", "no-op", "update"]:
          found = true
      if not found:
        stderr.write(verb & ": " & a & " was not adopted (see the " &
          "collision report)\n")
        return 1
    if r.drift.len > 0:
      stderr.write(verb & ": " & $r.drift.len & " object(s) left in " &
        "place as actionable drift\n")
      return 1
    0
  except ValueError as e:
    stderr.write(verb & ": " & e.msg & "\n")
    2
  except EAddOn as e:
    stderr.write(verb & ": " & e.msg & "\n")
    2
  except AddonCollisionError as e:
    stderr.write(verb & ": " & e.msg & "\n")
    2
  except AddonDriftError as e:
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

proc runAddonAdoptCli*(args: seq[string]): int =
  ## ``repro system adopt <address> --profile <file>`` (spec §11.2 step
  ## 3): the object the resource targets is claimed as it is -- its bytes
  ## become the add-on's, nothing is written to it -- and the generation
  ## that results owns it.
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
