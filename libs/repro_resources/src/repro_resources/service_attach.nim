## Shared-Development-Services L6 (spec §4.3) — THE ATTACH DECISION: what
## happens when a consumer resolves a shared service and an instance is
## already running under that instance key.
##
## § THE DECISION HAS THREE OUTCOMES, NOT TWO
##
## §4.3's table, verbatim:
##
##   | interface fingerprint equal | **Attach silently.** |
##   | interface fingerprint differs, major compatibility field equal |
##     **Attach, and warn.** |
##   | major compatibility field differs | **Refuse.** |
##
## And the reason there are three: "The middle row is the behaviour a
## developer wants from a workspace: keep working against the live
## instance, and say that it was built from somebody else's definition.
## The bottom row is why the decision cannot be 'always warn'."
##
## THE CONTROL THAT KEEPS THE WARNING MEANINGFUL is structural here, not
## a convention a reviewer has to trust. The comparand is built ONLY
## from the lifted interface (`ServiceInterfaceSnapshot` below), and the
## lift deliberately carries a service's SIGNATURE and not its
## implementation -- `InterfaceService` has no `executable`, no `args`,
## no `runtimeFile` and no `on <trigger>:`. So a change to the
## implementation alone cannot reach this module's input at all, and
## `attachDecision` has no branch that could warn about one. §4.3's own
## words for why that matters: "comparing whole closures is too coarse:
## it would warn on every change that cannot possibly matter to a
## consumer".
##
## § WHY THE COMPARAND IS A PER-SERVICE PROJECTION, NOT THE PROJECT
##   FINGERPRINT
##
## §4.3 says the comparison is "on the **interface fingerprint** the lift
## already produces". `interfaceFingerprint(ProjectInterface)` is a
## PACKAGE-WIDE digest, and using it directly would re-introduce the
## defect the same sentence rejects one clause earlier: an unrelated
## service, library or executable in the owner's package moving would
## warn every consumer of every OTHER service in it. So the comparand is
## the same projection restricted to ONE service and the activity that
## declares it, computed by `serviceInterfaceFingerprint` below over the
## very member list the warning then names.
##
## That pairing is the point, and the exact strength of it is worth
## stating because L6's review found this header overclaiming it.
## `fingerprint` is a digest OF `members` through a length-prefixed,
## INJECTIVE encoding, so "the fingerprints differ" does imply "the
## member LISTS differ as SEQUENCES". It does NOT by itself imply that
## some member differs under an ORDER-INSENSITIVE key -- and
## `memberDifferences` was keyed that way, so a pure REORDER of two
## `config:` keys warned and named nothing. Measured before the fix, on
## `l6AttOrderA` / `l6AttOrderB`: fingerprints `79ee2201...` vs
## `b3747a45...`, `memberDifferences` count 0. `memberDifferences` is
## now POSITION-AWARE (`smcReordered`), which closes the gap between
## what the digest distinguishes and what the diff can name.
##
## "A warning is never empty of members" is accordingly an ASSERTION
## over a fixture set, not a theorem: the suite "a warning is never
## EMPTY of members" in
## `t_l6_attach_decision_has_three_outcomes.nim` ranges over every
## fixture pair that reaches row 2 -- the five single-name/signature
## variants AND the two reorder pairs -- and the all-ordered-pairs
## suite checks the same thing over the whole fixture set. No proof is
## claimed; what is claimed is that no input in the set falsifies it.
## `projectFingerprint` is carried beside it for diagnostics and is
## deliberately NOT the comparand.
##
## § WHAT IS HERE AND WHAT IS A LATER MILESTONE
##
## Here: the interface projection, the three-outcome decision, the
## `--replace` decision and its lease refusal -- each a PURE FUNCTION of
## a representable record.
##
## NOT here, and NOT faked:
##
##   * the REGISTRY that makes an instance key into a *running instance*
##     is **L7**. This module takes a `RunningServiceInstance` as an
##     argument; it holds no registry, starts nothing, stops nothing and
##     talks to no daemon. Every clause below is therefore demonstrated
##     against a record a caller constructs -- in this milestone's tests,
##     one built from a REAL lift and a REAL lease/state-store
##     round-trip -- and L7 is where the record comes from a live
##     instance instead.
##   * `repro up --replace`'s CLI wiring is **L7**'s for the same reason:
##     there is nothing to replace until there is a registry to resolve.
##     `replaceDecision` is the whole of the policy, and it is callable
##     today.
##
## § THE LEASE MACHINERY IS REUSED, NOT MODELLED
##
## `lease.nim` already reference-counts holders per address
## (`leased(address, consumerId, policy)`) and already maps a policy to a
## deadline (`deadlineFrom`), and `reaper.nim` already defines LIVE as
## "its own recorded deadline is still in the future". `holderIsLive`
## below is that same predicate with the `keep` case written out, and
## `holdersFromLeasedDeps` / `holdersFromStateRecord` are the two real
## sources a caller has. Nothing about a lease is re-implemented.
##
## ONE LIMITATION OF THE ON-DISK RECORD, STATED RATHER THAN PAPERED
## OVER. `mergeHolderDeadlines` DROPS a `keep` holder from
## `ResourceStateRecord.holders` (it "pins with no expiry", recorded only
## as `effectiveDeadline = none`), so a record alone cannot NAME a keep
## holder -- and D-SS5 expects a `stable`, state-owning service to
## default to `keep`. `holdersFromStateRecord` therefore reports what the
## record can carry and says what it cannot; naming a keep holder needs
## the holder set L7's registry will hold, or a keep-holder list in the
## record. See `holdersFromStateRecord`'s own comment.
##
## § TEST-DOUBLE POLICY
##
## No mocks are used by this module's tests and none may be added. The
## snapshots come from real `package` blocks expanded by the real DSL
## macro and lifted by the real `toProjectInterface`; the holders come
## from real `LeasedDep` values through the real `deadlineFrom`, written
## to and read back from a real `StateStore` under a throwaway root --
## never a live `.repro/` tree.
##
## § WHY THIS MODULE IS IN `repro_resources`, AND WHY IT IS NOT IN THE
##   UMBRELLA
##
## Same two reasons `service_identity.nim` gives. It bridges the lanes:
## it reads the lifted interface (`repro_interface_artifacts`) and the
## instance key / lease projections (`repro_resources`), and the reverse
## dependency does not exist. And it is deliberately NOT re-exported
## from the `repro_resources` umbrella, which is linked into every
## out-of-tree resource provider -- none of which decides an attach.
## Import `repro_resources/service_attach` by name.

