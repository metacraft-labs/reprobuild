## Recipe/lock consistency: the two hard rules that compare what a recipe
## states with what its lock records, and the two locks with each other.
##
## * **H1, the lock satisfies the recipe.** In a `flake.lock`, an input whose
##   `flake.nix` URL names a revision must be locked at that revision, and a
##   node must not record one revision in `original.rev` and another in
##   `locked.rev`. In a `repro.lock`, a resolved package must lie inside the
##   `uses:` range the recipe states for it, and an exact `uses:` version must
##   resolve to the `sourceRevision` the producer's `versions:` entry maps it
##   to.
## * **H2, the two systems agree.** When a repo carries both a `repro.lock` and
##   a `flake.lock`, every repository both of them resolve must be resolved at
##   one revision, and when both recipes pin it by exact revision the two pins
##   must be the same. A repository is identified by its canonical URL
##   (`canonicalRepositoryUrl`, the normalisation `repro sync` uses), never by
##   a name: two names for one repository are compared, and one name for two
##   repositories is not.
##
## Neither rule classifies a dependency (first-party, third-party, sibling).
## Each checks only facts that are written down: the recipe text and the lock
## text. An exact pin, a range, a library with no lock, and a repository only
## one system resolves all pass. Only an internal inconsistency fails.
##
## This module is PURE. It reads the four texts it is handed and two lookups
## the caller supplies (a producer recipe's `versions:` entries, and a git ref
## resolved in a checkout), and starts no process. The managed `pre-commit`
## hook calls it with the texts the commit will carry, the pre-push gate with
## the texts `HEAD` carries, so the two cannot disagree about what a rule
## means. The refusal text is generated here, once, for both.
##
## What it does NOT cover, said here so nobody reads silence as a pass:
##
## * only ROOT inputs of a `flake.lock` (an input of an input is the upstream
##   flake's own business, and its constraint is not in this recipe);
## * only `uses:` entries written as string literals and not under a `when` /
##   `if` / `case` arm (`scanReproUsesDeclarations`); a `const` or a
##   conditional entry is listed in `notChecked` instead. The recipe is not
##   compiled at hook time, so its extracted interface is not available;
## * a `uses:` entry is related to a `repro.lock` package and dependency by
##   the selector NAME the recipe wrote, because that name is the only link a
##   `uses:` entry has to its resolution: a `packages` entry carries no URL
##   (its identity in the lock IS its name), and a `uses:` entry carries none
##   either. Where both sides do carry one — the producer's `versions:` entry
##   states a `sourceRepository` and the `deps` entry a `url` — the two must
##   be one repository by canonical URL, or the exact-version check is listed
##   in `notChecked` instead of compared. H2 matches by canonical URL only;
## * an exact `uses:` version whose `sourceRevision` is a ref (`refs/tags/…`)
##   is resolved through the caller's lookup in the producer's checkout; when
##   that checkout is absent or the ref does not resolve, the entry is listed
##   in `notChecked`;
## * a range in one recipe against a revision in the other is not compared:
##   a version range and a commit id have no common scale without the
##   producer's `versions:` table, and the resolution check (H2 on the two
##   locks plus H1 on each) already proves the intersection non-empty
##   whenever it passes.

import std/[json, os, sequtils, strutils, tables]

import repro_lock
import repro_cli_support/recipe_constraints

export recipe_constraints

const
  H1Property* = "recipe_lock_constraint_violated"
    ## The pre-push gate property for an H1 violation.
  H2Property* = "cross_lock_revision_disagreement"
    ## The pre-push gate property for an H2 violation.
  LockUpdateAvailabilityNote* = "not available yet"
    ## How every message qualifies `repro lock update`: the command that does
    ## an intended upgrade in one step is named so the operator learns it, and
    ## it is NOT backticked because it cannot be run today (see
    ## `flakeRevPinEditRemedy` on what backticks mean in these messages).

