## ``repro_solver/lock_pins`` — Named-Lock-Files NLF-M3: the transport that
## carries a COMMITTED LOCK's answer from the process that read it to the
## process that solves.
##
## `Named-Lock-Files.md` §1.2 measures what the committed lock did before this
## module existed: the CLI read it, forwarded only its VARIANT assignments into
## `REPRO_VARIANTS`, and dropped `solution.packages` on the floor. Both halves
## were defects. The variant half arrived as an ordinary `prSet` contribution,
## which the encoder renders as a `#minimize` WEIGHT — a preference a model
## scoring better elsewhere can outvote — and the version half did not arrive
## at all, so version concretization re-ran fully unpinned even with a lock
## present. A lock that biases is not a lock.
##
## ## Why a transport at all
##
## The reader and the solver are different processes. `repro build` resolves
## the governing lock in the CLI (`resolveSolvedGraphForBuild`); the solve runs
## at module initialization inside the compiled project provider. The two
## communicate over the environment, which is the same contract
## `REPRO_VARIANTS` (`--variant`), `REPRO_DEVELOP_OVERRIDES_FILE` (develop
## overrides) and `REPRO_EMIT_SOLVER_INPUTS` already use.
##
## ## Why the grammar lives HERE and not on either side of it
##
## Both sides can already see `repro_solver`: the CLI imports it for
## `UnifiedSolution`, and `repro_dsl_stdlib/configurables/variants.nim` imports
## it for the encoders it feeds. Neither can see the other — the DSL stdlib
## deliberately does not import the CLI, and the CLI deliberately does not
## import the DSL stdlib (its `REPRO_VARIANTS` and `REPRO_EMIT_SOLVER_INPUTS`
## handling is duplicated with a "MUST match" comment for exactly that reason).
## Putting the writer and the reader of one grammar in one module removes the
## opportunity for those two copies to drift, which for a lock transport is not
## a cosmetic risk: a reader that silently fails to understand what the writer
## emitted un-pins the graph and reports nothing.
##
## This module holds NO solver dependency of its own (std only), so importing
## it costs neither side anything.
##
## ## The grammar
##
## ```
## REPRO_LOCK_PINS = "pkg:libfoo=1.4.0,pkg:zlib=1.3.1,var:enableTls=true"
## REPRO_LOCK_PATH = "/abs/path/to/repro.lock"
## ```
##
## Entries are comma-separated; each is `<kind>:<name>=<value>` with `kind` in
## `pkg` / `var`. Packages come first, then variants, each run sorted by name,
## so the rendering is canonical — the same lock always produces the same
## string. `REPRO_LOCK_PATH` names the lock the pins came from and exists so a
## conflict diagnostic can say WHICH lock is disagreeing with the recipe.
##
## An entry this reader does not understand is an ERROR, not something to skip.
## Forward-compatible tolerance is the wrong default for a pin: an unknown
## entry dropped in silence is a constraint that was supposed to hold and
## didn't, with nothing in the output to say so. That is the precise failure
## mode §1.2 exists to record, and it would be re-introduced one layer down.
##
## LIMIT, stated rather than discovered: a variant value containing a comma is
## not representable, and `renderLockPins` refuses one instead of emitting a
## string that would parse back as two pins. `REPRO_VARIANTS` has the same
## limit and does not say so.

import std/[algorithm, os, strutils, tables]

const LockPinsEnvVar* = "REPRO_LOCK_PINS"
  ## Names the pin set forwarded from the governing committed lock. Written by
  ## the CLI's lock-consumption block; read by
  ## ``repro_dsl_stdlib/configurables/variants.nim`` when it builds the solver
  ## inputs.

const LockPathEnvVar* = "REPRO_LOCK_PATH"
  ## Names the committed lock the pins were read from — diagnostics only. The
  ## pins themselves are authoritative; this is what makes a conflict message
  ## actionable.

