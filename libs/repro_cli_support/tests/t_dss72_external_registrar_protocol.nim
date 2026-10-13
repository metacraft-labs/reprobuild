## Shared-Development-Services **§7.2** — HOW THE OWNING PROJECT'S REGISTRAR
## IS REACHED, AND WHY EVERY SHORTFALL IN ITS ANSWER IS A REFUSAL.
##
## §7.2 settles that reprobuild ships no product registrar and that "the
## project that *owns* the shared service supplies the implementation". The
## injection point is `setServiceRegistrar`, which is called inside `repro
## up`'s process; an owning project's recipe is not. `service_registrar.nim`
## is the bridge: a program the operator declares with
## `REPRO_SERVICE_REGISTRAR`, driven over a two-file protocol.
##
## § WHAT IS REAL HERE
##
## Every case below writes a REAL program to a REAL temp directory, makes it
## executable, and runs it through the production `runExternalServiceRegistrar`
## — a real `uncontrolledStartProcess`, a real exit code, a real answer file
## read off the real filesystem. The programs are `/bin/sh` scripts because a
## project's registrar is whatever the project wrote; what is under test is
## reprobuild's side of the contract.
##
## § THE CASES ARE THE WAYS A REGISTRAR CAN QUIETLY NOT REGISTER
##
## This file's subject is a credential that must not be invented, so the
## interesting cases are the near-misses rather than the happy path:
##
##   * **exit 0 and no answer file.** An exit code is not a registration. A
##     program that succeeds without answering would leave every member's
##     `clientId` uncomputed while reporting success.
##   * **a STALE answer file.** The sharpest of them: an answer left by the
##     previous run, plus a program that exits 0 without writing, reads as
##     "registered exactly what it registered last time" — against an
##     instance that may have been re-seeded since. The answer path is
##     removed before the program runs, and the case proves it by leaving a
##     valid-but-stale answer in place and asserting the run REFUSES.
##   * **a requested member the answer omits.** The silent drop: recording
##     the members that came back and saying nothing about the rest is how a
##     consumer ends up with no client id and no diagnostic.
##   * **a member the answer invents.** The registrar and the recipe disagree
##     about which members exist; recording the overlap would hide that.
##   * **a duplicated member**, an **empty clientId**, an **unknown
##     provenance word**, and a **`development` claim** from an external
##     registrar — each refused by name.
##
## § WHAT THIS FILE DOES NOT CLAIM
##
## It does not claim that an `issuer` stamp means an issuer was spoken to.
## Reprobuild cannot verify that without holding the issuer's credentials and
## re-asking, which is the product knowledge §7.2 keeps out of the build tool.
## What §7.2 asks of reprobuild is narrower and is tested in
## `t_dss72_registrar_provenance_is_marked_and_refusable.nim`: its own
## development registrar is marked, cannot claim another provenance, and is
## refusable by asking.
##
## § MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
##
## There is no test double anywhere here. The registrar programs are real
## programs; `decodeServiceRegistrarAnswer` is exercised both through them and
## directly as the pure function it is, over real JSON text.

import std/[json, os, strutils, unittest]

import repro_cli_support/service_registrar
import repro_resources/readiness_edge

const
  Svc = "sso"
  Instance = "service-instance:com.example.dss72.sso#workspace#dev"
  Members = @["isonim-site", "codetracer-cli"]
  Contributors = @["isonim", "codetracer"]
  IssuerIds = @["394610871109772528", "394610871243990256"]
  Sentinel = "\u0001SENTINEL-NOT-OVERWRITTEN"

proc attrs(members = Members; contributors = Contributors):
    ServiceRegistrationAttrs =
  ServiceRegistrationAttrs(serviceName: Svc, instanceAddress: Instance,
    members: members, contributors: contributors)

type
  Scratch = object
    root: string
    program: string

