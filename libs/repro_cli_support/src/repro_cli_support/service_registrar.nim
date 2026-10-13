## Shared-Development-Services **§7.2** — how the project that OWNS a shared
## service supplies the registrar reprobuild deliberately does not ship.
##
## § WHAT §7.2 SETTLES, AND WHAT THEREFORE IS *NOT* HERE
##
## > **Reprobuild ships no product registrar, and that is deliberate.**
## > Registering a relying party means an issuer's management API, its client
## > types and its grant types — product knowledge that does not belong in a
## > general build tool. The injection point is the contract; the project that
## > *owns* the shared service supplies the implementation.
##
## So there is no Zitadel client in this file, no OIDC vocabulary, and no
## notion of a redirect URI, an app type or a grant type. What is here is the
## other half of that sentence: a way for an owning project's implementation to
## *be* the injected `ServiceRegistrar`, since `setServiceRegistrar` is called
## inside `repro up`'s process and an owning project's recipe is not.
##
## § THE MECHANISM: A DECLARED PROGRAM, TWO FILES, AND NOTHING IMPLICIT
##
## `REPRO_SERVICE_REGISTRAR` names a program. With it set, `repro up` installs
## an `externalServiceRegistrar` around that program; with it unset the CLI
## installs its own development registrar, which §7.2 requires to stay the
## default ("requiring one to bring a stack up would make the offline path
## impossible. It is the *silence* that is wrong, not the fallback").
##
## An environment variable rather than a new DSL setter, and the precedent is
## exact: `REPRO_ENVIRONMENT` already selects the environment that *binds this
## very service's* configurables, for the reason D-SS8 gives — a choice the
## recipe must not make for the developer. Which registrar a workspace talks to
## is the same class of choice: it is a property of the machine the developer is
## sitting at (is there an issuer running here?) rather than of the recipe. A
## declared program is not a naming convention either way: nothing here infers
## a registrar from a path, a file name or a service name.
##
## THE PROTOCOL IS TWO FILES, NOT TWO PIPES:
##
## ```text
## <program> --request <request.json> --answer <answer.json>
## ```
##
## The program reads the request, performs the registration, writes the answer,
## and exits 0. Its stdout and stderr are the developer's — inherited, not
## captured — because an issuer's management API failing is the thing the
## developer most needs to read, and a protocol that owned the pipes would bury
## it. A pipe-based protocol would also make every log line a potential parse
## error, which is how a registrar that worked becomes a registrar that
## "returned invalid JSON".
##
## § WHY EVERY DISAGREEMENT HERE IS A REFUSAL
##
## This file's whole subject is a value that must not be invented, so each of
## the ways an answer can fall short is refused by name rather than smoothed
## over. In particular a **requested member the answer does not mention** is
## refused: that is the silent drop this campaign keeps finding, and the
## alternative — recording the members that came back and saying nothing about
## the rest — leaves a consumer with an uncomputed `clientId` and the failure
## surfacing at the issuer.
##
## An answer claiming any provenance other than `issuer` is also refused. An
## external registrar exists to return the issuer's identifier; one that
## announces a development value is not an alternative to the built-in
## development registrar, it is a confusing duplicate of it, and installing it
## would mean two code paths producing the same stamp with different failure
## modes.
##
## **WHAT THIS DOES NOT DO, STATED PLAINLY.** Reprobuild does not verify that
## the program spoke to an issuer. It cannot: verifying would mean holding the
## issuer's credentials and re-asking, which is the product knowledge §7.2 keeps
## out of the build tool. The `issuer` stamp on a value is therefore *the
## installed registrar's claim*, and what §7.2 asks of reprobuild is narrower
## and is enforced: reprobuild's OWN development registrar is marked, cannot
## claim another provenance (`setServiceRegistrar` refuses it by name), and a
## consumer can refuse what it produced by asking.
##
## § TEST-DOUBLE POLICY
##
## Nothing here is mocked. `encodeServiceRegistrarRequest` and
## `decodeServiceRegistrarAnswer` are pure functions over real JSON text and
## are tested as such; `externalServiceRegistrar` spawns a real program with
## `uncontrolledStartProcess` and is tested against real scripts on the real
## filesystem. The program is `uncontrolled` by nature — it is supplied by a
## project and reprobuild cannot have a typed execution profile for a binary it
## has never seen.

