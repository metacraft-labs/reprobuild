## The fact schema — Platform-And-Filesystem-Facts **F1**.
##
## Spec: ``reprobuild-specs/Platform-And-Filesystem-Facts.milestones.org``
##       §F1 "The fact tables".
##
## A declared fact is not a magic number. It is a triple, and the second
## and third members are what separate this library from a header of
## constants:
##
## 1. a **value**, in a type that can say ``varies`` or ``unknown``
##    rather than forcing a confident guess;
## 2. a **citation** — the vendor document or standard that states it, so
##    a reader can check the claim without a machine;
## 3. an **observability marker** — how a test falsifies it, or an
##    explicit statement that it cannot be observed from user space.
##
## The third is the one that makes the initiative different from what it
## replaces. `Platform-And-Filesystem-Facts.milestones.org` states the
## rule this schema exists to enforce: *a constant that no test can
## falsify is worse than no constant, because policy will rely on it.*
## So every ``Fact`` carries ``falsifiedBy``, and F2's conformance suite
## refuses a table entry whose marker is empty.
##
## **This library declares; it does not probe.** The question "what can
## this filesystem do?" is answered here. The different question "does
## this operation work between THESE two paths?" is answered by
## ``repro_local_store/link_capability``, which attempts the operation —
## constants cannot answer it (Btrfs refuses ``link()`` across subvolumes
## on one device) and the probe cannot answer this one (it knows nothing
## about a filesystem the host does not have). Neither replaces the
## other; see the milestone's §"The distinction that must not be lost".

type
  Ternary* = enum
    ## A boolean fact that is allowed to admit it is not a boolean.
    ##
    ## ``tnVaries`` and ``tnUnknown`` are values, not evasions: an
    ## honest "this depends on the mount options" is a fact a policy can
    ## act on (degrade to probing), while a confident wrong ``tnYes`` is
    ## a defect that policy will act on incorrectly.
    tnNo
    tnYes
    tnVaries         ## genuinely depends on version, mount option or
                     ## backing store; no single value is correct.
    tnUnknown        ## nobody has established it. Distinct from
                     ## ``tnVaries``: unknown is a gap in the table,
                     ## varies is a property of the filesystem.
    tnNotApplicable  ## the question does not arise here (e.g. "are mode
                     ## bits per-inode?" on a filesystem that stores no
                     ## mode bits).

  QuantityKind* = enum
    ## How to read a ``Quantity``'s ``value`` field.
    qkExact    ## exactly ``value``.
    qkAtLeast  ## at least ``value``; no upper bound has been
               ## established. Falsifiable downward (a host that
               ## refuses at ``value`` contradicts it) and deliberately
               ## not falsifiable upward.
    qkVaries   ## version- / configuration-dependent. ``value`` carries
               ## no meaning and MUST NOT be read.
    qkUnknown  ## not established. ``value`` carries no meaning.

  Quantity* = object
    ## A numeric fact that can decline to be a number.
    kind*: QuantityKind
    value*: int64

  Provenance* = enum
    ## Where the value came from. Orthogonal to observability: a fact can
    ## be documented and unobservable, or measured and undocumented.
    pvStandard      ## a standard (POSIX, the filesystem's on-disk spec).
    pvVendorDoc     ## the vendor's own documentation.
    pvMeasured      ## measured on a host by this repository; the
                    ## citation names the run that measured it.
    pvUnestablished ## no source; the value is ``unknown`` or ``varies``
                    ## and says so.

  Observability* = enum
    ## How a test could falsify the fact. F2's suite reads this to decide
    ## what it is allowed to report as verified.
    obOperation   ## a test performs the operation and reads the result.
                  ## The strongest marker: the fact is falsifiable by
                  ## doing the thing.
    obQuery       ## a test reads it from an OS query
                  ## (``GetVolumeInformationW`` flags, ``pathconf``,
                  ## ``statfs``) rather than by doing the operation.
    obConsequence ## observable only through a downstream consequence,
                  ## never directly. Atomicity is the type case: a test
                  ## can see that the destination was replaced, but
                  ## cannot crash the machine mid-rename to prove the
                  ## window does not exist.
    obNone        ## not observable from user space at all.
                  ## ``falsifiedBy`` MUST then say WHY, not what.

  Fact*[T] = object
    ## One declared property. See the module doc for why all four
    ## non-value fields exist.
    value*: T
    citation*: string
      ## The document that states it. Prose, meant to be read by a
      ## human and checked without a machine. Never parsed.
    provenance*: Provenance
    observability*: Observability
    falsifiedBy*: string
      ## The observation that would contradict the value — phrased as
      ## the operation a test performs. When ``observability == obNone``
      ## this states why no such observation exists.

func fact*[T](value: T; citation: string; provenance: Provenance;
              observability: Observability; falsifiedBy: string): Fact[T] =
  ## Construct a fact. Every field is required; there is deliberately no
  ## overload that lets a citation or a falsification recipe be omitted.
  Fact[T](value: value, citation: citation, provenance: provenance,
          observability: observability, falsifiedBy: falsifiedBy)

# ---------------------------------------------------------------------------
# Quantity constructors and predicates
# ---------------------------------------------------------------------------

func exactly*(n: int64): Quantity =
  Quantity(kind: qkExact, value: n)

func atLeast*(n: int64): Quantity =
  Quantity(kind: qkAtLeast, value: n)

func varyingQuantity*(): Quantity =
  Quantity(kind: qkVaries, value: 0)

func unknownQuantity*(): Quantity =
  Quantity(kind: qkUnknown, value: 0)

func isDefinite*(q: Quantity): bool =
  ## ``true`` when the value carries a number a test can drive to a
  ## boundary. ``qkVaries`` / ``qkUnknown`` do not, and a suite that
  ## treated them as checkable would be asserting against a zero.
  q.kind in {qkExact, qkAtLeast}

func isDefinite*(t: Ternary): bool =
  ## ``true`` when the value is a claim a host can contradict.
  ## ``tnVaries`` / ``tnUnknown`` / ``tnNotApplicable`` are not: a host
  ## that answers either way is consistent with all three.
  t in {tnNo, tnYes}

func `$`*(q: Quantity): string =
  case q.kind
  of qkExact: $q.value
  of qkAtLeast: ">= " & $q.value
  of qkVaries: "varies"
  of qkUnknown: "unknown"

func `$`*(t: Ternary): string =
  case t
  of tnNo: "no"
  of tnYes: "yes"
  of tnVaries: "varies"
  of tnUnknown: "unknown"
  of tnNotApplicable: "n/a"

func describe*[T](f: Fact[T]): string =
  ## One-line diagnostic. Safe to log; never parsed.
  $f.value & " [" & $f.provenance & "/" & $f.observability & "] " &
    f.citation

func isWellFormed*[T](f: Fact[T]): bool =
  ## A fact is well formed when it carries both of the things that make
  ## it more than a number. F2 asserts this over the whole table, which
  ## is what stops an entry being added with an empty citation.
  f.citation.len > 0 and f.falsifiedBy.len > 0
