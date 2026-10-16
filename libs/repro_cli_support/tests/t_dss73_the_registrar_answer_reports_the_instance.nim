## Shared-Development-Services **§7.3** — THE REGISTRAR REPORTS WHAT THE
## RUNNING INSTANCE IS, IN THE SAME ANSWER AND FROM THE SAME RUN.
##
## §7.3 settles WHERE the issuer URL lives (a computed attribute of the
## instance, on the minted lane). This file is about WHO produces it, which
## §7.3 leaves to the implementation and which has four candidates. The one
## implemented is **the registrar**, and the others lose for reasons that are
## measured rather than aesthetic:
##
##   * **The owner's service writes a descriptor and something reads it.**
##     Rejected BY NAME in the step-5 design note of
##     `resolveSharedServiceReferences`: "A DESCRIPTOR FILE OR AN ENVIRONMENT
##     VARIABLE between the two projects ... carries no stamp, so the consumer
##     cannot ask where the value came from, and it outlives the issuer it
##     describes." L9's review measured that outliving: `dev-server.sh`'s
##     `cleanup()` removed the readiness marker and not the descriptor, so a
##     product read a dead issuer's client ids after `repro down`.
##
##   * **The daemon derives it from the instance's bound address.** The daemon
##     holds a transport address, not an issuer URL; §7.3 says the value is a
##     function of the instance AND its environment ("which hostname the
##     selected environment gave it"), and the daemon holds no environment
##     bindings and no scheme. It would have to guess `http://127.0.0.1:<port>`,
##     which is not the `iss` an OIDC client must present. The registration
##     record is also deliberately NOT the daemon's — "two writers on one
##     record is a race".
##
##   * **The environment binding supplies it and the instance confirms it.**
##     Half right, and the half it gets wrong is the one §7.3 turns on: the
##     binding is an INPUT to the instance, known at expansion, while the
##     attribute is what the instance turned out to be. An implementation that
##     delivered the binding would be delivering §7.3's "guess" under the
##     attribute's name.
##
##   * **The registrar reports it.** The registrar is the one component that
##     has actually spoken to the running instance — that is what makes its
##     `issuer` stamp meaningful for a client id, and it makes the same stamp
##     meaningful for the instance's address. It is reached only after the
##     service's declared readiness (§7.1's edge), so what it reports is a
##     property of a live, seeded instance. One run, one answer, one stamp.
##
## § WHAT THIS FILE MEASURES
##
##   * the attributes arrive from a REAL program over the real two-file
##     protocol, and from the SAME RUN as the registrations — one process, one
##     answer document, one parse;
##   * `decodeServiceRegistrarAnswer` is a PROJECTION of the document decode
##     and not a second parse, so the two halves cannot come from different
##     readings;
##   * the answer's field name and the durable record's are ONE definition,
##     asserted equal rather than claimed to "match";
##   * every way the attribute half can be a value nobody determined is
##     refused BY NAME: a non-object, a non-string value, an empty string;
##   * the key is OPTIONAL, because a registrar for a service with no external
##     identity has nothing to report — and an absent key yields no attributes
##     rather than an empty-valued one.
##
## § MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED
##
## Every case either writes a REAL `/bin/sh` program to a real temp directory
## and runs it through the production `runExternalServiceRegistrarAnswer` (a
## real `uncontrolledStartProcess`, a real exit code, a real answer file), or
## calls the production decode directly as the pure function over real JSON
## text that it is. There is no substituted type and no injected callback.

import std/[os, strutils, unittest]

import repro_cli_support/service_registrar
import repro_resources/readiness_edge
import repro_resources/service_registry   # InstanceAttributesField

const
  Svc = "sso"
  Instance = "service-instance:com.example.dss73.sso#workspace#dev"
  Members = @["isonim-site"]
  Contributors = @["isonim"]
  IssuerId = "394615916756821232"
  IssuerUrl = "https://login.metacraft-labs.test:19443"
  Sentinel = "\u0001SENTINEL-NOT-OVERWRITTEN"

proc attrs(): ServiceRegistrationAttrs =
  ServiceRegistrationAttrs(serviceName: Svc, instanceAddress: Instance,
    members: Members, contributors: Contributors)

proc answerText(attributesJson: string): string =
  ## A full answer document with the §7.3 half spliced in verbatim, so a
  ## case can write a shape the encoder would never produce.
  "{\"schemaId\": \"" & ServiceRegistrarAnswerSchemaId & "\"," &
  " \"provenance\": \"" & $rprIssuer & "\"," &
  " \"registrations\": [{\"member\": \"" & Members[0] & "\", \"" &
  ClientIdAttributeName & "\": \"" & IssuerId & "\"}]" &
  (if attributesJson.len == 0: ""
   else: ", \"" & RegistrarAnswerInstanceAttributesField & "\": " &
     attributesJson) & "}"

