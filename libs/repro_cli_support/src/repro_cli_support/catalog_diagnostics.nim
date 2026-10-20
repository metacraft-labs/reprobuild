## Actionable catalog diagnostics at the CLI -- ReproOS-Campaign-Completion
## M6 deliverable 4.
##
## ``catalog_composition.composeCatalogs`` refuses with diagnostics that
## state WHAT is wrong in terms of catalog coordinates. A user reaches them
## through ``repro build`` (and every surface that resolves the same pins:
## inspection, ``repro develop``, dev-env activation), ``repro lock refresh
## --provisioning`` and the build-time lock-mismatch explanation. This module
## turns each one into something the user can act on, from the diagnostic's
## structured facts plus what only the CLI knows -- the consumer's
## ``repro-catalogs.toml`` (with the line of every table), its lock and the
## exact re-select command:
##
##   * every catalog is named by the ``repo`` and ``remote`` its import
##     declares, with the revision it was read at and the
##     ``repro-catalogs.toml`` line that imports it;
##   * every candidate is named with its contributor and the source location
##     its catalog published for it;
##   * the file to edit (``repro-catalogs.toml`` or the lock) and the exact
##     edit or command that resolves it are stated.
##
## Nothing here selects, refuses or accepts anything: the remedy lines are
## appended under a refusal that has already been made, and a refusal never
## becomes a success. Exit codes are those of the surfaces (``repro build``
## 1, ``repro lock refresh --provisioning`` 1; dev-env activation is never
## fatal and provisions nothing on a refusal). Paths in these lines are the
## consumer's own files on this host; they never reach a digest or the lock.

import std/[algorithm, os, sequtils, strutils]

import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/catalog_declaration
import repro_lock

import ./catalog_discovery

type
  CatalogRemedyContext* = object
    ## What the CLI knows about the consumer when it renders a remedy.
    projectRoot*: string
    lockPath*: string
    reselectCommand*: string
      ## The exact ``repro lock refresh --provisioning ...`` for this lock.
    declaration*: LocatedCatalogDeclaration
      ## The declaration the catalogs were read for; ``path`` empty when the
      ## catalog source did not read one (a test source).
    lockClaims*: seq[LockedRealization]
      ## The committed lock's records for the platform pair being resolved.

proc q(value: string): string = "\"" & value & "\""

proc declarationPath(ctx: CatalogRemedyContext): string =
  if ctx.declaration.path.len > 0: ctx.declaration.path
  else: ctx.projectRoot / CatalogImportsFileName

proc importAt(ctx: CatalogRemedyContext; repo: string): string =
  ## Where ``repo`` is imported: ``<path>:<line>``, or the declaration path
  ## alone when no import of that repo is known.
  let at = declarationLocation(ctx.declaration, repo)
  if at.len > 0: at else: declarationPath(ctx)

proc locationText(location: SourceLocation): string =
  ## A published source location, as the catalog published it. A current
  ## publisher writes it relative to the catalog repository's root.
  if location.file.len == 0:
    return "<unknown source>"
  location.file.replace('\\', '/') & ":" & $location.line

proc catalogText(c: CatalogCoordinate): string =
  catalogName(c.workspace, c.remote) &
    (if c.revision.len > 0: " at " & c.revision else: " (no revision)")

proc reselectText(ctx: CatalogRemedyContext): string =
  "re-select with `" & ctx.reselectCommand & "`"

proc contributionLine(ctx: CatalogRemedyContext;
                      p: CatalogDiagnosticParty): string =
  "contributor " & q(p.contributor) & " from " & catalogText(p.coordinate) &
    ", declared at " & locationText(p.location) & " (imported at " &
    importAt(ctx, p.coordinate.workspace) & ")"

proc ownerLine(ctx: CatalogRemedyContext; p: CatalogDiagnosticParty): string =
  catalogText(p.coordinate) & " declares interface " & p.interfaceFingerprint &
    " at " & locationText(p.location) & " (imported at " &
    importAt(ctx, p.coordinate.workspace) & ")"

proc policyLines(ctx: CatalogRemedyContext; package: string): seq[string] =
  for t in ctx.declaration.policyTables:
    if t.package == package:
      result.add(ctx.declaration.path & ":" & $t.line & " names " &
        q(t.contributor))