type
  ELockPinsMalformed* = object of CatchableError
    ## The pin string could not be understood. Raised rather than skipped —
    ## see the module doc.

  ELockConflict* = object of CatchableError
    ## A committed lock's pin cannot hold together with a constraint the recipe
    ## declares. Raised INSTEAD of re-solving to something the lock does not
    ## say, and names both sides plus the lock file.

  LockPins* = object
    ## The pinned answer a committed lock supplies to a solve.
    ## ``packages`` maps package name -> pinned version; ``variants`` maps
    ## variant name -> pinned value; ``lockPath`` is where they came from.
    packages*: Table[string, string]
    variants*: Table[string, string]
    lockPath*: string

proc initLockPins*(): LockPins =
  LockPins(packages: initTable[string, string](),
           variants: initTable[string, string](),
           lockPath: "")

proc isEmpty*(pins: LockPins): bool =
  ## True when no lock governs this solve. The ordinary no-lock build.
  pins.packages.len == 0 and pins.variants.len == 0

proc checkValue(kind, name, value: string) =
  if ',' in value:
    raise newException(ELockPinsMalformed,
      "locked " & kind & " '" & name & "' has value '" & value &
      "' containing a comma, which the " & LockPinsEnvVar &
      " grammar cannot represent")

proc renderLockPins*(packages, variants: Table[string, string]): string =
  ## Render a solved graph's package versions and variant assignments to the
  ## canonical pin string. Both runs are sorted by name so two renderings of
  ## the same solved graph are byte-identical regardless of ``Table``
  ## iteration order — the same rule ``repro_lock.solutionToLock`` applies to
  ## the serialized lock, one hop later.
  var parts: seq[string] = @[]
  var pkgNames: seq[string] = @[]
  for name in packages.keys: pkgNames.add(name)
  pkgNames.sort()
  for name in pkgNames:
    checkValue("package", name, packages[name])
    parts.add("pkg:" & name & "=" & packages[name])
  var varNames: seq[string] = @[]
  for name in variants.keys: varNames.add(name)
  varNames.sort()
  for name in varNames:
    checkValue("variant", name, variants[name])
    parts.add("var:" & name & "=" & variants[name])
  parts.join(",")

proc parseLockPins*(raw: string; lockPath = ""): LockPins =
  ## Parse a pin string. Empty input yields empty pins (the no-lock case).
  ## Anything present but unparseable raises.
  result = initLockPins()
  result.lockPath = lockPath
  for entry in raw.split(','):
    let stripped = entry.strip()
    if stripped.len == 0: continue
    let colon = stripped.find(':')
    let eq = stripped.find('=')
    if colon <= 0 or eq <= colon + 1:
      raise newException(ELockPinsMalformed,
        "malformed " & LockPinsEnvVar & " entry '" & stripped &
        "' (expected pkg:<name>=<version> or var:<name>=<value>)")
    let kind = stripped[0 ..< colon]
    let name = stripped[colon + 1 ..< eq].strip()
    let value = stripped[eq + 1 .. ^1]
    if name.len == 0:
      raise newException(ELockPinsMalformed,
        "malformed " & LockPinsEnvVar & " entry '" & stripped &
        "' (empty name)")
    case kind
    of "pkg": result.packages[name] = value
    of "var": result.variants[name] = value
    else:
      raise newException(ELockPinsMalformed,
        "unknown " & LockPinsEnvVar & " entry kind '" & kind & "' in '" &
        stripped & "'. A pin this reader cannot apply is refused rather " &
        "than skipped: skipping it would drop a constraint that was " &
        "supposed to hold, with nothing in the output to say so")

proc lockPinsFromEnv*(): LockPins =
  ## The pins governing THIS process, read from the environment the CLI's
  ## lock-consumption block wrote. Empty when no committed lock governs the
  ## build.
  parseLockPins(getEnv(LockPinsEnvVar), getEnv(LockPathEnvVar))

proc lockSourceDescription*(pins: LockPins): string =
  ## How a diagnostic should refer to the governing lock.
  if pins.lockPath.len > 0: "committed lock '" & pins.lockPath & "'"
  else: "the committed lock"

