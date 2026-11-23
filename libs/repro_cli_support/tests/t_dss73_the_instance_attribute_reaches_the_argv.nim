## Shared-Development-Services **§7.3** — `@instance-attribute:<name>@` AT THE
## POINT OF USE, AND WHAT AN ABSENT ONE DOES.
##
## §7.3 corrects §9.3 rather than implementing it. §9.3 wrote `sso.issuer`, a
## member on the lifted service handle; §7.3 measured that spelling as having
## no referent and decided:
##
## > **The decision: the issuer URL is a computed attribute OF THE INSTANCE,
## > reached by the same mechanism as the minted client id. It does not become
## > a field on the handle.**
##
## > The handle is resolved at **expansion**, and the issuer URL does not exist
## > then. It is a property of a *running* instance — which port it bound,
## > which hostname the selected environment gave it.
##
## So this file measures the lane's LAST hop, the one §9.3's corrected example
## spells:
##
## ```nim
## args "--issuer",    "@instance-attribute:issuer@"
##      "--client-id", "@issuer-minted:isonim-site@"
## ```
##
## § WHAT THIS FILE ASSERTS, AND WHICH OF IT IS STRUCTURAL
##
## The *resolution* is an assertion: a row in the session document reaches a
## supervised service's resolved `command`. The *refusals* are assertions too
## — each is a raise this file provokes and reads.
##
## ONE PROPERTY HERE IS STRUCTURAL rather than asserted, and it is worth
## separating: `@instance-attribute:` has **no permissive spelling**. There is
## no token that resolves an attribute without requiring the `issuer`
## provenance, because none is declared — so "a development issuer URL reaches
## a consumer" is not a case that is checked and refused, it is a case that
## cannot be written. What IS asserted is that the only spelling that exists
## refuses a non-`issuer` row by name. (`@minted:` deliberately *is* the
## permissive spelling of its pair, because §7.2 keeps the offline path
## working for an identifier. An issuer URL has no usable offline form.)
##
## § THE NEAR-MISSES PROBED, BECAUSE A DECLARED-AND-DROPPED CONSTRUCT IS THIS
## § CAMPAIGN'S DOMINANT FINDING
##
##   * a MISSPELLED attribute name — refused, naming what is available, which
##     is the diagnostic that ends the investigation in one read;
##   * an attribute on a service that reported NONE — refused, and the refusal
##     says that the development registrar reports none and why;
##   * TWO TOKENS IN ONE ARGV, one of each family — both resolve, from their
##     own tables, in one pass;
##   * the token EMBEDDED in a larger argument (`--issuer=@instance-…@`) —
##     refused rather than rewritten, like its two siblings. Before §7.3 this
##     shape and the whole-argument shape behaved identically and both were
##     wrong: the token matched no prefix and was passed through VERBATIM, so a
##     consuming service received the literal text `@instance-attribute:issuer@`
##     as its `--issuer`;
##   * the token in a NON-ARGV position (`cwd`, `workingDirectory`) — NOT
##     substituted, and that is the documented boundary rather than a gap:
##     §7.3's lane is argv, and silently resolving tokens in a path would
##     invent a second surface with no refusal on it;
##   * TWO SHARED SERVICES each reporting an `issuer` — the bare name becomes
##     ambiguous and refuses; the qualified name resolves. Picking one would be
##     a service pointed at the wrong issuer with nothing said;
##   * the THREE TOKEN PREFIXES' non-containment, in all six directions.
##
## § MOCK POLICY — NO MOCK OBJECTS, AND NONE MAY BE ADDED
##
## No test double, stub or fake. Every case writes the session document with
## the real `writeSharedInstanceMinted` / `mergeSharedInstanceMinted`, reads it
## back with the real `readSharedInstanceAttributes`, and asks the real
## `substituteMintedAttributes` and the real `serviceSpecFromSummary` what a
## supervised service's argv would be — over a real directory on the real
## filesystem. `RegistrarProvenance` is the production enum the resource lane
## stamps with, so this file cannot be measuring a second vocabulary.

import std/[os, strutils, tables, unittest]

import cbor                             # cborText, for the empty `metadata`
import repro_dev_env_artifacts          # DevEnvServiceSummary
import repro_cli_support/dev_session
import repro_cli_support/service_registrar  # the env var the refusal names
import repro_resources/readiness_edge