import std/[algorithm, options, strutils, tables, times]

import blake3
import repro_core                              # writeString / writeU32Le
import repro_interface_artifacts               # ProjectInterface & friends
import repro_resources/lease                   # LeasedDep / deadlineFrom
import repro_resources/service_identity        # ServiceInstanceKey & friends
import repro_resources/state_store             # ResourceStateRecord

const
  ServiceInterfaceDigestTag* = "reprobuild.service-interface.v1"
    ## Domain-separation tag, first in the per-service interface digest.
    ## Distinct from `service_identity`'s `ServiceIdentityDigestTag` for
    ## the reason that one exists: two digests computed by two different
    ## schemes over overlapping material must not be able to collide, and
    ## a scheme change is a tag change. It is also the reason this digest
    ## can never be confused with an IDENTITY digest -- §4.2's `derived`
    ## identity is a digest of the materialised definition, and this is a
    ## digest of the SIGNATURE. Mixing them would make an
    ## implementation-only change move the attach comparand, which is
    ## exactly what the gate's control forbids.

  UndeclaredCompatibilityMajor* = 0'u32
    ## The major a service that never wrote `compatibility <n>` carries.
    ##
    ## It is the ZERO value on purpose, and the reason is the envelope.
    ## `InterfaceService.compatibilityMajor` is read only from a v>=23
    ## payload, so every v<23 artifact decodes to 0 -- and if the DSL's
    ## default were 1, a cached pre-v23 artifact would compare UNEQUAL
    ## against a freshly lifted definition that declared nothing, and the
    ## decision's hardest outcome (refusal) would fire for an artifact
    ## version boundary rather than for an incompatibility. With 0 as both
    ## the decode default and the DSL default, every service that declares
    ## nothing agrees with every other, across the boundary.
    ##
    ## The DSL consequently REFUSES `compatibility 0`: declaring it would
    ## be indistinguishable from not declaring it, and a setter whose
    ## value cannot be observed is the silent drop this campaign keeps
    ## finding.

