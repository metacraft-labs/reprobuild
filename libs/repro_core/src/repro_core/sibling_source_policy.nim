## Which tree a sibling-first package compiles from: the developer's sibling
## checkout, or the pinned tree a `$<PKG>_SRC` variable names.
##
## ONE routine for two callers that must not disagree (Unified-Locking-And-
## Hooks.md §13.5, "The sources a recipe compile reads", amended 2026-11-22):
##
##   * reprobuild's own `config.nims`, which `just lint`, `just build` and
##     every compile inside this repository load (`addSiblingFirstPackagePath`);
##   * the engine's recipe compiles — the interface extraction behind the
##     pre-push gate's dependency-set check, and the provider compile — which
##     do NOT load that file and replay its package paths
##     (`repro_interface_artifacts.bootstrapSiblingPackagePathFlags`).
##
## Before this module the engine's replay put `$<PKG>_SRC` first and the
## sibling second, whatever the sibling's relation to the pin, and it took
## the path compiled INTO the engine when neither was there. So the gate
## compiled reprobuild's recipe against a different `nim-shm-gset` than
## `just lint` did, and the answer depended on the pusher's shell.
##
## The decision is PURE so NimScript can run it: the caller observes (reads
## the lock, asks git) and hands the observations in. `config.nims` observes
## with `gorgeEx`; the engine with
## `repro_interface_artifacts.observeSiblingCheckout`, beside the other git
## lookups that module already makes, the same three questions.

import std/strutils

const
  SiblingPolicyEnvVar* = "REPRO_SIBLING_POLICY"
    ## `sibling` or `pin` forces the choice; anything else (unset) decides by
    ## the sibling's relation to the pin.

  RepositorySelectingGitVariables* = ["GIT_DIR", "GIT_WORK_TREE",
    "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX"]
    ## A git hook exports the variables that select THE HOOK'S repository, and
    ## `git -C` does not override them: under the pre-commit `just lint`,
    ## `rev-parse HEAD` answered reprobuild's own HEAD for every sibling
    ## (measured 2026-11-18), and the pre-push gate runs inside a hook too. A
    ## probe of a sibling clears them.

type
  SiblingPolicy* = enum
    spAuto       ## decide by the sibling's relation to the pin
    spSibling    ## `REPRO_SIBLING_POLICY=sibling`: always the checkout
    spPin        ## `REPRO_SIBLING_POLICY=pin`: always the pinned tree

  SiblingObservation* = object
    ## What the caller observed about one sibling-first package.
    siblingPresent*: bool
      ## the sibling checkout exists and holds the package's marker file
    envPinPresent*: bool
      ## `$<PKG>_SRC`, as the CALLER set it, names a tree that holds the
      ## marker and is not the sibling itself. A value the engine seeded from
      ## its own build is not one (`explicitSourceEnv`).
    pin*: string
      ## the revision this repository pins for the sibling
      ## (`pinnedSiblingRevisionIn`), "" when it pins none
    headRev*: string
      ## the sibling's HEAD, "" when it could not be read
    dirtyKnown*: bool
      ## whether ``dirty`` was observed
    dirty*: bool
      ## the sibling carries uncommitted changes to tracked files
    atOrAhead*: bool
      ## the pin is an ancestor of (or is) HEAD

  SiblingSourceKind* = enum
    sskSibling        ## compile against the sibling checkout
    sskEnvPin         ## compile against the tree `$<PKG>_SRC` names
    sskStaleSibling
      ## the sibling is NOT at or ahead of the pin, carries no local changes,
      ## and no pinned tree was named: the only checkout there is is stale.
      ## `config.nims` compiles against it and says so (it never stops a
      ## compile, see its `reportUnresolvedPackagePath`); the engine's recipe
      ## compiles refuse rather than compile a recipe against the wrong
      ## sources (`repro_interface_artifacts`, `SiblingSourceUnavailableError`)
    sskAbsent
      ## no sibling checkout: the caller's fallbacks decide

  SiblingSourceChoice* = object
    kind*: SiblingSourceKind
    why*: string        ## the reason, in the words the caller prints

proc parseSiblingPolicy*(value: string): SiblingPolicy =
  case value.strip().toLowerAscii()
  of "sibling": spSibling
  of "pin": spPin
  else: spAuto

