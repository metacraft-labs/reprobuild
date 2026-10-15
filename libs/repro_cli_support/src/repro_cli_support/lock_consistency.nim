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
## * **H3, the commit-time re-pin moves resolutions only** (§16.4). This is a
##   rule for a WRITER, not a check over a lock: ``reproRepinVerdict`` says
##   whether a `repro.nim` constraint excludes the revision a sibling checkout
##   is at, and ``repinExclusionViolation`` renders the refusal the
##   `pre-commit` hook prints when one does (the hook itself decides which
##   repositories to hold in both locks).
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

type
  ConsistencyRule* = enum
    crH1 = "H1"
    crH2 = "H2"
    crH3 = "H3"
      ## A refusal of the commit-time re-pin (§16.4), not a check over a
      ## lock: see ``repinExclusionViolation``.

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

proc lockUpdateCommand*(dependency, rev, repoRoot: string): string =
  ## THE spelling of `repro lock update` in every message: the dependency,
  ## the target revision when there is one, and the repo it runs against, so
  ## the command runs unchanged from wherever the message was printed.
  ##
  ## It is printed in backticks, because it is a runnable command line (see
  ## ``flakeRevPinEditRemedy`` on what backticks promise here).
  "repro lock update " & quoteShell(dependency) &
    (if rev.len > 0: " --to " & rev else: "") &
    (if repoRoot.len > 0: " --repo-root=" & quoteShell(repoRoot) else: "")

proc flakeRevPinEditRemedy*(input, declaredRev, observedRev,
    flakeRoot: string; pathForm = false): string =
  ## THE single generator for "the remedy moves a revision `flake.nix`
  ## states".
  ##
  ## Every message that sends the operator to a revision written in
  ## `flake.nix` prints it: the refresh's own decline notice, NF-3's pre-push
  ## refusal over the same input, and the H1 / H2 / H3 refusals below. They
  ## are kept on one generator for the reason `flakeReconcileCommands` is —
  ## the messages used to disagree about what fixes a row, and the gate named
  ## a command the refresh would decline.
  ##
  ## The remedy is `repro lock update <input> --to <observed>`
  ## (Unified-Locking-And-Hooks.md §16.4), which replaced the hand edit this
  ## generator used to print: it rewrites the revision in the input's url,
  ## re-locks the node through nix — the only thing that computes the new
  ## `narHash` — and moves every other resolution of the repository with it,
  ## all or nothing. The hand route is still named, for an operator who wants
  ## to make the edit themselves: after the edit ALONE `flake.nix` says one
  ## revision and the lock's `original` the other, and nix reconciles them on
  ## its next evaluation; `nix flake lock` is that evaluation, asked for.
  ##
  ## NOTE for anyone editing this string: backticks are reserved for RUNNABLE
  ## command lines — `backtickedCommands` lifts every one of them out and the
  ## cases EXECUTE what they find. The hand edit is in words; the two command
  ## lines (`repro lock update`, and the re-lock that completes a hand edit)
  ## are quoted.
  ##
  ## ``pathForm`` spells a pin written as the URL's last path component
  ## (`github:o/r/<sha>`) instead of a `rev=` query parameter.
  let before = if pathForm: "/" & declaredRev else: "rev=" & declaredRev
  let after = if pathForm: "/" & observedRev else: "rev=" & observedRev
  "run `" & lockUpdateCommand(input, observedRev, flakeRoot) & "`: it " &
    "changes " & before & " to " & after & " in that input's url in " &
    flakeRevPinFile(flakeRoot) & " — the revision is the author's statement " &
    "and lives there, so no refresh can move it — and re-locks the node " &
    "through nix, which is what recomputes its narHash (by hand: make that " &
    "edit, then `nix flake lock" &
    (if flakeRoot.len > 0: " " & quoteShell(flakeRoot) else: "") &
    "`, or simply re-enter the dev shell)"

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