proc decoded(attributesJson: string): ServiceRegistrarAnswer =
  decodeServiceRegistrarAnswerDocument("/opt/registrar.sh",
    answerText(attributesJson), Members)

proc refusalFor(attributesJson: string): string =
  ## Decode and return the refusal, asserting that it REFUSED rather than
  ## answered. A bare `expect` cannot tell a refusal from a return the
  ## except arm never saw.
  var answered = ServiceRegistrarAnswer(
    instanceAttributes: @[(name: Sentinel, value: Sentinel)])
  try:
    answered = decoded(attributesJson)
    check false
  except ServiceRegistrarError as err:
    result = err.msg
  check answered.instanceAttributes == @[(name: Sentinel, value: Sentinel)]

suite "§7.3 — the answer document's instance attributes":

  test "an `issuer` attribute decodes beside the registrations":
    let answer = decoded("{\"" & IssuerAttributeName & "\": \"" &
      IssuerUrl & "\"}")
    check answer.registrations.len == 1
    check answer.registrations[0].mintedId == IssuerId
    check answer.instanceAttributes.len == 1
    check answer.instanceAttributes[0].name == IssuerAttributeName
    check answer.instanceAttributes[0].value == IssuerUrl

  test "the key is OPTIONAL and an absent one yields no attributes":
    let answer = decoded("")
    check answer.registrations.len == 1
    check answer.instanceAttributes.len == 0

  test "an explicit `null` is read as absent, not as an empty value":
    let answer = decoded("null")
    check answer.instanceAttributes.len == 0

  test "an empty object yields no attributes":
    check decoded("{}").instanceAttributes.len == 0

  test "several attributes come back SORTED BY NAME":
    # Deterministic order, so two runs of one registrar produce one
    # session document and a reader diffing them does not see a
    # reordering that means nothing.
    let answer = decoded("{\"zulu\": \"z\", \"" & IssuerAttributeName &
      "\": \"" & IssuerUrl & "\", \"alpha\": \"a\"}")
    check answer.instanceAttributes.len == 3
    check answer.instanceAttributes[0].name == "alpha"
    check answer.instanceAttributes[1].name == IssuerAttributeName
    check answer.instanceAttributes[2].name == "zulu"

  test "`decodeServiceRegistrarAnswer` is the registrations PROJECTION":
    # ONE PARSE. The old spelling still answers exactly the rows the
    # document decode found; if it parsed the text a second time, the
    # two readings could disagree about a document both halves of the
    # lane depend on.
    let text = answerText("{\"" & IssuerAttributeName & "\": \"" &
      IssuerUrl & "\"}")
    check decodeServiceRegistrarAnswer("/opt/registrar.sh", text,
      Members) ==
      decodeServiceRegistrarAnswerDocument("/opt/registrar.sh", text,
        Members).registrations

  test "the answer's field name IS the durable record's, one definition":
    # Asserted rather than claimed to match: the two documents carry the
    # same key, and binding one constant to the other is what makes that
    # structural. A test that pinned both literals would pass while they
    # drifted.
    check RegistrarAnswerInstanceAttributesField == InstanceAttributesField

suite "§7.3 — a value nobody determined is refused by name":

  test "a non-object `instanceAttributes` is refused":
    let message = refusalFor("[\"" & IssuerUrl & "\"]")
    checkpoint(message)
    check message.contains(RegistrarAnswerInstanceAttributesField)
    check message.contains("rather than an object")
    check message.contains("§7.3")

  test "a non-string value is refused rather than stringified":
    let message = refusalFor("{\"" & IssuerAttributeName & "\": 19443}")
    checkpoint(message)
    check message.contains("`" & IssuerAttributeName & "`")
    check message.contains("rather than a string")

  test "an EMPTY string value is refused, and the remedy is to OMIT it":
    let message = refusalFor("{\"" & IssuerAttributeName & "\": \"\"}")
    checkpoint(message)
    check message.contains("EMPTY")
    check message.contains("must not be chosen")
    check message.contains("OMIT")

  test "a refused attribute half refuses the WHOLE answer":
    # The registrations in that same document are well formed. They are
    # NOT returned: an answer whose attribute half is malformed is an
    # answer this build cannot read, and recording the half it could
    # would be the partial application the registration half already
    # refuses by name.
    expect ServiceRegistrarError:
      discard decoded("{\"" & IssuerAttributeName & "\": \"\"}")