type
  ConsistencyRule* = enum
    crH1 = "H1"
    crH2 = "H2"

  ConsistencyViolation* = object
    ## One inconsistency, with everything a refusal names.
    rule*: ConsistencyRule
    system*: string         ## `flake`, `repro`, or `both` (H2)
    dependency*: string     ## the input / package / dependency name
    repository*: string     ## canonical repository URL, "" when none
    recipeFile*: string     ## the recipe that states the constraint
    recipeLine*: int        ## its line (0 when unknown)
    constraint*: string     ## what the recipe states (a rev, a range)
    resolved*: string       ## what the lock records
    summary*: string        ## one sentence: the files, the line, both values
    remedies*: seq[string]  ## each way to restore consistency
    evidence*: string       ## `key=value` fields, for the structured report

  ConsistencyText* = object
    ## One input file of the check, as the caller read it.
    present*: bool
    path*: string           ## for messages
    text*: string

  ConsistencyInputs* = object
    repoRoot*: string
    flakeNix*, flakeLock*, reproNim*, reproLock*: ConsistencyText
    lockPathBase*: string
      ## The directory the `repro.lock`'s `deps` paths are relative to.
    producerVersions*: proc (depName, depAbs: string):
        tuple[found: bool; file: string; entries: seq[ReproVersionEntry]] {.closure.}
      ## The `versions:` entries of the recipe at ``depAbs`` (a producer's
      ## checkout), or ``found = false``.
    resolveRef*: proc (depAbs, gitRef: string): string {.closure.}
      ## ``gitRef`` resolved to a commit id in the checkout at ``depAbs``, or
      ## "".

  ConsistencyReport* = object
    violations*: seq[ConsistencyViolation]
    notChecked*: seq[string]
      ## constraints the check could not evaluate, and why
    diagnostics*: seq[string]
      ## an input that could not be read (a lock that does not parse)

proc hasViolations*(r: ConsistencyReport): bool = r.violations.len > 0

# ---------------------------------------------------------------------------
# The shared remedy generator for a pin written in `flake.nix`
# ---------------------------------------------------------------------------

proc flakeRevPinFile*(flakeRoot: string): string =
  if flakeRoot.len > 0: flakeRoot / "flake.nix" else: "the flake's flake.nix"

proc flakeRevPinEditRemedy*(declaredRev, observedRev,
    flakeRoot: string; pathForm = false): string =
  ## THE single generator for "the remedy here is a FILE EDIT, not a command".
  ##
  ## Every message that sends the operator to `flake.nix` prints it: the
  ## refresh's own decline notice, NF-3's pre-push refusal over the same input,
  ## and the H1 / H2 refusals below. They are kept on one generator for the
  ## reason `flakeReconcileCommands` is — the messages used to disagree about
  ## what fixes a row, and the gate named a command the refresh would decline.
  ##
  ## NOTE for anyone editing this string: backticks are reserved for RUNNABLE
  ## command lines — `backtickedCommands` lifts every one of them out and the
  ## cases EXECUTE what they find — and the first step here is an edit to a
  ## file. It therefore carries no backticks around the edit, and quotes only
  ## the one thing that really is a command line: the re-lock.
  ##
  ## The re-lock is named because the edit ALONE does not clear the disagreement.
  ## After it, `flake.nix` says one revision and the lock's `original` still says
  ## the other; nix reconciles that on its next evaluation by re-locking the node
  ## — moving `original.rev` and `locked.rev` together and computing the new
  ## `narHash` itself, which is the one part of this no reprobuild command can
  ## do. `nix flake lock` is that evaluation, asked for explicitly.
  ##
  ## ``pathForm`` spells a pin written as the URL's last path component
  ## (`github:o/r/<sha>`) instead of a `rev=` query parameter.
  let before = if pathForm: "/" & declaredRev else: "rev=" & declaredRev
  let after = if pathForm: "/" & observedRev else: "rev=" & observedRev
  "change " & before & " to " & after &
    " in that input's url in " & flakeRevPinFile(flakeRoot) &
    " — the revision is the author's statement and lives there, so no refresh " &
    "can move it — then re-lock the node so flake.lock follows the edit (`nix " &
    "flake lock" & (if flakeRoot.len > 0: " " & flakeRoot else: "") &
    "`, or simply re-enter the dev shell), which is also what recomputes its " &
    "narHash"

