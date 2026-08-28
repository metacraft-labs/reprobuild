## ``ext_repro_action`` — the build-side facts RunQuota cannot see.
##
## Normative specification:
##
## * ``reprobuild-specs/Build-Analytics-And-Optimization.md`` §"Two Stores"
##   → "Raw per-execution rows — RunQuota" and §"Observation Model";
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Domain
##   Extensions" → "Reprobuild action extension", and OS-5.
##
## Raw per-execution rows are RunQuota's. Reprobuild contributes ONE
## extension row per execution carrying what RunQuota has no way to
## observe: the cache decision and why it missed, the stable action id,
## the action COMPATIBILITY KEY, tool identity, and the dependency
## evidence counts. Reprobuild does not define a database for these rows,
## does not choose their location, and does not manage their retention.
##
## **THE REGISTERED ID IS DECOMPOSED, NOT SPELLED.** The specification
## names the registered extension as ``reprobuild.action.v1``, and
## RunQuota's registry cannot store that string as an ``extension_id``:
## the id becomes a table name by concatenation, so ``isStorableIdentifier``
## admits only a bare lowercase identifier and a dotted name is refused.
## The three parts are exactly the three columns the registry already has
## — owner ``reprobuild``, extension_id ``repro_action``, schema_version
## ``1`` — which is also the only spelling that yields the table name
## ``ext_repro_action`` that the milestone gate and the specification's own
## §"Domain Extensions" example both name. Nothing about RunQuota's
## mechanism was changed to fit this; the dotted form is a rendering of the
## triple, and ``registeredExtensionName`` below renders it.

import std/[algorithm, os, strutils]

import repro_hash
import repro_hash/blake3_policy

const
  ReproActionExtensionId* = "repro_action"
    ## The registry ``extension_id``. RunQuota composes the table name
    ## ``ext_repro_action`` from it; this constant is the only place
    ## reprobuild spells it.
  ReproActionExtensionOwner* = "reprobuild"
  ReproActionSchemaVersion* = 1'i64

  CompatibilityKeyDomainTag = "reprobuild.action-compatibility.v1\0"
    ## Domain separation for the compatibility key, carried INSIDE the
    ## hashed payload rather than as a new ``HashDomain`` member: the
    ## enum's ordinal is a wire value that three separate decoders
    ## bounds-check, so extending it would change wire validation for a
    ## quantity that never goes on a wire.

type
  ReproActionCacheOutcome* = enum
    ## The cache decision that produced this execution, in the vocabulary
    ## §"Reprobuild action extension" names (``hit``, ``miss``,
    ## ``refused``) plus the two decisions the engine can actually reach
    ## that are neither: an action declared uncacheable, and a hybrid
    ## policy cutoff.
    racNotCacheable = "not-cacheable"
    racMiss = "miss"
    racHit = "hit"
    racHybridCutoff = "hybrid-cutoff"
    racRefused = "refused"

  ReproActionFacts* = object
    ## Everything one ``ext_repro_action`` row carries, as a plain value.
    ##
    ## A VALUE and not a reference to engine state: this module is
    ## imported by the engine, so a type reaching back into the engine
    ## would close a cycle, and the row must be constructible in a test
    ## without a build.
    actionId*: string
    actionKind*: string
    compatibilityKey*: string
    cacheOutcome*: ReproActionCacheOutcome
    cacheMissReason*: string
      ## Empty when there is nothing to say. Written as SQL NULL, so
      ## "missed for no recorded reason" stays distinguishable from
      ## "missed because the reason was the empty string".
    weakFingerprintHex*: string
    strongFingerprintHex*: string
      ## Empty when the lookup found no record at all, in which case
      ## there is no strong fingerprint to report. NULL, again.
    pool*: string
    poolUnits*: int64
    outputBytes*: int64
    substituted*: bool
      ## Whether the result was materialised from a binary cache rather
      ## than produced by this execution.
    toolKind*: string
    toolIdentity*: string
    declaredInputs*: int64
    declaredOutputs*: int64
    depfileInputs*: int64
    monitorReads*: int64
    monitorWrites*: int64
    monitorProbes*: int64

proc registeredExtensionName*(): string =
  ## The dotted name the specification uses in prose, rendered from the
  ## three registry columns that actually store it.
  ReproActionExtensionOwner & "." & ReproActionExtensionId.replace("repro_", "") &
    ".v" & $ReproActionSchemaVersion

const reproActionCreateTable* = """
create table ext_repro_action (
  host_id text not null,
  execution_id text not null,
  action_id text not null,
  action_kind text not null,
  compatibility_key text not null,
  cache_outcome text not null,
  cache_miss_reason text,
  weak_fingerprint text not null,
  strong_fingerprint text,
  pool text,
  pool_units integer not null,
  output_bytes integer not null,
  substituted integer not null,
  tool_kind text,
  tool_identity text,
  declared_inputs integer not null,
  declared_outputs integer not null,
  depfile_inputs integer not null,
  monitor_reads integer not null,
  monitor_writes integer not null,
  monitor_probes integer not null,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions (host_id, execution_id)
);
"""
  ## Step 1 of the forward-only ladder: version 0 → version 1.
  ##
  ## Keyed on the two spine columns and carrying the foreign key to
  ## ``executions``, which is the shape RunQuota's own gate checks inside
  ## the same transaction as this statement.