proc reposOf(parties: seq[CatalogDiagnosticParty]; owners: bool): seq[string] =
  for p in parties:
    if (p.contributor.len == 0) == owners and
        p.coordinate.workspace notin result:
      result.add(p.coordinate.workspace)
  result.sort(cmp)

proc remedyLines*(d: CatalogDiagnostic; ctx: CatalogRemedyContext;
                  all: seq[CatalogDiagnostic] = @[]): seq[string] =
  ## The lines that make ``d`` actionable (see the module docstring),
  ## unindented. Empty for no diagnostic kind: each one names what to edit.
  ## ``all``: every diagnostic of the same refusal, so a consequence (a
  ## policy left unsatisfied because its contributor's contributions were
  ## refused for another reason) points at its cause instead.
  let decl = declarationPath(ctx)
  # Refusals that make every contribution for a package ineligible: the
  # ones about it, and the ones about a catalog (which may be the owner of
  # its interface). A consequence names them instead of a wrong remedy.
  let catalogLevel = all.filterIt(it.kind in {cdIncompleteCoordinate,
    cdMissingCatalog, cdCatalogIdentityConflict})
  proc blockers(package: string): seq[string] =
    for b in all:
      if (b.packageName == package and b.kind in {
            cdDuplicateCanonicalInterface, cdIncompatibleFingerprint,
            cdUnknownTargetInterface}) or b in catalogLevel:
        if $b.kind notin result: result.add($b.kind)
  let contributions = d.parties.filterIt(it.contributor.len > 0)
  let owners = d.parties.filterIt(it.contributor.len == 0)
  case d.kind
  of cdAmbiguousContribution:
    result.add("candidates:")
    for p in contributions:
      result.add("  " & contributionLine(ctx, p))
    var repeated: seq[string] = @[]
    let ids = contributions.mapIt(it.contributor)
    for id in ids:
      if ids.count(id) > 1 and id notin repeated:
        repeated.add(id)
    repeated.sort(cmp)
    if repeated.len > 0:
      for id in repeated:
        let parties = contributions.filterIt(it.contributor == id)
        # The catalogs offering ``id``, each once, in party order: one
        # catalog may publish the contributor more than once, and that is
        # not two catalogs claiming it.
        var repos: seq[string] = @[]
        for p in parties:
          if p.coordinate.workspace notin repos:
            repos.add(p.coordinate.workspace)
        if repos.len == 1:
          result.add("fix: catalog " & q(repos[0]) & " (" &
            importAt(ctx, repos[0]) & ") publishes " & $parties.len &
            " contributions from contributor " & q(id) & " for " &
            q(d.packageName) & " (declared at " &
            parties.mapIt(locationText(it.location)).join(", ") & "). A " &
            "curator policy names a contributor, not one of its " &
            "contributions, so none can choose between them: pin " &
            q(repos[0]) & " at a revision that publishes one (the `commit` " &
            "or `ref` of its [[import]] in " & decl & "), or have its " &
            "publisher republish it with one; then " & reselectText(ctx))
          continue
        let offering = repos.mapIt(q(it) & " (" & importAt(ctx, it) & ")")
        result.add("fix: contributor " & q(id) & " is offered by " &
          $offering.len & " imported catalogs: " & offering.join(", ") &
          ". A contributor id names one publisher and no policy can choose " &
          "between two catalogs that claim it: remove the [[import]] of the " &
          "catalog that should not offer it from " & decl & " (or pin it at " &
          "a revision that does not), then " & reselectText(ctx))
    else:
      let choices = contributions.mapIt(q(it.contributor)).
        deduplicate().sorted(cmp)
      result.add("fix: in " & decl & ", add a curator policy naming one of " &
        choices.join(", ") & ":")
      result.add("    [[policy]]")
      result.add("    package = " & q(d.packageName))
      result.add("    contributor = " &
        (if choices.len > 0: choices[0] else: q("<contributor>")))
      result.add("  then " & reselectText(ctx))
  of cdDuplicateCanonicalInterface:
    result.add("owners:")
    for p in owners:
      result.add("  " & ownerLine(ctx, p))
    let owningRepos = reposOf(owners, true)
    if owningRepos.len == 1:
      # One catalog declaring the package twice, differently: no [[import]]
      # can be removed to resolve that.
      result.add("fix: catalog " & q(owningRepos[0]) & " (" &
        importAt(ctx, owningRepos[0]) & ") declares the canonical interface " &
        "of " & q(d.packageName) & " " & $owners.len & " times, differently " &
        "(at " & owners.mapIt(locationText(it.location)).join(", ") & "); " &
        "pin it at a revision that declares it once (the `commit` or `ref` " &
        "of its [[import]] in " & decl & "), or have its publisher " &
        "republish it; then " & reselectText(ctx))
      return
    result.add("fix: exactly one imported catalog may own the canonical " &
      "interface of " & q(d.packageName) & ": in " & decl & ", remove the " &
      "[[import]] of every owner but one (" &
      reposOf(owners, true).mapIt(q(it) & " at " & importAt(ctx, it)).
        join(", ") & "), then " & reselectText(ctx))
  of cdIncompatibleFingerprint:
    for p in contributions:
      result.add("contribution: " & contributionLine(ctx, p) &
        ", pinned to interface " & p.interfaceFingerprint)
    for p in owners:
      result.add("canonical interface: " & ownerLine(ctx, p))
    let offending = reposOf(contributions, false)
    let owning = reposOf(owners, true)
    var options: seq[string] = @[]
    for r in offending:
      options.add("pin catalog " & q(r) & " (" & importAt(ctx, r) & ") at a " &
        "revision published against interface " & d.canonicalFingerprint)
    for r in owning:
      options.add("pin catalog " & q(r) & " (" & importAt(ctx, r) & ") at " &
        "the revision whose interface the contribution names")
    for r in offending:
      options.add("remove the [[import]] of " & q(r))
    result.add("fix: in " & decl & ", " & options.join(", or ") & "; then " &
      reselectText(ctx) & ". The publisher of " &
      offending.mapIt(q(it)).join(", ") & " fixes it by republishing with " &
      "`interfaceFingerprint " & q(d.canonicalFingerprint) & "` at " &
      contributions.mapIt(locationText(it.location)).join(", "))
  of cdUnknownTargetInterface:
    for p in contributions:
      result.add("contribution: " & contributionLine(ctx, p))
    if catalogLevel.len > 0:
      result.add("fix: first resolve the " & catalogLevel.mapIt($it.kind).
        deduplicate().join(" and ") & " refusal for " &
        catalogLevel.mapIt(q(it.catalogs[0].workspace)).deduplicate().
          join(", ") & ": if that catalog owns the canonical interface of " &
        q(d.packageName) & ", this resolves too")
    result.add("fix: in " & decl & ", add an [[import]] for the catalog " &
      "that publishes the canonical interface of " & q(d.packageName) &
      ", or remove the [[import]] of " &
      reposOf(contributions, false).mapIt(q(it) & " (" & importAt(ctx, it) &
        ")").join(", ") & "; then " & reselectText(ctx))
  of cdPolicySelectionUnsatisfied:
    let named = d.named.mapIt(q(it)).join(", ")
    var where = policyLines(ctx, d.packageName)
    for p in contributions:
      result.add("eligible: " & contributionLine(ctx, p))
    let tables = if where.len > 0: " (" & where.join("; ") & ")" else: ""
    let causes = blockers(d.packageName)
    if d.eligible.len == 0 and causes.len > 0:
      result.add("fix: no contribution for " & q(d.packageName) & " is " &
        "eligible until the " & causes.join(" and ") & " refusal is " &
        "resolved; resolve that first (the [[policy]] for it" & tables &
        " can stay)")
    elif d.eligible.len > 0:
      result.add("fix: in " & decl & ", change the [[policy]] for package " &
        q(d.packageName) & tables & " to name one of the eligible " &
        "contributors " & d.eligible.mapIt(q(it)).join(", ") & ", or add " &
        "the [[import]] of the catalog that publishes " & named & "; then " &
        reselectText(ctx))
    else:
      result.add("fix: no imported catalog offers an eligible contribution " &
        "for " & q(d.packageName) & ": in " & decl & ", add the [[import]] " &
        "of the catalog that publishes " & named & ", or remove the " &
        "[[policy]] for it" & tables & "; then " & reselectText(ctx))
  of cdContradictoryPolicy:
    let where = policyLines(ctx, d.packageName)
    result.add("fix: in " & decl & ", keep exactly one [[policy]] table for " &
      "package " & q(d.packageName) &
      (if where.len > 0: " (" & where.join("; ") & ")" else: "") &
      " and delete the others, then " & reselectText(ctx))
  of cdLockedContributionUnavailable:
    for p in contributions:
      result.add("eligible: " & contributionLine(ctx, p))
    let causes = blockers(d.packageName)
    if d.eligible.len == 0 and causes.len > 0:
      result.add("fix: no contribution for " & q(d.packageName) & " is " &
        "eligible until the " & causes.join(" and ") & " refusal is " &
        "resolved; resolve that first (the lock " & ctx.lockPath &
        " need not change)")
      return
    result.add("fix: the lock " & ctx.lockPath & " pins contributor " &
      d.named.mapIt(q(it)).join(", ") & " for " & q(d.packageName) &
      ", which no imported catalog offers (eligible: " &
      (if d.eligible.len > 0: d.eligible.mapIt(q(it)).join(", ")
       else: "none") & "). " & reselectText(ctx).capitalizeAscii() &
      " (rewrites the lock's provisioning records from the catalogs and " &
      "the curator policy in " & decl & "), or restore the lock from " &
      "version control if it was edited by hand")
  of cdContradictoryLock:
    result.add("fix: the lock " & ctx.lockPath & " carries records naming " &
      d.named.mapIt(q(it)).join(", ") & " for " & q(d.packageName) &
      " on one platform pair; restore it from version control, or " &
      reselectText(ctx))
  of cdIncompleteCoordinate:
    for c in d.catalogs:
      result.add("fix: the catalog source supplied an incomplete " &
        "coordinate for " & catalogText(c) & "; every import needs `repo`, " &
        "`remote` and a `commit` or `ref` in " & importAt(ctx, c.workspace) &
        ", and the lock a full pin: " & reselectText(ctx))
  of cdMissingCatalog:
    for c in d.catalogs:
      result.add("fix: fetch " & catalogName(c.workspace, c.remote) &
        " at " & c.revision & " into the workspace's shared clone (`repro " &
        "ws sync`), or remove its [[import]] (" & importAt(ctx, c.workspace) &
        "); then " & reselectText(ctx))
  of cdCatalogIdentityConflict:
    for c in d.catalogs:
      result.add("fix: " & catalogText(c) & " was read with different " &
        "contents; keep one [[import]] of " & q(c.workspace) & " in " & decl &
        " (" & importAt(ctx, c.workspace) & "), then " & reselectText(ctx))

