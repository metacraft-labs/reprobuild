## Shared-Development-Services **L9 F5** — THE SESSION'S MINTED RECORD IS
## MERGED INTO, NOT OVERWRITTEN, AND THE AMBIGUITY RULE SURVIVES THE MERGE.
##
## § WHY A MERGE EXISTS AT ALL
##
## `repro up` writes this session's minted rows twice over, from two places
## that run in a fixed order inside one process:
##
##   1. `convergeSharedServiceInstances` converges the shared services THIS
##      project declares and writes their rows at its foot;
##   2. `resolveSharedServiceReferences` then runs every
##      `<package>.<service>.shared(...)` the recipe wrote and reads what
##      THOSE instances minted out of their own identity-keyed registration
##      records — L9 F5's cross-session read.
##
## A project can do both: declare one shared service and resolve another's. So
## step 2 cannot WRITE, or it discards what step 1 converged a moment earlier;
## and it cannot write a SECOND FILE, because `substituteMintedAttributes`
## takes ONE table and the file that happened to be read first would silently
## win a member both held. One document, one reader, one ambiguity rule.
##
## § THE FIVE THINGS THAT COULD GO WRONG, EACH A CASE
##
##   1. THE MERGE DISCARDS WHAT WAS THERE. The converge's own rows survive a
##      resolver's merge.
##   2. THE MERGE DUPLICATES A KEY instead of replacing it. A repeated
##      `(serviceName, member)` must REPLACE: appending would leave two rows
##      whose values the fold then has to choose between, and the fold DELETES
##      a bare member two rows disagree about — so an append would turn a
##      re-resolution into a refusal.
##   3. THE STAMP IS LOST IN THE MERGE. §7.2's whole guarantee across the
##      crossing. Asserted on the merged rows and again through the real
##      `substituteMintedAttributes`.
##   4. THE AMBIGUITY RULE IS LOST. Two different instances minting a member
##      of the SAME name must make the bare key unresolvable, so the
##      substitution REFUSES rather than picking one. That rule predates this
##      change and the merge must not weaken it.
##   5. ACCUMULATION IS ORDER-DEPENDENT. The resolver accumulates across every
##      resolution and merges once; two successive merges must hold both
##      batches, or a consumer that resolves two services loses one.
##
## § MOCKS: NONE
##
## No test double, stub, fake or monkey-patch. Every case writes the real file
## with the real `writeSharedInstanceMinted` / `mergeSharedInstanceMinted`
## into a real temporary session directory on the real filesystem, reads it
## back with the real `readSharedInstanceMintedRows` /
## `readSharedInstanceMintedAttributes`, and asks the real
## `substituteMintedAttributes` what a consuming service's argv would receive.
## Nothing here reimplements the merge or the fold.

import std/[json, os, strutils, tables, tempfiles, unittest]

import repro_cli_support/dev_session
import repro_resources/readiness_edge   # §7.2's provenance vocabulary

const
  Shared = "idp"
  Other = "otherIdp"
  Consumer = "apiServer"
  MemberA = "https://a.example.test:8443/callback"
  MemberB = "https://b.example.test:8443/callback"
  IssuerId = "394610871109772528"
  DevId = "656520947787f86a22aa9f39"

proc outDirFor(name: string): string =
  ## A fresh `outDir`, which is what every surface here is keyed on. The
  ## session subdirectory is created by the writer, not by this proc: that
  ## `createDir` is part of what is under test.
  createTempDir("repro-f5-merge-" & name & "-", "")

proc rowsOf(outDir: string): JsonNode =
  let path = outDir.sharedInstanceMintedPath
  if not fileExists(path):
    return newJArray()
  let rows = parseJson(readFile(path)){"registrations"}
  if rows.isNil: newJArray() else: rows