proc lockRecordsPackage*(pins: LockPins; packageName: string): bool =
  ## Whether the lock's solved graph carries ``packageName`` itself — under
  ## either identifier spelling, since a recipe's package reaches a lock as
  ## ``isonim_gpui`` from one path and ``isonim-gpui`` from another (reprobuild-pm
  ## issue 2026-10-12 lists both side by side). A solve that SAW a recipe
  ## records that recipe's package (every parent package gets a synthetic
  ## ``0.1.0`` candidate, and the solved graph carries it), so absence is
  ## evidence the writing solve never had the recipe at all.
  ##
  ## Lives here, beside the pin grammar, because both conflict checkers ask
  ## it: the provider's (``repro_dsl_stdlib/configurables/variants``) and the
  ## targeted re-pin's (``repro lock refresh --repin``, in the CLI). Two copies
  ## of the spelling rule would be two answers to "did the writer see it".
  if packageName in pins.packages: return true
  let hyphen = packageName.replace('_', '-')
  let underscore = packageName.replace('-', '_')
  hyphen in pins.packages or underscore in pins.packages

proc repinCommandFor*(depPackage: string): string =
  ## The targeted re-pin that clears a conflict on ``depPackage``
  ## (`Locking-And-Solver.md` §"Targeted re-pin"), as the reader would type it.
  "repro lock refresh --repin=" & depPackage

const LockProducerCheckoutsEnvVar* = "REPRO_LOCK_PRODUCER_CHECKOUTS"
  ## Names, for the governing committed lock, every lock-pinned cross-repo
  ## producer whose recipe this build reads from a checkout on disk: the
  ## producer's name, that checkout's directory and the revision the lock pins
  ## for it. Written by the CLI's lock-consumption block beside
  ## ``REPRO_LOCK_PINS``; read by the provider ONLY while it renders an
  ## ``ELockConflict`` (``lockProducerCheckoutsFromEnv``).
  ##
  ## WHY. A cross-repo producer's ``uses:`` ranges reach the consumer's solve
  ## from whichever checkout of that producer the recipe import found, and that
  ## checkout need not be at the revision the consumer's lock pins. When it is
  ## behind (or ahead), the range that contradicts the lock is the CHECKOUT's,
  ## not the pinned revision's, and the right remedy is to bring the checkout
  ## to the pin, not to re-pin a correct lock to fit it. The provider cannot
  ## work that out alone: it sees the recipe it imported, not the lock's
  ## revision pins, which ``REPRO_LOCK_PINS`` does not carry.
  ##
  ## WHY ONLY ON THE FAILURE PATH. Environment reads are evidence for the
  ## monitored action that makes them, and the value names absolute paths of
  ## this machine. Read during an ordinary solve it would key every interface
  ## extraction on the checkout layout; read only while raising, it keys
  ## nothing, because a failed action is never cached.
  ##
  ## Grammar: one entry per line, ``<name>\t<checkout dir>\t<revision>``.
  ## Tabs and newlines are the separators because a path may contain commas;
  ## an entry whose fields contain either is not rendered (the diagnostic then
  ## falls back to the text it had before, which claims nothing false).

type
  LockProducerCheckout* = object
    ## One entry of ``LockProducerCheckoutsEnvVar``.
    name*: string            ## the producer's lock entry name (its repo).
    checkoutDir*: string     ## absolute directory of the checkout read.
    pinnedRevision*: string  ## the revision the consumer's lock pins.

  StaleProducerCheckout* = object
    ## A cross-repo producer whose recipe was read from a checkout that is not
    ## at the revision the consumer's lock pins. ``checkoutDir`` empty means
    ## "none known", the ordinary case.
    name*: string
    checkoutDir*: string
    head*: string
    pinnedRevision*: string

proc isKnown*(stale: StaleProducerCheckout): bool =
  stale.checkoutDir.len > 0

proc renderLockProducerCheckouts*(
    entries: openArray[LockProducerCheckout]): string =
  ## The canonical ``LockProducerCheckoutsEnvVar`` value: sorted by name, so
  ## one lock and one checkout layout always render the same string.
  var kept: seq[LockProducerCheckout] = @[]
  for e in entries:
    var clean = e.name.len > 0 and e.checkoutDir.len > 0 and
      e.pinnedRevision.len > 0
    for field in [e.name, e.checkoutDir, e.pinnedRevision]:
      if '\t' in field or '\n' in field or '\r' in field: clean = false
    if clean: kept.add(e)
  kept.sort(proc (a, b: LockProducerCheckout): int = cmp(a.name, b.name))
  var lines: seq[string] = @[]
  for e in kept:
    lines.add(e.name & "\t" & e.checkoutDir & "\t" & e.pinnedRevision)
  lines.join("\n")