proc isPathFormPin*(c: FlakeInputConstraint): bool =
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
        flakeRevPinEditRemedy(c.input, c.exactRev, locked, root,
          isPathFormPin(c)))
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
        v.remedies.add("If " & pinned & " is the intended upgrade, run `" &
          lockUpdateCommand(c.selector, pinned, root) & "`: it changes the " &
          "uses: entry at " & where & " to the version whose " &
          "sourceRevision is " & pinned & " (it refuses when no versions: " &
          "entry of " & mapped.producerFile & " maps " & pinned &
          "; add that entry first)")
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
          "flake's revision), run `" &
          lockUpdateCommand(dep.name, flakeRev, root) & "`, which moves " &
          "every resolution of the repository to it (by hand: " &
          reproLockEntryEdit(reproLockFile, dep.name, reproRev, flakeRev) &
          ")")
        if c.exactRev.len > 0:
          v.remedies.add("To make both locks name " & reproRev & " (the " &
            "repro.lock revision), " &
            flakeRevPinEditRemedy(r.input, c.exactRev, reproRev, root,
              isPathFormPin(c)))
        else:
          v.remedies.add("flake.nix lets '" & r.input & "' follow a " &
            "branch, so flake.lock records whatever that branch resolves " &
            "to: to make both locks name " & reproRev & " (the repro.lock " &
            "revision), run `" & lockUpdateCommand(r.input, reproRev, root) &
            "`; to make both name the branch tip, re-lock the input with `" &
            flakeRelockInputCommand(r.input, root) & "` and then run " &
            "repro lock update " & dep.name & " --to the revision it records")
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
          v.remedies.add("Make the two recipes name one revision: to keep " &
            mapped.rev & " (the repro.nim version), " &
            flakeRevPinEditRemedy(r.input, c.exactRev, mapped.rev, root,
              isPathFormPin(c)) & "; to keep " & c.exactRev & " (the " &
            "flake.nix pin), run `" &
            lockUpdateCommand(dep.name, c.exactRev, root) & "`, which " &
            "changes the uses: entry at " & where & " to the version whose " &
            "sourceRevision is " & c.exactRev & " (it refuses when no " &
            "versions: entry of " & mapped.producerFile & " maps it)")
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

# ---------------------------------------------------------------------------
# H3: the commit-time re-pin moves lock resolutions, never a recipe constraint
# (Unified-Locking-And-Hooks.md §16.3 H3, §16.4)
# ---------------------------------------------------------------------------
#
# The managed `pre-commit` hook re-pins both locks from the sibling checkouts
# it observes. When the recipe constrains a dependency so that the observed
# revision falls outside the constraint (an exact `rev=` in `flake.nix`, an
# exact `uses:` version in `repro.nim`, a `uses:` range), the re-pin writes
# nothing for that repository in either lock and the commit is refused. The
# functions below decide whether a `repro.nim` constraint excludes an observed
# revision, and render the refusal; the hook decides which repositories to
# hold and when to write.

const
  H3Property* = "commit_repin_excluded_by_recipe_constraint"
    ## The evidence tag of an H3 refusal in `pre-commit-lock.log`.

type
  RepinConstraintKind* = enum
    rckFlakeRev       ## `flake.nix` names the input's revision
    rckExactVersion   ## an exact `uses:` version, mapped to a sourceRevision
    rckRange          ## a `uses:` range

  RepinConstraintExclusion* = object
    ## A recipe constraint that excludes the revision a sibling checkout is
    ## at, found by the commit-time re-pin.
    kind*: RepinConstraintKind
    dependency*: string     ## the name the recipe gives it (input / selector)
    repository*: string     ## canonical repository URL, "" when unknown
    checkout*: string       ## the sibling checkout observed
    observed*: string       ## the checkout's HEAD
    constraintText*: string ## the constraint as written (`beta ==1.0.0`)
    pinnedRev*: string
      ## The revision an exact constraint means (``rckFlakeRev``,
      ## ``rckExactVersion``), or "" for a range.
    observedVersion*: string
      ## For ``rckRange``: the version the producer's `versions:` table maps
      ## the observed revision to.
    producerFile*: string   ## the producer recipe whose `versions:` was read
    producerLine*: int
    recipeFile*: string     ## the recipe that states the constraint
    recipeLine*: int
    pathForm*: bool         ## a `flake.nix` pin written as `/<sha>`
    repoRoot*: string       ## the repo being committed (for the flake remedy)
    held*: seq[string]
      ## One sentence per lock resolution of the repository the re-pin left
      ## alone (`flake.lock input 'beta-src' stays at <rev>`).
    lockedRev*: string      ## the revision the locks name now
    overridden*: bool       ## an explicit develop override substitutes it
    overrideRepo*: string   ## the workspace repo the override names
    overrideFiles*: seq[string]
      ## The develop-override documents that name it.

  ReproRepinVerdict* = object
    ## What `repro.nim` says about moving one `repro.lock` dependency to an
    ## observed revision.
    exclusions*: seq[RepinConstraintExclusion]
    exactPin*: string
      ## The revision an unconditional exact `uses:` version maps it to, or "".
    exactPinFile*: string
    exactPinLine*: int
    notChecked*: seq[string]
      ## Constraints that could not be evaluated, and why. None of them is a
      ## pass and none is a refusal.