suite "L9 F5 — the session's minted record merges without losing rows":
  test "a merge into an empty session writes the rows it was given":
    let outDir = outDirFor("empty")
    defer:
      try: removeDir(outDir) except OSError, IOError: discard
    # Nothing has been written: this is the PURE CONSUMER shape, whose file
    # `convergeSharedServiceInstances` removes on every `repro up` because it
    # declares no shared service of its own.
    check readSharedInstanceMintedRows(outDir).len == 0
    mergeSharedInstanceMinted(outDir, @[(serviceName: Shared,
      member: MemberA, mintedId: IssuerId, provenance: rprIssuer)])
    let rows = readSharedInstanceMintedRows(outDir)
    check rows.len == 1
    check rows[0].serviceName == Shared
    check rows[0].member == MemberA
    check rows[0].mintedId == IssuerId
    check rows[0].provenance == rprIssuer
    # And it is a well-formed document of the declared schema, not an ad-hoc
    # append: the file the supervisor reads has one reader and one shape.
    check parseJson(readFile(outDir.sharedInstanceMintedPath)){
      "schemaId"}.getStr("") == SharedInstanceMintedSchemaId

  test "the converge's OWN rows survive the resolver's merge":
    # THE CASE THE MERGE EXISTS FOR. A project that both declares a shared
    # service and resolves another's: a plain write here would discard what
    # the converge produced in the same process a moment earlier.
    let outDir = outDirFor("both")
    defer:
      try: removeDir(outDir) except OSError, IOError: discard
    writeSharedInstanceMinted(outDir, @[(serviceName: Shared,
      member: MemberA, mintedId: DevId, provenance: rprDevelopment)])
    mergeSharedInstanceMinted(outDir, @[(serviceName: Other,
      member: MemberB, mintedId: IssuerId, provenance: rprIssuer)])
    let rows = readSharedInstanceMintedRows(outDir)
    check rows.len == 2
    var seenA, seenB = false
    for row in rows:
      if row.serviceName == Shared and row.member == MemberA:
        seenA = true
        check row.mintedId == DevId
        check row.provenance == rprDevelopment
      if row.serviceName == Other and row.member == MemberB:
        seenB = true
        check row.mintedId == IssuerId
        check row.provenance == rprIssuer
    check seenA
    check seenB

  test "a repeated (service, member) is REPLACED and not appended":
    let outDir = outDirFor("replace")
    defer:
      try: removeDir(outDir) except OSError, IOError: discard
    mergeSharedInstanceMinted(outDir, @[(serviceName: Shared,
      member: MemberA, mintedId: DevId, provenance: rprDevelopment)])
    mergeSharedInstanceMinted(outDir, @[(serviceName: Shared,
      member: MemberA, mintedId: IssuerId, provenance: rprIssuer)])
    let rows = readSharedInstanceMintedRows(outDir)
    check rows.len == 1
    check rows[0].mintedId == IssuerId
    check rows[0].provenance == rprIssuer
    # AND THE FOLD STILL RESOLVES IT. This is why replace rather than append:
    # two rows for one member disagree, and the fold DELETES a bare key it
    # cannot decide — so an append would turn a second read of the same
    # instance into a refusal.
    let table = readSharedInstanceMintedAttributes(outDir)
    check table.hasKey(MemberA)
    check table[MemberA].value == IssuerId
    check substituteMintedAttributes(Consumer,
      @["--client-id", IssuerMintedAttributeTokenPrefix & MemberA &
        MintedAttributeTokenSuffix], table) == @["--client-id", IssuerId]

  test "the §7.2 stamp survives the merge, all the way to the argv decision":
    let outDir = outDirFor("stamp")
    defer:
      try: removeDir(outDir) except OSError, IOError: discard
    mergeSharedInstanceMinted(outDir, @[(serviceName: Shared,
      member: MemberA, mintedId: DevId, provenance: rprDevelopment)])
    let table = readSharedInstanceMintedAttributes(outDir)
    check table[MemberA].provenance == rprDevelopment
    # `@minted:` takes whichever registrar produced it — §7.2 keeps the
    # offline path working.
    check substituteMintedAttributes(Consumer,
      @[MintedAttributeTokenPrefix & MemberA & MintedAttributeTokenSuffix],
      table) == @[DevId]
    # `@issuer-minted:` REFUSES, and names the provenance it found. A merge
    # that dropped the stamp would still refuse — as `unstamped` — which is
    # why the message is asserted and not merely the raise.
    var refusal = ""
    try:
      discard substituteMintedAttributes(Consumer,
        @[IssuerMintedAttributeTokenPrefix & MemberA &
          MintedAttributeTokenSuffix], table)
    except ValueError as err:
      refusal = err.msg
    check refusal.contains("carries provenance `" & $rprDevelopment & "`")
    check refusal.contains("DEVELOPMENT identifier")
    check not refusal.contains(DevId)   # the digest is refused, not delivered

  test "two instances minting the same member name stay unresolvable":
    # THE AMBIGUITY RULE, which predates this change and must not be
    # weakened by it: a bare member two services disagree about resolves to
    # nothing, so the substitution REFUSES rather than picking one. That is
    # the only safe answer — the consumer named a member, not a service.
    let outDir = outDirFor("ambiguous")
    defer:
      try: removeDir(outDir) except OSError, IOError: discard
    mergeSharedInstanceMinted(outDir, @[
      (serviceName: Shared, member: MemberA, mintedId: IssuerId,
       provenance: rprIssuer),
      (serviceName: Other, member: MemberA, mintedId: DevId,
       provenance: rprDevelopment)])
    check readSharedInstanceMintedRows(outDir).len == 2
    let table = readSharedInstanceMintedAttributes(outDir)
    check not table.hasKey(MemberA)
    # Both QUALIFIED keys are still there, so an author who knows which
    # service they mean can still address it.
    check table[Shared & ":" & MemberA].value == IssuerId
    check table[Other & ":" & MemberA].value == DevId
    var refusal = ""
    try:
      discard substituteMintedAttributes(Consumer,
        @[MintedAttributeTokenPrefix & MemberA & MintedAttributeTokenSuffix],
        table)
    except ValueError as err:
      refusal = err.msg
    check refusal.contains("IS NOT COMPUTED")
    check refusal.len > 0

  test "accumulating across resolutions keeps every batch":
    # The resolver accumulates across EVERY resolution and merges once below
    # its loop. A consumer that resolves two shared services must end up with
    # both, and the order the batches arrive in must not matter.
    let a = outDirFor("acc-a")
    let b = outDirFor("acc-b")
    defer:
      for d in [a, b]:
        try: removeDir(d) except OSError, IOError: discard
    let first = (serviceName: Shared, member: MemberA, mintedId: IssuerId,
      provenance: rprIssuer)
    let second = (serviceName: Other, member: MemberB, mintedId: DevId,
      provenance: rprDevelopment)
    # One merge of two rows, and two merges of one row each, must agree.
    mergeSharedInstanceMinted(a, @[first, second])
    mergeSharedInstanceMinted(b, @[second])
    mergeSharedInstanceMinted(b, @[first])
    let ta = readSharedInstanceMintedAttributes(a)
    let tb = readSharedInstanceMintedAttributes(b)
    check ta.len == tb.len
    check ta[MemberA] == tb[MemberA]
    check ta[MemberB] == tb[MemberB]
    check ta[MemberA].provenance == rprIssuer
    check ta[MemberB].provenance == rprDevelopment

  test "the row reader and the attribute reader are ONE parse":
    # `readSharedInstanceMintedAttributes` is folded from
    # `readSharedInstanceMintedRows`, and `readSharedInstanceMinted` drops
    # the stamp from that. Two readings of one document are two things that
    # can disagree, and the disagreement that matters here — one reader
    # seeing a stamp and the other not — is §7.2's whole defect. So every
    # row the row reader sees is reachable through both of the others.
    let outDir = outDirFor("one-parse")
    defer:
      try: removeDir(outDir) except OSError, IOError: discard
    mergeSharedInstanceMinted(outDir, @[
      (serviceName: Shared, member: MemberA, mintedId: IssuerId,
       provenance: rprIssuer),
      (serviceName: Other, member: MemberB, mintedId: DevId,
       provenance: rprDevelopment)])
    let rows = readSharedInstanceMintedRows(outDir)
    let stamped = readSharedInstanceMintedAttributes(outDir)
    let blind = readSharedInstanceMinted(outDir)
    check rows.len == 2
    check stamped.len == blind.len
    for row in rows:
      let qualified = row.serviceName & ":" & row.member
      check stamped[qualified].value == row.mintedId
      check stamped[qualified].provenance == row.provenance
      check blind[qualified] == row.mintedId
    # And the document on disk is what the rows say it is.
    check rowsOf(outDir).len == 2