proc reproActionMigrations*(): seq[string] =
  ## The ladder. ``[i]`` takes the table from version ``i`` to ``i + 1``,
  ## so the sequence length IS the highest version this client can ask
  ## for; a declaration naming a version with no step for it is refused
  ## by RunQuota rather than approximated.
  @[reproActionCreateTable]

proc reproActionColumns*(): seq[string] =
  @["action_id", "action_kind", "compatibility_key", "cache_outcome",
    "cache_miss_reason", "weak_fingerprint", "strong_fingerprint", "pool",
    "pool_units", "output_bytes", "substituted", "tool_kind", "tool_identity",
    "declared_inputs", "declared_outputs", "depfile_inputs", "monitor_reads",
    "monitor_writes", "monitor_probes"]

# ---------------------------------------------------------------------------
# The compatibility key
# ---------------------------------------------------------------------------
#
# §"Observation Model" is explicit that this key is DELIBERATELY COARSER
# THAN THE ACTION-CACHE KEY:
#
#   "The exact weak fingerprint used for cache identity is too specific
#    for long-term performance history: a source edit should not make all
#    duration history useless. The compatibility key must therefore be
#    coarser than the action-cache key while still separating measurements
#    that are not comparable."
#
# Cache identity answers "have I built exactly this?"; the compatibility
# key answers "what KIND of work is this?". The two diverge on precisely
# the case that matters and on no other: editing a source file changes the
# strong fingerprint (the action-cache key) and MUST NOT change the
# compatibility key, or the cost history for that action is discarded
# every time somebody types.
#
# That divergence is invisible in any test that builds the same inputs
# twice, which is why it is asserted directly by editing an input and
# rebuilding.

proc outputRole*(outputs: openArray[string]): string =
  ## The §"Observation Model" output-role dimension: object, archive,
  ## shared library, executable, bundle. Classified from the output
  ## extension because that is the only thing available to every action
  ## kind; an unrecognised extension gets its own role rather than being
  ## pooled with executables, so two roles are never silently compared.
  if outputs.len == 0:
    return "none"
  var roles: seq[string] = @[]
  for output in outputs:
    let ext = output.splitFile.ext.toLowerAscii()
    let role =
      case ext
      of ".o", ".obj": "object"
      of ".a", ".lib": "archive"
      of ".so", ".dylib", ".dll": "shared-library"
      of ".exe", "": "executable"
      of ".app", ".bundle", ".framework": "bundle"
      else: "file" & ext
    if role notin roles:
      roles.add(role)
  roles.sort()
  roles.join("+")

proc normalizedArgvShape*(argv: openArray[string]): string =
  ## §"Observation Model"'s "normalized argv shape".
  ##
  ## Flags are kept VERBATIM, because compile mode, optimisation and
  ## debug settings, target triple and feature flags are all spelled as
  ## flags and are exactly the dimensions that make two measurements
  ## incomparable. Path-shaped operands are replaced by their EXTENSION
  ## class, because the identity of the file being compiled is what a
  ## source edit or a rename changes, and neither of those makes the cost
  ## of the work incomparable.
  ##
  ## The tool itself (argv[0]) is dropped here: it is carried separately
  ## as tool identity, and its absolute path moves with the toolchain
  ## store path without the work changing.
  var parts: seq[string] = @[]
  for i, arg in argv:
    if i == 0:
      parts.add("<tool>")
      continue
    if arg.len > 0 and arg[0] == '-':
      # A flag with an attached path operand (``-I/nix/store/...``,
      # ``--out:build/x.o``) is split at the separator so the flag stays
      # verbatim and only the operand is abstracted.
      var cut = -1
      for sep in ['=', ':']:
        let idx = arg.find(sep)
        if idx >= 0 and (cut < 0 or idx < cut):
          cut = idx
      if cut > 0 and arg.len > cut + 1 and
          (arg.contains('/') or arg.contains('\\')):
        parts.add(arg[0 .. cut] & "<path" & arg.splitFile.ext.toLowerAscii() & ">")
      else:
        parts.add(arg)
      continue
    if arg.contains('/') or arg.contains('\\') or arg.splitFile.ext.len > 0:
      parts.add("<path" & arg.splitFile.ext.toLowerAscii() & ">")
    else:
      parts.add(arg)
  parts.join("\x1f")

proc compatibilityKey*(actionKind, commandStatsId, toolKind, toolIdentity: string;
                       argv, outputs: openArray[string]): string =
  ## The key, hex-encoded.
  ##
  ## Its inputs are §"Observation Model"'s list and nothing else. In
  ## particular NEITHER FINGERPRINT is an input: the weak fingerprint is
  ## computed over the action's canonical text and the strong one folds in
  ## the input CONTENT digests, so either would reintroduce the cache
  ## identity this key exists to be coarser than.
  var payload = CompatibilityKeyDomainTag
  payload.add(actionKind)
  payload.add('\x1e')
  payload.add(commandStatsId)
  payload.add('\x1e')
  payload.add(toolKind)
  payload.add('\x1e')
  payload.add(toolIdentity)
  payload.add('\x1e')
  payload.add(normalizedArgvShape(argv))
  payload.add('\x1e')
  payload.add(outputRole(outputs))
  var bytes = newSeq[byte](payload.len)
  for i, ch in payload:
    bytes[i] = byte(ord(ch))
  toHex(blake3DomainDigest(bytes, hdMetadataEnvelope).bytes)