proc parseLockProducerCheckouts*(raw: string): seq[LockProducerCheckout] =
  ## Parse a ``LockProducerCheckoutsEnvVar`` value. A line that is not three
  ## non-empty fields is skipped rather than raised on: the value only refines
  ## a diagnostic that is already being raised, and failing that diagnostic
  ## over its own annotation would hide the conflict it reports.
  for line in raw.split('\n'):
    let fields = line.strip(chars = {'\r'}).split('\t')
    if fields.len != 3: continue
    if fields[0].len == 0 or fields[1].len == 0 or fields[2].len == 0:
      continue
    result.add(LockProducerCheckout(name: fields[0], checkoutDir: fields[1],
      pinnedRevision: fields[2]))

proc lockProducerCheckoutsFromEnv*(): seq[LockProducerCheckout] =
  ## This process's entries. Call it only while rendering a conflict (see
  ## ``LockProducerCheckoutsEnvVar`` for why).
  parseLockProducerCheckouts(getEnv(LockProducerCheckoutsEnvVar))

proc samePackageName(a, b: string): bool =
  ## A producer's lock entry is its REPO's name (``codetracer-ruby-recorder``)
  ## while the registry holds its PACKAGE's (``codetracer_ruby_recorder``);
  ## the two spellings name one producer (see ``lockRecordsPackage``).
  a.replace('_', '-').toLowerAscii == b.replace('_', '-').toLowerAscii

proc checkoutGitDir(checkoutDir: string): string =
  ## The git directory of ``checkoutDir``: ``.git`` itself, or the directory a
  ## ``.git`` FILE names (``gitdir: <path>``, a linked worktree or a submodule).
  let dotGit = checkoutDir / ".git"
  if dirExists(dotGit): return dotGit
  if not fileExists(dotGit): return ""
  var text = ""
  try: text = readFile(dotGit)
  except CatchableError: return ""
  for line in text.splitLines():
    if line.startsWith("gitdir:"):
      let target = line["gitdir:".len .. ^1].strip()
      if target.len == 0: return ""
      return if target.isAbsolute: target else: checkoutDir / target
  ""

proc lookUpRef(gitDir, commonDir, refName: string): string =
  ## The object id ``refName`` names: its loose file (per-worktree first, then
  ## shared), else its ``packed-refs`` line. Empty when it cannot be read.
  for dir in [gitDir, commonDir]:
    let loose = dir / refName
    if fileExists(loose):
      try:
        let value = readFile(loose).strip()
        if value.startsWith("ref:"):
          return ""  # a ref to a ref: not followed, nothing claimed
        return value
      except CatchableError:
        return ""
  let packed = commonDir / "packed-refs"
  if fileExists(packed):
    try:
      for line in readFile(packed).splitLines():
        if line.len == 0 or line[0] in {'#', '^'}: continue
        let space = line.find(' ')
        if space > 0 and line[space + 1 .. ^1].strip() == refName:
          return line[0 ..< space]
    except CatchableError:
      discard
  ""

proc checkoutHeadRevision*(checkoutDir: string): string =
  ## The commit ``checkoutDir``'s HEAD names, read from the repository files
  ## (`gitrepository-layout(5)`,
  ## https://git-scm.com/docs/gitrepository-layout): ``HEAD`` is either an
  ## object id (detached) or ``ref: <name>``, resolved through the loose ref
  ## file or ``packed-refs``; a linked worktree's shared refs live under the
  ## directory its ``commondir`` file names. Empty when any step cannot be
  ## read, so a caller never claims a revision it did not observe.
  ##
  ## Read from files rather than by running ``git`` because the caller is the
  ## provider, raising inside a monitored action whose ``PATH`` need not
  ## carry ``git``, and this answers the one question asked without a process.
  let gitDir = checkoutGitDir(checkoutDir)
  if gitDir.len == 0: return ""
  var commonDir = gitDir
  let commonFile = gitDir / "commondir"
  if fileExists(commonFile):
    try:
      let target = readFile(commonFile).strip()
      if target.len > 0:
        commonDir = if target.isAbsolute: target else: gitDir / target
    except CatchableError:
      return ""
  var head = ""
  try: head = readFile(gitDir / "HEAD").strip()
  except CatchableError: return ""
  if head.startsWith("ref:"):
    head = lookUpRef(gitDir, commonDir, head["ref:".len .. ^1].strip())
  if head.len < 7: return ""
  for ch in head:
    if ch notin HexDigits: return ""
  head.toLowerAscii