proc flakeRelockInputCommand*(input, flakeRoot: string): string =
  ## The command that re-locks ONE input from what `flake.nix` states, for a
  ## node whose `locked` no longer matches it.
  ##
  ## `nix flake update <input>`, not `nix flake lock`: nix reuses a lock entry
  ## whenever its `original` equals the `flake.nix` reference and never checks
  ## `locked` against either (nix `src/libflake/flake.cc`; measured with nix
  ## 2.32.8 — a node with `original.rev = A` and `locked.rev = B` under a
  ## `flake.nix` pinning `A` survives `nix flake lock` unchanged, and
  ## `nix flake update <input>` re-locks it to `A`).
  "nix flake update " & input &
    (if flakeRoot.len > 0: " --flake " & flakeRoot else: "")

proc lockUpdateMention(dependency, rev: string): string =
  ## `repro lock update`, named but not backticked (it cannot run today).
  "repro lock update " & dependency &
    (if rev.len > 0: " --to " & rev else: "") & " (" &
    LockUpdateAvailabilityNote & ") will do this in one step"

proc isPathFormPin(c: FlakeInputConstraint): bool =
  ## Is the exact revision written as the URL's path (`github:o/r/<sha>`)
  ## rather than as `rev=`?
  c.exactRev.len > 0 and ("rev=" & c.exactRev) notin c.url.toLowerAscii()

proc reproLockEntryEdit(lockPath, dep, fromRev, toRev: string): string =
  ## The hand edit that moves one `repro.lock` dependency entry. Words, no
  ## backticks: it is an edit, not a command.
  "in " & lockPath & ", change the '" & dep & "' entry's revision and its " &
    "git-sha1 integrity from " & fromRev & " to " & toRev

# ---------------------------------------------------------------------------
# H1 for a flake
# ---------------------------------------------------------------------------

