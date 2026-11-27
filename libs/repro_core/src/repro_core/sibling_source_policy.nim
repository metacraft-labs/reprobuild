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
    pinMissing*: bool
      ## the pin is observed NOT to be a commit in the sibling's object
      ## store: it was never fetched there. Such a sibling cannot be at or
      ## ahead of the pin, so it is judged as any other that is not; the
      ## field only changes what the report says, because the remedy starts
      ## with a fetch. False when not observed.

  SiblingSourceKind* = enum
    sskSibling        ## compile against the sibling checkout
    sskEnvPin         ## compile against the tree `$<PKG>_SRC` names
    sskStaleSibling
      ## the sibling is NOT at or ahead of the pin, carries no local changes,
      ## and no pinned tree was named: the only checkout there is is stale.
      ## `config.nims` compiles against it and says so (it never stops a
      ## compile, see its `reportUnresolvedPackagePath`); the engine's recipe
      ## compiles refuse rather than compile a recipe against the wrong
      ## sources (`repro_interface_artifacts`, `SiblingSourceUnavailableError`),
      ## except that a packaged engine compiling against its OWN source tree
      ## uses the root it was built with, which is the pin, and says so
      ## (`repro_interface_artifacts.staleSiblingRoot`)
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

const SiblingPinnedPackagesEnvVar* = "REPRO_SIBLING_PINNED"
  ## A comma-separated list of `<PKG>_SRC` names whose package takes the
  ## tree `$<PKG>_SRC` names, as `REPRO_SIBLING_POLICY=pin` would, whatever
  ## `REPRO_SIBLING_POLICY` says for the others. The engine sets it in the
  ## environment of a compile that evaluates the recipe's `config.nims`
  ## itself (the provider compile), for each package whose stale sibling it
  ## replaced: there the file cannot judge the sibling on its own -- that
  ## compile's `PATH` has no `git`, and "cannot tell" keeps the sibling --
  ## and must not, since the engine's verdict (made against the pins of the
  ## tree it compiles) is the one the command's own `--path`s already carry.

proc siblingPolicyFor*(envName, policyValue, pinnedValue: string):
    SiblingPolicy =
  ## The policy for the package `$envName` names: `spPin` when
  ## ``pinnedValue`` (`$REPRO_SIBLING_PINNED`) lists it, else
  ## ``policyValue`` (`$REPRO_SIBLING_POLICY`).
  for item in pinnedValue.split(','):
    if item.strip() == envName:
      return spPin
  parseSiblingPolicy(policyValue)

# ---------------------------------------------------------------------------
# Judging ahead of an evaluation that cannot run git.
#
# `nim check` and nimsuggest evaluate `config.nims` with `gorgeEx` (and
# `staticExec`) answering ("", 0) for every command, so the file cannot ask
# git where a sibling stands, and every sibling reads as "cannot tell" --
# which keeps it. A stale `../nim-cli-spec` was compiled that way by the
# `nim check` sweep of `just lint` while `nim c` in the same shell would have
# taken the pinned `$CLI_SPEC_SRC`, and the sweep failed on `undeclared
# identifier` with no line naming the sibling (measured 2026-11-26).
#
# So a driver of such evaluations judges first, in an evaluation that CAN
# run git (`nim dump`), and hands the verdicts on:
#
#   * `REPRO_SIBLING_VERDICTS_OUT=<file>` asks that evaluation to write one
#     line per sibling it did not compile as it is (`formatSiblingVerdict`);
#   * the driver prints each line's message once, lists every `pin` verdict
#     in `$REPRO_SIBLING_PINNED` (so the blind evaluations take the pinned
#     tree too), and sets `REPRO_SIBLING_JUDGED=1`, which tells every
#     evaluation the siblings were judged and reported for it, so none
#     repeats the report.
#
# A blind evaluation with neither says so itself for a sibling whose HEAD is
# not the pin, rather than compiling it in silence.
# ---------------------------------------------------------------------------

const
  SiblingVerdictsOutEnvVar* = "REPRO_SIBLING_VERDICTS_OUT"
    ## A file the evaluation of `config.nims` appends its verdicts to.
  SiblingJudgedEnvVar* = "REPRO_SIBLING_JUDGED"
    ## `1`: the siblings of this evaluation were judged, and reported, by
    ## the caller, which evaluated `config.nims` where git runs.

type SiblingVerdictKind* = enum
  svkPin = "pin"
    ## the pinned tree `$<PKG>_SRC` names replaces the sibling
  svkStale = "stale"
    ## the stale sibling is compiled, because no pinned tree is named