proc pinnedSiblingRevisionIn*(lockText, siblingReposText, name: string):
    string =
  ## The revision a repository pins for the sibling directory ``name``: its
  ## `deps` entry in the committed `repro.lock` (``lockText``), else a
  ## `name=<sha>` / `name!=<sha>` line of `.github/sibling-repos`
  ## (``siblingReposText``, which lists a sibling `repro.lock` pins by its
  ## bare name only). "" when neither pins it.
  if lockText.len > 0:
    # One inline table per `deps` entry, with no nested braces.
    # A name also heads its `packages` entry, which has no revision.
    let key = "{ name = \"" & name & "\","
    let field = "revision = \""
    var at = lockText.find(key)
    while at >= 0:
      let stop = lockText.find('}', at)
      let revAt = lockText.find(field, at)
      if stop > at and revAt > at and revAt < stop:
        let start = revAt + field.len
        let close = lockText.find('"', start)
        if close > start: return lockText[start ..< close]
      at = lockText.find(key, at + key.len)
  for raw in siblingReposText.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    for sep in ["!=", "="]:
      let at = line.find(sep)
      if at > 0 and line[0 ..< at] == name:
        return line[at + sep.len .. ^1].strip()
  ""

proc shortRevision(rev: string): string =
  if rev.len > 12: rev[0 ..< 12] else: rev

proc siblingIsStale(obs: SiblingObservation): bool =
  ## Behind (or off the line of) its pin, with no local changes. Only a real
  ## observation says so: an unread HEAD, an unread status or no pin keeps
  ## the checkout, as `config.nims` always did ("cannot tell" is not
  ## "stale"). `nim check` answers every probe with ("", 0), which lands here.
  obs.pin.len > 0 and obs.headRev.len >= 12 and obs.dirtyKnown and
    not obs.dirty and not obs.atOrAhead

proc staleReason(obs: SiblingObservation): string =
  "the sibling is at " & shortRevision(obs.headRev) & ", which is not at " &
    "or ahead of the revision " & shortRevision(obs.pin) &
    " this repository pins, and carries no local changes"

proc chooseSiblingSource*(policy: SiblingPolicy;
    obs: SiblingObservation): SiblingSourceChoice =
  ## Sibling-first, but never silently against the pin:
  ##
  ##   * no sibling checkout -> `sskAbsent`;
  ##   * `REPRO_SIBLING_POLICY=sibling` -> the sibling;
  ##   * a pinned tree named and `REPRO_SIBLING_POLICY=pin` -> that tree;
  ##   * a pinned tree named and the sibling stale (``siblingIsStale``) ->
  ##     that tree;
  ##   * no pinned tree named and the sibling stale -> `sskStaleSibling`;
  ##   * `REPRO_SIBLING_POLICY=pin`, no pinned tree named, and a sibling
  ##     whose HEAD is observed NOT to be the pin -> `sskStaleSibling`: the
  ##     pin was asked for and only another revision is available;
  ##   * otherwise (at or ahead of the pin, dirty, or not observable) -> the
  ##     sibling, the developer's intent.
  if not obs.siblingPresent:
    return SiblingSourceChoice(kind: sskAbsent)
  if policy == spSibling:
    return SiblingSourceChoice(kind: sskSibling,
      why: SiblingPolicyEnvVar & "=sibling")
  if obs.envPinPresent:
    if policy == spPin:
      return SiblingSourceChoice(kind: sskEnvPin,
        why: SiblingPolicyEnvVar & "=pin")
    if siblingIsStale(obs):
      return SiblingSourceChoice(kind: sskEnvPin, why: staleReason(obs))
    return SiblingSourceChoice(kind: sskSibling)
  if siblingIsStale(obs):
    return SiblingSourceChoice(kind: sskStaleSibling, why: staleReason(obs))
  if policy == spPin and obs.pin.len > 0 and obs.headRev.len >= 12 and
      not obs.headRev.startsWith(obs.pin) and not obs.pin.startsWith(obs.headRev):
    return SiblingSourceChoice(kind: sskStaleSibling,
      why: SiblingPolicyEnvVar & "=pin, and the sibling is at " &
        shortRevision(obs.headRev) & ", not at the revision " &
        shortRevision(obs.pin) & " this repository pins")
  SiblingSourceChoice(kind: sskSibling)