type
  ServiceAttachError* = object of CatchableError
    ## Raised when a snapshot cannot be taken at all -- the named service
    ## is not in the lifted interface. Never raised to express an
    ## OUTCOME: a refusal is a value (`saoRefuseMajor`), because the
    ## caller has to print it, and an exception would make "refuse"
    ## indistinguishable from "this interface does not describe that
    ## service".

  ServiceMemberKind* = enum
    ## The categories of thing a consumer compiles against when it
    ## resolves a service. §7 names the two kinds of value ON a resolved
    ## handle -- staged configurables and computed resource attributes --
    ## and this enum is the SIGNATURE side of that: what the lift
    ## carries, which is what a fingerprint can compare.
    smkSignature       ## a field of the service row itself
    smkActivityParam   ## a constructor parameter of the declaring activity
    smkConfigKey       ## a `config:` key of the declaring activity
    smkSiblingService  ## another service the declaring activity declares
    smkContributionPoint
      ## Shared-Development-Services D-SS11 (§4.6): a CONTRIBUTION POINT
      ## the service converges.
      ##
      ## It is a member a consumer compiles against, which is why it is
      ## in this enum and therefore in the fingerprint: a consumer writes
      ## `infra.sso.shared(relyingParties = append("x"))` against the
      ## owner's declared point set, exactly as it writes
      ## `sso.externalDomain` against a `config:` key. §4.6 requires the
      ## lift to carry the points for that reason.
      ##
      ## APPENDED AS THE LAST ENUM VALUE, so no existing ordinal moves.
      ## The per-service digest writes `ord(member.kind)`, so inserting
      ## it anywhere earlier would re-key every existing fingerprint for
      ## a reason that has nothing to do with any interface changing.
      ##
      ## IT IS DISTINCT FROM `smkConfigKey` even though a contribution
      ## point IS a `config:` key. The two statements a consumer can make
      ## about one key are different -- "bind this" (refused to a
      ## consumer, §6.6) and "append to this" (the whole of §5) -- so an
      ## instance that stopped converging a point while keeping the key
      ## has changed what a contributing consumer compiled against, and a
      ## member list that said only `config:` could not name it.

  ServiceInterfaceMember* = object
    kind*: ServiceMemberKind
    name*: string
      ## The member's declared name, as the author wrote it, VERBATIM.
      ##
      ## Verbatim because that is what `interfaceFingerprint` already
      ## does -- `writeActivity` writes `key.name` as declared -- so
      ## normalising here would make the per-service digest disagree with
      ## the package-wide one about whether a cosmetic re-spelling is a
      ## change. It is NOT because Nim would reject the other spelling:
      ## Nim's identifier equality folds case and underscores, so a
      ## consumer's `enable sso(external_domain = "x")` binds
      ## `externalDomain` perfectly well, and L5's `l5ContainsNormalized`
      ## folds them for the DSL's own key lookup too. The consequence is
      ## therefore a CONSERVATIVE over-warning and never a missed one: a
      ## producer who re-spells a key warns its consumers about a
      ## difference they could have ignored. Said plainly because the
      ## opposite claim -- that the two spellings are a real interface
      ## change -- is false and was written here first.
      ##
      ## THE COMPARISON IS SYMMETRIC, which is the asymmetry check this
      ## campaign's standing hunt demands after L5's blocking defect.
      ## `memberDifferences` keys BOTH sides off this field unfolded, and
      ## both sides are produced by the same projection out of the same
      ## lift, so there is no side on which a different rule applies. The
      ## one place a CALLER's spelling meets a declared one is
      ## `serviceInterfaceMembers`' `serviceName` argument, and a
      ## mismatch there raises `ServiceAttachError` naming every service
      ## the interface does declare -- loud, not silent.
    signature*: string
      ## What a consumer compiles against -- the Nim type for a param or
      ## a config key, the declared value for a signature field.

  ServiceInterfaceSnapshot* = object
    ## The interface projection of ONE service: both sides of the attach
    ## decision carry exactly this, and nothing else.
    serviceName*: string
    packageName*: string
    projectName*: string
    activityName*: string
      ## The declaring activity, or "" for a package-level service.
    handleType*: string
    compatibilityMajor*: uint32
    members*: seq[ServiceInterfaceMember]
    fingerprint*: string
      ## Lowercase hex of the per-service interface digest, taken OVER
      ## `members` -- see this module's header for why it is per-service
      ## rather than the package-wide one, and for the exact strength of
      ## the "a warning's member list is never empty" property (an
      ## assertion over the fixture set, not a construction).
    projectFingerprint*: string
      ## Lowercase hex of `interfaceFingerprint(ProjectInterface)`.
      ## Diagnostic only, and deliberately not the comparand.

  ServiceMemberChange* = enum
    smcAdded      ## in the resolving definition, absent from the running one
    smcRemoved    ## in the running instance, absent from the resolving one
    smcChanged    ## in both, with a different signature
    smcReordered
      ## in both, with the SAME name, kind and signature, at a different
      ## position.
      ##
      ## WHY THIS KIND EXISTS, AND IT IS A DEFECT REPORT. The digest is
      ## order-sensitive BY DESIGN -- `serviceInterfaceMembers` refuses
      ## to sort, because reordering two `config:` keys changes which
      ## key a POSITIONAL `enable sso(..., 9)` argument binds, so a
      ## reorder is a real interface change. `memberDifferences` keyed
      ## both sides on `(kind, name)` ALONE and was therefore
      ## order-INSENSITIVE, so a pure reorder moved the fingerprint,
      ## reached §4.3's row 2 -- and named NO member. Measured on the
      ## L6 tree before this kind existed, over `l6AttOrderA` /
      ## `l6AttOrderB` (two `config:` keys, reverse order, nothing else
      ## changed): fingerprints `79ee2201efbd5547...` vs
      ## `b3747a45956add46...`, outcome `saoAttachWithWarning`,
      ## `memberDifferences` count **0**, diagnostic "... Differing
      ## members: . Shared-Development..." -- an empty list where §4.3
      ## requires "the members that differ".
      ##
      ## The fix is NOT to canonicalise the digest input. Sorting it
      ## would make a reorder attach SILENTLY, which trades a warning
      ## that names nothing for no warning at all about a change that
      ## rebinds a consumer's positional arguments. The diff is made
      ## position-aware instead, which is this kind.

  ServiceMemberDifference* = object
    kind*: ServiceMemberKind
    name*: string
    change*: ServiceMemberChange
    runningSignature*: string
    requestedSignature*: string
    runningOrdinal*: int
      ## For `smcReordered`: the member's 0-based position among the
      ## members BOTH snapshots carry, in the running instance's
      ## declaration order. `-1` for every other change kind, where it
      ## has no meaning -- an explicit -1 rather than the object's
      ## default 0, so a reader cannot mistake "not applicable" for
      ## "first".
      ##
      ## IT COUNTS SHARED MEMBERS AND NOT ABSOLUTE POSITIONS, and that
      ## is the whole of the anti-spray rule -- see
      ## `memberDifferences`.
    requestedOrdinal*: int
      ## The same position in the resolving definition's declaration
      ## order. `-1` outside `smcReordered`.

  ServiceInstanceHolder* = object
    ## One reference-counted holder of a running instance, in the shape
    ## `lease.nim` reference-counts them: a `consumerId` and the deadline
    ## its policy maps to.
    consumerId*: string
    deadline*: Option[Time]
      ## `none` is a `keep` holder -- it pins with NO expiry, which is
      ## `deadlineFrom`'s own answer for `lkKeep` and the one §2.3 calls
      ## dominating. It is NOT "unknown".

  RunningServiceInstance* = object
    ## A REPRESENTABLE RECORD of a running instance. L7's registry is
    ## what will produce one from a live daemon; this milestone's tests
    ## construct one from a real lift and a real lease/state round-trip.
    ## Either way the decision functions below see the same type, so L7
    ## adds a producer and changes no policy.
    key*: ServiceInstanceKey
    address*: string
      ## `serviceInstanceAddress(key)` -- the address the lease is held
      ## on. Carried rather than recomputed so a record read back from a
      ## store can report the address it was actually stored under.
    interfaceSnapshot*: ServiceInterfaceSnapshot
      ## The snapshot of the definition the RUNNING instance was started
      ## from. §4.3's warning names "the project whose definition is
      ## running", which is why the snapshot carries its project name.
    holders*: seq[ServiceInstanceHolder]

  ServiceAttachOutcome* = enum
    saoAttachSilently      ## §4.3 row 1
    saoAttachWithWarning   ## §4.3 row 2
    saoRefuseMajor         ## §4.3 row 3

  ServiceAttachDecision* = object
    outcome*: ServiceAttachOutcome
    diagnostic*: string
      ## The warning or the refusal, rendered. EMPTY if and only if the
      ## outcome is `saoAttachSilently` -- asserted in both directions,
      ## because "attach silently" that printed something would fail the
      ## gate's control just as surely as a warning on every difference.
    differences*: seq[ServiceMemberDifference]
    serviceName*: string
    runningFingerprint*: string
    requestedFingerprint*: string
    runningMajor*: uint32
    requestedMajor*: uint32
    runningProject*: string
    runningPackage*: string

  ServiceReplaceOutcome* = enum
    sroReplace              ## stop the running instance, start this definition
    sroRefuseOtherHolders   ## another holder has a live lease
    sroForcedOverOtherHolders
      ## `--force`: proceed THOUGH another holder has a live lease. A
      ## third value rather than `sroReplace` with a flag, because the
      ## caller must print the names it is overriding and a bool invites
      ## dropping them.

  ServiceReplaceDecision* = object
    outcome*: ServiceReplaceOutcome
    diagnostic*: string
      ## Empty if and only if the outcome is `sroReplace`.
    blockingHolders*: seq[string]
      ## The live holders OTHER than the requester, sorted, so a refusal
      ## and a forced override name the same set in the same order.
    lapsedHolders*: seq[string]
      ## Holders whose dated lease has expired. Named separately because
      ## they are NOT a reason to refuse and a reader who sees only
      ## "three holders" would think they were.