proc newScratch(tag: string): Scratch =
  let root = getTempDir() / ("dss72-reg-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  Scratch(root: root, program: root / "register-rp.sh")

proc drop(s: Scratch) =
  try: removeDir(s.root)
  except CatchableError: discard

proc writeProgram(s: Scratch; body: string) =
  writeFile(s.program, "#!/bin/sh\n" & body)
  setFilePermissions(s.program, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc answeringProgram(rows: string; provenance = $rprIssuer): string =
  ## A program that parses its own argv for `--answer` and writes the
  ## given rows there. It also copies the request beside the answer, so a
  ## case can assert what the registrar was actually asked.
  """
answer=""
request=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --answer) answer="$2"; shift 2 ;;
    --request) request="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$request" "$(dirname "$answer")/seen-request.json"
cat > "$answer" <<'JSON'
{"schemaId": "reprobuild.service-registrar-answer.v1",
 "provenance": "PROVENANCE",
 "registrations": [ROWS]}
JSON
""".replace("ROWS", rows).replace("PROVENANCE", provenance)

proc issuerRows(): string =
  var parts: seq[string] = @[]
  for i, m in Members:
    parts.add("{\"member\": \"" & m & "\", \"" & ClientIdAttributeName &
      "\": \"" & IssuerIds[i] & "\"}")
  parts.join(", ")

proc runIt(s: Scratch; a = attrs()):
    seq[tuple[member, mintedId: string]] =
  runExternalServiceRegistrar(s.program, s.root / "scratch", a)

proc refusalFrom(s: Scratch; a = attrs()): string =
  ## Run and return the refusal message, asserting that it REFUSED rather
  ## than answering. A bare `expect` cannot tell a refusal from a return
  ## the except arm never saw.
  var answered = @[(member: Sentinel, mintedId: Sentinel)]
  var message = ""
  try:
    answered = s.runIt(a)
  except ServiceRegistrarError as err:
    message = err.msg
  doAssert answered == @[(member: Sentinel, mintedId: Sentinel)],
    "the registrar ANSWERED where a refusal was required: " & $answered
  message

suite "§7.2 — the declared program is reached, and its answer is used":

  test "a conforming program's answer is returned in REQUEST order":
    let s = newScratch("happy")
    defer: s.drop()
    s.writeProgram(answeringProgram(issuerRows()))
    let rows = s.runIt()
    check rows.len == Members.len
    for i, m in Members:
      check rows[i].member == m
      check rows[i].mintedId == IssuerIds[i]

  test "the request carries the schema, the service, the instance and the fold":
    let s = newScratch("request")
    defer: s.drop()
    s.writeProgram(answeringProgram(issuerRows()))
    discard s.runIt()
    let seen = parseJson(readFile(s.root / "scratch" / "seen-request.json"))
    check seen{"schemaId"}.getStr("") == ServiceRegistrarRequestSchemaId
    check seen{"serviceName"}.getStr("") == Svc
    check seen{"instanceAddress"}.getStr("") == Instance
    var gotMembers: seq[string] = @[]
    for node in seen{"members"}:
      gotMembers.add(node.getStr(""))
    check gotMembers == Members
    # The parallel attribution travels too: a project's registrar may
    # legitimately need to know WHICH consumer asked for a member.
    var gotContributors: seq[string] = @[]
    for node in seen{"contributors"}:
      gotContributors.add(node.getStr(""))
    check gotContributors == Contributors

  test "the answer is ordered by the request, not by the program":
    # A program answering in its own order must not reorder what a reader
    # diffing two runs' session files sees.
    let s = newScratch("order")
    defer: s.drop()
    var reversed: seq[string] = @[]
    for i in countdown(Members.high, 0):
      reversed.add("{\"member\": \"" & Members[i] & "\", \"" &
        ClientIdAttributeName & "\": \"" & IssuerIds[i] & "\"}")
    s.writeProgram(answeringProgram(reversed.join(", ")))
    let rows = s.runIt()
    check rows[0].member == Members[0]
    check rows[1].member == Members[1]

suite "§7.2 — the ways a registrar can quietly not register are refusals":

  test "a non-zero exit refuses, naming the code and the request path":
    let s = newScratch("exitcode")
    defer: s.drop()
    s.writeProgram("echo 'the issuer said no' >&2\nexit 7\n")
    let message = s.refusalFrom()
    checkpoint(message)
    check message.contains("exited 7")
    check message.contains("registrar-request.json")

  test "exit 0 with NO answer file refuses: an exit code is not a registration":
    let s = newScratch("noanswer")
    defer: s.drop()
    s.writeProgram("exit 0\n")
    let message = s.refusalFrom()
    checkpoint(message)
    check message.contains("wrote no answer")
    check message.contains("An exit code is not a")

  test "a STALE answer file is not read: it is removed before the run":
    # THE SHARPEST NEAR-MISS. A perfectly valid answer from a previous
    # run, plus a program that exits 0 without writing, would read as a
    # successful registration of last run's identifiers.
    let s = newScratch("stale")
    defer: s.drop()
    s.writeProgram(answeringProgram(issuerRows()))
    discard s.runIt()
    let answerPath = s.root / "scratch" / "registrar-answer.json"
    check fileExists(answerPath)
    let staleBytes = readFile(answerPath)
    check staleBytes.contains(IssuerIds[0])
    # Now a program that does nothing at all. The stale answer is right
    # there and must not be believed.
    s.writeProgram("exit 0\n")
    let message = s.refusalFrom()
    checkpoint(message)
    check message.contains("wrote no answer")
    check not fileExists(answerPath)

  test "a requested member the answer OMITS refuses, naming it":
    let s = newScratch("omitted")
    defer: s.drop()
    s.writeProgram(answeringProgram(
      "{\"member\": \"" & Members[0] & "\", \"" & ClientIdAttributeName &
      "\": \"" & IssuerIds[0] & "\"}"))
    let message = s.refusalFrom()
    checkpoint(message)
    check message.contains("did not answer")
    check message.contains("`" & Members[1] & "`")
    check message.contains("silent drop")

  test "a member the answer INVENTS refuses, naming it":
    let s = newScratch("invented")
    defer: s.drop()
    s.writeProgram(answeringProgram(issuerRows() &
      ", {\"member\": \"nobody-asked\", \"" & ClientIdAttributeName &
      "\": \"x-1\"}"))
    let message = s.refusalFrom()
    checkpoint(message)
    check message.contains("not requested")
    check message.contains("nobody-asked")

  test "a duplicated member refuses rather than last-writer-wins":
    let s = newScratch("duplicate")
    defer: s.drop()
    s.writeProgram(answeringProgram(issuerRows() &
      ", {\"member\": \"" & Members[0] & "\", \"" &
      ClientIdAttributeName & "\": \"other-1\"}"))
    let message = s.refusalFrom()
    checkpoint(message)
    check message.contains("twice")
    check message.contains("`" & Members[0] & "`")

  test "an EMPTY clientId refuses: D-SS10's one forbidden answer":
    let s = newScratch("emptyid")
    defer: s.drop()
    s.writeProgram(answeringProgram(
      "{\"member\": \"" & Members[0] & "\", \"" & ClientIdAttributeName &
      "\": \"\"}, {\"member\": \"" & Members[1] & "\", \"" &
      ClientIdAttributeName & "\": \"" & IssuerIds[1] & "\"}"))
    let message = s.refusalFrom()
    checkpoint(message)
    check message.contains("EMPTY")
    check message.contains("`" & Members[0] & "`")

  test "a program that cannot be started refuses, naming the variable":
    let s = newScratch("missing")
    defer: s.drop()
    # Deliberately never written: the declared program does not exist.
    let message = s.refusalFrom()
    checkpoint(message)
    check message.contains("could not be started")
    check message.contains(ServiceRegistrarProgramEnvVar)

suite "§7.2 — an external registrar must claim the issuer, and say so legibly":

  test "an answer claiming `development` is refused":
    # An external registrar exists to return the issuer's identifier. One
    # announcing a development value is not an alternative to the
    # built-in development registrar; it is a second copy of it with
    # different failure modes, and the supported offline path is to unset
    # the variable.
    let s = newScratch("devclaim")
    defer: s.drop()
    s.writeProgram(answeringProgram(issuerRows(),
      provenance = $rprDevelopment))
    let message = s.refusalFrom()
    checkpoint(message)
    check message.contains("`" & $rprDevelopment & "`")
    check message.contains(ServiceRegistrarProgramEnvVar)

  test "an unknown provenance word is refused, not defaulted":
    let s = newScratch("unknownprov")
    defer: s.drop()
    s.writeProgram(answeringProgram(issuerRows(),
      provenance = "attested-by-a-future-build"))
    let message = s.refusalFrom()
    checkpoint(message)
    check message.contains("does not know")
    check message.contains("attested-by-a-future-build")

  test "a wrong schemaId is refused rather than read field by field":
    let s = newScratch("schema")
    defer: s.drop()
    s.writeProgram(answeringProgram(issuerRows()).replace(
      ServiceRegistrarAnswerSchemaId, "some.other.answer.v9"))
    let message = s.refusalFrom()
    checkpoint(message)
    check message.contains("some.other.answer.v9")
    check message.contains(ServiceRegistrarAnswerSchemaId)

  test "a missing `registrations` array is refused, not read as `nothing to do`":
    let s = newScratch("noarray")
    defer: s.drop()
    var message = ""
    var answered = @[(member: Sentinel, mintedId: Sentinel)]
    try:
      answered = decodeServiceRegistrarAnswer("p",
        "{\"schemaId\": \"" & ServiceRegistrarAnswerSchemaId &
        "\", \"provenance\": \"" & $rprIssuer & "\"}", Members)
    except ServiceRegistrarError as err:
      message = err.msg
    checkpoint(message)
    check answered == @[(member: Sentinel, mintedId: Sentinel)]
    check message.contains("no `registrations` array")
    check message.contains("nothing to register")

  test "an answer that is not JSON, or not an object, is refused":
    for text in ["not json at all", "[1, 2, 3]", "\"a string\""]:
      var message = ""
      try:
        discard decodeServiceRegistrarAnswer("p", text, Members)
        check false  # unreachable
      except ServiceRegistrarError as err:
        message = err.msg
      checkpoint(text & " -> " & message)
      check message.len > 0

suite "§7.2 — the declared program, and the identity it announces":

  test "an unset or whitespace variable means NO external registrar":
    # The development registrar stays the default, which is §7.2's fourth
    # bullet: "requiring one to bring a stack up would make the offline
    # path impossible".
    let saved = getEnv(ServiceRegistrarProgramEnvVar)
    defer: putEnv(ServiceRegistrarProgramEnvVar, saved)
    delEnv(ServiceRegistrarProgramEnvVar)
    check resolveExternalServiceRegistrarProgram() == ""
    putEnv(ServiceRegistrarProgramEnvVar, "   \t ")
    check resolveExternalServiceRegistrarProgram() == ""
    putEnv(ServiceRegistrarProgramEnvVar, " /opt/x/register.sh ")
    check resolveExternalServiceRegistrarProgram() == "/opt/x/register.sh"

  test "the announced identity names the program and claims the issuer":
    let identity = externalServiceRegistrarIdentity("/opt/x/register.sh")
    check identity.provenance == rprIssuer
    check identity.name.contains("/opt/x/register.sh")
    # NOT the development registrar's name, which `setServiceRegistrar`
    # refuses to pair with any other provenance.
    check identity.name != DevelopmentRegistrarName
    # And it is installable, which is the thing that would break if the
    # two names ever collided.
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    setServiceRegistrar(externalServiceRegistrar("/opt/x/register.sh",
      getTempDir()), identity)
    check installedServiceRegistrarIdentity() == identity