import std/[algorithm, json, os, osproc, strutils, tables]

import repro_core                        # extendedPath
import repro_core/ambient_execution      # uncontrolledStartProcess
import repro_resources/readiness_edge    # the §7.2 provenance contract

type
  ServiceRegistrarError* = object of CatchableError
    ## Every refusal this module raises. Distinct from
    ## `ReadinessEdgeError` so a caller can tell "the project's registrar
    ## answered badly" from "the edge itself refused".

const
  ServiceRegistrarProgramEnvVar* = "REPRO_SERVICE_REGISTRAR"
    ## Names the program that performs the registration. Unset (or empty
    ## after stripping) means the development registrar, which §7.2 keeps
    ## as the default.

  ServiceRegistrarRequestSchemaId* =
    "reprobuild.service-registrar-request.v1"
  ServiceRegistrarAnswerSchemaId* =
    "reprobuild.service-registrar-answer.v1"
    ## Both documents carry their schema id and both are CHECKED. A
    ## program answering a shape this build cannot read is refused rather
    ## than parsed optimistically: the field that would be missed is the
    ## identifier itself.

  RegistrarRequestFlag* = "--request"
  RegistrarAnswerFlag* = "--answer"

proc resolveExternalServiceRegistrarProgram*(): string =
  ## The declared registrar program, or `""` for "none declared".
  ##
  ## Stripped, because a variable set to whitespace by a shell fragment is
  ## a variable nobody meant to set, and treating it as a program name
  ## would fail with `cannot start ` and a blank path.
  getEnv(ServiceRegistrarProgramEnvVar).strip()

proc externalServiceRegistrarIdentity*(program: string):
    ServiceRegistrarIdentity =
  ## How an external registrar announces itself in the session event log.
  ##
  ## The program's path is part of the NAME on purpose. §7.2 wants the log
  ## to answer "did this workspace ever talk to an issuer", and `external`
  ## alone does not: two machines can have two different programs, and the
  ## one a reader cares about is the one that ran here.
  ServiceRegistrarIdentity(name: "external:" & program,
    provenance: rprIssuer)

proc encodeServiceRegistrarRequest*(attrs: ServiceRegistrationAttrs): string =
  ## The request document. Carries the folded member set AND its parallel
  ## contributor attribution, because a project-supplied registrar may
  ## legitimately need to know which consumer asked for a member — a
  ## redirect URI often belongs to the contributor rather than to the
  ## service.
  var members = newJArray()
  for m in attrs.members:
    members.add(%m)
  var contributors = newJArray()
  for c in attrs.contributors:
    contributors.add(%c)
  let doc = %*{
    "schemaId": ServiceRegistrarRequestSchemaId,
    "serviceName": attrs.serviceName,
    "instanceAddress": attrs.instanceAddress,
    "members": members,
    "contributors": contributors}
  $doc & "\n"