const
  Svc = "sso"
  OtherSvc = "idp"
  Consumer = "api-server"
  Member = "isonim-site"
  IssuerUrl = "https://login.metacraft-labs.test"
  OtherIssuerUrl = "https://login.other.test"
  MintedId = "394615916756821232"
  IssuerToken = InstanceAttributeTokenPrefix & IssuerAttributeName &
    MintedAttributeTokenSuffix
  MintedToken = IssuerMintedAttributeTokenPrefix & Member &
    MintedAttributeTokenSuffix
  Sentinel = "\u0001SENTINEL-NOT-OVERWRITTEN"
  ProjectRoot = "/nonexistent/dss73/project"
    ## Never touched on disk: `serviceSpecFromSummary` only joins paths
    ## with it, and the cases here read the resolved argv.

proc scratchOut(tag: string): string =
  let root = getTempDir() / ("dss73-argv-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  root

proc writeIssuerAttribute(outDir: string;
                          provenance = rprIssuer;
                          service = Svc;
                          name = IssuerAttributeName;
                          value = IssuerUrl;
                          registrar = "external:/opt/registrar.sh") =
  writeSharedInstanceMinted(outDir, @[], @[(serviceName: service,
    name: name, value: value, registrar: registrar,
    provenance: provenance)])

proc substituted(outDir: string; command: seq[string];
                 service = Consumer): seq[string] =
  substituteMintedAttributes(service, command,
    readSharedInstanceMintedAttributes(outDir),
    readSharedInstanceAttributes(outDir))

proc tokenService(command: seq[string]; cwd = "."): DevEnvServiceSummary =
  DevEnvServiceSummary(
    name: Consumer,
    activityRequirements: @[Consumer],
    metadata: cborText(""),
    typedCommand: command,
    workingDirectory: cwd)

suite "§7.3 — the running instance's issuer URL reaches the argv":

  test "the attribute round-trips the session document with its stamp":
    let outDir = scratchOut("roundtrip")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir)
    let rows = readSharedInstanceAttributeRows(outDir)
    check rows.len == 1
    check rows[0].serviceName == Svc
    check rows[0].name == IssuerAttributeName
    check rows[0].value == IssuerUrl
    check rows[0].provenance == rprIssuer
    let table = readSharedInstanceAttributes(outDir)
    # BOTH KEYS, for the same reason the minted fold has both: a
    # consumer names what it needs and does not know which shared
    # service reported it.
    check table[IssuerAttributeName].value == IssuerUrl
    check table[Svc & ":" & IssuerAttributeName].value == IssuerUrl
    check table[IssuerAttributeName].registrar == "external:/opt/registrar.sh"

  test "`@instance-attribute:issuer@` concretizes to the recorded URL":
    let outDir = scratchOut("resolve")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir)
    check substituted(outDir, @["--issuer", IssuerToken]) ==
      @["--issuer", IssuerUrl]

  test "it reaches a SUPERVISED service's resolved command":
    # THE SURFACE THAT ACTUALLY BUILDS THE CHILD'S ARGV. An attribute
    # carried as far as the table and dropped by `serviceSpecFromSummary`
    # would be a fact parsed, validated, carried -- and read by nothing.
    let outDir = scratchOut("spec")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir)
    let spec = serviceSpecFromSummary(ProjectRoot,
      tokenService(@["bin/api", "--issuer", IssuerToken]),
      readSharedInstanceMintedAttributes(outDir),
      readSharedInstanceAttributes(outDir))
    check spec.command == @["bin/api", "--issuer", IssuerUrl]

  test "TWO TOKENS IN ONE ARGV, one of each family, both resolve":
    # §9.3's corrected example verbatim. The two values come from two
    # row sets of ONE document and are concretized in one pass; a
    # reader that handled only the family it was looking for would leave
    # the other verbatim, which is the shape this whole file exists for.
    let outDir = scratchOut("both")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeSharedInstanceMinted(outDir,
      @[(serviceName: Svc, member: Member, mintedId: MintedId,
         provenance: rprIssuer)],
      @[(serviceName: Svc, name: IssuerAttributeName, value: IssuerUrl,
         registrar: "external:/opt/registrar.sh",
         provenance: rprIssuer)])
    let spec = serviceSpecFromSummary(ProjectRoot,
      tokenService(@["bin/api", "--issuer", IssuerToken,
        "--client-id", MintedToken]),
      readSharedInstanceMintedAttributes(outDir),
      readSharedInstanceAttributes(outDir))
    check spec.command == @["bin/api", "--issuer", IssuerUrl,
      "--client-id", MintedId]

  test "the F5 cross-session MERGE keeps both row sets":
    # `mergeSharedInstanceMinted` is the resolver's writer: a project
    # that both declares a shared service and resolves another's merges
    # into rows it already wrote. A merge that read the document and
    # wrote back only the registrations would drop every attribute --
    # a silent drop with a merge's name on it.
    let outDir = scratchOut("merge")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeSharedInstanceMinted(outDir,
      @[(serviceName: Svc, member: Member, mintedId: MintedId,
         provenance: rprIssuer)], @[])
    mergeSharedInstanceMinted(outDir, @[],
      @[(serviceName: Svc, name: IssuerAttributeName, value: IssuerUrl,
         registrar: "external:/opt/registrar.sh",
         provenance: rprIssuer)])
    check readSharedInstanceMintedRows(outDir).len == 1
    check readSharedInstanceAttributeRows(outDir).len == 1
    mergeSharedInstanceMinted(outDir,
      @[(serviceName: Svc, member: "second", mintedId: "2",
         provenance: rprIssuer)], @[])
    # The attribute survived a merge that passed none.
    check readSharedInstanceAttributeRows(outDir).len == 1
    check readSharedInstanceMintedRows(outDir).len == 2
    check substituted(outDir, @["--issuer", IssuerToken]) ==
      @["--issuer", IssuerUrl]

  test "a merged attribute REPLACES one of the same name":
    let outDir = scratchOut("mergereplace")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir)
    mergeSharedInstanceMinted(outDir, @[],
      @[(serviceName: Svc, name: IssuerAttributeName,
         value: OtherIssuerUrl, registrar: "external:/opt/registrar.sh",
         provenance: rprIssuer)])
    check readSharedInstanceAttributeRows(outDir).len == 1
    check substituted(outDir, @[IssuerToken]) == @[OtherIssuerUrl]