static:
  ## THE WIRE ORDINALS OF `ServiceMemberKind`, ASSERTED RATHER THAN
  ## DESCRIBED. `serviceInterfaceDigest` writes `ord(member.kind)` into
  ## the per-service digest, so these five numbers are part of a
  ## persisted comparison: inserting a value mid-enum silently renumbers
  ## every later one and re-keys every existing fingerprint for a reason
  ## unrelated to any interface changing.
  ##
  ## `smkContributionPoint`'s own doc comment says it was "appended as
  ## the last enum value, so no existing ordinal moves" -- but a comment
  ## is not a guarantee, and before this block nothing in the tree would
  ## have failed if a later value were inserted above it. This block is
  ## the guarantee: a mid-enum insertion is now a COMPILE error in this
  ## file naming the member whose ordinal moved, which is a structural
  ## check rather than a test that has to be remembered and run.
  ##
  ## The cardinality assertion is what makes it complete. Without it,
  ## APPENDING a sixth value -- which is the safe operation -- would also
  ## be invisible here, and a reviewer would have no prompt to confirm
  ## the new value went at the end rather than merely compiling. Adding
  ## one is meant to require editing this block.
  doAssert ord(smkSignature) == 0, "ServiceMemberKind: smkSignature moved"
  doAssert ord(smkActivityParam) == 1,
    "ServiceMemberKind: smkActivityParam moved"
  doAssert ord(smkConfigKey) == 2, "ServiceMemberKind: smkConfigKey moved"
  doAssert ord(smkSiblingService) == 3,
    "ServiceMemberKind: smkSiblingService moved"
  doAssert ord(smkContributionPoint) == 4,
    "ServiceMemberKind: smkContributionPoint moved -- D-SS11 appended it " &
    "as ordinal 4 and the per-service digest writes ord(kind), so this " &
    "renumbering re-keys every persisted service fingerprint"
  doAssert ord(high(ServiceMemberKind)) == 4,
    "ServiceMemberKind grew or shrank: confirm the new value was APPENDED " &
    "(the digest writes ord(kind)) and then update this assertion"

# ---------------------------------------------------------------------------
# The interface projection.
# ---------------------------------------------------------------------------

proc majorWord*(major: uint32): string =
  ## A major, for a diagnostic. `UndeclaredCompatibilityMajor` renders as
  ## what it means rather than as the bare digit: a refusal that read
  ## "its major is 2 and this definition declares 0" sends the author
  ## looking for a `compatibility 0` they never wrote, when the fact is
  ## that one side has no `compatibility` setter at all.
  if major == UndeclaredCompatibilityMajor: "0 (it declares none)"
  else: $major

proc memberKindWord*(kind: ServiceMemberKind): string =
  ## The phrase a diagnostic uses for a member category.
  case kind
  of smkSignature: "signature field"
  of smkActivityParam: "activity parameter"
  of smkConfigKey: "config key"
  of smkSiblingService: "sibling service"
  of smkContributionPoint: "contribution point"

proc identityModeWord*(mode: InterfaceServiceIdentityMode): string =
  case mode
  of isimDerived: "derived"
  of isimStable: "stable"

proc scopeWord*(scope: InterfaceServiceScope): string =
  case scope
  of issProject: "project"
  of issWorkspace: "workspace"
  of issUser: "user"
  of issSystem: "system"