proc decodeServiceRegistrarAnswer*(program, text: string;
                                   requested: openArray[string]):
    seq[tuple[member, mintedId: string]] =
  ## Read a registrar's answer, or REFUSE BY NAME.
  ##
  ## `requested` is what was asked for, and it is a parameter rather than
  ## something inferred from the answer because the two most dangerous
  ## shapes are exactly the disagreements between them: a member that was
  ## asked for and not answered (a silent drop), and a member that was
  ## answered and not asked for (an invention).
  var doc: JsonNode
  try:
    doc = parseJson(text)
  except CatchableError as err:
    raise newException(ServiceRegistrarError,
      "the service registrar `" & program & "` wrote an answer that is " &
      "not JSON: " & err.msg & ". The protocol is " &
      "Shared-Development-Services.md §7.2's: write `" &
      ServiceRegistrarAnswerSchemaId & "` to the path given by `" &
      RegistrarAnswerFlag & "`. Note that stdout and stderr are YOURS -- " &
      "they are inherited by the developer's terminal and are never " &
      "parsed -- so log freely and keep the answer in the file.")
  if doc.kind != JObject:
    raise newException(ServiceRegistrarError,
      "the service registrar `" & program & "` answered with a JSON " &
      $doc.kind & " rather than an object.")
  let schema = doc{"schemaId"}.getStr("")
  if schema != ServiceRegistrarAnswerSchemaId:
    raise newException(ServiceRegistrarError,
      "the service registrar `" & program & "` answered with schemaId `" &
      schema & "`; this build reads `" & ServiceRegistrarAnswerSchemaId &
      "` only. Refused rather than read field by field: a document of an " &
      "unknown shape that happens to carry a `registrations` key would " &
      "be parsed into client ids nothing has validated.")
  let word = doc{"provenance"}.getStr("")
  var provenance = rprUnstamped
  var known = false
  for candidate in RegistrarProvenance:
    if $candidate == word:
      provenance = candidate
      known = true
      break
  if not known:
    raise newException(ServiceRegistrarError,
      "the service registrar `" & program & "` declared provenance `" &
      word & "`, which this build does not know. Declare `\"provenance\": " &
      "\"" & $rprIssuer & "\"`. An unknown word is REFUSED rather than " &
      "defaulted: defaulting to `" & $rprIssuer & "` would let a typo " &
      "claim the issuer, and defaulting to anything else would silently " &
      "downgrade a real registration.")
  if provenance != rprIssuer:
    raise newException(ServiceRegistrarError,
      "the service registrar `" & program & "` declared provenance `" &
      $provenance & "`. An EXTERNAL registrar exists to return the " &
      "issuer's identifier (Shared-Development-Services.md §7.2), so an " &
      "answer that does not claim `" & $rprIssuer & "` is refused: it is " &
      "not an alternative to reprobuild's built-in development " &
      "registrar, it is a second copy of it with different failure " &
      "modes. Unset `" & ServiceRegistrarProgramEnvVar & "` to use the " &
      "offline path deliberately -- that is the supported way to bring " &
      "a stack up without an issuer.")
  let rows = doc{"registrations"}
  if rows.isNil or rows.kind != JArray:
    raise newException(ServiceRegistrarError,
      "the service registrar `" & program & "` answered with no " &
      "`registrations` array. An answer that registers nothing is " &
      "refused rather than read as `nothing to register`: every " &
      "consumer's `" & ClientIdAttributeName & "` would stay uncomputed " &
      "and the failure would surface at the issuer instead of here.")
  var seen = initTable[string, string]()
  for row in rows:
    if row.kind != JObject:
      raise newException(ServiceRegistrarError,
        "the service registrar `" & program & "` answered with a " &
        "registration row that is a JSON " & $row.kind & " rather than " &
        "an object.")
    let member = row{"member"}.getStr("")
    let clientId = row{ClientIdAttributeName}.getStr("")
    if member.len == 0:
      raise newException(ServiceRegistrarError,
        "the service registrar `" & program & "` answered with a " &
        "registration row carrying no `member`, so there is no way to " &
        "say which consumer its `" & ClientIdAttributeName & "` belongs " &
        "to.")
    if clientId.len == 0:
      raise newException(ServiceRegistrarError,
        "the service registrar `" & program & "` answered member `" &
        member & "` with an EMPTY `" & ClientIdAttributeName & "`. " &
        "D-SS10: \"a nil or an empty string is the one answer that must " &
        "not be chosen\", because an empty string is indistinguishable " &
        "from a legitimately empty value. A registrar that could not " &
        "register a member must fail and say which one.")
    if seen.hasKey(member):
      raise newException(ServiceRegistrarError,
        "the service registrar `" & program & "` answered member `" &
        member & "` twice, with `" & seen[member] & "` and `" & clientId &
        "`. Refused rather than last-writer-wins: the two rows are two " &
        "claims about one consumer's credential and nothing here can " &
        "choose between them.")
    seen[member] = clientId
  var requestedSet = initTable[string, bool]()
  for m in requested:
    requestedSet[m] = true
  var missing: seq[string] = @[]
  for m in requested:
    if not seen.hasKey(m):
      missing.add(m)
  if missing.len > 0:
    raise newException(ServiceRegistrarError,
      "the service registrar `" & program & "` was asked to register " &
      $requested.len & " member(s) and did not answer " &
      $missing.len & " of them: `" & missing.join("`, `") & "`. " &
      "REFUSED rather than partially applied, because the members it " &
      "did answer would be recorded and the ones it did not would " &
      "leave their consumers with an uncomputed `" &
      ClientIdAttributeName & "` and no diagnostic -- the silent drop " &
      "this edge exists to make impossible. A registrar that cannot " &
      "register a member must fail and name it.")
  var invented: seq[string] = @[]
  for member in seen.keys:
    if not requestedSet.hasKey(member):
      invented.add(member)
  if invented.len > 0:
    invented.sort()
    raise newException(ServiceRegistrarError,
      "the service registrar `" & program & "` answered member(s) `" &
      invented.join("`, `") & "` that were not requested. Refused " &
      "rather than ignored: an answer naming a member this instance " &
      "never folded means the registrar and the recipe disagree about " &
      "which members exist, and recording the overlap would hide that.")
  # The answer is returned in REQUEST ORDER, not in the order the program
  # happened to write it. The caller pairs these rows with nothing, but a
  # reader diffing two runs' `shared-instance-registrations.json` should
  # not see a reordering that means nothing.
  for m in requested:
    result.add((member: m, mintedId: seen[m]))