proc formatSiblingVerdict*(kind: SiblingVerdictKind;
    envName, message: string): string =
  ## One verdict line: `<kind>\t<envName>\t<message>\n`, the message on
  ## one line (tabs and line breaks become spaces) so a shell reader can
  ## split it with `IFS=$'\t' read -r`.
  var flat = newStringOfCap(message.len)
  for c in message:
    flat.add(if c in {'\t', '\n', '\r'}: ' ' else: c)
  $kind & "\t" & envName & "\t" & flat & "\n"

# ---------------------------------------------------------------------------
# flake.lock: the pins the development shell exports.
#
# reprobuild's `flake.lock` pins io-mon, nim-shm-gset, runquota and others
# that its `repro.lock` does not list, and the development shell exports
# exactly those trees as `$IO_MON_SRC`, `$SHM_GSET_SRC`, `$RUNQUOTA_SRC`, ...
# (Nix-Flake-Coexistence.md §3.2). It is the record of the revision every
# in-shell compile reads, so a pin lookup must not depend on a second copy of
# it being kept in `.github/sibling-repos` (which today repeats some of these
# pins and names others only by a branch). The judgement this lookup feeds
# (`chooseSiblingSource`) is what keeps a stale sibling out of a compile: a
# sibling checkout 94 commits behind the pinned io-mon was compiled into the
# dev env's interface extraction without a word, and the compile failed on an
# `undeclared routine` naming neither checkout (measured 2026-11-21, `repro
# exec` in a reprobuild checkout).
#
# A deliberately small scanner, not `std/json`: `config.nims` runs this in
# the NimScript VM on every compile, where `parseJson` of the 85 KB lock costs
# about half a second and this scan under a tenth of one (measured
# 2026-11-22, `nim e`, Nim 2.2.4), once per load (`flakeLockDirectPins`). It
# walks the JSON grammar (https://www.rfc-editor.org/rfc/rfc8259) once, keeps
# only the fields of the lock format it needs (`nodes.<n>.inputs`,
# `nodes.<n>.locked`, `root`;
# https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-flake#lock-files),
# and gives up -- "" , "cannot tell" -- on anything malformed.
# ---------------------------------------------------------------------------

type
  FlakeLockNode = object
    name: string
    inputs: seq[string]
      ## the nodes its inputs name DIRECTLY (a string value). An input that
      ## `follows` another flake's input (a list value) is that flake's
      ## choice, not this one's, and is not kept.
    lockedType, lockedRepo, lockedUrl, lockedRev: string

proc flakeSkipWs(t: string; i: var int) =
  while i < t.len and t[i] in {' ', '\t', '\n', '\r'}: inc i

proc flakeString(t: string; i: var int; ok: var bool): string =
  ## A JSON string at ``i`` (which must be its opening quote). Escapes are
  ## decoded except `\uXXXX`, kept as written: no name, URL or revision
  ## in a lock carries one, and a kept escape only fails to match.
  if i >= t.len or t[i] != '"':
    ok = false
    return ""
  inc i
  while i < t.len:
    let c = t[i]
    if c == '"':
      inc i
      return
    if c == '\\' and i + 1 < t.len:
      let e = t[i + 1]
      case e
      of 'n': result.add('\n')
      of 't': result.add('\t')
      of 'r': result.add('\r')
      of 'b': result.add('\b')
      of 'f': result.add('\f')
      of 'u': result.add("\\u")
      else: result.add(e)
      i += 2
    else:
      result.add(c)
      inc i
  ok = false

proc flakeSkipValue(t: string; i: var int; ok: var bool) =
  ## Skips one JSON value of any kind at ``i``.
  flakeSkipWs(t, i)
  if i >= t.len:
    ok = false
    return
  case t[i]
  of '"':
    discard flakeString(t, i, ok)
  of '{', '[':
    let close = if t[i] == '{': '}' else: ']'
    inc i
    flakeSkipWs(t, i)
    if i < t.len and t[i] == close:
      inc i
      return
    while ok and i < t.len:
      if close == '}':
        discard flakeString(t, i, ok)
        flakeSkipWs(t, i)
        if i >= t.len or t[i] != ':':
          ok = false
          return
        inc i
      flakeSkipValue(t, i, ok)
      flakeSkipWs(t, i)
      if i < t.len and t[i] == ',':
        inc i
        flakeSkipWs(t, i)
      elif i < t.len and t[i] == close:
        inc i
        return
      else:
        ok = false
  else:
    # A number, `true`, `false` or `null`: up to the next delimiter. A
    # delimiter where a value belongs is malformed, and stops the scan.
    let start = i
    while i < t.len and t[i] notin {',', '}', ']', ' ', '\t', '\n', '\r'}:
      inc i
    if i == start: ok = false