proc serviceInterfaceMembers*(value: ProjectInterface;
                              serviceName: string):
    seq[ServiceInterfaceMember] =
  ## The member list a consumer of `serviceName` compiles against.
  ##
  ## Order is DECLARATION order within each category and the categories
  ## are in a fixed order, so the digest below is a function of the
  ## declaration and not of a table's iteration. A `sort` here would
  ## instead make a REORDERING of two `config:` keys invisible, and a
  ## reorder changes which parameter a POSITIONAL `enable` argument binds
  ## (L5/M.1 measured Nim's rule: an argument at index `i` binds the
  ## parameter at index `i`), so it is a real interface change.
  var svc: InterfaceService
  var found = false
  for candidate in value.publicServices:
    if candidate.name == serviceName:
      svc = candidate
      found = true
      break
  if not found:
    var available: seq[string] = @[]
    for candidate in value.publicServices:
      available.add("`" & candidate.name & "`")
    raise newException(ServiceAttachError,
      "the lifted interface of package `" & value.packageName &
      "` declares no service named `" & serviceName & "`; it declares " &
      (if available.len == 0: "none"
       else: available.join(", ")) &
      ". A snapshot is taken of a service the LIFT carries, which is " &
      "the only thing a consumer can have compiled against.")
  result = @[
    ServiceInterfaceMember(kind: smkSignature, name: "name",
      signature: svc.name),
    ServiceInterfaceMember(kind: smkSignature, name: "activity",
      signature: svc.activityName),
    ServiceInterfaceMember(kind: smkSignature, name: "handleType",
      signature: svc.handleType),
    ServiceInterfaceMember(kind: smkSignature, name: "identity",
      signature:
        identityModeWord(svc.identityMode) &
        (if svc.identityMode == isimStable:
           " \"" & svc.identityStableId & "\""
         else: "")),
    ServiceInterfaceMember(kind: smkSignature, name: "scope",
      signature: scopeWord(svc.scope)),
    ServiceInterfaceMember(kind: smkSignature, name: "compatibility",
      signature: $svc.compatibilityMajor)]
  # D-SS11: the contribution points are appended at the END, after the
  # activity's members, so this block is skipped rather than returned
  # from -- a PACKAGE-LEVEL service has no declaring activity and the
  # loop below would find none, but it can still declare `converge`, and
  # a point that reached the artifact and not the snapshot would be a
  # point a consumer compiles against and the attach decision cannot see.
  if svc.activityName.len > 0:
    for act in value.publicActivities:
      if act.name != svc.activityName:
        continue
      for param in act.params:
        result.add(ServiceInterfaceMember(kind: smkActivityParam,
          name: param.name, signature: param.nimType))
      for key in act.config:
        # REQUIRED-NESS IS CARRIED AND IT NEEDED NO NEW FIELD. L5's review
        # expected one `bool` on `InterfaceConfigKey` here; "required" is
        # exactly "declared with no default" (L5's own words: "a `config:`
        # key with no default is a REQUIRED configurable"), and
        # `hasDefault` has carried that since L3 at v21. So the signature
        # below spells it out of the two fields that already exist, and the
        # envelope gained no field for it -- see this milestone's report.
        result.add(ServiceInterfaceMember(kind: smkConfigKey,
          name: key.name,
          signature:
            key.nimType &
            (if key.hasDefault: " = " & key.defaultRepr else: " (required)")))
      for sibling in act.services:
        if sibling == svc.name:
          continue
        result.add(ServiceInterfaceMember(kind: smkSiblingService,
          name: sibling, signature: ""))
      break
  # D-SS11: the contribution points, LAST.
  #
  # The signature is the point's own name, not its type: the lift carries
  # bare names (§4.6's reason -- the consumer's spelling and the owner's
  # are the same string), and the TYPE of a contribution point is
  # `seq[string]` for every point this port carries, so a type here would
  # be a constant dressed as a comparand.
  for point in svc.contributionPoints:
    result.add(ServiceInterfaceMember(kind: smkContributionPoint,
      name: point, signature: point))

proc contributionPointsOf*(snapshot: ServiceInterfaceSnapshot):
    seq[string] =
  ## The CONTRIBUTION POINTS a snapshot declares, bare names, declaration
  ## order.
  ##
  ## §4.6: "a contribution that reaches an instance which does not
  ## declare that point must be **refused, never dropped** -- including
  ## across a version skew, where the running instance was built from an
  ## older definition that lacks the point." The snapshot is the one
  ## record both sides of that comparison already carry: the RUNNING
  ## instance's is persisted with its registry record, and the resolving
  ## definition's comes out of the owner's lift. So this projection --
  ## and not a second channel -- is what the refusal reads.
  for member in snapshot.members:
    if member.kind == smkContributionPoint:
      result.add(member.name)

proc serviceInterfaceFingerprint*(members: openArray[ServiceInterfaceMember]):
    string =
  ## The per-service interface digest, as lowercase hex.
  ##
  ## Length-prefixed through `repro_core`'s `writeString` / `writeU32Le`,
  ## the same primitives every other payload in this repository uses, so
  ## the encoding is INJECTIVE: two different member SEQUENCES cannot
  ## encode to the same bytes. A naive `join` would not have it -- a
  ## member named `a` with signature `b:c` and one named `a:b` with
  ## signature `c` would collide.
  ##
  ## WHAT INJECTIVITY DOES AND DOES NOT BUY, SAID PRECISELY, BECAUSE
  ## THIS COMMENT CLAIMED THE STRONGER THING AND L6'S REVIEW DISPROVED
  ## IT. It buys "equal fingerprints implies the member sequences are
  ## identical", so row 1 cannot fire on two interfaces that differ in
  ## any way this projection carries. It does NOT buy "differing
  ## fingerprints implies `memberDifferences` is non-empty": that is a
  ## claim about the DIFF, and it holds only because
  ## `memberDifferences` compares the same things this digest does --
  ## names, kinds, signatures AND relative position. It compares
  ## position because of `smcReordered`, added after a measured empty
  ## warning. If anyone ever makes the diff order-insensitive again, or
  ## sorts the input here, that pairing breaks and the reorder fixtures
  ## are what says so.
  ##
  ## THE INPUT IS NOT SORTED, ON PURPOSE. See
  ## `serviceInterfaceMembers`: order is declaration order because a
  ## reorder rebinds a POSITIONAL `enable` argument.
  var payload: seq[byte] = @[]
  payload.writeString(ServiceInterfaceDigestTag)
  payload.writeU32Le(uint32(members.len))
  for member in members:
    payload.add(byte(ord(member.kind)))
    payload.writeString(member.name)
    payload.writeString(member.signature)
  blake3.digest(payload).toHex().toLowerAscii()

proc serviceInterfaceSnapshot*(value: ProjectInterface;
                               serviceName: string): ServiceInterfaceSnapshot =
  ## The snapshot both sides of §4.3's comparison are made of.
  var svc: InterfaceService
  for candidate in value.publicServices:
    if candidate.name == serviceName:
      svc = candidate
      break
  let members = serviceInterfaceMembers(value, serviceName)
  ServiceInterfaceSnapshot(
    serviceName: serviceName,
    packageName: value.packageName,
    projectName: value.projectName,
    activityName: svc.activityName,
    handleType: svc.handleType,
    compatibilityMajor: svc.compatibilityMajor,
    members: members,
    fingerprint: serviceInterfaceFingerprint(members),
    projectFingerprint: toHex(interfaceFingerprint(value).bytes).toLowerAscii())

# ---------------------------------------------------------------------------
# The member diff that the warning names.
# ---------------------------------------------------------------------------