proc canonicalPath(path: string): string =
  ## ``path`` with symlinks resolved when it exists (macOS spells a temporary
  ## directory both ``/var/…`` and ``/private/var/…``), normalized either way.
  result = path
  try:
    if fileExists(path) or dirExists(path): result = expandFilename(path)
  except CatchableError:
    discard
  result = normalizedPath(result).replace('\\', '/')

proc isUnder(file, dir: string): bool =
  let f = canonicalPath(file)
  let d = canonicalPath(dir).strip(leading = false, chars = {'/'})
  d.len > 0 and f.startsWith(d & "/")

proc staleProducerCheckoutFor*(entries: openArray[LockProducerCheckout];
                               parentPackage: string;
                               declarationFile = ""): StaleProducerCheckout =
  ## The entry for the producer that declared a range, when its checkout's
  ## HEAD is NOT the revision the lock pins; otherwise an unknown value.
  ##
  ## The entry is the one whose checkout holds ``declarationFile`` (the
  ## declaring recipe, when the caller knows it), else, only when no file is
  ## known, the one named like ``parentPackage`` under either spelling. The file comes first because a
  ## producer's package name need not be its repository's. A checkout whose
  ## HEAD cannot be read is not called stale: the diagnostic then says what it
  ## said before rather than something it did not observe.
  ##
  ## A KNOWN recipe file that lies under none of the checkouts was read from
  ## somewhere else (a develop override's tree, a nested sibling, the store),
  ## so the name is not consulted then: a checkout of the same name is not the
  ## tree the range came from, and its HEAD says nothing about it. Likewise a
  ## pinned revision that is not an object id (at least seven hex digits) is
  ## not compared, since a HEAD can never equal a ref name.
  var found = -1
  if declarationFile.len > 0 and declarationFile.isAbsolute:
    for i, e in entries:
      if declarationFile.isUnder(e.checkoutDir):
        found = i
        break
    if found < 0: return
  else:
    for i, e in entries:
      if samePackageName(e.name, parentPackage):
        found = i
        break
  if found < 0: return
  let e = entries[found]
  let head = checkoutHeadRevision(e.checkoutDir)
  if head.len == 0: return
  let pinned = e.pinnedRevision.toLowerAscii
  if pinned.len < 7: return
  for ch in pinned:
    if ch notin HexDigits: return
  if head == pinned or (pinned.len >= 7 and head.startsWith(pinned)):
    return
  StaleProducerCheckout(name: e.name, checkoutDir: e.checkoutDir,
    head: head, pinnedRevision: e.pinnedRevision)