proc flakeObjectKey(t: string; i: var int; ok: var bool;
    first: var bool): tuple[present: bool, key: string] =
  ## The next key of the object whose `{` has been consumed, positioned
  ## after its `:`; (false, "") at the closing `}`.
  flakeSkipWs(t, i)
  if not first:
    if i < t.len and t[i] == ',':
      inc i
      flakeSkipWs(t, i)
    elif i < t.len and t[i] == '}':
      inc i
      return (false, "")
    else:
      ok = false
      return (false, "")
  elif i < t.len and t[i] == '}':
    inc i
    return (false, "")
  first = false
  let key = flakeString(t, i, ok)
  flakeSkipWs(t, i)
  if not ok or i >= t.len or t[i] != ':':
    ok = false
    return (false, "")
  inc i
  flakeSkipWs(t, i)
  (true, key)

proc flakeOpenObject(t: string; i: var int): bool =
  ## Consumes a `{` at ``i``; false (without consuming) when the value
  ## there is not an object.
  flakeSkipWs(t, i)
  if i < t.len and t[i] == '{':
    inc i
    return true
  false

proc flakeNode(t: string; i: var int; ok: var bool; name: string):
    FlakeLockNode =
  result.name = name
  if not flakeOpenObject(t, i):
    flakeSkipValue(t, i, ok)
    return
  var first = true
  while ok:
    let (present, key) = flakeObjectKey(t, i, ok, first)
    if not present: break
    if key == "inputs" and flakeOpenObject(t, i):
      var firstInput = true
      while ok:
        let (more, _) = flakeObjectKey(t, i, ok, firstInput)
        if not more: break
        if i < t.len and t[i] == '"':
          result.inputs.add(flakeString(t, i, ok))
        else:
          flakeSkipValue(t, i, ok)
    elif key == "locked" and flakeOpenObject(t, i):
      var firstField = true
      while ok:
        let (more, field) = flakeObjectKey(t, i, ok, firstField)
        if not more: break
        if i < t.len and t[i] == '"' and
            field in ["type", "repo", "url", "rev"]:
          let value = flakeString(t, i, ok)
          case field
          of "type": result.lockedType = value
          of "repo": result.lockedRepo = value
          of "url": result.lockedUrl = value
          else: result.lockedRev = value
        else:
          flakeSkipValue(t, i, ok)
    else:
      flakeSkipValue(t, i, ok)

proc parseFlakeLock(t: string; nodes: var seq[FlakeLockNode];
    root: var string): bool =
  var ok = true
  var i = 0
  root = "root"
  if not flakeOpenObject(t, i): return false
  var first = true
  while ok:
    let (present, key) = flakeObjectKey(t, i, ok, first)
    if not present: break
    if key == "nodes" and flakeOpenObject(t, i):
      var firstNode = true
      while ok:
        let (more, name) = flakeObjectKey(t, i, ok, firstNode)
        if not more: break
        nodes.add(flakeNode(t, i, ok, name))
    elif key == "root" and i < t.len and t[i] == '"':
      root = flakeString(t, i, ok)
    else:
      flakeSkipValue(t, i, ok)
  ok

proc flakeNodeRepositoryName(node: FlakeLockNode): string =
  ## The name of the repository a locked node fetches: the `repo` of a
  ## forge reference (`github:`, `gitlab:`, `sourcehut:`), else the last
  ## path component of its URL without a `.git` suffix (`git+https://…/
  ## nim-bearssl` is `nim-bearssl`). "" for a node that fetches no
  ## repository (`path:`, `indirect`).
  case node.lockedType
  of "github", "gitlab", "sourcehut":
    return node.lockedRepo
  of "git", "mercurial", "tarball", "file":
    var url = node.lockedUrl
    for sep in ['?', '#']:
      let at = url.find(sep)
      if at >= 0: url = url[0 ..< at]
    while url.endsWith("/"): url.setLen(url.len - 1)
    let slash = url.rfind('/')
    var base = if slash >= 0: url[slash + 1 .. ^1] else: url
    if base.endsWith(".git"): base.setLen(base.len - 4)
    return base
  else:
    return ""

type FlakeLockPin* = tuple[repository, revision: string]
  ## One repository a `flake.lock` pins through a direct input of its root.