proc memberKeyOf(member: ServiceInterfaceMember): string =
  ## The identity a member is matched on across the two snapshots:
  ## `(kind, name)`, with a NUL separator so a kind ordinal cannot run
  ## into a name that begins with a digit. Factored out because the diff
  ## below now needs it in five places and a fifth hand-spelled copy is
  ## how the two sides drift apart.
  $ord(member.kind) & "\x00" & member.name

proc memberDifferences*(running, requested: ServiceInterfaceSnapshot):
    seq[ServiceMemberDifference] =
  ## The members that differ, in a stable order: removals, signature
  ## changes and REORDERS in the RUNNING instance's declaration order
  ## first, then additions in the resolving definition's.
  ##
  ## § THE DIFF IS POSITION-AWARE, BECAUSE THE DIGEST IS
  ##
  ## `serviceInterfaceFingerprint` digests `members` IN ORDER and
  ## `serviceInterfaceMembers` deliberately does not sort, for the
  ## reason that comment gives: a reorder of two `config:` keys rebinds
  ## a consumer's POSITIONAL `enable` argument, so it is a real
  ## interface change. A diff keyed on `(kind, name)` alone is
  ## order-insensitive and therefore CANNOT name the difference the
  ## digest just reacted to -- which is exactly the empty warning L6's
  ## review measured (see `smcReordered`). So the two have to agree on
  ## what a difference is, and they agree HERE, by this proc also
  ## looking at position. The alternative -- sorting the digest input --
  ## was rejected: it would make a reorder attach silently.
  ##
  ## § THE ANTI-SPRAY RULE: POSITIONS ARE COUNTED AMONG SHARED MEMBERS
  ##   ONLY
  ##
  ## The ordinal a member is compared on is its index in the
  ## SUBSEQUENCE of members the two snapshots BOTH carry, in each side's
  ## own declaration order -- not its absolute index in `members`.
  ##
  ## The reason is insertion and removal. Adding one `config:` key at
  ## the FRONT shifts every following member's absolute index by one, so
  ## an absolute-ordinal comparison would report one addition plus a
  ## spurious reorder for every member after it -- N+1 differences for
  ## one edit, and the author would be told that keys they never touched
  ## had moved. Restricting the count to the shared members makes that
  ## insertion report exactly one addition: the shared members keep
  ## their relative order, so every shared ordinal is unchanged. What
  ## survives the restriction is precisely a change in the RELATIVE
  ## order of members both sides declare, which is the only thing that
  ## can rebind a positional argument between two interfaces that
  ## otherwise agree.
  ##
  ## A member whose SIGNATURE changed is reported as `smcChanged` and
  ## never also as `smcReordered`: the signature change is the stronger
  ## and more actionable statement, and reporting both would double-name
  ## one member. It still OCCUPIES its slot in the shared subsequence,
  ## because it is present on both sides -- dropping it would make its
  ## neighbours look moved.
  ##
  ## WHAT THIS RULE IS NOT: a minimal set of moves. Two sides whose
  ## shared members are a ROTATION of each other (`a b c` against
  ## `c a b`) have every shared ordinal changed, so all three are named
  ## even though one move explains it. That is conservative in the safe
  ## direction -- it over-names and never misses a reorder -- and it
  ## keeps the rule something a reader can evaluate by hand. A
  ## longest-common-subsequence diff would name fewer; it is not needed
  ## for a warning whose job is to say which members to look at.
  result = @[]
  var requestedByKey = initTable[string, ServiceInterfaceMember]()
  for member in requested.members:
    requestedByKey[memberKeyOf(member)] = member
  var runningByKey = initTable[string, ServiceInterfaceMember]()
  for member in running.members:
    runningByKey[memberKeyOf(member)] = member

  # The shared-member subsequences, one ordinal table per side.
  var runningSharedOrdinal = initTable[string, int]()
  var runningShared = 0
  for member in running.members:
    let key = memberKeyOf(member)
    if key in requestedByKey:
      runningSharedOrdinal[key] = runningShared
      inc runningShared
  var requestedSharedOrdinal = initTable[string, int]()
  var requestedShared = 0
  for member in requested.members:
    let key = memberKeyOf(member)
    if key in runningByKey:
      requestedSharedOrdinal[key] = requestedShared
      inc requestedShared

  var seenKeys: seq[string] = @[]
  for member in running.members:
    let key = memberKeyOf(member)
    seenKeys.add(key)
    if key notin requestedByKey:
      result.add(ServiceMemberDifference(kind: member.kind,
        name: member.name, change: smcRemoved,
        runningSignature: member.signature, requestedSignature: "",
        runningOrdinal: -1, requestedOrdinal: -1))
      continue
    let other = requestedByKey[key]
    if other.signature != member.signature:
      result.add(ServiceMemberDifference(kind: member.kind,
        name: member.name, change: smcChanged,
        runningSignature: member.signature,
        requestedSignature: other.signature,
        runningOrdinal: -1, requestedOrdinal: -1))
      continue
    if runningSharedOrdinal[key] != requestedSharedOrdinal[key]:
      result.add(ServiceMemberDifference(kind: member.kind,
        name: member.name, change: smcReordered,
        runningSignature: member.signature,
        requestedSignature: other.signature,
        runningOrdinal: runningSharedOrdinal[key],
        requestedOrdinal: requestedSharedOrdinal[key]))
  for member in requested.members:
    let key = memberKeyOf(member)
    if key notin seenKeys:
      result.add(ServiceMemberDifference(kind: member.kind,
        name: member.name, change: smcAdded,
        runningSignature: "", requestedSignature: member.signature,
        runningOrdinal: -1, requestedOrdinal: -1))