proc checkFlakeH1(inputs: ConsistencyInputs;
    constraints: FlakeRecipeConstraints;
    resolutions: seq[FlakeLockResolution]; report: var ConsistencyReport) =
  var byInput = initTable[string, FlakeLockResolution]()
  for r in resolutions: byInput[r.input] = r
  let root = inputs.repoRoot
  let flakeFile = inputs.flakeNix.path
  let lockFile = inputs.flakeLock.path
  for c in constraints.inputs:
    if c.input notin byInput: continue
    let r = byInput[c.input]
    let locked = r.lockedRev.toLowerAscii()
    let original = r.originalRev.toLowerAscii()
    if c.exactRev.len > 0 and locked.len > 0 and locked != c.exactRev:
      var v = ConsistencyViolation(rule: crH1, system: "flake",
        dependency: c.input, repository: c.canonicalRepo,
        recipeFile: flakeFile, recipeLine: c.line, constraint: c.exactRev,
        resolved: locked)
      v.summary = "H1 (the lock satisfies the recipe): " & flakeFile & ":" &
        $c.line & " pins input '" & c.input & "' at revision " & c.exactRev &
        ", but " & lockFile & " locks it at " & locked & " (node '" & r.node &
        "', locked.rev" &
        (if original.len > 0 and original != locked:
           "; its original.rev records " & original
         else: "") & ")"
      v.remedies.add("To build the revision the recipe states (" &
        c.exactRev & "), re-lock that input so flake.lock follows " &
        "flake.nix: `" & flakeRelockInputCommand(c.input, root) & "`")
      v.remedies.add("If " & locked & " is the intended upgrade, " &
        flakeRevPinEditRemedy(c.exactRev, locked, root, isPathFormPin(c)) &
        "; " & lockUpdateMention(c.input, locked))
      v.evidence = "rule=H1 system=flake input=" & c.input & " node=" &
        r.node & " recipe=" & flakeFile & ":" & $c.line & " rev=" &
        c.exactRev & " locked.rev=" & locked &
        (if original.len > 0: " original.rev=" & original else: "")
      report.violations.add(v)
    elif original.len > 0 and locked.len > 0 and original != locked:
      # The recipe's own pin is satisfied (or it states none), but the lock
      # records a constraint (`original.rev`) its own resolution violates: nix
      # reverts such a node on its next evaluation, so the committed lock does
      # not describe what will be built.
      var v = ConsistencyViolation(rule: crH1, system: "flake",
        dependency: c.input, repository: c.canonicalRepo,
        recipeFile: flakeFile, recipeLine: c.line, constraint: original,
        resolved: locked)
      v.summary = "H1 (the lock satisfies the recipe): " & lockFile &
        " node '" & r.node & "' for input '" & c.input &
        "' records original.rev " & original & " but locked.rev " & locked &
        "; " & flakeFile & ":" & $c.line &
        (if c.exactRev.len > 0: " pins revision " & c.exactRev
         elif c.url.len > 0: " states " & c.url
         else: " declares the input")
      v.remedies.add("Re-lock that input so flake.lock follows flake.nix: `" &
        flakeRelockInputCommand(c.input, root) & "`")
      if c.exactRev.len == 0:
        v.remedies.add("If " & original & " was meant to stay pinned, " &
          "restore rev=" & original & " in that input's url in " &
          flakeRevPinFile(root) & " and re-lock as above")
      v.evidence = "rule=H1 system=flake input=" & c.input & " node=" &
        r.node & " recipe=" & flakeFile & ":" & $c.line &
        (if c.exactRev.len > 0: " rev=" & c.exactRev else: "") &
        " locked.rev=" & locked & " original.rev=" & original
      report.violations.add(v)

# ---------------------------------------------------------------------------
# H1 for a repro.lock
# ---------------------------------------------------------------------------

type
  ExactSourceRevision = object
    found: bool
    rev: string            ## the commit id the exact version maps to
    spelled: string        ## the `sourceRevision` as written
    producerFile: string
    producerLine: int

proc exactRevisionOf(inputs: ConsistencyInputs; c: ReproUsesConstraint;
    dep: LockedDep; report: var ConsistencyReport): ExactSourceRevision =
  ## The commit an exact `uses:` version maps to, through the producer's
  ## `versions:` entries. Every way this can fail to answer is recorded in
  ## ``notChecked``; none of them is a pass.
  let where = c.file & ":" & $c.line
  if dep.path.len == 0:
    report.notChecked.add(where & ": '" & c.selector & " " & c.rangeText &
      "' — the repro.lock entry carries no checkout path, so the producer's " &
      "versions: table cannot be read")
    return
  if inputs.producerVersions.isNil: return
  let depAbs = os.normalizedPath(absolutePath(dep.path, inputs.lockPathBase))
  let pv = inputs.producerVersions(c.selector, depAbs)
  if not pv.found:
    report.notChecked.add(where & ": '" & c.selector & " " & c.rangeText &
      "' — no producer recipe at " & depAbs / "repro.nim")
    return
  let mapped = exactSourceRevision(c, pv.entries)
  if not mapped.found:
    report.notChecked.add(where & ": '" & c.selector & " " & c.rangeText &
      "' — " & pv.file & " declares no versions: entry \"" & c.exactVersion &
      "\"")
    return
  if not mapped.entry.sourceRevisionIsLiteral:
    report.notChecked.add(where & ": '" & c.selector & " " & c.rangeText &
      "' — the sourceRevision of " & pv.file & ":" & $mapped.entry.line &
      " is not a string literal")
    return
  # The selector NAME found the `repro.lock` entry; when the producer's
  # `versions:` entry also says which repository the version is cut from, the
  # two must be one repository by canonical URL before their revisions are
  # compared. One name for two repositories is not a disagreement (§16.3).
  let declaredRepo = canonicalRepositoryUrl(mapped.entry.sourceRepository)
  let lockedRepo = canonicalRepositoryUrl(dep.coordinates.url)
  if declaredRepo.len > 0 and lockedRepo.len > 0 and
      declaredRepo != lockedRepo:
    report.notChecked.add(where & ": '" & c.selector & " " & c.rangeText &
      "' — " & pv.file & ":" & $mapped.entry.line & " cuts that version " &
      "from " & declaredRepo & ", but the repro.lock entry '" & dep.name &
      "' fetches " & lockedRepo & "; one name for two repositories is not " &
      "compared")
    return
  result.spelled = mapped.entry.sourceRevision
  result.producerFile = pv.file
  result.producerLine = mapped.entry.line
  if isExactRevision(result.spelled):
    result.rev = result.spelled.toLowerAscii()
  elif not inputs.resolveRef.isNil:
    result.rev = inputs.resolveRef(depAbs, result.spelled).toLowerAscii()
  if result.rev.len == 0:
    report.notChecked.add(where & ": '" & c.selector & " " & c.rangeText &
      "' — sourceRevision " & result.spelled & " (" & pv.file & ":" &
      $mapped.entry.line & ") does not resolve in " & depAbs)
    return
  result.found = true

