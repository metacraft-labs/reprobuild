## Shared-Development-Services L6 (§4.3) — THE ATTACH DECISION: exactly
## one of silent attach / attach-with-warning / refusal, and `repro up
## --replace`'s refusal while another holder has a live lease.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every snapshot comes from a real `package` block in
## `l6_attach_fixtures.nim` expanded by the real DSL macro and lifted by
## the real `toProjectInterface`. Every holder comes from a real
## `LeasedDep` through the real `deadlineFrom` and, for the persisted
## cases, through the real `mergeHolderDeadlines` into a real
## `StateStore` on a real filesystem under a throwaway root. No daemon is
## faked and nothing is started.
##
## WHAT IS DEMONSTRATED AGAINST A CONSTRUCTED RECORD, AND WHY, SAID
## PLAINLY. The REGISTRY that turns an instance key into a *running
## instance* is **L7**, and so is the daemon. So every clause here is
## measured against a `RunningServiceInstance` this file CONSTRUCTS — from
## a real lift and a real lease — rather than against a live instance, and
## L7 is what replaces the constructor with a registry lookup. The
## decision functions are total and pure, so nothing about them changes
## when the record's provenance does; what L7 completes is the provenance.
## `repro up --replace`'s CLI wiring is L7's for the same reason: there is
## nothing to replace until there is a registry to resolve against. This
## file does not add a `--replace` flag that would accept and ignore.
##
## WHICH DISCRIMINATOR IS LOAD-BEARING, PER SUITE.
##
## * EVERY suite in this file imports `repro_resources/service_attach`,
##   a module that DOES NOT EXIST at the base commit `dc41f156f`, so at
##   the base the module does not compile and the compiler's `cannot open
##   file: repro_resources/service_attach` IS the measurement. Said
##   plainly rather than implied, because the campaign's rule is to say
##   which case each test is in.
## * The BEHAVIOURAL before/after that a reader should look at for this
##   milestone's refusals is `t_l6_service_compatibility_surface.nim`,
##   where every malformed spelling COMPILES at the base and the exit code
##   genuinely moves; and the fingerprint pair in
##   `t_l6_compatibility_major_crosses_the_lift.nim`, whose two
##   "does move" assertions fail at the base.
## * Within this file the substantive guard against a vacuous pass is the
##   CONTROL: `l6AttBase` vs `l6AttOtherImpl` must be `saoAttachSilently`
##   with an EMPTY diagnostic. A decision that warned on every difference
##   would pass every other case here and fail that one, which is exactly
##   what §4.3 says a design must not do.
## * ONE SUITE IN THIS FILE DOES HAVE A GENUINE BEHAVIOURAL BEFORE/AFTER,
##   and it is the one added by L6's review: "a pure REORDER warns, and
##   the warning names it". Its two naming cases and the strengthened
##   never-empty case FAIL against the order-INSENSITIVE
##   `memberDifferences` that shipped in the first draft of
##   `service_attach.nim` -- not because the module failed to compile,
##   but because the decision really did warn and name nothing. Mutation
##   M-R1 restores that behaviour and is the standing proof; M-R2 takes
##   the rejected alternative (sorting the digest input) and reddens the
##   same cases for the opposite reason. See the milestone drawer's
##   section R.
##
## Governing text — `Shared-Development-Services.md` §4.3 in full, plus
## §10's "an interface-compatible change attaches **without** a warning,
## so the warning retains meaning" and "an incompatible major refuses, and
## `--replace` refuses again while another holder has a live lease".

