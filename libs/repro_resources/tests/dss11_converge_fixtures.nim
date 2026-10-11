## Shared-Development-Services D-SS11 (§4.6) test fixture: the two
## producer definitions that make the CONVERGE RESPONSE's contribution
## points independently sourced on the two sides of the comparison.
##
## WHY THIS FIXTURE EXISTS, said plainly, because it is the whole reason
## the cases that use it discriminate. `applyServiceConverge` answers
## with the RUNNING INSTANCE's declared points when an instance was
## present, and with the REQUEST's otherwise. The existing skew fixture
## could not measure that branch: there, the consumer's request snapshot
## is itself derived from the owner's stale artifact, so both arms of the
## `if` carry the SAME one-point set and the comparison agrees
## vacuously. A review mutation that collapsed the branch to the
## request's snapshot left every test green.
##
## So the pair below is built the other way round: two SEPARATE package
## definitions, each lifted by the real DSL macro, declaring DIFFERENT
## contribution point sets. The registry entry is materialised from one
## and the converge request carries the other, so reading the wrong one
## changes the answer and the branch is proven rather than described.
##
## THEY DIFFER IN EXACTLY ONE DECLARED WAY, which is the discipline
## `l6_attach_fixtures.nim` states and follows: a pair that differs in
## two ways cannot say which difference the code reacted to. BOTH
## packages declare BOTH `config:` keys; only the `converge` list
## differs. Declaring the second key in only the newer one would have
## been the obvious spelling and is wrong here -- it would differ in two
## ways (a key and a point), and a response that echoed the key set
## rather than the converge list would pass.
##
## AND THEY STILL ATTACH RATHER THAN REFUSE, which the cases depend on:
## both declare `compatibility 1`, so §4.3's major row does not fire and
## the decision is an attach with `hadInstance` true. A differing
## contribution-point member makes it the WARNING row, which is correct
## and is asserted at the call sites.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## These are real `package` blocks expanded by the real DSL macro; the
## snapshots the tests compare are taken from the real
## `toProjectInterface` lift of these packages, and nothing about a
## service's interface is hand-written.
##
## Lives in a separate module from the test main for the reason
## `l6_attach_fixtures.nim` gives: under `-d:reproProviderMode` the
## `package` macro emits a `runPackageProvider` shim guarded on
## `isMainModule`, which would take over the test binary. Not named
## `t_*` / `test_*`, so `scripts/generate_test_edges.nim` does not
## register it as a test binary of its own.

import repro_project_dsl

package dss11CvOne:
  ## The OLDER definition: converges ONE of the two declared points.
  ## This is what the running instance is materialised from.
  devEnv:
    activity sso():
      config:
        relyingParties: seq[string] = @["owner"]
        fixtureUsers: seq[string] = @["dev@example.test"]

      service zitadel:
        args "start-from-init"
        identity stable "com.example.dss11cv.sso"
        scope workspace
        compatibility 1
        converge relyingParties

package dss11CvBoth:
  ## The NEWER definition: identical in every declared way except that
  ## it converges BOTH points. This is what the consumer's converge
  ## request carries.
  devEnv:
    activity sso():
      config:
        relyingParties: seq[string] = @["owner"]
        fixtureUsers: seq[string] = @["dev@example.test"]

      service zitadel:
        args "start-from-init"
        identity stable "com.example.dss11cv.sso"
        scope workspace
        compatibility 1
        converge relyingParties, fixtureUsers

package dss11CvNone:
  ## The definition that converges NOTHING, and it is a REAL definition
  ## rather than a snapshot with its members removed by hand.
  ##
  ## Written because the first draft of the "request declares no points"
  ## case built that request by stripping the `smkContributionPoint`
  ## members out of a lifted snapshot -- which produces a value the lift
  ## cannot: `ServiceInterfaceSnapshot.fingerprint` is a CARRIED field
  ## taken over `members`, and the codec carries the two independently,
  ## so the stripped snapshot had the full set's digest attached to a
  ## shorter member list. Measured consequence: the attach decision
  ## compared the two fingerprints, found them equal and returned
  ## `AttachSilently` with an EMPTY diagnostic, so the case was not
  ## exercising the version-skew shape it claimed to. Declaring the
  ## definition for real keeps the snapshot self-consistent and makes
  ## the decision the warning it should be.
  ##
  ## It still differs from `dss11CvBoth` in exactly one declared way:
  ## both `config:` keys are present, and only the `converge` list
  ## differs -- here by being absent altogether.
  devEnv:
    activity sso():
      config:
        relyingParties: seq[string] = @["owner"]
        fixtureUsers: seq[string] = @["dev@example.test"]

      service zitadel:
        args "start-from-init"
        identity stable "com.example.dss11cv.sso"
        scope workspace
        compatibility 1
