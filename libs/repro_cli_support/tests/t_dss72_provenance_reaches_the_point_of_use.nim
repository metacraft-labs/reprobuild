## Shared-Development-Services **§7.2** — THE PROVENANCE OF A MINTED
## IDENTIFIER REACHES THE POINT OF USE, AND A CONSUMER THAT NEEDS THE
## ISSUER'S REFUSES A DEVELOPMENT ONE **BY ASKING**.
##
## §7.2's defect is located precisely: the development registrar's id is
## "**indistinguishable, at the point of use**, from an id a real issuer
## minted". The point of use, in the lane that exists, is argv
## concretization — `substituteMintedAttributes` turning
## `@minted:<member>@` into the identifier the instance minted — so this file
## tests the question being asked *there*, on the other side of a real file
## written by `repro up` and read back by the supervisor.
##
## § WHY THE ROUND TRIP THROUGH THE FILE IS THE TEST
##
## Between the registrar and a consuming service's argv there is exactly one
## hop: `session/shared-instance-registrations.json`. A stamp that exists in
## memory and is dropped by that hop leaves the consumer in precisely §7.2's
## position, and nothing upstream would notice. The provenance and registry
## cases therefore write with the real
## `writeSharedInstanceMinted`, read with the real
## `readSharedInstanceMintedAttributes`, and only then substitute. The
## caller-supplied-table compatibility case separately exercises the public
## overloads whose callers have no registration metadata.
##
## § THE IDENTIFIER TEXT IS THE SAME FOR BOTH PROVENANCES, DELIBERATELY
##
## A development row and an issuer row carry byte-identical `mintedId` text
## in these cases. §7.2 forbids a naming convention ("a fact carried with the
## value"), and a test that could tell the two apart by reading the string
## would be asserting the convention rather than the fact. With the text
## identical, the only thing that can answer the question is the stamp.
##
## § WHAT ELSE IS PROBED HERE, AND WHY EACH WAS A NEAR-MISS
##
##   * **The token spellings do not overlap.** `@issuer-minted:` does not
##     contain `@minted:` (the character before `minted:` is `-`), which is
##     what lets one substring test catch an embedded token of either family
##     without confusing them. A rename to `@minted-by-issuer:` would make
##     every such token look like an embedded `@minted:` and be refused for
##     the wrong reason, so the non-containment is asserted rather than
##     assumed.
##   * **The embedded-token refusal covers BOTH prefixes.** Testing only the
##     shorter one would let `--client-id=@issuer-minted:x@` through as
##     literal text — a service launched with the token itself as its
##     credential, which is the silent form of that refusal.
##   * **The provenance-blind reader and the stamped reader see the same
##     rows.** The blind one is derived from the stamped one rather than
##     parsing the file again, because two readings of one document are two
##     things that can disagree, and the disagreement that matters here is
##     one reader seeing a stamp and the other not.
##   * **A row whose provenance word this build cannot read is `unstamped`,
##     not `issuer`.** The one answer it must not reach for is the issuer's.
##   * **Two services disagreeing about a member's PROVENANCE collapse the
##     bare key**, exactly as two disagreeing about its id already did. A
##     bare `@minted:member@` then refuses rather than picking one.
##   * **Registered member names survive their URI punctuation.** The
##     missing-member refusal lists the names written to the real record,
##     sorted and without duplicate service-qualified aliases. Direct-table
##     cases also exercise the public compatibility overloads; their keys
##     are caller-supplied names, not a second registration source.
##
## § MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
##
## The cases exercise the real `writeSharedInstanceMinted`, the real
## `readSharedInstanceMintedAttributes`, the real
## `substituteMintedAttributes` and the real `serviceSpecFromSummary` over a
## real directory on the real filesystem where persistence is involved.
## `RegistrarProvenance` is the
## production enum from `repro_resources/readiness_edge.nim` — the same one
## the resource lane stamps with, so this file cannot be measuring a second
## vocabulary.