proc versionAtRevision(inputs: ConsistencyInputs; c: ReproUsesConstraint;
    depAbs, depUrl, observed: string; report: var ConsistencyReport):
    tuple[found: bool; version, file: string; line: int] =
  ## The version whose producer `versions:` entry maps to ``observed``: the
  ## only way a hook that does not compile the producer recipe can tell which
  ## version a checkout is. Every way this fails to answer is recorded in
  ## ``report.notChecked``.
  let where = c.file & ":" & $c.line
  if inputs.producerVersions.isNil: return
  let pv = inputs.producerVersions(c.selector, depAbs)
  if not pv.found:
    report.notChecked.add(where & ": '" & c.selector & " " & c.rangeText &
      "' — no producer recipe at " & depAbs / "repro.nim" & ", so the " &
      "version of " & observed & " is unknown")
    return
  let lockedRepo = canonicalRepositoryUrl(depUrl)
  for e in pv.entries:
    if not e.sourceRevisionIsLiteral: continue
    let declaredRepo = canonicalRepositoryUrl(e.sourceRepository)
    if declaredRepo.len > 0 and lockedRepo.len > 0 and
        declaredRepo != lockedRepo:
      continue
    var rev = ""
    if isExactRevision(e.sourceRevision):
      rev = e.sourceRevision.toLowerAscii()
    elif not inputs.resolveRef.isNil:
      rev = inputs.resolveRef(depAbs, e.sourceRevision).toLowerAscii()
    if rev.len > 0 and rev == observed.toLowerAscii():
      return (true, e.version, pv.file, e.line)
  report.notChecked.add(where & ": '" & c.selector & " " & c.rangeText &
    "' — no versions: entry of " & pv.file & " maps to " & observed &
    ", so whether that range admits the checkout is not decidable")

proc versionMappedTo*(inputs: ConsistencyInputs; c: ReproUsesConstraint;
    depAbs, depUrl, rev: string):
    tuple[found: bool; version, file: string; line: int; why: string] =
  ## The version whose producer `versions:` entry (read from the producer's
  ## checkout at ``depAbs``) maps to ``rev``, for `repro lock update`, which
  ## replaces an exact `uses:` version with it. ``why`` says why nothing was
  ## found, in the words the H3 refusal uses.
  var report: ConsistencyReport
  let at = versionAtRevision(inputs, c, depAbs, depUrl, rev, report)
  (at.found, at.version, at.file, at.line, report.notChecked.join("; "))

proc reproRepinVerdict*(inputs: ConsistencyInputs; dependency, depAbs,
    depUrl, observed: string): ReproRepinVerdict =
  ## Does `repro.nim` (``inputs.reproNim``) admit moving the `repro.lock`
  ## dependency ``dependency`` (checked out at ``depAbs``, fetched from
  ## ``depUrl``) to ``observed``? A `uses:` entry is related to the dependency
  ## by its selector name, as H1 relates it (see the module header).
  ##
  ## * An unconditional exact version excludes every revision but the one its
  ##   producer's `versions:` entry maps it to; ``exactPin`` reports that
  ##   revision whether or not it excludes ``observed``, because a dependency
  ##   the recipe pins exactly is not compared with its checkout unless a
  ##   develop override substitutes it (§16.5), and only the caller knows
  ##   whether one does.
  ## * An unconditional range excludes ``observed`` when the producer's
  ##   `versions:` table maps ``observed`` to a version the range does not
  ##   admit. When no entry maps to it, the range is listed in ``notChecked``.
  ## * A conditional entry is listed in ``notChecked``, as H1 lists it.
  if not inputs.reproNim.present: return
  let decls = scanReproUsesDeclarations(inputs.reproNim.text,
    inputs.reproNim.path)
  var report: ConsistencyReport
  let dep = LockedDep(name: dependency, path: depAbs,
    coordinates: Coordinates(kind: ckVcs, url: depUrl))
  for decl in decls:
    let c = decl.constraint
    if c.selector != dependency: continue
    if c.kind notin {uckRange, uckExact}: continue
    let where = c.file & ":" & $c.line
    if decl.conditional:
      report.notChecked.add(where & ": '" & decl.rawConstraint &
        "' — under a when/if/case arm, so whether it constrains the re-pin " &
        "of '" & dependency & "' is not decidable without compiling the " &
        "recipe")
      continue
    if c.kind == uckExact:
      let mapped = exactRevisionOf(inputs, c, dep, report)
      if not mapped.found: continue
      result.exactPin = mapped.rev
      result.exactPinFile = c.file
      result.exactPinLine = c.line
      if mapped.rev != observed.toLowerAscii():
        result.exclusions.add(RepinConstraintExclusion(kind: rckExactVersion,
          dependency: dependency, repository: canonicalRepositoryUrl(depUrl),
          checkout: depAbs, observed: observed,
          constraintText: decl.rawConstraint, pinnedRev: mapped.rev,
          producerFile: mapped.producerFile, producerLine: mapped.producerLine,
          recipeFile: c.file, recipeLine: c.line))
    else:
      let at = versionAtRevision(inputs, c, depAbs, depUrl, observed, report)
      if at.found and not c.admits(at.version):
        result.exclusions.add(RepinConstraintExclusion(kind: rckRange,
          dependency: dependency, repository: canonicalRepositoryUrl(depUrl),
          checkout: depAbs, observed: observed,
          constraintText: decl.rawConstraint, observedVersion: at.version,
          producerFile: at.file, producerLine: at.line,
          recipeFile: c.file, recipeLine: c.line))
  result.notChecked = deduplicate(report.notChecked)