proc flakeLockDirectPins*(flakeLockText: string): seq[FlakeLockPin] =
  ## Every repository the committed `flake.lock` (``flakeLockText``) pins
  ## through an input its ROOT names directly, keyed by the repository the
  ## locked node fetches (``flakeNodeRepositoryName``), NEVER by the input's
  ## name: the input is `io-mon-src`, the sibling directory `io-mon`, and
  ## nothing ties the two spellings together but the locked repo.
  ##
  ## Only direct inputs count. The lock also holds the nodes of every
  ## transitive input -- io-mon's own pins of its dependencies among them --
  ## and those are other repositories' choices, not this one's; an input the
  ## root takes by `follows` is likewise another flake's choice. When two
  ## direct inputs fetch one repository at different revisions there is no
  ## one pin: the entry's revision is "" ("cannot tell", which keeps the
  ## sibling, as an unpinned one is kept). Empty for an empty or malformed
  ## lock.
  ##
  ## Parsed ONCE per lock: `config.nims` keeps the result for every package
  ## it registers (`flakeLockPins` there) rather than rescan 85 KB in the VM
  ## per package.
  if flakeLockText.len == 0:
    return
  var nodes: seq[FlakeLockNode]
  var rootName: string
  if not parseFlakeLock(flakeLockText, nodes, rootName):
    return
  var rootInputs: seq[string]
  for node in nodes:
    if node.name == rootName:
      rootInputs = node.inputs
      break
  for target in rootInputs:
    for node in nodes:
      if node.name != target or node.lockedRev.len == 0: continue
      let repository = flakeNodeRepositoryName(node).toLowerAscii()
      if repository.len == 0: continue
      var seen = false
      for entry in result.mitems:
        if entry.repository == repository:
          seen = true
          if entry.revision != node.lockedRev: entry.revision = ""
      if not seen:
        result.add((repository: repository, revision: node.lockedRev))

proc pinnedFlakeInputRevisionIn*(flakePins: openArray[FlakeLockPin];
    name: string): string =
  ## The revision ``flakePins`` (`flakeLockDirectPins`) holds for the
  ## repository ``name``, compared without regard to case; "" when it holds
  ## none or no single one.
  let wanted = name.toLowerAscii()
  for entry in flakePins:
    if entry.repository == wanted:
      return entry.revision
  ""

proc pinnedFlakeInputRevisionIn*(flakeLockText, name: string): string =
  ## `pinnedFlakeInputRevisionIn` over the text of a `flake.lock`.
  pinnedFlakeInputRevisionIn(flakeLockDirectPins(flakeLockText), name)

proc pinnedSiblingRevisionIn*(lockText: string;
    flakePins: openArray[FlakeLockPin]; siblingReposText, name: string):
    string =
  ## The revision a repository pins for the sibling directory ``name``, from
  ## the first of its three records that pins it:
  ##
  ##   1. its `deps` entry in the committed `repro.lock` (``lockText``): the
  ##      workspace lock is THE record of a sibling's revision, and
  ##      `repro lock update` and the commit-time re-pin keep the flake in
  ##      step with it;
  ##   2. a direct input of the committed `flake.lock` (``flakePins``, as
  ##      `flakeLockDirectPins` reads it) for a sibling `repro.lock` does not
  ##      pin: the revision the development shell exports as `$<PKG>_SRC`,
  ##      and so the tree every in-shell compile of this repository reads;
  ##   3. a `name=<sha>` / `name!=<sha>` line of `.github/sibling-repos`
  ##      (``siblingReposText``). Last, because its value may be a branch
  ##      (`codetracer=dev`) where the other two hold revisions, and a commit
  ##      id it does hold must equal flake.lock's
  ##      (`scripts/check_sibling_lock_pins.py`).
  ##
  ## "" when none pins it.
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
  let flakePin = pinnedFlakeInputRevisionIn(flakePins, name)
  if flakePin.len > 0:
    return flakePin
  for raw in siblingReposText.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    for sep in ["!=", "="]:
      let at = line.find(sep)
      if at > 0 and line[0 ..< at] == name:
        return line[at + sep.len .. ^1].strip()
  ""

proc shortRevision*(rev: string): string =
  ## The first twelve characters of a revision, as every report prints it.
  if rev.len > 12: rev[0 ..< 12] else: rev

proc siblingIsStale(obs: SiblingObservation): bool =
  ## Behind (or off the line of) its pin, with no local changes. Only a real
  ## observation says so: an unread HEAD, an unread status or no pin keeps
  ## the checkout, as `config.nims` always did ("cannot tell" is not
  ## "stale"). `nim check` answers every probe with ("", 0), which lands here.
  obs.pin.len > 0 and obs.headRev.len >= 12 and obs.dirtyKnown and
    not obs.dirty and not obs.atOrAhead

proc staleReason(obs: SiblingObservation): string =
  if obs.pinMissing:
    return "the sibling is at " & shortRevision(obs.headRev) &
      " and lacks the revision " & shortRevision(obs.pin) &
      " this repository pins, which was never fetched into it: fetch it " &
      "first; it carries no local changes"
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