proc checkReproH1(inputs: ConsistencyInputs;
    decls: seq[ReproUsesDeclaration]; ld: LockedDependencies;
    report: var ConsistencyReport) =
  let root = inputs.repoRoot
  let lockFile = inputs.reproLock.path
  var packagesByName = initTable[string, seq[LockedPackage]]()
  for p in ld.packages:
    if p.selection == ssUnselected: continue
    packagesByName.mgetOrPut(p.name, @[]).add(p)
  var depsByName = initTable[string, LockedDep]()
  for d in ld.deps:
    if d.path != "." and d.coordinates.kind == ckVcs:
      depsByName[d.name] = d
  for decl in decls:
    let c = decl.constraint
    let where = c.file & ":" & $c.line
    if decl.conditional:
      if c.kind in {uckRange, uckExact}:
        report.notChecked.add(where & ": '" & decl.rawConstraint &
          "' — under a when/if/case arm, so whether it applies to this " &
          "lock is not decidable without compiling the recipe")
      continue
    case c.kind
    of uckUnconstrained:
      continue
    of uckUnparseable:
      report.notChecked.add(where & ": '" & decl.rawConstraint &
        "' — not a version constraint this check can read (" &
        c.diagnostic & ")")
      continue
    of uckRange, uckExact:
      discard
    # The version range: against every selected package of that name.
    if c.selector in packagesByName:
      let candidates = packagesByName[c.selector]
      var admitted = false
      var undecidable = false
      var versions: seq[string]
      for p in candidates:
        versions.add(p.version)
        if c.admits(p.version): admitted = true
        elif not isComparableVersion(p.version): undecidable = true
      if not admitted and undecidable:
        # A resolved version the range grammar cannot read is neither inside
        # nor outside the range. Refusing would block a commit nobody can fix
        # by editing a range; passing would be silence read as a pass. It is
        # listed instead, and every caller surfaces the list.
        report.notChecked.add(where & ": '" & decl.rawConstraint & "' — " &
          lockFile & " resolves package '" & c.selector & "' at version " &
          versions.join(", ") & ", which is not a version this check can " &
          "compare with a range")
      elif not admitted:
        let resolved = versions.join(", ")
        var v = ConsistencyViolation(rule: crH1, system: "repro",
          dependency: c.selector, recipeFile: c.file, recipeLine: c.line,
          constraint: decl.rawConstraint, resolved: resolved)
        v.summary = "H1 (the lock satisfies the recipe): " & where &
          " requires '" & decl.rawConstraint & "' (" & decl.blockHead &
          ":), but " & lockFile & " resolves package '" & c.selector &
          "' at version " & resolved & ", which that range does not admit"
        v.remedies.add("To resolve it inside the range the recipe states, " &
          "re-solve the lock. From " & root & " run: `repro lock refresh`")
        v.remedies.add("If " & resolved & " is the intended version, widen " &
          "the range at " & where & " so it admits " & resolved &
          ", then re-solve the same way")
        v.evidence = "rule=H1 system=repro package=" & c.selector &
          " recipe=" & where & " constraint=" & quoteShell(decl.rawConstraint) &
          " resolved=" & resolved
        report.violations.add(v)
    # The exact version: its `sourceRevision` against the resolved revision.
    if c.kind == uckExact and c.selector in depsByName:
      let dep = depsByName[c.selector]
      let mapped = exactRevisionOf(inputs, c, dep, report)
      let pinned = dep.coordinates.revision.toLowerAscii()
      if mapped.found and pinned.len > 0 and pinned != mapped.rev:
        var v = ConsistencyViolation(rule: crH1, system: "repro",
          dependency: c.selector, repository:
            canonicalRepositoryUrl(dep.coordinates.url),
          recipeFile: c.file, recipeLine: c.line,
          constraint: mapped.rev, resolved: pinned)
        v.summary = "H1 (the lock satisfies the recipe): " & where &
          " requires '" & decl.rawConstraint & "', which " &
          mapped.producerFile & ":" & $mapped.producerLine &
          " maps to sourceRevision " & mapped.spelled &
          (if mapped.spelled.toLowerAscii() != mapped.rev:
             " (" & mapped.rev & ")"
           else: "") &
          ", but " & lockFile & " resolves '" & c.selector & "' at " & pinned
        v.remedies.add("To keep the version the recipe states, make the " &
          "lock name " & mapped.rev & ": " &
          reproLockEntryEdit(lockFile, c.selector, pinned, mapped.rev))
        v.remedies.add("If " & pinned & " is the intended upgrade, change " &
          "the uses: entry at " & where & " to the version whose " &
          "sourceRevision is " & pinned & " (adding that versions: entry to " &
          mapped.producerFile & " if it has none); " &
          lockUpdateMention(c.selector, pinned))
        v.evidence = "rule=H1 system=repro dependency=" & c.selector &
          " recipe=" & where & " constraint=" & quoteShell(decl.rawConstraint) &
          " sourceRevision=" & mapped.rev & " locked.revision=" & pinned
        report.violations.add(v)