proc runExternalServiceRegistrar*(program, scratchDir: string;
                                  attrs: ServiceRegistrationAttrs):
    seq[tuple[member, mintedId: string]] =
  ## Run the declared program once and read its answer.
  ##
  ## `scratchDir` is where the two protocol files live. A parameter rather
  ## than a temp directory chosen here, so a caller (and a test) can say
  ## where they go and read them afterwards: "what exactly was the
  ## registrar asked" is the first question when a registration goes
  ## wrong.
  createDir(extendedPath(scratchDir))
  let requestPath = scratchDir / "registrar-request.json"
  let answerPath = scratchDir / "registrar-answer.json"
  writeFile(extendedPath(requestPath), encodeServiceRegistrarRequest(attrs))
  # A STALE ANSWER IS WORSE THAN NO ANSWER: left in place, a program that
  # exits 0 without writing would be read as having registered exactly
  # what it registered last time, against an instance that may have been
  # re-seeded since.
  removeFile(extendedPath(answerPath))
  var exitCode = -1
  try:
    var process = uncontrolledStartProcess(program, getCurrentDir(),
      [RegistrarRequestFlag, requestPath, RegistrarAnswerFlag, answerPath],
      options = {poParentStreams})
    try:
      exitCode = process.waitForExit()
    finally:
      process.close()
  except CatchableError as err:
    raise newException(ServiceRegistrarError,
      "the service registrar `" & program & "` could not be started: " &
      err.msg & ". `" & ServiceRegistrarProgramEnvVar & "` must name an " &
      "executable program; unset it to use reprobuild's offline " &
      "development registrar instead.")
  if exitCode != 0:
    raise newException(ServiceRegistrarError,
      "the service registrar `" & program & "` exited " & $exitCode &
      ". Its own output went to this terminal (the protocol inherits " &
      "stdout and stderr), and the request it was given is still at " &
      requestPath & ". Nothing was registered and no `" &
      ClientIdAttributeName & "` was computed, which is the point: a " &
      "registrar that failed must not leave a consumer holding an " &
      "identifier no issuer knows.")
  if not fileExists(extendedPath(answerPath)):
    raise newException(ServiceRegistrarError,
      "the service registrar `" & program & "` exited 0 and wrote no " &
      "answer at " & answerPath & ". An exit code is not a " &
      "registration: a program that succeeds without answering leaves " &
      "every member's `" & ClientIdAttributeName & "` uncomputed while " &
      "reporting success, so the missing file is refused here rather " &
      "than discovered at the issuer.")
  decodeServiceRegistrarAnswer(program, readFile(extendedPath(answerPath)),
    attrs.members)

proc externalServiceRegistrar*(program, scratchDir: string): ServiceRegistrar =
  ## The injectable form: a `ServiceRegistrar` that runs the declared
  ## program. Install it with
  ## `setServiceRegistrar(externalServiceRegistrar(p, d),
  ## externalServiceRegistrarIdentity(p))`.
  result = proc (attrs: ServiceRegistrationAttrs):
      seq[tuple[member, mintedId: string]] {.closure.} =
    runExternalServiceRegistrar(program, scratchDir, attrs)