proc resolverRemedyLines(refusal: string; ctx: CatalogRemedyContext;
                         policy: seq[CatalogPolicyDeclaration]): seq[string] =
  ## Remedies for the resolver's own refusals that name a file to edit
  ## beyond the trailing re-select command.
  for kind in ["contribution-changed:", "interface-changed:",
               "catalog-changed:", "realization-changed:",
               "lock-claim-missing:"]:
    if refusal.startsWith(kind):
      return @["fix: the lock " & ctx.lockPath & " no longer describes " &
        "what the catalogs it pins offer; " & reselectText(ctx) &
        " to adopt what they offer now (it prints what changed), or " &
        "restore the lock from version control if it was edited by hand"]
  if refusal.startsWith("policy-contradicts-lock:"):
    for r in ctx.lockClaims:
      for t in policy:
        if t.package == r.packageName and t.contributor != r.contributor and
            ("for package \"" & r.packageName & "\"") in refusal:
          result.add("fix: to adopt the curator policy (" &
            ctx.declaration.path & ":" & $t.line & " names " &
            q(t.contributor) & "), " & reselectText(ctx) & "; to keep the " &
            "locked selection, change that [[policy]] back to contributor " &
            q(r.contributor))

proc withRemedies*(refusals: seq[string]; diagnostics: seq[CatalogDiagnostic];
                   ctx: CatalogRemedyContext; indent = "  "): seq[string] =
  ## ``refusals`` (each ``"<kind>: <message>"`` or a resolver refusal), each
  ## followed by its remedy lines indented by ``indent`` -- one string per
  ## refusal, the remedy lines joined to it with newlines. A refusal with no
  ## remedy is returned unchanged.
  for r in refusals:
    var lines: seq[string] = @[]
    for d in diagnostics:
      if r == $d.kind & ": " & d.message:
        lines = remedyLines(d, ctx, diagnostics)
        break
    if lines.len == 0:
      lines = resolverRemedyLines(r, ctx, ctx.declaration.policyTables)
    if lines.len == 0:
      result.add(r)
    else:
      result.add(r & "\n" & lines.mapIt(indent & it).join("\n"))