proc renderDifferences(differences: seq[ServiceMemberDifference]): string =
  var parts: seq[string] = @[]
  for diff in differences:
    case diff.change
    of smcChanged:
      parts.add(memberKindWord(diff.kind) & " `" & diff.name & "`: running `" &
        diff.runningSignature & "`, this definition `" &
        diff.requestedSignature & "`")
    of smcRemoved:
      parts.add(memberKindWord(diff.kind) & " `" & diff.name &
        "`: in the running instance (`" & diff.runningSignature &
        "`), absent from this definition")
    of smcAdded:
      parts.add(memberKindWord(diff.kind) & " `" & diff.name &
        "`: in this definition (`" & diff.requestedSignature &
        "`), absent from the running instance")
    of smcReordered:
      # Rendered 1-BASED because it is read by a human looking at their
      # own declaration; the field is 0-based. "of the members both
      # declare" is said rather than implied, because the number is NOT
      # the absolute position in the member list -- see
      # `memberDifferences`' anti-spray rule.
      parts.add(memberKindWord(diff.kind) & " `" & diff.name &
        "`: REORDERED -- same signature (`" & diff.runningSignature &
        "`), at position " & $(diff.runningOrdinal + 1) &
        " in the running instance and position " &
        $(diff.requestedOrdinal + 1) & " in this definition, counting " &
        "only the members both declare; a POSITIONAL argument binds a " &
        "different member against the two")
  parts.join("; ")

# ---------------------------------------------------------------------------
# §4.3 — the three-outcome decision.
# ---------------------------------------------------------------------------

proc attachDecision*(running: RunningServiceInstance;
                     requested: ServiceInterfaceSnapshot):
    ServiceAttachDecision =
  ## §4.3, as a total function. Exactly one of three outcomes, decided in
  ## this order and no other:
  ##
  ##   1. the MAJOR compatibility fields differ -> refuse;
  ##   2. else the interface fingerprints are equal -> attach silently;
  ##   3. else -> attach and warn, naming both fingerprints, the owning
  ##      project and the differing members.
  ##
  ## THE ORDER IS THE SPEC'S, AND -- SAID PRECISELY, BECAUSE THIS
  ## COMMENT CLAIMED THE STRONGER THING AND L6's SECOND REVIEW MEASURED
  ## IT -- THE TWO GUARDS ARE CURRENTLY INTERCHANGEABLE. The major is a
  ## member of the projection, so equal fingerprints imply equal majors
  ## and a differing major implies differing fingerprints. The
  ## fingerprint-equal branch therefore CANNOT fire on a pair whose
  ## majors differ, and swapping the two guards is behaviourally inert:
  ## measured, a true swap of the two blocks leaves the decision binary
  ## at 40 OK / 0 FAILED. What the tests falsify is that the major check
  ## is REACHED -- a mutation that makes this branch unreachable reddens
  ## five cases (section M's M3) -- not its position.
  ##
  ## The order is nonetheless kept major-first, for two reasons that are
  ## not behavioural today: it is the order §4.3's table is written in,
  ## and it stops being interchangeable the moment the major leaves the
  ## projection, at which point testing the fingerprint first WOULD route
  ## an incompatible major to the warning row -- "a warning there would
  ## be a defect report written after the damage". Testing the major
  ## first makes rows 1 and 2 unreachable for a major difference, which
  ## is what the table means by exclusivity.
  let runningSnapshot = running.interfaceSnapshot
  result = ServiceAttachDecision(
    serviceName: requested.serviceName,
    runningFingerprint: runningSnapshot.fingerprint,
    requestedFingerprint: requested.fingerprint,
    runningMajor: runningSnapshot.compatibilityMajor,
    requestedMajor: requested.compatibilityMajor,
    runningProject: runningSnapshot.projectName,
    runningPackage: runningSnapshot.packageName,
    differences: @[])
  if runningSnapshot.compatibilityMajor != requested.compatibilityMajor:
    result.outcome = saoRefuseMajor
    result.differences = memberDifferences(runningSnapshot, requested)
    result.diagnostic =
      "refusing to attach to the running instance of service `" &
      requested.serviceName & "`: its MAJOR compatibility field is " &
      majorWord(runningSnapshot.compatibilityMajor) &
      " and this definition declares " &
      majorWord(requested.compatibilityMajor) &
      ". The running instance was started " &
      "from project `" & runningSnapshot.projectName & "` (package `" &
      runningSnapshot.packageName & "`); this definition is project `" &
      requested.projectName & "` (package `" & requested.packageName &
      "`). Shared-Development-Services.md §4.3: \"Attaching would hand " &
      "the consumer a handle whose members it cannot use; a warning " &
      "there would be a defect report written after the damage.\" " &
      "Either align the two definitions, or take the instance over with " &
      "`repro up --replace`."
    return
  if runningSnapshot.fingerprint == requested.fingerprint:
    result.outcome = saoAttachSilently
    result.diagnostic = ""
    return
  result.outcome = saoAttachWithWarning
  result.differences = memberDifferences(runningSnapshot, requested)
  result.diagnostic =
    "attaching to the running instance of service `" &
    requested.serviceName & "`, which was started from a DIFFERENT " &
    "definition. Running project `" & runningSnapshot.projectName &
    "` (package `" & runningSnapshot.packageName & "`) interface " &
    "fingerprint " & runningSnapshot.fingerprint & "; this definition " &
    "(project `" & requested.projectName & "`, package `" &
    requested.packageName & "`) interface fingerprint " &
    requested.fingerprint & ". Both sides' major compatibility field is " &
    majorWord(requested.compatibilityMajor) & ", so the handle's " &
    "members are usable. Differing members: " &
    renderDifferences(result.differences) &
    ". Shared-Development-Services.md §4.3: \"keep working against the " &
    "live instance, and say that it was built from somebody else's " &
    "definition.\" Use `repro up --replace` to run this definition instead."

# ---------------------------------------------------------------------------
# Holders: the two real sources, and the liveness predicate.
# ---------------------------------------------------------------------------

proc holderIsLive*(holder: ServiceInstanceHolder; now: Time): bool =
  ## `reaper.nim`'s own definition -- "a holder is LIVE if its own
  ## recorded deadline is still in the future (`holders[c] > now`)" --
  ## with the `keep` case written out: a holder with NO deadline pins
  ## with no expiry and is always live (§2.3's keep-dominates rule).
  ## Strictly `>`, matching `hasLiveHolder`, so a holder whose deadline
  ## is exactly `now` is lapsed in both places.
  holder.deadline.isNone or holder.deadline.get > now

