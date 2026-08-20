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