import std/[algorithm, options, os, strutils, tables, times, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_resources
import repro_resources/service_attach
import repro_resources/service_identity

import ./l6_attach_fixtures

# ---------------------------------------------------------------------------
# Snapshots, from the real lift.
# ---------------------------------------------------------------------------

proc packageDefNamed(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError,
    "fixture drift: no package named " & name & " is registered")

proc normalisedInterface(name: string): ProjectInterface =
  ## The lifted interface with every PACKAGE-DERIVED HANDLE TYPE replaced
  ## by a constant, and nothing else touched.
  ##
  ## The artifice being undone is the same one L3's, L4's and L6's lift
  ## fixtures undo: the scenario is ONE package edited between two
  ## revisions, ten fixture packages cannot share a name inside one
  ## module, and `l3ActivityHandleTypeName` derives the handle type from
  ## the PACKAGE name — so without this every pair would differ on
  ## `handleType` and the comparison would say nothing. In particular the
  ## CONTROL would fail for a reason that has nothing to do with the
  ## implementation.
  ##
  ## `projectName` and `packageName` are deliberately NOT normalised:
  ## neither is a member of the projection, so neither can move the
  ## fingerprint, and §4.3 requires the warning to name "the project
  ## whose definition is running" — which a normalised name could not.
  result = toProjectInterface(packageDefNamed(name))
  for act in result.publicActivities.mitems:
    act.handleType = "NormalisedHandle_" & act.name
  for svc in result.publicServices.mitems:
    if svc.handleType.len > 0:
      svc.handleType = "NormalisedHandle_" & svc.activityName

proc snapshotOf(package: string; service = "zitadel"):
    ServiceInterfaceSnapshot =
  serviceInterfaceSnapshot(normalisedInterface(package), service)

proc scopeContext(package: string): ServiceScopeContext =
  ## A real scope context over a throwaway directory. Never `.repro/` and
  ## never a live tree, which is the campaign's working-agreement
  ## guardrail for every instance-identity experiment.
  let root = getTempDir() / ("repro-l6-" & $getCurrentProcessId() & "-" &
    package)
  createDir(root)
  ## `workspaceId` is supplied because the fixtures declare `scope
  ## workspace`: without it `resolveServiceScope` correctly DEGRADES to
  ## `project` and reports it (L4's measured behaviour), and the address
  ## would then be a project-scoped one -- which would make this file
  ## measure the degradation rather than the attach decision.
  ServiceScopeContext(projectRoot: canonicalRoot(root),
    workspaceRoot: canonicalRoot(root), workspaceId: "l6-workspace",
    user: "l6tester")

proc declaredDefFromLift(package, service: string): DslServiceDef =
  ## The declared identity and scope of a lifted service, in the shape
  ## `serviceInstanceKey` takes.
  ##
  ## WHY A PROJECTION AND NOT A LOWERED RECORD. A `service` declared
  ## inside `devEnv: activity <name>(...):` lowers into the body of the
  ## generated `reproActivity_<name>` proc, so its `DslServiceDef` is
  ## registered when the activity is ENABLED, not at module init --
  ## measured on this tree: `registeredServices("l6AttBase")` holds no
  ## `zitadel`. The DECLARATION is nonetheless real and complete on the
  ## lifted row, which is the whole point of L3's lift, and the mapping
  ## below is ordinal-for-ordinal on enums the static asserts in
  ## `repro_interface_artifacts` keep in step.
  ##
  ## This is NOT a mock: no behaviour is stubbed, and the projection is
  ## checked against a REAL lowered record in the suite "the projected
  ## key agrees with a real lowered record" below. L7's registry will
  ## hold the lowered record itself and will not need the projection.
  let pi = normalisedInterface(package)
  for svc in pi.publicServices:
    if svc.name != service:
      continue
    return DslServiceDef(
      packageName: package, serviceName: svc.name,
      identity: ServiceIdentityDef(
        kind: ServiceIdentityKind(ord(svc.identityMode)),
        stableId: svc.identityStableId),
      scope: ServiceScope(ord(svc.scope)))
  raise newException(ValueError,
    "fixture drift: " & package & " lifts no service " & service)

proc runningFrom(package: string; service = "zitadel";
                 holders: openArray[ServiceInstanceHolder] = []):
    RunningServiceInstance =
  ## A representable record of a running instance, keyed by the REAL
  ## instance key `service_identity` computes for the fixture's own
  ## declared identity and scope — so the address a lease would be taken
  ## on is the one this record reports, not a string this file invented.
  let key = serviceInstanceKey(declaredDefFromLift(package, service),
    scopeContext(package), [], "dev")
  runningServiceInstance(key, snapshotOf(package, service), holders)

proc differenceNamed(decision: ServiceAttachDecision;
                     kind: ServiceMemberKind; name: string):
    Option[ServiceMemberDifference] =
  for diff in decision.differences:
    if diff.kind == kind and diff.name == name:
      return some(diff)
  none(ServiceMemberDifference)

proc changesOfKind(decision: ServiceAttachDecision;
                   change: ServiceMemberChange): int =
  for diff in decision.differences:
    if diff.change == change:
      inc result

proc memberKeySet(snapshot: ServiceInterfaceSnapshot): seq[string] =
  ## The `(kind, name)` keys a snapshot carries, SORTED -- i.e. exactly
  ## what an order-insensitive diff can see. Used by the reorder cases'
  ## fixture-drift guard to prove the pair differs in NOTHING an
  ## order-insensitive comparison could notice.
  result = @[]
  for member in snapshot.members:
    result.add($ord(member.kind) & "/" & member.name & "/" &
      member.signature)
  result.sort()

# ---------------------------------------------------------------------------
# §4.3 row 1 — silent attach, and THE CONTROL.
# ---------------------------------------------------------------------------

suite "L6 §4.3 row 1 — equal fingerprints attach SILENTLY":

  test "THE CONTROL: an implementation-only change emits NO warning":
    # §4.3's own statement of why this clause is the one that keeps the
    # other two meaningful: "a design that warns on every difference
    # fails this gate even though every warning it prints is true."
    #
    # `l6AttOtherImpl` differs from `l6AttBase` in argv, `description`,
    # `restart` and one `env` pair, on BOTH its services. None of it is
    # what a consumer compiles against.
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttOtherImpl"))
    checkpoint(decision.diagnostic)
    check decision.outcome == saoAttachSilently
    check decision.diagnostic == ""
    check decision.differences.len == 0

  test "and the fingerprints really are equal, not merely compared so":
    # The guard against a decision that answered `saoAttachSilently`
    # without comparing anything.
    check snapshotOf("l6AttBase").fingerprint ==
      snapshotOf("l6AttOtherImpl").fingerprint
    check snapshotOf("l6AttBase").fingerprint.len == 64

  test "FIXTURE-DRIFT GUARD: the two implementations really do differ":
    # Without this the control could be passing because the two fixtures
    # had drifted into the same recipe. It is the same guard L4's surface
    # test writes as `doAssert result != WellFormed`, and it reads the
    # fixture SOURCE because that is the only place the implementation of
    # an activity-declared service is visible: the lowered
    # `DslServiceDef` is registered when the activity is enabled (see
    # `declaredDefFromLift`), and the LIFT deliberately does not carry
    # argv at all -- which is the property under test, so reading it from
    # the lift would be circular.
    let fixtures = readFile(currentSourcePath().parentDir() /
      "l6_attach_fixtures.nim")
    check fixtures.contains("\"start-from-init\", \"--port\", $port")
    check fixtures.contains("\"--totally\", \"--different\", \"--argv\"")
    check fixtures.contains("description \"a completely different " &
      "implementation\"")
    check fixtures.contains("restart \"always\"")
    check fixtures.contains("env(\"ZITADEL_LOG\", \"debug\")")

  test "a definition compared with itself attaches silently":
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttBase"))
    check decision.outcome == saoAttachSilently
    check decision.diagnostic == ""

  test "two definitions that declare NO major attach silently":
    # Why the undeclared major is 0 and not 1: every definition that
    # declares nothing, and every pre-v23 artifact, has to agree.
    let decision = attachDecision(runningFrom("l6AttUndeclaredA"),
      snapshotOf("l6AttUndeclaredB"))
    checkpoint(decision.diagnostic)
    check decision.runningMajor == 0'u32
    check decision.requestedMajor == 0'u32
    check decision.outcome == saoAttachSilently

# ---------------------------------------------------------------------------
# §4.3 row 2 — attach and warn.
# ---------------------------------------------------------------------------

suite "L6 §4.3 row 2 — a differing interface within one major WARNS":

  test "an ADDED config key warns, and the warning names it":
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttAddedKey"))
    checkpoint(decision.diagnostic)
    check decision.outcome == saoAttachWithWarning
    let diff = differenceNamed(decision, smkConfigKey, "fixtureUsers")
    check diff.isSome
    check diff.get.change == smcAdded
    check decision.diagnostic.contains("fixtureUsers")

  test "a RETYPED config key warns, naming both signatures":
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttChangedKeyType"))
    checkpoint(decision.diagnostic)
    check decision.outcome == saoAttachWithWarning
    let diff = differenceNamed(decision, smkConfigKey, "port")
    check diff.isSome
    check diff.get.change == smcChanged
    check diff.get.runningSignature.contains("int")
    check diff.get.requestedSignature.contains("string")

  test "a config key LOSING ITS DEFAULT warns -- required-ness is carried":
    # The L5 review expected one new `bool` on `InterfaceConfigKey` for
    # this. "Required" is exactly "declared with no default", which
    # `hasDefault` has carried since L3 at v21, so the member signature
    # spells it out of the two fields that already exist and the envelope
    # gained no field for it. This case is the proof that it is visible.
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttRequiredKey"))
    checkpoint(decision.diagnostic)
    check decision.outcome == saoAttachWithWarning
    let diff = differenceNamed(decision, smkConfigKey, "port")
    check diff.isSome
    check diff.get.change == smcChanged
    check diff.get.runningSignature.contains("= 8080")
    check diff.get.requestedSignature.contains("(required)")

  test "a RETYPED activity parameter warns":
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttOtherParamType"))
    checkpoint(decision.diagnostic)
    check decision.outcome == saoAttachWithWarning
    let diff = differenceNamed(decision, smkActivityParam, "pg")
    check diff.isSome
    check diff.get.change == smcChanged
    check diff.get.runningSignature == "string"
    check diff.get.requestedSignature == "int"

  test "a DELETED sibling service warns, as a removal":
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttNoSibling"))
    checkpoint(decision.diagnostic)
    check decision.outcome == saoAttachWithWarning
    let diff = differenceNamed(decision, smkSiblingService, "bootstrap")
    check diff.isSome
    check diff.get.change == smcRemoved

  test "the warning names BOTH fingerprints and the owning project":
    # §4.3: "The warning names both fingerprints, the project whose
    # definition is running, and the members that differ."
    let running = runningFrom("l6AttBase")
    let decision = attachDecision(running, snapshotOf("l6AttAddedKey"))
    checkpoint(decision.diagnostic)
    check decision.diagnostic.contains(running.interfaceSnapshot.fingerprint)
    check decision.diagnostic.contains(snapshotOf("l6AttAddedKey").fingerprint)
    check decision.diagnostic.contains("l6AttBase")
    check decision.runningProject == "l6AttBase"
    check decision.runningPackage == "l6AttBase"

  test "a warning is never EMPTY of members":
    # §4.3 row 2 requires the warning to name "the members that differ",
    # so a warning with an empty member list is a defect -- the middle
    # row saying nothing actionable.
    #
    # WHAT THIS TEST IS AND IS NOT. It is an ASSERTION over a fixture
    # set, not a proof. The earlier version of this comment claimed the
    # property followed from the digest's injectivity, and that argument
    # is UNSOUND: injectivity gives "equal fingerprints implies the
    # member SEQUENCES are identical", which says nothing about whether
    # an ORDER-INSENSITIVE diff can name the difference. L6's review
    # exhibited the counterexample -- `l6AttOrderA` / `l6AttOrderB`
    # below, where the fingerprints differed and `memberDifferences`
    # returned 0 -- and that is why `smcReordered` exists. The pairs
    # that exhibited it are in the list now, so the list, and not the
    # argument, is what carries the claim.
    #
    # Each entry is a (running, requested) PAIR rather than a single
    # package compared against `l6AttBase`, because the reorder cases
    # are relations between two spellings of one interface and have no
    # single-difference form against the base.
    const warnPairs = [
      ("l6AttBase", "l6AttAddedKey"),
      ("l6AttBase", "l6AttChangedKeyType"),
      ("l6AttBase", "l6AttRequiredKey"),
      ("l6AttBase", "l6AttOtherParamType"),
      ("l6AttBase", "l6AttNoSibling"),
      # The two reorder pairs, in both directions: a position-aware diff
      # has to name a member whichever side is the running one.
      ("l6AttOrderA", "l6AttOrderB"),
      ("l6AttOrderB", "l6AttOrderA"),
      ("l6AttParamOrderA", "l6AttParamOrderB"),
      ("l6AttParamOrderB", "l6AttParamOrderA"),
      ("l6AttOrderA", "l6AttOrderAPlusFront"),
      ("l6AttOrderAPlusFront", "l6AttOrderA")]
    for (runningPkg, requestedPkg) in warnPairs:
      let decision = attachDecision(runningFrom(runningPkg),
        snapshotOf(requestedPkg))
      checkpoint(runningPkg & " <- " & requestedPkg)
      check decision.outcome == saoAttachWithWarning
      check decision.differences.len > 0
      check decision.diagnostic.len > 0
      # And the member is NAMED in the rendered text, not merely counted
      # in the struct -- the empty warning the review measured had a
      # well-formed decision record and a diagnostic reading
      # "Differing members: .".
      for diff in decision.differences:
        check decision.diagnostic.contains(diff.name)
      check not decision.diagnostic.contains("Differing members: .")

  test "the warning says the handle's members are usable":
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttAddedKey"))
    check decision.diagnostic.contains("usable")
    check decision.diagnostic.contains("--replace")

# ---------------------------------------------------------------------------
# §4.3 row 2, the REORDER case — L6's review found a real defect here.
# ---------------------------------------------------------------------------

suite "L6 §4.3 row 2 — a pure REORDER warns, and the warning names it":
  ## WHAT WAS WRONG, MEASURED. `serviceInterfaceFingerprint` digests the
  ## member list IN ORDER and `serviceInterfaceMembers` deliberately does
  ## not sort it, because reordering two `config:` keys changes which key
  ## a POSITIONAL `enable sso(..., 9)` argument binds. But
  ## `memberDifferences` keyed both sides on `(kind, name)` alone, so it
  ## was order-INSENSITIVE. On the tree before this suite existed, with
  ## `l6AttOrderA` as the running definition and `l6AttOrderB` as the
  ## resolving one:
  ##
  ##   fingerprint A        79ee2201efbd5547...
  ##   fingerprint B        b3747a45956add46...
  ##   memberDifferences    0
  ##   outcome              saoAttachWithWarning
  ##   diagnostic           "... Differing members: . Shared-Dev..."
  ##
  ## -- a row-2 warning that named no member, against §4.3's "The warning
  ## names both fingerprints, the project whose definition is running,
  ## and the members that differ."
  ##
  ## WHICH DIRECTION THE FIX WENT, AND WHY NOT THE OTHER. The digest was
  ## NOT canonicalised. Sorting its input would have made these two
  ## fixtures attach SILENTLY, i.e. traded a warning that named nothing
  ## for no warning at all about a change that rebinds a consumer's
  ## positional arguments. The DIFF became position-aware instead
  ## (`smcReordered`), so the two agree on what a difference is.
  ##
  ## HOW TO READ THESE AS BEFORE/AFTER. Every test below FAILS on the
  ## order-insensitive diff -- the first two on `differences.len > 0`,
  ## the third is the control that the fix did not over-report. Measured
  ## in both states; see this milestone's drawer entry.

  test "FIXTURE-DRIFT GUARD: the pair differs ONLY in order":
    # Without this the two tests below could be passing because the
    # fixtures had drifted into a genuine name or signature difference,
    # which an order-INSENSITIVE diff would also have caught. Equal
    # sorted key/signature multisets is exactly "nothing an
    # order-insensitive comparison can see".
    check memberKeySet(snapshotOf("l6AttOrderA")) ==
      memberKeySet(snapshotOf("l6AttOrderB"))
    check memberKeySet(snapshotOf("l6AttParamOrderA")) ==
      memberKeySet(snapshotOf("l6AttParamOrderB"))
    # And the member SEQUENCES really are different, or there would be
    # no reorder to detect.
    check snapshotOf("l6AttOrderA").members !=
      snapshotOf("l6AttOrderB").members
    check snapshotOf("l6AttParamOrderA").members !=
      snapshotOf("l6AttParamOrderB").members

  test "two reordered CONFIG KEYS warn, and both are NAMED":
    # The reviewer's exact input: `first: int = 1` / `second: int = 2`
    # written in the two orders, nothing else changed.
    let running = runningFrom("l6AttOrderA")
    let requested = snapshotOf("l6AttOrderB")
    # The digest still distinguishes them -- the half of the pairing that
    # was never broken, asserted so a future canonicalisation of the
    # digest input reddens here too.
    check running.interfaceSnapshot.fingerprint != requested.fingerprint
    let decision = attachDecision(running, requested)
    checkpoint(decision.diagnostic)
    check decision.outcome == saoAttachWithWarning
    check decision.differences.len == 2
    check changesOfKind(decision, smcReordered) == 2
    for name in ["first", "second"]:
      let diff = differenceNamed(decision, smkConfigKey, name)
      check diff.isSome
      check diff.get.change == smcReordered
      # Same signature on both sides: it is the POSITION that moved, and
      # a `changed` here would be a misreport.
      check diff.get.runningSignature == diff.get.requestedSignature
      check diff.get.runningOrdinal != diff.get.requestedOrdinal
      check diff.get.runningOrdinal >= 0
      check diff.get.requestedOrdinal >= 0
      # §4.3 row 2: the warning NAMES the differing members.
      check decision.diagnostic.contains("`" & name & "`")
    # The two ordinals are each other's, which is what a swap means.
    check differenceNamed(decision, smkConfigKey, "first").get.runningOrdinal ==
      differenceNamed(decision, smkConfigKey, "second").get.requestedOrdinal
    check differenceNamed(decision, smkConfigKey, "second").get.runningOrdinal ==
      differenceNamed(decision, smkConfigKey, "first").get.requestedOrdinal
    # The exact defect, as a direct assertion: the rendered list is not
    # empty. `"Differing members: ."` is the literal text the broken
    # build produced.
    check decision.diagnostic.contains("REORDERED")
    check not decision.diagnostic.contains("Differing members: .")

  test "two reordered ACTIVITY PARAMETERS warn, and both are NAMED":
    # One category up, and the harder version: both parameters are
    # `string`, so the pair is indistinguishable by TYPE. Only the name
    # at each position differs -- precisely what a `(kind, name)`-keyed
    # diff is blind to.
    let running = runningFrom("l6AttParamOrderA")
    let requested = snapshotOf("l6AttParamOrderB")
    check running.interfaceSnapshot.fingerprint != requested.fingerprint
    let decision = attachDecision(running, requested)
    checkpoint(decision.diagnostic)
    check decision.outcome == saoAttachWithWarning
    check decision.differences.len == 2
    check changesOfKind(decision, smcReordered) == 2
    for name in ["pg", "cache"]:
      let diff = differenceNamed(decision, smkActivityParam, name)
      check diff.isSome
      check diff.get.change == smcReordered
      check diff.get.runningSignature == "string"
      check diff.get.requestedSignature == "string"
      check diff.get.runningOrdinal != diff.get.requestedOrdinal
      check decision.diagnostic.contains("`" & name & "`")
    check not decision.diagnostic.contains("Differing members: .")

  test "ANTI-SPRAY: inserting one key at the FRONT is ONE addition":
    # The control on the fix's own failure mode. `l6AttOrderAPlusFront`
    # is side A with `zeroth` inserted BEFORE `first`, so every following
    # member's ABSOLUTE ordinal moves. A position-aware diff that
    # compared absolute ordinals would report the addition plus a reorder
    # for `first` and for `second` -- two moves nobody made, and the
    # author sent to look at keys they did not touch.
    #
    # `memberDifferences` therefore counts positions only among the
    # members BOTH sides carry, where the insertion changes nothing.
    let decision = attachDecision(runningFrom("l6AttOrderA"),
      snapshotOf("l6AttOrderAPlusFront"))
    checkpoint(decision.diagnostic)
    check decision.outcome == saoAttachWithWarning
    check decision.differences.len == 1
    check changesOfKind(decision, smcAdded) == 1
    check changesOfKind(decision, smcReordered) == 0
    check changesOfKind(decision, smcChanged) == 0
    check changesOfKind(decision, smcRemoved) == 0
    let diff = differenceNamed(decision, smkConfigKey, "zeroth")
    check diff.isSome
    check diff.get.change == smcAdded
    # An ordinal is NOT APPLICABLE to an addition and says so, rather
    # than defaulting to 0 and reading as "first".
    check diff.get.runningOrdinal == -1
    check diff.get.requestedOrdinal == -1

  test "ANTI-SPRAY, the mirror: REMOVING the front key is ONE removal":
    let decision = attachDecision(runningFrom("l6AttOrderAPlusFront"),
      snapshotOf("l6AttOrderA"))
    checkpoint(decision.diagnostic)
    check decision.outcome == saoAttachWithWarning
    check decision.differences.len == 1
    check changesOfKind(decision, smcRemoved) == 1
    check changesOfKind(decision, smcReordered) == 0

  test "a SIGNATURE change is reported as changed, never as reordered":
    # `l6AttBase` vs `l6AttChangedKeyType`: `port` is retyped and stays
    # in place. The retype must not be laundered into a reorder, and the
    # neighbours must not be reported as moved -- a changed member still
    # occupies its slot in the shared subsequence.
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttChangedKeyType"))
    checkpoint(decision.diagnostic)
    check changesOfKind(decision, smcReordered) == 0
    let diff = differenceNamed(decision, smkConfigKey, "port")
    check diff.isSome
    check diff.get.change == smcChanged

  test "no reorder is reported between a definition and ITSELF":
    # The vacuity guard, and WHICH ASSERTION CARRIES IT -- corrected
    # after L6's second review measured the original claim. This case
    # used to say that "a diff that reported a reorder for every shared
    # member would pass the two naming tests above and fail here". The
    # first half is true; the second was NOT, and the mutation proves
    # it: `attachDecision` returns at its fingerprint-equal branch
    # WITHOUT calling `memberDifferences`, so a diff mutated to report a
    # reorder for every shared member leaves the `decision` assertions
    # below green (measured: 35 OK / 5 FAILED, and this case is one of
    # the 35). The cases that do catch it are the two naming cases
    # (`differences.len == 2`) and the three `changesOfKind(...,
    # smcReordered) == 0` cases above.
    #
    # So the diff is called DIRECTLY here as well, which is what makes
    # the guard real rather than a consequence of the short-circuit --
    # and the `decision` assertions are kept, because they are what
    # reddens under mutation M2 (warn on every difference), where this
    # case is the control's fourth sibling.
    for pkg in ["l6AttOrderA", "l6AttOrderB", "l6AttParamOrderA",
                "l6AttOrderAPlusFront", "l6AttBase"]:
      checkpoint(pkg)
      let decision = attachDecision(runningFrom(pkg), snapshotOf(pkg))
      check decision.outcome == saoAttachSilently
      check decision.differences.len == 0
      # The diff itself, not routed through the short-circuit.
      check memberDifferences(snapshotOf(pkg), snapshotOf(pkg)).len == 0

# ---------------------------------------------------------------------------
# §4.3 row 3 — refusal.
# ---------------------------------------------------------------------------

suite "L6 §4.3 row 3 — a differing MAJOR refuses":

  test "a different declared major refuses rather than warning":
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttOtherMajor"))
    checkpoint(decision.diagnostic)
    check decision.outcome == saoRefuseMajor
    check decision.runningMajor == 2'u32
    check decision.requestedMajor == 3'u32

  test "the refusal names both majors, both projects and the service":
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttOtherMajor"))
    checkpoint(decision.diagnostic)
    check decision.diagnostic.contains("MAJOR compatibility field is 2")
    check decision.diagnostic.contains("declares 3")
    check decision.diagnostic.contains("l6AttBase")
    check decision.diagnostic.contains("l6AttOtherMajor")
    check decision.diagnostic.contains("zitadel")
    check decision.diagnostic.contains("--replace")

  test "DECLARED vs UNDECLARED is also a major difference":
    # 2 against 0. §4.3 compares the field for equality and does not
    # treat "declared nothing" as compatible with everything -- which
    # would make the undeclared value a wildcard and the refusal
    # unreachable for exactly the recipes that have not been updated.
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttUndeclaredA"))
    checkpoint(decision.diagnostic)
    check decision.outcome == saoRefuseMajor
    check decision.runningMajor == 2'u32
    check decision.requestedMajor == UndeclaredCompatibilityMajor
    # And the refusal says so in words rather than printing a bare `0`,
    # which would send the author looking for a `compatibility 0` they
    # never wrote.
    check decision.diagnostic.contains("declares 0 (it declares none)")

  test "the ORDER is major-first, which is what makes the rows exclusive":
    # What this asserts: the pair's fingerprints DIFFER -- so row 2 is
    # live for it -- and the outcome is nonetheless a refusal. That is
    # row exclusivity: the refusal wins over the warning for a pair that
    # qualifies for both.
    #
    # WHAT IT DOES NOT MEASURE, said rather than left to be assumed.
    # L6's second review measured the order itself and it is NOT
    # falsifiable here, because a changed major ALSO moves the
    # fingerprint (the major is a member of the projection): the
    # fingerprint-equal branch cannot fire on a differing-major pair, so
    # a true swap of `attachDecision`'s two guards is behaviourally inert
    # and leaves this binary at 40 OK / 0 FAILED. What reddens -- section
    # M's M3, five cases -- is a mutation that makes the major branch
    # UNREACHABLE. So this case falsifies "the major check is reached",
    # not "the major check comes first"; see `attachDecision`'s own
    # comment for why the order is kept anyway.
    let running = runningFrom("l6AttBase")
    let requested = snapshotOf("l6AttOtherMajor")
    check running.interfaceSnapshot.fingerprint != requested.fingerprint
    check attachDecision(running, requested).outcome == saoRefuseMajor

  test "a refusal still reports the differing members, for the report":
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttOtherMajor"))
    let diff = differenceNamed(decision, smkSignature, "compatibility")
    check diff.isSome
    check diff.get.runningSignature == "2"
    check diff.get.requestedSignature == "3"

# ---------------------------------------------------------------------------
# The decision is TOTAL and the three outcomes are EXCLUSIVE.
# ---------------------------------------------------------------------------

suite "L6 — exactly one of three, for every pair in the fixture set":

  test "every ordered pair yields exactly one outcome, and the right one":
    # "Reconciling a `stable` service against a running instance yields
    # exactly one of" -- so the function is total and the outcome is a
    # function of the pair. Measured over every ordered pair of the
    # FIFTEEN fixtures rather than the hand-picked ones above: 225
    # pairs, each classified from the snapshots alone, and the decision's
    # answer compared against that independent classification.
    #
    # The five fixtures added by L6's review (`l6AttOrderA` / `B`,
    # `l6AttOrderAPlusFront`, `l6AttParamOrderA` / `B`) are in this set
    # too, so the never-empty check below ranges over every reorder pair
    # the set can form and not only over the two the dedicated suite
    # names.
    const packages = ["l6AttBase", "l6AttOtherImpl", "l6AttAddedKey",
      "l6AttChangedKeyType", "l6AttRequiredKey", "l6AttOtherParamType",
      "l6AttNoSibling", "l6AttOtherMajor", "l6AttUndeclaredA",
      "l6AttUndeclaredB", "l6AttOrderA", "l6AttOrderB",
      "l6AttOrderAPlusFront", "l6AttParamOrderA", "l6AttParamOrderB"]
    var counts: array[ServiceAttachOutcome, int]
    var reorderedSeen = 0
    for runningPkg in packages:
      for requestedPkg in packages:
        let running = runningFrom(runningPkg)
        let requested = snapshotOf(requestedPkg)
        let decision = attachDecision(running, requested)
        let expected =
          if running.interfaceSnapshot.compatibilityMajor !=
              requested.compatibilityMajor: saoRefuseMajor
          elif running.interfaceSnapshot.fingerprint == requested.fingerprint:
            saoAttachSilently
          else: saoAttachWithWarning
        checkpoint(runningPkg & " <- " & requestedPkg)
        check decision.outcome == expected
        # The diagnostic is empty if and only if the attach is silent.
        check (decision.diagnostic.len == 0) ==
          (decision.outcome == saoAttachSilently)
        # THE NEVER-EMPTY PROPERTY, over the whole set rather than over a
        # hand-picked list: every pair the FINGERPRINT distinguishes must
        # yield at least one NAMED member change. This is the assertion
        # that stands in for the unsound injectivity argument the module
        # header used to make; it is a check over 225 pairs, not a proof.
        if decision.outcome == saoAttachWithWarning:
          check decision.differences.len > 0
          for diff in decision.differences:
            check decision.diagnostic.contains(diff.name)
        reorderedSeen += changesOfKind(decision, smcReordered)
        counts[decision.outcome].inc
    # And the set really does exercise a reorder, so the clause above is
    # not vacuous on that kind.
    check reorderedSeen > 0
    # All three outcomes are actually exercised by the set, so the
    # universal claim above is not vacuous on any row.
    check counts[saoAttachSilently] > 0
    check counts[saoAttachWithWarning] > 0
    check counts[saoRefuseMajor] > 0
    check counts[saoAttachSilently] + counts[saoAttachWithWarning] +
      counts[saoRefuseMajor] == packages.len * packages.len

  test "the decision is symmetric in its outcome KIND":
    # Not in its text -- the warning names which side is running. The
    # kind has to be symmetric or "are these two compatible" would depend
    # on which one happened to start first.
    const pairs = [("l6AttBase", "l6AttAddedKey"),
      ("l6AttBase", "l6AttOtherMajor"), ("l6AttBase", "l6AttOtherImpl")]
    for (a, b) in pairs:
      checkpoint(a & " / " & b)
      check attachDecision(runningFrom(a), snapshotOf(b)).outcome ==
        attachDecision(runningFrom(b), snapshotOf(a)).outcome

suite "L6 — a snapshot of a service the lift does not carry is refused":

  test "the error names the services that ARE declared":
    expect ServiceAttachError:
      discard snapshotOf("l6AttBase", "zitadelle")
    var message = ""
    try:
      discard snapshotOf("l6AttBase", "zitadelle")
    except ServiceAttachError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("`zitadel`")
    check message.contains("`bootstrap`")

# ---------------------------------------------------------------------------
# §4.3's second half — `repro up --replace`, on the REAL lease lane.
# ---------------------------------------------------------------------------

const
  Requester = "project:/tmp/l6-requester"
  OtherKeep = "project:/tmp/l6-other-keep"
  OtherDelayed = "project:/tmp/l6-other-delayed"
  OtherImmediate = "project:/tmp/l6-other-immediate"

proc leaseNow(): Time =
  ## Whole seconds, because `ResourceStateRecord` persists a deadline as
  ## a Unix SECOND count -- a sub-second `now` would make a round-tripped
  ## deadline differ from the one that went in and the liveness
  ## comparison would be measuring the codec.
  fromUnix(getTime().toUnix())

suite "L6 — `--replace` refuses while another holder has a live lease":

  test "the holder set comes from real LeasedDeps through deadlineFrom":
    let now = leaseNow()
    let running = runningFrom("l6AttBase")
    let deps = [
      leased(running.address, Requester, keep()),
      leased(running.address, OtherKeep, keep()),
      leased(running.address, OtherDelayed, delayed(minutes = 30)),
      leased(running.address, OtherImmediate, immediate())]
    let holders = holdersFromLeasedDeps(deps, now)
    check holders.len == 4
    # `keep` is a `none` deadline -- `deadlineFrom`'s own answer, and the
    # §2.3 keep-dominates rule -- and it is always live.
    for holder in holders:
      if holder.consumerId == OtherKeep:
        check holder.deadline.isNone
        check holderIsLive(holder, now)
      if holder.consumerId == OtherImmediate:
        # `immediate` is a NOW-deadline, and `reaper.hasLiveHolder`'s
        # comparison is strictly `> now`, so it is lapsed at `now`.
        check holder.deadline == some(now)
        check not holderIsLive(holder, now)
      if holder.consumerId == OtherDelayed:
        check holder.deadline == some(now + initDuration(minutes = 30))
        check holderIsLive(holder, now)

  test "two other live holders REFUSE the replace, and are named":
    let now = leaseNow()
    let base = runningFrom("l6AttBase")
    let deps = [
      leased(base.address, Requester, keep()),
      leased(base.address, OtherKeep, keep()),
      leased(base.address, OtherDelayed, delayed(minutes = 30)),
      leased(base.address, OtherImmediate, immediate())]
    let running = runningServiceInstance(base.key, base.interfaceSnapshot,
      holdersFromLeasedDeps(deps, now))
    let decision = replaceDecision(running, Requester, now)
    checkpoint(decision.diagnostic)
    check decision.outcome == sroRefuseOtherHolders
    check decision.blockingHolders == @[OtherDelayed, OtherKeep]
    check decision.diagnostic.contains(OtherKeep)
    check decision.diagnostic.contains(OtherDelayed)
    check decision.diagnostic.contains("--force")
    check decision.diagnostic.contains("zitadel")

  test "a LAPSED holder is not a blocker, and is reported separately":
    # It must not be silently dropped either: a reader told "two holders"
    # who then finds three names on disk has to be able to tell which is
    # which.
    let now = leaseNow()
    let base = runningFrom("l6AttBase")
    let deps = [
      leased(base.address, Requester, keep()),
      leased(base.address, OtherKeep, keep()),
      leased(base.address, OtherImmediate, immediate())]
    let running = runningServiceInstance(base.key, base.interfaceSnapshot,
      holdersFromLeasedDeps(deps, now))
    let decision = replaceDecision(running, Requester, now)
    check decision.blockingHolders == @[OtherKeep]
    check decision.lapsedHolders == @[OtherImmediate]

  test "the REQUESTER's own live lease never blocks its own replace":
    # The clause is "while OTHER holders have live leases". A project
    # replacing an instance it is itself holding must not be refused by
    # its own lease, which would make `--replace` unusable for the one
    # consumer most likely to want it.
    let now = leaseNow()
    let base = runningFrom("l6AttBase")
    let running = runningServiceInstance(base.key, base.interfaceSnapshot,
      holdersFromLeasedDeps(
        [leased(base.address, Requester, keep())], now))
    let decision = replaceDecision(running, Requester, now)
    check decision.outcome == sroReplace
    check decision.diagnostic == ""
    check decision.blockingHolders.len == 0

  test "no holders at all replaces without a diagnostic":
    let now = leaseNow()
    let decision = replaceDecision(runningFrom("l6AttBase"), Requester, now)
    check decision.outcome == sroReplace
    check decision.diagnostic == ""

  test "`--force` proceeds, and still names what it is overriding":
    let now = leaseNow()
    let base = runningFrom("l6AttBase")
    let deps = [
      leased(base.address, OtherKeep, keep()),
      leased(base.address, OtherDelayed, delayed(minutes = 30))]
    let running = runningServiceInstance(base.key, base.interfaceSnapshot,
      holdersFromLeasedDeps(deps, now))
    let forced = replaceDecision(running, Requester, now, force = true)
    checkpoint(forced.diagnostic)
    check forced.outcome == sroForcedOverOtherHolders
    check forced.blockingHolders == @[OtherDelayed, OtherKeep]
    check forced.diagnostic.contains(OtherKeep)
    check forced.diagnostic.contains(OtherDelayed)
    check forced.diagnostic.contains("--force")
    # The refusal and the forced override name the SAME set in the SAME
    # order, so a developer who read the refusal and then passed
    # `--force` is not told about a different set of holders.
    let refused = replaceDecision(running, Requester, now)
    check refused.blockingHolders == forced.blockingHolders

  test "a holder whose delayed lease has expired no longer blocks":
    let now = leaseNow()
    let base = runningFrom("l6AttBase")
    let deps = [leased(base.address, OtherDelayed, delayed(minutes = 30))]
    let running = runningServiceInstance(base.key, base.interfaceSnapshot,
      holdersFromLeasedDeps(deps, now))
    check replaceDecision(running, Requester, now).outcome ==
      sroRefuseOtherHolders
    check replaceDecision(running, Requester,
      now + initDuration(minutes = 31)).outcome == sroReplace

suite "L6 — the holder set round-trips through a REAL state store":

  test "dated holders survive write -> read and still decide the replace":
    # The lease lane's own machinery end to end: real `LeasedDep`s, the
    # real `mergeHolderDeadlines` that computes the reference-counted
    # effective deadline, a real `StateStore` directory on a real
    # filesystem under a throwaway root, and the decision taken from what
    # came BACK off disk.
    let now = leaseNow()
    let base = runningFrom("l6AttBase")
    let deps = @[
      leased(base.address, Requester, delayed(minutes = 30)),
      leased(base.address, OtherDelayed, delayed(minutes = 30))]
    let merged = mergeHolderDeadlines(initTable[string, Time](), deps, now)
    check not merged.hasKeep
    check merged.effective == some(now + initDuration(minutes = 30))

    let root = getTempDir() / ("repro-l6-store-" & $getCurrentProcessId())
    removeDir(root)
    let store = openStateStore(root)
    defer:
      try: removeDir(root)
      except CatchableError: discard
    writeStateRecord(store, ResourceStateRecord(
      address: base.address, typeId: "l6.service", determinism: rdVolatile,
      identity: base.key.identity, present: true,
      holders: merged.holders, effectiveDeadline: merged.effective,
      lastRenewed: now))

    let record = readStateRecord(store, base.address)
    let back = holdersFromStateRecord(record)
    check back.holders.len == 2
    check back.holders[0].consumerId == OtherDelayed
    check back.holders[1].consumerId == Requester
    check back.holders[0].deadline == some(now + initDuration(minutes = 30))
    # A record with a DATED effective deadline names every holder it has,
    # so nothing can be unnamed -- which is the half of the flag that is
    # exact.
    check not back.mayHaveUnnamedKeepHolder

    let running = runningServiceInstance(base.key, base.interfaceSnapshot,
      back.holders)
    let decision = replaceDecision(running, Requester, now)
    check decision.outcome == sroRefuseOtherHolders
    check decision.blockingHolders == @[OtherDelayed]

  test "a KEEP holder is pinned but UNNAMED on disk, and that is reported":
    # `mergeHolderDeadlines` deliberately `del`s a keep holder from
    # `holders` -- "it pins with no expiry ... rather than storing a
    # bogus deadline" -- and records only `effectiveDeadline = none`. So
    # a persisted record alone CANNOT name a keep holder, and D-SS5
    # expects a `stable`, state-owning service to default to `keep`.
    #
    # `holdersFromStateRecord` reports that rather than guessing a name,
    # and this case is the evidence for the finding L6 hands to L7:
    # naming a blocking holder needs the holder set the registry will
    # hold, or a keep-holder list in the record. The flag is deliberately
    # "MAY have": `effectiveDeadline == none` is also what a record with
    # no holders at all carries, and nothing in the record separates the
    # two -- which the next case pins so the weaker claim cannot quietly
    # be strengthened.
    let now = leaseNow()
    let base = runningFrom("l6AttBase")
    let deps = @[leased(base.address, OtherKeep, keep())]
    let merged = mergeHolderDeadlines(initTable[string, Time](), deps, now)
    check merged.hasKeep
    check merged.effective.isNone
    check merged.holders.len == 0          # the keep holder's NAME is gone

    let root = getTempDir() / ("repro-l6-keep-" & $getCurrentProcessId())
    removeDir(root)
    let store = openStateStore(root)
    defer:
      try: removeDir(root)
      except CatchableError: discard
    writeStateRecord(store, ResourceStateRecord(
      address: base.address, typeId: "l6.service", determinism: rdVolatile,
      identity: base.key.identity, present: true,
      holders: merged.holders, effectiveDeadline: merged.effective,
      lastRenewed: now))

    let back = holdersFromStateRecord(readStateRecord(store, base.address))
    check back.holders.len == 0
    check back.mayHaveUnnamedKeepHolder
    # And the consequence, stated as an assertion rather than a comment:
    # a replace decided from the RECORD alone would proceed, while the
    # same decision taken from the LeasedDep set refuses. L7 is what
    # closes that, by holding the holder set.
    let fromRecord = runningServiceInstance(base.key, base.interfaceSnapshot,
      back.holders)
    check replaceDecision(fromRecord, Requester, now).outcome == sroReplace
    let fromLeases = runningServiceInstance(base.key, base.interfaceSnapshot,
      holdersFromLeasedDeps(deps, now))
    check replaceDecision(fromLeases, Requester, now).outcome ==
      sroRefuseOtherHolders

  test "an EMPTY record flags the same way, which is why it says MAY":
    # The imprecision, pinned. A record with no holders and no dated
    # deadline is indistinguishable from one pinned by an unnamed `keep`
    # holder, so the flag cannot be read as "there is a keep holder" --
    # and a `--replace` must not refuse on it alone, which the assertion
    # below states.
    let now = leaseNow()
    let base = runningFrom("l6AttBase")
    let root = getTempDir() / ("repro-l6-empty-" & $getCurrentProcessId())
    removeDir(root)
    let store = openStateStore(root)
    defer:
      try: removeDir(root)
      except CatchableError: discard
    writeStateRecord(store, ResourceStateRecord(
      address: base.address, typeId: "l6.service", determinism: rdVolatile,
      identity: base.key.identity, present: true,
      holders: initTable[string, Time](), effectiveDeadline: none(Time),
      lastRenewed: now))
    let back = holdersFromStateRecord(readStateRecord(store, base.address))
    check back.holders.len == 0
    check back.mayHaveUnnamedKeepHolder     # same flag, no keep holder
    check replaceDecision(runningServiceInstance(base.key,
      base.interfaceSnapshot, back.holders), Requester, now).outcome ==
      sroReplace

suite "L6 — the record's address is the lease address, not a new string":

  test "the running record reports `serviceInstanceAddress` of its key":
    let running = runningFrom("l6AttBase")
    check running.address == serviceInstanceAddress(running.key)
    check running.address.startsWith("service:workspace:")
    check running.key.identity == "com.example.l6.sso"
    check running.key.environment == "dev"
    # And the scope was not DEGRADED, so the address above is the
    # workspace-scoped one the fixtures declare rather than a quietly
    # narrowed project-scoped one.
    check running.key.scope == sscWorkspace
    check degradationReport(running.key) == ""

suite "L6 — the projected key agrees with a real LOWERED record":

  test "same declaration, same key -- the projection is falsifiable":
    # `declaredDefFromLift` projects the lifted row into the shape
    # `serviceInstanceKey` takes, because an activity-declared service's
    # `DslServiceDef` is not registered until the activity is enabled.
    # `l6AttKeySource` declares a PACKAGE-LEVEL service with the same
    # `identity` and `scope`, so its record IS registered at module init
    # and the two keys must agree. If the projection ever mapped an enum
    # wrongly this goes red.
    var lowered: DslServiceDef
    var found = false
    for svc in registeredServices("l6AttKeySource"):
      if svc.serviceName == "zitadel":
        lowered = svc
        found = true
    check found
    # The lowered record carries the implementation, which is what makes
    # it a different thing from the projection rather than a copy of it.
    check lowered.args == @["--serve"]
    let ctx = scopeContext("l6AttKeySource")
    let projected = declaredDefFromLift("l6AttKeySource", "zitadel")
    check projected.identity == lowered.identity
    check projected.scope == lowered.scope
    check serviceInstanceKey(projected, ctx, [], "dev") ==
      serviceInstanceKey(lowered, ctx, [], "dev")
    check serviceInstanceAddress(serviceInstanceKey(lowered, ctx, [], "dev")) ==
      serviceInstanceAddress(serviceInstanceKey(projected, ctx, [], "dev"))