proc lockConflictDiagnostic*(lockDescription, depPackage, locked,
                             parentPackage, rangePart: string;
                             declarerRecorded, crossRepoProducer: bool;
                             staleCheckout = StaleProducerCheckout()):
                             string =
  ## The text of an ``ELockConflict``: a committed lock pins ``depPackage`` to
  ## ``locked`` and ``parentPackage`` declares ``uses: <depPackage>
  ## <rangePart>``, which ``locked`` does not satisfy.
  ##
  ## ONE renderer for both places the conflict is detected — the build's
  ## provider and ``repro lock refresh --repin`` — so the two cannot drift into
  ## naming different remedies for the same contradiction. The spec fixes three
  ## things about it (`Locking-And-Solver.md` §"Targeted re-pin"; settled by
  ## reprobuild-pm issue 2026-10-14 "declaring a sibling producer imports its
  ## toolchain floor into the consumer's committed-lock solve"):
  ##
  ##   * the FIRST remedy is the targeted re-pin with the package filled in. A
  ##     whole-lock ``repro lock refresh`` re-solves every version pin and
  ##     every sibling revision pin to admit one new floor, and "relax the
  ##     declared constraint" means editing a recipe — often another repo's —
  ##     that states its floor correctly. Both remain named, after it;
  ##   * when ``crossRepoProducer``, it says the declaring package is a
  ##     cross-repo producer, because the reader otherwise searches their own
  ##     recipe for a constraint it does not contain;
  ##   * when the lock does not record the declaring package
  ##     (``declarerRecorded`` false) the writing solve never saw that recipe,
  ##     and there are two ways that happens — the recipe (or the ``uses:``
  ##     reaching it) was declared AFTER the lock was written, or the lock was
  ##     regenerated where the recipe was unreachable. The message used to
  ##     claim only the second, which is the wrong story for the ordinary case
  ##     of adding a dependency;
  ##   * when ``staleCheckout`` is known, the declaring producer's recipe was
  ##     read from a checkout whose HEAD is not the revision the lock pins for
  ##     it. The constraint is then the checkout's, the lock is not shown to be
  ##     wrong, and the text says so: it names the checkout and both
  ##     revisions, and its FIRST remedy is to bring the checkout to the pin.
  ##     The re-pin is named after it, for the case where the pinned revision
  ##     declares the range too. Re-pinning first would change a correct lock
  ##     to fit a stale checkout.
  result = "the " & lockDescription & " pins '" & depPackage & "' to " &
    locked & ", but package '" & parentPackage & "' declares `uses: " &
    depPackage & " " & rangePart & "`, which " & locked &
    " does not satisfy. "
  if staleCheckout.isKnown:
    result.add("'" & parentPackage & "' is a cross-repo producer, and its " &
      "recipe was read from the checkout at " & staleCheckout.checkoutDir &
      ", whose HEAD is " & staleCheckout.head & ", while the lock pins '" &
      staleCheckout.name & "' at " & staleCheckout.pinnedRevision &
      ". The constraint is that checkout's, and the pinned revision need " &
      "not declare it, so this does not show the lock is wrong. First bring " &
      "the checkout to the pin with `git -C " &
      quoteShell(staleCheckout.checkoutDir) & " checkout --detach " &
      quoteShell(staleCheckout.pinnedRevision) & "` (or place a checkout " &
      "of '" & staleCheckout.name & "' at that revision beside the " &
      "consumer) and build again. Re-pin '" & depPackage & "' with `" &
      repinCommandFor(depPackage) & "` only if the conflict remains with " &
      "the checkout at the pin: re-pinning now would change a correct lock " &
      "to fit a checkout the lock does not name.")
    return
  if crossRepoProducer:
    result.add("'" & parentPackage & "' is a cross-repo producer this " &
      "project consumes through `uses:`, not one of its own packages, so " &
      "the constraint is stated in that producer's recipe rather than in " &
      "this project's. Its ranges still bind this lock, as the ranges of " &
      "every package this project consumes do. ")
  result.add("Re-pin only '" & depPackage & "' with `" &
    repinCommandFor(depPackage) & "`, which re-solves that entry and holds " &
    "every other pin the lock records. ")
  if not declarerRecorded:
    result.add("The lock records no pin for '" & parentPackage &
      "' itself, so the solve that wrote it never saw the recipe that " &
      "declares this constraint: either that recipe (or the `uses:` that " &
      "reaches it) was declared after the lock was written, or the lock " &
      "was regenerated where the recipe was not reachable (typically a " &
      "develop-set sibling that was not checked out), so its pins are the " &
      "floors of fewer recipes than this build sees. In the second case run " &
      "the re-pin, or a full `repro lock refresh`, from a workspace where " &
      "the sibling declaring '" & parentPackage & "' is checked out; a " &
      "refresh that cannot reach such a sibling refuses rather than " &
      "dropping its constraints.")
  else:
    result.add("A committed lock is a pin, not a preference: the build " &
      "refuses to re-solve '" & depPackage & "' to a version the lock " &
      "does not name. Regenerate the lock with `repro lock refresh` or " &
      "relax the declared constraint only when a whole-lock re-solve or a " &
      "recipe change is what is wanted.")