suite "§7.3 — an attribute that is not available REFUSES BY NAME":

  test "an absent attribute refuses, naming it, and yields neither nil nor \"\"":
    let outDir = scratchOut("absent")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    # A document with a minted row and NO attributes -- the offline
    # shape, and the one a build predating §7.3 always produced.
    writeSharedInstanceMinted(outDir,
      @[(serviceName: Svc, member: Member, mintedId: MintedId,
         provenance: rprIssuer)], @[])
    var message = ""
    var answered = @[Sentinel]
    try:
      answered = substituted(outDir, @["--issuer", IssuerToken])
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    # THE SENTINEL IS THE ASSERTION THAT NOTHING WAS CHOSEN. D-SS10: "a
    # nil or an empty string is the one answer that must not be
    # chosen", and the verbatim token is the third wrong answer.
    check answered == @[Sentinel]
    check message.contains("`" & IssuerAttributeName & "`")
    check message.contains("NOT AVAILABLE")
    check message.contains("§7.3")
    # It says WHICH SERVICE asked...
    check message.contains("`" & Consumer & "`")
    # ...and WHAT WOULD SUPPLY IT.
    check message.contains(ServiceRegistrarProgramEnvVar)
    check message.contains("development registrar reports none")
    check message.contains("(none)")
    # And it does not resolve to the empty string anywhere in the result.
    check "" notin answered

  test "a MISSPELLED name is refused, naming what IS available":
    let outDir = scratchOut("misspelled")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir)
    var message = ""
    var answered = @[Sentinel]
    try:
      answered = substituted(outDir,
        @[InstanceAttributeTokenPrefix & "issuerUrl" &
          MintedAttributeTokenSuffix])
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check answered == @[Sentinel]
    check message.contains("`issuerUrl`")
    check message.contains("Attributes this session has: " &
      IssuerAttributeName)
    check message.contains("misspelling")

  test "the registrar's OWN misspelling surfaces as the consumer's refusal":
    # The other direction of the same typo: the recipe asks for
    # `issuer` and the registrar answered `issuerUrl`. Reprobuild
    # cannot know which of the two is wrong -- it holds no whitelist of
    # attribute names, deliberately -- so the refusal prints both and
    # the author decides.
    let outDir = scratchOut("registrartypo")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir, name = "issuerUrl")
    var message = ""
    try:
      discard substituted(outDir, @[IssuerToken])
      check false
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("`" & IssuerAttributeName & "`")
    check message.contains("issuerUrl")

  test "a DEVELOPMENT-stamped attribute is refused, naming the registrar":
    let outDir = scratchOut("devstamp")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir, provenance = rprDevelopment,
      registrar = DevelopmentRegistrarName)
    var message = ""
    var answered = @[Sentinel]
    try:
      answered = substituted(outDir, @[IssuerToken])
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check answered == @[Sentinel]
    check message.contains($rprDevelopment)
    check message.contains(DevelopmentRegistrarName)
    check message.contains("no offline spelling")

  test "an UNSTAMPED attribute is refused and not assumed":
    let outDir = scratchOut("unstamped")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir, provenance = rprUnstamped, registrar = "")
    var message = ""
    try:
      discard substituted(outDir, @[IssuerToken])
      check false
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check message.contains($rprUnstamped)
    check message.contains("(none recorded)")

  test "a row with an EMPTY value is SKIPPED, so the token refuses by name":
    # The session document's rows are skipped where the DURABLE record's
    # are refused, and the asymmetry is deliberate: the refusal that
    # matters is the one naming the attribute the recipe asked for, and
    # one malformed row must not stop a session whose services ask for
    # nothing.
    let outDir = scratchOut("emptyvalue")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir, value = "")
    check readSharedInstanceAttributeRows(outDir).len == 0
    var message = ""
    try:
      discard substituted(outDir, @[IssuerToken])
      check false
    except ValueError as err:
      message = err.msg
    check message.contains("NOT AVAILABLE")