suite "§7.3 — a REAL registrar program reports both halves in one run":

  setup:
    let root = getTempDir() / ("dss73-reg-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    let program = root / "register-rp.sh"

  teardown:
    try: removeDir(root)
    except CatchableError: discard

  test "one run of one program answers the ids AND the issuer URL":
    # The shape `infra/scripts/sso-register-relying-party.sh` has: read
    # the request, answer each requested member's client id, and report
    # the issuer the instance is actually serving. ONE run, because the
    # issuer is the authority on both and two runs against a real issuer
    # would register twice.
    writeFile(program, "#!/bin/sh\n" & """
answer=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --answer) answer="$2"; shift 2 ;;
    *) shift ;;
  esac
done
# Count the runs, so the case can assert there was exactly one.
echo run >> "$(dirname "$answer")/runs"
cat > "$answer" <<'JSON'
{"schemaId": "reprobuild.service-registrar-answer.v1",
 "provenance": "issuer",
 "registrations": [{"member": "MEMBER", "clientId": "CLIENTID"}],
 "instanceAttributes": {"issuer": "ISSUERURL"}}
JSON
""".replace("MEMBER", Members[0]).replace("CLIENTID", IssuerId)
      .replace("ISSUERURL", IssuerUrl))
    setFilePermissions(program, {fpUserRead, fpUserWrite, fpUserExec})
    let answer = runExternalServiceRegistrarAnswer(program,
      root / "scratch", attrs())
    check answer.registrations == @[(member: Members[0],
      mintedId: IssuerId)]
    check answer.instanceAttributes == @[(name: IssuerAttributeName,
      value: IssuerUrl)]
    check readFile(root / "scratch" / "runs").strip().splitLines().len == 1

  test "`runExternalServiceRegistrar` is one run of the same program":
    # The registrations-only spelling delegates rather than duplicating.
    # A caller that wanted both halves and called both procs would launch
    # the registrar twice -- against a real issuer, registering twice --
    # which is why the wrapper exists as a projection.
    writeFile(program, "#!/bin/sh\n" & """
answer=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --answer) answer="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo run >> "$(dirname "$answer")/runs"
cat > "$answer" <<'JSON'
{"schemaId": "reprobuild.service-registrar-answer.v1",
 "provenance": "issuer",
 "registrations": [{"member": "MEMBER", "clientId": "CLIENTID"}],
 "instanceAttributes": {"issuer": "ISSUERURL"}}
JSON
""".replace("MEMBER", Members[0]).replace("CLIENTID", IssuerId)
      .replace("ISSUERURL", IssuerUrl))
    setFilePermissions(program, {fpUserRead, fpUserWrite, fpUserExec})
    check runExternalServiceRegistrar(program, root / "scratch",
      attrs()) == @[(member: Members[0], mintedId: IssuerId)]
    check readFile(root / "scratch" / "runs").strip().splitLines().len == 1

  test "a registrar that reports NO attributes is not a failure":
    # §7.2 keeps the offline path; §7.3 adds no new obligation to a
    # registrar that has no external identity to report. The refusal
    # belongs at the point of use, naming the attribute the recipe asked
    # for.
    writeFile(program, "#!/bin/sh\n" & """
answer=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --answer) answer="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$answer" <<'JSON'
{"schemaId": "reprobuild.service-registrar-answer.v1",
 "provenance": "issuer",
 "registrations": [{"member": "MEMBER", "clientId": "CLIENTID"}]}
JSON
""".replace("MEMBER", Members[0]).replace("CLIENTID", IssuerId))
    setFilePermissions(program, {fpUserRead, fpUserWrite, fpUserExec})
    let answer = runExternalServiceRegistrarAnswer(program,
      root / "scratch", attrs())
    check answer.registrations.len == 1
    check answer.instanceAttributes.len == 0

  test "a program that answers an EMPTY issuer URL is refused":
    writeFile(program, "#!/bin/sh\n" & """
answer=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --answer) answer="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$answer" <<'JSON'
{"schemaId": "reprobuild.service-registrar-answer.v1",
 "provenance": "issuer",
 "registrations": [{"member": "MEMBER", "clientId": "CLIENTID"}],
 "instanceAttributes": {"issuer": ""}}
JSON
""".replace("MEMBER", Members[0]).replace("CLIENTID", IssuerId))
    setFilePermissions(program, {fpUserRead, fpUserWrite, fpUserExec})
    var message = ""
    try:
      discard runExternalServiceRegistrarAnswer(program, root / "scratch",
        attrs())
      check false
    except ServiceRegistrarError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("EMPTY")