import std/[os, strutils, tables, unittest]

import cbor                             # cborText, for the empty `metadata`
import repro_dev_env_artifacts          # DevEnvServiceSummary
import repro_cli_support/dev_session
import repro_resources/readiness_edge

const
  Svc = "sso"
  OtherSvc = "idp"
  Member = "isonim-site"
  Token = MintedAttributeTokenPrefix & Member & MintedAttributeTokenSuffix
  IssuerToken = IssuerMintedAttributeTokenPrefix & Member &
    MintedAttributeTokenSuffix
  SharedIdText = "394610871109772528"
    ## ONE text for both provenances. See the header.
  Sentinel = "\u0001SENTINEL-NOT-OVERWRITTEN"
  ProjectRoot = "/nonexistent/dss72/project"
    ## Never touched on disk: `serviceSpecFromSummary` only joins paths
    ## with it, and the cases here read the resolved argv.

proc scratchOut(tag: string): string =
  let root = getTempDir() / ("dss72-argv-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  root

proc writeOneRow(outDir: string; provenance: RegistrarProvenance;
                 service = Svc; member = Member; id = SharedIdText) =
  writeSharedInstanceMinted(outDir, @[(serviceName: service,
    member: member, mintedId: id, provenance: provenance)])

proc substituted(outDir: string; command: seq[string];
                 service = Svc): seq[string] =
  substituteMintedAttributes(service, command,
    readSharedInstanceMintedAttributes(outDir))

proc tokenService(command: seq[string]): DevEnvServiceSummary =
  ## A typed-only service whose argv carries a minted token — the shape
  ## §7's worked example writes, and the one `serviceSpecFromSummary`
  ## concretizes.
  DevEnvServiceSummary(
    name: Svc,
    activityRequirements: @[Svc],
    metadata: cborText(""),
    typedCommand: command,
    workingDirectory: ".")

suite "§7.2 — the stamp survives the one hop to the point of use":

  test "an unknown member refusal lists registered URI-bearing members":
    let outDir = scratchOut("registered-uris")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    const uriMember = "isonim-site|OIDC_APP_TYPE_WEB|" &
      "https://app.isonim.test:8443/oidc/callback|https://app.isonim.test:8443/"
    const otherMember = "blocktracer|https://blocktracer.test:8443/callback"
    writeSharedInstanceMinted(outDir, @[
      (serviceName: Svc, member: uriMember, mintedId: SharedIdText,
       provenance: rprIssuer),
      (serviceName: OtherSvc, member: otherMember, mintedId: "b-1",
       provenance: rprIssuer),
      (serviceName: OtherSvc, member: uriMember, mintedId: SharedIdText,
       provenance: rprIssuer)])
    # Prove that registration and resolution work before asking about a typo.
    check substituted(outDir, @[IssuerMintedAttributeTokenPrefix &
      uriMember & MintedAttributeTokenSuffix]) == @[SharedIdText]
    for prefix in [MintedAttributeTokenPrefix, IssuerMintedAttributeTokenPrefix]:
      var message = ""
      var answered = @[Sentinel]
      let misspelled = uriMember.replace(":8443/", ":8444/")
      try:
        answered = substituted(outDir, @[prefix & misspelled &
          MintedAttributeTokenSuffix])
      except ValueError as err:
        message = err.msg
      checkpoint(message)
      check answered == @[Sentinel]
      check message.contains("IS NOT COMPUTED")
      check message.contains(misspelled)
      check message.contains("Registered members: " & otherMember & ", " &
        uriMember & ". Leaving the token")
      check not message.contains("Registered members: (none)")
    mergeSharedInstanceMinted(outDir, @[
      (serviceName: Svc, member: "plain-member", mintedId: "p-1",
       provenance: rprIssuer)])
    var mixedMessage = ""
    try:
      discard substituted(outDir, @[IssuerToken])
    except ValueError as err:
      mixedMessage = err.msg
    check mixedMessage.contains("Registered members: " & otherMember & ", " &
      uriMember & ", plain-member. Leaving the token")

  test "an empty registry reports no registered members":
    let outDir = scratchOut("registered-empty")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    var message = ""
    try:
      discard substituted(outDir, @[IssuerToken])
    except ValueError as err:
      message = err.msg
    check message.contains("Registered members: (none).")

  test "caller supplied tables retain colon-bearing member names":
    const member = "https://manual.test:8443/callback"
    var stamped = initTable[string, MintedAttribute]()
    stamped[member] = MintedAttribute(value: SharedIdText,
      provenance: rprIssuer)
    var blind = initTable[string, string]()
    blind[member] = SharedIdText
    check substituteMintedAttributes(Svc, @[IssuerMintedAttributeTokenPrefix &
      member & MintedAttributeTokenSuffix], stamped) == @[SharedIdText]
    check substituteMintedAttributes(Svc, @[MintedAttributeTokenPrefix &
      member & MintedAttributeTokenSuffix], blind) == @[SharedIdText]
    var stampedMessage, blindMessage: string
    try:
      discard substituteMintedAttributes(Svc, @[Token], stamped)
    except ValueError as err:
      stampedMessage = err.msg
    try:
      discard substituteMintedAttributes(Svc, @[Token], blind)
    except ValueError as err:
      blindMessage = err.msg
    check stampedMessage.contains("Registered members: " & member & ".")
    check blindMessage.contains("Registered members: " & member & ".")

  test "a development row resolves through `@minted:` and is MARKED":
    let outDir = scratchOut("devrow")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeOneRow(outDir, rprDevelopment)
    let table = readSharedInstanceMintedAttributes(outDir)
    # The fact arrived. Asked, not inferred from the text.
    check table[Member].provenance == rprDevelopment
    check table[Member].value == SharedIdText
    check table[Svc & ":" & Member].provenance == rprDevelopment
    # The offline path still works, which is §7.2's fourth bullet.
    check substituted(outDir, @["--client-id", Token]) ==
      @["--client-id", SharedIdText]

  test "an issuer row resolves through `@issuer-minted:`, same id text":
    let outDir = scratchOut("issuerrow")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeOneRow(outDir, rprIssuer)
    check readSharedInstanceMintedAttributes(outDir)[Member].provenance ==
      rprIssuer
    check substituted(outDir, @["--client-id", IssuerToken]) ==
      @["--client-id", SharedIdText]
    # ...and the permissive token takes it too: requiring the issuer's is
    # the consumer's choice, not a restriction on what it may receive.
    check substituted(outDir, @[Token]) == @[SharedIdText]

  test "a DEVELOPMENT row is REFUSED for `@issuer-minted:`, by name":
    # THE CLAUSE. Same identifier text as the issuer case above, so the
    # only thing that can distinguish them is the stamp.
    let outDir = scratchOut("devrefuse")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeOneRow(outDir, rprDevelopment)
    var message = ""
    var answered = @[Sentinel]
    try:
      answered = substituted(outDir, @["--client-id", IssuerToken])
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    # It refused: it did not substitute, and it did not substitute "".
    check answered == @[Sentinel]
    # WHAT IT GOT and WHAT IT NEEDED, both named.
    check message.contains("`" & $rprDevelopment & "`")
    check message.contains("`" & $rprIssuer & "`")
    check message.contains("`" & IssuerToken & "`")
    check message.contains("`" & Member & "`")
    check message.contains("DEVELOPMENT identifier")
    # ...and it points at the event-log line that answers "which
    # registrar", so the two questions §7.2 names are one question.
    check message.contains(RegistrarInstalledEventKind)
    # ...and names the offline spelling as the deliberate alternative.
    check message.contains(Token)

  test "an UNSTAMPED row is refused for `@issuer-minted:` and not assumed":
    let outDir = scratchOut("unstamped")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeOneRow(outDir, rprUnstamped)
    # The permissive token still resolves it.
    check substituted(outDir, @[Token]) == @[SharedIdText]
    var message = ""
    var answered = @[Sentinel]
    try:
      answered = substituted(outDir, @[IssuerToken])
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check answered == @[Sentinel]
    check message.contains("NOTHING CLAIMED")
    check message.contains("`" & $rprUnstamped & "`")

  test "a row written by the provenance-blind writer is `unstamped`":
    # The three-field writer exists for a caller with nothing to state.
    # It must produce a row the issuer-requiring read refuses, never one
    # it accepts.
    let outDir = scratchOut("blindwriter")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeSharedInstanceMinted(outDir, @[(serviceName: Svc, member: Member,
      mintedId: SharedIdText)])
    check readSharedInstanceMintedAttributes(outDir)[Member].provenance ==
      rprUnstamped
    expect ValueError:
      discard substituted(outDir, @[IssuerToken])

  test "a provenance word this build cannot read is `unstamped`":
    # Fail-closed on a word from a newer writer: the one answer it must
    # not reach for is `issuer`. The row still resolves through
    # `@minted:`, so a newer writer cannot break an older reader's
    # offline path.
    let outDir = scratchOut("unknownword")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeOneRow(outDir, rprIssuer)
    let path = sharedInstanceMintedPath(outDir)
    writeFile(path, readFile(path).replace(
      "\"" & MintedProvenanceField & "\":\"" & $rprIssuer & "\"",
      "\"" & MintedProvenanceField & "\":\"attested-by-a-future-build\""))
    check readSharedInstanceMintedAttributes(outDir)[Member].provenance ==
      rprUnstamped
    check substituted(outDir, @[Token]) == @[SharedIdText]
    expect ValueError:
      discard substituted(outDir, @[IssuerToken])

  test "the provenance-blind reader sees exactly the stamped reader's rows":
    let outDir = scratchOut("twinreaders")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeSharedInstanceMinted(outDir, @[
      (serviceName: Svc, member: Member, mintedId: SharedIdText,
       provenance: rprIssuer),
      (serviceName: OtherSvc, member: "blocktracer", mintedId: "b-1",
       provenance: rprDevelopment)])
    let stamped = readSharedInstanceMintedAttributes(outDir)
    let blind = readSharedInstanceMinted(outDir)
    check blind.len == stamped.len
    for key, attr in stamped:
      check blind.hasKey(key)
      check blind[key] == attr.value

suite "§7.2 — the two token families, and the embedded-token refusal":

  test "`@issuer-minted:` does not contain `@minted:`":
    # Load-bearing spelling, asserted rather than assumed: the
    # embedded-token test is a substring test, and an issuer prefix that
    # contained the plain one would be refused for the wrong reason.
    check not IssuerMintedAttributeTokenPrefix.contains(
      MintedAttributeTokenPrefix)
    check IssuerMintedAttributeTokenPrefix != MintedAttributeTokenPrefix
    # Both end the same way, which is what makes one suffix enough.
    check IssuerToken.endsWith(MintedAttributeTokenSuffix)
    check Token.endsWith(MintedAttributeTokenSuffix)

  test "an embedded `@issuer-minted:` token is refused, naming its prefix":
    let outDir = scratchOut("embeddedissuer")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeOneRow(outDir, rprIssuer)
    var message = ""
    var answered = @[Sentinel]
    try:
      answered = substituted(outDir, @["--client-id=" & IssuerToken])
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check answered == @[Sentinel]
    check message.contains("embeds a minted-attribute token")
    check message.contains(IssuerMintedAttributeTokenPrefix)

  test "an embedded `@minted:` token is still refused":
    let outDir = scratchOut("embeddedplain")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeOneRow(outDir, rprDevelopment)
    expect ValueError:
      discard substituted(outDir, @["--client-id=" & Token])

  test "an argument carrying neither prefix passes through untouched":
    let outDir = scratchOut("passthrough")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeOneRow(outDir, rprDevelopment)
    check substituted(outDir, @["--issuer", "https://login.example.test",
      "--mode=minted"]) ==
      @["--issuer", "https://login.example.test", "--mode=minted"]

suite "§7.2 — two services disagreeing about one member resolve nothing":

  test "disagreeing IDS collapse the bare key, as before":
    let outDir = scratchOut("ambigid")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeSharedInstanceMinted(outDir, @[
      (serviceName: Svc, member: Member, mintedId: "a-1",
       provenance: rprIssuer),
      (serviceName: OtherSvc, member: Member, mintedId: "b-2",
       provenance: rprIssuer)])
    let table = readSharedInstanceMintedAttributes(outDir)
    check not table.hasKey(Member)
    check table[Svc & ":" & Member].value == "a-1"
    check table[OtherSvc & ":" & Member].value == "b-2"
    # The QUALIFIED key still resolves, from each service's own view.
    check substituted(outDir, @[IssuerToken], Svc) == @["a-1"]
    check substituted(outDir, @[IssuerToken], OtherSvc) == @["b-2"]

  test "disagreeing PROVENANCES collapse the bare key too":
    # NEW DIMENSION, fail-closed. Two services reporting the same id for
    # one member name with different stamps is a disagreement about where
    # the value came from, and resolving a bare token to either of them
    # would answer §7.2's question with a coin toss.
    let outDir = scratchOut("ambigprov")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeSharedInstanceMinted(outDir, @[
      (serviceName: Svc, member: Member, mintedId: SharedIdText,
       provenance: rprIssuer),
      (serviceName: OtherSvc, member: Member, mintedId: SharedIdText,
       provenance: rprDevelopment)])
    let table = readSharedInstanceMintedAttributes(outDir)
    check not table.hasKey(Member)
    check table[Svc & ":" & Member].provenance == rprIssuer
    check table[OtherSvc & ":" & Member].provenance == rprDevelopment
    # A service asking for the bare member now gets the NOT-COMPUTED
    # refusal rather than one of the two answers.
    var message = ""
    var answered = @[Sentinel]
    try:
      answered = substituteMintedAttributes("third-service", @[Token], table)
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check answered == @[Sentinel]
    check message.contains("IS NOT COMPUTED")

suite "§7.2 — the stamp reaches a supervised service's resolved argv":

  test "an issuer row concretizes `@issuer-minted:` in a service's command":
    # THE SURFACE THAT ACTUALLY BUILDS THE CHILD'S ARGV. A stamp carried
    # as far as the table and dropped by `serviceSpecFromSummary` would
    # be a fact that is parsed, validated, carried -- and read by
    # nothing, which is this campaign's dominant finding.
    let outDir = scratchOut("specissuer")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeOneRow(outDir, rprIssuer)
    let spec = serviceSpecFromSummary(ProjectRoot,
      tokenService(@["bin/api", "--client-id", IssuerToken]),
      readSharedInstanceMintedAttributes(outDir))
    check spec.command == @["bin/api", "--client-id", SharedIdText]

  test "a development row makes the same service REFUSE to be specced":
    let outDir = scratchOut("specdev")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeOneRow(outDir, rprDevelopment)
    var message = ""
    try:
      discard serviceSpecFromSummary(ProjectRoot,
        tokenService(@["bin/api", "--client-id", IssuerToken]),
        readSharedInstanceMintedAttributes(outDir))
      check false  # unreachable
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("REQUIRES an issuer-minted")

  test "the same service with `@minted:` is specced from either row":
    let outDir = scratchOut("specplain")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    for provenance in [rprDevelopment, rprIssuer, rprUnstamped]:
      writeOneRow(outDir, provenance)
      let spec = serviceSpecFromSummary(ProjectRoot,
        tokenService(@["bin/api", "--client-id", Token]),
        readSharedInstanceMintedAttributes(outDir))
      check spec.command == @["bin/api", "--client-id", SharedIdText]