suite "§7.3 — the shapes that must not resolve quietly":

  test "an EMBEDDED token is refused, naming the prefix and the shape":
    let outDir = scratchOut("embedded")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir)
    var message = ""
    var answered = @[Sentinel]
    try:
      answered = substituted(outDir, @["--issuer=" & IssuerToken])
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check answered == @[Sentinel]
    check message.contains("embeds an instance-attribute token")
    check message.contains("WHOLE argument only")
    check message.contains(InstanceAttributeTokenPrefix & "<name>")

  test "a token naming NOTHING refuses rather than resolving an empty name":
    # `@instance-attribute:@` has prefix and suffix and nothing between.
    # It parses as a token whose name is `""`, which matches no row, so
    # it takes the not-available refusal -- the SAME shape `@minted:@`
    # has taken since L8, deliberately unchanged here. What matters is
    # that it does not resolve: an empty name must not be allowed to
    # match an empty-named row, because `reconcileServiceInstanceAttributes`
    # refuses to store one.
    let outDir = scratchOut("emptyname")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir)
    var answered = @[Sentinel]
    var message = ""
    try:
      answered = substituted(outDir,
        @[InstanceAttributeTokenPrefix & MintedAttributeTokenSuffix])
    except ValueError as err:
      message = err.msg
    check answered == @[Sentinel]
    check message.contains("NOT AVAILABLE")

  test "the token in a NON-ARGV position is NOT substituted":
    # `workingDirectory` is not argv, and §7.3's lane is argv. This is
    # the boundary stated as a measurement rather than left implicit:
    # a reader that rewrote paths too would be a second surface with no
    # refusal on it, and a developer would discover it by having a
    # directory named after a URL.
    let outDir = scratchOut("nonargv")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir)
    let spec = serviceSpecFromSummary(ProjectRoot,
      tokenService(@["bin/api"], cwd = IssuerToken),
      readSharedInstanceMintedAttributes(outDir),
      readSharedInstanceAttributes(outDir))
    check spec.command == @["bin/api"]
    check spec.cwd == ProjectRoot / IssuerToken

  test "TWO SERVICES reporting `issuer` drop the bare key":
    let outDir = scratchOut("ambiguous")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeSharedInstanceMinted(outDir, @[],
      @[(serviceName: Svc, name: IssuerAttributeName, value: IssuerUrl,
         registrar: "external:/a.sh", provenance: rprIssuer),
        (serviceName: OtherSvc, name: IssuerAttributeName,
         value: OtherIssuerUrl, registrar: "external:/b.sh",
         provenance: rprIssuer)])
    let table = readSharedInstanceAttributes(outDir)
    check not table.hasKey(IssuerAttributeName)
    check table[Svc & ":" & IssuerAttributeName].value == IssuerUrl
    check table[OtherSvc & ":" & IssuerAttributeName].value ==
      OtherIssuerUrl
    # A third service asking for the bare name is REFUSED rather than
    # pointed at whichever row sorted first.
    var message = ""
    try:
      discard substituteMintedAttributes("third-service", @[IssuerToken],
        initTable[string, MintedAttribute](), table)
      check false
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("NOT AVAILABLE")
    # The service whose NAME matches a row still resolves, through the
    # qualified key.
    check substituteMintedAttributes(Svc, @[IssuerToken],
      initTable[string, MintedAttribute](), table) == @[IssuerUrl]

  test "two services reporting the SAME URL keep the bare key":
    # The fold drops a bare key only on DISAGREEMENT. Two services
    # behind one issuer is the ordinary case and must not refuse.
    let outDir = scratchOut("agree")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeSharedInstanceMinted(outDir, @[],
      @[(serviceName: Svc, name: IssuerAttributeName, value: IssuerUrl,
         registrar: "external:/a.sh", provenance: rprIssuer),
        (serviceName: OtherSvc, name: IssuerAttributeName,
         value: IssuerUrl, registrar: "external:/a.sh",
         provenance: rprIssuer)])
    check substituted(outDir, @[IssuerToken]) == @[IssuerUrl]