# ---------------------------------------------------------------------------
# H2: the two locks, by canonical repository URL
# ---------------------------------------------------------------------------

proc checkH2(inputs: ConsistencyInputs; constraints: FlakeRecipeConstraints;
    resolutions: seq[FlakeLockResolution]; ld: LockedDependencies;
    decls: seq[ReproUsesDeclaration]; report: var ConsistencyReport) =
  let root = inputs.repoRoot
  let reproLockFile = inputs.reproLock.path
  let flakeLockFile = inputs.flakeLock.path
  let flakeFile = inputs.flakeNix.path
  var constraintOf = initTable[string, FlakeInputConstraint]()
  for c in constraints.inputs: constraintOf[c.input] = c
  # The exact `uses:` version of each dependency name, for the constraint
  # comparison. Only unconditional, exact entries can state a revision.
  var exactUses = initTable[string, ReproUsesDeclaration]()
  for d in decls:
    if not d.conditional and d.constraint.kind == uckExact:
      exactUses[d.constraint.selector] = d
  for dep in ld.deps:
    if dep.path == "." or dep.coordinates.kind != ckVcs: continue
    let identity = canonicalRepositoryUrl(dep.coordinates.url)
    if identity.len == 0: continue
    let reproRev = dep.coordinates.revision.toLowerAscii()
    for r in resolutions:
      # IDENTITY, never a name: the input may be called anything.
      if r.canonicalRepo.len == 0 or r.canonicalRepo != identity: continue
      let c = constraintOf.getOrDefault(r.input, FlakeInputConstraint())
      let flakeRev = r.lockedRev.toLowerAscii()
      if reproRev.len > 0 and flakeRev.len > 0 and reproRev != flakeRev:
        var v = ConsistencyViolation(rule: crH2, system: "both",
          dependency: dep.name, repository: identity, recipeFile: flakeFile,
          recipeLine: c.line, constraint: flakeRev, resolved: reproRev)
        let flakeStatement =
          if c.exactRev.len > 0:
            "pinned by " & flakeFile & ":" & $c.line & " at " & c.exactRev
          elif c.line > 0:
            "declared at " & flakeFile & ":" & $c.line &
              (if c.gitRef.len > 0: ", following " & c.gitRef
               else: ", following its default branch")
          else: "declared in " & flakeFile
        v.summary = "H2 (the two locks agree): repository " & identity &
          " is resolved by " & reproLockFile & " as '" & dep.name & "' at " &
          reproRev & " and by " & flakeLockFile & " as input '" & r.input &
          "' at " & flakeRev & " (" & flakeStatement & ")"
        v.remedies.add("To make both locks name " & flakeRev & " (the " &
          "flake's revision): " &
          reproLockEntryEdit(reproLockFile, dep.name, reproRev, flakeRev))
        if c.exactRev.len > 0:
          v.remedies.add("To make both locks name " & reproRev & " (the " &
            "repro.lock revision): " &
            flakeRevPinEditRemedy(c.exactRev, reproRev, root,
              isPathFormPin(c)))
        else:
          v.remedies.add("flake.nix lets '" & r.input & "' follow a " &
            "branch, so flake.lock records whatever that branch resolves " &
            "to: to make both locks name the branch tip, re-lock it with `" &
            flakeRelockInputCommand(r.input, root) & "` and then move the " &
            "repro.lock entry to the revision it records, as above; to " &
            "make both name " & reproRev & ", pin rev=" & reproRev &
            " in that input's url in " & flakeRevPinFile(root) & " and " &
            "re-lock it the same way")
        v.remedies.add("For an intended upgrade, " &
          lockUpdateMention(dep.name, "<rev>") &
          ", moving every resolution of the repository in both locks")
        v.evidence = "rule=H2 repository=" & identity & " repro.lock=" &
          dep.name & "@" & reproRev & " flake.lock=" & r.input & "@" &
          flakeRev & (if c.line > 0: " recipe=" & flakeFile & ":" & $c.line
                      else: "")
        report.violations.add(v)
      # Both recipes pin it exactly: the two pins must be one revision.
      if c.exactRev.len > 0 and dep.name in exactUses:
        let decl = exactUses[dep.name]
        let mapped = exactRevisionOf(inputs, decl.constraint, dep, report)
        if mapped.found and mapped.rev != c.exactRev:
          let where = decl.constraint.file & ":" & $decl.constraint.line
          var v = ConsistencyViolation(rule: crH2, system: "both",
            dependency: dep.name, repository: identity,
            recipeFile: decl.constraint.file,
            recipeLine: decl.constraint.line, constraint: mapped.rev,
            resolved: c.exactRev)
          v.summary = "H2 (the two recipes agree): repository " & identity &
            " is pinned by " & flakeFile & ":" & $c.line & " (input '" &
            r.input & "') at " & c.exactRev & ", but " & where &
            " requires '" & decl.rawConstraint & "', which " &
            mapped.producerFile & ":" & $mapped.producerLine & " maps to " &
            mapped.rev & "; no single revision satisfies both recipes"
          v.remedies.add("Make the two recipes name one revision: either " &
            flakeRevPinEditRemedy(c.exactRev, mapped.rev, root,
              isPathFormPin(c)) & ", or change the uses: entry at " & where &
            " to the version whose sourceRevision is " & c.exactRev & "; " &
            lockUpdateMention(dep.name, "<rev>"))
          v.evidence = "rule=H2 kind=constraint-conflict repository=" &
            identity & " flake.nix=" & r.input & "@" & c.exactRev &
            " repro.nim=" & dep.name & "@" & mapped.rev
          report.violations.add(v)

