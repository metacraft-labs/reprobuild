## The `uses:` constraint grammar: one entry's selector and version text,
## classified, and whether it admits a version.
##
## "nim >=2.2 <3", "lib ==1.4.0", "git", "nimble:chronicles >=0.10": the
## selector is the first whitespace-separated token, optionally prefixed by an
## ecosystem namespace (`nimble:`; Package-Model.md § Ecosystem namespaces) (the split `usesSelectorOf` makes in the DSL
## runtime) and the rest is a range in the grammar
## `repro_solver/version_constraints.parseSemverRange` reads (`>=`, `<`, `^`,
## `~`, `=`, a bare or `v`-prefixed version, comma- or space-separated).
##
## It lives here, beside the range parser and depending on nothing else, so
## every reader of a `uses:` range uses this one: the lock refresh's recipe
## reader (`repro_cli_support/recipe_constraints`, which re-exports it) and
## the installed prefix's compiler check (`repro_core/installed_prefix_nim`),
## which sits below the CLI support library.

import std/strutils

import ./version_constraints

const
  NamespaceSeparator* = ':'
    ## Separates an ecosystem namespace from the package name in a selector:
    ## `nimble:chronicles` (Package-Model.md § Ecosystem namespaces). A plain
    ## package name never holds a colon, so the split is unambiguous.
  KnownNamespaces* = ["nimble"]
    ## The ecosystem namespaces an ecosystem spec defines. `nimble:` is the
    ## Nimble package catalog's (Nimble-Package-Catalog.md NPC-AREQ3); the
    ## next ecosystem adds its own here with its spec.

type
  SelectorNamespace* = object
    ## A `uses:` selector split at its namespace.
    namespace*: string ## "" for a plain name
    name*: string      ## the package name within the namespace
    defect*: string    ## why the selector is not a valid namespaced name

proc splitNamespace*(selector: string): SelectorNamespace =
  ## Split ``selector`` into its ecosystem namespace and package name:
  ## `nimble:zip` is (`nimble`, `zip`), `zip` is (``""``, `zip`). The
  ## namespace is part of the package's identity: the solver, the lock and
  ## `repro add` keep the full spelling. ``defect`` is set for a selector
  ## with an empty namespace or name, a second colon, or a namespace no
  ## ecosystem defines (``KnownNamespaces``).
  let at = selector.find(NamespaceSeparator)
  if at < 0:
    return SelectorNamespace(name: selector)
  result.namespace = selector[0 ..< at]
  result.name = selector[at + 1 .. ^1]
  if result.namespace.len == 0:
    result.defect = "'" & selector & "' has an empty namespace before `:`"
  elif result.name.len == 0:
    result.defect = "'" & selector & "' names no package after `" &
      result.namespace & ":`"
  elif NamespaceSeparator in result.name:
    result.defect = "'" & selector & "' has more than one `:`; a selector " &
      "is `<namespace>:<name>` or a plain name"
  elif result.namespace notin KnownNamespaces:
    result.defect = "'" & selector & "' names the namespace `" &
      result.namespace & ":`, which no ecosystem defines (known: " &
      KnownNamespaces.join(", ") & ")"

proc isNamespaced*(selector: string): bool =
  ## Does ``selector`` carry an ecosystem namespace (`nimble:zip`)?
  NamespaceSeparator in selector

type
  UsesConstraintKind* = enum
    uckUnconstrained   ## the entry names a package and no version
    uckRange           ## a range (`>=2.2 <3`, `^1.5`, `~2.1`)
    uckExact           ## an exact version (`==1.2.3`, `=1.2.3`, `1.2.3`)
    uckUnparseable     ## a version text the semver grammar rejects

  ReproUsesConstraint* = object
    ## What one `uses:` entry states about its package's version.
    selector*: string      ## the package the entry names, namespace included
    namespace*: string     ## its ecosystem namespace (`nimble`), or ""
    name*: string          ## the name within the namespace (`zip`)
    rangeText*: string     ## the version text after the selector, or ""
    kind*: UsesConstraintKind
    exactVersion*: string  ## the version an exact entry names, or ""
    range*: SemverRange    ## the parsed range (unbounded when unconstrained)
    diagnostic*: string    ## why the text is unparseable
    file*: string          ## the recipe the entry is written in
    line*: int             ## its line, or 0 when unknown

proc parseReproUsesConstraint*(rawConstraint: string; file = "";
    line = 0): ReproUsesConstraint =
  ## Split a `uses:` constraint ("lib ==1.4.0", "nim >=2.2 <3", "git") into
  ## its selector and version constraint, and classify the constraint. The
  ## selector is the first whitespace-separated token, the same split
  ## `usesSelectorOf` makes in the DSL runtime.
  result.file = file
  result.line = line
  result.range = unboundedRange()
  let text = rawConstraint.strip()
  let parts = text.splitWhitespace()
  if parts.len == 0:
    result.kind = uckUnparseable
    result.diagnostic = "empty uses: constraint"
    return
  result.selector = parts[0]
  let ns = splitNamespace(result.selector)
  result.namespace = ns.namespace
  result.name = ns.name
  if ns.defect.len > 0:
    result.kind = uckUnparseable
    result.diagnostic = ns.defect
    return
  if parts.len == 1:
    result.kind = uckUnconstrained
    return
  result.rangeText = text[text.find(parts[0]) + parts[0].len .. ^1].strip()
  try:
    result.range = parseSemverRange(result.rangeText)
  except ESemverParse as err:
    result.kind = uckUnparseable
    result.diagnostic = err.msg
    return
  # Exact when the text is ONE token with no bound operator, or an `=`/`==`
  # token: the forms `parseSingleConstraint` reads as an exact pin. Deciding
  # from the text rather than from the parsed bounds keeps `>=1.2.3 <1.2.4`
  # (a range that happens to admit one version) a range, as the author wrote.
  let tokens = result.rangeText.replace(",", " ").splitWhitespace()
  if tokens.len == 1:
    var t = tokens[0]
    var exact = false
    if t.startsWith("=="):
      t = t[2 .. ^1]; exact = true
    elif t.startsWith("="):
      t = t[1 .. ^1]; exact = true
    elif t.len > 0 and t[0] notin {'>', '<', '^', '~'}:
      exact = true
    if exact:
      if t.len > 0 and t[0] in {'v', 'V'}: t = t[1 .. ^1]
      result.kind = uckExact
      result.exactVersion = t.strip()
      return
  result.kind = uckRange

proc admits*(c: ReproUsesConstraint; version: string): bool =
  ## Does the constraint admit ``version``? An unconstrained entry admits
  ## every version; an unparseable constraint or version admits none.
  case c.kind
  of uckUnconstrained: true
  of uckUnparseable: false
  of uckExact, uckRange:
    try: satisfies(parseSemver(version.strip()), c.range)
    except ESemverParse: false

proc isComparableVersion*(version: string): bool =
  ## Can ``version`` be compared with a range at all? ``admits`` answers false
  ## both for a version outside the range and for one the grammar cannot read;
  ## a caller that must tell those apart asks this.
  try:
    discard parseSemver(version.strip())
    true
  except ESemverParse:
    false