suite "§7.3 — the three token families cannot be confused":

  test "no prefix contains another, in all six directions":
    # LOAD-BEARING, exactly as it is for the minted pair. The embedded
    # check is a SUBSTRING test, so a rename that made one prefix
    # contain another would refuse a valid token for the wrong reason
    # -- and would do it silently, because the refusal would still be a
    # refusal.
    let prefixes = [MintedAttributeTokenPrefix,
      IssuerMintedAttributeTokenPrefix, InstanceAttributeTokenPrefix]
    for i in 0 ..< prefixes.len:
      for j in 0 ..< prefixes.len:
        if i != j:
          check not prefixes[i].contains(prefixes[j])

  test "`@issuer-minted:` behaviour is UNCHANGED by §7.3":
    # THE POSITIVE CONTROL FOR THE EXISTING LANE. §7.3 adds a sibling;
    # a change that made the minted pair resolve differently would be a
    # regression this file is positioned to catch, because it holds both
    # row sets in one document.
    let outDir = scratchOut("unchanged")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeSharedInstanceMinted(outDir,
      @[(serviceName: Svc, member: Member, mintedId: MintedId,
         provenance: rprIssuer)],
      @[(serviceName: Svc, name: IssuerAttributeName, value: IssuerUrl,
         registrar: "external:/a.sh", provenance: rprIssuer)])
    check substituted(outDir, @["--client-id", MintedToken]) ==
      @["--client-id", MintedId]
    check substituted(outDir,
      @["--client-id", MintedAttributeTokenPrefix & Member &
        MintedAttributeTokenSuffix]) == @["--client-id", MintedId]

  test "`@issuer-minted:`'s PROVENANCE REFUSAL is unchanged":
    let outDir = scratchOut("unchangedrefusal")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeSharedInstanceMinted(outDir,
      @[(serviceName: Svc, member: Member, mintedId: MintedId,
         provenance: rprDevelopment)],
      @[(serviceName: Svc, name: IssuerAttributeName, value: IssuerUrl,
         registrar: "external:/a.sh", provenance: rprIssuer)])
    var message = ""
    try:
      discard substituted(outDir, @["--client-id", MintedToken])
      check false
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("REQUIRES an issuer-minted")
    # And the attribute beside it still resolves: one refusal does not
    # depend on the other's row set.
    check substituted(outDir, @["--issuer", IssuerToken]) ==
      @["--issuer", IssuerUrl]

  test "an attribute-only document leaves the minted refusal intact":
    let outDir = scratchOut("attronly")
    defer: (try: removeDir(outDir) except CatchableError: discard)
    writeIssuerAttribute(outDir)
    var message = ""
    try:
      discard substituted(outDir, @["--client-id", MintedToken])
      check false
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("IS NOT COMPUTED")