# ---------------------------------------------------------------------------
# The entry point
# ---------------------------------------------------------------------------

proc checkRecipeLockConsistency*(inputs: ConsistencyInputs): ConsistencyReport =
  ## H1 on each system present, and H2 when both locks are present. A lock
  ## that cannot be parsed is a diagnostic, not a pass and not a violation:
  ## the callers already have stages that refuse an unreadable lock, and this
  ## check must not invent a disagreement out of a parse failure.
  var constraints: FlakeRecipeConstraints
  var resolutions: seq[FlakeLockResolution]
  let haveFlake = inputs.flakeNix.present and inputs.flakeLock.present
  if haveFlake:
    constraints = flakeRecipeConstraintsOf(inputs.flakeNix.text,
      inputs.flakeNix.path)
    resolutions = flakeLockResolutions(inputs.flakeLock.text)
    # `flakeLockResolutions` answers an unreadable document with an empty list,
    # which would read here as "nothing to check". Say so instead.
    var readable = false
    try:
      readable = parseJson(inputs.flakeLock.text).kind == JObject
    except CatchableError:
      readable = false
    if not readable:
      result.diagnostics.add(inputs.flakeLock.path & " could not be read " &
        "as a flake lock (not a JSON object); the recipe/lock consistency " &
        "of the flake side was not checked")
    checkFlakeH1(inputs, constraints, resolutions, result)
  var ld: LockedDependencies
  var haveReproLock = false
  if inputs.reproLock.present:
    try:
      ld = parseLockedDependencies(inputs.reproLock.text)
      haveReproLock = true
    except CatchableError as err:
      result.diagnostics.add(inputs.reproLock.path & " could not be read " &
        "as a lock (" & err.msg & "); the recipe/lock consistency of the " &
        "repro.lock side was not checked")
  var decls: seq[ReproUsesDeclaration]
  if inputs.reproNim.present:
    decls = scanReproUsesDeclarations(inputs.reproNim.text,
      inputs.reproNim.path)
  if haveReproLock and inputs.reproNim.present:
    checkReproH1(inputs, decls, ld, result)
  if haveReproLock and haveFlake:
    checkH2(inputs, constraints, resolutions, ld, decls, result)
  # H1 and H2 both consult an exact `uses:` entry, so an entry neither could
  # evaluate would otherwise be listed twice.
  result.notChecked = deduplicate(result.notChecked)

proc violationsOf*(r: ConsistencyReport;
    rule: ConsistencyRule): seq[ConsistencyViolation] =
  for v in r.violations:
    if v.rule == rule: result.add(v)

proc renderConsistencyViolation*(v: ConsistencyViolation): string =
  ## One violation as one paragraph: the summary, then each remedy.
  result = v.summary & "."
  for i, r in v.remedies:
    result.add(" (" & $(i + 1) & ") " & r & ".")

proc renderConsistencyRefusal*(violations: openArray[ConsistencyViolation]):
    seq[string] =
  ## The refusal lines, shared verbatim by the `pre-commit` hook and the
  ## pre-push gate.
  for v in violations:
    result.add(renderConsistencyViolation(v))

type
  FlakeLockWriteGate* = proc (plannedText: string): bool {.closure.}
    ## Asked by the commit-time `flake.lock` refresh with the document it is
    ## about to write; returning false vetoes the write. The `pre-commit` hook
    ## uses it to run H1 / H2 over the lock the commit WOULD carry, so a commit
    ## refused for an inconsistency writes and stages nothing.