proc repinExclusionViolation*(e: RepinConstraintExclusion):
    ConsistencyViolation =
  ## THE refusal for a commit whose re-pin a recipe constraint stopped: the
  ## observed revision, the constrained value, the recipe line, and the two
  ## ways forward (§16.4). Rendered by ``renderConsistencyViolation`` like the
  ## H1 / H2 refusals, so the three read alike.
  ##
  ## Backticks mark only commands that run where the message is printed (see
  ## ``flakeRevPinEditRemedy``): the upgrade is the backticked `repro lock
  ## update <dependency> --to <observed>`, which rewrites the exact pin and
  ## moves both locks; edits are in words.
  let where = e.recipeFile & ":" & $e.recipeLine
  result = ConsistencyViolation(rule: crH3,
    system: (if e.kind == rckFlakeRev: "flake" else: "repro"),
    dependency: e.dependency, repository: e.repository,
    recipeFile: e.recipeFile, recipeLine: e.recipeLine,
    constraint: (if e.pinnedRev.len > 0: e.pinnedRev else: e.constraintText),
    resolved: e.observed)
  let statement =
    case e.kind
    of rckFlakeRev:
      " pins input '" & e.dependency & "' at revision " & e.pinnedRev
    of rckExactVersion:
      " requires '" & e.constraintText & "', which " & e.producerFile &
        ":" & $e.producerLine & " maps to sourceRevision " & e.pinnedRev
    of rckRange:
      " requires '" & e.constraintText & "', which does not admit version " &
        e.observedVersion & " (" & e.producerFile & ":" & $e.producerLine &
        " maps " & e.observed & " to it)"
  result.summary = "H3 (the commit-time re-pin moves lock resolutions, " &
    "never a recipe constraint): the sibling checkout " & e.checkout &
    " is at " & e.observed & ", but " & where & statement &
    "; the re-pin wrote nothing for this repository in either lock" &
    (if e.held.len > 0: " (" & e.held.join("; ") & ")" else: "")
  # (1) The intended upgrade.
  case e.kind
  of rckFlakeRev:
    result.remedies.add("If " & e.observed & " is the intended upgrade, " &
      flakeRevPinEditRemedy(e.dependency, e.pinnedRev, e.observed, e.repoRoot,
        e.pathForm) & "; it moves both locks with it, and then commit again")
  of rckExactVersion:
    result.remedies.add("If " & e.observed & " is the intended upgrade, " &
      "run `" & lockUpdateCommand(e.dependency, e.observed, e.repoRoot) &
      "`: it changes the uses: entry at " & where & " to the version whose " &
      "sourceRevision is " & e.observed & " and moves both locks with it " &
      "(it refuses when no versions: entry of " & e.producerFile & " maps " &
      e.observed & "; add that entry first); then commit again")
  of rckRange:
    result.remedies.add("If version " & e.observedVersion & " is the " &
      "intended upgrade, widen the range at " & where & " so it admits " &
      e.observedVersion & ", and commit again (repro lock update will not " &
      "widen a range: that is the author's decision)")
  # (2) The temporary experiment.
  let back = if e.pinnedRev.len > 0: e.pinnedRev else: e.lockedRev
  let checkoutCmd =
    if back.len > 0: "`git -C " & quoteShell(e.checkout) & " checkout " &
      back & "`"
    else: ""
  if e.overridden:
    result.remedies.add("If " & e.observed & " was a temporary experiment, " &
      "drop the develop override of '" & e.overrideRepo & "' (remove its " &
      "entry from " &
      (if e.overrideFiles.len > 0: e.overrideFiles.join(" and ")
       else: "the workspace's develop overrides") &
      "; no repro command removes a single override yet)" &
      (if checkoutCmd.len > 0:
         ", or check the sibling out at the " &
           (if e.pinnedRev.len > 0: "pinned" else: "locked") &
           " revision: " & checkoutCmd
       else: "") & "; then commit again")
  elif checkoutCmd.len > 0:
    result.remedies.add("If " & e.observed & " was a temporary experiment, " &
      "check the sibling out at a revision the recipe admits, such as the " &
      "one the locks name now: " & checkoutCmd & "; then commit again")
  result.evidence = "rule=H3 system=" & result.system & " dependency=" &
    e.dependency & " recipe=" & where & " constraint=" &
    quoteShell(result.constraint) & " observed=" & e.observed &
    (if e.observedVersion.len > 0: " version=" & e.observedVersion else: "") &
    " overridden=" & $e.overridden
