## ReproOS-Remix-Product-Experience M0 verification
## ``verify_remix_experience_journey_and_state_coverage``.
##
## "Every protocol and trust state maps to an actionable user journey and
## no install-affecting state lacks a visible representation."
##
## The four parts of the coverage rule in
## `reprobuild-pm/spec/Remix-Experience-Journeys.md` §"Coverage rule",
## checked against the shared state module every surface renders from.
## Exhaustiveness of the vocabulary mappings is also enforced at compile
## time by their `case` statements; this test checks what they return.

import std/[sets, unittest]

import repro_remix

suite "Remix Product Experience M0 — journey and state coverage":

  test "1. every visible state occurs in the fixture dataset":
    var seen = initHashSet[VisibleState]()
    for (_, v) in fixtureViews():
      for s in deriveStates(v): seen.incl s
    for s in withStalePolicy(deriveStates(ReleaseView())): seen.incl s
    for s in VisibleState:
      checkpoint $s
      check s in seen

  test "2. every record kind, statement kind, refusal and conflict class maps somewhere":
    for k in RecordKind:
      discard decisionForRecordKind(k)
    var stateful = 0
    for k in StatementKind:
      let (has, _) = stateForStatement(Statement(kind: k, subjectKind: sbRelease,
        scope: @["block"]))
      if has: inc stateful
    check stateful >= 7
    for r in RemixRefusal:
      let s = stateForRefusal(r)
      checkpoint $r
      # Every refusal reaches the user as a state that removes the install
      # affordance; none is silently allowed.
      check not isInstallable([s])
    for c in ConflictClass:
      check decisionForConflict(c) in {dConflictAcknowledgement, dCapabilityGrant}

  test "3. every state that gates installation explains itself":
    for s in VisibleState:
      let i = info(s)
      checkpoint $s
      check i.explanation.len > 10
      if i.gate notin {gAllow, gAllowWithWarning, gAllowWithAcknowledgement, gPerVerdict,
                       gRefuseIfGating}:
        check not isInstallable([s])

  test "4. blocking states dominate and are never rendered alone by colour":
    for (name, v) in fixtureViews():
      let states = deriveStates(v)
      checkpoint name
      check states.len > 0
      for s in states:
        check explanation(s).len > 0           # text exists for every state
      if vsBlocked in states or vsRevoked in states or vsUnverifiable in states:
        check states[0] in {vsBlocked, vsRevoked, vsUnverifiable}
        check not isInstallable(states)