proc holdersFromLeasedDeps*(deps: openArray[LeasedDep]; now: Time):
    seq[ServiceInstanceHolder] =
  ## The holder set of a `LeasedDep` list, through the REAL
  ## `deadlineFrom`. This is the complete source: a `keep` dep yields a
  ## `none` deadline and keeps its `consumerId`, which is the case the
  ## on-disk record cannot represent.
  result = @[]
  for dep in deps:
    result.add(ServiceInstanceHolder(consumerId: dep.consumerId,
      deadline: deadlineFrom(dep.policy, now)))

proc holdersFromStateRecord*(record: ResourceStateRecord):
    tuple[holders: seq[ServiceInstanceHolder];
          mayHaveUnnamedKeepHolder: bool] =
  ## The holder set a persisted `ResourceStateRecord` can carry, plus the
  ## flag for what it cannot.
  ##
  ## `reconcile.mergeHolderDeadlines` DELIBERATELY `del`s a `keep` holder
  ## from `holders` -- "it pins with no expiry ... rather than storing a
  ## bogus deadline" -- and records only `effectiveDeadline = none`. So a
  ## record whose effective deadline is `none` may be pinned by a holder
  ## whose NAME was never written down, and a caller that must NAME
  ## holders (`replaceDecision`'s refusal) has to get them from the
  ## registry instead. Reported rather than guessed, because inventing a
  ## name here would make a refusal name the wrong project.
  ##
  ## THE FLAG IS "MAY HAVE" AND NOT "HAS", AND THE IMPRECISION IS THE
  ## FINDING. `effectiveDeadline == none` is produced by TWO different
  ## states -- "at least one `keep` holder pins this" and "no dated
  ## holder exists at all" -- and the record carries nothing that
  ## separates them. So this proc cannot answer "is there a keep holder";
  ## only "could there be one, unnamed". Claiming the stronger answer
  ## would make a `--replace` refuse an instance nobody holds. L6 hands
  ## this to **L7**: the registry holds the holder set, so it can answer
  ## exactly; the alternative is a keep-holder list in the record. It
  ## matters because D-SS5 expects a `stable`, state-owning service to
  ## default to `keep`, which is precisely the case the record loses.
  result.holders = @[]
  for consumerId, deadline in record.holders:
    result.holders.add(ServiceInstanceHolder(consumerId: consumerId,
      deadline: some(deadline)))
  result.holders.sort(proc (a, b: ServiceInstanceHolder): int =
    cmp(a.consumerId, b.consumerId))
  result.mayHaveUnnamedKeepHolder = record.effectiveDeadline.isNone

proc runningServiceInstance*(key: ServiceInstanceKey;
                             snapshot: ServiceInterfaceSnapshot;
                             holders: openArray[ServiceInstanceHolder]):
    RunningServiceInstance =
  ## Assemble the record. The address is derived from the key by the same
  ## `serviceInstanceAddress` the lease is taken under, so a record and
  ## the lease it refers to cannot name different addresses.
  RunningServiceInstance(
    key: key,
    address: serviceInstanceAddress(key),
    interfaceSnapshot: snapshot,
    holders: @holders)

# ---------------------------------------------------------------------------
# §4.3's second half — `repro up --replace`.
# ---------------------------------------------------------------------------

proc replaceDecision*(running: RunningServiceInstance;
                      requestingHolder: string;
                      now: Time;
                      force = false): ServiceReplaceDecision =
  ## §4.3: "`repro up --replace` stops the running instance and starts
  ## this consumer's definition. It **refuses while other holders have
  ## live leases**, naming them, and proceeds under `--force`."
  ##
  ## "OTHER" is load-bearing and is the requester's own holder id: a
  ## project replacing an instance it is itself holding must not be
  ## refused by its own lease, which would make `--replace` unusable for
  ## the one consumer most likely to want it.
  ##
  ## A LAPSED dated holder is not a blocker, and it is named separately
  ## rather than dropped -- see `lapsedHolders`.
  result = ServiceReplaceDecision(blockingHolders: @[], lapsedHolders: @[])
  for holder in running.holders:
    if holder.consumerId == requestingHolder:
      continue
    if holderIsLive(holder, now):
      result.blockingHolders.add(holder.consumerId)
    else:
      result.lapsedHolders.add(holder.consumerId)
  result.blockingHolders.sort()
  result.lapsedHolders.sort()
  if result.blockingHolders.len == 0:
    result.outcome = sroReplace
    result.diagnostic = ""
    return
  var named: seq[string] = @[]
  for holder in result.blockingHolders:
    named.add("`" & holder & "`")
  let shared =
    "the running instance of service `" &
    running.interfaceSnapshot.serviceName & "` at `" & running.address &
    "` is held by " & $result.blockingHolders.len & " other live lease" &
    (if result.blockingHolders.len == 1: "" else: "s") & ": " &
    named.join(", ") & "."
  if force:
    result.outcome = sroForcedOverOtherHolders
    result.diagnostic =
      "`--force`: replacing anyway. " & shared &
      " Those holders lose the instance they are using; " &
      "Shared-Development-Services.md §4.3 makes this the explicit " &
      "takeover path, and `--force` is what makes it explicit."
  else:
    result.outcome = sroRefuseOtherHolders
    result.diagnostic =
      "refusing `repro up --replace`: " & shared &
      " Stopping it would take the instance away from " &
      (if result.blockingHolders.len == 1: "that holder"
       else: "those holders") &
      " mid-use. Run `repro down` in " &
      (if result.blockingHolders.len == 1: "it" else: "them") &
      ", or pass `--force` to replace the instance anyway. " &
      "Shared-Development-Services.md §4.3: `--replace` \"refuses while " &
      "other holders have live leases, naming them, and proceeds under " &
      "`--force`.\""
